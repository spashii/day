import Foundation

// What the rules in Rules/ return. They live in Model so every surface builds against one
// fixed shape while the rule bodies change underneath.

/// How an event draws in the month grid.
public enum MonthMark: String, Codable, Hashable, Sendable, CaseIterable {
    /// Not drawn: cancelled, declined, working location, focus time, birthday, recurring
    /// out of office.
    case hidden
    /// A bar across its days with the title once per week row.
    case bar
    /// A gray dot at the bottom of the cell.
    case dot
    /// A 2 pt rule in the event color, then the title.
    case titled
}

/// The one answer to "what is next" that the Lock Screen, the menu bar and the Day's Join
/// window all share, so no surface disagrees.
public struct NextEvents: Hashable, Sendable {
    /// Started at or before now and not ended; the one that started last if several.
    public var current: Event?
    /// The first candidate that starts after now, within seven days.
    public var next: Event?

    public init(current: Event? = nil, next: Event? = nil) {
        self.current = current
        self.next = next
    }
}

/// One line of the Day list, top to bottom.
public enum DayRow: Hashable, Sendable, Identifiable {
    /// An all-day item. `position` is `day 2 of 3` for an item spanning several days; the
    /// view writes `Lisbon, day 2 of 3`.
    case allDay(Event, position: String?)
    /// After three all-day items: `2 more`.
    case allDayMore(String)
    /// Today only: everything that has ended, folded into one line until tapped. The text
    /// is `Formatting.earlier(_:)`.
    case earlier([Event])
    /// The red now line, before the day starts or in a gap between events.
    case nowLine(Date)
    /// An event row. `secondLine` is the one unusual thing about it (`in 20 min`,
    /// `ends in 25 min`, `No reply yet`, a place); `showsJoin` puts Join on the trailing edge.
    case event(Event, secondLine: String?, showsJoin: Bool)
    /// A gap of an hour or more: `1 h free`, or `Free until 16:00` when it holds now.
    /// `start` is when the gap begins, which keeps two gaps with the same text apart.
    case gap(String, start: Date)

    public enum ID: Hashable, Sendable {
        case allDay(EventID)
        case allDayMore
        case earlier
        case nowLine
        case event(EventID)
        case gap(Date)
    }

    public var id: ID {
        switch self {
        case .allDay(let event, _): .allDay(event.id)
        case .allDayMore: .allDayMore
        case .earlier: .earlier
        case .nowLine: .nowLine
        case .event(let event, _, _): .event(event.id)
        case .gap(_, let start): .gap(start)
        }
    }
}

/// One Lock Screen timeline entry, carrying all three families so one provider serves them.
/// The widget conforms it to `TimelineEntry`.
public struct WidgetEntry: Hashable, Sendable {
    public var date: Date
    /// Above the clock: `14:00 Investor call`, `Thu 9:30 Standup`,
    /// `Nothing in the next 7 days`, `Add a Google account`, `Open to update`.
    public var inline: String
    public var rectangular: RectangularLines
    public var circular: CircularContent
    /// Inline and circular tap target: `day://day/<yyyy-mm-dd>` for today.
    public var url: URL?

    public init(
        date: Date,
        inline: String,
        rectangular: RectangularLines,
        circular: CircularContent,
        url: URL?
    ) {
        self.date = date
        self.inline = inline
        self.rectangular = rectangular
        self.circular = circular
        self.url = url
    }
}

/// The rectangular family's three separate lines. Never joined into one `Text`: a single
/// `Text` in this family is cut to two lines.
public struct RectangularLines: Hashable, Sendable {
    /// Line 1: the event title, or a state (`Add a Google account`,
    /// `Nothing in the next 7 days`).
    public var title: String
    /// Line 2; nil leaves it empty.
    public var when: WhenLine?
    /// Line 3, secondary: `16:00 Weekly planning`, `Also 14:30 Acme sync`,
    /// `Last one today`, `As of 9:12` (`As of Tue 9:12` once the day has changed since the
    /// data was fetched), `1 account signed out`. Dropped under Always-On.
    public var after: String?
    /// Tap target: `day://event/<account>/<calendar>/<id>` for the event shown.
    public var url: URL?

    public init(title: String, when: WhenLine? = nil, after: String? = nil, url: URL? = nil) {
        self.title = title
        self.when = when
        self.after = after
        self.url = url
    }
}

/// Rectangular line 2, in a form that keeps itself current without a reload.
public struct WhenLine: Hashable, Sendable {
    /// The clock part: `14:00`, `until 15:00`, `14:00 to 15:00`, `Tomorrow 9:30`, `Thu 9:30`.
    public var text: String
    /// Set within 60 minutes of the start. The view appends ` · ` and
    /// `Text(.currentDate, format: .reference(to: relativeTo))`, which ticks by itself.
    public var relativeTo: Date?
    /// Under Always-On (`isLuminanceReduced`): clock times only, `14:00 to 15:00` or
    /// `until 15:00`, so no countdown freezes into a lie.
    public var reduced: String

    public init(text: String, relativeTo: Date? = nil, reduced: String? = nil) {
        self.text = text
        self.relativeTo = relativeTo
        self.reduced = reduced ?? text
    }
}

/// The circular family: a start time, or the calendar symbol.
public enum CircularContent: Hashable, Sendable {
    /// `9:30`, with `THU` above it when the event is not today and `PM` below it in
    /// 12-hour locales.
    case time(String, weekday: String?, period: String?)
    /// Nothing in seven days, no account, or data over 24 hours old: the `calendar` symbol
    /// in secondary gray, so the slot does not look broken.
    case symbol
}

/// The Mac menu bar item's label.
public struct MenuBarLabel: Hashable, Sendable {
    /// Draw the `calendar` symbol before the text. Only the symbol-alone state does: a label
    /// with an event is text, to leave room beside the notch.
    public var showsSymbol: Bool
    /// `14:00`, `in 12 min`, `18 min left`, each with the event's title when the title is 8
    /// characters or fewer (`14:00 Standup`); nil for the symbol alone.
    public var text: String?

    public init(showsSymbol: Bool, text: String?) {
        self.showsSymbol = showsSymbol
        self.text = text
    }

    /// After the last event, or nothing today.
    public static let symbolOnly = MenuBarLabel(showsSymbol: true, text: nil)
}
