import DayCore
import SwiftUI

/// The Settings window, two tabs and nothing else. Accounts is the same list as first run and
/// the iPhone Calendars sheet, so calendar visibility lives here and not on screen every day.
/// General has `Open at login`, the reminders switch and the update controls.
struct SettingsView: View {
    @Bindable var state: MacState
    let updater: Updater
    let login: OpenAtLogin

    var body: some View {
        TabView(selection: $state.settingsTab) {
            Tab("Accounts", systemImage: "person.crop.circle", value: MacState.SettingsTab.accounts) {
                AccountsView()
                    .frame(width: 520, height: 480)
            }
            Tab("General", systemImage: "gearshape", value: MacState.SettingsTab.general) {
                // Each tab is as tall as its content, and the window follows when the tab changes.
                GeneralSettings(updater: updater, login: login)
                    .frame(width: 520, height: 300)
            }
        }
    }
}

/// `Open at login`, `Remind me on this Mac`, `Check for updates automatically` and
/// `Check for Updates…`.
struct GeneralSettings: View {
    @Bindable var updater: Updater
    let login: OpenAtLogin

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Open at login",
                    isOn: Binding(get: { login.isOn }, set: { login.set($0) })
                )
            } footer: {
                if let failure = login.failure {
                    Text(verbatim: failure)
                }
            }
            ReminderSettingsSection()
            Section {
                Toggle("Check for updates automatically", isOn: $updater.automatic)
                Button("Check for Updates…") { updater.check() }
                    .disabled(!updater.canCheck)
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }
}

#Preview("Settings") {
    let store = PreviewStore.make()
    SettingsView(state: MacState(store: store), updater: Updater(start: false), login: OpenAtLogin())
        .calendarStore(store)
}
