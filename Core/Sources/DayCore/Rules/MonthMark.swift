import Foundation

/// How an event draws in the month, first match wins. Shared by the iPhone, the Mac and
/// day-cli. `local` is the reader's calendar and zone, which decide the days an event covers.
///
/// 1. Hidden: cancelled, declined, working location, focus time, birthday, recurring out of
///    office.
/// 2. Bar: a one-off that is all-day, covers more than one day, is out of office, or came
///    from Gmail.
/// 3. Dot: any recurring event.
/// 4. Titled: a timed one-off with an outside guest, on a personal account, at a place, or
///    two hours or longer.
/// 5. Dot: every other timed one-off (short internal calls).
///
/// Rule 5 is a settled design choice, not a default: short internal one-off calls are dots
/// too, so the titled lines that remain are the ones worth reading. It stays one marked
/// branch, so the month's density has a single place to change.
public func monthMark(
    _ event: Event, account: Account, calendar: CalendarInfo, in local: Calendar
) -> MonthMark {
    // Rule 1.
    if event.status == .cancelled || event.response == .declined {
        return .hidden
    }
    switch event.kind {
    case .workingLocation, .focusTime, .birthday:
        return .hidden
    case .outOfOffice where event.isRecurring:
        return .hidden
    default:
        break
    }

    // Rule 2. Recurrence is checked first, so a recurring multi-day event is a dot.
    if !event.isRecurring {
        if event.isAllDay || event.kind == .outOfOffice || event.kind == .fromGmail
            || coveredDays(event, calendar: local).count > 1
        {
            return .bar
        }
    }

    // Rule 3.
    if event.isRecurring {
        return .dot
    }

    // Rule 4 is the helper; rule 5 is the branch. Without the branch every timed one-off is
    // titled, which in a busy working calendar more than doubles the titled lines in a month.
    // RULE 5, short internal one-offs are dots:
    if !hasReasonForTitle(event, account: account, in: local) {
        return .dot
    }
    // END RULE 5.
    return .titled
}

/// Rule 4: an outside guest, a personal account, a place, or two hours or more.
private func hasReasonForTitle(_ event: Event, account: Account, in local: Calendar) -> Bool {
    let outsideGuest = event.attendeeDomains.contains { $0.lowercased() != account.domain }
    let atPlace = Formatting.place(event) != nil
    let long = event.time.interval(in: local).duration >= 2 * 60 * 60
    return outsideGuest || account.isConsumer || atPlace || long
}

/// The days an event draws on in `calendar`'s zone. All-day events cover their civil days up
/// to the exclusive end. A timed event covers its start day, and a later day only if it runs
/// past 05:00 there by the wall clock, so a flight landing at 00:15 stays on one day, also on
/// the night the clocks change.
public func coveredDays(_ event: Event, calendar: Calendar) -> ClosedRange<CivilDate> {
    switch event.time {
    case .allDay(let start, let endExclusive):
        return start...max(start, endExclusive.adding(days: -1))
    case .timed(let start, let end, _):
        let first = CivilDate(start, in: calendar)
        let endDay = CivilDate(end, in: calendar)
        guard endDay > first else { return first...first }
        let midnight = endDay.date(in: calendar)
        let cutoff =
            calendar.date(bySettingHour: 5, minute: 0, second: 0, of: midnight)
            ?? midnight.addingTimeInterval(5 * 60 * 60)
        let last = end > cutoff ? endDay : endDay.adding(days: -1)
        return first...max(first, last)
    }
}
