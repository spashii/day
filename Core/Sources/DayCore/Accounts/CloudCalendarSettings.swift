import CryptoKit
import Foundation
import Synchronization

/// Why the key-value store changed (`NSUbiquitousKeyValueStoreChangeReasonKey`).
public enum SettingsChange: Hashable, Sendable {
    /// Another device wrote or removed these keys.
    case server(keys: [String])
    /// The first download for this Apple ID, on this device's first launch. The store looks
    /// empty until it ends, and a key the download has not brought yet reads as removed.
    case initialSync
    /// The device's iCloud account changed; the store is another account's.
    case account
    /// The app wrote more than the store allows; nothing was lost, and nothing is applied.
    case quotaViolation
}

/// What keeps a `SettingsCloud` observation alive; it stops when released or cancelled.
public final class SettingsObservation: Sendable {
    private let stop: Mutex<(@Sendable () -> Void)?>

    public init(_ stop: @escaping @Sendable () -> Void) {
        self.stop = Mutex(stop)
    }

    public func cancel() {
        stop.withLock { current in
            current?()
            current = nil
        }
    }

    deinit { cancel() }
}

/// A key-value store every device on the Apple ID shares: `NSUbiquitousKeyValueStore` in the
/// apps (`UbiquitousSettings` in app/Shared/Model), memory in tests.
public protocol SettingsCloud: Sendable {
    func data(forKey key: String) -> Data?
    /// Sets the value; nil removes the key.
    func setData(_ data: Data?, forKey key: String)
    func keys() -> [String]
    /// Calls `changed` each time the store changes from outside this process, with the reason,
    /// and asks the store for what changed while the app was not running.
    func observe(_ changed: @escaping @Sendable (SettingsChange) -> Void) -> SettingsObservation
}

/// A settings cloud in memory. Two settings stores given the same instance behave like two
/// devices on one Apple ID.
public final class MemorySettingsCloud: SettingsCloud {
    private struct State {
        var values: [String: Data]
        var downloading = false
        var observers: [Int: @Sendable (SettingsChange) -> Void] = [:]
        var nextObserver = 0
    }

    private let state: Mutex<State>

    public init(_ values: [String: Data] = [:]) {
        state = Mutex(State(values: values))
    }

    /// The first download is under way: a write is dropped, as the real store does, until
    /// `finishInitialDownload`.
    public var isDownloading: Bool {
        get { state.withLock { $0.downloading } }
        set { state.withLock { $0.downloading = newValue } }
    }

    public func data(forKey key: String) -> Data? {
        state.withLock { $0.values[key] }
    }

    public func setData(_ data: Data?, forKey key: String) {
        state.withLock { state in
            guard !state.downloading else { return }
            state.values[key] = data
        }
    }

    public func keys() -> [String] {
        state.withLock { Array($0.values.keys) }
    }

    public func observe(_ changed: @escaping @Sendable (SettingsChange) -> Void) -> SettingsObservation {
        let id = state.withLock { state in
            state.nextObserver += 1
            state.observers[state.nextObserver] = changed
            return state.nextObserver
        }
        return SettingsObservation { [weak self] in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
    }

    /// What iCloud does to the store from outside: sets `values` as another device or the
    /// download would, then tells every observer why.
    public func deliver(_ change: SettingsChange, setting values: [String: Data?] = [:]) {
        let observers = state.withLock { state in
            for (key, value) in values { state.values[key] = value }
            return Array(state.observers.values)
        }
        for observer in observers { observer(change) }
    }

    /// The first download ends: the server's values arrive and observers hear why.
    public func finishInitialDownload(bringing values: [String: Data] = [:]) {
        state.withLock { $0.downloading = false }
        deliver(.initialSync, setting: values.mapValues { Optional($0) })
    }
}

/// One calendar's setting as the cloud holds it. A visibility entry carries `visible`, a
/// symbol entry carries `symbol`; the account is a hash too, so removing an account can find
/// every entry of its own.
public struct CalendarSettingsEntry: Codable, Hashable, Sendable {
    public var account: String
    /// The person's toggle, in a visibility entry.
    public var visible: Bool?
    /// The SF Symbol name in a symbol entry; nil is the color dot.
    public var symbol: String?

