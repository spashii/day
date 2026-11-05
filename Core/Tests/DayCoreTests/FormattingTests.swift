import Foundation
import Testing

@testable import DayCore

/// Section 13 and the copy tables: counts, times, durations, day and month titles, and the
/// short lines the sheet and the Day list share.
struct FormattingTests {
    let calendar = TestData.amsterdam
    let us = TestData.calendar("America/New_York", locale: "en_US")

    // MARK: Counts

    static let countCases: [(Int, String)] = [
        (1, "one"), (2, "two"), (5, "five"), (9, "nine"), (10, "10"), (11, "11"), (120, "120"),
    ]

    @Test(arguments: countCases)
    func countsAreWordsUnderTen(_ n: Int, _ text: String) {
        #expect(Formatting.count(n) == text)
    }

    @Test func capitalizedCounts() {
        #expect(Formatting.countCapitalized(1) == "One")
        #expect(Formatting.countCapitalized(6) == "Six")
        #expect(Formatting.countCapitalized(10) == "10")
    }

    @Test func moreIsAlwaysANumeral() {
        #expect(Formatting.more(2) == "2 more")
        #expect(Formatting.more(1) == "1 more")
        #expect(Formatting.more(12) == "12 more")
    }

    @Test func signedOutAccounts() {
        #expect(Formatting.signedOut(accounts: 1) == "1 account signed out")
        #expect(Formatting.signedOut(accounts: 2) == "2 accounts signed out")
    }

    // MARK: Durations

    static let durationCases: [(Double, String)] = [
        (60, "1 min"), (1500, "25 min"), (3540, "59 min"), (3600, "1 h"), (5400, "1 h 30 min"),
        (7200, "2 h"), (17100, "4 h 45 min"), (0, "0 min"),
    ]

    @Test(arguments: durationCases)
    func durations(_ seconds: Double, _ text: String) {
        #expect(Formatting.duration(seconds) == text)
        #expect(Formatting.free(seconds) == "\(text) free")
    }

    @Test func durationsRoundToTheNearestMinuteAndNeverGoNegative() {
        #expect(Formatting.duration(89) == "1 min")
        #expect(Formatting.duration(91) == "2 min")
        #expect(Formatting.duration(-30) == "0 min")
    }

    @Test func countdownsRoundUp() {
        #expect(Formatting.countdown(1) == "1 min")
        #expect(Formatting.countdown(60) == "1 min")
        #expect(Formatting.countdown(61) == "2 min")
        #expect(Formatting.countdown(18 * 60 - 30) == "18 min")
        #expect(Formatting.countdown(3600) == "1 h")
        #expect(Formatting.countdown(3601) == "1 h 1 min")
    }

    // MARK: Times

    @Test func twentyFourHourTimesHaveNoLeadingZero() {
        #expect(Formatting.time(TestData.date("2026-11-04 09:30"), calendar: calendar) == "9:30")
        #expect(Formatting.time(TestData.date("2026-11-04 14:00"), calendar: calendar) == "14:00")
        #expect(Formatting.time(TestData.date("2026-11-04 00:05"), calendar: calendar) == "0:05")
        #expect(Formatting.time(TestData.date("2026-11-04 23:59"), calendar: calendar) == "23:59")
    }

    @Test func twelveHourTimesFollowTheSystem() {
        #expect(TestData.plain(Formatting.time(TestData.date("2026-11-04 09:30", in: us), calendar: us)) == "9:30 AM")
        #expect(TestData.plain(Formatting.time(TestData.date("2026-11-04 14:00", in: us), calendar: us)) == "2:00 PM")
        #expect(TestData.plain(Formatting.time(TestData.date("2026-11-04 00:05", in: us), calendar: us)) == "12:05 AM")
        #expect(TestData.plain(Formatting.time(TestData.date("2026-11-04 12:00", in: us), calendar: us)) == "12:00 PM")
    }

    @Test func clockSplitsTheDigitsFromThePeriod() {
        let a = Formatting.clock(TestData.date("2026-11-04 14:05"), calendar: calendar)
        #expect(a.digits == "14:05")
        #expect(a.period == nil)
        let b = Formatting.clock(TestData.date("2026-11-04 14:05", in: us), calendar: us)
        #expect(b.digits == "2:05")
        #expect(b.period == "PM")
        let c = Formatting.clock(TestData.date("2026-11-04 00:30", in: us), calendar: us)
        #expect(c.digits == "12:30")
        #expect(c.period == "AM")
    }

    @Test func timesReadInTheCalendarsZone() {
        let instant = TestData.date("2026-11-04 14:00")
        #expect(Formatting.time(instant, calendar: calendar) == "14:00")
        #expect(Formatting.time(instant, calendar: TestData.calendar("Asia/Kolkata")) == "18:30")
        #expect(Formatting.time(instant, calendar: TestData.calendar("America/New_York")) == "8:00")
    }

    @Test func timesAcrossDaylightSavingReadTheWallClock() {
        #expect(Formatting.time(TestData.date("2026-03-29 03:30"), calendar: calendar) == "3:30")
        #expect(Formatting.time(TestData.date("2026-10-25 04:30"), calendar: calendar) == "4:30")
    }

