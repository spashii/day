import Foundation
import Testing

@testable import DayCore

/// Section 4, "Which event": the one function the Lock Screen, the menu bar and the Day's Join
/// window share.
struct NextEventTests {
    let calendar = TestData.amsterdam

    func next(_ events: [Event], _ now: String) -> NextEvents {
        nextEvents(events: events, now: TestData.date(now), calendar: calendar)
    }

    @Test func currentAndNextOnTheInventedWednesday() throws {
        let events = try TestData.inventedEvents()
        func titles(_ time: String) -> [String?] {
            let result = nextEvents(events: events, now: TestData.wednesday(time), calendar: calendar)
            return [result.current?.title, result.next?.title]
        }
        #expect(titles("07:50") == [nil, "Standup"])
        #expect(titles("09:20") == [nil, "Standup"])
        #expect(titles("09:30") == ["Standup", "Design review"])
        #expect(titles("11:40") == ["Design review", "Lunch with Maya"])
        #expect(titles("12:10") == [nil, "Lunch with Maya"])
        // Investor call started first, Acme sync started last: the one that started last.
        #expect(titles("14:40") == ["Acme sync", "Weekly planning"])
        #expect(titles("14:10") == ["Investor call", "Acme sync"])
        #expect(titles("16:20") == ["Weekly planning", "Standup"])
        // After the last event of the day everything rolls to tomorrow.
        #expect(titles("17:30") == [nil, "Standup"])
    }

    @Test func boundariesBelongToTheLaterState() {
        let events = [TestData.event("A", "2026-11-04 10:00", "2026-11-04 11:00")]
        #expect(next(events, "2026-11-04 09:59:59").next?.title == "A")
        #expect(next(events, "2026-11-04 09:59:59").current == nil)
        // At the start it is current, not next.
        #expect(next(events, "2026-11-04 10:00").current?.title == "A")
        #expect(next(events, "2026-11-04 10:00").next == nil)
        // At the end it is over.
        #expect(next(events, "2026-11-04 11:00").current == nil)
        #expect(next(events, "2026-11-04 11:00").next == nil)
    }

    @Test func ofSeveralCurrentOnesTheLastStartedWins() {
        let events = [
            TestData.event("Long", "2026-11-04 09:00", "2026-11-04 12:00"),
            TestData.event("Later", "2026-11-04 10:00", "2026-11-04 11:00"),
            TestData.event("Latest", "2026-11-04 10:30", "2026-11-04 10:45"),
        ]
        #expect(next(events, "2026-11-04 10:35").current?.title == "Latest")
        #expect(next(events, "2026-11-04 10:50").current?.title == "Later")
        #expect(next(events, "2026-11-04 11:30").current?.title == "Long")
    }

    @Test func equalStartsAreDecidedByEarlierEndThenInputOrder() {
        let a = TestData.event("A", "2026-11-04 10:00", "2026-11-04 11:00")
        let b = TestData.event("B", "2026-11-04 10:00", "2026-11-04 10:30")
        let c = TestData.event("C", "2026-11-04 10:00", "2026-11-04 10:30")
        #expect(next([a, b, c], "2026-11-04 10:10").current?.title == "B")
        #expect(next([a, c, b], "2026-11-04 10:10").current?.title == "C")
        #expect(next([a, b, c], "2026-11-04 09:00").next?.title == "B")
    }

    // MARK: What is a candidate

    @Test func timedEventsOnly() {
        let events = [TestData.allDay("Trip", "2026-11-04", "2026-11-05")]
        #expect(next(events, "2026-11-04 08:00") == NextEvents())
    }

    @Test(arguments: [
        "declined", "cancelled", "free", "focusTime", "outOfOffice", "workingLocation", "birthday",
    ])
    func excluded(_ why: String) {
        var event = TestData.event("X", "2026-11-04 10:00", "2026-11-04 11:00")
        switch why {
        case "declined": event.response = .declined
        case "cancelled": event.status = .cancelled
        case "free": event.isFree = true
        case "focusTime": event.kind = .focusTime
        case "outOfOffice": event.kind = .outOfOffice
        case "workingLocation": event.kind = .workingLocation
        case "birthday": event.kind = .birthday
        default: Issue.record("unknown case")
        }
        #expect(next([event], "2026-11-04 08:00") == NextEvents())
        #expect(next([event], "2026-11-04 10:30") == NextEvents())
    }

