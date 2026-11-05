import Foundation
import Testing

@testable import DayCore

/// Section 7 of the brief: the summary tables, every bullet of "other days", and each rule of
/// sentence one and sentence two, with the edge cases the rules leave to judgment.
struct SummaryTests {
    let calendar = TestData.amsterdam

    func summary(_ day: String, now: Date, _ events: [Event], calendar: Calendar? = nil) -> Summary {
        summarize(
            day: TestData.day(day), events: events, now: now, calendar: calendar ?? self.calendar)
    }

    /// A one-off with no guests on 10 November unless said otherwise. Tests set what they
    /// are about.
    func e(
        _ title: String, _ from: String, _ to: String, day: String = "2026-11-10",
        recurring: Bool = false, attendees: Int = 0, free: Bool = false
    ) -> Event {
        TestData.event(
            title, "\(day) \(from)", "\(day) \(to)", recurring: recurring, response: attendees > 1 ? .accepted : .none,
            attendees: attendees, free: free)
    }

    let morning = TestData.date("2026-11-10 08:00")

    // MARK: The invented Wednesday

    struct Row: Sendable, CustomTestStringConvertible {
        var time: String
        var first: String
        var second: String?

        var testDescription: String { time }
    }

    static let wednesday: [Row] = [
        Row(time: "07:50", first: "Six events, 9:30 to 17:00.",
            second: "Investor call and Acme sync overlap at 14:30."),
        Row(time: "12:10", first: "Four to go, done at 17:00.",
            second: "Investor call and Acme sync overlap at 14:30."),
        Row(time: "15:10", first: "One to go: Weekly planning at 16:00.", second: nil),
        Row(time: "16:20", first: "Last one: Weekly planning, until 17:00.", second: nil),
        Row(time: "17:30", first: "Done for today.", second: "Tomorrow starts at 9:30 with Standup."),
    ]

    @Test(arguments: wednesday)
    func theInventedWednesday(_ row: Row) throws {
        let events = try TestData.inventedEvents()
        let result = summary("2026-11-04", now: TestData.wednesday(row.time), events)
        #expect(result == Summary(first: row.first, second: row.second))
    }

    @Test func theFixtureHasOneInvestorCallBecauseOfMerging() throws {
        // Unmerged, the same meeting overlaps itself: the bug the merge guard exists for.
        let fixture = try TestData.loadFixture()
        let unmerged = fixture.events.filter { !$0.isAllDay }
        let bad = summary("2026-11-04", now: TestData.wednesday("07:50"), unmerged)
        #expect(bad.first == "Seven events, 9:30 to 17:00.")
        #expect(bad.second == "Investor call and Investor call overlap at 14:00.")
        let good = summary("2026-11-04", now: TestData.wednesday("07:50"), fixture.visibleEvents())
        #expect(good.first == "Six events, 9:30 to 17:00.")
    }

    // MARK: Other days

