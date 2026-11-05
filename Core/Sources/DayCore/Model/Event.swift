import Foundation

/// An event as one calendar holds it. After merging, `Event.calendars` lists every calendar
/// a duplicate sat on, while the ID stays the kept copy's.
public struct EventID: Codable, Hashable, Comparable, Sendable {
    public var calendar: CalendarID
    /// Google's event ID. For an instance of a recurring series this is the instance ID
    /// (`<series>_<start>`), unique per occurrence.
    public var googleID: String

    public init(calendar: CalendarID, googleID: String) {
        self.calendar = calendar
        self.googleID = googleID
    }

    public var account: AccountID {
        calendar.account
    }

    public static func < (lhs: EventID, rhs: EventID) -> Bool {
        (lhs.calendar, lhs.googleID) < (rhs.calendar, rhs.googleID)
    }
}

/// When an event happens.
public enum EventTime: Codable, Hashable, Sendable {
    /// Google's `start.date` and `end.date`: civil days, end exclusive. A one-day event on
    /// 4 November is `2026-11-04` to `2026-11-05`.
    case allDay(start: CivilDate, endExclusive: CivilDate)
    /// Google's `start.dateTime` and `end.dateTime`. `authoredZone` is the zone the event was
    /// written in (`start.timeZone`, else the calendar's), which the event sheet names when
    /// its offset differs from the device's.
    case timed(start: Date, end: Date, authoredZone: String?)

    public var isAllDay: Bool {
        if case .allDay = self { return true }
        return false
    }

    /// The first instant, with all-day days starting at local midnight in `calendar`.
    public func start(in calendar: Calendar) -> Date {
        switch self {
        case .allDay(let start, _): start.date(in: calendar)
        case .timed(let start, _, _): start
        }
    }

    /// The instant it ends, exclusive.
    public func end(in calendar: Calendar) -> Date {
        switch self {
        case .allDay(_, let end): end.date(in: calendar)
        case .timed(_, let end, _): end
        }
    }

    /// Start to end in `calendar`'s zone. A zero-length event is a zero-length interval.
    public func interval(in calendar: Calendar) -> DateInterval {
        let start = start(in: calendar)
        return DateInterval(start: start, end: max(start, end(in: calendar)))
    }
}

/// Google's `eventType`. Raw values are Google's strings.
public enum EventKind: String, Codable, Hashable, Sendable, CaseIterable {
    case `default`
    case birthday
    case focusTime
    case outOfOffice
    case workingLocation
    case fromGmail
}

/// Google's event `status`.
public enum EventStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case confirmed
    case tentative
    case cancelled
}

/// The account holder's own `responseStatus` on the event. `none` means the event has no
/// guest list, so there is nothing to answer. Compare against `Response.none` explicitly
/// when the left side is optional, or Swift reads `.none` as nil.
public enum Response: String, Codable, Hashable, Sendable, CaseIterable {
    case needsAction
    case declined
    case tentative
    case accepted
    case none
}

/// One event, after decoding from Google and before or after merging across accounts.
public struct Event: Codable, Hashable, Identifiable, Sendable {
    public var id: EventID
    public var iCalUID: String
    /// `originalStartTime` of a recurring instance; nil for single events. With `iCalUID`
    /// it is the merge key, because one instance has a different ID in every account.
    public var originalStart: Date?
    /// Exactly as written in Google, emoji included. `Event.untitled` when Google sent none.
    public var title: String
    public var time: EventTime
    public var kind: EventKind
    public var status: EventStatus
    /// Google sent a `recurringEventId`: this is one occurrence of a series.
    public var isRecurring: Bool
    public var response: Response
    public var isOrganizer: Bool
    /// People on the guest list, the account holder included and rooms excluded; 0 with no
    /// guest list. The event sheet shows it as `5 guests`.
    public var attendeeCount: Int
    /// Lowercased email domains of every guest except the account holder and rooms, unique
    /// and sorted. Month rule 4 titles a one-off when one differs from the account's domain.
    public var attendeeDomains: [String]
    /// Google's guest list as it came, rooms and the account holder included, in Google's
    /// order. Empty with no guest list, and in a cache written before guests were kept, which
    /// the next full read replaces (`CacheFormat`). The event sheet draws it through `guests`.
    public var attendees: [Attendee]
    /// Google's `transparency` is `transparent`: shown as free, never a widget candidate.
    public var isFree: Bool
    /// Google's `location` as written; may be a place, an address or a URL.
    public var location: String?
    /// The meeting link, already chosen in source order (conference video entry point,
    /// `hangoutLink`, a URL in the location, a known meeting URL in the description).
    public var joinURL: URL?
    /// Google Calendar's own page for the event, the target of `Open in Google Calendar`.
    public var htmlLink: URL?
    /// Plain text, tags already stripped.
    public var description: String?
    /// Resolved color: the label's, then the event's `colorId`, then the calendar's.
    public var colorKey: ColorKey
    /// Every calendar this event sits on after merging, the kept copy's first.
    public var calendars: [CalendarID]

