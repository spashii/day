import Foundation
import Testing

@testable import DayCore

/// Edits to a whole series, which under `singleEvents=true` replace every instance in the
/// window: an instance's ID is `<series>_<original start>`, so moving the series gives each
/// one a new ID, and a "this and following" edit starts a second series. Google does not
/// document that the old IDs come back cancelled, so these answers leave them out, the case
/// that would show a meeting twice. All people, events and tokens are invented.
struct SyncSeriesTests {
    typealias Harness = SyncTests.Harness
    typealias Script = SyncTests.Script

    /// A confirmed instance on Amsterdam time.
    static func instance(
        _ id: String, series: String, day: String, from: String, to: String, was original: String
    ) -> String {
        """
        {"id": "\(id)", "status": "confirmed", "summary": "Standup",
         "start": {"dateTime": "2026-11-\(day)T\(from):00+01:00", "timeZone": "Europe/Amsterdam"}, "end": {"dateTime": "2026-11-\(day)T\(to):00+01:00", "timeZone": "Europe/Amsterdam"},
         "recurringEventId": "\(series)", "originalStartTime": {"dateTime": "2026-11-\(day)T\(original):00+01:00", "timeZone": "Europe/Amsterdam"}, "iCalUID": "\(series)@google.com"}
        """
    }

