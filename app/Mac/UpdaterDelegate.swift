import AppKit
import DayCore
import Foundation
import Sparkle
import os

/// Marks the feed request on the author's own Macs with `self=1`, so apps.idea2prod.in, which
/// counts update checks, can tell them from everyone else's. `OwnerMac` is a user default that
/// only the author sets, from outside the app; on any other Mac it is unset and the request
/// goes out plain.
///
/// No system profile is ever sent: `SUEnableSystemProfiling` is not set in Info.plist, and
/// `sendingSystemProfile` is ignored here, so nothing can add it through this delegate.
///
/// It also installs downloaded updates. Sparkle downloads an update in the background and
/// then waits for the app to quit to install it, and Day lives in the menu bar and is almost
/// never quit, so an update could stay staged for weeks. Instead Day takes the install over
/// (`willInstallUpdateOnQuit`) and relaunches into the new version at the first idle moment,
/// by `isIdleForUpdate`: checked when the update is ready, every minute after, and whenever
/// Day stops being the active app. Quitting before then still installs it, as before.
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    static let ownerKey = "OwnerMac"

    private let defaults: UserDefaults
    /// The current and next event at a moment, from the store the menu bar label reads.
    private let upcoming: @MainActor (Date) -> NextEvents

    /// Sparkle's handler that quits, installs and relaunches; held while an update waits.
    private var install: (() -> Void)?
    private var version = ""
    private var ticker: Task<Void, Never>?
    private var resignObserver: (any NSObjectProtocol)?
    /// The last reason logged for waiting, so a minute-by-minute check logs only changes.
    private var lastWait = ""

    private static let log = Logger(subsystem: DayIdentifiers.bundleID, category: "update")

    init(defaults: UserDefaults = .standard, upcoming: @escaping @MainActor (Date) -> NextEvents) {
        self.defaults = defaults
        self.upcoming = upcoming
    }

    func feedParameters(
        for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool
    ) -> [[String: String]] {
        defaults.bool(forKey: Self.ownerKey) ? [["key": "self", "value": "1"]] : []
    }

    // MARK: Installing when idle

    /// Returning true tells Sparkle that Day installs this one itself. A later call carries a
    /// newer update and replaces the held handler.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        install = immediateInstallHandler
        version = "\(item.displayVersionString) (\(item.versionString))"
        lastWait = ""
        Self.log.notice("update \(self.version, privacy: .public) ready; installing when idle")
        startWatching()
        installIfIdle()
        return true
    }

    /// The cycle ended without the install, or Sparkle gave the update up: its handler no
    /// longer installs anything.
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        drop()
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        drop()
    }

    private func drop() {
        guard install != nil else { return }
        Self.log.notice("update \(self.version, privacy: .public) dropped by Sparkle")
        install = nil
        ticker?.cancel()
        ticker = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private func startWatching() {
        if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    self?.installIfIdle()
                }
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // On the next turn, once the panel or window that just lost focus has gone.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.installIfIdle() } }
            }
        }
    }

    /// Hands the install back to Sparkle when Day is idle. The handler stays held: Sparkle
    /// lets it run again if the quit it starts is cancelled.
    private func installIfIdle() {
        guard let install else { return }
        let now = Date()
        let next = upcoming(now)
        let windows = Self.ownWindows()
        guard isIdleForUpdate(appIsActive: NSApp.isActive, windows: windows, next: next, now: now)
        else {
            let shown = windows.filter { $0.isKey || $0.isVisible }.count
            let near = !isIdleForUpdate(appIsActive: false, windows: [], next: next, now: now)
            let wait = "active \(NSApp.isActive), windows shown \(shown), event near \(near)"
            if wait != lastWait {
                lastWait = wait
                Self.log.notice("update \(self.version, privacy: .public) waits: \(wait, privacy: .public)")
            }
            return
        }
        Self.log.notice("update \(self.version, privacy: .public) installing now")
        install()
    }

    /// Day's windows as the rule sees them. The menu bar item's own window is always on
    /// screen and is left out; the panel under it is a window of its own and counts. A window
    /// is visible when some of it is on screen uncovered, not merely ordered in behind others.
    private static func ownWindows() -> [AppWindow] {
        NSApp.windows.filter { !isMenuBarItem($0) }.map { window in
            AppWindow(
                isKey: window.isKeyWindow,
                isVisible: window.isVisible && window.occlusionState.contains(.visible))
        }
    }

    /// AppKit's window for a status item: `NSStatusBarWindow`, at the status bar level, never
    /// key. The second test keeps it out should the class be renamed.
    private static func isMenuBarItem(_ window: NSWindow) -> Bool {
        window.className == "NSStatusBarWindow"
            || (window.level == .statusBar && !window.canBecomeKey)
    }
}
