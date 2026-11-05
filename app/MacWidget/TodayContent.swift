import DayCore
import Foundation

/// What one desktop widget entry shows, in all three families, as of the entry's date.
///
/// Every row comes from the Day list's own rule, `dayRows`, and the small family's event from
/// `nextEvents`, so the widget, the Day pane and the menu bar never disagree. Two things the
/// list draws are left out, because they change every minute and a widget only redraws at its
/// entries: the now line's time, and the countdown second lines (`in 20 min`,
/// `ends in 25 min`). A row keeps the second line that holds all day: `No reply yet`, or the
/// place.
enum TodayContent: Hashable, Sendable {
    /// A line where the events would be, and the day a click opens.
    case message(String, url: URL)
    case day(TodayDay)

    var url: URL {
        switch self {
        case .message(_, let url): url
        case .day(let day): day.url
        }
    }
}

/// One day as the three families draw it.
struct TodayDay: Hashable, Sendable {
    var day: CivilDate
    var calendar: Calendar
    /// Small: the next event, which rolls to tomorrow's first after the last one today, as on
    /// the Lock Screen. Nil when nothing starts in the next 7 days.
    var next: TodayNext?
    /// All-day lines in the Day list's form, then `2 more` after three.
    var allDay: [TodayRow]
    /// Today's events that have ended, in order: drawn dimmed, or folded into the Earlier row.
    var ended: [Event]
    /// The event under way and the ones to come today, with the gap rows between them.
    var ahead: [TodayRow]
    /// `As of 9:12` when the data is over 2 hours old, else `1 account signed out`; the
    /// Lock Screen's line 3 states. Medium and large only.
    var status: String?
    /// `day://day/<today>`.
    var url: URL
    /// What the day says when no event is left to come: `Nothing scheduled` for a day with
    /// nothing at all, `Nothing else today` once the last event has ended (an all-day line
    /// is an event). Nil while something is still to come.
    var ending: DayEnding?
    /// The symbols the person gave their calendars, which lead the rows. Empty for none.
    var symbols: CalendarSymbolMap = CalendarSymbolMap()

    /// The line the small family and an empty medium family write: the day's ending, and
    /// `Nothing scheduled` where the day has none to name.
    var emptyMessage: String {
        ending == .nothingElse ? TodayContent.nothingElse : TodayContent.nothingScheduled
    }
}

/// The small family's event.
struct TodayNext: Hashable, Sendable {
    var event: Event
    /// Today, the start and end (`14:00`, `15:00`); on a later day, `Tomorrow 9:30` or
    /// `Thu 9:30` with no end.
    var start: String
    var end: String?
    var secondLine: String?
    /// The day the event starts, which a click opens.
    var url: URL
}

/// One line of a family's list.
enum TodayRow: Hashable, Sendable, Identifiable {
    case allDay(Event, position: String?)
    case allDayMore(String)
    /// `Earlier: Standup, Design review`.
    case earlier([Event])
    /// An event that has ended, dimmed.
    case past(Event)
    case event(Event, secondLine: String?)
    /// `Nothing else today`, under the rows of a day whose last event has ended.
    case nothingElse(String)
    /// `1 h free`, `Free until 16:00`.
    case gap(String, start: Date)
    /// `2 more`: events cut off at the bottom for lack of room.
    case more(String)

    enum ID: Hashable {
        case allDay(EventID)
        case allDayMore
        case earlier
        case event(EventID)
        case nothingElse
        case gap(Date)
        case more
    }

    var id: ID {
        switch self {
        case .allDay(let event, _): .allDay(event.id)
        case .allDayMore: .allDayMore
        case .earlier: .earlier
        case .past(let event), .event(let event, _): .event(event.id)
        case .nothingElse: .nothingElse
        case .gap(_, let start): .gap(start)
        case .more: .more
        }
    }

    var isEvent: Bool {
        if case .event = self { return true }
        return false
    }
}

extension TodayContent {
    /// The words of the Lock Screen widget's states, which the desktop widget shares.
    static let addAccount = "Add a Google account"
    static let openToUpdate = "Open to update"
    /// The copy decision for the desktop widget's empty state.
    static let nothingScheduled = "Nothing scheduled"
    /// The copy decision for a day whose last event has ended; the Day list writes it with a
    /// period.
    static let nothingElse = "Nothing else today"

    /// Past this age no family names an event, as on the Lock Screen, and a click opens the
    /// app, which refreshes and writes a new snapshot. The Lock Screen's thresholds live in
    /// `WidgetRule` in Core's `WidgetTimeline.swift`; these follow them.
    static let expiredAfter: TimeInterval = 24 * 60 * 60
    /// Past this age medium and large add `As of 9:12`.
    static let staleAfter: TimeInterval = 2 * 60 * 60

