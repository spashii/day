import Foundation

/// The folder holding Day's own files: plain JSON, each replaced atomically, so a reader in
/// another process (the widget) sees the old file or the new one and never half of either.
/// No database: a suspended app holding a SQLite lock in an App Group container is killed
/// with `0xdead10cc`.
///
/// - `accounts.json`: the accounts in the order added.
/// - `calendars-<sub>.json`: one account's calendar list with labels (`CalendarsFile`).
/// - `events-<sub>.json`: one account's fetched window (`EventsFile`).
/// - `visibility.json`: the person's own calendar toggles (`CalendarVisibility`).
/// - `widget-snapshot.json`: what the Lock Screen widget reads (`WidgetSnapshot`).
public struct CacheDirectory: Hashable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The App Group container on iPhone, so the widget reads what the app writes; on the
    /// Mac, `~/Library/Application Support/Day`, since there is no extension to share with.
    public static func shared() throws -> CacheDirectory {
        let fileManager = FileManager.default
        #if os(iOS)
            guard
                let container = fileManager.containerURL(
                    forSecurityApplicationGroupIdentifier: DayIdentifiers.appGroup)
            else { throw CocoaError(.fileNoSuchFile) }
            let url = container.appending(
                path: "Library/Application Support/Day", directoryHint: .isDirectory)
        #else
            let support = try fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: true)
            let url = support.appending(path: "Day", directoryHint: .isDirectory)
        #endif
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return CacheDirectory(url: url)
    }

    public func fileURL(_ name: String) -> URL {
        url.appending(path: name, directoryHint: .notDirectory)
    }

    /// The decoded file, or nil when it is missing or unreadable. A damaged cache file is
    /// treated as no cache: the next fetch rewrites it.
    public func read<Value: Decodable>(_ type: Value.Type, from name: String) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(name)) else { return nil }
        return try? DayJSON.decoder().decode(type, from: data)
    }

    public func write<Value: Encodable>(_ value: Value, to name: String) throws {
        try write(DayJSON.encoder().encode(value), to: name)
    }

    /// Writes to a temporary file beside the target, then swaps it in.
    public func write(_ data: Data, to name: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let destination = fileURL(name)
        let temporary = fileURL(".\(name).\(UUID().uuidString).tmp")
        #if os(iOS)
            // Readable after the first unlock, because widget reloads happen while the phone
            // is locked.
            try data.write(to: temporary, options: [.completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: temporary)
        #endif
        do {
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                do {
                    try fileManager.moveItem(at: temporary, to: destination)
                } catch {
                    // Another process created it in between; replace theirs instead.
                    _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
                }
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public func remove(_ name: String) {
        try? FileManager.default.removeItem(at: fileURL(name))
    }
}

/// File names, kept in one place so the app, the widget and the tests agree.
public enum CacheFile {
    public static let accounts = "accounts.json"
    public static let visibility = "visibility.json"
    public static let widgetSnapshot = WidgetSnapshot.fileName

    public static func calendars(_ account: AccountID) -> String {
        "calendars-\(safe(account.sub)).json"
    }

    public static func events(_ account: AccountID) -> String {
        "events-\(safe(account.sub)).json"
    }

    /// A `sub` is digits; anything else is replaced so it can never escape the folder.
    static func safe(_ sub: String) -> String {
        String(sub.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(scalar) : "_"
        })
    }
}

/// One account's calendar list as last read from Google, labels included. Labels change
/// rarely and cost a call per calendar, so they are read again once a day.
public struct CalendarsFile: Codable, Hashable, Sendable {
    public var fetchedAt: Date
    public var labelsFetchedAt: Date?
    /// Google's order, primary first; not yet deduplicated across accounts.
    public var calendars: [CalendarInfo]

    public init(fetchedAt: Date, labelsFetchedAt: Date?, calendars: [CalendarInfo]) {
        self.fetchedAt = fetchedAt
        self.labelsFetchedAt = labelsFetchedAt
        self.calendars = calendars
    }
}

/// One account's events over the fetched window, as Google returned them (not merged across
/// accounts; the reader merges).
public struct EventsFile: Codable, Hashable, Sendable {
    /// The last full refresh. `Offline. Showing events as of 9:40.` reads it.
    public var fetchedAt: Date
    /// The days this file covers, in the device's zone when fetched.
    public var from: CivilDate
    public var through: CivilDate
    /// Sorted by start.
    public var events: [Event]

    public init(fetchedAt: Date, window: ClosedRange<CivilDate>, events: [Event]) {
        self.fetchedAt = fetchedAt
        from = window.lowerBound
        through = window.upperBound
        self.events = events
    }

    public var window: ClosedRange<CivilDate> {
        from...max(from, through)
    }
}

/// The person's own calendar toggles. A calendar with no entry follows Google's `selected`
/// flag, so day one matches Google Calendar; an entry, once set, wins. Kept in the shared
/// folder so the widget fetches exactly the calendars the app shows.
public struct CalendarVisibility: Codable, Hashable, Sendable {
    public private(set) var overrides: [CalendarID: Bool]

    public init(overrides: [CalendarID: Bool] = [:]) {
        self.overrides = overrides
    }

    public func isVisible(_ calendar: CalendarInfo) -> Bool {
        overrides[calendar.id] ?? calendar.selected
    }

    public mutating func set(_ visible: Bool, for calendar: CalendarID) {
        overrides[calendar] = visible
    }

    /// Drops a removed account's toggles, so adding it back starts from Google's flags.
    public mutating func forget(_ account: AccountID) {
        overrides = overrides.filter { $0.key.account != account }
    }

    // A list of pairs rather than a dictionary, because `CalendarID` is not a string and a
    // dictionary keyed by it encodes as an unreadable flat array.
    struct Entry: Codable {
        var calendar: CalendarID
        var visible: Bool
    }

    enum CodingKeys: String, CodingKey {
        case overrides
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try c.decodeIfPresent([Entry].self, forKey: .overrides) ?? []
        overrides = Dictionary(
            entries.map { ($0.calendar, $0.visible) }, uniquingKeysWith: { _, last in last })
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let entries = overrides.sorted { $0.key < $1.key }.map {
            Entry(calendar: $0.key, visible: $0.value)
        }
        try c.encode(entries, forKey: .overrides)
    }
}
