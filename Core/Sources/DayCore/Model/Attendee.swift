import Foundation

/// One entry of an event's guest list, as Google sends it: the account holder, rooms and the
/// organizer included. Rooms are kept so the cache says what Google said; `GuestList` leaves
/// them out of everything the event sheet draws.
public struct Attendee: Codable, Hashable, Sendable {
    public var email: String
    /// Google's `displayName`; nil when the guest has none, which is then shown by `email`.
    public var displayName: String?
    public var isOrganizer: Bool
    /// This entry is the calendar the copy sits on, which for his own calendars is him.
    public var isSelf: Bool
    /// A room or other resource, by Google's flag or by its calendar address.
    public var isResource: Bool
    public var isOptional: Bool
    /// Google's `responseStatus`; a guest it sends none for is awaiting, as Google counts it.
    public var response: Response

    public init(
        email: String,
        displayName: String? = nil,
        isOrganizer: Bool = false,
        isSelf: Bool = false,
        isResource: Bool = false,
        isOptional: Bool = false,
        response: Response = .needsAction
    ) {
        self.email = email
        self.displayName = displayName
        self.isOrganizer = isOrganizer
        self.isSelf = isSelf
        self.isResource = isResource
        self.isOptional = isOptional
        self.response = response
    }

    // Only what differs from the default is written, because the cache holds a guest list
    // for every event in five months and most guests have none of the flags.
    enum CodingKeys: String, CodingKey {
        case email, displayName, isOrganizer, isSelf, isResource, isOptional, response
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        isOrganizer = try c.decodeIfPresent(Bool.self, forKey: .isOrganizer) ?? false
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        isResource = try c.decodeIfPresent(Bool.self, forKey: .isResource) ?? false
        isOptional = try c.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
        response = try c.decodeIfPresent(Response.self, forKey: .response) ?? .needsAction
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(email, forKey: .email)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        if isOrganizer { try c.encode(true, forKey: .isOrganizer) }
        if isSelf { try c.encode(true, forKey: .isSelf) }
        if isResource { try c.encode(true, forKey: .isResource) }
        if isOptional { try c.encode(true, forKey: .isOptional) }
        if response != .needsAction { try c.encode(response, forKey: .response) }
    }
}

/// A guest's answer in Google's own words for the guest list.
public enum GuestAnswer: String, Hashable, Sendable, CaseIterable {
    case yes
    case no
    case maybe
    case awaiting

    /// `allCases` order is the order the summary line counts them in.
    public init(_ response: Response) {
        switch response {
        case .accepted: self = .yes
        case .declined: self = .no
        case .tentative: self = .maybe
        case .needsAction, .none: self = .awaiting
        }
    }

    /// What the summary line and VoiceOver say.
    public var word: String {
        rawValue
    }
}

/// The guest list of the event sheet: who is shown, in what order, and the line above them.
/// Built from the event's `attendees`, so it shows exactly what Google returned. When Google
/// hides the list (`guestsCanSeeOtherGuests` is false) that is only the account holder, and
/// there is then no list to draw.
public struct GuestList: Hashable, Sendable {
    public struct Row: Hashable, Identifiable, Sendable {
        /// Position in the list, because an address is not unique across a hand-edited event.
        public var id: Int
        /// `You`, else the name Google has, else the address.
        public var name: String
        public var email: String
        public var answer: GuestAnswer
        public var isOrganizer: Bool
        public var isOptional: Bool

        /// The words printed after the name, in the order VoiceOver reads them.
        public var marks: [String] {
            (isOrganizer ? [GuestList.organizerMark] : []) + (isOptional ? [GuestList.optionalMark] : [])
        }

        /// `Ines Vos, yes, Organizer`: name, answer, then Organizer or Optional where they apply.
        public var spoken: String {
            ([name, answer.word] + marks).joined(separator: ", ")
        }
    }

    public static let organizerMark = "Organizer"
    public static let optionalMark = "Optional"
    public static let youName = "You"
    /// Guests drawn before `Show All`.
    public static let collapsedLimit = 8

    /// The organizer first, then the account holder, then everyone else in Google's order.
    /// The account holder comes second so his own answer, which the sheet used to print
    /// after the count, is never hidden behind `Show All`.
    public var rows: [Row]

    /// Everyone who is not a room, which is what `summary` counts.
    public var count: Int {
        rows.count
    }

    /// `5 guests: 3 yes, 1 no, 1 awaiting`: Google's words, with no count that is 0.
    public var summary: String {
        let tallies = GuestAnswer.allCases.compactMap { answer -> String? in
            let n = rows.filter { $0.answer == answer }.count
            return n > 0 ? "\(n) \(answer.word)" : nil
        }
        return "\(count) guests: \(tallies.joined(separator: ", "))"
    }

    /// More guests than fit before `Show All`.
    public var isLong: Bool {
        rows.count > GuestList.collapsedLimit
    }

    /// The first eight, or all of them once `Show All` was pressed.
    public func shown(all: Bool) -> [Row] {
        all ? rows : Array(rows.prefix(GuestList.collapsedLimit))
    }

    /// Nil unless at least two people are listed: a list of only the account holder is what
    /// Google sends for an event whose guests are hidden, and one person is not a guest list.
    public init?(_ attendees: [Attendee]) {
        let people = attendees.filter { !$0.isResource }
        guard people.count > 1 else { return nil }
        let ordered = people.filter(\.isOrganizer)
            + people.filter { $0.isSelf && !$0.isOrganizer }
            + people.filter { !$0.isSelf && !$0.isOrganizer }
        rows = ordered.enumerated().map { index, person in
            Row(
                id: index, name: GuestList.name(of: person), email: person.email,
                answer: GuestAnswer(person.response), isOrganizer: person.isOrganizer,
                isOptional: person.isOptional)
        }
    }

    static func name(of person: Attendee) -> String {
        if person.isSelf { return youName }
        let named = person.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let named, !named.isEmpty { return named }
        return person.email
    }
}
