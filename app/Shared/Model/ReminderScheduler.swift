import DayCore
import Foundation
import Observation
import UserNotifications

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Keeps this device's pending notifications equal to `ReminderSchedule.plan` over its own
/// cache. Nothing leaves the device and no server is involved: every sync hands over the data
/// it just drew, and the pending requests are brought in line with it.
///
/// - Diffed, not rebuilt: a request is added when it is new or its signature changed, removed
///   when the plan dropped it, and left alone otherwise (`ReminderSchedule.changes`).
/// - The first time there is something to schedule, and Day is in front, the system's
///   permission question is asked. Never on first launch: with no account there is no plan.
/// - The per-device switch lives in this device's `UserDefaults` and nowhere else, so it is
///   not carried to another device by iCloud. Off removes everything pending.
/// - Passes never overlap: a sync that arrives while one runs is remembered, and the pass
///   that follows uses only the newest data.
@MainActor
@Observable
final class ReminderScheduler {
    static let shared = ReminderScheduler()

    /// Where the switch is kept. Plain `UserDefaults`, which does not sync.
    static let switchKey = "RemindersOn"

    /// What the system lets Day do, as far as the settings row cares.
    enum Permission: Hashable {
        /// Not read yet.
        case unknown
        /// The system has not been asked, or Day has nothing to schedule yet.
        case notAsked
        case allowed
        case denied
    }

    /// Remind on this device. On until the person turns it off.
    private(set) var isOn: Bool
    private(set) var permission: Permission = .unknown

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var input: Input?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var running = false

    private struct Input {
        let data: CalendarData
        let calendar: Calendar
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOn = defaults.object(forKey: Self.switchKey) as? Bool ?? true
    }

    // MARK: Called by the app

    /// A sync has drawn `data`: schedule from it. Cheap to call often; it returns at once.
    func update(_ data: CalendarData, calendar: Calendar) {
        input = Input(data: data, calendar: calendar)
        schedule()
    }

    /// The settings row. Turning off removes what is pending; turning on schedules from the
    /// data of the last sync.
    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: Self.switchKey)
        schedule()
    }

    /// Day came to the front, where the person may have just changed notifications in
    /// Settings: reads the permission again, so the line about notifications being off goes
    /// on its own, and schedules when it changed, so reminders allowed there are pending
    /// without waiting for the next sync.
    func becameActive() {
        Task {
            let before = permission
            await refreshPermission()
            if permission != before { schedule() }
        }
    }

    /// Reads what the system allows now, for the settings row. The person can change it in
    /// System Settings at any time.
    func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permission = Self.permission(from: settings.authorizationStatus)
    }

    // MARK: Passes

    private func schedule() {
        dirty = true
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        while dirty {
            dirty = false
            await reconcile()
        }
        running = false
    }

    private func reconcile() async {
        let center = UNUserNotificationCenter.current()
        ReminderResponder.shared.activate()

        guard isOn else {
            await removeAll(from: center)
            await refreshPermission()
            return
        }
        guard let input else { return }
        let planned = ReminderSchedule.plan(input.data, now: Date(), calendar: input.calendar)

        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            // Asked once, when there is a reminder to deliver and the person can see the
            // question. A sync in the background waits for the next time Day is in front.
            guard !planned.isEmpty, Self.isInFront else {
                permission = .notAsked
                return
            }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        permission = Self.permission(from: settings.authorizationStatus)
        guard permission == .allowed else { return }

        let pending = await center.pendingNotificationRequests().map {
            PendingReminder(
                identifier: $0.identifier,
                signature: $0.content.userInfo[ReminderPayload.signature] as? String)
        }
        let changes = ReminderSchedule.changes(planned: planned, pending: pending)
        if !changes.remove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: changes.remove)
        }
        for reminder in changes.add {
            try? await center.add(Self.request(for: reminder, calendar: input.calendar))
        }
    }

    private func removeAll(from center: UNUserNotificationCenter) async {
        let ours = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(ReminderSchedule.identifierPrefix) }
        if !ours.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
    }

    // MARK: Requests

    /// The request for one planned notification: a calendar trigger on the exact second, with
    /// the zone named, so it is the same instant whatever the device does with its clock
    /// settings meanwhile. A call's notifications carry the `Join` action.
    static func request(for reminder: PlannedReminder, calendar: Calendar) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.threadIdentifier = reminder.thread
        content.interruptionLevel = reminder.level == .timeSensitive ? .timeSensitive : .active
        var info: [String: String] = [
            ReminderPayload.signature: reminder.signature,
            ReminderPayload.link: reminder.link.absoluteString,
        ]
        if let join = reminder.joinURL {
            content.categoryIdentifier = ReminderResponder.joinCategory
            info[ReminderPayload.join] = join.absoluteString
        }
        if let email = reminder.accountEmail {
            info[ReminderPayload.email] = email
        }
        content.userInfo = info

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        var parts = gregorian.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
        parts.calendar = gregorian
        parts.timeZone = gregorian.timeZone
        return UNNotificationRequest(
            identifier: reminder.identifier, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    // MARK: System state

    private static func permission(from status: UNAuthorizationStatus) -> Permission {
        switch status {
        case .notDetermined: .notAsked
        case .denied: .denied
        default: .allowed
        }
    }

    private static var isInFront: Bool {
        #if os(iOS)
            UIApplication.shared.applicationState == .active
        #else
            NSApplication.shared.isActive
        #endif
    }
}

/// The keys of a request's `userInfo`: the signature the diff compares, and what answering the
/// notification needs. Not tied to the main actor, because the system calls the delegate off
/// it.
enum ReminderPayload {
    static let signature = "signature"
    static let link = "link"
    static let join = "join"
    static let email = "email"
}