    // MARK: Days

    @Test func weekdayAndTime() {
        let thursday = TestData.date("2026-11-05 09:30")
        #expect(Formatting.weekdayTime(thursday, calendar: calendar) == "Thu 9:30")
        #expect(Formatting.shortWeekday(thursday, calendar: calendar) == "Thu")
        #expect(Formatting.shortWeekdayCapitalized(thursday, calendar: calendar) == "THU")
    }

    @Test func dayTimeIsTodayTomorrowOrWeekday() {
        let now = TestData.date("2026-11-04 17:30")
        #expect(Formatting.dayTime(TestData.date("2026-11-04 18:00"), relativeTo: now, calendar: calendar) == "18:00")
        #expect(Formatting.dayTime(TestData.date("2026-11-05 09:30"), relativeTo: now, calendar: calendar) == "Tomorrow 9:30")
        #expect(Formatting.dayTime(TestData.date("2026-11-06 09:30"), relativeTo: now, calendar: calendar) == "Fri 9:30")
        // Tomorrow is a calendar day, not 24 hours: 00:10 is tomorrow at 23:50.
        let late = TestData.date("2026-11-04 23:50")
        #expect(Formatting.dayTime(TestData.date("2026-11-05 00:10"), relativeTo: late, calendar: calendar) == "Tomorrow 0:10")
    }

    @Test func dayTitles() {
        let day = TestData.day("2026-11-04")
        #expect(Formatting.weekday(day, calendar: calendar) == "Wednesday")
        #expect(Formatting.dayAndMonth(day, calendar: calendar) == "4 November")
        #expect(Formatting.dayHeader(day, calendar: calendar) == "Wednesday 4 November")
        #expect(Formatting.firstOfMonth(TestData.day("2026-12-01"), calendar: calendar) == "1 Dec")
    }

    @Test func monthTitleCarriesTheYearOnlyWhenNotThisYear() {
        let now = TestData.date("2026-11-04 12:00")
        #expect(Formatting.monthTitle(year: 2026, month: 11, now: now, calendar: calendar) == "November")
        #expect(Formatting.monthTitle(year: 2027, month: 1, now: now, calendar: calendar) == "January 2027")
        #expect(Formatting.monthTitle(year: 2026, month: 11, now: now, calendar: calendar, alwaysYear: true) == "November 2026")
    }

    // MARK: Event sheet lines

    /// The system interval formatter owns the range mark and the digit padding, so these
    /// pin what the line must say and not how a given OS release punctuates it.
    @Test func eventWhen() throws {
        let fixture = try TestData.loadFixture()
        let cal = fixture.calendar
        let investor = try #require(fixture.events.first { $0.title == "Investor call" })
        let sheet = TestData.plain(Formatting.eventWhen(investor, calendar: cal))
        #expect(sheet.hasPrefix("Wednesday 4 November"))
        #expect(sheet.contains("14:00"))
        #expect(sheet.hasSuffix("15:00"))
        #expect(sheet.contains(" at ") == false)
        #expect(!sheet.contains(" to "))
        // One day, so the date is said once.
        #expect(sheet.components(separatedBy: "November").count == 2)

        // An all-day range names both days; the exclusive end is Friday's midnight, so the
        // last day is Thursday.
        let lisbon = try #require(fixture.events.first { $0.title == "Lisbon" && $0.kind == .default })
        let range = TestData.plain(Formatting.eventWhen(lisbon, calendar: cal))
        #expect(range.hasPrefix("Tuesday 3 November"))
        #expect(range.hasSuffix("Thursday 5 November"))
        #expect(!range.contains(":"))
        let birthday = try #require(fixture.events.first { $0.kind == .birthday })
        #expect(Formatting.eventWhen(birthday, calendar: cal) == "Sunday 8 November")

        // Across midnight both ends carry their date and time.
        let flight = try #require(fixture.events.first { $0.title == "Flight to Amsterdam (TP 674)" })
        let across = TestData.plain(Formatting.eventWhen(flight, calendar: cal))
        #expect(across.hasPrefix("Thursday 5 November"))
        #expect(across.contains("20:30"))
        #expect(across.contains("Friday 6 November"))
        #expect(across.hasSuffix("00:15"))
    }

    @Test func eventWhenFollowsTheSystemClockAndZone() {
        // 12-hour region: the period comes from the system, once for the range.
        let us = TestData.calendar("America/New_York", locale: "en_US")
        let lunch = TestData.event("Lunch", "2026-11-04 14:00", "2026-11-04 15:00", zone: us)
        let sheet = TestData.plain(Formatting.eventWhen(lunch, calendar: us))
        #expect(sheet.contains("Wednesday"))
        #expect(sheet.contains("November 4"))
        #expect(sheet.contains("2:00"))
        #expect(sheet.contains("3:00 PM"))

        // The same instant reads in the calendar's zone, not the author's.
        let amsterdam = TestData.event("Call", "2026-11-04 09:30", "2026-11-04 10:30")
        var india = TestData.amsterdam
        india.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let there = TestData.plain(Formatting.eventWhen(amsterdam, calendar: india))
        #expect(there.contains("14:00"))
        #expect(there.hasSuffix("15:00"))

        // An all-day day alone, and a zero-length event, never crash or print a range.
        let single = TestData.allDay("Holiday", "2026-11-04", "2026-11-05")
        #expect(Formatting.eventWhen(single, calendar: TestData.amsterdam) == "Wednesday 4 November")
        let instant = TestData.event("Ping", "2026-11-04 09:30", "2026-11-04 09:30")
        #expect(TestData.plain(Formatting.eventWhen(instant, calendar: TestData.amsterdam)).contains("09:30"))
    }

