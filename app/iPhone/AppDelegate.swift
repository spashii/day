import DayCore
import UIKit

/// The iPhone's push entry points, attached to `DayApp` with `UIApplicationDelegateAdaptor`.
/// A background push can launch the app with no scene in front, so the token is asked for
/// here at launch rather than when a view appears. `PushSync` does the work.
@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushSync.shared.start(model: AppLaunch.shared.model)
        return true
    }

    func application(
        _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushSync.shared.didRegister(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        PushSync.shared.didFailToRegister(error)
    }

    /// `content-available` from the relay: sync, then say whether anything changed, which
    /// the system weighs when it rations the next ones.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        switch await PushSync.shared.pushArrived() {
        case .newData: .newData
        case .noData: .noData
        case .failed: .failed
        }
    }
}
