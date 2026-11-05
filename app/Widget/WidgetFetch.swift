import DayCore
import Foundation
import Synchronization

/// Stage two: the widget reads Google itself, on every timeline reload.
///
/// Each reload runs `SyncEngine.refreshWidgetSnapshot`: for every visible calendar, the
/// changes since the app's sync token (or today through eight days ahead by window, when the
/// token cannot serve those days), laid over the app's cached events in memory, then the
/// snapshot written back with the newer `fetchedAt` winning. On any failure, or after
/// `deadline`, the snapshot on disk is what renders. The widget never writes the app's event
/// or sync files; the app reads the same changes again on its next refresh.
///
/// Tokens come from the shared keychain at After First Unlock and the files from the App
/// Group at the matching file protection, so a locked phone refreshes too. A snapshot under
/// a minute old renders without reading Google: that is the reload the app asks for right
/// after writing one.
///
/// The events and tokens come from the app's near file (a few days of events per account),
/// not the five-month cache, so the work inside the deadline and the extension's memory
/// ceiling stays small however long the app has run. The cost on a real phone is still to be
/// measured; see `docs/SYNC.md`.
enum WidgetFetch {
    /// One line turns stage two off again, leaving the widget on what the app writes.
    static let isEnabled = true

    /// How long a reload may spend on the network, keychain and file work together. Apple
    /// publishes no limit for `getTimeline`; five seconds has room for a token refresh and
    /// one call per calendar, which run in parallel.
    static let deadline: Duration = .seconds(5)

    /// The engine's own cutoff, shorter than `deadline`, so a read that runs long ends
    /// cleanly and keeps the snapshot on disk before the outer cutoff has to give up.
    static let engineDeadline: Duration = .milliseconds(4500)

    /// The snapshot to render after trying a refresh, or nil when the one on disk should
    /// render as it is: no client, no account, the read failed or ran out of time.
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