    @Test(arguments: [EventKind.default, .fromGmail])
    func included(_ kind: EventKind) {
        let event = TestData.event("X", "2026-11-04 10:00", "2026-11-04 11:00", kind: kind)
        #expect(next([event], "2026-11-04 08:00").next?.title == "X")
    }

    @Test func tentativeAndUnansweredStillCount() {
        let tentative = TestData.event("T", "2026-11-04 10:00", "2026-11-04 11:00", status: .tentative)
        let pending = TestData.event("P", "2026-11-04 12:00", "2026-11-04 13:00", response: .needsAction)
        let maybe = TestData.event("M", "2026-11-04 14:00", "2026-11-04 15:00", response: .tentative)
        #expect(next([tentative, pending, maybe], "2026-11-04 08:00").next?.title == "T")
        #expect(next([tentative, pending, maybe], "2026-11-04 11:30").next?.title == "P")
        #expect(next([tentative, pending, maybe], "2026-11-04 13:30").next?.title == "M")
    }

    // MARK: Horizon

    @Test func horizonIsTheEndOfTheSeventhDayAhead() {
        // From Wednesday 4 November the seventh day ahead is Wednesday 11 November.
        let last = TestData.event("Last", "2026-11-11 23:30", "2026-11-11 23:59")
        let eighth = TestData.event("Eighth", "2026-11-12 00:00", "2026-11-12 01:00")
        #expect(next([last, eighth], "2026-11-04 00:01").next?.title == "Last")
        #expect(next([eighth], "2026-11-04 23:59").next == nil)
        // Just after midnight the window has moved on by a day.
        #expect(next([eighth], "2026-11-05 00:00").next?.title == "Eighth")
    }

    @Test func eventsThatAlreadyEndedNeverCount() {
        let events = [TestData.event("Old", "2026-11-03 10:00", "2026-11-03 11:00")]
        #expect(next(events, "2026-11-04 08:00") == NextEvents())
    }

    @Test func anEventRunningAcrossMidnightIsCurrentOnBothSides() {
        let events = [TestData.event("Flight", "2026-11-04 22:00", "2026-11-05 06:00")]
        #expect(next(events, "2026-11-04 23:30").current?.title == "Flight")
        #expect(next(events, "2026-11-05 03:00").current?.title == "Flight")
        #expect(next(events, "2026-11-05 06:00").current == nil)
    }

    // MARK: Join

    @Test func joinWindowOpensTenMinutesBeforeAndClosesAtTheEnd() {
        let call = TestData.event(
            "Call", "2026-11-04 14:00", "2026-11-04 15:00", join: "https://meet.google.com/abc-defg-hij")
        func joinable(_ time: String) -> String? {
            let now = TestData.date("2026-11-04 \(time)")
            let result = nextEvents(events: [call], now: now, calendar: calendar)
            return joinableEvent(next: result, now: now)?.title
        }
        #expect(joinable("13:49") == nil)
        #expect(joinable("13:50") == "Call")
        #expect(joinable("14:00") == "Call")
        #expect(joinable("14:59") == "Call")
        #expect(joinable("15:00") == nil)
    }

    @Test func joinNeedsALink() {
        let call = TestData.event("Call", "2026-11-04 14:00", "2026-11-04 15:00")
        let now = TestData.date("2026-11-04 14:05")
        #expect(joinableEvent(next: nextEvents(events: [call], now: now, calendar: calendar), now: now) == nil)
    }

    @Test func theCurrentOneWinsAndTheNextOneJoinsInItsWindow() {
        let a = TestData.event("A", "2026-11-04 14:00", "2026-11-04 15:00", join: "https://zoom.us/j/1")
        let b = TestData.event("B", "2026-11-04 14:30", "2026-11-04 15:30", join: "https://zoom.us/j/2")
        let early = TestData.date("2026-11-04 14:10")
        let overlap = nextEvents(events: [a, b], now: early, calendar: calendar)
        #expect(joinWindow(next: overlap, now: early).map(\.title) == ["A"])
        let near = TestData.date("2026-11-04 14:20")
        let both = nextEvents(events: [a, b], now: near, calendar: calendar)
        #expect(joinWindow(next: both, now: near).map(\.title) == ["A", "B"])
        // Command-J joins the current one.
        #expect(joinableEvent(next: both, now: near)?.title == "A")
    }
}
