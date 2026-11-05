import Foundation

// Google's reminder JSON and the step into the model. These types decode without ever
// throwing: they sit inside `GoogleEvent` and `GoogleCalendarListEntry`, where an error would
// drop the whole event or calendar, and a reminder Day cannot read is not worth that.

/// One reminder in `reminders.overrides` or `defaultReminders`.
public struct GoogleReminder: Decodable, Hashable, Sendable {
    /// `popup` or `email`.
    public var method: String?
    /// Minutes before the start. Google documents 0 to 40320.
    public var minutes: Int?

    public init(method: String? = nil, minutes: Int? = nil) {
        self.method = method
        self.minutes = minutes
    }

    enum CodingKeys: String, CodingKey {
        case method
        case minutes
    }

    public init(from decoder: any Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        method = (try? c?.decodeIfPresent(String.self, forKey: .method)) ?? nil
        minutes = (try? c?.decodeIfPresent(Int.self, forKey: .minutes)) ?? nil
    }
}

/// A list of reminders that decodes to what it can, an empty list for anything else.
public struct GoogleReminderList: Decodable, Hashable, Sendable {
    public var reminders: [GoogleReminder]

    public init(_ reminders: [GoogleReminder] = []) {
        self.reminders = reminders
    }

    public init(from decoder: any Decoder) throws {
        let lenient = try? [Lenient<GoogleReminder>](from: decoder)
        reminders = lenient?.compactMap(\.value) ?? []
    }

    /// Minutes of the popup reminders, ascending and without repeats; email reminders are
    /// Google's own to send.
    public var popupMinutes: [Int] {
        Array(Set(reminders.filter { $0.method == "popup" }.compactMap(\.minutes))).sorted()
    }
}

/// An event's `reminders` object.
public struct GoogleReminders: Decodable, Hashable, Sendable {
    public var useDefault: Bool?
    public var overrides: GoogleReminderList?

    public init(useDefault: Bool? = nil, overrides: [GoogleReminder]? = nil) {
        self.useDefault = useDefault
        self.overrides = overrides.map { GoogleReminderList($0) }
    }

    enum CodingKeys: String, CodingKey {
        case useDefault
        case overrides
    }

    public init(from decoder: any Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        useDefault = (try? c?.decodeIfPresent(Bool.self, forKey: .useDefault)) ?? nil
        overrides = (try? c?.decodeIfPresent(GoogleReminderList.self, forKey: .overrides)) ?? nil
    }
}

extension GoogleDecoding {
    /// What the cache keeps of an event's reminders: nil when the event reminds nowhere
    /// (nothing sent, `useDefault` off and no popup override), so most events of a calendar
    /// with no reminders cost no bytes.
    public static func reminders(_ google: GoogleReminders?) -> EventReminders? {
        guard let google else { return nil }
        let useDefault = google.useDefault == true
        let overrides = google.overrides?.popupMinutes ?? []
        guard useDefault || !overrides.isEmpty else { return nil }
        // Google ignores the overrides while `useDefault` is on, so they are not kept.
        return EventReminders(useDefault: useDefault, overrides: useDefault ? [] : overrides)
    }

    /// The calendar's popup defaults, in minutes.
    public static func defaultReminders(_ list: GoogleReminderList?) -> [Int] {
        list?.popupMinutes ?? []
    }
}
