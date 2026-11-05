import DayCore
import Foundation

/// Invented data for the widget while no Google client exists, and for the widget gallery.
///
/// The fixture's week is moved by whole days so its Wednesday lands on today. Clock times
/// stay as written and "now" is the real clock, so the Lock Screen shows a believable next
/// event at any hour on any date, with the same text the rules would write for real data.
enum NextDemo {
    /// True while `GoogleClientID` still holds the placeholder, the rule `FixtureStore` uses
    /// to decide the app runs on invented data.
    static var isActive: Bool {
        let id = Bundle.main.object(forInfoDictionaryKey: DayIdentifiers.googleClientIDKey)
        return id == nil || (id as? String) == DayIdentifiers.googleClientPlaceholder
    }

    /// The invented snapshot for `now`, or nil outside demo mode. Reads the bundle, so never
    /// call it from `placeholder`.
    static func load(now: Date) -> (snapshot: WidgetSnapshot, calendar: Calendar)? {
        guard isActive else { return nil }
        return loadAlways(now: now)
    }

    /// The same, regardless of the client ID: the gallery always shows invented events.
    static func loadAlways(now: Date) -> (snapshot: WidgetSnapshot, calendar: Calendar)? {
        guard let url = Bundle.main.url(forResource: "invented-week", withExtension: "json"),
            let fixture = try? Fixture.load(from: url)
        else { return nil }
        return (snapshot(from: fixture, now: now), fixture.calendar)
    }

    /// Visible calendars only, accounts in the order added, duplicates merged, and the week
    /// moved so the fixture's day lands on `now`'s day.
    static func snapshot(from fixture: Fixture, now: Date) -> WidgetSnapshot {
        let calendar = fixture.calendar
        let days = CivilDate(fixture.now, in: calendar).distance(
            to: CivilDate(now, in: calendar))
        let visible = Set(fixture.calendars.filter(\.selected).map(\.id))
        let order = Dictionary(
            uniqueKeysWithValues: fixture.accounts.enumerated().map { ($0.element.id, $0.offset) })
        let events = fixture.events
            .enumerated()
            .filter { visible.contains($0.element.id.calendar) }
            .sorted {
                (order[$0.element.account] ?? .max, $0.offset)
                    < (order[$1.element.account] ?? .max, $1.offset)
            }
            .map { shift($0.element, days: days, calendar: calendar) }
        return WidgetSnapshot(
            fetchedAt: now, accountCount: fixture.accounts.count, signedOutAccounts: 0,
            events: merged(events))
    }

    private static func shift(_ event: Event, days: Int, calendar: Calendar) -> Event {
        func moved(_ date: Date) -> Date {
            calendar.date(byAdding: .day, value: days, to: date) ?? date
        }
        var event = event
        switch event.time {
        case .allDay(let start, let end):
            event.time = .allDay(start: start.adding(days: days), endExclusive: end.adding(days: days))
        case .timed(let start, let end, let zone):
            event.time = .timed(start: moved(start), end: moved(end), authoredZone: zone)
        }
        event.originalStart = event.originalStart.map(moved)
        return event
    }
}
