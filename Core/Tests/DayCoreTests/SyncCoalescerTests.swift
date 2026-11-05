import Foundation
import Testing

@testable import DayCore

/// Bursts of pushes fold into as few syncs as still answer each one (`SyncCoalescer`).
struct SyncCoalescerTests {
    /// A sync the test holds open until it lets it finish.
    actor Syncs {
        private(set) var started = 0
        private var held: [CheckedContinuation<Void, Never>] = []

        func run() async {
            started += 1
            await withCheckedContinuation { held.append($0) }
        }

        func finishOne() {
            guard !held.isEmpty else { return }
            held.removeFirst().resume()
        }

        var running: Int { held.count }

        /// Whether the `run`th sync has started and is the one held now.
        func isRunning(run: Int) -> Bool {
            started == run && held.count == 1
        }
    }

    /// Waits until `condition` holds, for at most two seconds.
    static func until(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<2000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("condition never held")
    }

    @Test func aBurstDuringASyncCostsOneMoreSync() async throws {
        let syncs = Syncs()
        let coalescer = SyncCoalescer { await syncs.run() }
        let first = Task { await coalescer.request() }
        try await Self.until { await syncs.running == 1 }

        let burst = (0..<10).map { _ in Task { await coalescer.request() } }
        try await Self.until { await coalescer.requestCount == 11 }
        await syncs.finishOne()
        await first.value

        // The burst came while the first sync ran, so it gets exactly one sync of its own.
        try await Self.until { await syncs.running == 1 }
        #expect(await syncs.started == 2)
        await syncs.finishOne()
        for request in burst { await request.value }
        #expect(await syncs.started == 2)
    }

    @Test func requestsAfterASyncEachGetTheirOwn() async throws {
        let syncs = Syncs()
        let coalescer = SyncCoalescer { await syncs.run() }
        for round in 1...3 {
            let request = Task { await coalescer.request() }
            try await Self.until { await syncs.running == 1 }
            await syncs.finishOne()
            await request.value
            #expect(await syncs.started == round)
        }
    }

    @Test func aRequestDuringTheTrailingSyncGetsAnotherAfterIt() async throws {
        let syncs = Syncs()
        let coalescer = SyncCoalescer { await syncs.run() }
        let first = Task { await coalescer.request() }
        try await Self.until { await syncs.running == 1 }
        let second = Task { await coalescer.request() }
        try await Self.until { await coalescer.requestCount == 2 }
        await syncs.finishOne()
        await first.value

        // The trailing sync runs; a push now cannot be answered by it either.
        try await Self.until { await syncs.isRunning(run: 2) }
        let third = Task { await coalescer.request() }
        try await Self.until { await coalescer.requestCount == 3 }
        await syncs.finishOne()
        await second.value
        try await Self.until { await syncs.isRunning(run: 3) }
        await syncs.finishOne()
        await third.value
        #expect(await syncs.started == 3)
    }

    @Test func waitingWithALimitGivesUpWithoutStoppingTheWork() async throws {
        let syncs = Syncs()
        let finished = await PushTiming.wait(upTo: .milliseconds(50)) { await syncs.run() }
        #expect(finished == nil)
        #expect(await syncs.running == 1)
        await syncs.finishOne()
        let quick = await PushTiming.wait(upTo: .seconds(5)) { 42 }
        #expect(quick == 42)
    }
}
