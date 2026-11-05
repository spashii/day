import Foundation

/// Lock Screen entries from `now`, each computed as of its own date so the content is exactly
/// what `now == entry.date` would show.
///
/// Entries fall at every candidate start and end in the next 24 hours, an hour before every
/// start (when the rectangular family's line 2 starts counting down), at local midnight, and
/// when the snapshot turns 2 and 24 hours old. Changes less than 5 minutes apart share one
/// entry at the later of them, so the widget is never ahead of the data and never more than
/// 5 minutes behind it. `fetchedAt` drives `As of 9:12` and, past 24 hours, `Open to update`
/// on all three families; `signedOutAccounts` drives `1 account signed out`. Pass the
/// snapshot's merged events.
public func widgetTimeline(
    events: [Event], now: Date, fetchedAt: Date, signedOutAccounts: Int, calendar: Calendar
) -> [WidgetEntry] {
    let horizon = now.addingTimeInterval(24 * 60 * 60)
    var changes: [Date] = []
    func add(_ date: Date) {
        if date > now, date <= horizon { changes.append(date) }
    }

    for candidate in candidates(events: events, now: now, calendar: calendar) {
        add(candidate.start)
        add(candidate.end)
        add(candidate.start.addingTimeInterval(-WidgetRule.countdownWindow))
    }
    let today = CivilDate(now, in: calendar)
    for days in 1...2 {
        add(today.adding(days: days).date(in: calendar))
    }
    add(fetchedAt.addingTimeInterval(WidgetRule.staleAfter + 1))
    add(fetchedAt.addingTimeInterval(WidgetRule.expiredAfter + 1))

    var dates: [Date] = [now]
    var anchor: Date?
    for change in changes.sorted() {
        if let held = anchor, change.timeIntervalSince(held) < WidgetRule.mergeWindow {
            dates[dates.count - 1] = change
        } else {
            dates.append(change)
            anchor = change
        }
    }
    return dates.map {
        widgetEntry(
            at: $0, events: events, fetchedAt: fetchedAt, signedOutAccounts: signedOutAccounts,
            calendar: calendar)
    }
}

/// The entry while no account is added: `Add a Google account`, and the calendar symbol.
public func noAccountWidgetEntry(now: Date, calendar: Calendar) -> WidgetEntry {
    WidgetEntry(
        date: now,
        inline: "Add a Google account",
        rectangular: RectangularLines(title: "Add a Google account"),
        circular: .symbol,
        url: DayLink.day(CivilDate(now, in: calendar)).url)
}

private enum WidgetRule {
    /// Line 2 counts down inside this window.
    static let countdownWindow: TimeInterval = 60 * 60
    /// `As of 9:12` appears on line 3 past this age.
    static let staleAfter: TimeInterval = 2 * 60 * 60
    /// Past this age no family draws an event: inline and rectangular read `Open to update`
    /// and circular shows the symbol. Rectangular is the one that claims to know about now,
    /// so it must not keep drawing yesterday's data as today's.
    static let expiredAfter: TimeInterval = 24 * 60 * 60
    static let mergeWindow: TimeInterval = 5 * 60
    static let nothingAhead = "Nothing in the next 7 days"
    static let openToUpdate = "Open to update"
}

