import Foundation
import Testing

@testable import DayCore

/// Which local notifications a device keeps pending, from its own cache alone: Google's
/// reminders, the events and calendars that get none, the rolling window, all-day events,
/// zones and daylight saving, and the extra notification at the start of a call.
struct ReminderScheduleTests {
    let calendar = TestData.amsterdam
    /// Wednesday 4 November 2026, 08:00 in Amsterdam.
    var now: Date { TestData.date("2026-11-04 08:00") }

    // MARK: Builders

    func timed(
        _ title: String, _ start: String, _ end: String,
        reminders: EventReminders? = EventReminders(useDefault: true),
        location: String? = nil, join: String? = nil, response: Response = .none,
        status: EventStatus = .confirmed, zone: Calendar? = nil, id: String? = nil
    ) -> Event {
        var event = TestData.event(
            title, start, end, zone: zone ?? calendar, id: id, status: status, response: response,
            location: location, join: join)
        event.reminders = reminders
        return event
    }

    func allDay(
        _ title: String, _ start: String, _ endExclusive: String,
        reminders: EventReminders? = EventReminders(overrides: [900])
    ) -> Event {
        var event = TestData.allDay(title, start, endExclusive)
        event.reminders = reminders
        return event
    }

    func data(_ events: [Event], defaults: [Int] = [10], hidden: Bool = false) -> CalendarData {
        var info = TestData.workCalendar
        info.defaultReminders = defaults
        var visibility = CalendarVisibility()
        if hidden { visibility.set(false, for: info.id) }
        return CalendarData(
            accounts: [TestData.work], calendarsByAccount: [TestData.work.id: [info]],
            eventsByAccount: [TestData.work.id: events], visibility: visibility)
    }

    func plan(
        _ events: [Event], defaults: [Int] = [10], hidden: Bool = false, now: Date? = nil,
        calendar: Calendar? = nil, horizon: TimeInterval = ReminderSchedule.defaultHorizon,
        limit: Int = ReminderSchedule.defaultLimit
    ) -> [PlannedReminder] {
        ReminderSchedule.plan(
            data(events, defaults: defaults, hidden: hidden), now: now ?? self.now,
            calendar: calendar ?? self.calendar, horizon: horizon, limit: limit)
    }

    func leads(_ plan: [PlannedReminder]) -> [Int] {
        plan.compactMap {
            if case .lead(let minutes) = $0.kind { return minutes }
            return nil
        }
    }

    // MARK: Google's reminders

