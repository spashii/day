import Foundation
import Testing

@testable import DayCore

/// Section 4 of the brief: the Lock Screen table on the invented Wednesday, the line 2 and
/// line 3 rules, Always-On, the states, staying correct, and the timeline's entry times
/// across midnight and daylight saving.
struct WidgetTimelineTests {
    let calendar = TestData.amsterdam

    func entry(
        _ events: [Event], now: Date, fetchedAt: Date? = nil, signedOut: Int = 0,
        calendar: Calendar? = nil
    ) -> WidgetEntry {
        widgetTimeline(
            events: events, now: now, fetchedAt: fetchedAt ?? now, signedOutAccounts: signedOut,
            calendar: calendar ?? self.calendar)[0]
    }

    // MARK: The table

    struct Row: Sendable, CustomTestStringConvertible {
        var time: String
        var inline: String
        var rectangular: [String]
        var circular: String

        var testDescription: String { time }
    }

    static let table: [Row] = [
        Row(time: "07:50", inline: "9:30 Standup",
            rectangular: ["Standup", "9:30 to 9:45", "11:00 Design review"], circular: "9:30"),
        Row(time: "09:20", inline: "9:30 Standup",
            rectangular: ["Standup", "9:30 · in 10 min", "11:00 Design review"], circular: "9:30"),
        Row(time: "11:40", inline: "12:30 Lunch with Maya",
            rectangular: ["Design review", "until 12:00", "12:30 Lunch with Maya"],
            circular: "12:30"),
        Row(time: "14:10", inline: "14:30 Acme sync",
            rectangular: ["Investor call", "until 15:00", "Also 14:30 Acme sync"], circular: "14:30"),
        Row(time: "16:20", inline: "Thu 9:30 Standup",
            rectangular: ["Weekly planning", "until 17:00", "Last one today"], circular: "THU 9:30"),
        Row(time: "17:30", inline: "Thu 9:30 Standup",
            rectangular: ["Standup", "Tomorrow 9:30", "11:00 Design review"], circular: "THU 9:30"),
    ]

    @Test(arguments: table)
    func lockScreenTableOnTheInventedWednesday(_ row: Row) throws {
        let events = try TestData.inventedEvents()
        let now = TestData.wednesday(row.time)
        let shown = entry(events, now: now)
        #expect(shown.date == now)
        #expect(shown.inline == row.inline)
        #expect(shown.rectangularText(now: now, calendar: calendar) == row.rectangular)
        #expect(shown.circularText == row.circular)
    }

    @Test func tapTargets() throws {
        let events = try TestData.inventedEvents()
        let now = TestData.wednesday("14:10")
        let shown = entry(events, now: now)
        // Inline and circular open today; rectangular opens the event sheet for its event.
        #expect(shown.url == DayLink.day(TestData.day("2026-11-04")).url)
        let investor = try #require(events.first { $0.title == "Investor call" })
        #expect(shown.rectangular.url == DayLink.event(investor.id).url)
        #expect(shown.rectangular.url?.absoluteString.hasPrefix("day://event/") == true)
        // The day link is the entry's own day, so a tomorrow event still opens today.
        let late = entry(events, now: TestData.wednesday("17:30"))
        #expect(late.url == DayLink.day(TestData.day("2026-11-04")).url)
    }

    // MARK: Line 2

    @Test func lineTwoFirstMatch() throws {
        let events = [
            TestData.event("In progress", "2026-11-04 10:00", "2026-11-04 11:00"),
            TestData.event("Soon", "2026-11-04 14:00", "2026-11-04 15:00"),
        ]
        let now = TestData.date("2026-11-04 10:30")
        // In progress beats everything.
        #expect(entry(events, now: now).rectangular.when == WhenLine(text: "until 11:00"))

        // Within 60 minutes: the clock and a date for the view to count down against.
        let near = entry(events, now: TestData.date("2026-11-04 13:00"))
        #expect(near.rectangular.when
            == WhenLine(text: "14:00", relativeTo: TestData.date("2026-11-04 14:00"), reduced: "14:00 to 15:00"))

