import SwiftUI

/// `Remind me on this Mac` / `Remind me on this iPhone`: whether this device schedules the
/// reminders from the person's Google events. On until turned off, kept on this device only,
/// and turning it off removes what is pending.
///
/// A form section, so each platform places it where its settings are: the Mac's General tab
/// and, on the iPhone, the Calendars sheet, which is its only settings screen. The line under
/// the switch is the footer; a second line appears only while the system has notifications
/// for Day turned off.
struct ReminderSettingsSection: View {
    private let scheduler = ReminderScheduler.shared

    var body: some View {
        Section {
            Toggle(
                title,
                isOn: Binding(get: { scheduler.isOn }, set: { scheduler.setOn($0) }))
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.cell) {
                Text("Uses the reminders on your Google events.")
                if scheduler.isOn, scheduler.permission == .denied {
                    // Placeholder wording, owned by the copy thread.
                    Text(verbatim: "Notifications for Day are turned off in System Settings.")
                }
            }
        }
        .task { await scheduler.refreshPermission() }
    }

    private var title: LocalizedStringKey {
        #if os(macOS)
            "Remind me on this Mac"
        #else
            "Remind me on this iPhone"
        #endif
    }
}

#Preview("Reminders") {
    Form { ReminderSettingsSection() }
        .formStyle(.grouped)
        .frame(width: 420)
}
