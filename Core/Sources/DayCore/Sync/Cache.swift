import Foundation

/// The folder holding Day's own files: plain JSON, each replaced atomically, so a reader in
/// another process (the widget) sees the old file or the new one and never half of either.
/// No database: a suspended app holding a SQLite lock in an App Group container is killed
/// with `0xdead10cc`.
///
/// - `accounts.json`: the accounts in the order added.
/// - `calendars-<sub>.json`: one account's calendar list with labels and its sync token
///   (`CalendarsFile`).
/// - `events-<sub>.json`: one account's events (`EventsFile`).
/// - `sync-<sub>.json`: beside it, each calendar's sync token and the days it covers
///   (`SyncFile`).
/// - `near-<sub>.json`: the part of those two the widget needs, today through a week and more
///   ahead, in one small file (`NearFile`).
/// - `visibility.json`: the person's own calendar toggles (`CalendarVisibility`).
/// - `widget-snapshot.json`: what the Lock Screen widget reads (`WidgetSnapshot`).
public struct CacheDirectory: Hashable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The App Group container on iPhone, so the widget reads what the app writes; on the
    /// Mac, `~/Library/Application Support/Day`. The Mac's desktop widget reads only the
    /// snapshot, which the app copies into the App Group itself (`WidgetSnapshotWriter`).
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

    public static func sync(_ account: AccountID) -> String {
        "sync-\(safe(account.sub)).json"
    }

    public static func near(_ account: AccountID) -> String {
        "near-\(safe(account.sub)).json"
    }

    /// A `sub` is digits; anything else is replaced so it can never escape the folder.
    static func safe(_ sub: String) -> String {
        String(sub.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(scalar) : "_"
        })
    }
}

/// One account's calendar list as last read from Google, labels included, with the token
/// its next incremental read starts from. Both sit in one file, so the token never runs
/// ahead of the list it describes. Labels change rarely and cost a call per calendar, so they
/// are read again with the daily full list.
public struct CalendarsFile: Codable, Hashable, Sendable {
    /// When Google last answered for the list, in full or with changes.
    public var fetchedAt: Date
    public var labelsFetchedAt: Date?
    /// Google's order, primary first; not yet deduplicated across accounts. A calendar added
    /// by an incremental read joins at the end.
    public var calendars: [CalendarInfo]
    /// `nextSyncToken` from the last read; nil until a full read has carried one.
    public var syncToken: String?
    /// When the list was last read in full. Incremental reads leave out changes to a
    /// calendar's own properties (the name and zone its owner set, the access role), so the
    /// list is read in full again once a day.
    public var fullSyncAt: Date?

    public init(
        fetchedAt: Date, labelsFetchedAt: Date?, calendars: [CalendarInfo],
        syncToken: String? = nil, fullSyncAt: Date? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.labelsFetchedAt = labelsFetchedAt
        self.calendars = calendars
        self.syncToken = syncToken
        self.fullSyncAt = fullSyncAt
    }
}

/// One account's events, as Google returned them (not merged across accounts; the reader
/// merges). Rewritten only when the events change, because a refresh every few minutes
/// usually finds nothing new and the file is the largest Day keeps.
public struct EventsFile: Codable, Hashable, Sendable {
    /// Sorted by start.
    public var events: [Event]

    public init(events: [Event]) {
        self.events = events
    }
}

/// How one account's events are kept current: the last complete refresh and each calendar's
/// sync token, in `sync-<sub>.json` beside the events. Small, so it is written on every
/// refresh.
public struct SyncFile: Codable, Hashable, Sendable {
    /// The last refresh in which every shown calendar of the account answered.
    /// `Offline. Showing events as of 9:40.` reads it. Nil until one has.
    public var fetchedAt: Date?
    /// One entry per calendar that has been fetched.
    public var calendars: [CalendarSync]

    public init(fetchedAt: Date?, calendars: [CalendarSync]) {
        self.fetchedAt = fetchedAt
        self.calendars = calendars
    }
}

/// One account's events and sync state as one value, which every change works on. On disk
/// it is the two files above, each replaced atomically, the events first: a crash between
/// the two leaves new events with old tokens, and reading changes again from an old token is
/// harmless, because each change carries the event's whole current state. The other order
/// could leave a token ahead of its events, and the change in between would be lost for good.
/// Readers go the other way, sync file first (`CacheDirectory.account(_:)`), so whatever
/// moment they land on, the events are at least as new as the tokens. The near file follows
/// last and is a copy of the two.
public struct AccountCache: Hashable, Sendable {
    public var fetchedAt: Date?
    /// Sorted by start once `sortEvents` has run.
    public var events: [Event]
    public var sync: [CalendarSync]