        // At exactly an hour it still counts down; one second over it is the range.
        let countdown = WhenLine(
            text: "14:00", relativeTo: TestData.date("2026-11-04 14:00"), reduced: "14:00 to 15:00")
        #expect(entry(events, now: TestData.date("2026-11-04 13:00:00")).rectangular.when == countdown)
        #expect(entry(events, now: TestData.date("2026-11-04 12:59:59")).rectangular.when
            == WhenLine(text: "14:00 to 15:00"))

        // Tomorrow, then later.
        let tomorrow = [TestData.event("Early", "2026-11-05 09:30", "2026-11-05 10:00")]
        #expect(entry(tomorrow, now: TestData.date("2026-11-04 20:00")).rectangular.when
            == WhenLine(text: "Tomorrow 9:30"))
        #expect(entry(tomorrow, now: TestData.date("2026-11-03 20:00")).rectangular.when
            == WhenLine(text: "Thu 9:30"))
    }

    @Test func withinTheHourAcrossMidnightStillCountsDown() {
        let events = [TestData.event("Early", "2026-11-05 00:30", "2026-11-05 01:00")]
        let shown = entry(events, now: TestData.date("2026-11-04 23:50"))
        #expect(shown.rectangular.when?.text == "0:30")
        #expect(shown.rectangular.when?.relativeTo == TestData.date("2026-11-05 00:30"))
    }

    @Test func alwaysOnShowsClockTimesOnly() throws {
        let events = try TestData.inventedEvents()
        // Countdown form: the reduced text is the range.
        let soon = entry(events, now: TestData.wednesday("09:20"))
        #expect(soon.rectangular.when?.reduced == "9:30 to 9:45")
        // In progress: until.
        let progress = entry(events, now: TestData.wednesday("14:10"))
        #expect(progress.rectangular.when?.reduced == "until 15:00")
        // Later today and tomorrow are clock times already.
        let later = entry(events, now: TestData.wednesday("07:50"))
        #expect(later.rectangular.when?.reduced == "9:30 to 9:45")
        let tomorrow = entry(events, now: TestData.wednesday("17:30"))
        #expect(tomorrow.rectangular.when?.reduced == "Tomorrow 9:30")
        // Only the within-the-hour form carries a relative date, which Always-On never draws.
        #expect(later.rectangular.when?.relativeTo == nil)
        #expect(progress.rectangular.when?.relativeTo == nil)
        #expect(soon.rectangular.when?.relativeTo != nil)
    }

    // MARK: Line 3

    @Test func lineThreeFirstMatch() {
        let a = TestData.event("A", "2026-11-04 10:00", "2026-11-04 12:00")
        let b = TestData.event("B", "2026-11-04 11:00", "2026-11-04 11:30")
        let c = TestData.event("C", "2026-11-04 15:00", "2026-11-04 16:00")
        let now = TestData.date("2026-11-04 10:30")
        let fetched = TestData.date("2026-11-04 10:30")

        // 5. Last one today.
        #expect(entry([a], now: now).rectangular.after == "Last one today")
        // 4. The follower, with no connective.
        #expect(entry([a, c], now: now).rectangular.after == "15:00 C")
        // 3. Also, when the next event overlaps the one shown.
        #expect(entry([a, b, c], now: now).rectangular.after == "Also 11:00 B")
        // 2. Signed out beats Also and the follower.
        #expect(entry([a, b, c], now: now, signedOut: 1).rectangular.after == "1 account signed out")
        #expect(entry([a, b, c], now: now, signedOut: 2).rectangular.after == "2 accounts signed out")
        // 1. As of beats signed out.
        let old = entry([a, b, c], now: now, fetchedAt: fetched.addingTimeInterval(-3 * 3600), signedOut: 2)
        #expect(old.rectangular.after == "As of 7:30")
    }

    @Test func lineThreeNamesTheDayOfTheEventShown() {
        // A shown event tomorrow with another after it that day names the follower; alone,
        // nothing, because Last one today would be untrue.
        let alone = [TestData.event("Early", "2026-11-05 09:30", "2026-11-05 10:00")]
        #expect(entry(alone, now: TestData.date("2026-11-04 20:00")).rectangular.after == nil)
        let pair = alone + [TestData.event("Next", "2026-11-05 11:00", "2026-11-05 12:00")]
        #expect(entry(pair, now: TestData.date("2026-11-04 20:00")).rectangular.after == "11:00 Next")
        // The following event on a later day is not named.
        let split = alone + [TestData.event("Friday", "2026-11-06 11:00", "2026-11-06 12:00")]
        #expect(entry(split, now: TestData.date("2026-11-04 20:00")).rectangular.after == nil)
    }

    @Test func snapshotAgeThresholds() {
        let events = [
            TestData.event("A", "2026-11-04 15:00", "2026-11-04 16:00"),
            TestData.event("B", "2026-11-06 10:00", "2026-11-06 11:00"),
        ]
        let fetched = TestData.date("2026-11-04 09:12")
        // Exactly 2 hours old is still fine; one second more is stale.
        let exact = entry(events, now: fetched.addingTimeInterval(2 * 3600), fetchedAt: fetched)
        #expect(exact.rectangular.after == "Last one today")
        let stale = entry(events, now: fetched.addingTimeInterval(2 * 3600 + 1), fetchedAt: fetched)
        #expect(stale.rectangular.after == "As of 9:12")
        // The other two families keep their data until 24 hours, then give up.
        #expect(stale.inline == "15:00 A")
        #expect(stale.circularText == "15:00")

        let day = fetched.addingTimeInterval(24 * 3600)
        let atDay = entry(events, now: day, fetchedAt: fetched)
        #expect(atDay.inline == "Fri 10:00 B")
        // At exactly 24 hours the rectangular family still shows its event, dated.
        #expect(atDay.rectangular.title == "B")
        #expect(atDay.rectangular.after == "As of 9:12")
        let expired = entry(events, now: day.addingTimeInterval(1), fetchedAt: fetched)
        #expect(expired.inline == "Open to update")
        #expect(expired.circularText == "symbol")
    }

    @Test func rectangularStopsNamingAnEventPastTwentyFourHours() {
        let events = [
            TestData.event("A", "2026-11-04 15:00", "2026-11-04 16:00"),
            TestData.event("B", "2026-11-04 17:00", "2026-11-04 18:00"),
        ]
        let fetched = TestData.date("2026-11-04 09:12")
        // In progress, signed out and overlapping, so every line 2 and line 3 form is on
        // offer: none of them draws once the data is over a day old.
        let overlapping = events + [TestData.event("C", "2026-11-05 10:00", "2026-11-05 12:00")]
        for now in ["2026-11-05 09:13", "2026-11-05 10:30", "2026-11-06 08:00"] {
            let shown = entry(overlapping, now: TestData.date(now), fetchedAt: fetched, signedOut: 2)
            #expect(shown.rectangular.title == "Open to update", "\(now)")
            #expect(shown.rectangular.when == nil, "\(now)")
            #expect(shown.rectangular.after == nil, "\(now)")
            // Unset, because the widget reads a set one as an event on screen and redacts it.
            #expect(shown.rectangular.url == nil, "\(now)")
            #expect(shown.inline == "Open to update", "\(now)")
            #expect(shown.circular == .symbol, "\(now)")
            #expect(shown.url == DayLink.day(CivilDate(TestData.date(now), in: calendar)).url, "\(now)")
            #expect(!shown.rectangular.afterNamesEvent)
        }
        // Fresh data right after: the event is back.
        let fresh = entry(overlapping, now: TestData.date("2026-11-05 09:13"), fetchedAt: TestData.date("2026-11-05 09:13"))
        #expect(fresh.rectangular.title == "C")
    }

    @Test func lineThreeNamesAnEventOnlyWhenItDoes() {
        func lines(_ after: String?) -> RectangularLines {
            RectangularLines(title: "T", after: after)
        }
        #expect(lines("Also 14:30 Acme sync").afterNamesEvent)
        #expect(lines("11:00 Design review").afterNamesEvent)
        #expect(lines("9:30 Standup").afterNamesEvent)
        #expect(lines("9:30 AM Standup").afterNamesEvent)
        // A count at the start of a state is not a time.
        #expect(!lines("1 account signed out").afterNamesEvent)
        #expect(!lines("2 accounts signed out").afterNamesEvent)
        #expect(!lines("As of 9:12").afterNamesEvent)
        #expect(!lines("Last one today").afterNamesEvent)
        #expect(!lines(nil).afterNamesEvent)
    }

    // MARK: States

    @Test func nothingAhead() {
        let shown = entry([], now: TestData.date("2026-11-04 12:00"))
        #expect(shown.inline == "Nothing in the next 7 days")
        #expect(shown.rectangular.title == "Nothing in the next 7 days")
        #expect(shown.rectangular.when == nil)
        #expect(shown.rectangular.after == nil)
        #expect(shown.rectangular.url == nil)
        #expect(shown.circular == .symbol)
        #expect(shown.url == DayLink.day(TestData.day("2026-11-04")).url)

        // Line 3 still carries age and sign-in.
        let signedOut = entry([], now: TestData.date("2026-11-04 12:00"), signedOut: 1)
        #expect(signedOut.rectangular.after == "1 account signed out")
        let old = entry(
            [], now: TestData.date("2026-11-04 12:00"), fetchedAt: TestData.date("2026-11-04 09:12"),
            signedOut: 1)
        #expect(old.rectangular.after == "As of 9:12")
    }

    @Test func noAccount() {
        let shown = noAccountWidgetEntry(now: TestData.date("2026-11-04 12:00"), calendar: calendar)
        #expect(shown.inline == "Add a Google account")
        #expect(shown.rectangular.title == "Add a Google account")
        #expect(shown.rectangular.when == nil)
        #expect(shown.rectangular.after == nil)
        #expect(shown.circular == .symbol)
    }

    @Test func theSeventhDayAheadIsTheLastOne() {
        let now = TestData.date("2026-11-04 12:00")
        // 11 November 23:00 is the end of the seventh day ahead; 12 November is the eighth.
        let inside = [TestData.event("Inside", "2026-11-11 23:00", "2026-11-11 23:30")]
        #expect(entry(inside, now: now).inline == "Wed 23:00 Inside")
        let outside = [TestData.event("Outside", "2026-11-12 00:30", "2026-11-12 01:00")]
        #expect(entry(outside, now: now).inline == "Nothing in the next 7 days")
    }

    @Test func eventsThatNeverCount() throws {
        let now = TestData.date("2026-11-04 08:00")
        let hidden = [
            TestData.event("Declined", "2026-11-04 09:00", "2026-11-04 10:00", response: .declined),
            TestData.event("Cancelled", "2026-11-04 09:00", "2026-11-04 10:00", status: .cancelled),
            TestData.event("Free", "2026-11-04 09:00", "2026-11-04 10:00", free: true),
            TestData.event("Focus", "2026-11-04 09:00", "2026-11-04 10:00", kind: .focusTime),
            TestData.event("Away", "2026-11-04 09:00", "2026-11-04 10:00", kind: .outOfOffice),
            TestData.event("Place", "2026-11-04 09:00", "2026-11-04 10:00", kind: .workingLocation),
            TestData.event("Birthday", "2026-11-04 09:00", "2026-11-04 10:00", kind: .birthday),
            TestData.allDay("Trip", "2026-11-04", "2026-11-05"),
        ]
        #expect(entry(hidden, now: now).inline == "Nothing in the next 7 days")
        let shown = hidden + [
            TestData.event("Flight", "2026-11-04 20:00", "2026-11-04 22:00", kind: .fromGmail)
        ]
        #expect(entry(shown, now: now).inline == "20:00 Flight")
    }

    // MARK: Locales

    @Test func twelveHourLocaleStacksThePeriod() {
        let us = TestData.calendar("America/New_York", locale: "en_US")
        let events = [
            TestData.event("Standup", "2026-11-05 09:30", "2026-11-05 09:45", zone: us),
            TestData.event("Dinner", "2026-11-04 19:00", "2026-11-04 20:00", zone: us),
        ]
        let now = TestData.date("2026-11-04 12:00", in: us)
        let dinner = entry(events, now: now, calendar: us)
        #expect(TestData.plain(dinner.inline) == "7:00 PM Dinner")
        #expect(dinner.circular == .time("7:00", weekday: nil, period: "PM"))

        let morning = entry(events, now: TestData.date("2026-11-04 21:00", in: us), calendar: us)
        #expect(morning.circular == .time("9:30", weekday: "THU", period: "AM"))
        #expect(TestData.plain(morning.inline) == "Thu 9:30 AM Standup")
        #expect(TestData.plain(morning.rectangular.when?.text ?? "") == "Tomorrow 9:30 AM")

        // Noon and midnight read 12, never 0.
        let noon = [TestData.event("Noon", "2026-11-04 12:15", "2026-11-04 13:00", zone: us)]
        #expect(entry(noon, now: TestData.date("2026-11-04 08:00", in: us), calendar: us).circular
            == .time("12:15", weekday: nil, period: "PM"))
        let midnight = [TestData.event("Late", "2026-11-05 00:10", "2026-11-05 01:00", zone: us)]
        #expect(entry(midnight, now: TestData.date("2026-11-04 08:00", in: us), calendar: us).circular
            == .time("12:10", weekday: "THU", period: "AM"))
    }

    // MARK: Staying correct

    @Test func entriesFallWhereTheContentChanges() throws {
        let events = try TestData.inventedEvents()
        let now = TestData.wednesday("12:10")
        let timeline = widgetTimeline(
            events: events, now: now, fetchedAt: now, signedOutAccounts: 0, calendar: calendar)
        #expect(timeline.first?.date == now)
        #expect(timeline.map(\.date) == timeline.map(\.date).sorted())
        #expect(Set(timeline.map(\.date)).count == timeline.count)

        let dates = Set(timeline.map(\.date))
        // Every start and end of the next 24 hours, here the events of the afternoon.
        for time in ["12:30", "13:30", "14:00", "15:00", "16:00", "17:00"] {
            #expect(dates.contains(TestData.wednesday(time)), "missing \(time)")
        }
        // An hour before a start, when line 2 begins counting down.
        #expect(dates.contains(TestData.wednesday("13:00")))
        // Local midnight.
        #expect(dates.contains(TestData.date("2026-11-05 00:00")))
        // Nothing beyond 24 hours.
        #expect(timeline.allSatisfy { $0.date <= now.addingTimeInterval(24 * 3600) })
    }

    @Test func everyEntryIsWhatItsOwnDateWouldShow() throws {
        let events = try TestData.inventedEvents()
        let now = TestData.wednesday("07:50")
        let timeline = widgetTimeline(
            events: events, now: now, fetchedAt: now, signedOutAccounts: 1, calendar: calendar)
        #expect(timeline.count > 10)
        for entry in timeline.dropFirst() {
            let fresh = widgetTimeline(
                events: events, now: entry.date, fetchedAt: now, signedOutAccounts: 1,
                calendar: calendar)[0]
            #expect(entry == fresh, "entry at \(entry.date) is stale")
        }
    }

    @Test func changesCloserThanFiveMinutesShareTheLaterEntry() {
        // A ends at 10:00, B starts at 10:03: one entry, at 10:03, so the widget is never
        // ahead of the data and never more than 5 minutes behind it.
        let events = [
            TestData.event("A", "2026-11-04 09:00", "2026-11-04 10:00"),
            TestData.event("B", "2026-11-04 10:03", "2026-11-04 11:00"),
        ]
        let now = TestData.date("2026-11-04 09:30")
        let timeline = widgetTimeline(
            events: events, now: now, fetchedAt: now, signedOutAccounts: 0, calendar: calendar)
        let dates = timeline.map(\.date)
        #expect(dates.contains(TestData.date("2026-11-04 10:03")))
        #expect(!dates.contains(TestData.date("2026-11-04 10:00")))
        // A change right after now is not merged into now itself.
        let soon = widgetTimeline(
            events: events, now: TestData.date("2026-11-04 09:58"), fetchedAt: now, signedOutAccounts: 0,
            calendar: calendar)
        #expect(soon.map(\.date).contains(TestData.date("2026-11-04 10:03")))
        // Changes 5 minutes apart or more keep their own entries.
        let apart = [
            TestData.event("A", "2026-11-04 09:00", "2026-11-04 10:00"),
            TestData.event("B", "2026-11-04 10:05", "2026-11-04 11:00"),
        ]
        let two = widgetTimeline(
            events: apart, now: now, fetchedAt: now, signedOutAccounts: 0, calendar: calendar
        ).map(\.date)
        #expect(two.contains(TestData.date("2026-11-04 10:00")))
        #expect(two.contains(TestData.date("2026-11-04 10:05")))
    }

    @Test func entriesAtTheBoundariesOfAge() {
        let events = [TestData.event("A", "2026-11-06 09:00", "2026-11-06 10:00")]
        let fetched = TestData.date("2026-11-04 09:12")
        let now = TestData.date("2026-11-04 10:00")
        let timeline = widgetTimeline(
            events: events, now: now, fetchedAt: fetched, signedOutAccounts: 0, calendar: calendar)
        // As of 9:12 appears just after 11:12, and Open to update just after 09:12 tomorrow.
        let afterTwoHours = timeline.first { $0.date > TestData.date("2026-11-04 11:12") }
        #expect(afterTwoHours?.rectangular.after == "As of 9:12")
        let atDay = widgetTimeline(
            events: events, now: TestData.date("2026-11-04 20:00"), fetchedAt: fetched,
            signedOutAccounts: 0, calendar: calendar)
        let last = atDay.last
        #expect(last?.inline == "Open to update")
        #expect(last?.circular == .symbol)
        // The rectangular family switches at the same entry, not later.
        #expect(last?.rectangular == RectangularLines(title: "Open to update"))
    }

    // MARK: Midnight and daylight saving

    @Test func midnightEntryIsLocalMidnightNotTwentyFourHours() {
        let events: [Event] = []
        // The night the clocks go back (25 hours): the midnight inside the horizon is
        // 00:00 CEST, an hour before the same wall time 24 hours on.
        let now = TestData.date("2026-10-24 22:00")
        let timeline = widgetTimeline(
            events: events, now: now, fetchedAt: now.addingTimeInterval(-600), signedOutAccounts: 0,
            calendar: calendar)
        let midnight = TestData.date("2026-10-25 00:00")
        #expect(timeline.map(\.date).contains(midnight))
        let after = timeline.first { $0.date == midnight }
        #expect(after?.url == DayLink.day(TestData.day("2026-10-25")).url)
        // 24 hours after 22:00 CEST is 21:00 CET, so the next midnight is out of range.
        #expect(timeline.map(\.date).filter { calendar.component(.hour, from: $0) == 0 }.count == 1)

        // The day after the clocks went back, midnight is 00:00 CET.
        let sunday = TestData.date("2026-10-25 12:00")
        let next = widgetTimeline(
            events: events, now: sunday, fetchedAt: sunday, signedOutAccounts: 0, calendar: calendar)
        #expect(next.map(\.date).contains(TestData.date("2026-10-26 00:00")))
    }

    @Test func springForwardKeepsWallClockTimes() {
        // 29 March 2026: 02:00 CET jumps to 03:00 CEST, a 23-hour day.
        let events = [
            TestData.event("Morning", "2026-03-29 09:30", "2026-03-29 10:00"),
            TestData.event("After", "2026-03-30 09:30", "2026-03-30 10:00"),
        ]
        let now = TestData.date("2026-03-29 12:00")
        let timeline = widgetTimeline(
            events: events, now: now, fetchedAt: now, signedOutAccounts: 0, calendar: calendar)
        #expect(timeline[0].inline == "Mon 9:30 After")
        #expect(timeline.map(\.date).contains(TestData.date("2026-03-30 00:00")))
        let early = widgetTimeline(
            events: events, now: TestData.date("2026-03-29 01:30"), fetchedAt: TestData.date("2026-03-29 01:30"),
            signedOutAccounts: 0, calendar: calendar)
        #expect(early[0].inline == "9:30 Morning")
    }
}
