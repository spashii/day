import Foundation
import Testing

@testable import DayCore

/// The five classification rules of the month marks, first match wins, on the invented week
/// and on one event at a time.
struct MonthMarkTests {
    let calendar = TestData.amsterdam

    func mark(
        _ event: Event, account: Account = TestData.work, in info: CalendarInfo? = nil,
        calendar: Calendar? = nil
    ) -> MonthMark {
        let info = info ?? (account.id == TestData.work.id ? TestData.workCalendar : TestData.personalCalendar)
        return monthMark(event, account: account, calendar: info, in: calendar ?? self.calendar)
    }

    // MARK: The invented week

    struct Case: Sendable, CustomTestStringConvertible {
        var title: String
        var day: String
        var kind: EventKind = .default
        var expected: MonthMark

        var testDescription: String { "\(title) on \(day) is \(expected)" }
    }

    static let inventedWeek: [Case] = [
        Case(title: "Flight to Lisbon (TP 671)", day: "2026-11-02", kind: .fromGmail, expected: .bar),
        Case(title: "Office", day: "2026-11-02", kind: .workingLocation, expected: .hidden),
        Case(title: "Lisbon", day: "2026-11-03", expected: .bar),
        Case(title: "Lisbon", day: "2026-11-03", kind: .workingLocation, expected: .hidden),
        Case(title: "Standup", day: "2026-11-04", expected: .dot),
        Case(title: "Lunch with Maya", day: "2026-11-04", expected: .titled),
        Case(title: "Investor call", day: "2026-11-04", expected: .titled),
        Case(title: "Vendor demo", day: "2026-11-04", expected: .hidden),
        Case(title: "Focus time", day: "2026-11-05", kind: .focusTime, expected: .hidden),
        Case(title: "Quick sync on pricing", day: "2026-11-05", expected: .dot),
        Case(title: "Flight to Amsterdam (TP 674)", day: "2026-11-05", kind: .fromGmail, expected: .bar),
        Case(title: "Out of office", day: "2026-11-06", kind: .outOfOffice, expected: .hidden),
        Case(title: "Investor call", day: "2026-11-06", expected: .titled),
        Case(title: "Dentist", day: "2026-11-07", expected: .titled),
        Case(title: "Dinner with Maya", day: "2026-11-07", expected: .titled),
        Case(title: "Noor's birthday", day: "2026-11-08", kind: .birthday, expected: .hidden),
        Case(title: "Out of office", day: "2026-11-09", kind: .outOfOffice, expected: .bar),
        Case(title: "Board call", day: "2026-11-09", expected: .titled),
        Case(title: "Standup", day: "2026-11-09", expected: .hidden),
        Case(title: "Sint Maarten", day: "2026-11-11", expected: .bar),
        Case(title: "Coffee with Ana", day: "2026-11-17", expected: .titled),
        Case(title: "Pricing check-in", day: "2026-11-18", expected: .dot),
        Case(title: "Quarterly planning", day: "2026-11-19", expected: .titled),
        Case(title: "Berlin", day: "2026-11-23", expected: .bar),
        Case(title: "Team offsite", day: "2026-11-25", expected: .bar),
        Case(title: "Design review", day: "2026-11-26", expected: .hidden),
        Case(title: "Contract call with Northwind", day: "2026-11-26", expected: .titled),
        Case(title: "Sinterklaas", day: "2026-12-05", expected: .bar),
    ]

