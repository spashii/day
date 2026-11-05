import DayCore
import SwiftUI

/// Day for the Mac: one window with the Month and the selected day beside it, a menu bar item
/// with today in a panel, and Settings. A regular app with a Dock icon; closing the window
/// leaves it running in the menu bar and Command-Q quits.
@main
struct DayMacApp: App {
    @NSApplicationDelegateAdaptor(DayAppDelegate.self) private var delegate
    private let launch = MacLaunch.shared
    @State private var showsMenuBarItem = DayMacApp.showsMenuBarItem

    init() { LatencyCommand.runIfAsked() }

    /// A snapshot run draws into files and shows nothing, so it adds no item beside the one
    /// of the Day that is running.
    private static var showsMenuBarItem: Bool {
        #if DEBUG
            UserDefaults.standard.string(forKey: "SnapshotTo") == nil
        #else
            true
        #endif
    }

    var body: some Scene {
        Window("Day", id: DayWindowID.main) {
            MainWindow(state: launch.state, login: launch.login)
                .calendarStore(launch.store)
                // A click on the desktop widget: `day://day/<date>` opens that day with the
                // pane showing. SwiftUI brings this window up first when it was closed.
                .onOpenURL { url in
                    guard let route = launch.store.route(for: url) else { return }
                    launch.state.goTo(route.day(in: launch.store))
                    launch.state.showsDayPane = true
                }
        }
        // The window is as large as its content allows: the first-run window is fixed at its
        // size, and the Month ranges from its minimum up.
        .windowResizability(.contentSize)
        .defaultSize(width: MainWindow.idealSize.width, height: MainWindow.idealSize.height)
        .commands {
            DayCommands(state: launch.state)
        }

        MenuBarExtra(isInserted: $showsMenuBarItem) {
            MenuBarPanel(state: launch.state)
                .calendarStore(launch.store)
        } label: {
            MenuBarLabelView()
                .calendarStore(launch.store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(state: launch.state, updater: launch.updater, login: launch.login)
                .calendarStore(launch.store)
        }
    }
}
