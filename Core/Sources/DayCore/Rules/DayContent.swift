import Foundation

// What the summary, the Day rows and the widget agree a day contains. One definition of
// "counted", of the part of an event that falls on a day, and of a free gap, so the summary's
// free block and the list's gap row can never disagree.

/// The shortest gap that counts as free time: the summary's free block and the Day's gap row.
let freeGapThreshold: TimeInterval = 60 * 60

/// Timed, not cancelled, not declined, of kind default or fromGmail. What the summary counts
/// and what the Day list draws as a row. A `transparent` (free) event is still counted: it
/// takes the day's time, and only the overlap rule and the widget leave it out.
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

    func overlaps(_ other: DaySpan) -> Bool {
        min(end, other.end) > max(start, other.start)
    }
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

/// The gaps of `freeGapThreshold` or more between consecutive counted events, with
/// overlapping events counted as one stretch of busy time. Only between events: the time
/// before the first start and after the last end is not a gap.
func freeGaps(_ spans: [DaySpan]) -> [FreeGap] {
    guard var reach = spans.first?.end else { return [] }
    var gaps: [FreeGap] = []
    for span in spans.dropFirst() {
        if span.start.timeIntervalSince(reach) >= freeGapThreshold {
            gaps.append(FreeGap(start: reach, end: span.start))
        }
        reach = max(reach, span.end)
    }
    return gaps
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

/// The out-of-office event that covers the whole of `day`, the one that ends last if there
/// are several.
func wholeDayOutOfOffice(on day: CivilDate, events: [Event], calendar: Calendar) -> Event? {
    var best: (event: Event, end: Date)?
    for event in events
    where event.kind == .outOfOffice && event.status != .cancelled && event.response != .declined
        && coversWholeDay(event, on: day, calendar: calendar)
    {
        let end = event.time.end(in: calendar)
        if best == nil || end > best!.end { best = (event, end) }
    }
    return best?.event
}

/// The day an out-of-office event returns on, for `until Friday`: the day its end falls on.
/// An end at midnight is exclusive, so it names the first day back; an all-day item's
/// exclusive end does the same.
func outOfOfficeReturn(_ event: Event, calendar: Calendar) -> CivilDate {
    switch event.time {
    case .allDay(_, let endExclusive): endExclusive
    case .timed(_, let end, _): CivilDate(end, in: calendar)
    }
}
