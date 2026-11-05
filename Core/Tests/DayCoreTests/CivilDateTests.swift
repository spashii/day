import Foundation
import Testing

@testable import DayCore

/// Dates are where the product is most likely to be wrong somewhere: civil days that never
/// drift with the zone, events authored in one zone and read in another, midnight crossings,
/// and the nights the clocks change.
struct CivilDateTests {
    let calendar = TestData.amsterdam

    // MARK: All-day events are civil dates

    @Test(arguments: ["Asia/Kolkata", "America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Pago_Pago", "UTC"])
    func allDayCoverageIsTheSameInEveryZone(_ zone: String) {
        let trip = TestData.allDay("Lisbon", "2026-11-03", "2026-11-06")
        let local = TestData.calendar(zone)
        #expect(coveredDays(trip, calendar: local) == TestData.day("2026-11-03")...TestData.day("2026-11-05"))
        // The exclusive end is not covered, however far east or west.
        #expect(!coveredDays(trip, calendar: local).contains(TestData.day("2026-11-06")))
        // A one-day event covers one day.
        let one = TestData.allDay("Birthday", "2026-11-08", "2026-11-09")
        #expect(coveredDays(one, calendar: local).count == 1)
    }

    @Test func anAllDayEventStartsAtLocalMidnightNotUTCMidnight() {
        let one = TestData.allDay("Holiday", "2026-11-11", "2026-11-12")
        for zone in ["Asia/Kolkata", "America/Los_Angeles", "Pacific/Kiritimati"] {
            let local = TestData.calendar(zone)
            let start = one.time.start(in: local)
            #expect(CivilDate(start, in: local) == TestData.day("2026-11-11"), "\(zone)")
            #expect(local.component(.hour, from: start) == 0, "\(zone)")
            #expect(one.time.end(in: local) == TestData.day("2026-11-12").date(in: local), "\(zone)")
        }
    }

    @Test func aDayWhoseMidnightDoesNotExistStartsAtTheFirstInstantThatDoes() {
        // Cuba moves its clocks forward at 00:00 on 8 March 2026, so the day starts at 01:00.
        let havana = TestData.calendar("America/Havana")
        let day = TestData.day("2026-03-08")
        let start = day.date(in: havana)
        #expect(CivilDate(start, in: havana) == day)
        #expect(havana.component(.hour, from: start) == 1)
        #expect(CivilDate(start.addingTimeInterval(-1), in: havana) == day.adding(days: -1))
    }

    @Test func twentyThreeAndTwentyFiveHourDaysStillAdvanceOneDay() {
        let spring = TestData.day("2026-03-29")
        let length = spring.adding(days: 1).date(in: calendar).timeIntervalSince(spring.date(in: calendar))
        #expect(length == 23 * 3600)
        let autumn = TestData.day("2026-10-25")
        let long = autumn.adding(days: 1).date(in: calendar).timeIntervalSince(autumn.date(in: calendar))
        #expect(long == 25 * 3600)
    }

    // MARK: Events authored in one zone, read in another

    @Test func theSameInstantsAreOnDifferentDaysInDifferentZones() {
        let utc = TestData.calendar("UTC")
        let event = TestData.event("Late call", "2026-11-04 22:30", "2026-11-04 23:30", zone: utc)
        let kolkata = TestData.calendar("Asia/Kolkata")
        let losAngeles = TestData.calendar("America/Los_Angeles")
        #expect(coveredDays(event, calendar: utc) == TestData.day("2026-11-04")...TestData.day("2026-11-04"))
        #expect(coveredDays(event, calendar: calendar) == TestData.day("2026-11-04")...TestData.day("2026-11-04"))
        #expect(coveredDays(event, calendar: kolkata) == TestData.day("2026-11-05")...TestData.day("2026-11-05"))
        #expect(coveredDays(event, calendar: losAngeles) == TestData.day("2026-11-04")...TestData.day("2026-11-04"))
    }

    @Test func authoredZoneLineAppearsOnlyWhenTheOffsetDiffers() throws {
        let fixture = try TestData.loadFixture()
        let investor = try #require(fixture.events.first { $0.title == "Investor call" })
        // Written in New York, read in Amsterdam (14:00 there is 08:00 in New York).
        #expect(Formatting.authoredTime(investor, calendar: calendar) == "8:00 to 9:00 in New York")
        // Read in New York: same offset, no line.
        #expect(Formatting.authoredTime(investor, calendar: TestData.calendar("America/New_York")) == nil)
        // Standup is written in Amsterdam: read in Amsterdam nothing, read in India a line.
        let standup = try #require(fixture.events.first { $0.title == "Standup" })
        #expect(Formatting.authoredTime(standup, calendar: calendar) == nil)
        let india = TestData.calendar("Asia/Kolkata")
        #expect(Formatting.authoredTime(standup, calendar: india) == "9:30 to 9:45 in Amsterdam")
    }

