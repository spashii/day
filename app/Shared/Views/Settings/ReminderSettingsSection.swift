import DayCore
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// `Remind me on this Mac` / `Remind me on this iPhone`: whether this device schedules the
/// reminders from the person's Google events. On until turned off, kept on this device only,
/// and turning it off removes what is pending.
///
/// A form section, so each platform places it where its settings are: the Mac's General tab
/// and, on the iPhone, the Calendars sheet, which is its only settings screen. The line under
/// the switch is the footer.
///
/// When the person was asked and said no, or later turned Day's notifications off, the switch
/// keeps its value and is greyed out, and a line with a button to the system's settings shows
/// under it. Day reads the permission again each time it comes to the front
/// (`ReminderScheduler.becameActive`), so the line goes on its own once notifications are back.
struct ReminderSettingsSection: View {
    private let scheduler = ReminderScheduler.shared

    var body: some View {
        let denied = scheduler.permission == .denied
        Section {
            Toggle(
                title,
                isOn: Binding(get: { scheduler.isOn }, set: { scheduler.setOn($0) }))
                .disabled(denied)
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.cell) {
                Text("Uses the reminders on your Google events.")
                if denied {
                    Text(deniedLine)
                    Button(openSettingsTitle) { Self.openNotificationSettings() }
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

    private var deniedLine: LocalizedStringKey {
        #if os(macOS)
            "Notifications for Day are off in System Settings."
        #else
            "Notifications for Day are off in Settings."
        #endif
    }

    private var openSettingsTitle: LocalizedStringKey {
        #if os(macOS)
            "Open System Settings"
        #else
            "Open Settings"
        #endif
    }

    /// Day's own entry in the system's notification settings. On the Mac the Notifications
    /// pane takes the bundle identifier and opens on Day; if that address is ever refused,
    /// the pane itself opens and Day is one click away.
    private static func openNotificationSettings() {
        #if os(macOS)
            let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            let id = Bundle.main.bundleIdentifier ?? DayIdentifiers.bundleID
            if let app = URL(string: "\(pane)?id=\(id)"), NSWorkspace.shared.open(app) { return }
            if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
        #else
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                UIApplication.shared.open(url)
            }
        #endif
    }
}

#Preview("Reminders") {
    Form { ReminderSettingsSection() }
        .formStyle(.grouped)
        .frame(width: 420)
}
