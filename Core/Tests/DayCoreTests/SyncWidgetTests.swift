import Foundation
import Testing

@testable import DayCore

/// What the widget reads and what it must not conclude: the app's near file instead of the
/// whole cache, and no sign-out invented from a keychain item it cannot find.
struct SyncWidgetTests {
    typealias Harness = SyncTests.Harness
    typealias Script = SyncTests.Script

    /// The widget's own answers for a quiet 20 minutes.
    static func scriptQuietWidget(_ h: Harness) {
        h.google.answer("you@gmail.com:s1", #"{"items": [], "nextSyncToken": "s2"}"#)
        h.google.answer("family7k@group.calendar.google.com:f1", #"{"items": [], "nextSyncToken": "f2"}"#)
        h.google.answer("club3m@group.calendar.google.com:c1", #"{"items": [], "nextSyncToken": "c2"}"#)
    }

    // MARK: The near file

    @Test func theAppWritesTheNearFileWithOnlyTheDaysTheWidgetNeeds() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        // The Month reads April, which the full cache keeps and the near file must not.
        h.google.answer("you@gmail.com:2027-03-11T23:00:00Z", Script.personalApril)
        h.google.answer("family7k@group.calendar.google.com:2027-03-11T23:00:00Z", #"{"items": []}"#)
        h.google.answer("club3m@group.calendar.google.com:2027-03-11T23:00:00Z", #"{"items": []}"#)
        let april = CivilDate(year: 2027, month: 4, day: 1)...CivilDate(year: 2027, month: 4, day: 30)
        _ = await h.engine.extendWindow(toInclude: april)

        let stored = try h.stored()
        #expect(stored.events.contains { $0.id.googleID == "trip0410" })
        let near = try #require(h.cache.near(SyncTests.account))
        // Yesterday through ten days ahead of Wednesday 4 November.
        #expect(near.days == CivilDate(year: 2026, month: 11, day: 3)...CivilDate(year: 2026, month: 11, day: 14))
        #expect(near.events.contains { $0.id.googleID == "dentist07" })
        #expect(!near.events.contains { $0.id.googleID == "trip0410" })
        #expect(near.events.count < stored.events.count)
        // The tokens are the ones that go with those events.
        #expect(near.sync == stored.sync)
        #expect(near.fetchedAt == stored.fetchedAt)
    }

    @Test func theWidgetBuildsItsSnapshotFromTheNearFile() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        // Emptied, the whole cache would give the widget nothing; the near file still has
        // the week.
        try h.cache.write(EventsFile(events: []), to: CacheFile.events(SyncTests.account))
        h.advance(20 * 60)
        SyncWidgetTests.scriptQuietWidget(h)
        let snapshot = try #require(await h.engine.refreshWidgetSnapshot())
        #expect(h.google.misses.isEmpty)
        #expect(snapshot.events.contains { $0.title == "Standup" })
        #expect(snapshot.events.contains { $0.title == "Dinner with Maya" })
        #expect(snapshot.fetchedAt == h.clock.value)
    }

    @Test func theWidgetReadsTheWholeCacheWhenThereIsNoNearFile() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.cache.remove(CacheFile.near(SyncTests.account))
        h.advance(20 * 60)
        SyncWidgetTests.scriptQuietWidget(h)
        let snapshot = try #require(await h.engine.refreshWidgetSnapshot())
        #expect(h.google.misses.isEmpty)
        #expect(snapshot.events.contains { $0.title == "Standup" })
    }

    @Test func theWidgetReadsTheWholeCacheWhenTheNearFileIsForOtherDays() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        let stored = try h.stored()
        // A near file from a month ago: it holds nothing the widget needs.
        let old = CivilDate(year: 2026, month: 10, day: 1)...CivilDate(year: 2026, month: 10, day: 12)
        try h.cache.write(
            NearFile(days: old, fetchedAt: stored.fetchedAt, events: [], sync: stored.sync),
            to: CacheFile.near(SyncTests.account))
        h.advance(20 * 60)
        SyncWidgetTests.scriptQuietWidget(h)
        let snapshot = try #require(await h.engine.refreshWidgetSnapshot())
        #expect(snapshot.events.contains { $0.title == "Standup" })
    }

    @Test func removingAnAccountRemovesItsNearFile() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        #expect(h.cache.near(SyncTests.account) != nil)
        try await h.engine.removeAccount(SyncTests.account)
        #expect(h.cache.near(SyncTests.account) == nil)
    }

    // MARK: Sign-out is the app's to decide

    @Test func aTokenTheWidgetCannotFindDoesNotSignTheAccountOut() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        let app = try #require(await h.engine.refresh().snapshot)
        // The extension finds no keychain item, as it does when it cannot see the app's.
        try h.tokens.removeToken(for: SyncTests.account)
        h.advance(20 * 60)
        let before = h.stub.requests.count
        let snapshot = await h.engine.refreshWidgetSnapshot()
        #expect(snapshot == app)
        #expect(snapshot?.signedOutAccounts == 0)
        #expect(WidgetSnapshot.read(from: h.cache) == app)
        #expect(h.stub.requests.count == before)
        #expect(h.cache.read([Account].self, from: CacheFile.accounts)?.first?.signedOut == false)
    }

    @Test func oneAccountWithoutAnItemIsLeftAloneAndTheOtherIsStillRead() async throws {
        let h = try DecodingTests.Sync.Harness()
        _ = await h.engine.refresh()
        try h.tokens.removeToken(for: DecodingTests.acme)
        h.advance(3600)
        let before = h.stub.requests.count
        let snapshot = try #require(await h.engine.refreshWidgetSnapshot())
        #expect(snapshot.signedOutAccounts == 0)
        #expect(snapshot.accountCount == 2)
        #expect(snapshot.events.contains { $0.title == "Standup" })
        let added = h.stub.requests[before...]
        #expect(added.contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-gmail" })
        #expect(!added.contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-acme" })
        let accounts = try #require(h.cache.read([Account].self, from: CacheFile.accounts))
        #expect(accounts.allSatisfy { !$0.signedOut })
    }
}
