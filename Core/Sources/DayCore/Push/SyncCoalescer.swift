import Foundation
import Synchronization

/// Folds a burst of sync requests into as few syncs as still answer every one of them.
///
/// A request made while no sync runs starts one. A request made while one runs cannot be
/// answered by it, since that sync may have read Google before the change the request is
/// about, so it waits for exactly one more sync after the running one; every request made
/// during the same run shares that one. Ten pushes during a sync cost two syncs, not eleven.
///
/// Each caller returns when a sync that started after its request has finished.
public actor SyncCoalescer {
    private let operation: @Sendable () async -> Void
    /// Requests made so far, and the count the last finished sync answered.
    private var requested = 0
    private var answered = 0
    private var running = false
    private var waiters: [(upTo: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init(_ operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    /// Requests made so far, for tests that need a burst to have landed.
    var requestCount: Int {
        requested
    }

    public func request() async {
        requested += 1
        let mine = requested
        if !running {
            running = true
            Task { await self.drain() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append((mine, continuation))
        }
    }

    /// Runs syncs until every request made so far is answered. A sync answers the requests
    /// made before it started, so the count is taken before it runs.
    private func drain() async {
        while answered < requested {
            let covers = requested
            await operation()
            answered = covers
            let ready = waiters.filter { $0.upTo <= covers }
            waiters.removeAll { $0.upTo <= covers }
            for waiter in ready { waiter.continuation.resume() }
        }
        running = false
    }
}

/// Waiting with a limit, for work the system gives a fixed time.
public enum PushTiming {
    /// Runs `operation` and returns its value, or nil once `limit` has passed. The operation
    /// is not cancelled: what it writes is still written, and only the caller stops waiting,
    /// which is what a background push must do before its time is up.
    public static func wait<T: Sendable>(
        upTo limit: Duration, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            let timer = Task {
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                if once.claim() { continuation.resume(returning: nil) }
            }
            Task {
                let value = await operation()
                if once.claim() { continuation.resume(returning: value) }
                timer.cancel()
            }
        }
    }

    private final class Once: Sendable {
        private let claimed = Mutex(false)

        func claim() -> Bool {
            claimed.withLock { done in
                defer { done = true }
                return !done
            }
        }
    }
}