    /// The content at `t` for a snapshot's events, fetched at `fetchedAt`.
    static func at(
        _ t: Date, events: [Event], fetchedAt: Date, signedOutAccounts: Int, calendar: Calendar,
        symbols: CalendarSymbolMap = CalendarSymbolMap()
    ) -> TodayContent {
        let today = CivilDate(t, in: calendar)
        let url = DayLink.day(today).url
        let age = t.timeIntervalSince(fetchedAt)
        if age > expiredAfter {
            return .message(openToUpdate, url: url)
        }

        let lines = steadySecondLines(on: today, events: events, calendar: calendar)
        var allDay: [TodayRow] = []
        var ended: [Event] = []
        var ahead: [TodayRow] = []
        let rows = dayRows(day: today, events: events, now: t, calendar: calendar)
        for row in rows {
            switch row {
            case .allDay(let event, let position):
                allDay.append(.allDay(event, position: position))
            case .allDayMore(let text):
                allDay.append(.allDayMore(text))
            case .earlier(let events):
                ended = events
            case .nowLine:
                break
            case .event(let event, _, _):
                ahead.append(.event(event, secondLine: lines[event.id]))
            case .gap(let text, let start):
                ahead.append(.gap(text, start: start))
            }
        }

        // The Lock Screen's line 3 states, in its words: a bare time once the day has
        // changed would read as today's, so it then carries the weekday.
        let status: String?
        if age > staleAfter {
            let when = CivilDate(fetchedAt, in: calendar) == today
                ? Formatting.time(fetchedAt, calendar: calendar)
                : Formatting.weekdayTime(fetchedAt, calendar: calendar)
            status = "As of \(when)"
        } else if signedOutAccounts > 0 {
            status = Formatting.signedOut(accounts: signedOutAccounts)
        } else {
            status = nil
        }

        return .day(
            TodayDay(
                day: today, calendar: calendar,
                next: next(at: t, events: events, calendar: calendar),
                allDay: allDay, ended: ended, ahead: ahead, status: status, url: url,
                ending: dayEnding(rows: rows, day: today, now: t, calendar: calendar),
                symbols: symbols))
    }

    /// The first event that starts after `t` in the next 7 days, the `nextEvents` rule.
    private static func next(at t: Date, events: [Event], calendar: Calendar) -> TodayNext? {
        guard let event = nextEvents(events: events, now: t, calendar: calendar).next else {
            return nil
        }
        let start = event.time.start(in: calendar)
        let day = CivilDate(start, in: calendar)
        let isToday = day == CivilDate(t, in: calendar)
        return TodayNext(
            event: event,
            start: isToday
                ? Formatting.time(start, calendar: calendar)
                : Formatting.dayTime(start, relativeTo: t, calendar: calendar),
            end: isToday ? Formatting.time(event.time.end(in: calendar), calendar: calendar) : nil,
            secondLine: steadySecondLines(on: day, events: events, calendar: calendar)[event.id],
            url: DayLink.day(day).url)
    }

    /// Each row's second line without the countdowns: the Day list's own rule read from a
    /// moment long before the day, where nothing is under way or within the hour, so what is
    /// left is `No reply yet` or the place.
    private static func steadySecondLines(
        on day: CivilDate, events: [Event], calendar: Calendar
    ) -> [EventID: String] {
        var lines: [EventID: String] = [:]
        for case .event(let event, let line?, _) in dayRows(
            day: day, events: events, now: .distantPast, calendar: calendar)
        {
            lines[event.id] = line
        }
        return lines
    }
}

extension TodayDay {
    /// The large family's candidates, most complete first; the view draws the first that
    /// fits. Ended events dimmed in place, then folded into the Earlier row as the Day view
    /// folds them, then without the gap rows, then with events cut from the end behind
    /// `2 more`.
    var largeLayouts: [[TodayRow]] {
        let earlier: [TodayRow] = ended.isEmpty ? [] : [.earlier(ended)]
        let events = ahead.filter(\.isEvent)
        var layouts: [[TodayRow]] = []
        if !ended.isEmpty {
            layouts.append(allDay + ended.map(TodayRow.past) + ahead + closing)
        }
        layouts.append(allDay + earlier + ahead + closing)
        layouts.append(allDay + earlier + events + closing)
        layouts += Self.cut(events).map { allDay + earlier + $0 }
        return Self.distinct(layouts)
    }

    /// The medium family's candidates: today's events still to come, with the all-day lines
    /// while there is room for them, then with events cut from the end behind `2 more`.
    var mediumLayouts: [[TodayRow]] {
        let events = ahead.filter(\.isEvent)
        var layouts: [[TodayRow]] = [allDay + events + closing, events + closing]
        layouts += Self.cut(events)
        return Self.distinct(layouts.filter { !$0.isEmpty })
    }

    /// The last line of a day with nothing left to come, which stays when the all-day lines
    /// are the only thing above it.
    private var closing: [TodayRow] {
        ending == .nothingElse ? [.nothingElse(TodayContent.nothingElse)] : []
    }

    /// `events` with one, two and so on cut from the end, each followed by its `2 more`;
    /// never fewer than one event.
    private static func cut(_ events: [TodayRow]) -> [[TodayRow]] {
        guard events.count > 1 else { return [] }
        return (1..<events.count).map { hidden in
            Array(events.dropLast(hidden)) + [.more(Formatting.more(hidden))]
        }
    }

    private static func distinct(_ layouts: [[TodayRow]]) -> [[TodayRow]] {
        var seen: Set<[TodayRow]> = []
        return layouts.filter { seen.insert($0).inserted }
    }
}
