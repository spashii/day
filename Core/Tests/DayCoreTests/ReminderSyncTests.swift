import Foundation
import Testing

@testable import DayCore

/// Reminders through the sync engine: they arrive with the events and the calendar list, an
/// app that has just gained them reads both again once, and the notifications follow from
/// what the cache then holds.
struct ReminderSyncTests {
    typealias Harness = SyncTests.Harness

    /// Personal with a 10-minute popup default (and an email one that is ignored), Family and
    /// Club as in the other sync tests.
    static let list = #"""
        {"kind": "calendar#calendarList", "nextSyncToken": "l9", "items": [
          {"id": "family7k@group.calendar.google.com", "summary": "Family", "backgroundColor": "#33b679", "selected": true, "accessRole": "writer", "timeZone": "Europe/Amsterdam"},
          {"id": "you@gmail.com", "summary": "you@gmail.com", "summaryOverride": "Personal", "backgroundColor": "#039be5", "selected": true, "accessRole": "owner", "primary": true, "timeZone": "Europe/Amsterdam",
           "defaultReminders": [{"method": "popup", "minutes": 10}, {"method": "email", "minutes": 60}]},
          {"id": "club3m@group.calendar.google.com", "summary": "Club", "backgroundColor": "#f6bf26", "selected": true, "accessRole": "reader", "timeZone": "Europe/Amsterdam"}
        ]}
        """#

    /// Standup follows the calendar's default; the dentist sets its own; the coffee has none.
    static let personal = #"""
        {"kind": "calendar#events", "nextSyncToken": "s9", "items": [
          {"id": "standup05", "status": "confirmed", "summary": "Standup",
           "start": {"dateTime": "2026-11-05T09:30:00+01:00"}, "end": {"dateTime": "2026-11-05T09:45:00+01:00"}, "iCalUID": "standup05@google.com",
           "reminders": {"useDefault": true}},
          {"id": "dentist05", "status": "confirmed", "summary": "Dentist", "location": "Tandarts Oost",
           "start": {"dateTime": "2026-11-05T14:30:00+01:00"}, "end": {"dateTime": "2026-11-05T15:15:00+01:00"}, "iCalUID": "dentist05@google.com",
           "reminders": {"useDefault": false, "overrides": [{"method": "popup", "minutes": 60}, {"method": "email", "minutes": 1440}]}},
          {"id": "coffee05", "status": "confirmed", "summary": "Coffee with Ana",
           "start": {"dateTime": "2026-11-05T16:00:00+01:00"}, "end": {"dateTime": "2026-11-05T16:30:00+01:00"}, "iCalUID": "coffee05@google.com"}
        ]}
        """#

    func scriptFullRead(_ h: Harness) {
        h.google.answer("list:full", Self.list)
        h.google.answer("you@gmail.com:\(SyncTests.fullFrom)", Self.personal)
        h.google.answer("family7k@group.calendar.google.com:\(SyncTests.fullFrom)", SyncTests.Script.familyFull)
        h.google.answer("club3m@group.calendar.google.com:\(SyncTests.fullFrom)", SyncTests.Script.clubFull)
    }

    @Test func remindersArriveWithTheEventsAndTheCalendarList() async throws {
        let h = try Harness()
        scriptFullRead(h)
        let report = await h.engine.refresh()
        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)

        #expect(report.data.calendarInfo(SyncTests.personal)?.defaultReminders == [10])
        #expect(report.data.calendarInfo(SyncTests.family)?.defaultReminders == [])
        #expect(try h.event("standup05")?.reminders == EventReminders(useDefault: true))
        #expect(try h.event("dentist05")?.reminders == EventReminders(useDefault: false, overrides: [60]))
        #expect(try h.event("coffee05")?.reminders == nil)

        // The files on disk hold them too, so the next launch schedules before any network.
        let reloaded = h.engine.load()
        #expect(reloaded.calendarInfo(SyncTests.personal)?.defaultReminders == [10])
        let now = h.clock.value
        let planned = ReminderSchedule.plan(reloaded, now: now, calendar: h.calendar)
        #expect(planned.map(\.title) == ["Standup", "Dentist"])
        #expect(planned.map(\.fireDate) == [
            TestData.date("2026-11-05 09:20", in: h.calendar),
            TestData.date("2026-11-05 13:30", in: h.calendar),
        ])
    }

    @Test func aListFromBeforeRemindersIsReadInFullOnceAndTheEventsWithIt() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        #expect(try h.event("dentist07")?.reminders == nil)

        // Both files as the version before reminders wrote them: no number in the list.
        let listName = CacheFile.calendars(SyncTests.account)
        var list = try #require(h.cache.read(CalendarsFile.self, from: listName))
        list.format = CacheFormat.current - 1
        try h.cache.write(list, to: listName)
        let syncName = CacheFile.sync(SyncTests.account)
        var sync = try #require(h.cache.read(SyncFile.self, from: syncName))
        sync.format = CacheFormat.current - 1
        try h.cache.write(sync, to: syncName)

        h.advance(180)
        let before = h.stub.requests.count
        scriptFullRead(h)
        let report = await h.engine.refresh()
        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)

        let keys = h.keys(from: before)
        #expect(keys.contains("list:full"))
        #expect(!keys.contains("list:l1"))
        #expect(keys.contains("you@gmail.com:\(SyncTests.fullFrom)"))
        #expect(report.data.calendarInfo(SyncTests.personal)?.defaultReminders == [10])
        #expect(try h.event("standup05")?.reminders == EventReminders(useDefault: true))
        #expect(h.cache.read(CalendarsFile.self, from: listName)?.format == CacheFormat.current)

        // From here on the list is read by token again.
        h.advance(180)
        let again = h.stub.requests.count
        h.scriptQuiet(list: "l9", personal: "s9", family: "f1", club: "c1")
        _ = await h.engine.refresh()
        let next = h.keys(from: again)
        #expect(next.contains("list:l9"))
        #expect(!next.contains("list:full"))
    }

    @Test func aCurrentListIsStillReadByToken() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(180)
        let before = h.stub.requests.count
        h.scriptQuiet(list: "l1", personal: "s1", family: "f1", club: "c1")
        _ = await h.engine.refresh()
        let keys = h.keys(from: before)
        #expect(keys.contains("list:l1"))
        #expect(!keys.contains("list:full"))
    }

    @Test func aListFileWithoutANumberIsFormatOne() throws {
        let old = #"{"fetchedAt": "2026-11-04T08:00:00Z", "calendars": [], "syncToken": "l1"}"#
        let file = try DayJSON.decoder().decode(CalendarsFile.self, from: Data(old.utf8))
        #expect(file.format == 1)
        #expect(file.syncToken == "l1")
        #expect(CalendarsFile(fetchedAt: .now, labelsFetchedAt: nil, calendars: []).format == CacheFormat.current)
    }
}