    @Test func guests() {
        func event(_ response: Response, _ count: Int) -> Event {
            TestData.event("E", "2026-11-04 10:00", "2026-11-04 11:00", response: response, attendees: count)
        }
        #expect(Formatting.guests(event(.needsAction, 5)) == "5 guests · No reply yet")
        #expect(Formatting.guests(event(.accepted, 5)) == "5 guests · Going")
        #expect(Formatting.guests(event(.tentative, 5)) == "5 guests · Maybe")
        #expect(Formatting.guests(event(.none, 0)) == nil)
        #expect(Formatting.guests(event(.accepted, 1)) == nil)
    }

    @Test func earlierLine() {
        func events(_ n: Int) -> [Event] {
            (1...n).map { TestData.event(["Standup", "Design review", "Lunch", "Sync", "Retro"][$0 - 1], "2026-11-04 0\($0):00", "2026-11-04 0\($0):30") }
        }
        #expect(Formatting.earlier(events(1)) == "Earlier: Standup")
        #expect(Formatting.earlier(events(2)) == "Earlier: Standup, Design review")
        #expect(Formatting.earlier(events(3)) == "Earlier: Standup, Design review and 1 more")
        #expect(Formatting.earlier(events(4)) == "Earlier: Standup, Design review and 2 more")
    }

    @Test func places() {
        func place(_ location: String?) -> String? {
            Formatting.place(TestData.event("E", "2026-11-04 10:00", "2026-11-04 11:00", location: location))
        }
        #expect(place("Café Nord\nRua Inventada 4, 1100-053 Lisboa") == "Café Nord")
        #expect(place("  Room 4.12  ") == "Room 4.12")
        #expect(place("Amsterdam Schiphol (AMS)") == "Amsterdam Schiphol (AMS)")
        #expect(place("https://zoom.us/j/123") == nil)
        #expect(place("http://example.com") == nil)
        #expect(place("meet.google.com/abc-defg-hij") == nil)
        #expect(place("zoom.us") == nil)
        #expect(place("teams.microsoft.com/l/meetup-join/abc") == nil)
        #expect(place("") == nil)
        #expect(place("   ") == nil)
        #expect(place(nil) == nil)
    }

    @Test func cityFromTheZoneIdentifier() {
        #expect(Formatting.city(zoneIdentifier: "Europe/Amsterdam") == "Amsterdam")
        #expect(Formatting.city(zoneIdentifier: "America/New_York") == "New York")
        #expect(Formatting.city(zoneIdentifier: "America/Argentina/Buenos_Aires") == "Buenos Aires")
        #expect(Formatting.city(zoneIdentifier: "UTC") == "UTC")
    }

    // MARK: Copy hygiene

    /// What the rules' strings never say: a greeting, an adjective about the day, an
    /// exclamation mark, a dash. A title Google sends is data and is not in this list's way:
    /// the fixture has none of these words.
    @Test func noEmDashesAnywhereInTheStringsTheRulesProduce() throws {
        let events = try TestData.inventedEvents()
        var strings: [String] = []
        for time in ["07:50", "09:20", "11:40", "12:10", "14:10", "15:10", "16:20", "17:30"] {
            let now = TestData.wednesday(time)
            for day in ["2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-09"] {
                for row in dayRows(day: TestData.day(day), events: events, now: now, calendar: calendar) {
                    switch row {
                    case .allDay(let e, let p): strings += [e.title, p ?? ""]
                    case .allDayMore(let t): strings.append(t)
                    case .earlier(let list): strings.append(Formatting.earlier(list))
                    case .event(_, let second, _): strings.append(second ?? "")
                    case .gap(let t, _): strings.append(t)
                    case .nowLine: break
                    }
                }
            }
            for entry in widgetTimeline(events: events, now: now, fetchedAt: now, signedOutAccounts: 1, calendar: calendar) {
                strings += [entry.inline, entry.rectangular.title, entry.rectangular.when?.text ?? "",
                            entry.rectangular.when?.reduced ?? "", entry.rectangular.after ?? ""]
            }
        }
        let banned = try #require(try? Regex(#"(?i)good (morning|afternoon|evening)|\b(packed|light|heavy|hectic|quiet)\b"#))
        for string in strings {
            #expect(!string.contains("\u{2014}"), "\(string)")
            #expect(!string.contains("\u{2013}"), "\(string)")
            #expect(!string.contains("!"), "\(string)")
            #expect(string.firstMatch(of: banned) == nil, "\(string)")
        }
        #expect(strings.count > 200)
    }
}
