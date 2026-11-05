import Foundation
import Synchronization
import Testing

@testable import DayCore

/// A refresh the system cuts short. The background task is ended by cancelling its task, and
/// the app is ended if the work goes on: so cancelling a refresh must stop every request and
/// return, however slow Google is, and what had already answered must be kept.
struct SyncCancellationTests {
    typealias Harness = SyncTests.Harness
    typealias Script = SyncTests.Script

    /// Answers like the recorded stub until told to hang on some requests, which then never
    /// answer: they end only when their task is cancelled, as a request on a bad network does.
    final class Hanging: HTTPTransport {
        private let inner: DecodingTests.Stub
        private let hangs = Mutex<(@Sendable (URLRequest) -> Bool)?>(nil)
        private let waiting = Mutex(0)

        init(_ inner: DecodingTests.Stub) {
            self.inner = inner
        }

        func hang(on matches: @escaping @Sendable (URLRequest) -> Bool) {
            hangs.withLock { $0 = matches }
        }

        func release() {
            hangs.withLock { $0 = nil }
        }

        var waitingCount: Int {
            waiting.withLock { $0 }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if let matches = hangs.withLock({ $0 }), matches(request) {
                waiting.withLock { $0 += 1 }
                defer { waiting.withLock { $0 -= 1 } }
                try await Task.sleep(for: .seconds(600))
            }
            return try await inner.send(request)
        }
    }