/// The entry as of `t`.
private func widgetEntry(
    at t: Date, events: [Event], fetchedAt: Date, signedOutAccounts: Int, calendar: Calendar
) -> WidgetEntry {
    let age = t.timeIntervalSince(fetchedAt)
    let today = CivilDate(t, in: calendar)

    // Too old to name anything. Lines 2 and 3 stay empty and the rectangular tap target is
    // left unset (the widget reads a set one as "an event is on screen" and redacts
    // privately), so every family opens today.
    if age > WidgetRule.expiredAfter {
        return WidgetEntry(
            date: t,
            inline: WidgetRule.openToUpdate,
            rectangular: RectangularLines(title: WidgetRule.openToUpdate),
            circular: .symbol,
            url: DayLink.day(today).url)
    }

    let list = candidates(events: events, now: t, calendar: calendar)
    let current = currentCandidate(in: list, now: t)
    let ahead = list.filter { $0.start > t }
    let next = ahead.first

    // Inline and circular always show `next`: during a meeting you know which one.
    let inline: String
    let circular: CircularContent
    if let next {
        let onToday = CivilDate(next.start, in: calendar) == today
        let when = onToday
            ? Formatting.time(next.start, calendar: calendar)
            : Formatting.weekdayTime(next.start, calendar: calendar)
        inline = "\(when) \(next.event.title)"
        let clock = Formatting.clock(next.start, calendar: calendar)
        circular = .time(
            clock.digits,
            weekday: onToday ? nil : Formatting.shortWeekdayCapitalized(next.start, calendar: calendar),
            period: clock.period)
    } else {
        inline = WidgetRule.nothingAhead
        circular = .symbol
    }

    // Rectangular is the only family that knows about now.
    let signedOut = signedOutAccounts > 0 ? Formatting.signedOut(accounts: signedOutAccounts) : nil
    let stale = age > WidgetRule.staleAfter
        ? "As of \(Formatting.time(fetchedAt, calendar: calendar))" : nil
    let rectangular: RectangularLines
    if let shown = current ?? next {
        let following = current != nil ? ahead.first : ahead.dropFirst().first
        let after = stale ?? signedOut ?? followingLine(
            shown: shown, following: following, shownIsCurrent: current != nil, now: t,
            calendar: calendar)
        rectangular = RectangularLines(
            title: shown.event.title,
            when: whenLine(shown, now: t, shownIsCurrent: current != nil, calendar: calendar),
            after: after,
            url: DayLink.event(shown.event.id).url)
    } else {
        rectangular = RectangularLines(title: WidgetRule.nothingAhead, when: nil, after: stale ?? signedOut)
    }

    return WidgetEntry(
        date: t,
        inline: inline,
        rectangular: rectangular,
        circular: circular,
        url: DayLink.day(today).url)
}

/// Line 2, first match: `until 15:00`; `14:00 · in 12 min` within the hour (the relative part
/// is the view's, from `relativeTo`); `14:00 to 15:00` later today; `Tomorrow 9:30`;
/// `Thu 9:30`. The reduced form is clock times only, for Always-On.
private func whenLine(
    _ shown: Candidate, now: Date, shownIsCurrent: Bool, calendar: Calendar
) -> WhenLine {
    let end = Formatting.time(shown.end, calendar: calendar)
    if shownIsCurrent {
        return WhenLine(text: "until \(end)")
    }
    let start = Formatting.time(shown.start, calendar: calendar)
    let range = "\(start) to \(end)"
    if shown.start.timeIntervalSince(now) <= WidgetRule.countdownWindow {
        return WhenLine(text: start, relativeTo: shown.start, reduced: range)
    }
    if CivilDate(shown.start, in: calendar) == CivilDate(now, in: calendar) {
        return WhenLine(text: range)
    }
    return WhenLine(text: Formatting.dayTime(shown.start, relativeTo: now, calendar: calendar))
}

/// Line 3 once age and sign-in have nothing to say: `Also 14:30 Acme sync` when the next
/// event overlaps the one shown, `16:00 Weekly planning` when another follows on that day,
/// `Last one today` when nothing does. An event on a later day with nothing after it that
/// day has no line, because `Last one today` would be untrue.
///
/// The follower carries no connective: on a 160 pt line `Then 11:00 Design review` is cut
/// to `Then 11:00 Desi`, and `Then` is the one word that says nothing. `Also` stays, because
/// it is what says overlap.
private func followingLine(
    shown: Candidate, following: Candidate?, shownIsCurrent: Bool, now: Date, calendar: Calendar
) -> String? {
    let today = CivilDate(now, in: calendar)
    let shownDay = shownIsCurrent ? today : CivilDate(shown.start, in: calendar)
    if let following {
        let at = Formatting.time(following.start, calendar: calendar)
        if following.start < shown.end {
            return "Also \(at) \(following.event.title)"
        }
        if CivilDate(following.start, in: calendar) == shownDay {
            return "\(at) \(following.event.title)"
        }
    }
    return shownDay == today ? "Last one today" : nil
}

extension RectangularLines {
    /// Whether line 3 carries an event's words (`Also 14:30 Acme sync`, `16:00 Weekly
    /// planning`) as opposed to a state (`As of 9:12`, `1 account signed out`, `Last one
    /// today`). The view marks only the former privacy sensitive. It lives beside the
    /// strings it reads, so the wording and the test for it cannot drift apart.
    public var afterNamesEvent: Bool {
        guard let after else { return false }
        return after.hasPrefix("Also ")
            || after.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) != nil
    }
}
