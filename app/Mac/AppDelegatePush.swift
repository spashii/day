import AppKit
import DayCore

/// The Mac's push entry points, on the app delegate `DayMacApp` already attaches with
/// `NSApplicationDelegateAdaptor`. Day runs in the menu bar, so a background push reaches it
/// at once; a Mac that is asleep gets the latest one when it wakes. `PushSync` does the work.
///
/// Named explicitly for the Objective-C runtime, since AppKit finds these by selector and
/// the conformance is declared in another file.
extension DayAppDelegate {
    @objc(application:didRegisterForRemoteNotificationsWithDeviceToken:)
    func application(
        _ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushSync.shared.didRegister(deviceToken: deviceToken)
    }

    @objc(application:didFailToRegisterForRemoteNotificationsWithError:)
    func application(
        _ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        PushSync.shared.didFailToRegister(error)
    }

    @objc(application:didReceiveRemoteNotification:)
    func application(
        _ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        Task { _ = await PushSync.shared.pushArrived() }
    }
}
