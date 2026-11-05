import DayCore
import Foundation

/// Where a `day://` link lands, once it has been checked against what the store holds. The
/// widget builds the links with `DayLink`; this is the other end, shared by both apps.
///
/// - `day://day/2026-11-04` lands on that day.
/// - `day://event/<account>/<calendar>/<event>` lands on the event, to show its sheet over
///   its day. An event the cache no longer holds (a widget tapped days later, an account
///   removed since) lands on today instead, because a link must never open nothing.
enum Route: Hashable, Sendable {
    case day(CivilDate)
    case event(Event)

    /// The day the link opens: the day itself, or for an event the day that holds it. An
    /// event under way across midnight opens today; any other opens its first day.
    @MainActor
    func day(in store: any CalendarStore) -> CivilDate {
        switch self {
        case .day(let day):
            return day
        case .event(let event):
            let days = coveredDays(event, calendar: store.calendar)
            return days.contains(store.today) ? store.today : days.lowerBound
        }
    }
}

extension CalendarStore {
    /// The route for a `day://` URL, or nil for any other URL.
    func route(for url: URL) -> Route? {
        switch DayLink(url: url) {
        case .day(let day):
            return .day(day)
        case .event(let id):
            return event(with: id).map(Route.event) ?? .day(today)
        case nil:
            return nil
        }
    }

    /// The event a link names, looked up in the cached window. The ID is the kept copy's when
    /// the same event sits on two accounts; a widget built before a calendar was hidden may
    /// carry the other copy's, so any copy sitting on the named calendar also matches.
    func event(with id: EventID) -> Event? {
        let events = events(in: SyncEngine.defaultWindow(today: today))
        return events.first { $0.id == id }
            ?? events.first { $0.id.googleID == id.googleID && $0.calendars.contains(id.calendar) }
    }
}
