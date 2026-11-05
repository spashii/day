import BackgroundTasks
import DayCore
import UIKit

/// The background refresh: a bonus on top of the widget's own read on every timeline reload,
/// because the system runs `BGAppRefreshTask` when it likes and promises no schedule (it
/// learns from how often the app is opened, and runs none in Low Power Mode or after the app
/// is swiped away). Each run is the app's own incremental refresh, so the next launch opens
/// on current data and current tokens; it reloads the Lock Screen only when the snapshot
/// changed, and asks for the next run 15 minutes out.
///
/// The system ends a run without notice when its time is up, by cancelling the task, and ends
/// the app if the work goes on past that. So a run spends at most 20 seconds, with one try
/// per request (`AppModel.refreshInBackground`), and cancelling it stops every request at
/// once; the calendars that already answered are written and the next run starts from them.
///
/// `DayApp` attaches the task's handler to its scene (`.backgroundTask(.appRefresh)`), which
/// registers it while the app starts, as the system requires.
enum BackgroundRefresh {
    /// How soon the next run may begin. The system decides the real time; asking for less
    /// than it grants costs nothing, and an incremental refresh is cheap enough to take every
    /// run offered.
    static let interval: TimeInterval = 15 * 60

    /// Asks for the next run. Fails quietly where the system offers none, such as the
    /// simulator, and does nothing until an account is signed in.
    @MainActor
    static func schedule(for model: AppModel?) {
        guard let model, model.accounts.contains(where: { !$0.signedOut }) else { return }
        let request = BGAppRefreshTaskRequest(identifier: DayIdentifiers.refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The task body. The next run is requested first, so a run cut short still leaves one.
    /// It returns as soon as the refresh does, cancelled or not, because the system counts a
    /// body that outlives its time against the app.
    @MainActor
    static func perform() async {
        schedule(for: AppLaunch.shared.model)
        await AppLaunch.shared.model?.refreshInBackground()
    }
}

/// Keeps the app running for the few seconds the system grants after it leaves the front, so
/// the last fetch and the final widget reload can finish.
@MainActor
enum BackgroundTime {
    static func run(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let assertion = Assertion()
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            assertion.end()
        }
        Task {
            await work()
            assertion.end()
        }
    }

    /// Ending twice is an error, and the system's expiry can race the work's own end.
    @MainActor
    private final class Assertion {
        var identifier = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}
