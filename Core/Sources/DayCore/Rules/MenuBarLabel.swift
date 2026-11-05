import Foundation

/// The Mac menu bar label, from the same `nextEvents` as the Lock Screen.
///
/// - In progress: `Investor call, 18 min left`. Like the rectangular widget, the menu bar
///   knows about now, so the meeting you are in wins over the one starting soon.
/// - Within 15 minutes of the next start, on either side of midnight: `Investor call in 12 min`.
/// - Quiet (next event today more than 15 minutes away): the symbol and `14:00`.
/// - After the last event, or nothing today: the symbol alone.
///
/// Titles are cut at 16 characters so the label clears the notch, and a cut title takes an
/// ellipsis (`Quarterly planni…`) so the cut reads as one. Brief section 9 decides this.
public func menuBarLabel(next: NextEvents, now: Date, calendar: Calendar) -> MenuBarLabel {
    if let current = next.current, case .timed(_, let end, _) = current.time {
        let left = Formatting.countdown(end.timeIntervalSince(now))
        return MenuBarLabel(showsSymbol: false, text: "\(cut(current.title)), \(left) left")
    }
    guard let upcoming = next.next, case .timed(let start, _, _) = upcoming.time else {
        return .symbolOnly
    }
    let away = start.timeIntervalSince(now)
    // Close enough to name, even across midnight.
    if away <= 15 * 60 {
        return MenuBarLabel(
            showsSymbol: false, text: "\(cut(upcoming.title)) in \(Formatting.countdown(away))")
    }
    guard CivilDate(start, in: calendar) == CivilDate(now, in: calendar) else {
        return .symbolOnly
    }
    return MenuBarLabel(showsSymbol: true, text: Formatting.time(start, calendar: calendar))
}

private func cut(_ title: String) -> String {
    Formatting.truncated(title, to: 16)
}
