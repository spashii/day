import DayCore
import Foundation
import Synchronization

/// Stage two: the widget fetches for itself.
///
/// On a reload, when the snapshot is 15 minutes old or older, the extension fetches today
/// through eight days ahead for every visible calendar with `SyncEngine`, writes the
/// snapshot back (the newer `fetchedAt` wins against the app's own write) and builds the
/// timeline from it. On any failure, or after 5 seconds, the old snapshot is what renders.
/// The widget never writes the app's per-account event files.
///
/// It is off. `isEnabled` stays false until stage one has run on the device, because this is
/// the one part that cannot be proven away from it: a Google client inside a WidgetKit
/// extension, tokens read from a locked phone, two writers of one file, and a deadline that
/// is a guess. Stage one (the app writes, the widget reads) is complete without it.
enum WidgetFetch {
    /// The flag. One line turns stage two on.
    static let isEnabled = false

    /// How long a reload may spend on the network, keychain and file work together. Apple
    /// publishes no limit for `getTimeline`, so this is a guess to validate with logging on
    /// the device.
    static let deadline: Duration = .seconds(5)

    /// The engine's own cutoff, shorter than `deadline`, so a fetch that runs long ends
    /// cleanly and keeps the snapshot on disk before the outer cutoff has to give up.
    static let engineDeadline: Duration = .milliseconds(4500)

    /// The snapshot to render after trying a refresh, or nil when the one on disk should
    /// render as it is: no client, no account, the fetch failed or ran out of time. A fresh
    /// snapshot (under 15 minutes) comes back without a fetch.
    static func refresh() async -> WidgetSnapshot? {
        await Deadline.run(within: deadline) {
            guard let auth = GoogleAuth(), let cache = try? CacheDirectory.shared() else {
                return nil
            }
            let engine = SyncEngine(auth: auth, tokens: KeychainTokenStore(), cache: cache)
            return await engine.refreshWidgetSnapshot(
                maxAge: WidgetSnapshot.freshFor, deadline: engineDeadline)
        }
    }
}

/// Runs `operation` and gives up after `limit`, returning nil. Unlike a task group it does
/// not wait for the operation to notice it was cancelled, so a hung keychain read or network
/// call cannot hold the reload past the deadline.
enum Deadline {
    static func run<T: Sendable>(
        within limit: Duration, _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let race = Race()
            let work = Task {
                let value = await operation()
                if race.claim() { continuation.resume(returning: value) }
                race.cancelTimer()
            }
            race.setTimer(
                Task {
                    guard (try? await Task.sleep(for: limit)) != nil else { return }
                    if race.claim() { continuation.resume(returning: nil) }
                    work.cancel()
                })
        }
    }

    /// Lets exactly one of the two tasks resume the continuation.
    private final class Race: Sendable {
        private let claimed = Mutex(false)
        private let timer = Mutex<Task<Void, Never>?>(nil)

        func claim() -> Bool {
            claimed.withLock { done in
                if done { return false }
                done = true
                return true
            }
        }

        func setTimer(_ task: Task<Void, Never>) {
            timer.withLock { $0 = task }
        }

        func cancelTimer() {
            timer.withLock { $0?.cancel() }
        }
    }
}
