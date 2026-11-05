import DayCore
import Foundation
import UserNotifications

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// What happens when a reminder arrives and when it is answered.
///
/// - Shown even while Day is in front, as Google Calendar's own reminders are.
/// - `Join` opens the event's meeting link the way the sheet's Join does: a universal link on
///   the iPhone so Meet, Zoom and Teams open their apps, the default browser on the Mac with
///   the account added to Google links. On the iPhone the action opens Day first, because the
///   system only lets an app open another app from the front; on the Mac it does not bring
///   Day forward.
/// - Tapping the notification opens the event, through the same `day://event/...` link the
///   widgets use.
///
/// The notification center has one delegate. Call `activate()` once at launch (the app
/// delegate's `didFinishLaunching`), so an answer to a notification that started Day is
/// delivered; until then the first sync activates it.
@MainActor
final class ReminderResponder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderResponder()

    /// The category of a call's notifications, which has the `Join` action.
    static let joinCategory = "io.github.spashii.day.reminder.join"
    static let joinAction = "io.github.spashii.day.reminder.join.action"

    private var activated = false

    func activate() {
        let center = UNUserNotificationCenter.current()
        if center.delegate !== self {
            center.delegate = self
        }
        guard !activated else { return }
        activated = true
        Task {
            // Other categories (a future push one) are kept.
            var categories = await center.notificationCategories()
            categories = categories.filter { $0.identifier != Self.joinCategory }
            categories.insert(Self.category)
            center.setNotificationCategories(categories)
        }
    }

    private static var category: UNNotificationCategory {
        #if os(iOS)
            let options: UNNotificationActionOptions = [.foreground]
        #else
            let options: UNNotificationActionOptions = []
        #endif
        let join = UNNotificationAction(
            identifier: joinAction, title: ReminderText.join, options: options)
        return UNNotificationCategory(
            identifier: joinCategory, actions: [join], intentIdentifiers: [], options: [])
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let link = (info[ReminderPayload.link] as? String).flatMap(URL.init(string:))
        let join = (info[ReminderPayload.join] as? String).flatMap(URL.init(string:))
        let email = info[ReminderPayload.email] as? String
        await MainActor.run {
            Self.open(action: action, link: link, join: join, email: email)
        }
    }

    private static func open(action: String, link: URL?, join: URL?, email: String?) {
        switch action {
        case joinAction:
            guard let join else { return }
            // The handoff only reads the address, to add it to Google links on the Mac.
            let account = email.map {
                Account(id: AccountID(sub: ""), email: $0, addedAt: .distantPast)
            }
            let handoff = HandoffAction.system
            handoff(join, account: account)
        case UNNotificationDefaultActionIdentifier:
            guard let link else { return }
            #if os(iOS)
                UIApplication.shared.open(link)
            #else
                NSWorkspace.shared.open(link)
            #endif
        default:
            break
        }
    }
}