    public init(
        id: EventID,
        iCalUID: String,
        originalStart: Date? = nil,
        title: String,
        time: EventTime,
        kind: EventKind = .default,
        status: EventStatus = .confirmed,
        isRecurring: Bool = false,
        response: Response = .none,
        isOrganizer: Bool = false,
        attendeeCount: Int = 0,
        attendeeDomains: [String] = [],
        attendees: [Attendee] = [],
        isFree: Bool = false,
        location: String? = nil,
        joinURL: URL? = nil,
        htmlLink: URL? = nil,
        description: String? = nil,
        colorKey: ColorKey = .gray,
        calendars: [CalendarID]? = nil
    ) {
        self.id = id
        self.iCalUID = iCalUID
        self.originalStart = originalStart
        self.title = title
        self.time = time
        self.kind = kind
        self.status = status
        self.isRecurring = isRecurring
        self.response = response
        self.isOrganizer = isOrganizer
        self.attendeeCount = attendeeCount
        self.attendeeDomains = attendeeDomains
        self.attendees = attendees
        self.isFree = isFree
        self.location = location
        self.joinURL = joinURL
        self.htmlLink = htmlLink
        self.description = description
        self.colorKey = colorKey
        self.calendars = calendars ?? [id.calendar]
    }

    /// What an event with no title is called on every surface: the row, the month, the
    /// sheet, the widgets and the menu bar. Google sends no title for an untitled event or
    /// for any event on a calendar shared as free/busy only, and an empty one would draw an
    /// empty line.
    public static let untitled = "Busy"

    /// The placeholder Day wrote for an untitled event before `untitled` was one word.
    private static let formerPlaceholder = "(No title)"

    public var account: AccountID {
        id.account
    }

    public var isAllDay: Bool {
        time.isAllDay
    }

    /// Someone besides the account holder is invited. Decides `No reply yet` on a row.
    public var hasOtherAttendees: Bool {
        attendeeCount > 1
    }

    /// The event sheet's guest list; nil when fewer than two people are listed.
    public var guests: GuestList? {
        GuestList(attendees)
    }

    // Optional keys default, so the fixture stays short and a cache written before a key
    // existed still loads instead of forcing a full refetch.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EventID.self, forKey: .id)
        iCalUID = try c.decodeIfPresent(String.self, forKey: .iCalUID) ?? id.googleID
        originalStart = try c.decodeIfPresent(Date.self, forKey: .originalStart)
        // A cache written before `untitled` holds the old placeholder; reading it as
        // `untitled` fixes those events at once instead of waiting for a full read of each
        // calendar, and keeps the cache the person is using.
        let stored = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        title = stored.allSatisfy(\.isWhitespace) || stored == Event.formerPlaceholder
            ? Event.untitled : stored
        time = try c.decode(EventTime.self, forKey: .time)
        kind = try c.decodeIfPresent(EventKind.self, forKey: .kind) ?? .default
        status = try c.decodeIfPresent(EventStatus.self, forKey: .status) ?? .confirmed
        isRecurring = try c.decodeIfPresent(Bool.self, forKey: .isRecurring) ?? false
        response = try c.decodeIfPresent(Response.self, forKey: .response) ?? .none
        isOrganizer = try c.decodeIfPresent(Bool.self, forKey: .isOrganizer) ?? false
        attendeeCount = try c.decodeIfPresent(Int.self, forKey: .attendeeCount) ?? 0
        attendeeDomains = try c.decodeIfPresent([String].self, forKey: .attendeeDomains) ?? []
        attendees = try c.decodeIfPresent([Attendee].self, forKey: .attendees) ?? []
        isFree = try c.decodeIfPresent(Bool.self, forKey: .isFree) ?? false
        location = try c.decodeIfPresent(String.self, forKey: .location)
        joinURL = try c.decodeIfPresent(URL.self, forKey: .joinURL)
        htmlLink = try c.decodeIfPresent(URL.self, forKey: .htmlLink)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        colorKey = try c.decodeIfPresent(ColorKey.self, forKey: .colorKey) ?? .gray
        calendars = try c.decodeIfPresent([CalendarID].self, forKey: .calendars) ?? [id.calendar]
    }
}
