import Foundation

/// The Mac menu bar label, from the same `nextEvents` as the Lock Screen.
///
/// The label is as short as it can be, because macOS hides the menu bar items that do not fit
/// beside the notch and the longest label goes first. It is the next event's time only:
///
/// - Quiet (next event today more than 15 minutes away): `14:00`.
/// - Within 15 minutes of the next start, on either side of midnight: `in 12 min`.
/// - In progress: `18 min left`. Like the rectangular widget, the menu bar knows about now,
///   so the meeting you are in wins over the one starting soon.
/// - After the last event, or nothing today: the `calendar` symbol alone.
///
/// The title joins the label only when the whole title is 8 characters or fewer
/// (`14:00 Standup`, `Standup in 12 min`, `Standup, 18 min left`). A longer title is left
/// out, never cut: half a title says less than none, and the panel has the rest.
public func menuBarLabel(next: NextEvents, now: Date, calendar: Calendar) -> MenuBarLabel {
    if let current = next.current, case .timed(_, let end, _) = current.time {
        let left = "\(Formatting.countdown(end.timeIntervalSince(now))) left"
        let text = shortTitle(current).map { "\($0), \(left)" } ?? left
        return MenuBarLabel(showsSymbol: false, text: text)
    }
    guard let upcoming = next.next, case .timed(let start, _, _) = upcoming.time else {
        return .symbolOnly
    }
    let away = start.timeIntervalSince(now)
    // Close enough to count down, even across midnight.
    if away <= 15 * 60 {
        let wait = "in \(Formatting.countdown(away))"
        let text = shortTitle(upcoming).map { "\($0) \(wait)" } ?? wait
        return MenuBarLabel(showsSymbol: false, text: text)
    }
    guard CivilDate(start, in: calendar) == CivilDate(now, in: calendar) else {
        return .symbolOnly
    }
    let time = Formatting.time(start, calendar: calendar)
    return MenuBarLabel(
        showsSymbol: false, text: shortTitle(upcoming).map { "\(time) \($0)" } ?? time)
}

/// The most characters a title may have and still join the label.
private let titleLimit = 8

/// The event's title when all of it fits the label, else nil.
private func shortTitle(_ event: Event) -> String? {
    let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return !title.isEmpty && title.count <= titleLimit ? title : nil
}
