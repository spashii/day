import Foundation
import Testing

@testable import DayCore

#if canImport(AppKit)
    import AppKit
#endif

/// The symbol a calendar wears: the curated set, the small JSON file the app writes and the
/// Lock Screen widget reads, and the lookups the surfaces share.
struct CalendarSymbolTests {
    let work = TestData.workCalendar.id
    let personal = TestData.personalCalendar.id

    static func scratchFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "day-symbols-\(UUID().uuidString)")
    }

    func json(_ map: CalendarSymbolMap) throws -> String {
        String(decoding: try DayJSON.encoder().encode(map), as: UTF8.self)
    }

    // MARK: The set

    @Test func theSetIsThirtyDistinctSymbols() {
        let names = CalendarSymbol.all.map(\.name)
        #expect(names.count == 30)
        #expect(Set(names).count == names.count)
        #expect(Set(CalendarSymbol.all.map(\.label)).count == names.count)
        #expect(CalendarSymbol.named("briefcase")?.label == "Work")
        #expect(CalendarSymbol.named("nonexistent.symbol") == nil)
    }

    /// The set must stay inside what the system draws: `Image(systemName:)` with an unknown
    /// name shows nothing, and the picker would have a blank cell.
    @Test func everySymbolExistsOnThisSystem() {
        #if canImport(AppKit)
            for symbol in CalendarSymbol.all {
                #expect(
                    NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil) != nil,
                    "\(symbol.name) is not an SF Symbol on this macOS")
            }
        #endif
    }

    // MARK: Encoding

    @Test func encodesAsSortedPairsKeyedByAccountAndCalendar() throws {
        var map = CalendarSymbolMap()
        // Set out of order: the file is sorted by account, then calendar.
        map.set(CalendarSymbol.named("house"), for: personal)
        map.set(CalendarSymbol.named("briefcase"), for: work)
        #expect(
            try json(map)
                == #"{"symbols":[{"calendar":{"account":"A","googleID":"you@acme.com"},"symbol":"briefcase"},{"calendar":{"account":"P","googleID":"you@gmail.com"},"symbol":"house"}]}"#
        )
    }

    @Test func rewritingAnUnchangedMapWritesTheSameBytes() throws {
        var map = CalendarSymbolMap()
        for (index, symbol) in CalendarSymbol.all.enumerated() {
            map.set(
                symbol,
                for: CalendarID(account: AccountID("\(index % 3)"), googleID: "c\(index)@group"))
        }
        let again = try DayJSON.decoder().decode(
            CalendarSymbolMap.self, from: DayJSON.encoder().encode(map))
        #expect(again == map)
        #expect(try json(again) == json(map))
    }

    @Test func calendarIDsWithHashAndPlusSurvive() throws {
        let holiday = CalendarID(
            account: AccountID("1"), googleID: "en.dutch#holiday@group.v.calendar.google.com")
        let odd = CalendarID(account: AccountID("1"), googleID: "a+b@example.com")
        var map = CalendarSymbolMap()
        map.set(CalendarSymbol.named("beach.umbrella"), for: holiday)
        map.set(CalendarSymbol.named("gift"), for: odd)
        let back = try DayJSON.decoder().decode(
            CalendarSymbolMap.self, from: DayJSON.encoder().encode(map))
        #expect(back.symbol(for: holiday)?.name == "beach.umbrella")
        #expect(back.symbol(for: odd)?.name == "gift")
    }

    @Test func aHandWrittenFileReadsAndUnknownKeysAreIgnored() throws {
        let text = """
            {"version": 2, "symbols": [
              {"calendar": {"account": "A", "googleID": "you@acme.com"}, "symbol": "dumbbell", "note": 1}
            ], "other": true}
            """
        let map = try DayJSON.decoder().decode(CalendarSymbolMap.self, from: Data(text.utf8))
        #expect(map.symbol(for: work)?.name == "dumbbell")
        #expect(map.assigned.count == 1)
    }

    @Test func aFileWithNoSymbolsKeyIsEmpty() throws {
        let map = try DayJSON.decoder().decode(CalendarSymbolMap.self, from: Data("{}".utf8))
        #expect(map.isEmpty)
    }

    @Test func theLastEntryWinsForTheSameCalendar() throws {
        let text = """
            {"symbols": [
              {"calendar": {"account": "A", "googleID": "you@acme.com"}, "symbol": "book"},
              {"calendar": {"account": "A", "googleID": "you@acme.com"}, "symbol": "gift"}
            ]}
            """
        let map = try DayJSON.decoder().decode(CalendarSymbolMap.self, from: Data(text.utf8))
        #expect(map.symbol(for: work)?.name == "gift")
    }

    // MARK: Meaning

    @Test func noEntryMeansTheColorDot() {
        #expect(CalendarSymbolMap().symbol(for: work) == nil)
    }

    @Test func aNameTheSetDoesNotHoldReadsAsNoSymbol() throws {
        let text = """
            {"symbols": [{"calendar": {"account": "A", "googleID": "you@acme.com"}, "symbol": "no.such.symbol"}]}
            """
        let map = try DayJSON.decoder().decode(CalendarSymbolMap.self, from: Data(text.utf8))
        #expect(map.symbol(for: work) == nil)
    }

    @Test func settingNilGoesBackToTheColorDotAndLeavesNoEntry() throws {
        var map = CalendarSymbolMap()
        map.set(CalendarSymbol.named("book"), for: work)
        map.set(nil, for: work)
        #expect(map.symbol(for: work) == nil)
        #expect(map.isEmpty)
        #expect(try json(map) == #"{"symbols":[]}"#)
    }

    @Test func twoAccountsSharingACalendarKeepTheirOwnSymbols() {
        let google = "team@acme.com"
        let first = CalendarID(account: AccountID("A"), googleID: google)
        let second = CalendarID(account: AccountID("B"), googleID: google)
        var map = CalendarSymbolMap()
        map.set(CalendarSymbol.named("briefcase"), for: first)
        #expect(map.symbol(for: first)?.name == "briefcase")
        #expect(map.symbol(for: second) == nil)
    }

    @Test func forgettingAnAccountDropsOnlyItsSymbols() {
        var map = CalendarSymbolMap()
        map.set(CalendarSymbol.named("briefcase"), for: work)
        map.set(CalendarSymbol.named("house"), for: personal)
        map.forget(TestData.work.id)
        #expect(map.symbol(for: work) == nil)
        #expect(map.symbol(for: personal)?.name == "house")
    }

    // MARK: The file

    @Test func theFileRoundTripsThroughTheSharedFolder() throws {
        let folder = Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = CacheDirectory(url: folder)
        #expect(CalendarSymbolMap.read(from: cache).isEmpty)

        var map = CalendarSymbolMap()
        map.set(CalendarSymbol.named("music.note"), for: personal)
        try map.write(to: cache)
        #expect(
            FileManager.default.fileExists(
                atPath: cache.fileURL("calendar-symbols.json").path(percentEncoded: false)))
        #expect(CalendarSymbolMap.read(from: cache) == map)
    }

    @Test func aDamagedFileReadsAsNoSymbols() throws {
        let folder = Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = CacheDirectory(url: folder)
        try cache.write(Data("not json".utf8), to: CalendarSymbolMap.fileName)
        #expect(CalendarSymbolMap.read(from: cache).isEmpty)
    }

    // MARK: Lookups the surfaces share

    @Test func anEventWearsItsOwnCalendarsSymbolFirst() {
        var map = CalendarSymbolMap()
        map.set(CalendarSymbol.named("briefcase"), for: work)
        map.set(CalendarSymbol.named("house"), for: personal)
        var event = TestData.event("Investor call", "2026-11-04 14:00", "2026-11-04 15:00")
        event.calendars = [work, personal]
        #expect(map.symbol(for: event)?.name == "briefcase")
    }

    @Test func aMergedEventFallsBackToAnotherCalendarItSitsOn() {
        var map = CalendarSymbolMap()
        map.set(CalendarSymbol.named("house"), for: personal)
        var event = TestData.event("Investor call", "2026-11-04 14:00", "2026-11-04 15:00")
        event.calendars = [work, personal]
        #expect(map.symbol(for: event)?.name == "house")
        #expect(CalendarSymbolMap().symbol(for: event) == nil)
    }

    @Test func theLockScreenSymbolIsTheNextEventsNotTheCurrentOnes() {
        var map = CalendarSymbolMap()
        map.set(CalendarSymbol.named("briefcase"), for: work)
        map.set(CalendarSymbol.named("house"), for: personal)
        let events = [
            TestData.event("Standup", "2026-11-04 10:00", "2026-11-04 11:00"),
            TestData.event("Dinner", "2026-11-04 19:00", "2026-11-04 21:00", account: TestData.personal),
        ]
        let calendar = TestData.amsterdam
        func symbol(_ now: String) -> String? {
            map.nextEventSymbol(events: events, now: TestData.date(now), calendar: calendar)?.name
        }
        #expect(symbol("2026-11-04 09:00") == "briefcase")
        // Standup is current at 10:30; the Lock Screen names what is next.
        #expect(symbol("2026-11-04 10:30") == "house")
        #expect(symbol("2026-11-04 21:30") == nil)
    }

    @Test func theNextEventWithNoSymbolShowsNone() {
        var map = CalendarSymbolMap()
        map.set(CalendarSymbol.named("house"), for: personal)
        let events = [TestData.event("Standup", "2026-11-04 10:00", "2026-11-04 11:00")]
        #expect(
            map.nextEventSymbol(
                events: events, now: TestData.date("2026-11-04 09:00"), calendar: TestData.amsterdam)
                == nil)
    }

    @Test func theInventedWeekGivesTheNextEventsCalendarItsSymbol() throws {
        let fixture = try TestData.loadFixture()
        let events = try TestData.inventedEvents()
        var map = CalendarSymbolMap()
        // Standup on Wednesday 4 November at 9:30 is on the work calendar.
        let standup = try #require(events.first { $0.title == "Standup" })
        map.set(CalendarSymbol.named("laptopcomputer"), for: standup.id.calendar)
        let symbol = map.nextEventSymbol(
            events: events, now: TestData.wednesday("07:50"), calendar: fixture.calendar)
        #expect(symbol?.name == "laptopcomputer")
    }
}
