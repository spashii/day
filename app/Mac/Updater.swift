import DayCore
import Foundation
import Observation
import Sparkle

/// Updates come through Sparkle: it reads the appcast on Day's website (apps.idea2prod.in),
/// checks each update against the signing key in Info.plist, downloads it in the background
/// and installs it without asking, at the first idle moment (UpdaterDelegate). Checking and
/// installing automatically are the defaults in Info.plist, so Sparkle never asks about them;
/// `Check for updates automatically` in Settings turns both off. Nothing else in Day goes
/// online for updates.
///
/// A run that was started with `-UseFixtures` (screenshots, tests) never starts Sparkle, so
/// its network check cannot land in a capture.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    /// Sparkle does not retain its delegate, so the updater has to.
    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// False while a check is already under way, and always false when Sparkle was not
    /// started.
    private(set) var canCheck = false

    /// `Check for updates automatically`. Sparkle can change the setting itself, so it is read
    /// through the observation below too.
    var automatic: Bool {
        didSet {
            if controller.updater.automaticallyChecksForUpdates != automatic {
                controller.updater.automaticallyChecksForUpdates = automatic
            }
        }
    }

    /// `upcoming` gives the current and next event at a moment, which the delegate needs to
    /// keep a relaunch away from the start of a meeting.
    init(start: Bool, upcoming: @escaping @MainActor (Date) -> NextEvents = { _ in NextEvents() }) {
        delegate = UpdaterDelegate(upcoming: upcoming)
        let controller = SPUStandardUpdaterController(
            startingUpdater: start, updaterDelegate: delegate, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        automatic = updater.automaticallyChecksForUpdates
        canCheck = updater.canCheckForUpdates
        // Sparkle changes both on the main thread.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.canCheck = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated {
                    if self?.automatic != value { self?.automatic = value }
                }
            },
        ]
        if start {
            observations.append(
                UserDefaults.standard.observe(\.SULastCheckTime, options: [.new]) { [weak self] _, change in
                    let last = change.newValue ?? nil
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.checkIfAsked(last: last) } }
                })
        }
    }

    /// `Check for Updates…`.
    func check() {
        controller.checkForUpdates(nil)
    }

    /// Sparkle reads its last check time only when it schedules the next check, so moving it
    /// back from outside (tools/verify-release.sh does, to prove a release lands) would wait
    /// for the next launch. A time further back than the check interval can only have come
    /// from outside, since Sparkle writes the current time, so it means: check now. The update
    /// that check finds installs at the first idle moment, like any other.
    private func checkIfAsked(last: Date?) {
        let updater = controller.updater
        guard let last, Date().timeIntervalSince(last) > updater.updateCheckInterval,
            updater.automaticallyChecksForUpdates, updater.canCheckForUpdates
        else { return }
        updater.checkForUpdatesInBackground()
    }
}

extension UserDefaults {
    /// Sparkle's last check time, named as its key so that key-value observing sees changes,
    /// including ones written by another process.
    @objc dynamic var SULastCheckTime: Date? {
        object(forKey: "SULastCheckTime") as? Date
    }
}
