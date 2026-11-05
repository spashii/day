import Foundation
import Testing

@testable import DayCore

/// Google's reminders into the cache: popup reminders only, the calendar's defaults beside
/// the event's own, and nothing a strange answer can do to the event around them.
struct ReminderDecodingTests {
    static let calendar = TestData.workCalendar

    static func event(_ reminders: String?) throws -> Event {
        let field = reminders.map { #", "reminders": \#($0)"# } ?? ""
        let json = #"{"id": "e1", "summary": "Standup", "start": {"dateTime": "2026-11-04T10:00:00+01:00"}, "end": {"dateTime": "2026-11-04T10:30:00+01:00"}\#(field)}"#
        let google = try JSONDecoder().decode(GoogleEvent.self, from: Data(json.utf8))
        return try #require(GoogleDecoding.event(google, on: calendar))
    }

    @Test func overridesKeepOnlyPopupRemindersAscending() throws {
        let event = try Self.event(
            #"{"useDefault": false, "overrides": [{"method": "email", "minutes": 1440}, {"method": "popup", "minutes": 30}, {"method": "popup", "minutes": 10}, {"method": "popup", "minutes": 30}]}"#)
        #expect(event.reminders == EventReminders(useDefault: false, overrides: [10, 30]))
    }

    @Test func useDefaultIsKeptAndTheOverridesBesideItAreNot() throws {
        let event = try Self.event(
            #"{"useDefault": true, "overrides": [{"method": "popup", "minutes": 5}]}"#)
        #expect(event.reminders == EventReminders(useDefault: true, overrides: []))
        #expect(try Self.event(#"{"useDefault": true}"#).reminders == EventReminders(useDefault: true))
    }

    @Test func anEventThatRemindsNowhereKeepsNothing() throws {
        #expect(try Self.event(nil).reminders == nil)
        #expect(try Self.event(#"{"useDefault": false}"#).reminders == nil)
        #expect(try Self.event(#"{}"#).reminders == nil)
        #expect(
            try Self.event(#"{"useDefault": false, "overrides": [{"method": "email", "minutes": 10}]}"#)
                .reminders == nil)
    }

    @Test func anAllDayOverrideKeepsItsMinutesPastADay() throws {
        let event = try Self.event(
            #"{"useDefault": false, "overrides": [{"method": "popup", "minutes": 900}, {"method": "popup", "minutes": 40320}]}"#)
        #expect(event.reminders?.overrides == [900, 40320])
    }

    @Test func aStrangeAnswerNeverCostsTheEvent() throws {
        for reminders in [
            #""soon""#, "7", "[]", #"{"overrides": "x"}"#, #"{"overrides": [3, null, "a"]}"#,
            #"{"overrides": [{"method": 5, "minutes": "ten"}]}"#, #"{"useDefault": "yes"}"#,
        ] {
            let event = try Self.event(reminders)
            #expect(event.title == "Standup", "reminders: \(reminders)")
            #expect(event.reminders == nil, "reminders: \(reminders)")
        }
        // A good reminder beside a broken one still counts.
        let mixed = try Self.event(
            #"{"overrides": [{"method": "popup", "minutes": "ten"}, {"method": "popup", "minutes": 15}]}"#)
        #expect(mixed.reminders?.overrides == [15])
    }

    @Test func aCalendarKeepsItsPopupDefaults() throws {
        let entries = try JSONDecoder().decode(
            GooglePage<GoogleCalendarListEntry>.self,
            from: Data(
                #"""
                {"items": [
                  {"id": "a@acme.com", "summary": "Work", "primary": true, "accessRole": "owner",
                   "defaultReminders": [{"method": "popup", "minutes": 10}, {"method": "email", "minutes": 60}, {"method": "popup", "minutes": 1}]},
                  {"id": "b@acme.com", "summary": "Mail only", "defaultReminders": [{"method": "email", "minutes": 5}]},
                  {"id": "c@acme.com", "summary": "None"},
                  {"id": "d@acme.com", "summary": "Odd", "defaultReminders": "x"}
                ]}
                """#.utf8)
        ).items
        let infos = GoogleDecoding.calendars(entries, account: TestData.work.id)
        #expect(infos.map(\.name) == ["Work", "Mail only", "None", "Odd"])
        #expect(infos.map(\.defaultReminders) == [[1, 10], [], [], []])
    }

    @Test func theFieldsMasksAskForReminders() {
        #expect(CalendarAPI.eventFields.contains("reminders(useDefault,overrides(method,minutes))"))
        #expect(CalendarAPI.calendarListFields.contains("defaultReminders(method,minutes)"))
        // The sync token still has to come back with every page.
        #expect(CalendarAPI.eventFields.contains("nextSyncToken"))
        #expect(CalendarAPI.calendarListFields.contains("nextSyncToken"))
    }

    @Test func remindersSurviveTheCacheAndAnOlderCacheStillLoads() throws {
        var event = TestData.event("Sync", "2026-11-04 10:00", "2026-11-04 11:00")
        event.reminders = EventReminders(useDefault: false, overrides: [10, 60])
        let data = try DayJSON.encoder().encode(event)
        #expect(try DayJSON.decoder().decode(Event.self, from: data) == event)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["reminders"] = nil
        let old = try DayJSON.decoder().decode(
            Event.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.reminders == nil)
        #expect(old.title == "Sync")

        var info = TestData.workCalendar
        info.defaultReminders = [10]
        let saved = try DayJSON.encoder().encode(info)
        #expect(try DayJSON.decoder().decode(CalendarInfo.self, from: saved) == info)
        var bare = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        bare["defaultReminders"] = nil
        let older = try DayJSON.decoder().decode(
            CalendarInfo.self, from: JSONSerialization.data(withJSONObject: bare))
        #expect(older.defaultReminders.isEmpty)
    }

    @Test func eventsWithoutRemindersAddNothingToTheCache() throws {
        let event = TestData.event("Sync", "2026-11-04 10:00", "2026-11-04 11:00")
        let json = try #require(String(data: DayJSON.encoder().encode(event), encoding: .utf8))
        #expect(!json.contains("reminders"))
    }

    @Test func aChangedEventKeepsItsRemindersThroughAnIncrementalChange() throws {
        let google = try JSONDecoder().decode(
            GoogleEvent.self,
            from: Data(
                #"{"id": "e1", "start": {"dateTime": "2026-11-04T10:00:00+01:00"}, "reminders": {"useDefault": true}}"#.utf8))
        guard case .upsert(let event) = GoogleDecoding.change(google, on: Self.calendar) else {
            Issue.record("expected an upsert")
            return
        }
        #expect(event.reminders == EventReminders(useDefault: true))
    }
}
