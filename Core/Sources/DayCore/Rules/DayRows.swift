import Foundation

/// The Day list for `day`, top to bottom: all-day lines, the Earlier row (today only), the
/// now line, event rows with their one unusual second line and Join, and gap rows. Pass
/// merged events from visible calendars covering `day` and the day after it.
///
/// - All-day lines: at most three, then `2 more`. Multi-day items carry `day 2 of 3`.
///   Birthdays live here. Working location and focus time never appear.
/// - Earlier (today only): everything that has ended, folded into one row.
/// - Now line: before the first event still to come, when none is in progress. Never through
///   an event in progress, and not after the last event.
/// - Gap rows: a gap of 60 minutes or more between events, the same threshold and events as
///   the summary's free block. The gap that holds now reads `Free until 16:00`.
/// - Rows: declined and cancelled events do not appear.
public func dayRows(day: CivilDate, events: [Event], now: Date, calendar: Calendar) -> [DayRow] {
    var rows: [DayRow] = []

    let lines = allDayLines(on: day, events: events, calendar: calendar)
    rows += lines.prefix(3).map { DayRow.allDay($0.event, position: $0.position) }
    if lines.count > 3 {
        rows.append(.allDayMore(Formatting.more(lines.count - 3)))
    }

    let isToday = CivilDate(now, in: calendar) == day
    let spans = daySpans(on: day, events: events, calendar: calendar)
    let ended = isToday ? spans.filter { $0.end <= now } : []
    let shown = isToday ? spans.filter { $0.end > now } : spans
    if !ended.isEmpty {
        rows.append(.earlier(ended.map(\.event)))
    }

    let upcoming = nextEvents(events: events, now: now, calendar: calendar)
    let joinIDs = Set(joinWindow(next: upcoming, now: now).map(\.id))

    // The now line sits above the first event still to come. When that event has already
    // started it is in progress, and nothing is drawn through it.
    var nowLineBefore: EventID?
    if isToday, let first = shown.first, first.start > now {
        nowLineBefore = first.event.id
    }

    var reach = ended.map(\.end).max()
    for span in shown {
        if span.event.id == nowLineBefore {
            rows.append(.nowLine(now))
        }
        if let reach, span.start.timeIntervalSince(reach) >= freeGapThreshold {
            let gap = FreeGap(start: reach, end: span.start)
            // A gap wholly in the past is already folded into Earlier.
            if !isToday || gap.end > now {
                let text = gap.contains(now)
                    ? "Free until \(Formatting.time(gap.end, calendar: calendar))"
                    : Formatting.free(gap.length)
                rows.append(.gap(text, start: gap.start))
            }
        }
        reach = max(reach ?? span.end, span.end)
        rows.append(
            .event(
                span.event,
                secondLine: secondLine(for: span.event, now: now),
                showsJoin: joinIDs.contains(span.event.id)))
    }
    return rows
}

/// The one unusual thing about a row, first match: `ends in 25 min` while in progress,
/// `in 20 min` within the hour before the start, `No reply yet` on an unanswered one-off with
/// other guests, the first line of a physical location. Never the meeting service.
private func secondLine(for event: Event, now: Date) -> String? {
    if case .timed(let start, let end, _) = event.time {
        if start <= now, now < end {
            return "ends in \(Formatting.countdown(end.timeIntervalSince(now)))"
        }
        if start > now, start.timeIntervalSince(now) <= 60 * 60 {
            return "in \(Formatting.countdown(start.timeIntervalSince(now)))"
        }
    }
    if !event.isRecurring, event.hasOtherAttendees, event.response == .needsAction {
        return "No reply yet"
    }
    return Formatting.place(event)
}

private struct AllDayLine {
    var event: Event
    var position: String?
}

/// All-day items on `day`, in the order they began. Timed out-of-office events join them
/// when they are one-offs or cover the whole day, because the month draws a bar for them
/// and the day has to say what the bar was: partial recurring ones are routine and stay out.
/// A timed one that covers only part of the day carries its hours as the position
/// (`9:30 to 12:00`, the form of the widget's line 2), because a bare title would read as
/// the whole day away.
private func allDayLines(on day: CivilDate, events: [Event], calendar: Calendar) -> [AllDayLine] {
    var found: [(line: AllDayLine, began: CivilDate, order: Int)] = []
    for (order, event) in events.enumerated() {
        guard event.status != .cancelled, event.response != .declined,
            event.kind != .workingLocation, event.kind != .focusTime
        else { continue }
        switch event.time {
        case .allDay(let start, let endExclusive):
            guard start <= day, day < endExclusive else { continue }
            let total = start.distance(to: endExclusive)
            let position = total > 1 ? "day \(start.distance(to: day) + 1) of \(total)" : nil
            found.append((AllDayLine(event: event, position: position), start, order))
        case .timed:
            guard event.kind == .outOfOffice else { continue }
            let covered = coveredDays(event, calendar: calendar)
            guard covered.contains(day) else { continue }
            let whole = coversWholeDay(event, on: day, calendar: calendar)
            guard !event.isRecurring || whole else { continue }
            var position: String?
            if covered.count > 1 {
                position = "day \(covered.lowerBound.distance(to: day) + 1) of \(covered.count)"
            } else if !whole, let part = span(of: event, on: day, calendar: calendar) {
                let from = Formatting.time(part.start, calendar: calendar)
                let to = Formatting.time(part.end, calendar: calendar)
                position = "\(from) to \(to)"
            }
            found.append((AllDayLine(event: event, position: position), covered.lowerBound, order))
        }
    }
    return found.sorted { ($0.began, $0.order) < ($1.began, $1.order) }.map(\.line)
}
