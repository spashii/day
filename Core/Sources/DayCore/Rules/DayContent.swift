import Foundation

// What the Day rows and the widget agree a day contains. One definition of "counted", of the
// part of an event that falls on a day, and of a free gap, so the list and the widget can
// never disagree.

/// The shortest gap that counts as free time: the Day's gap row.
let freeGapThreshold: TimeInterval = 60 * 60

/// Timed, not cancelled, not declined, of kind default or fromGmail. What the Day list draws
/// as a row and what the widget draws from. A `transparent` (free) event is still counted: it
/// takes the day's time, and only the widget leaves it out.
func isCounted(_ event: Event) -> Bool {
    guard case .timed = event.time else { return false }
    return event.status != .cancelled
        && event.response != .declined
        && (event.kind == .default || event.kind == .fromGmail)
}

/// A counted event as it sits on one day. `start` and `end` are the part that falls on the
/// day: an event covering a second day (it runs past 05:00 there) is cut at midnight on each
/// side, so the second day reads `0:00` as its start. An event that merely crosses midnight
/// (a flight landing at 00:15) belongs to its first day only and keeps its true end.
struct DaySpan {
    var event: Event
    var start: Date
    var end: Date
    /// Position in the input, the last tiebreak, so equal times keep account order.
    var order: Int
}

/// The part of a timed event that falls on `day`, nil when it does not.
func span(of event: Event, on day: CivilDate, calendar: Calendar) -> (start: Date, end: Date)? {
    guard case .timed(let start, let end, _) = event.time else { return nil }
    let covered = coveredDays(event, calendar: calendar)
    guard covered.contains(day) else { return nil }
    let from = covered.lowerBound < day ? day.date(in: calendar) : start
    let to = covered.upperBound > day ? day.adding(days: 1).date(in: calendar) : end
    return (from, max(from, to))
}

/// Counted events on `day`, earliest first; equal starts by earlier end, then input order.
func daySpans(on day: CivilDate, events: [Event], calendar: Calendar) -> [DaySpan] {
    events.enumerated().compactMap { index, event -> DaySpan? in
        guard isCounted(event), let part = span(of: event, on: day, calendar: calendar)
        else { return nil }
        return DaySpan(event: event, start: part.start, end: part.end, order: index)
    }
    .sorted { a, b in
        (a.start, a.end, a.order) < (b.start, b.end, b.order)
    }
}

/// A stretch between counted events with nothing in it.
struct FreeGap {
    var start: Date
    var end: Date

    var length: TimeInterval {
        end.timeIntervalSince(start)
    }

    func contains(_ now: Date) -> Bool {
        start <= now && now < end
    }
}

/// Whether an event covers the whole of `day`. All-day items cover their civil days; a timed
/// one has to run from midnight to midnight or longer.
func coversWholeDay(_ event: Event, on day: CivilDate, calendar: Calendar) -> Bool {
    switch event.time {
    case .allDay(let first, let endExclusive):
        return first <= day && day < endExclusive
    case .timed(let from, let to, _):
        return from <= day.date(in: calendar) && to >= day.adding(days: 1).date(in: calendar)
    }
}
