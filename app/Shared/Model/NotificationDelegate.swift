import UserNotifications

/// The notification center's one delegate. The system keeps a single delegate per app, so
/// every kind of notification Day has goes through here and on to its owner.
///
/// - Day's reminders (`ReminderSchedule.identifierPrefix`) go to `ReminderResponder`, which
///   shows them while Day is in front and opens the event or the call.
/// - The relay's pushes are background pushes with no alert. They reach the app delegate
///   (`PushSync`), never this. Should one ever carry an alert, it gets the system's default
///   here: no banner while Day is in front, and a tap only opens Day. A push feature that
///   needs more adds its branch here rather than a second delegate, which would replace this
///   one and silence the reminders' Join.
///
/// `ReminderResponder.activate()` installs it at launch, from both app delegates.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if ReminderResponder.handles(notification.request) {
            return ReminderResponder.presentation(for: notification)
        }
        return []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        if ReminderResponder.handles(response.notification.request) {
            await ReminderResponder.respond(to: response)
        }
    }
}