    @Test func theEventsOwnOverridesReplaceTheCalendarsDefaults() {
        let event = timed(
            "Standup", "2026-11-04 10:00", "2026-11-04 10:30",
            reminders: EventReminders(overrides: [30, 5]))
        let found = plan([event], defaults: [10])
        #expect(leads(found) == [30, 5])
        #expect(found.map(\.fireDate) == [
            TestData.date("2026-11-04 09:30"), TestData.date("2026-11-04 09:55"),
        ])
    }

    @Test func useDefaultTakesTheCalendarsDefaultsAndIgnoresOverrides() {
        let event = timed(
            "Standup", "2026-11-04 10:00", "2026-11-04 10:30",
            reminders: EventReminders(useDefault: true, overrides: [5]))
        #expect(leads(plan([event], defaults: [60, 10])) == [60, 10])
        // A calendar with no defaults leaves such an event without reminders.
        #expect(plan([event], defaults: []).isEmpty)
    }

    @Test func anEventWithNoRemindersGetsNone() {
        #expect(plan([timed("Standup", "2026-11-04 10:00", "2026-11-04 10:30", reminders: nil)]).isEmpty)
        #expect(
            plan([
                timed(
                    "Standup", "2026-11-04 10:00", "2026-11-04 10:30",
                    reminders: EventReminders())
            ]).isEmpty)
    }

    @Test func declinedAndCancelledEventsGetNone() {
        let events = [
            timed("Declined", "2026-11-04 10:00", "2026-11-04 10:30", response: .declined),
            timed("Cancelled", "2026-11-04 11:00", "2026-11-04 11:30", status: .cancelled),
            timed("Maybe", "2026-11-04 12:00", "2026-11-04 12:30", response: .tentative),
            timed("Unanswered", "2026-11-04 13:00", "2026-11-04 13:30", response: .needsAction),
        ]
        #expect(plan(events).map(\.title) == ["Maybe", "Unanswered"])
    }

    @Test func aHiddenCalendarGetsNone() {
        let event = timed("Standup", "2026-11-04 10:00", "2026-11-04 10:30")
        #expect(plan([event]).count == 1)
        #expect(plan([event], hidden: true).isEmpty)
    }

    @Test func aDuplicateOnTwoAccountsRemindsOnce() {
        var other = timed("Sync", "2026-11-04 10:00", "2026-11-04 10:30")
        other.id = EventID(calendar: TestData.personalCalendar.id, googleID: "copy")
        other.iCalUID = "shared"
        var mine = timed("Sync", "2026-11-04 10:00", "2026-11-04 10:30")
        mine.iCalUID = "shared"
        var info = TestData.workCalendar
        info.defaultReminders = [10]
        var personal = TestData.personalCalendar
        personal.defaultReminders = [10]
        let data = CalendarData(
            accounts: [TestData.work, TestData.personal],
            calendarsByAccount: [TestData.work.id: [info], TestData.personal.id: [personal]],
            eventsByAccount: [TestData.work.id: [mine], TestData.personal.id: [other]])
        #expect(ReminderSchedule.plan(data, now: now, calendar: calendar).count == 1)
    }

    // MARK: The window

    @Test func aReminderInThePastIsNotScheduled() {
        // Ten minutes before 08:05 was five minutes ago.
        let soon = timed("Soon", "2026-11-04 08:05", "2026-11-04 08:30")
        #expect(plan([soon]).isEmpty)
        // With two reminders only the one still ahead is kept.
        let both = timed(
            "Both", "2026-11-04 08:20", "2026-11-04 08:50",
            reminders: EventReminders(overrides: [10, 30]))
        #expect(leads(plan([both])) == [10])
        // An event under way has nothing ahead.
        #expect(plan([timed("Now", "2026-11-04 07:30", "2026-11-04 09:00")]).isEmpty)
    }

    @Test func theWindowIsMeasuredOnTheFireTimeNotTheStart() {
        // Starts 48 h 30 min ahead: its 10-minute reminder is outside the window, its
        // 60-minute one inside.
        let edge = timed(
            "Edge", "2026-11-06 08:30", "2026-11-06 09:00",
            reminders: EventReminders(overrides: [10, 60]))
        #expect(leads(plan([edge])) == [60])
        // A reminder a day ahead of a later event fires inside the window.
        let early = timed(
            "Early", "2026-11-07 06:00", "2026-11-07 07:00",
            reminders: EventReminders(overrides: [1440]))
        #expect(plan([early]).map(\.fireDate) == [TestData.date("2026-11-06 06:00")])
    }

    @Test func theWindowEndsExactlyAtTheHorizon() {
        let inside = timed(
            "In", "2026-11-06 08:10", "2026-11-06 08:40", reminders: EventReminders(overrides: [10]))
        let outside = timed(
            "Out", "2026-11-06 08:11", "2026-11-06 08:40", reminders: EventReminders(overrides: [10]))
        // 48 h after 08:00 is 08:00 on the 6th: the first fires at it, the second a minute later.
        #expect(plan([inside, outside]).map(\.title) == ["In"])
        #expect(plan([inside], horizon: 24 * 3600).isEmpty)
    }

    @Test func atMostSixtyAreScheduledAndTheEarliestWin() {
        let events = (0..<70).map { i in
            let minutes = 9 * 60 + i * 10
            let start = String(format: "2026-11-04 %02d:%02d", minutes / 60, minutes % 60)
            let end = String(format: "2026-11-04 %02d:%02d", (minutes + 5) / 60, (minutes + 5) % 60)
            return timed("E\(i)", start, end, reminders: EventReminders(overrides: [5]))
        }
        let found = plan(events)
        #expect(found.count == 60)
        #expect(found.first?.title == "E0")
        #expect(found.last?.title == "E59")
        #expect(found.map(\.fireDate) == found.map(\.fireDate).sorted())
        #expect(plan(events, limit: 3).map(\.title) == ["E0", "E1", "E2"])
        #expect(plan(events, limit: 0).isEmpty)
        // iOS refuses more than 64 pending requests.
        #expect(ReminderSchedule.defaultLimit < 64)
    }

    @Test func remindersComeEarliestFirstAcrossEvents() {
        let a = timed("A", "2026-11-04 12:00", "2026-11-04 12:30", reminders: EventReminders(overrides: [5]))
        let b = timed("B", "2026-11-04 10:00", "2026-11-04 10:30", reminders: EventReminders(overrides: [60, 5]))
        #expect(plan([a, b]).map { "\($0.title) \($0.kind)" } == [
            "B lead(minutes: 60)", "B lead(minutes: 5)", "A lead(minutes: 5)",
        ])
    }

    // MARK: All-day events

    @Test func anAllDayReminderBeforeTheDayIsTomorrow() throws {
        // Google's "1 day before at 9:00" is 900 minutes before midnight.
        let event = allDay("Lisbon", "2026-11-06", "2026-11-09")
        let found = try #require(plan([event]).first)
        #expect(found.fireDate == TestData.date("2026-11-05 09:00"))
        #expect(found.title == "Lisbon")
        #expect(found.body == "Tomorrow")
        #expect(found.level == .active)
    }

    @Test func anAllDayReminderOnTheDayIsToday() throws {
        // "On the day at 9:00" is 540 minutes after midnight.
        let event = allDay("Holiday", "2026-11-05", "2026-11-06", reminders: EventReminders(overrides: [-540]))
        let found = try #require(plan([event]).first)
        #expect(found.fireDate == TestData.date("2026-11-05 09:00"))
        #expect(found.body == "Today")
    }

    @Test func anAllDayReminderWithinTheWeekNamesTheWeekday() throws {
        let event = allDay(
            "Trip", "2026-11-06", "2026-11-07", reminders: EventReminders(overrides: [2 * 1440 - 540]))
        let found = try #require(plan([event]).first)
        #expect(found.fireDate == TestData.date("2026-11-04 09:00"))
        #expect(found.body == "Friday")
    }

    @Test func anAllDayReminderAWeekOrMoreAheadNamesTheDate() throws {
        let event = allDay(
            "Trip", "2026-11-13", "2026-11-14", reminders: EventReminders(overrides: [9 * 1440 - 540]))
        let found = try #require(plan([event]).first)
        #expect(found.fireDate == TestData.date("2026-11-04 09:00"))
        #expect(found.body == "Friday 13 November")
    }

    @Test func anAllDayEventFollowsItsOwnOverridesNotTheTimedDefaults() {
        // Google keeps all-day defaults apart and does not send them; ten minutes before
        // midnight would be a reminder at 23:50.
        let event = allDay("Birthday", "2026-11-06", "2026-11-07", reminders: EventReminders(useDefault: true))
        #expect(plan([event], defaults: [10]).isEmpty)
    }

    @Test func anAllDayEventNeverGetsAStartNotification() {
        var event = allDay("Offsite", "2026-11-06", "2026-11-07")
        event.joinURL = URL(string: "https://meet.google.com/abc-defg-hij")
        let found = plan([event])
        #expect(found.map(\.kind) == [.lead(minutes: 900)])
        // It keeps the link for its Join action.
        #expect(found.first?.joinURL == event.joinURL)
    }

    @Test func aPastAllDayReminderIsNotScheduled() {
        // 09:00 on the 4th has passed at 10:00 that day.
        let event = allDay("Today", "2026-11-05", "2026-11-06")
        #expect(plan([event], now: TestData.date("2026-11-04 10:00")).isEmpty)
    }

    // MARK: Zones and daylight saving

    @Test func theSameEventFiresAtTheSameInstantAndReadsInTheDevicesZone() throws {
        let event = timed("Sync", "2026-11-05 09:30", "2026-11-05 10:00")
        let kolkata = TestData.calendar("Asia/Kolkata")
        let here = try #require(plan([event]).first)
        let there = try #require(plan([event], calendar: kolkata).first)
        #expect(here.fireDate == there.fireDate)
        #expect(here.fireDate == TestData.date("2026-11-05 09:20"))
        #expect(here.body == "In 10 min, 9:30 to 10:00")
        #expect(there.body == "In 10 min, 14:00 to 14:30")
        // A zone change is a change to what is pending.
        #expect(here.identifier == there.identifier)
        #expect(here.signature != there.signature)
    }

    @Test func anAllDayReminderKeepsItsHourInTheDevicesZone() throws {
        let event = allDay("Lisbon", "2026-11-06", "2026-11-07")
        let early = TestData.date("2026-11-03 12:00")
        let tokyo = TestData.calendar("Asia/Tokyo")
        let here = try #require(plan([event], now: early).first)
        let there = try #require(plan([event], now: early, calendar: tokyo).first)
        #expect(here.fireDate == TestData.date("2026-11-05 09:00", in: calendar))
        #expect(there.fireDate == TestData.date("2026-11-05 09:00", in: tokyo))
        #expect(here.fireDate != there.fireDate)
    }

    @Test func anAllDayReminderStaysOnTheWallClockAcrossDaylightSaving() throws {
        // Clocks go forward on 28 March 2027, so that day has 23 hours. 1500 minutes is two
        // days before at 23:00; counting 25 hours back from midnight would land at 22:00.
        let event = allDay("Monday", "2027-03-29", "2027-03-30", reminders: EventReminders(overrides: [1500]))
        let start = TestData.date("2027-03-25 08:00")
        let found = try #require(plan([event], now: start, horizon: 14 * 24 * 3600).first)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: found.fireDate)
        #expect(parts.year == 2027 && parts.month == 3 && parts.day == 27)
        #expect(parts.hour == 23 && parts.minute == 0)
        #expect(found.body == "Monday")
    }

    @Test func aTimedReminderIsAnElapsedSpanAcrossDaylightSaving() throws {
        // 03:30 on 28 March 2027 is after the gap; an hour earlier is 01:30, not 02:30.
        let event = timed(
            "Early", "2027-03-28 03:30", "2027-03-28 04:00", reminders: EventReminders(overrides: [60]))
        let start = TestData.date("2027-03-27 20:00")
        let found = try #require(plan([event], now: start).first)
        #expect(found.fireDate == event.time.start(in: calendar).addingTimeInterval(-3600))
        let parts = calendar.dateComponents([.hour, .minute], from: found.fireDate)
        #expect(parts.hour == 1 && parts.minute == 30)
    }

    // MARK: Calls

    @Test func aCallGetsOneMoreNotificationAtItsStart() throws {
        let call = timed(
            "Investor call", "2026-11-04 14:00", "2026-11-04 15:00",
            reminders: EventReminders(overrides: [10]), join: "https://meet.google.com/abc-defg-hij")
        let found = plan([call])
        #expect(found.map(\.kind) == [.lead(minutes: 10), .start])

        let reminder = found[0]
        #expect(reminder.level == .active)
        #expect(reminder.body == "In 10 min, 14:00 to 15:00")
        #expect(reminder.joinURL == call.joinURL)

        let start = found[1]
        #expect(start.fireDate == TestData.date("2026-11-04 14:00"))
        #expect(start.level == .timeSensitive)
        #expect(start.title == "Investor call")
        #expect(start.body == "Starting now, 14:00 to 15:00")
        #expect(start.joinURL == call.joinURL)
        #expect(Set(found.map(\.identifier)).count == 2)
    }

    @Test func onlyTheStartOfACallIsTimeSensitive() {
        let call = timed(
            "Call", "2026-11-04 14:00", "2026-11-04 15:00",
            reminders: EventReminders(overrides: [30, 10]), join: "https://zoom.us/j/1")
        let found = plan([call])
        #expect(found.filter { $0.level == .timeSensitive }.map(\.kind) == [.start])
    }

    @Test func aReminderAtZeroMinutesIsNotRepeatedBesideTheStartNotification() {
        let call = timed(
            "Call", "2026-11-04 14:00", "2026-11-04 15:00",
            reminders: EventReminders(overrides: [0, 10]), join: "https://zoom.us/j/1")
        #expect(plan([call]).map(\.kind) == [.lead(minutes: 10), .start])
    }

    @Test func anEventWithoutALinkHasNoJoinAndNoStartNotification() {
        let event = timed("Lunch", "2026-11-04 12:00", "2026-11-04 13:00", location: "Café Nord")
        let found = plan([event])
        #expect(found.count == 1)
        #expect(found[0].joinURL == nil)
        #expect(found[0].level == .active)
    }

    @Test func aCallWithNoRemindersStaysSilent() {
        let call = timed(
            "Call", "2026-11-04 14:00", "2026-11-04 15:00", reminders: nil,
            join: "https://zoom.us/j/1")
        #expect(plan([call]).isEmpty)
        // So does one that Google would not remind about, such as a declined one.
        let declined = timed(
            "Call", "2026-11-04 14:00", "2026-11-04 15:00", join: "https://zoom.us/j/1",
            response: .declined)
        #expect(plan([declined]).isEmpty)
    }

    @Test func theStartNotificationIsScheduledEvenWhenItsReminderIsAlreadyPast() {
        let call = timed(
            "Call", "2026-11-04 08:05", "2026-11-04 09:00",
            reminders: EventReminders(overrides: [10]), join: "https://zoom.us/j/1")
        #expect(plan([call]).map(\.kind) == [.start])
    }

    // MARK: Words

    @Test func aReminderReadsInTenMinutesWithTheTimes() throws {
        let event = timed("Standup", "2026-11-04 09:30", "2026-11-04 10:00")
        let found = try #require(plan([event]).first)
        #expect(found.title == "Standup")
        #expect(found.body == "In 10 min, 9:30 to 10:00")
    }

    @Test func thePlaceGoesOnASecondLineButALinkDoesNot() throws {
        let place = timed("Lunch", "2026-11-04 12:00", "2026-11-04 13:00", location: "Café Nord")
        #expect(try #require(plan([place]).first).body == "In 10 min, 12:00 to 13:00\nCafé Nord")
        let link = timed(
            "Call", "2026-11-04 12:00", "2026-11-04 13:00",
            reminders: EventReminders(overrides: [10]), location: "https://zoom.us/j/1")
        #expect(try #require(plan([link]).first).body == "In 10 min, 12:00 to 13:00")
    }

    @Test func anHourOrMoreAheadNamesTheDayNotASpan() throws {
        let event = timed(
            "Workshop", "2026-11-04 12:00", "2026-11-04 13:00",
            reminders: EventReminders(overrides: [90, 60, 59]))
        #expect(plan([event]).map(\.body) == [
            "Today, 12:00 to 13:00", "Today, 12:00 to 13:00", "In 59 min, 12:00 to 13:00",
        ])
    }

    @Test func aReminderTheDayBeforeReadsTomorrow() throws {
        let event = timed(
            "Review", "2026-11-05 09:30", "2026-11-05 10:00",
            reminders: EventReminders(overrides: [1440]))
        #expect(try #require(plan([event]).first).body == "Tomorrow, 9:30 to 10:00")
    }

    @Test func anHourBeforeAnEarlyStartCanStillBeTomorrow() throws {
        // Fires at 23:30 the night before: the day word counts from when it fires.
        let event = timed(
            "Flight", "2026-11-05 00:30", "2026-11-05 02:00",
            reminders: EventReminders(overrides: [60]))
        let found = try #require(plan([event], now: TestData.date("2026-11-04 20:00")).first)
        #expect(found.body == "Tomorrow, 0:30 to 2:00")
    }

    @Test func aReminderDaysAheadNamesTheWeekdayThenTheDate() throws {
        let friday = timed(
            "Offsite", "2026-11-06 09:30", "2026-11-06 10:00",
            reminders: EventReminders(overrides: [2 * 1440]))
        let later = timed(
            "Board", "2026-11-13 09:30", "2026-11-13 10:00",
            reminders: EventReminders(overrides: [9 * 1440]))
        // Both fire at 9:30 today.
        let found = Dictionary(uniqueKeysWithValues: plan([friday, later]).map { ($0.title, $0.body) })
        #expect(found == [
            "Offsite": "Friday, 9:30 to 10:00", "Board": "Friday 13 November, 9:30 to 10:00",
        ])
    }

    @Test func aReminderAtTheStartReadsStartingNow() throws {
        let event = timed(
            "Lunch", "2026-11-04 12:00", "2026-11-04 13:00", reminders: EventReminders(overrides: [0]))
        #expect(try #require(plan([event]).first).body == "Starting now, 12:00 to 13:00")
    }

    @Test func aZeroLengthEventShowsItsStartAlone() throws {
        let event = timed("Pill", "2026-11-04 12:00", "2026-11-04 12:00")
        #expect(try #require(plan([event]).first).body == "In 10 min, 12:00")
    }

    @Test func anUntitledEventKeepsItsPlaceholderTitle() throws {
        let event = timed(Event.untitled, "2026-11-04 12:00", "2026-11-04 13:00")
        #expect(try #require(plan([event]).first).title == "Busy")
    }

    @Test func aTwelveHourDeviceWritesItsOwnClock() throws {
        let american = TestData.calendar("America/New_York", locale: "en_US")
        let event = timed("Standup", "2026-11-04 09:30", "2026-11-04 10:00", zone: american)
        let found = try #require(plan([event], now: TestData.date("2026-11-04 08:00", in: american), calendar: american).first)
        #expect(TestData.plain(found.body) == "In 10 min, 9:30 AM to 10:00 AM")
    }

    // MARK: Identifiers and the diff

    @Test func anEventsIdentifiersAreStableAndDistinct() {
        let event = timed(
            "Call", "2026-11-04 14:00", "2026-11-04 15:00",
            reminders: EventReminders(overrides: [30, 10]), join: "https://zoom.us/j/1")
        let first = plan([event])
        let second = plan([event])
        #expect(first.map(\.identifier) == second.map(\.identifier))
        #expect(Set(first.map(\.identifier)).count == 3)
        #expect(first.allSatisfy { $0.identifier.hasPrefix(ReminderSchedule.identifierPrefix) })
        #expect(Set(first.map(\.thread)).count == 1)
    }

    @Test func aMovedEventKeepsItsIdentifierAndChangesItsSignature() throws {
        let before = try #require(
            plan([timed("Sync", "2026-11-04 10:00", "2026-11-04 10:30", id: "x")]).first)
        let after = try #require(
            plan([timed("Sync", "2026-11-04 11:00", "2026-11-04 11:30", id: "x")]).first)
        #expect(before.identifier == after.identifier)
        #expect(before.signature != after.signature)
    }

    @Test func anUnchangedPlanChangesNothing() {
        let found = plan([
            timed("A", "2026-11-04 10:00", "2026-11-04 10:30"),
            timed("B", "2026-11-04 11:00", "2026-11-04 11:30"),
        ])
        let pending = found.map { PendingReminder(identifier: $0.identifier, signature: $0.signature) }
        let changes = ReminderSchedule.changes(planned: found, pending: pending)
        #expect(changes.isEmpty)
    }

    @Test func onlyWhatChangedIsAddedAndOnlyWhatWentIsRemoved() throws {
        let a = timed("A", "2026-11-04 10:00", "2026-11-04 10:30")
        let b = timed("B", "2026-11-04 11:00", "2026-11-04 11:30")
        let c = timed("C", "2026-11-04 12:00", "2026-11-04 12:30")
        let old = plan([a, b, c])
        let pending = old.map { PendingReminder(identifier: $0.identifier, signature: $0.signature) }

        // B moves, C is gone, D is new, A is untouched.
        let moved = timed("B", "2026-11-04 11:30", "2026-11-04 12:00")
        let d = timed("D", "2026-11-04 13:00", "2026-11-04 13:30")
        var movedB = moved
        movedB.id = b.id
        let next = plan([a, movedB, d])
        let changes = ReminderSchedule.changes(planned: next, pending: pending)

        #expect(Set(changes.add.map(\.title)) == ["B", "D"])
        #expect(changes.remove == [try #require(old.first { $0.title == "C" }).identifier])
        // The moved reminder replaces the old one under its own identifier.
        #expect(!changes.remove.contains(try #require(old.first { $0.title == "B" }).identifier))
    }

    @Test func otherRequestsAreLeftAlone() {
        let found = plan([timed("A", "2026-11-04 10:00", "2026-11-04 10:30")])
        let foreign = PendingReminder(identifier: "push.abc", signature: nil)
        let changes = ReminderSchedule.changes(planned: found, pending: [foreign])
        #expect(changes.add.count == 1)
        #expect(changes.remove.isEmpty)
    }

    @Test func aPendingRequestWithoutASignatureIsReplaced() {
        let found = plan([timed("A", "2026-11-04 10:00", "2026-11-04 10:30")])
        let pending = [PendingReminder(identifier: found[0].identifier, signature: nil)]
        #expect(ReminderSchedule.changes(planned: found, pending: pending).add == found)
    }

    @Test func turningTheSwitchOffMeansAnEmptyPlanAndEverythingRemoved() {
        let found = plan([timed("A", "2026-11-04 10:00", "2026-11-04 10:30")])
        let pending = found.map { PendingReminder(identifier: $0.identifier, signature: $0.signature) }
        let changes = ReminderSchedule.changes(planned: [], pending: pending)
        #expect(changes.add.isEmpty)
        #expect(changes.remove == found.map(\.identifier))
    }

    @Test func theLinkOpensTheEventAndCarriesTheAccount() throws {
        let event = timed("A", "2026-11-04 10:00", "2026-11-04 10:30")
        let found = try #require(plan([event]).first)
        #expect(DayLink(url: found.link) == .event(event.id))
        #expect(found.accountEmail == "you@acme.com")
        #expect(found.event == event.id)
    }
}
