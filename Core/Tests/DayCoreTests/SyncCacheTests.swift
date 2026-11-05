import Foundation
import Testing

@testable import DayCore

/// The two cache files and the order they are read in.
struct SyncCacheTests {
    /// The app writes an account's events, then its sync file. A reader in another process
    /// that lands between the two must get events at least as new as the tokens, or it would
    /// read no changes on top of old events and write a snapshot without them.
    @Test func aReaderBetweenTheAppsTwoWritesGetsEventsNoOlderThanTheTokens() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "day-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = CacheDirectory(url: folder)
        let id = AccountID("100000000000000000001")
        let calendarID = CalendarID(account: id, googleID: "you@gmail.com")
        var template = try #require(try DecodingTests.fixture().events.first)
        let at = Date(timeIntervalSince1970: 1_793_797_000)
        let days = CivilDate(year: 2026, month: 11, day: 3)...CivilDate(year: 2026, month: 11, day: 14)

        func account(_ n: Int) -> AccountCache {
            template.title = "g\(n)"
            return AccountCache(
                fetchedAt: at,
                events: [template],
                sync: [
                    CalendarSync(
                        calendar: calendarID, token: "t\(n)", tokenFrom: at, tokenTo: at,
                        fullSyncAt: at, syncedAt: at, days: days)
                ])
        }
        try cache.write(account(1), for: id, previous: nil)

        // The app's whole write of generation 2 lands between the reader's two reads.
        let read = cache.account(id) {
            try? cache.write(account(2), for: id, previous: nil)
        }
        let seen = try #require(read)
        let title = try #require(seen.events.first?.title)
        let stamp = try #require(seen.sync.first?.token)
        let events = try #require(Int(title.dropFirst()))
        let token = try #require(Int(stamp.dropFirst()))
        // New events with the old token: the changes between are read again, harmlessly.
        #expect(events == 2)
        #expect(token == 1)
        #expect(events >= token)
    }

    /// The same, for the write landing between the app's own two writes: the reader sees
    /// the new events and the old token, never the other way round.
    @Test func aReaderBetweenEventsAndSyncFileOfOneWriteSeesTheOldToken() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "day-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = CacheDirectory(url: folder)
        let id = AccountID("100000000000000000001")
        let calendarID = CalendarID(account: id, googleID: "you@gmail.com")
        var template = try #require(try DecodingTests.fixture().events.first)
        let at = Date(timeIntervalSince1970: 1_793_797_000)
        let days = CivilDate(year: 2026, month: 11, day: 3)...CivilDate(year: 2026, month: 11, day: 14)
        template.title = "g1"
        let old = AccountCache(
            fetchedAt: at, events: [template],
            sync: [CalendarSync(calendar: calendarID, token: "t1", tokenFrom: at, tokenTo: at, fullSyncAt: at, syncedAt: at, days: days)])
        try cache.write(old, for: id, previous: nil)

        // The app has written its new events and not yet its new sync file.
        template.title = "g2"
        try cache.write(EventsFile(events: [template]), to: CacheFile.events(id))
        let seen = try #require(cache.account(id))
        #expect(seen.events.first?.title == "g2")
        #expect(seen.sync.first?.token == "t1")
    }
}