    @Test func nothingScheduled() throws {
        let events = try TestData.inventedEvents()
        // A Saturday with nothing on it, and today with nothing and nothing tomorrow.
        #expect(
            summary("2026-11-14", now: TestData.wednesday("12:10"), events)
                == Summary(first: "Nothing scheduled."))
        #expect(summary("2026-11-10", now: morning, []) == Summary(first: "Nothing scheduled."))
    }

    @Test func emptyDayMayStillSayWhatTomorrowStartsWith() {
        let events = [e("Dentist", "09:00", "10:00", day: "2026-11-11")]
        #expect(
            summary("2026-11-10", now: morning, events)
                == Summary(first: "Nothing scheduled.", second: "Tomorrow starts at 9:00 with Dentist."))
        // Only today says what tomorrow starts with; another empty day does not.
        #expect(summary("2026-11-12", now: morning, events) == Summary(first: "Nothing scheduled."))
    }

    @Test func oneEvent() {
        let events = [e("Dentist", "14:30", "15:15")]
        #expect(
            summary("2026-11-10", now: morning, events)
                == Summary(first: "One event: Dentist at 14:30."))
    }

    @Test func twoEventsOnTheSaturday() throws {
        let events = try TestData.inventedEvents()
        #expect(
            summary("2026-11-07", now: TestData.wednesday("12:10"), events)
                == Summary(first: "Dentist at 14:30 and Dinner with Maya at 19:00."))
    }

    @Test func fourMeetingsWithOneOneOff() throws {
        let events = try TestData.inventedEvents()
        #expect(
            summary("2026-11-06", now: TestData.wednesday("12:10"), events)
                == Summary(
                    first: "Four meetings, 10:00 to 16:00.",
                    second: "Investor call at 15:00 is the only one-off."))
    }

    @Test func threeMeetingsWithAFreeBlock() throws {
        let events = try TestData.inventedEvents()
        #expect(
            summary("2026-11-03", now: TestData.date("2026-11-02 08:00"), events)
                == Summary(
                    first: "Three meetings, 13:00 to 18:00.", second: "Free from 14:00 to 16:00."))
    }

    @Test func outOfOfficeUntilFridayWithTheBoardCallStillOn() throws {
        let events = try TestData.inventedEvents()
        #expect(
            summary("2026-11-09", now: TestData.wednesday("12:10"), events)
                == Summary(
                    first: "Out of office until Friday.", second: "Board call at 15:00 is still on."))
    }

    @Test func doneForTodayWithNothingTomorrow() {
        let events = [e("Dentist", "09:00", "10:00")]
        #expect(
            summary("2026-11-10", now: TestData.date("2026-11-10 12:00"), events)
                == Summary(first: "Done for today."))
    }

    @Test func aPastDayIsListedNotCounted() throws {
        let events = try TestData.inventedEvents()
        // Tuesday, seen on Wednesday: nothing is ahead, so no sentence two.
        #expect(
            summary("2026-11-03", now: TestData.wednesday("12:10"), events)
                == Summary(first: "Three meetings, 13:00 to 18:00."))
    }

    @Test func thursdayInTheFixtureEndsAfterMidnight() throws {
        // The flight lands at 00:15, which is before 05:00, so it stays on Thursday and keeps
        // its true end. Nothing of it is on Friday. The range names Friday, because 9:30 to
        // 0:15 would read as an end before the start.
        let events = try TestData.inventedEvents()
        let result = summary("2026-11-05", now: TestData.wednesday("12:10"), events)
        #expect(result.first == "Four events, 9:30 to Fri 0:15.")
        #expect(
            result.second
                == "One-offs: Quick sync on pricing at 15:30 and Flight to Amsterdam (TP 674) at 20:30.")
        #expect(
            summary("2026-11-06", now: TestData.wednesday("12:10"), events).first
                == "Four meetings, 10:00 to 16:00.")
    }

    // MARK: Sentence one

    @Test func listingNamesTheNounByGuests() {
        let meetings = (0..<3).map {
            e("M\($0)", String(format: "%02d:00", 9 + $0), String(format: "%02d:30", 9 + $0), recurring: true, attendees: 3)
        }
        #expect(summary("2026-11-10", now: morning, meetings).first == "Three meetings, 9:00 to 11:30.")
        // One without a guest list turns every noun to events.
        let mixed = meetings + [e("Solo", "13:00", "13:30")]
        #expect(summary("2026-11-10", now: morning, mixed).first == "Four events, 9:00 to 13:30.")
    }

    @Test func countsAreWordsUnderTenAndNumeralsAfter() {
        func events(_ n: Int) -> [Event] {
            (0..<n).map { e("E\($0)", String(format: "%02d:00", 8 + $0), String(format: "%02d:30", 8 + $0), recurring: true) }
        }
        #expect(summary("2026-11-10", now: TestData.date("2026-11-09 08:00"), events(9)).first == "Nine events, 8:00 to 16:30.")
        #expect(summary("2026-11-10", now: TestData.date("2026-11-09 08:00"), events(10)).first == "10 events, 8:00 to 17:30.")
        // The same rule for the to-go count.
        #expect(summary("2026-11-10", now: TestData.date("2026-11-10 08:00"), events(10)).first == "10 to go, done at 17:30.")
        #expect(summary("2026-11-10", now: TestData.date("2026-11-10 08:30"), events(10)).first == "Nine to go, done at 17:30.")
    }

    @Test func toGoCountsWhatHasNotEnded() {
        let events = [
            e("A", "09:00", "10:00", recurring: true),
            e("B", "11:00", "12:00", recurring: true),
            e("C", "13:00", "14:00", recurring: true),
        ]
        // At the first start the day has started: to go, not the list.
        #expect(summary("2026-11-10", now: TestData.date("2026-11-10 08:59"), events).first == "Three events, 9:00 to 14:00.")
        #expect(summary("2026-11-10", now: TestData.date("2026-11-10 09:00"), events).first == "Three to go, done at 14:00.")
        // An event ending exactly now has ended.
        #expect(summary("2026-11-10", now: TestData.date("2026-11-10 10:00"), events).first == "Two to go, done at 14:00.")
        #expect(summary("2026-11-10", now: TestData.date("2026-11-10 12:00"), events).first == "One to go: C at 13:00.")
        #expect(summary("2026-11-10", now: TestData.date("2026-11-10 13:30"), events).first == "Last one: C, until 14:00.")
        #expect(summary("2026-11-10", now: TestData.date("2026-11-10 14:00"), events).first == "Done for today.")
    }

    @Test func oneRemainingThatHasNotStarted() {
        let events = [e("A", "09:00", "10:00"), e("B", "15:00", "16:00")]
        #expect(summary("2026-11-10", now: TestData.date("2026-11-10 11:00"), events).first == "One to go: B at 15:00.")
    }

    @Test func titlesAreExactlyAsWritten() {
        let events = [e("Café ☕ Maya's 1:1", "09:00", "10:00")]
        #expect(summary("2026-11-10", now: morning, events).first == "One event: Café ☕ Maya's 1:1 at 9:00.")
    }

    @Test func twelveHourLocalesWriteTheirOwnTimes() {
        let us = TestData.calendar("America/New_York", locale: "en_US")
        let events = [
            TestData.event("Dentist", "2026-11-10 14:30", "2026-11-10 15:15", zone: us)
        ]
        let result = summary("2026-11-10", now: TestData.date("2026-11-10 08:00", in: us), events, calendar: us)
        #expect(TestData.plain(result.first) == "One event: Dentist at 2:30 PM.")
    }

    // MARK: What is counted

    @Test func countedEventsOnly() {
        let events = [
            e("Counted", "09:00", "10:00"),
            TestData.event("Declined", "2026-11-10 10:00", "2026-11-10 11:00", response: .declined),
            TestData.event("Cancelled", "2026-11-10 11:00", "2026-11-10 12:00", status: .cancelled),
            TestData.event("Focus", "2026-11-10 12:00", "2026-11-10 13:00", kind: .focusTime),
            TestData.event("Place", "2026-11-10 13:00", "2026-11-10 14:00", kind: .workingLocation),
            TestData.event("Away", "2026-11-10 14:00", "2026-11-10 15:00", kind: .outOfOffice),
            TestData.event("Birthday", "2026-11-10 15:00", "2026-11-10 16:00", kind: .birthday),
            TestData.allDay("Trip", "2026-11-10", "2026-11-11"),
            TestData.event("Flight", "2026-11-10 18:00", "2026-11-10 20:00", kind: .fromGmail),
        ]
        #expect(summary("2026-11-10", now: morning, events).first == "Counted at 9:00 and Flight at 18:00.")
    }

    @Test func aFreeEventIsCountedButNeverOverlaps() {
        let events = [
            e("Busy", "09:00", "10:00", recurring: true),
            e("Marked free", "09:30", "10:30", recurring: true, free: true),
        ]
        let result = summary("2026-11-10", now: morning, events)
        #expect(result.first == "Busy at 9:00 and Marked free at 9:30.")
        #expect(result.second == nil)
    }

    // MARK: Out of office

    @Test func outOfOfficeStatesBeatEverythingInSentenceOne() throws {
        let events = try TestData.inventedEvents()
        let now = TestData.wednesday("12:10")
        // Midweek, nothing counted: out of office, not nothing scheduled.
        #expect(summary("2026-11-10", now: now, events) == Summary(first: "Out of office until Friday."))
        // The last day of the block is plainly out of office.
        #expect(summary("2026-11-12", now: now, events) == Summary(first: "Out of office."))
        // Friday is back.
        #expect(summary("2026-11-13", now: now, events).first != "Out of office.")
    }

    @Test func outOfOfficeEndingDecidesWeekdayOrDate() {
        let now = TestData.date("2026-11-04 08:00")
        func block(until end: String) -> [Event] {
            [TestData.allDay("Away", "2026-11-04", end, kind: .outOfOffice)]
        }
        // Return on the 10th: six days out, a weekday.
        #expect(summary("2026-11-04", now: now, block(until: "2026-11-10")).first == "Out of office until Tuesday.")
        // Seven days out reads as today's weekday, so it is a date.
        #expect(summary("2026-11-04", now: now, block(until: "2026-11-11")).first == "Out of office until 11 November.")
        #expect(summary("2026-11-04", now: now, block(until: "2026-11-26")).first == "Out of office until 26 November.")
        // One day: plainly out of office.
        #expect(summary("2026-11-04", now: now, block(until: "2026-11-05")).first == "Out of office.")
    }

    @Test func aTimedOutOfOfficeNamesTheDayItEndsOn() {
        let now = TestData.date("2026-11-04 08:00")
        // Ends Friday at midnight: back on Friday. Ends Friday at noon: until Friday.
        let toMidnight = TestData.event("Away", "2026-11-04 00:00", "2026-11-06 00:00", kind: .outOfOffice)
        #expect(summary("2026-11-04", now: now, [toMidnight]).first == "Out of office until Friday.")
        let toNoon = TestData.event("Away", "2026-11-04 00:00", "2026-11-06 12:00", kind: .outOfOffice)
        #expect(summary("2026-11-04", now: now, [toNoon]).first == "Out of office until Friday.")
        #expect(summary("2026-11-05", now: now, [toMidnight]).first == "Out of office.")
        // Not a whole day: no out of office sentence.
        let partial = TestData.event("Away", "2026-11-04 13:00", "2026-11-04 17:00", kind: .outOfOffice)
        #expect(summary("2026-11-04", now: now, [partial]).first == "Nothing scheduled.")
        // A declined or cancelled block does not make the day out of office.
        let declined = TestData.event(
            "Away", "2026-11-04 00:00", "2026-11-06 00:00", kind: .outOfOffice, response: .declined)
        #expect(summary("2026-11-04", now: now, [declined]).first == "Nothing scheduled.")
    }

    @Test func outOfOfficeSaysTheFirstEventStillOn() {
        let events = [
            TestData.event("Away", "2026-11-04 00:00", "2026-11-06 00:00", kind: .outOfOffice),
            e("Early", "09:00", "10:00", day: "2026-11-04"),
            e("Late", "15:00", "16:00", day: "2026-11-04"),
        ]
        // Early is over by noon, so Late is the one still on.
        #expect(summary("2026-11-04", now: TestData.date("2026-11-04 12:00"), events).second == "Late at 15:00 is still on.")
        #expect(summary("2026-11-04", now: TestData.date("2026-11-04 08:00"), events).second == "Early at 9:00 is still on.")
        // Nothing left, and tomorrow is still out of office with nothing counted: no sentence.
        #expect(summary("2026-11-04", now: TestData.date("2026-11-04 17:00"), events).second == nil)
    }

    // MARK: Sentence two

    @Test func overlapIsNamedUntilItIsOver() {
        // A third event keeps sentence one from naming 14:30 itself.
        let events = [
            e("A", "14:00", "15:00", recurring: true),
            e("B", "14:30", "15:00", recurring: true),
            e("C", "17:00", "17:30", recurring: true),
        ]
        func second(_ now: String) -> String? {
            summary("2026-11-10", now: TestData.date("2026-11-10 \(now)"), events).second
        }
        #expect(second("08:00") == "A and B overlap at 14:30.")
        #expect(second("14:45") == "A and B overlap at 14:30.")
        // At 15:00 both have ended: one to go at 17:00, and the overlap is over.
        #expect(second("15:00") == nil)
        // Back to back is not an overlap.
        let touching = [e("A", "14:00", "15:00", recurring: true), e("B", "15:00", "16:00", recurring: true)]
        #expect(summary("2026-11-10", now: morning, touching).second == nil)
    }

    @Test func theEarliestOverlapIsTheOneNamed() {
        let events = [
            e("Late A", "16:00", "17:00", recurring: true),
            e("Late B", "16:30", "17:30", recurring: true),
            e("Early A", "10:00", "11:00", recurring: true),
            e("Early B", "10:30", "11:30", recurring: true),
        ]
        #expect(summary("2026-11-10", now: morning, events).second == "Early A and Early B overlap at 10:30.")
    }

    @Test func anOverlapThatWouldRepeatATimeFallsThrough() {
        // Sentence one for two events names both starts, so the overlap at 14:30 would say
        // 14:30 twice. Nothing else matches, so there is no sentence two.
        let events = [
            e("A", "14:00", "15:00", recurring: true),
            e("B", "14:30", "15:00", recurring: true),
        ]
        let result = summary("2026-11-10", now: morning, events)
        #expect(result.first == "A at 14:00 and B at 14:30.")
        #expect(result.second == nil)
    }

    @Test(arguments: [
        (1, "O1 at 10:00 is the only one-off."),
        (2, "One-offs: O1 at 10:00 and O2 at 12:00."),
        (3, "One-offs: O1, O2 and 1 more."),
        (4, "One-offs: O1, O2 and 2 more."),
    ])
    func oneOffsWhenSomeButNotAllAreOneOffs(_ count: Int, _ expected: String) {
        let starts = ["10:00", "12:00", "14:00", "16:00"]
        let ends = ["10:30", "12:30", "14:30", "16:30"]
        // Recurring events at both ends keep sentence one from naming the one-offs' times.
        var events = [
            e("R1", "08:00", "08:30", recurring: true), e("R2", "18:00", "18:30", recurring: true),
        ]
        for i in 0..<count {
            events.append(e("O\(i + 1)", starts[i], ends[i]))
        }
        #expect(summary("2026-11-10", now: TestData.date("2026-11-09 08:00"), events).second == expected)
    }

    @Test func allOrNoneOneOffsSaysNothingAboutThem() {
        // Every event a one-off, or none: rule 3 is silent and the free block speaks.
        let all = [e("A", "10:00", "10:30"), e("B", "12:00", "12:30"), e("C", "14:30", "15:00")]
        #expect(summary("2026-11-10", now: morning, all).second == "Free from 10:30 to 12:00.")
        let none = [
            e("A", "10:00", "10:30", recurring: true), e("B", "12:00", "12:30", recurring: true),
            e("C", "12:40", "13:00", recurring: true),
        ]
        #expect(summary("2026-11-10", now: morning, none).second == "Free from 10:30 to 12:00.")
    }

    @Test func aOneOffAlreadyNamedInSentenceOneFallsThrough() {
        let events = [
            e("O", "09:00", "10:00"),
            e("R1", "12:00", "12:30", recurring: true),
            e("R2", "15:00", "15:30", recurring: true),
        ]
        // Sentence one names 9:00; the only-one-off sentence would repeat it.
        let result = summary("2026-11-10", now: morning, events)
        #expect(result.first == "Three events, 9:00 to 15:30.")
        #expect(result.second == "Free from 10:00 to 12:00.")
    }

    @Test func freeBlockIsFromToOrUntil() {
        let events = [
            e("A", "09:00", "10:00", recurring: true),
            e("B", "12:00", "13:00", recurring: true),
            e("C", "17:00", "18:00", recurring: true),
        ]
        // Ahead: the first block.
        #expect(summary("2026-11-10", now: morning, events).second == "Free from 10:00 to 12:00.")
        // Inside it: until.
        let inside = summary("2026-11-10", now: TestData.date("2026-11-10 10:30"), events)
        #expect(inside.first == "Two to go, done at 18:00.")
        #expect(inside.second == "Free until 12:00.")
        // During B the first block is behind: the next one is ahead.
        let later = summary("2026-11-10", now: TestData.date("2026-11-10 12:30"), events)
        #expect(later.second == "Free from 13:00 to 17:00.")
        // After B, inside the next block, but its end is already in sentence one.
        let last = summary("2026-11-10", now: TestData.date("2026-11-10 13:30"), events)
        #expect(last.first == "One to go: C at 17:00.")
        #expect(last.second == nil)
    }

    @Test func freeBlockThresholdIsSixtyMinutes() {
        let sixty = [e("A", "09:00", "10:00", recurring: true), e("B", "11:00", "12:00", recurring: true)]
        // Sentence one for two events names 9:00 and 11:00, so 10:00 to 11:00 repeats 11:00.
        // Use three events so sentence one names the span only.
        let three = sixty + [e("C", "16:00", "17:00", recurring: true)]
        #expect(summary("2026-11-10", now: morning, three).second == "Free from 10:00 to 11:00.")
        let fiftyNine = [
            e("A", "09:00", "10:00", recurring: true), e("B", "10:59", "12:00", recurring: true),
            e("C", "12:30", "13:00", recurring: true),
        ]
        #expect(summary("2026-11-10", now: morning, fiftyNine).second == nil)
    }

    @Test func overlappingEventsAreOneStretchOfBusyTime() {
        // B ends at 10:00 but A runs to 11:00: the 90 minutes between B and C are not free.
        // B is marked free, so the overlap rule leaves it out and the free block speaks.
        let events = [
            e("A", "09:00", "11:00", recurring: true),
            e("B", "09:30", "10:00", recurring: true, free: true),
            e("C", "11:30", "12:00", recurring: true),
            e("D", "14:00", "15:00", recurring: true),
        ]
        let result = summary("2026-11-10", now: morning, events)
        #expect(result.first == "Four events, 9:00 to 15:00.")
        #expect(result.second == "Free from 12:00 to 14:00.")
    }

    @Test func aFreeBlockThatRepeatsASentenceOneTimeFallsThrough() {
        // The listing for two events names both starts, so a gap ending at the second start
        // is skipped rather than said twice.
        let events = [e("A", "13:00", "14:00", recurring: true), e("B", "16:00", "17:00", recurring: true)]
        let result = summary("2026-11-10", now: TestData.date("2026-11-09 08:00"), events)
        #expect(result.first == "A at 13:00 and B at 16:00.")
        #expect(result.second == nil)
    }

    @Test func tomorrowOnlyAfterTheDayIsDone() {
        let events = [
            e("Today", "09:00", "10:00", recurring: true),
            e("Tomorrow's first", "08:30", "09:00", day: "2026-11-11", recurring: true),
            e("Tomorrow's second", "07:00", "07:30", day: "2026-11-11", recurring: true),
        ]
        // Still one to go: no tomorrow.
        #expect(summary("2026-11-10", now: morning, events).second == nil)
        // Done: tomorrow's earliest, not the first in the list.
        #expect(
            summary("2026-11-10", now: TestData.date("2026-11-10 11:00"), events).second
                == "Tomorrow starts at 7:00 with Tomorrow's second.")
    }

    // MARK: Midnight and daylight saving

    @Test func anEventThatRunsPastFiveAMCoversTwoDays() {
        let overnight = TestData.event("Overnight", "2026-11-10 22:00", "2026-11-11 07:00", attendees: 2)
        let now = TestData.date("2026-11-09 08:00")
        #expect(summary("2026-11-10", now: now, [overnight]).first == "One event: Overnight at 22:00.")
        // The second day holds the part after midnight, but the event began on Tuesday, and
        // the line says so rather than reading as an event that starts at midnight.
        #expect(summary("2026-11-11", now: now, [overnight]).first == "One event: Overnight at Tue 22:00.")
        #expect(summary("2026-11-12", now: now, [overnight]).first == "Nothing scheduled.")
    }

    @Test func anEventThatCrossesMidnightButEndsBeforeFiveStaysOnItsDay() {
        let flight = TestData.event("Flight", "2026-11-10 20:30", "2026-11-11 00:15", kind: .fromGmail)
        let now = TestData.date("2026-11-09 08:00")
        #expect(summary("2026-11-10", now: now, [flight]).first == "One event: Flight at 20:30.")
        #expect(summary("2026-11-11", now: now, [flight]).first == "Nothing scheduled.")
        // Ending at exactly 05:00 is not past 05:00.
        let five = TestData.event("Red-eye", "2026-11-10 23:00", "2026-11-11 05:00")
        #expect(summary("2026-11-11", now: now, [five]).first == "Nothing scheduled.")
        let past = TestData.event("Red-eye", "2026-11-10 23:00", "2026-11-11 05:01")
        #expect(summary("2026-11-11", now: now, [past]).first == "One event: Red-eye at Tue 23:00.")
    }

    @Test func aRangeThatEndsAfterMidnightNamesTheDayItEndsOn() {
        let flight = TestData.event("Flight", "2026-11-10 20:30", "2026-11-11 00:15", kind: .fromGmail)
        let day = [
            e("A", "09:30", "10:00", recurring: true), e("B", "11:00", "12:00", recurring: true), flight,
        ]
        // Before the day: the listing carries the day on its end.
        let before = summary("2026-11-10", now: morning, day)
        #expect(before.first == "Three events, 9:30 to Wed 0:15.")
        // Under way: the same word on the finish line.
        let during = summary("2026-11-10", now: TestData.date("2026-11-10 09:45"), day)
        #expect(during.first == "Three to go, done at Wed 0:15.")
        // The last one in progress.
        let last = summary("2026-11-10", now: TestData.date("2026-11-10 21:00"), day)
        #expect(last.first == "Last one: Flight, until Wed 0:15.")
        // A range inside one day never takes the word.
        let plain = summary("2026-11-10", now: morning, Array(day.prefix(2)) + [e("C", "16:00", "17:00", recurring: true)])
        #expect(plain.first == "Three events, 9:30 to 17:00.")
    }

    @Test func anEventCarriedOverFromTheEveningBeforeNamesItsRealStart() {
        // On Wednesday the overnight stay is a span from 00:00, but it began on Tuesday.
        let overnight = TestData.event("Night shift", "2026-11-10 22:00", "2026-11-11 07:00", recurring: true, attendees: 3)
        let day = [
            overnight,
            TestData.event("Standup", "2026-11-11 09:00", "2026-11-11 09:15", recurring: true, attendees: 3),
            TestData.event("Review", "2026-11-11 11:00", "2026-11-11 12:00", recurring: true, attendees: 3),
        ]
        let now = TestData.date("2026-11-09 08:00")
        let result = summary("2026-11-11", now: now, day)
        #expect(result.first == "Three meetings, Tue 22:00 to 12:00.")
        // Two of them: the real start of each, and plain times for the ones on the day.
        let two = summary("2026-11-11", now: now, Array(day.prefix(2)))
        #expect(two.first == "Night shift at Tue 22:00 and Standup at 9:00.")
    }

    @Test func twoEventsCarriedOverBeganOverlappingBeforeMidnight() {
        let a = TestData.event("Night shift", "2026-11-10 22:00", "2026-11-11 07:00", recurring: true)
        let b = TestData.event("Handover", "2026-11-10 23:00", "2026-11-11 08:00", recurring: true)
        let c = TestData.event("Review", "2026-11-11 11:00", "2026-11-11 12:00", recurring: true)
        let result = summary("2026-11-11", now: TestData.date("2026-11-09 08:00"), [a, b, c])
        #expect(result.first == "Three events, Tue 22:00 to 12:00.")
        #expect(result.second == "Night shift and Handover overlap at Tue 23:00.")
    }

    @Test func aRangeBeyondAWeekNamesTheDateNotTheWeekday() {
        // A weekday name seven days out would read as the day itself.
        let retreat = TestData.event("Retreat", "2026-11-10 09:00", "2026-11-17 09:00", recurring: true)
        let more = [
            e("A", "08:00", "08:30", recurring: true), e("B", "08:45", "09:00", recurring: true), retreat,
        ]
        let before = TestData.date("2026-11-09 08:00")
        #expect(summary("2026-11-10", now: before, more).first == "Three events, 8:00 to 17 Nov 9:00.")
        // Six days out still has a weekday.
        let shorter = TestData.event("Retreat", "2026-11-10 09:00", "2026-11-16 09:00", recurring: true)
        #expect(
            summary("2026-11-10", now: before, [more[0], more[1], shorter]).first
                == "Three events, 8:00 to Mon 9:00.")
    }

    @Test func freeTimeIsElapsedTimeAcrossTheClocksChanging() {
        // 29 March 2026: 02:00 CET becomes 03:00 CEST. 01:45 to 03:30 is 45 minutes of
        // elapsed time though the wall clock says 1 h 45 min: not a free block.
        let short = [
            TestData.event("A", "2026-03-29 01:00", "2026-03-29 01:45", recurring: true),
            TestData.event("B", "2026-03-29 03:30", "2026-03-29 04:30", recurring: true),
            TestData.event("C", "2026-03-29 10:00", "2026-03-29 11:00", recurring: true),
        ]
        let now = TestData.date("2026-03-28 08:00")
        #expect(summary("2026-03-29", now: now, short).second == "Free from 4:30 to 10:00.")
        // 01:00 to 03:30 wall clock is 1 h 30 min elapsed.
        let long = [
            TestData.event("A", "2026-03-29 00:00", "2026-03-29 01:00", recurring: true),
            TestData.event("B", "2026-03-29 03:30", "2026-03-29 04:00", recurring: true),
            TestData.event("C", "2026-03-29 20:00", "2026-03-29 21:00", recurring: true),
        ]
        #expect(summary("2026-03-29", now: now, long).second == "Free from 1:00 to 3:30.")
        #expect(Formatting.duration(
            TestData.date("2026-03-29 03:30").timeIntervalSince(TestData.date("2026-03-29 01:00"))) == "1 h 30 min")
    }
}