    enum CodingKeys: String, CodingKey {
        case account = "a"
        case visible = "v"
        case symbol = "s"
    }

    public init(account: String, visible: Bool? = nil, symbol: String? = nil) {
        self.account = account
        self.visible = visible
        self.symbol = symbol
    }
}

/// The two files the widgets read, together: what the cloud's entries are laid over.
public struct CalendarSettings: Hashable, Sendable {
    public var visibility: CalendarVisibility
    public var symbols: CalendarSymbolMap

    public init(visibility: CalendarVisibility, symbols: CalendarSymbolMap) {
        self.visibility = visibility
        self.symbols = symbols
    }
}

/// The person's calendar settings, shared by every device on the Apple ID through the iCloud
/// key-value store, two keys per calendar: `v.<hash>` holds whether it is shown and `s.<hash>`
/// its symbol. Each is last write wins on its own, so choosing an icon on one device never
/// erases a toggle made on another, and the other way round.
///
/// The key-value store is ordinary iCloud data, not end-to-end encrypted, so it never holds
/// an address or a calendar ID: each key is a hash of the account's Google user ID and the
/// calendar's ID, and the entry names its account by another hash. A change on the Mac and one
/// on the iPhone to different calendars never collide either. Two keys for each calendar stay
/// far under the store's limits of 1024 keys and 1 MB.
///
/// The files the widgets read (`visibility.json`, `calendar-symbols.json`) stay as they are
/// and become this device's copy: every change is written to both, and `reconcile` lays the
/// cloud's entries over the copy on launch, after each refresh and when another device
/// changes a key.
///
/// An entry, once written, is only ever replaced, never removed, except when its account is
/// removed. Choosing no symbol writes an entry without one, so a device that was off at the
/// time cannot bring the old symbol back.
public struct CloudCalendarSettings: Sendable {
    public let cloud: any SettingsCloud

    public init(cloud: any SettingsCloud) {
        self.cloud = cloud
    }

    static let visibilityPrefix = "v."
    static let symbolPrefix = "s."

    /// `v.` and 32 hex digits: under the store's 64-byte key limit, and the same on every
    /// device for the same account and calendar.
    public static func visibilityKey(for calendar: CalendarID) -> String {
        visibilityPrefix + hash(for: calendar)
    }

    public static func symbolKey(for calendar: CalendarID) -> String {
        symbolPrefix + hash(for: calendar)
    }

    private static func hash(for calendar: CalendarID) -> String {
        hash("day-calendar\n\(calendar.account.sub)\n\(calendar.googleID)", bytes: 16)
    }

    /// The account as entries name it.
    public static func tag(for account: AccountID) -> String {
        hash("day-account\n\(account.sub)", bytes: 8)
    }

    private static func hash(_ text: String, bytes: Int) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(bytes).map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: Reading

    /// An entry as the cloud holds it. `.unreadable` for a value that does not decode (one a
    /// later version wrote), which is neither applied nor written over.
    enum Lookup: Hashable {
        case none
        case entry(CalendarSettingsEntry)
        case unreadable
    }

    func lookup(_ key: String) -> Lookup {
        guard let data = cloud.data(forKey: key) else { return .none }
        guard let entry = try? JSONDecoder().decode(CalendarSettingsEntry.self, from: data) else {
            return .unreadable
        }
        return .entry(entry)
    }

    /// Whether another device shows the calendar; nil when it has not said.
    func visible(for calendar: CalendarID) -> Bool? {
        if case .entry(let entry) = lookup(Self.visibilityKey(for: calendar)) { return entry.visible }
        return nil
    }

    /// The symbol another device chose; nil for the color dot or no entry (`hasSymbolEntry`).
    func symbol(for calendar: CalendarID) -> String? {
        if case .entry(let entry) = lookup(Self.symbolKey(for: calendar)) { return entry.symbol }
        return nil
    }