    public init(fetchedAt: Date? = nil, events: [Event] = [], sync: [CalendarSync] = []) {
        self.fetchedAt = fetchedAt
        self.events = events
        self.sync = sync
    }

    public func state(of calendar: CalendarID) -> CalendarSync? {
        sync.first { $0.calendar == calendar }
    }
}

extension CacheDirectory {
    /// The account's events and sync state, or nil when neither file exists.
    ///
    /// The sync file is read first, because the app writes the events first and the sync file
    /// second. A reader in another process (the widget) that lands between the two writes then
    /// gets new events with an old token, which only means reading some changes again. The
    /// other order could pair old events with a new token, and the changes in between would
    /// be missed: the widget would write a snapshot without them, stamped newer than the
    /// app's correct one.
    public func account(_ id: AccountID) -> AccountCache? {
        account(id, betweenReads: {})
    }

    /// `betweenReads` runs after the first file is read and before the second, which is where
    /// another process's write can land. Tests write there.
    func account(_ id: AccountID, betweenReads: () -> Void) -> AccountCache? {
        let sync = read(SyncFile.self, from: CacheFile.sync(id))
        betweenReads()
        let events = read(EventsFile.self, from: CacheFile.events(id))
        guard events != nil || sync != nil else { return nil }
        // Events with no sync state read as never synced: every calendar gets a full read,
        // which writes one.
        return AccountCache(
            fetchedAt: sync?.fetchedAt, events: events?.events ?? [],
            sync: events == nil ? [] : sync?.calendars ?? [])
    }

    /// Writes `account`, the events file only when its events differ from `previous`'s.
    public func write(_ account: AccountCache, for id: AccountID, previous: AccountCache?) throws {
        let missing = !FileManager.default.fileExists(
            atPath: fileURL(CacheFile.events(id)).path(percentEncoded: false))
        if missing || previous?.events != account.events {
            try write(EventsFile(events: account.events), to: CacheFile.events(id))
        }
        try write(SyncFile(fetchedAt: account.fetchedAt, calendars: account.sync), to: CacheFile.sync(id))
    }

    public func removeAccount(_ id: AccountID) {
        remove(CacheFile.near(id))
        remove(CacheFile.sync(id))
        remove(CacheFile.events(id))
        remove(CacheFile.calendars(id))
    }

    /// The account's near file, or nil when there is none or it cannot be read.
    public func near(_ id: AccountID) -> NearFile? {
        read(NearFile.self, from: CacheFile.near(id))
    }

    /// Writes the near file for `account`, after its events and sync file. It is only ever a
    /// copy: if it falls behind, it holds old events with the old tokens that go with them,
    /// which the widget reads changes from correctly.
    public func writeNear(
        _ account: AccountCache, for id: AccountID, days: ClosedRange<CivilDate>,
        calendar: Calendar
    ) throws {
        let range = SyncEngine.interval(days, calendar: calendar)
        try write(
            NearFile(
                days: days, fetchedAt: account.fetchedAt,
                events: account.events.filter { SyncEngine.overlaps($0, range, calendar: calendar) },
                sync: account.sync),
            to: CacheFile.near(id))
    }
}

/// The part of one account's cache the widget reads, in one file so the events and the tokens
/// that go with them can never be seen from two moments. The widget has about 30 MB and 5
/// seconds, and the full cache holds five months of events with their descriptions: a few
/// megabytes of JSON to decode and several times that in memory before the first request.
/// This holds only the events overlapping `days`.
public struct NearFile: Codable, Hashable, Sendable {
    /// The days `events` is complete for.
    public var days: ClosedRange<CivilDate>
    /// The account's `fetchedAt` when this was written.
    public var fetchedAt: Date?
    /// Every event of the account overlapping `days`, sorted as the cache is.
    public var events: [Event]
    /// Every calendar's sync state as it was when the events were written.
    public var sync: [CalendarSync]

    public init(
        days: ClosedRange<CivilDate>, fetchedAt: Date?, events: [Event], sync: [CalendarSync]
    ) {
        self.days = days
        self.fetchedAt = fetchedAt
        self.events = events
        self.sync = sync
    }

    /// Whether it can stand in for the full cache when `needed` days are asked for.
    func covers(_ needed: ClosedRange<CivilDate>) -> Bool {
        days.lowerBound <= needed.lowerBound && days.upperBound >= needed.upperBound
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
