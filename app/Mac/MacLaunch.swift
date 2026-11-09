import AppKit
import DayCore
import SwiftUI

/// What this run of the Mac app is made of, built once: the store, the shared state and the
/// two settings models. The scenes, the menu commands and the app delegate all read the same
/// ones.
///
/// The invented fixture runs when `-UseFixtures` is passed or no Google client is configured;
/// otherwise `AppModel` runs on the real engine, as on the iPhone.
@MainActor
final class MacLaunch {
    static let shared = MacLaunch()

    let store: any CalendarStore
    /// Nil on the fixture, which has nothing to fetch.
    let model: AppModel?
    let state: MacState
    let updater: Updater
    let login = OpenAtLogin()

    private init() {
        // Edit holds Copy and nothing else: AppKit would add Start Dictation, Emoji & Symbols
        // and AutoFill to it, none of which has anywhere to go in a read-only calendar.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "NSDisabledDictationMenuItem")
        defaults.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
        defaults.set(false, forKey: "NSAutoFillHeuristicControllerEnabled")

        if let fixture = FixtureStore.fromLaunchArguments() {
            store = fixture
            model = nil
        } else if let live = AppModel.live() {
            store = live
            model = live
        } else {
            store = FixtureStore()
            model = nil
        }
        state = MacState(store: store)
        // Screenshots and tests pass -UseFixtures; Sparkle stays off for them. The events are
        // the menu bar label's, read at the moment the update asks rather than on the store's
        // minute clock, so the two minutes around a start are exact.
        updater = Updater(
            start: UserDefaults.standard.string(forKey: "UseFixtures") == nil,
            upcoming: { [store] now in
                let today = CivilDate(now, in: store.calendar)
                return nextEvents(
                    events: store.events(in: today...today.adding(days: 8)), now: now,
                    calendar: store.calendar)
            })
    }
}

/// Starts the clock and the schedule when the app launches, refreshes when it comes to the
/// front, and keeps Day running in the menu bar when the window closes.
@MainActor
final class DayAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything can schedule a reminder, so a click on one that arrived while Day
        // was not running reaches it.
        ReminderResponder.shared.activate()
        MacLaunch.shared.model?.start()
        MenuTrim.start()
        #if DEBUG
            DebugSnapshot.startIfRequested()
        #endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MacLaunch.shared.model?.sceneDidBecomeActive()
        MacLaunch.shared.login.refresh()
    }

    /// Closing the window leaves Day in the menu bar; Command-Q quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Hides the top-level menus that have nothing in them. SwiftUI leaves the title of a menu
/// behind when every item of its command group is replaced, which here is Format: the app has
/// no text to format, and an empty menu in the bar reads as broken. File is empty too while no
/// window is open and returns with Close. SwiftUI rebuilds menus when commands or windows
/// change, so this runs again whenever an item is added or removed. The menus are hidden, not
/// removed, because SwiftUI keeps filling the same menu objects.
@MainActor
enum MenuTrim {
    private static var observers: [any NSObjectProtocol] = []

    static func start() {
        trim()
        guard observers.isEmpty else { return }
        observers = [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Not inside the notification: the menu is still being changed.
                DispatchQueue.main.async { MainActor.assumeIsolated { trim() } }
            }
        }
    }

    private static func trim() {
        guard let main = NSApp.mainMenu else { return }
        // Index 0 is the application menu; the rest are the bar's menus.
        for item in main.items.dropFirst() {
            guard let submenu = item.submenu else { continue }
            tidy(submenu)
            // Help holds the system's menu search even when it lists no items of its own.
            let empty = submenu !== NSApp.helpMenu
                && submenu.items.allSatisfy { $0.isSeparatorItem || $0.isHidden }
            if item.isHidden != empty {
                item.isHidden = empty
            }
        }
    }

    /// Hides what the app has no use for and the system adds on its own: the sidebar toggle
    /// (the day pane has its own item), AutoFill beside Copy, and any separator that would
    /// lead, trail or double up once those are gone.
    private static func tidy(_ menu: NSMenu) {
        let hasCopy = menu.items.contains { $0.title == "Copy" }
        for item in menu.items {
            let unwanted =
                item.action == #selector(NSSplitViewController.toggleSidebar(_:))
                || (hasCopy && item.hasSubmenu)
            if unwanted, !item.isHidden {
                item.isHidden = true
            }
        }
        var previousIsSeparator = true
        for item in menu.items where !item.isHidden || item.isSeparatorItem {
            if item.isSeparatorItem {
                let hide = previousIsSeparator
                if item.isHidden != hide { item.isHidden = hide }
                previousIsSeparator = true
            } else {
                previousIsSeparator = false
            }
        }
        // A separator left at the end has nothing after it.
        for item in menu.items.reversed() {
            if item.isHidden { continue }
            if item.isSeparatorItem { item.isHidden = true }
            break
        }
    }
}