    /// The rest of Personal's window, as the full read holds it.
    static let others = #"""
        {"id": "dentist07", "status": "confirmed", "summary": "Dentist", "location": "Tandarts Oost",
         "start": {"dateTime": "2026-11-07T14:30:00+01:00"}, "end": {"dateTime": "2026-11-07T15:15:00+01:00"}, "iCalUID": "dentist07@google.com"},
        {"id": "coffee10", "status": "confirmed", "summary": "Coffee with Ana",
         "start": {"dateTime": "2026-11-10T10:00:00+01:00"}, "end": {"dateTime": "2026-11-10T10:30:00+01:00"}, "iCalUID": "coffee10@google.com"},
        {"id": "planning12", "status": "confirmed", "summary": "Quarterly planning",
         "start": {"dateTime": "2026-11-12T13:00:00+01:00"}, "end": {"dateTime": "2026-11-12T16:00:00+01:00"}, "iCalUID": "planning12@google.com"}
        """#

    /// Changing the Standup series to 10:00 for all events: three instances with new IDs,
    /// and nothing for the old ones.
    static let allEventsMoved = """
        {"kind": "calendar#events", "nextSyncToken": "s2", "items": [
        \(instance("standupx_20261104T090000Z", series: "standupx", day: "04", from: "10:00", to: "10:15", was: "10:00")),
        \(instance("standupx_20261105T090000Z", series: "standupx", day: "05", from: "10:00", to: "10:15", was: "10:00")),
        \(instance("standupx_20261106T090000Z", series: "standupx", day: "06", from: "10:00", to: "10:15", was: "10:00"))
        ]}
        """

    /// Personal read by window afterwards.
    static let personalAfterAllEventsMoved = """
        {"kind": "calendar#events", "nextSyncToken": "s5", "items": [
        \(instance("standupx_20261104T090000Z", series: "standupx", day: "04", from: "10:00", to: "10:15", was: "10:00")),
        \(instance("standupx_20261105T090000Z", series: "standupx", day: "05", from: "10:00", to: "10:15", was: "10:00")),
        \(instance("standupx_20261106T090000Z", series: "standupx", day: "06", from: "10:00", to: "10:15", was: "10:00")),
        \(others)
        ]}
        """

    /// "This and following" from Thursday, at 10:00: a second series, and nothing for the
    /// instances of the first one it replaces.
    static let followingSplit = """
        {"kind": "calendar#events", "nextSyncToken": "s2", "items": [
        \(instance("standupy_20261105T090000Z", series: "standupy", day: "05", from: "10:00", to: "10:15", was: "10:00")),
        \(instance("standupy_20261106T090000Z", series: "standupy", day: "06", from: "10:00", to: "10:15", was: "10:00"))
        ]}
        """

    static let personalAfterSplit = """
        {"kind": "calendar#events", "nextSyncToken": "s5", "items": [
        \(instance("standupx_20261104T083000Z", series: "standupx", day: "04", from: "09:30", to: "09:45", was: "09:30")),
        \(instance("standupy_20261105T090000Z", series: "standupy", day: "05", from: "10:00", to: "10:15", was: "10:00")),
        \(instance("standupy_20261106T090000Z", series: "standupy", day: "06", from: "10:00", to: "10:15", was: "10:00")),
        \(others)
        ]}
        """

    /// One occurrence cancelled and the next moved, the way one edited occurrence arrives.
    static let oneOccurrenceEach = """
        {"kind": "calendar#events", "nextSyncToken": "s2", "items": [
         {"id": "standupx_20261105T083000Z", "status": "cancelled", "recurringEventId": "standupx",
          "originalStartTime": {"dateTime": "2026-11-05T09:30:00+01:00", "timeZone": "Europe/Amsterdam"}},
        \(instance("standupx_20261106T083000Z", series: "standupx", day: "06", from: "11:00", to: "11:15", was: "09:30"))
        ]}
        """

    static func standups(_ h: Harness) throws -> [Event] {
        try h.stored().events.filter { $0.title == "Standup" }
            .sorted { $0.time.start(in: h.calendar) < $1.time.start(in: h.calendar) }
    }

    /// Each cases starts from the initial sync and the next refresh three minutes later.
    static func nextRefresh(_ h: Harness) async -> (report: SyncReport, keys: [String]) {
        h.advance(180)
        h.google.answer("list:l1", #"{"items": [], "nextSyncToken": "l2"}"#)
        h.google.answer("family7k@group.calendar.google.com:f1", #"{"items": [], "nextSyncToken": "f2"}"#)
        h.google.answer("club3m@group.calendar.google.com:c1", #"{"items": [], "nextSyncToken": "c2"}"#)
        let before = h.stub.requests.count
        let report = await h.engine.refresh()
        return (report, h.keys(from: before))
    }

    // MARK: Whole series

    @Test func changingTheTimeOfAllEventsLeavesNoOldInstance() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.google.answer("you@gmail.com:s1", SyncSeriesTests.allEventsMoved)
        h.google.answer("you@gmail.com:\(SyncTests.fullFrom)", SyncSeriesTests.personalAfterAllEventsMoved)
        let (report, keys) = await SyncSeriesTests.nextRefresh(h)

        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)
        // The change set is read, found to rewrite a series, and the window is read once
        // more in the same refresh. The other calendars read only their changes.
        #expect(keys.filter { $0.hasPrefix("you@gmail.com:") } == ["you@gmail.com:s1", "you@gmail.com:\(SyncTests.fullFrom)"])
        #expect(keys.filter { $0.hasPrefix("family7k") } == ["family7k@group.calendar.google.com:f1"])

        // Three standups, all at 10:00: nothing is left at 9:30.
        let standups = try SyncSeriesTests.standups(h)
        #expect(standups.map(\.id.googleID) == [
            "standupx_20261104T090000Z", "standupx_20261105T090000Z", "standupx_20261106T090000Z",
        ])
        for standup in standups {
            let start = standup.time.start(in: h.calendar)
            #expect(h.calendar.component(.hour, from: start) == 10)
        }
        // The rest of the calendar came back with the window read.
        #expect(try h.event("dentist07") != nil)
        #expect(try h.event("planning12") != nil)

        let state = try #require(try h.stored().state(of: SyncTests.personal))
        #expect(state.token == "s5")
        #expect(state.fullSyncAt == h.clock.value)

        // The day shows one standup.
        let friday = CivilDate(year: 2026, month: 11, day: 6)
        #expect(report.data.events(in: friday...friday, calendar: h.calendar).filter { $0.title == "Standup" }.count == 1)
        #expect(report.snapshot?.events.filter { $0.title == "Standup" }.count == 3)
    }

    @Test func aThisAndFollowingEditLeavesNoOldInstance() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.google.answer("you@gmail.com:s1", SyncSeriesTests.followingSplit)
        h.google.answer("you@gmail.com:\(SyncTests.fullFrom)", SyncSeriesTests.personalAfterSplit)
        let (report, keys) = await SyncSeriesTests.nextRefresh(h)

        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)
        #expect(keys.contains("you@gmail.com:\(SyncTests.fullFrom)"))

        // Wednesday's stays at 9:30; Thursday's and Friday's are the new series at 10:00 and
        // the first series' instances for those days are gone.
        let standups = try SyncSeriesTests.standups(h)
        #expect(standups.map(\.id.googleID) == [
            "standupx_20261104T083000Z", "standupy_20261105T090000Z", "standupy_20261106T090000Z",
        ])
        let starts = standups.map { h.calendar.dateComponents([.day, .hour, .minute], from: $0.time.start(in: h.calendar)) }
        #expect(starts.map(\.hour) == [9, 10, 10])
        #expect(starts.map(\.minute) == [30, 0, 0])
    }

    // MARK: One occurrence is not a series

    @Test func oneEditedOccurrenceIsAppliedWithoutAWindowRead() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.google.answer("you@gmail.com:s1", SyncSeriesTests.oneOccurrenceEach)
        let (report, keys) = await SyncSeriesTests.nextRefresh(h)

        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)
        // Cancelled instances do not count, and one moved instance is one change.
        #expect(keys.filter { $0.hasPrefix("you@gmail.com:") } == ["you@gmail.com:s1"])
        let standups = try SyncSeriesTests.standups(h)
        #expect(standups.map(\.id.googleID) == ["standupx_20261104T083000Z", "standupx_20261106T083000Z"])
        #expect(try h.stored().state(of: SyncTests.personal)?.token == "s2")
    }

    @Test func onlyDifferentInstancesOfOneSeriesCountAsASeriesEdit() {
        func item(_ id: String, series: String?, status: String = "confirmed") -> GoogleEvent {
            GoogleEvent(id: id, status: status, recurringEventId: series)
        }
        #expect(!SyncEngine.editsASeries([]))
        #expect(!SyncEngine.editsASeries([item("a", series: nil), item("b", series: nil)]))
        #expect(!SyncEngine.editsASeries([item("a_1", series: "a")]))
        // The same instance twice is still one.
        #expect(!SyncEngine.editsASeries([item("a_1", series: "a"), item("a_1", series: "a")]))
        // Two instances of two series are two single edits.
        #expect(!SyncEngine.editsASeries([item("a_1", series: "a"), item("b_1", series: "b")]))
        // A cancelled instance and an edited one.
        #expect(!SyncEngine.editsASeries([item("a_1", series: "a", status: "cancelled"), item("a_2", series: "a")]))
        #expect(!SyncEngine.editsASeries([item("a_1", series: "a", status: "cancelled"), item("a_2", series: "a", status: "cancelled")]))
        #expect(SyncEngine.editsASeries([item("a_1", series: "a"), item("a_2", series: "a")]))
        #expect(SyncEngine.editsASeries([item("x", series: nil), item("a_1", series: "a"), item("b_1", series: "b"), item("a_2", series: "a")]))
    }

    // MARK: The same, for the widget

    @Test func theWidgetReadsItsDaysWhenASeriesWasEdited() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(20 * 60)
        h.google.answer("you@gmail.com:s1", SyncSeriesTests.allEventsMoved)
        // Today through eight days ahead, Wednesday 4 November in Amsterdam.
        h.google.answer("you@gmail.com:2026-11-03T23:00:00Z", SyncSeriesTests.personalAfterAllEventsMoved)
        h.google.answer("family7k@group.calendar.google.com:f1", #"{"items": [], "nextSyncToken": "f2"}"#)
        h.google.answer("club3m@group.calendar.google.com:c1", #"{"items": [], "nextSyncToken": "c2"}"#)
        let snapshot = try #require(await h.engine.refreshWidgetSnapshot())
        #expect(h.google.misses.isEmpty)

        let standups = snapshot.events.filter { $0.title == "Standup" }
        #expect(standups.count == 3)
        for standup in standups {
            #expect(h.calendar.component(.hour, from: standup.time.start(in: h.calendar)) == 10)
        }
        // The app's files stay for the app: its token is still s1 and it reads the change
        // set, and the window, itself.
        #expect(try h.stored().state(of: SyncTests.personal)?.token == "s1")
    }
}
