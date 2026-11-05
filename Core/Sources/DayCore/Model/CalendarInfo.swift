import Foundation

/// A calendar as one account sees it. The same Google calendar shared into two accounts has
/// two IDs; sync keeps only the one with the highest access role.
public struct CalendarID: Codable, Hashable, Comparable, Sendable {
    public var account: AccountID
    /// Google's calendar ID. Contains `#`, `@` and `+`, so it is percent-encoded in every
    /// URL path (see `DayLink` and the Calendar API client).
    public var googleID: String

    public init(account: AccountID, googleID: String) {
        self.account = account
        self.googleID = googleID
    }

    public static func < (lhs: CalendarID, rhs: CalendarID) -> Bool {
        (lhs.account, lhs.googleID) < (rhs.account, rhs.googleID)
    }

    /// Google's public holiday calendars, which draw as gray bars and secondary text.
    public var isHoliday: Bool {
        googleID.hasSuffix("#holiday@group.v.calendar.google.com")
    }
}

/// Google's `accessRole`, ordered so the highest wins when one calendar is shared into
/// several accounts.
public enum AccessRole: String, Codable, Hashable, Comparable, Sendable, CaseIterable {
    case freeBusyReader
    case reader
    case writer
    case owner

    public static func < (lhs: AccessRole, rhs: AccessRole) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// An event label defined on a calendar (`labelProperties.eventLabels`). An event carrying a
/// label takes the label's color before its own `colorId` and the calendar's color.
public struct LabelInfo: Codable, Hashable, Sendable {
    public var name: String
    public var colorHex: String

    public init(name: String, colorHex: String) {
        self.name = name
        self.colorHex = colorHex
    }
}

/// One entry of an account's calendar list.
public struct CalendarInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: CalendarID
    /// `summaryOverride`, else `summary`: named exactly as in Google.
    public var name: String
    /// The calendar's resolved `backgroundColor`, `#rrggbb`.
    public var colorHex: String
    /// Google's own `selected` flag. Day's visibility starts from it, so day one matches
    /// Google Calendar; the person's own toggles are stored by the app, not here.
    public var selected: Bool
    public var isPrimary: Bool
    public var accessRole: AccessRole
    /// IANA identifier, `Europe/Amsterdam`.
    public var timeZone: String
    /// Keyed by Google's label ID.
    public var labels: [String: LabelInfo]
    /// Minutes before the start of each popup reminder in Google's `defaultReminders`, which
    /// the events that `useDefault` follow. Email reminders are left out.
    public var defaultReminders: [Int]

    public init(
        id: CalendarID,
        name: String,
        colorHex: String,
        selected: Bool = true,
        isPrimary: Bool = false,
        accessRole: AccessRole = .reader,
        timeZone: String = "UTC",
        labels: [String: LabelInfo] = [:],
        defaultReminders: [Int] = []
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.selected = selected
        self.isPrimary = isPrimary
        self.accessRole = accessRole
        self.timeZone = timeZone
        self.labels = labels
        self.defaultReminders = defaultReminders
    }

    /// The mark beside the calendar's name. Gray when Google sent something unreadable.
    public var colorKey: ColorKey {
        ColorKey(hex: colorHex) ?? .gray
    }

    public var isHoliday: Bool {
        id.isHoliday
    }

    // Optional keys default, so the fixture stays short and a cache written before a key
    // existed still loads instead of forcing a full refetch.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(CalendarID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#616161"
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? true
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        accessRole = try c.decodeIfPresent(AccessRole.self, forKey: .accessRole) ?? .reader
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone) ?? "UTC"
        labels = try c.decodeIfPresent([String: LabelInfo].self, forKey: .labels) ?? [:]
        defaultReminders = try c.decodeIfPresent([Int].self, forKey: .defaultReminders) ?? []
    }
}