    /// Whether any device has written the calendar's symbol entry, even one for no symbol.
    func hasSymbolEntry(for calendar: CalendarID) -> Bool {
        if case .entry = lookup(Self.symbolKey(for: calendar)) { return true }
        return false
    }

    // MARK: Writing

    /// The person toggled a calendar.
    public func setVisible(_ visible: Bool, for calendar: CalendarID) {
        write(
            CalendarSettingsEntry(account: Self.tag(for: calendar.account), visible: visible),
            forKey: Self.visibilityKey(for: calendar))
    }

    /// The person chose a symbol, nil for the color dot.
    public func setSymbol(_ name: String?, for calendar: CalendarID) {
        write(
            CalendarSettingsEntry(account: Self.tag(for: calendar.account), symbol: name),
            forKey: Self.symbolKey(for: calendar))
    }

    /// Removes every entry of the account, including calendars this device never listed.
    public func forget(_ account: AccountID) {
        let tag = Self.tag(for: account)
        for key in cloud.keys() where key.hasPrefix(Self.visibilityPrefix) || key.hasPrefix(Self.symbolPrefix) {
            if case .entry(let entry) = lookup(key), entry.account == tag {
                cloud.setData(nil, forKey: key)
            }
        }
    }

    private func write(_ entry: CalendarSettingsEntry, forKey key: String) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        cloud.setData(data, forKey: key)
    }

    // MARK: Changes from outside

    /// The keys to pass `reconcile` as removed for `change`, or nil when the change is to be
    /// skipped.
    /// - Another device's change: the keys that are gone now, which clear the calendar here.
    /// - The first download and an account switch: none. The store looks empty while it
    ///   downloads, so a key missing then says nothing about another device, and the settings
    ///   in the files must survive; reconciling again once it is done gives the store the
    ///   settings it lacks.
    /// - Over the quota: skipped, since what the store holds is not what was written.
    public func removedKeys(for change: SettingsChange) -> Set<String>? {
        switch change {
        case .server(let keys):
            return Set(keys.filter { cloud.data(forKey: $0) == nil })
        case .initialSync, .account:
            return []
        case .quotaViolation:
            return nil
        }
    }

    // MARK: Reconciling

    /// This device's settings with the cloud's laid over them, for the calendars in `known`.
    /// For the toggle and the symbol, each on its own:
    /// - a calendar with an entry takes it;
    /// - a calendar whose key another device just removed (`removed`, from `removedKeys`)
    ///   loses that setting here too;
    /// - a calendar with a setting here and no entry gives the cloud its setting. On the first
    ///   launch of this version that copies the files into the cloud; later it covers a cloud
    ///   that was out of reach when the setting was made.
    /// Settings of calendars not in `known` are left as they are.
    public func reconcile(
        _ local: CalendarSettings, known: [CalendarID], removed: Set<String> = []
    ) -> CalendarSettings {
        var visibility = local.visibility.overrides
        var symbols = local.symbols.assigned
        for calendar in Set(known) {
            let visibleKey = Self.visibilityKey(for: calendar)
            switch lookup(visibleKey) {
            case .entry(let entry):
                if let visible = entry.visible { visibility[calendar] = visible }
            case .unreadable:
                break
            case .none where removed.contains(visibleKey):
                visibility[calendar] = nil
            case .none:
                if let visible = visibility[calendar] { setVisible(visible, for: calendar) }
            }
            let symbolKey = Self.symbolKey(for: calendar)
            switch lookup(symbolKey) {
            case .entry(let entry):
                symbols[calendar] = entry.symbol
            case .unreadable:
                break
            case .none where removed.contains(symbolKey):
                symbols[calendar] = nil
            case .none:
                if let symbol = symbols[calendar] { setSymbol(symbol, for: calendar) }
            }
        }
        return CalendarSettings(
            visibility: CalendarVisibility(overrides: visibility),
            symbols: CalendarSymbolMap(assigned: symbols))
    }
}
