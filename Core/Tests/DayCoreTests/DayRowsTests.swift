import Foundation
import Testing

@testable import DayCore

/// Section 7 of the brief: the Day list, top to bottom.
struct DayRowsTests {
    let calendar = TestData.amsterdam

    func rows(_ day: String, now: Date, _ events: [Event], calendar: Calendar? = nil) -> [DayRow] {
        dayRows(day: TestData.day(day), events: events, now: now, calendar: calendar ?? self.calendar)
    }

    /// One line per row, in the words the list draws: `12:30 Lunch with Maya | in 20 min | Join`.
    func render(_ rows: [DayRow], calendar: Calendar? = nil) -> [String] {
        let calendar = calendar ?? self.calendar
        return rows.map { row in
            switch row {
            case .allDay(let event, let position):
                return "all-day: \(event.title)" + (position.map { ", \($0)" } ?? "")
            case .allDayMore(let text):
                return "all-day: \(text)"
            case .earlier(let events):
                return Formatting.earlier(events)
            case .nowLine(let now):
                return "now \(Formatting.time(now, calendar: calendar))"
            case .event(let event, let second, let join):
                let start = Formatting.time(event.time.start(in: calendar), calendar: calendar)
                return ["\(start) \(event.title)", second, join ? "Join" : nil]
                    .compactMap { $0 }.joined(separator: " | ")
            case .gap(let text, _):
                return "gap: \(text)"
            }
        }
    }

    func wednesday(_ time: String) throws -> [String] {
        render(rows("2026-11-04", now: TestData.wednesday(time), try TestData.inventedEvents()))
    }

    // MARK: The invented Wednesday