    static func harness() throws -> (Harness, Hanging) {
        var hanging: Hanging?
        let h = try Harness(wrapping: { stub in
            let transport = Hanging(stub)
            hanging = transport
            return transport
        })
        return (h, try #require(hanging))
    }

    /// Waits for `condition`, up to ten seconds.
    static func until(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition never held")
    }

    /// A task's value, or nil if it has not finished within `limit`. A refresh that ignores
    /// cancellation would otherwise hang the test instead of failing it.
    static func value<Value: Sendable>(
        of task: Task<Value, Never>, within limit: Duration = .seconds(10)
    ) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let claimed = Mutex(false)
            let finish: @Sendable (Value?) -> Void = { value in
                let first = claimed.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: value) }
            }
            Task { finish(await task.value) }
            Task {
                try? await Task.sleep(for: limit)
                finish(nil)
            }
        }
    }

    static func isFamily(_ request: URLRequest) -> Bool {
        request.url?.path(percentEncoded: false).contains("/family7k") == true
    }

    // MARK: Cancelling the caller

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheCallerStopsEveryRequestAndKeepsWhatAnswered() async throws {
        let (h, hanging) = try SyncCancellationTests.harness()
        h.scriptInitialSync()
        let first = await h.engine.refresh()
        let tokens = try h.stored().sync
        h.advance(180)
        h.google.answer("list:l1", #"{"items": [], "nextSyncToken": "l2"}"#)
        h.google.answer("you@gmail.com:s1", Script.personalInsertAndUpdate1)
        h.google.answer("you@gmail.com:s1+q2", Script.personalInsertAndUpdate2)
        h.google.answer("club3m@group.calendar.google.com:c1", #"{"items": [], "nextSyncToken": "c2"}"#)
        hanging.hang(on: SyncCancellationTests.isFamily)

        let started = ContinuousClock.now
        let task = Task { await h.engine.refresh() }
        try await SyncCancellationTests.until { hanging.waitingCount > 0 }
        task.cancel()
        let ended = await SyncCancellationTests.value(of: task)
        let report = try #require(ended, "the cancelled refresh did not end")
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(hanging.waitingCount == 0)

        // Google was not reached for Family, so the screen says so; nothing else is claimed.
        #expect(report.outcome == .unreachable)
        #expect(report.data.lastFetchedAt == first.data.lastFetchedAt)
        // Personal and Club had answered and are kept, with their new tokens.
        #expect(try h.event("lunch04") != nil)
        let stored = try h.stored()
        #expect(stored.state(of: SyncTests.personal)?.token == "s2")
        #expect(stored.state(of: SyncTests.club)?.token == "c2")
        // Family keeps what it had, and its token.
        #expect(stored.state(of: SyncTests.family) == tokens.first { $0.calendar == SyncTests.family })

        // The next refresh is not held up behind the cancelled one.
        hanging.release()
        h.advance(180)
        h.google.answer("list:l2", #"{"items": [], "nextSyncToken": "l3"}"#)
        h.google.answer("you@gmail.com:s2", #"{"items": [], "nextSyncToken": "s3"}"#)
        h.google.answer("family7k@group.calendar.google.com:f1", #"{"items": [], "nextSyncToken": "f2"}"#)
        h.google.answer("club3m@group.calendar.google.com:c2", #"{"items": [], "nextSyncToken": "c3"}"#)
        let again = await h.engine.refresh()
        #expect(again.outcome == .current)
        #expect(again.data.lastFetchedAt == h.clock.value)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheCallerEndsAnAccessTokenRefreshToo() async throws {
        let (h, hanging) = try SyncCancellationTests.harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        let tokens = try h.stored().sync
        // The access token has run out, so the refresh starts with a call to the token
        // endpoint, and that never answers.
        h.advance(2 * 3600)
        hanging.hang { $0.url?.host() == "oauth2.googleapis.com" }

        let started = ContinuousClock.now
        let task = Task { await h.engine.refresh() }
        try await SyncCancellationTests.until { hanging.waitingCount > 0 }
        task.cancel()
        let ended = await SyncCancellationTests.value(of: task)
        let report = try #require(ended, "the cancelled refresh did not end")
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(report.outcome == .unreachable)
        #expect(try h.stored().sync == tokens)
        // Being cancelled is not being signed out.
        #expect(report.data.accounts.first?.signedOut == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallerThatJoinedStopsWaitingWhenCancelledAndLeavesTheRunToItsStarter() async throws {
        let (h, hanging) = try SyncCancellationTests.harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(180)
        h.scriptQuiet(list: "l1", personal: "s1", family: "f1", club: "c1")
        hanging.hang(on: SyncCancellationTests.isFamily)

        let finished = Mutex(false)
        let starter = Task {
            let report = await h.engine.refresh()
            finished.withLock { $0 = true }
            return report
        }
        try await SyncCancellationTests.until { hanging.waitingCount > 0 }
        let joiner = Task { await h.engine.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        joiner.cancel()
        let ended = await SyncCancellationTests.value(of: joiner)
        let joined = try #require(ended, "the cancelled joiner kept waiting")
        #expect(joined.outcome == .unreachable)
        // The run it joined is still going.
        #expect(!finished.withLock { $0 })
        #expect(hanging.waitingCount > 0)

        starter.cancel()
        let done = await SyncCancellationTests.value(of: starter)
        #expect(done != nil)
        #expect(finished.withLock { $0 })
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallerThatJoinedACancelledRunStartsItsOwn() async throws {
        let (h, hanging) = try SyncCancellationTests.harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(180)
        h.scriptQuiet(list: "l1", personal: "s1", family: "f1", club: "c1")
        // The first run never gets its calendar list, so it has changed nothing.
        hanging.hang { $0.url?.path(percentEncoded: false).hasSuffix("/users/me/calendarList") == true }

        let starter = Task { await h.engine.refresh() }
        try await SyncCancellationTests.until { hanging.waitingCount > 0 }
        let joiner = Task { await h.engine.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        // Google answers again, and the starter is cancelled (the background task's time ran out).
        hanging.release()
        starter.cancel()
        let cut = await SyncCancellationTests.value(of: starter)
        #expect(cut?.outcome == .unreachable)

        let ended = await SyncCancellationTests.value(of: joiner)
        let report = try #require(ended, "the joiner did not get a refresh of its own")
        #expect(report.outcome == .current)
        #expect(report.data.lastFetchedAt == h.clock.value)
        #expect(try h.stored().state(of: SyncTests.personal)?.token == "s1+")
    }

    // MARK: The background budget

    @Test(.timeLimit(.minutes(1)))
    func theBackgroundRefreshEndsAtItsBudgetWithOneTryPerRequest() async throws {
        let (h, hanging) = try SyncCancellationTests.harness()
        h.scriptInitialSync()
        let first = await h.engine.refresh()
        h.advance(180)
        h.scriptQuiet(list: "l1", personal: "s1", family: "f1", club: "c1")
        hanging.hang(on: SyncCancellationTests.isFamily)

        let started = ContinuousClock.now
        let report = await h.engine.refreshInBackground(within: .milliseconds(300))
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(250))
        #expect(elapsed < .seconds(10))
        #expect(report.outcome == .unreachable)
        #expect(hanging.waitingCount == 0)
        #expect(report.data.lastFetchedAt == first.data.lastFetchedAt)
        // Personal answered in time and moved on.
        #expect(try h.stored().state(of: SyncTests.personal)?.token == "s1+")
    }

    @Test func theBackgroundRefreshTriesEachRequestOnce() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        func familyReads(after count: Int) -> Int {
            h.keys(from: count).filter { $0.hasPrefix("family7k") }.count
        }

        h.advance(180)
        h.scriptQuiet(list: "l1", personal: "s1", family: "f1", club: "c1")
        h.google.answer("family7k@group.calendar.google.com:f1", "", status: 503)
        var before = h.stub.requests.count
        let background = await h.engine.refreshInBackground()
        #expect(background.outcome == .unreachable)
        #expect(familyReads(after: before) == 1)

        // In the front the app backs off and tries again, three times in the tests.
        h.advance(180)
        h.scriptQuiet(list: "l1+", personal: "s1+", family: "f1", club: "c1+")
        h.google.answer("family7k@group.calendar.google.com:f1", "", status: 503)
        before = h.stub.requests.count
        let foreground = await h.engine.refresh()
        #expect(foreground.outcome == .unreachable)
        #expect(familyReads(after: before) == 3)
    }
}
