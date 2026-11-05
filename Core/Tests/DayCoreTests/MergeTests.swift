import Foundation
import Testing

@testable import DayCore

/// Section 10 of the brief: one event across accounts. His data has no duplicates today, so
/// the guard is proven here with fixtures.
struct MergeTests {
    let calendar = TestData.amsterdam

    /// The same meeting as two accounts hold it: shared iCalUID and start, different IDs.
    func copy(
        _ account: Account, uid: String = "shared@google.com", start: String = "2026-11-04 14:00",
        original: String? = nil, response: Response = .needsAction, organizer: Bool = false,
        title: String = "Investor call"
    ) -> Event {
        TestData.event(
            title, start, "\(start.prefix(10)) 23:00", id: "\(account.id.sub)-id", uid: uid, account: account,
            response: response, organizer: organizer, attendees: 4, original: original)
    }

    @Test func sameUIDAndStartIsOneEvent() {
        let result = merged([copy(TestData.personal), copy(TestData.work)])
        #expect(result.count == 1)
        #expect(result[0].calendars == [TestData.personalCalendar.id, TestData.workCalendar.id])
    }

    @Test func theFirstAddedAccountsCopyIsKeptWhenNothingElseDecides() {
        let result = merged([copy(TestData.personal), copy(TestData.work)])
        #expect(result[0].account == TestData.personal.id)
        #expect(result[0].id.googleID == "P-id")
        // The input order is the tiebreak, so the other order keeps the other copy.
        let reversed = merged([copy(TestData.work), copy(TestData.personal)])
        #expect(reversed[0].account == TestData.work.id)
    }

    @Test func theCopyHeOrganizesWinsFirst() {
        let result = merged([
            copy(TestData.personal, response: .accepted), copy(TestData.work, organizer: true),
        ])
        #expect(result[0].account == TestData.work.id)
        // The kept copy's own calendar leads the list; the other follows.
        #expect(result[0].calendars == [TestData.workCalendar.id, TestData.personalCalendar.id])
    }

    @Test func theCopyHeAnsweredBeatsOneHeDidNot() {
        for answer in [Response.accepted, .declined, .tentative] {
            let result = merged([copy(TestData.personal), copy(TestData.work, response: answer)])
            #expect(result[0].account == TestData.work.id, "\(answer)")
        }
        // Unanswered and no guest list are not answers.
        let none = merged([copy(TestData.personal, response: .none), copy(TestData.work, response: .needsAction)])
        #expect(none[0].account == TestData.personal.id)
    }

    @Test func organizerBeatsAnswered() {
        let result = merged([
            copy(TestData.personal, response: .accepted),
            copy(TestData.work, response: .needsAction, organizer: true),
        ])
        #expect(result[0].account == TestData.work.id)
    }

    @Test func recurringInstancesMergeByOriginalStart() {
        let a = copy(TestData.personal, original: "2026-11-04 14:00")
        let b = copy(TestData.work, original: "2026-11-04 14:00")
        #expect(merged([a, b]).count == 1)
        // The next occurrence of the same series is a different event.
        let nextWeek = copy(
            TestData.personal, start: "2026-11-11 14:00", original: "2026-11-11 14:00")
        var other = nextWeek
        other.id = EventID(calendar: nextWeek.id.calendar, googleID: "P-id-2")
        #expect(merged([a, b, other]).count == 2)
        // An instance moved to another time keeps its original start, so it still matches the
        // copy in the other account that moved with it.
        var movedA = a
        movedA.time = .timed(
            start: TestData.date("2026-11-04 16:00"), end: TestData.date("2026-11-04 17:00"), authoredZone: nil)
        var movedB = b
        movedB.time = movedA.time
        #expect(merged([movedA, movedB]).count == 1)
    }

    @Test func singleEventsMergeByStart() {
        let a = copy(TestData.personal, start: "2026-11-04 14:00")
        let b = copy(TestData.work, start: "2026-11-04 15:00")
        // Same UID, different start: two events.
        #expect(merged([a, b]).count == 2)
    }

    @Test func differentUIDsNeverMerge() {
        let a = copy(TestData.personal, uid: "one@google.com")
        let b = copy(TestData.work, uid: "two@google.com")
        #expect(merged([a, b]).count == 2)
    }

    @Test func allDayEventsMergeByDay() {
        func trip(_ account: Account, _ start: String) -> Event {
            var event = TestData.allDay("Trip", start, "2026-11-08", account: account)
            event.iCalUID = "trip@google.com"
            return event
        }
        #expect(merged([trip(TestData.personal, "2026-11-05"), trip(TestData.work, "2026-11-05")]).count == 1)
        #expect(merged([trip(TestData.personal, "2026-11-05"), trip(TestData.work, "2026-11-06")]).count == 2)
    }

    @Test func mergingKeepsTheOrderOfFirstAppearance() {
        let a = copy(TestData.personal, uid: "a@google.com", start: "2026-11-04 09:00", title: "A")
        let b = copy(TestData.personal, uid: "b@google.com", start: "2026-11-04 10:00", title: "B")
        let a2 = copy(TestData.work, uid: "a@google.com", start: "2026-11-04 09:00", title: "A")
        #expect(merged([a, b, a2]).map(\.title) == ["A", "B"])
    }

    @Test func mergingIsIdempotentAndLeavesDistinctEventsAlone() {
        let events = [
            copy(TestData.personal), copy(TestData.work),
            copy(TestData.work, uid: "other@google.com", title: "Other"),
        ]
        let once = merged(events)
        #expect(merged(once) == once)
        #expect(once.count == 2)
        #expect(merged([]) == [])
    }

    @Test func threeCopiesListEveryCalendarOnce() {
        let extra = CalendarID(account: TestData.work.id, googleID: "team@group.calendar.google.com")
        var third = copy(TestData.work)
        third.id = EventID(calendar: extra, googleID: "W2-id")
        third.calendars = [extra]
        let result = merged([copy(TestData.personal), copy(TestData.work), third])
        #expect(result.count == 1)
        #expect(result[0].calendars == [TestData.personalCalendar.id, TestData.workCalendar.id, extra])
    }

    // MARK: The guard that matters

    @Test func theInventedFixtureHoldsTheSameCallOnBothAccounts() throws {
        let fixture = try TestData.loadFixture()
        let copies = fixture.events.filter { $0.title == "Investor call" && $0.iCalUID.hasPrefix("7hq2") }
        #expect(copies.count == 2)
        #expect(merged(fixture.events).filter { $0.iCalUID.hasPrefix("7hq2") }.count == 1)
        // Nothing else in the fixture merges: 120 events become 119.
        #expect(merged(fixture.events).count == fixture.events.count - 1)
    }

    @Test func aMergedMeetingNeverOverlapsItself() throws {
        let fixture = try TestData.loadFixture()
        let day = TestData.day("2026-11-04")
        let now = TestData.wednesday("07:50")
        let unmerged = summarize(day: day, events: fixture.events, now: now, calendar: fixture.calendar)
        #expect(unmerged.second?.contains("Investor call and Investor call") == true)
        let good = summarize(day: day, events: merged(fixture.events), now: now, calendar: fixture.calendar)
        #expect(good.second?.contains("Investor call and Investor call") != true)
        #expect(good.second == "Investor call and Acme sync overlap at 14:30.")
    }
}