    @Test func offsetsAreComparedNotZoneNames() {
        // Lisbon and London share an offset all year, so a Lisbon event read in London needs
        // no line; read in Amsterdam it does.
        let event = TestData.event(
            "Call", "2026-11-04 10:00", "2026-11-04 11:00", zone: TestData.calendar("Europe/Lisbon"))
        #expect(Formatting.authoredTime(event, calendar: TestData.calendar("Europe/London")) == nil)
        #expect(Formatting.authoredTime(event, calendar: calendar) == "10:00 to 11:00 in Lisbon")
    }

    @Test func theOffsetIsTheOneAtThatMoment() {
        // Phoenix never changes its clocks; Los Angeles does. In July they agree, in December
        // they are an hour apart, and the line follows the day of the event.
        let phoenix = TestData.calendar("America/Phoenix")
        let losAngeles = TestData.calendar("America/Los_Angeles")
        let summer = TestData.event("Call", "2026-07-01 09:00", "2026-07-01 10:00", zone: phoenix)
        #expect(Formatting.authoredTime(summer, calendar: losAngeles) == nil)
        let winter = TestData.event("Call", "2026-12-01 09:00", "2026-12-01 10:00", zone: phoenix)
        #expect(Formatting.authoredTime(winter, calendar: losAngeles) == "9:00 to 10:00 in Phoenix")
    }

    // MARK: Midnight crossings

    @Test func aTimedEventCoversASecondDayOnlyPastFiveInTheMorning() {
        func days(_ start: String, _ end: String) -> Int {
            coveredDays(TestData.event("E", start, end), calendar: calendar).count
        }
        #expect(days("2026-11-10 20:30", "2026-11-11 00:15") == 1)
        #expect(days("2026-11-10 22:00", "2026-11-11 00:00") == 1)
        #expect(days("2026-11-10 22:00", "2026-11-11 04:59") == 1)
        #expect(days("2026-11-10 22:00", "2026-11-11 05:00") == 1)
        #expect(days("2026-11-10 22:00", "2026-11-11 05:01") == 2)
        #expect(days("2026-11-10 22:00", "2026-11-11 07:00") == 2)
        // Several days: every day up to the one it ends on, if it ends after 05:00 there.
        #expect(days("2026-11-10 09:00", "2026-11-13 00:00") == 3)
        #expect(days("2026-11-10 09:00", "2026-11-13 06:00") == 4)
        // Same day, however early.
        #expect(days("2026-11-10 01:00", "2026-11-10 03:00") == 1)
        #expect(days("2026-11-10 00:00", "2026-11-10 23:59") == 1)
    }

    @Test func midnightCrossingBetweenTwoZonesReadsTheReadersDay() {
        // 20:30 to 00:15 in Lisbon is 21:30 to 01:15 in Amsterdam: still one day, the 5th.
        let lisbon = TestData.calendar("Europe/Lisbon")
        let flight = TestData.event("Flight", "2026-11-05 20:30", "2026-11-06 00:15", zone: lisbon)
        #expect(coveredDays(flight, calendar: calendar) == TestData.day("2026-11-05")...TestData.day("2026-11-05"))
        // In Kolkata it is 02:00 to 05:45 on the 6th: past 05:00, but it starts and ends on
        // the 6th, so one day.
        let kolkata = TestData.calendar("Asia/Kolkata")
        #expect(coveredDays(flight, calendar: kolkata) == TestData.day("2026-11-06")...TestData.day("2026-11-06"))
    }

    // MARK: The clocks change

    @Test func theFiveAMCutoffIsWallClockOnTheNightTheClocksGoBack() {
        // 25 October 2026: 03:00 CEST becomes 02:00 CET. 04:30 CET is before 05:00 by the
        // wall clock, though 5 hours after midnight CEST have elapsed by then.
        let early = TestData.event("E", "2026-10-24 22:00", "2026-10-25 04:30")
        #expect(coveredDays(early, calendar: calendar).count == 1)
        let late = TestData.event("E", "2026-10-24 22:00", "2026-10-25 05:01")
        #expect(coveredDays(late, calendar: calendar).count == 2)
    }

    @Test func theFiveAMCutoffIsWallClockOnTheNightTheClocksGoForward() {
        // 29 March 2026: 02:00 CET becomes 03:00 CEST. 05:30 CEST is past 05:00 by the wall
        // clock, though only 4.5 hours have elapsed since midnight.
        let late = TestData.event("E", "2026-03-28 22:00", "2026-03-29 05:30")
        #expect(coveredDays(late, calendar: calendar).count == 2)
        let early = TestData.event("E", "2026-03-28 22:00", "2026-03-29 04:30")
        #expect(coveredDays(early, calendar: calendar).count == 1)
    }

    @Test func civilDateArithmeticAcrossYearsAndLeapDays() {
        #expect(TestData.day("2027-02-28").adding(days: 1) == TestData.day("2027-03-01"))
        #expect(TestData.day("2028-02-28").adding(days: 1) == TestData.day("2028-02-29"))
        #expect(TestData.day("2026-12-31").adding(days: 1) == TestData.day("2027-01-01"))
        #expect(TestData.day("2026-11-04").distance(to: TestData.day("2026-12-04")) == 30)
        #expect(TestData.day("2026-10-25").distance(to: TestData.day("2026-10-26")) == 1)
    }
}