    @Test(arguments: inventedWeek)
    func theInventedWeek(_ c: Case) throws {
        let fixture = try TestData.loadFixture()
        let accounts = Dictionary(uniqueKeysWithValues: fixture.accounts.map { ($0.id, $0) })
        let calendars = Dictionary(uniqueKeysWithValues: fixture.calendars.map { ($0.id, $0) })
        let day = TestData.day(c.day)
        let event = try #require(
            merged(fixture.events).first {
                $0.title == c.title && $0.kind == c.kind
                    && coveredDays($0, calendar: fixture.calendar).contains(day)
            })
        let result = monthMark(
            event, account: accounts[event.account]!, calendar: calendars[event.id.calendar]!,
            in: fixture.calendar)
        #expect(result == c.expected)
    }

    @Test func holidayCalendarsAreBars() throws {
        let fixture = try TestData.loadFixture()
        let info = try #require(fixture.calendars.first { $0.name == "Holidays in the Netherlands" })
        #expect(info.isHoliday)
        let event = try #require(fixture.events.first { $0.title == "Sint Maarten" })
        let account = try #require(fixture.accounts.first { $0.id == event.account })
        #expect(monthMark(event, account: account, calendar: info, in: fixture.calendar) == .bar)
    }

    // MARK: Rule 1, hidden

    @Test(arguments: ["cancelled", "declined", "workingLocation", "focusTime", "birthday", "recurringOutOfOffice"])
    func hidden(_ why: String) {
        var event = TestData.event("X", "2026-11-04 10:00", "2026-11-04 11:00", attendees: 4)
        switch why {
        case "cancelled": event.status = .cancelled
        case "declined": event.response = .declined
        case "workingLocation": event.kind = .workingLocation
        case "focusTime": event.kind = .focusTime
        case "birthday": event.kind = .birthday
        case "recurringOutOfOffice":
            event.kind = .outOfOffice
            event.isRecurring = true
        default: Issue.record("unknown case")
        }
        #expect(mark(event) == .hidden)
    }

    @Test func hiddenBeatsEveryOtherRule() {
        let trip = TestData.allDay("Trip", "2026-11-04", "2026-11-08")
        var declined = trip
        declined.response = .declined
        #expect(mark(declined) == .hidden)
        var cancelled = trip
        cancelled.status = .cancelled
        #expect(mark(cancelled) == .hidden)
        var birthday = trip
        birthday.kind = .birthday
        #expect(mark(birthday) == .hidden)
        // A one-off out of office is a bar; the same recurring is hidden, not a dot.
        var away = TestData.event("Away", "2026-11-04 09:00", "2026-11-04 17:00", kind: .outOfOffice)
        #expect(mark(away) == .bar)
        away.isRecurring = true
        #expect(mark(away) == .hidden)
    }

    // MARK: Rule 2, bar

    @Test func allDayOneOffsAreBars() {
        #expect(mark(TestData.allDay("Berlin", "2026-11-23", "2026-11-24")) == .bar)
        #expect(mark(TestData.allDay("Berlin", "2026-11-23", "2026-11-26")) == .bar)
    }

    @Test func multiDayTimedOneOffsAreBarsOnlyPastFiveAM() {
        // Ending at exactly 05:00 is not past 05:00; a long timed event is a titled line.
        let atFive = TestData.event("Red-eye", "2026-11-10 22:00", "2026-11-11 05:00")
        #expect(mark(atFive) == .titled)
        let pastFive = TestData.event("Red-eye", "2026-11-10 22:00", "2026-11-11 05:01")
        #expect(mark(pastFive) == .bar)
        let long = TestData.event("Conference", "2026-11-10 09:00", "2026-11-12 17:00")
        #expect(mark(long) == .bar)
    }

    @Test func outOfOfficeAndGmailOneOffsAreBarsEvenWithinADay() {
        #expect(mark(TestData.event("Away", "2026-11-10 13:00", "2026-11-10 14:00", kind: .outOfOffice)) == .bar)
        #expect(mark(TestData.event("Flight", "2026-11-10 09:00", "2026-11-10 10:00", kind: .fromGmail)) == .bar)
    }

    // MARK: Rule 3, dot

    @Test func recurrenceBeatsEverythingBelowTheHiddenRule() {
        var allDay = TestData.allDay("Trash day", "2026-11-10", "2026-11-11")
        allDay.isRecurring = true
        #expect(mark(allDay) == .dot)
        let multi = TestData.event(
            "Series", "2026-11-10 22:00", "2026-11-11 07:00", recurring: true, attendees: 3,
            domains: ["other.example"], location: "Somewhere")
        #expect(mark(multi) == .dot)
        let gmail = TestData.event("Weekly flight", "2026-11-10 09:00", "2026-11-10 10:00", kind: .fromGmail, recurring: true)
        #expect(mark(gmail) == .dot)
        // Even on a personal account, with an outside guest and at a place.
        let personal = TestData.event(
            "Climbing", "2026-11-10 19:00", "2026-11-10 21:30", account: TestData.personal,
            recurring: true, attendees: 4, domains: ["other.example"], location: "Gym")
        #expect(mark(personal, account: TestData.personal) == .dot)
    }

    // MARK: Rule 4, titled

    @Test func anOutsideGuestTitlesAOneOff() {
        let outside = TestData.event(
            "Investor call", "2026-11-10 14:00", "2026-11-10 14:30", attendees: 3, domains: ["acme.com", "harbor.example"])
        #expect(mark(outside) == .titled)
        // Domains compare without regard to case.
        let shouting = TestData.event(
            "Call", "2026-11-10 14:00", "2026-11-10 14:30", attendees: 3, domains: ["ACME.COM"])
        #expect(mark(shouting) == .dot)
    }

    @Test func aPersonalAccountTitlesEveryTimedOneOff() {
        let short = TestData.event(
            "Haircut", "2026-11-10 14:00", "2026-11-10 14:30", account: TestData.personal)
        #expect(mark(short, account: TestData.personal) == .titled)
        let gmailToo = Account(id: AccountID("G"), email: "you@googlemail.com", addedAt: Date(timeIntervalSince1970: 0))
        #expect(mark(short, account: gmailToo) == .titled)
    }

    @Test func aPlaceTitlesAOneOffButALinkDoesNot() {
        func with(_ location: String?) -> MonthMark {
            mark(TestData.event("Call", "2026-11-10 14:00", "2026-11-10 14:30", location: location))
        }
        #expect(with("Café Nord") == .titled)
        #expect(with("Café Nord\nRua Inventada 4, Lisboa") == .titled)
        #expect(with("Room 4.12") == .titled)
        #expect(with("https://zoom.us/j/123456789") == .dot)
        #expect(with("meet.google.com/abc-defg-hij") == .dot)
        #expect(with("www.example.com/room") == .dot)
        #expect(with("") == .dot)
        #expect(with(nil) == .dot)
    }

    @Test func twoHoursOrMoreTitlesAOneOff() {
        func hours(_ end: String) -> MonthMark {
            mark(TestData.event("Workshop", "2026-11-10 10:00", "2026-11-10 \(end)", attendees: 4, domains: ["acme.com"]))
        }
        #expect(hours("11:59") == .dot)
        #expect(hours("12:00") == .titled)
        #expect(hours("13:00") == .titled)
    }

    // MARK: Rule 5, dots for short internal calls
    //
    // This is the whole of rule 5, a settled choice. It pins the marked branch at the end of
    // monthMark: without it every timed one-off is a titled line.

    @Test func shortInternalOneOffsAreDots() {
        let call = TestData.event(
            "Pricing check-in", "2026-11-10 10:00", "2026-11-10 10:30", response: .accepted, attendees: 3,
            domains: ["acme.com"])
        #expect(mark(call) == .dot)
        // One-offs without a guest list, short and without a place, are dots too.
        #expect(mark(TestData.event("Solo", "2026-11-10 10:00", "2026-11-10 10:30")) == .dot)
    }

    @Test func theSameCallOnAPersonalAccountIsATitledLine() {
        // Rule 4 again: the account is the only difference.
        let work = TestData.event("Call", "2026-11-10 10:00", "2026-11-10 10:30", attendees: 3, domains: ["acme.com"])
        #expect(mark(work) == .dot)
        #expect(mark(work, account: TestData.personal) == .titled)
    }

    // MARK: Days covered

    @Test func multiDayAcrossTheClocksChanging() {
        // The night of 25 October the clocks go back: 22:00 CEST Saturday to 04:30 CET
        // Sunday is under 05:00 by the wall clock, so one day, a titled line (it is long).
        let backOne = TestData.event("Night shift", "2026-10-24 22:00", "2026-10-25 04:30")
        #expect(mark(backOne) == .titled)
        #expect(coveredDays(backOne, calendar: calendar).count == 1)
        // 05:30 is past 05:00: two days, a bar.
        let backTwo = TestData.event("Night shift", "2026-10-24 22:00", "2026-10-25 05:30")
        #expect(mark(backTwo) == .bar)
        // The night of 29 March the clocks go forward: 23:00 CET to 05:30 CEST is past 05:00.
        let forward = TestData.event("Night shift", "2026-03-28 23:00", "2026-03-29 05:30")
        #expect(mark(forward) == .bar)
        let forwardEarly = TestData.event("Night shift", "2026-03-28 23:00", "2026-03-29 04:30")
        #expect(mark(forwardEarly) == .titled)
    }
}