    @Test func atTwelveTen() throws {
        #expect(
            try wednesday("12:10") == [
                "all-day: Lisbon, day 2 of 3",
                "Earlier: Standup, Design review",
                "now 12:10",
                "12:30 Lunch with Maya | in 20 min",
                "14:00 Investor call | No reply yet",
                "14:30 Acme sync",
                "gap: 1 h free",
                "16:00 Weekly planning",
            ])
    }

    @Test func beforeTheDayStarts() throws {
        // The now line above the first row; a gap row only between events; the place of a
        // one-off while it is not the next hour.
        #expect(
            try wednesday("07:50") == [
                "all-day: Lisbon, day 2 of 3",
                "now 7:50",
                "9:30 Standup",
                "gap: 1 h 15 min free",
                "11:00 Design review",
                "12:30 Lunch with Maya | Café Nord",
                "14:00 Investor call | No reply yet",
                "14:30 Acme sync",
                "gap: 1 h free",
                "16:00 Weekly planning",
            ])
    }

    @Test func tenMinutesBeforeTheFirstOneJoinOpens() throws {
        #expect(try wednesday("09:19").contains("9:30 Standup | in 11 min"))
        #expect(try wednesday("09:20").contains("9:30 Standup | in 10 min | Join"))
    }

    @Test func duringAnEventTheNowLineIsNotDrawn() throws {
        #expect(
            try wednesday("11:40") == [
                "all-day: Lisbon, day 2 of 3",
                "Earlier: Standup",
                "11:00 Design review | ends in 20 min | Join",
                "12:30 Lunch with Maya | in 50 min",
                "14:00 Investor call | No reply yet",
                "14:30 Acme sync",
                "gap: 1 h free",
                "16:00 Weekly planning",
            ])
    }

    @Test func twoOverlappingEventsBothGetJoinInTheirWindows() throws {
        #expect(
            try wednesday("14:10") == [
                "all-day: Lisbon, day 2 of 3",
                "Earlier: Standup, Design review and 1 more",
                "14:00 Investor call | ends in 50 min | Join",
                "14:30 Acme sync | in 20 min",
                "gap: 1 h free",
                "16:00 Weekly planning",
            ])
        let late = try wednesday("14:25")
        #expect(late.contains("14:00 Investor call | ends in 35 min | Join"))
        #expect(late.contains("14:30 Acme sync | in 5 min | Join"))
    }

    @Test func theGapThatHoldsNowReadsFreeUntil() throws {
        #expect(
            try wednesday("15:10") == [
                "all-day: Lisbon, day 2 of 3",
                "Earlier: Standup, Design review and 3 more",
                "now 15:10",
                "gap: Free until 16:00",
                "16:00 Weekly planning | in 50 min",
            ])
    }

    @Test func afterTheLastEventTheNowLineIsGone() throws {
        #expect(
            try wednesday("16:20") == [
                "all-day: Lisbon, day 2 of 3",
                "Earlier: Standup, Design review and 3 more",
                "16:00 Weekly planning | ends in 40 min | Join",
            ])
        #expect(
            try wednesday("17:30") == [
                "all-day: Lisbon, day 2 of 3",
                "Earlier: Standup, Design review and 4 more",
            ])
    }

    @Test func mergedAndDeclinedEventsAppearOnceOrNotAtAll() throws {
        let all = try wednesday("07:50").joined(separator: "\n")
        #expect(all.components(separatedBy: "Investor call").count == 2)
        #expect(!all.contains("Vendor demo"))
    }

    @Test func rowIdentitiesAreStableAcrossMinutes() throws {
        let events = try TestData.inventedEvents()
        let a = rows("2026-11-04", now: TestData.wednesday("12:10"), events).map(\.id)
        let b = rows("2026-11-04", now: TestData.wednesday("12:11"), events).map(\.id)
        #expect(a == b)
        #expect(Set(a).count == a.count)
    }

    // MARK: Other days of the fixture

    @Test func aFutureDayHasNoEarlierRowNoNowLineAndAllItsGaps() throws {
        let events = try TestData.inventedEvents()
        let thursday = render(rows("2026-11-05", now: TestData.wednesday("12:10"), events))
        #expect(
            thursday == [
                "all-day: Lisbon, day 3 of 3",
                "9:30 Standup",
                "gap: 1 h 15 min free",
                "11:00 Design review",
                "gap: 3 h 30 min free",
                "15:30 Quick sync on pricing",
                "gap: 4 h 45 min free",
                "20:30 Flight to Amsterdam (TP 674) | Lisbon Humberto Delgado (LIS)",
            ])
    }

    @Test func fridayShowsItsHourGaps() throws {
        let events = try TestData.inventedEvents()
        #expect(
            render(rows("2026-11-06", now: TestData.wednesday("12:10"), events)) == [
                "10:00 Roadmap review",
                "gap: 1 h free",
                "12:00 Support handover",
                "gap: 1 h free",
                "13:30 Design critique",
                "gap: 1 h free",
                "15:00 Investor call",
            ])
    }

    @Test func outOfOfficeDaysShowTheBlockWithItsPosition() throws {
        let events = try TestData.inventedEvents()
        let now = TestData.wednesday("12:10")
        #expect(
            render(rows("2026-11-09", now: now, events)) == [
                "all-day: Out of office, day 1 of 4", "15:00 Board call",
            ])
        #expect(
            render(rows("2026-11-11", now: now, events)) == [
                "all-day: Out of office, day 3 of 4", "all-day: Sint Maarten",
            ])
    }

    @Test func birthdaysLiveInTheAllDayLine() throws {
        let events = try TestData.inventedEvents()
        #expect(render(rows("2026-11-08", now: TestData.wednesday("12:10"), events)) == ["all-day: Noor's birthday"])
    }

    @Test func aPastDayShowsEverythingWithoutEarlierOrNowLine() throws {
        let events = try TestData.inventedEvents()
        let now = TestData.wednesday("12:10")
        let tuesday = render(rows("2026-11-03", now: now, events))
        #expect(
            tuesday == [
                "all-day: Lisbon, day 1 of 3",
                "13:00 Team retro",
                "gap: 2 h free",
                "16:00 Customer office hours",
                "17:00 Hiring sync",
            ])
    }

    // MARK: All-day lines

    @Test func allDayLinesAreCappedAtThreeThenMore() {
        func items(_ n: Int) -> [Event] {
            (1...n).map { TestData.allDay("Item \($0)", "2026-11-10", "2026-11-11") }
        }
        let now = TestData.date("2026-11-10 08:00")
        #expect(render(rows("2026-11-10", now: now, items(3))) == ["all-day: Item 1", "all-day: Item 2", "all-day: Item 3"])
        #expect(
            render(rows("2026-11-10", now: now, items(5))) == [
                "all-day: Item 1", "all-day: Item 2", "all-day: Item 3", "all-day: 2 more",
            ])
        #expect(render(rows("2026-11-10", now: now, items(4))).last == "all-day: 1 more")
    }

    @Test func multiDayItemsShowTheirPosition() {
        let trip = TestData.allDay("Lisbon", "2026-11-03", "2026-11-06")
        let now = TestData.date("2026-11-04 08:00")
        #expect(render(rows("2026-11-03", now: now, [trip])) == ["all-day: Lisbon, day 1 of 3"])
        #expect(render(rows("2026-11-04", now: now, [trip])) == ["all-day: Lisbon, day 2 of 3"])
        #expect(render(rows("2026-11-05", now: now, [trip])) == ["all-day: Lisbon, day 3 of 3"])
        #expect(render(rows("2026-11-06", now: now, [trip])) == [])
        #expect(render(rows("2026-11-02", now: now, [trip])) == [])
    }

    @Test func allDayItemsKeepTheOrderTheyBegan() {
        let events = [
            TestData.allDay("Starts today", "2026-11-05", "2026-11-06"),
            TestData.allDay("Started earlier", "2026-11-03", "2026-11-07"),
        ]
        #expect(
            render(rows("2026-11-05", now: TestData.date("2026-11-05 08:00"), events)) == [
                "all-day: Started earlier, day 3 of 4", "all-day: Starts today",
            ])
    }

    @Test func allDayItemsThatNeverAppear() {
        let events = [
            TestData.allDay("Place", "2026-11-05", "2026-11-06", kind: .workingLocation),
            TestData.allDay("Focus", "2026-11-05", "2026-11-06", kind: .focusTime),
            TestData.allDay("Declined", "2026-11-05", "2026-11-06", response: .declined),
            TestData.allDay("Cancelled", "2026-11-05", "2026-11-06", status: .cancelled),
            TestData.allDay("Kept", "2026-11-05", "2026-11-06"),
            TestData.allDay("Birthday", "2026-11-05", "2026-11-06", kind: .birthday, recurring: true),
        ]
        #expect(
            render(rows("2026-11-05", now: TestData.date("2026-11-05 08:00"), events)) == [
                "all-day: Kept", "all-day: Birthday",
            ])
    }

    @Test func timedOutOfOfficeJoinsTheAllDayLines() {
        let now = TestData.date("2026-11-05 08:00")
        let whole = TestData.event("Away", "2026-11-05 00:00", "2026-11-07 00:00", kind: .outOfOffice)
        #expect(render(rows("2026-11-05", now: now, [whole])) == ["all-day: Away, day 1 of 2"])
        // One day, not the whole of it: the hours stand where the position would.
        let partial = TestData.event("Away", "2026-11-05 13:00", "2026-11-05 17:00", kind: .outOfOffice)
        #expect(render(rows("2026-11-05", now: now, [partial])) == ["all-day: Away, 13:00 to 17:00"])
        // A recurring one that is only part of the day is routine and stays out, as in the month.
        let routine = TestData.event(
            "Away", "2026-11-05 16:30", "2026-11-05 23:00", kind: .outOfOffice, recurring: true)
        #expect(render(rows("2026-11-05", now: now, [routine])) == [])
    }

    // MARK: Second lines

    @Test func secondLineIsTheFirstUnusualThing() {
        let now = TestData.date("2026-11-04 10:00")
        func line(_ event: Event) -> String? {
            for case .event(_, let second, _) in rows("2026-11-04", now: now, [event]) { return second }
            return nil
        }
        // In progress beats the start.
        let progress = TestData.event(
            "P", "2026-11-04 09:30", "2026-11-04 10:25", location: "Café Nord", join: "https://meet.google.com/x")
        #expect(line(progress) == "ends in 25 min")
        // Within the hour beats unanswered.
        let soon = TestData.event(
            "S", "2026-11-04 10:20", "2026-11-04 11:00", response: .needsAction, attendees: 4,
            location: "Café Nord")
        #expect(line(soon) == "in 20 min")
        // Unanswered one-off with other guests beats the place.
        let pending = TestData.event(
            "N", "2026-11-04 14:00", "2026-11-04 15:00", response: .needsAction, attendees: 4,
            location: "Café Nord")
        #expect(line(pending) == "No reply yet")
        // Recurring ones are never unanswered news; a place is shown.
        let series = TestData.event(
            "R", "2026-11-04 14:00", "2026-11-04 15:00", recurring: true, response: .needsAction,
            attendees: 4, location: "Café Nord")
        #expect(line(series) == "Café Nord")
        // No guest list, no place: nothing to say.
        #expect(line(TestData.event("Q", "2026-11-04 14:00", "2026-11-04 15:00")) == nil)
        // A link in the location is not a place. The meeting service is never named.
        let linked = TestData.event(
            "L", "2026-11-04 14:00", "2026-11-04 15:00", location: "https://meet.google.com/abc-defg-hij",
            join: "https://meet.google.com/abc-defg-hij")
        #expect(line(linked) == nil)
        // A place is its first line only.
        let address = TestData.event(
            "A", "2026-11-04 14:00", "2026-11-04 15:00", location: "Café Nord\nRua Inventada 4, Lisboa")
        #expect(line(address) == "Café Nord")
    }

    @Test func startsWithinSixtyMinutesIsInclusive() {
        let now = TestData.date("2026-11-04 10:00")
        func line(_ start: String) -> String? {
            let event = TestData.event("E", "2026-11-04 \(start)", "2026-11-04 12:30")
            for case .event(_, let second, _) in rows("2026-11-04", now: now, [event]) { return second }
            return nil
        }
        #expect(line("11:00") == "in 1 h")
        #expect(line("10:59") == "in 59 min")
        #expect(line("11:01") == nil)
    }

    @Test func countdownsRoundUpSoNeverZero() {
        let event = TestData.event("E", "2026-11-04 10:00", "2026-11-04 11:30")
        let now = TestData.date("2026-11-04 09:59:30")
        for case .event(_, let second, _) in rows("2026-11-04", now: now, [event]) {
            #expect(second == "in 1 min")
        }
        let during = TestData.date("2026-11-04 10:00:10")
        for case .event(_, let second, _) in rows("2026-11-04", now: during, [event]) {
            #expect(second == "ends in 1 h 30 min")
        }
    }

    // MARK: Gaps and the now line

    @Test func aGapNeedsSixtyMinutes() {
        let events = [
            TestData.event("A", "2026-11-10 09:00", "2026-11-10 10:00"),
            TestData.event("B", "2026-11-10 10:59", "2026-11-10 11:30"),
            TestData.event("C", "2026-11-10 13:00", "2026-11-10 14:00"),
        ]
        #expect(
            render(rows("2026-11-10", now: TestData.date("2026-11-09 08:00"), events)) == [
                "9:00 A", "10:59 B", "gap: 1 h 30 min free", "13:00 C",
            ])
    }

    @Test func overlappingEventsMakeNoGapBetweenThem() {
        let events = [
            TestData.event("Long", "2026-11-10 09:00", "2026-11-10 12:00"),
            TestData.event("Short", "2026-11-10 09:30", "2026-11-10 10:00"),
            TestData.event("After", "2026-11-10 12:30", "2026-11-10 13:00"),
        ]
        #expect(
            render(rows("2026-11-10", now: TestData.date("2026-11-09 08:00"), events)) == [
                "9:00 Long", "9:30 Short", "12:30 After",
            ])
    }

    @Test func theNowLineSitsAboveTheFirstRowStillToCome() {
        let events = [
            TestData.event("A", "2026-11-10 09:00", "2026-11-10 10:00"),
            TestData.event("B", "2026-11-10 10:20", "2026-11-10 11:00"),
        ]
        func lines(_ now: String) -> [String] {
            render(rows("2026-11-10", now: TestData.date("2026-11-10 \(now)"), events))
        }
        #expect(lines("08:00") == ["now 8:00", "9:00 A | in 1 h", "10:20 B"])
        // In a short gap there is a now line and no gap row.
        #expect(lines("10:10") == ["Earlier: A", "now 10:10", "10:20 B | in 10 min"])
        // Inside an event, none; after the last, none.
        #expect(lines("09:30") == ["9:00 A | ends in 30 min", "10:20 B | in 50 min"])
        #expect(lines("11:00") == ["Earlier: A, B"])
    }

    @Test func noEventsNoNowLine() {
        #expect(render(rows("2026-11-10", now: TestData.date("2026-11-10 12:00"), [])) == [])
    }

    // MARK: Nothing else today

    func ending(_ day: String, _ now: String, _ events: [Event]) -> DayEnding? {
        let at = TestData.date(now)
        return dayEnding(
            rows: rows(day, now: at, events), day: TestData.day(day), now: at, calendar: calendar)
    }

    @Test func aDayWithNothingAtAllIsNothingScheduled() {
        #expect(ending("2026-11-10", "2026-11-10 12:00", []) == .nothingScheduled)
        // Any day, not only today.
        #expect(ending("2026-11-11", "2026-11-10 12:00", []) == .nothingScheduled)
    }

    @Test func afterTheLastTimedEventTheDayIsNothingElse() {
        let events = [
            TestData.event("A", "2026-11-10 09:00", "2026-11-10 10:00"),
            TestData.event("B", "2026-11-10 10:00", "2026-11-10 11:00"),
        ]
        #expect(ending("2026-11-10", "2026-11-10 12:00", events) == .nothingElse)
        // The last event is still in progress, or another is still to come.
        #expect(ending("2026-11-10", "2026-11-10 10:30", events) == nil)
        #expect(ending("2026-11-10", "2026-11-10 08:00", events) == nil)
    }

    @Test func theAllDayLineStaysAndNothingElseFollowsItWithOrWithoutOne() {
        let events = [
            TestData.allDay("Lisbon", "2026-11-10", "2026-11-11"),
            TestData.event("A", "2026-11-10 09:00", "2026-11-10 10:00"),
        ]
        let now = TestData.date("2026-11-10 12:00")
        #expect(render(rows("2026-11-10", now: now, events)) == ["all-day: Lisbon", "Earlier: A"])
        #expect(ending("2026-11-10", "2026-11-10 12:00", events) == .nothingElse)
        #expect(ending("2026-11-10", "2026-11-10 12:00", [events[1]]) == .nothingElse)
    }

    @Test func anAllDayEventAloneCountsAsAnEvent() {
        let events = [TestData.allDay("Lisbon", "2026-11-10", "2026-11-11")]
        #expect(ending("2026-11-10", "2026-11-10 08:00", events) == .nothingElse)
    }

    @Test func nothingElseIsOnlyEverTodays() {
        let events = [
            TestData.allDay("Lisbon", "2026-11-11", "2026-11-12"),
            TestData.event("A", "2026-11-09 09:00", "2026-11-09 10:00"),
        ]
        // Another day's list has no ending of its own while it has rows: it reads as a list.
        #expect(ending("2026-11-11", "2026-11-10 12:00", events) == nil)
        #expect(ending("2026-11-09", "2026-11-10 12:00", events) == nil)
    }

    @Test func theInventedWednesdayEndsWhenTheLastEventDoes() throws {
        let events = try TestData.inventedEvents()
        func at(_ time: String) -> DayEnding? {
            let now = TestData.wednesday(time)
            return dayEnding(
                rows: rows("2026-11-04", now: now, events), day: TestData.day("2026-11-04"), now: now,
                calendar: calendar)
        }
        #expect(at("12:10") == nil)
        #expect(at("17:30") == .nothingElse)
    }

    @Test func earlierFoldsTheEndedAndOnlyOnToday() {
        let events = [
            TestData.event("A", "2026-11-10 09:00", "2026-11-10 10:00"),
            TestData.event("B", "2026-11-10 10:00", "2026-11-10 11:00"),
            TestData.event("C", "2026-11-10 11:00", "2026-11-10 12:00"),
            TestData.event("D", "2026-11-10 16:00", "2026-11-10 17:00"),
        ]
        #expect(
            render(rows("2026-11-10", now: TestData.date("2026-11-10 13:00"), events)) == [
                "Earlier: A, B and 1 more", "now 13:00", "gap: Free until 16:00", "16:00 D",
            ])
        // Tomorrow, the same events are the whole list.
        #expect(
            render(rows("2026-11-10", now: TestData.date("2026-11-09 13:00"), events)).first == "9:00 A")
    }

    @Test func earlierEventsComeBackInOrderForTheUnfold() {
        let events = [
            TestData.event("B", "2026-11-10 10:00", "2026-11-10 11:00"),
            TestData.event("A", "2026-11-10 09:00", "2026-11-10 10:00"),
        ]
        let all = rows("2026-11-10", now: TestData.date("2026-11-10 13:00"), events)
        guard case .earlier(let ended) = all.first else {
            Issue.record("no earlier row")
            return
        }
        #expect(ended.map(\.title) == ["A", "B"])
    }

    // MARK: Join

    @Test func joinOnAtMostTheCurrentAndTheNextEvent() {
        func call(_ title: String, _ start: String, _ end: String) -> Event {
            TestData.event(
                title, "2026-11-10 \(start)", "2026-11-10 \(end)", join: "https://meet.google.com/\(title)")
        }
        let events = [
            call("A", "09:00", "10:00"), call("B", "10:05", "10:30"), call("C", "10:10", "10:40"),
        ]
        let now = TestData.date("2026-11-10 09:58")
        // A in progress, B next in 7 minutes; C is third and gets none.
        #expect(
            render(rows("2026-11-10", now: now, events)) == [
                "9:00 A | ends in 2 min | Join", "10:05 B | in 7 min | Join", "10:10 C | in 12 min",
            ])
    }

    @Test func noLinkNoJoin() {
        let event = TestData.event("A", "2026-11-10 09:00", "2026-11-10 10:00")
        #expect(render(rows("2026-11-10", now: TestData.date("2026-11-10 09:30"), [event])) == ["9:00 A | ends in 30 min"])
    }

    // MARK: Midnight and daylight saving

    @Test func anOvernightEventIsARowOnBothDays() {
        let overnight = TestData.event("Overnight", "2026-11-10 22:00", "2026-11-11 07:00")
        let now = TestData.date("2026-11-09 08:00")
        #expect(render(rows("2026-11-10", now: now, [overnight])) == ["22:00 Overnight"])
        #expect(render(rows("2026-11-11", now: now, [overnight])) == ["22:00 Overnight"])
        #expect(render(rows("2026-11-12", now: now, [overnight])) == [])
        // A flight that lands at 00:15 belongs to its own day only.
        let flight = TestData.event("Flight", "2026-11-10 20:30", "2026-11-11 00:15", kind: .fromGmail)
        #expect(render(rows("2026-11-11", now: now, [flight])) == [])
    }

    @Test func overnightRowsAfterMidnightAreInProgress() {
        let overnight = TestData.event("Overnight", "2026-11-10 22:00", "2026-11-11 07:00")
        let now = TestData.date("2026-11-11 05:00")
        #expect(render(rows("2026-11-11", now: now, [overnight])) == ["22:00 Overnight | ends in 2 h"])
    }

    @Test func gapsAcrossTheClocksChangingAreElapsedTime() {
        // 29 March 2026: 01:45 CET to 03:30 CEST is 45 minutes of elapsed time.
        let short = [
            TestData.event("A", "2026-03-29 01:00", "2026-03-29 01:45"),
            TestData.event("B", "2026-03-29 03:30", "2026-03-29 04:30"),
        ]
        let now = TestData.date("2026-03-28 08:00")
        #expect(render(rows("2026-03-29", now: now, short)) == ["1:00 A", "3:30 B"])
        // 01:00 to 03:30 is 1 h 30 min.
        let long = [
            TestData.event("A", "2026-03-29 00:00", "2026-03-29 01:00"),
            TestData.event("B", "2026-03-29 03:30", "2026-03-29 04:30"),
        ]
        #expect(render(rows("2026-03-29", now: now, long)) == ["0:00 A", "gap: 1 h 30 min free", "3:30 B"])
    }

    @Test func allDayLinesDoNotMoveWithTheZone() {
        // The same civil days read the same east and west of Greenwich.
        let trip = TestData.allDay("Lisbon", "2026-11-03", "2026-11-06")
        for zone in ["Asia/Kolkata", "America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Pago_Pago", "UTC"] {
            let local = TestData.calendar(zone)
            let now = TestData.date("2026-11-04 08:00", in: local)
            #expect(
                render(rows("2026-11-04", now: now, [trip], calendar: local), calendar: local)
                    == ["all-day: Lisbon, day 2 of 3"], "\(zone)")
            #expect(render(rows("2026-11-06", now: now, [trip], calendar: local), calendar: local) == [], "\(zone)")
        }
    }

    @Test func theSameInstantsLandOnDifferentDaysInDifferentZones() {
        // 22:30 to 23:30 UTC on 4 November is 23:30 to 00:30 in Amsterdam and 04:00 to 05:00
        // on the 5th in Kolkata.
        let utc = TestData.calendar("UTC")
        let event = TestData.event("Late call", "2026-11-04 22:30", "2026-11-04 23:30", zone: utc)
        let amsterdam = TestData.amsterdam
        let kolkata = TestData.calendar("Asia/Kolkata", locale: "en_US")
        let now = TestData.date("2026-11-03 08:00", in: utc)
        #expect(render(rows("2026-11-04", now: now, [event], calendar: amsterdam), calendar: amsterdam) == ["23:30 Late call"])
        #expect(render(rows("2026-11-05", now: now, [event], calendar: amsterdam), calendar: amsterdam) == [])
        #expect(render(rows("2026-11-04", now: now, [event], calendar: kolkata), calendar: kolkata) == [])
        #expect(TestData.plain(render(rows("2026-11-05", now: now, [event], calendar: kolkata), calendar: kolkata)[0]) == "4:00 AM Late call")
    }
}
