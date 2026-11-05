import Foundation

// Google's JSON as the Calendar API v3 sends it, limited to the fields Day asks for. Every
// field but an ID is optional, because Google leaves out whatever is unset or default.
// `GoogleDecoding` turns these into the model; nothing outside Google/ and Sync/ sees them.

/// A list response page. Items decode one by one, so a single odd entry is skipped instead
/// of failing the whole calendar.
struct GooglePage<Item: Decodable & Sendable>: Decodable, Sendable {
    var items: [Item]
    var nextPageToken: String?
    /// Only on the last page: where the next incremental sync of this collection starts.
    var nextSyncToken: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken
        case nextSyncToken
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
        nextSyncToken = try c.decodeIfPresent(String.self, forKey: .nextSyncToken)
        let lenient = try c.decodeIfPresent([Lenient<Item>].self, forKey: .items) ?? []
        items = lenient.compactMap(\.value)
    }
}

/// Decodes a value or nothing, without throwing, so the surrounding array keeps going.
struct Lenient<Value: Decodable & Sendable>: Decodable, Sendable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// An entry of `calendarList.list`.
public struct GoogleCalendarListEntry: Decodable, Hashable, Sendable {
    public var id: String
    public var summary: String?
    public var summaryOverride: String?
    /// Hex, and it supersedes `colorId`.
    public var backgroundColor: String?
    /// Absent means false.
    public var selected: Bool?
    public var primary: Bool?
    /// `freeBusyReader`, `reader`, `writer`, `writerWithoutPrivateAccess` or `owner`.
    public var accessRole: String?
    public var timeZone: String?
    public var deleted: Bool?
    public var hidden: Bool?
}

/// `calendars.get`: the calendar itself, which is where event labels are defined.
public struct GoogleCalendarResource: Decodable, Hashable, Sendable {
    public struct LabelProperties: Decodable, Hashable, Sendable {
        public var eventLabels: [GoogleEventLabel]?
    }

    public var id: String
    public var summary: String?
    public var timeZone: String?
    public var labelProperties: LabelProperties?
}

/// One label in `labelProperties.eventLabels`.
public struct GoogleEventLabel: Decodable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var backgroundColor: String?
    /// Read when a label has no hex of its own, through the modern palette.
    public var colorId: String?
}

/// An event from `events.list` with `singleEvents=true`. In an incremental answer a
/// `cancelled` item may carry nothing but its `id` (a deleted event) or its `id`,
/// `recurringEventId` and `originalStartTime` (a cancelled instance of a series).
public struct GoogleEvent: Decodable, Hashable, Sendable {
    /// `start`, `end` and `originalStartTime`: `date` for all-day, `dateTime` otherwise.
    public struct Time: Decodable, Hashable, Sendable {
        /// `2026-11-04`, a civil date with no zone.
        public var date: String?
        /// RFC 3339 with an offset, `2026-11-04T14:00:00+01:00`.
        public var dateTime: String?
        /// IANA zone the event was written in, when Google sends one.
        public var timeZone: String?

        public init(date: String? = nil, dateTime: String? = nil, timeZone: String? = nil) {
            self.date = date
            self.dateTime = dateTime
            self.timeZone = timeZone
        }
    }

    /// An attendee or the organizer.
    public struct Person: Decodable, Hashable, Sendable {
        public var email: String?
        /// This entry is the calendar the copy sits on, which for his own calendars is him.
        public var isSelf: Bool?
        /// A room or other resource, not a person.
        public var resource: Bool?
        /// `needsAction`, `declined`, `tentative` or `accepted`.
        public var responseStatus: String?

        enum CodingKeys: String, CodingKey {
            case email
            case isSelf = "self"
            case resource
            case responseStatus
        }
    }

    public struct ConferenceData: Decodable, Hashable, Sendable {
        public var entryPoints: [EntryPoint]?
    }

    public struct EntryPoint: Decodable, Hashable, Sendable {
        /// `video` (at most one), `phone`, `sip` or `more`.
        public var entryPointType: String?
        public var uri: String?
    }

    public var id: String
    public var iCalUID: String?
    public var status: String?
    public var summary: String?
    /// HTML as the web app writes it, or plain text from other clients.
    public var description: String?
    public var location: String?
    public var htmlLink: String?
    public var colorId: String?
    public var eventLabelId: String?
    public var start: Time?
    public var end: Time?
    public var originalStartTime: Time?
    public var recurringEventId: String?
    /// `transparent` means the event shows as free.
    public var transparency: String?
    public var eventType: String?
    public var organizer: Person?
    public var attendees: [Person]?
    public var hangoutLink: String?
    public var conferenceData: ConferenceData?
}
