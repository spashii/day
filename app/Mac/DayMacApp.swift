import DayCore
import SwiftUI

/// Day for the Mac: one window with the Month and the selected day beside it, a menu bar item
/// with today in a panel, and Settings. A regular app with a Dock icon; closing the window
/// leaves it running in the menu bar and Command-Q quits.
@main
struct DayMacApp: App {
    @NSApplicationDelegateAdaptor(DayAppDelegate.self) private var delegate
    private let launch = MacLaunch.shared

    var body: some Scene {
        Window("Day", id: DayWindowID.main) {
            MainWindow(state: launch.state, login: launch.login)
                .calendarStore(launch.store)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            DayCommands(state: launch.state)
        }

        MenuBarExtra {
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
