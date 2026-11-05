import Foundation

/// The current and next event, for the Lock Screen, the Mac menu bar and the Day's Join
/// window, so no surface ever disagrees.
///
/// Candidates: timed events not cancelled, not declined, of kind default or fromGmail, and
/// not marked free, from now through the end of the seventh day ahead. `current` started at
/// or before now and has not ended (the one that started last if several); `next` is the
/// first that starts after now. Pass merged events from visible calendars.
public func nextEvents(events: [Event], now: Date, calendar: Calendar) -> NextEvents {
    let list = candidates(events: events, now: now, calendar: calendar)
    return NextEvents(
        current: currentCandidate(in: list, now: now)?.event,
        next: list.first { $0.start > now }?.event)
}

/// The event Join acts on: the current one, else the next one from 10 minutes before its
/// start, and only while it has a link. Command-J on the Mac and the menu bar panel use it.
public func joinableEvent(next: NextEvents, now: Date) -> Event? {
    joinWindow(next: next, now: now).first
}

/// The events Join shows on in the Day list: the current one while it has a link, and the
/// next one from 10 minutes before its start while it has a link. At most these two, current
/// first.
func joinWindow(next: NextEvents, now: Date) -> [Event] {
    var events: [Event] = []
    if let current = next.current, current.joinURL != nil {
        events.append(current)
    }
    if let upcoming = next.next, upcoming.joinURL != nil,
        case .timed(let start, _, _) = upcoming.time,
        start.timeIntervalSince(now) <= 10 * 60
    {
        events.append(upcoming)
    }
    return events
}

/// Timed, not cancelled, not declined, default or fromGmail, not free.
func isCandidate(_ event: Event) -> Bool {
    isCounted(event) && !event.isFree
}

/// A candidate with its times read out once.
struct Candidate {
    var event: Event
    var start: Date
    var end: Date
}

/// The candidates that have not ended and start before the horizon, earliest start first;
/// equal starts by earlier end, then input order. The horizon is the end of the seventh day
/// ahead, the window the widget can fetch for itself.
func candidates(events: [Event], now: Date, calendar: Calendar) -> [Candidate] {
    let horizon = CivilDate(now, in: calendar).adding(days: 8).date(in: calendar)
    return events.enumerated().compactMap { index, event -> (Candidate, Int)? in
        guard isCandidate(event), case .timed(let start, let end, _) = event.time,
            end > now, start < horizon
        else { return nil }
        return (Candidate(event: event, start: start, end: end), index)
    }
    .sorted { a, b in
        (a.0.start, a.0.end, a.1) < (b.0.start, b.0.end, b.1)
    }
    .map(\.0)
}

/// The candidate that started last and has not ended; of several with that start, the one
/// that ends first. `list` is sorted as `candidates` returns it.
func currentCandidate(in list: [Candidate], now: Date) -> Candidate? {
    var current: Candidate?
    for candidate in list where candidate.start <= now {
        if let held = current, held.start == candidate.start { continue }
        current = candidate
    }
    return current
}
