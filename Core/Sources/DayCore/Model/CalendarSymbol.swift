import Foundation

/// One of the SF Symbols a calendar can wear instead of its color dot.
///
/// The set is curated and closed: thirty symbols that suit a calendar, every one in SF
/// Symbols since iOS 16 and macOS 13, so each exists on every system Day runs on. A
/// closed set keeps the picker one compact grid, and lets a stored name that is not in the
/// set (a damaged file, a symbol a later version dropped) fall back to the color dot rather
/// than draw an empty image.
public struct CalendarSymbol: Hashable, Identifiable, Sendable {
    /// The SF Symbol name, which is also what the symbols file stores.
    public let name: String
    /// What VoiceOver says for the symbol in the picker.
    public let label: String

    public var id: String { name }

    init(_ name: String, _ label: String) {
        self.name = name
        self.label = label
    }

    /// The picker's order: work and study, people and home, travel, health, food, money,
    /// fun, birthdays. Six to a row, so five full rows.
    public static let all: [CalendarSymbol] = [
        CalendarSymbol("briefcase", "Work"),
        CalendarSymbol("building.2", "Office"),
        CalendarSymbol("laptopcomputer", "Computer"),
        CalendarSymbol("graduationcap", "Study"),
        CalendarSymbol("book", "Reading"),
        CalendarSymbol("house", "Home"),
        CalendarSymbol("person", "Personal"),
        CalendarSymbol("person.2", "People"),
        CalendarSymbol("person.3", "Family"),
        CalendarSymbol("figure.and.child.holdinghands", "Kids"),
        CalendarSymbol("heart", "Heart"),
        CalendarSymbol("pawprint", "Pets"),
        CalendarSymbol("airplane", "Flights"),
        CalendarSymbol("suitcase", "Trips"),
        CalendarSymbol("car", "Car"),
        CalendarSymbol("beach.umbrella", "Holiday"),
        CalendarSymbol("cross.case", "Health"),
        CalendarSymbol("figure.run", "Running"),
        CalendarSymbol("dumbbell", "Gym"),
        CalendarSymbol("fork.knife", "Food"),
        CalendarSymbol("cup.and.saucer", "Coffee"),
        CalendarSymbol("wineglass", "Drinks"),
        CalendarSymbol("creditcard", "Money"),
        CalendarSymbol("banknote", "Cash"),
        CalendarSymbol("music.note", "Music"),
        CalendarSymbol("theatermasks", "Theater"),
        CalendarSymbol("soccerball", "Sport"),
        CalendarSymbol("bicycle", "Cycling"),
        CalendarSymbol("birthday.cake", "Birthday"),
        CalendarSymbol("gift", "Gifts"),
    ]

    /// The symbol with this SF Symbol name, or nil when the set does not hold it.
    public static func named(_ name: String) -> CalendarSymbol? {
        byName[name]
    }

    private static let byName: [String: CalendarSymbol] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) })
}

/// The symbol each calendar wears, chosen by the person on this device.
///
/// It lives in `calendar-symbols.json` in the shared folder and never in Google: Day is
/// read-only, and a symbol is Day's own decoration. The app writes the file; the Lock
/// Screen widget reads it. A calendar with no entry has no symbol and draws its color dot,
/// which is the default for every calendar.
///
/// Entries are keyed by account and Google calendar ID, the same key as visibility, so two
/// accounts that share one calendar can wear different symbols.
public struct CalendarSymbolMap: Codable, Hashable, Sendable {
    public static let fileName = "calendar-symbols.json"

    /// SF Symbol names by calendar. A name may be one the set no longer holds; lookups
    /// check, so it reads as no symbol.
    public private(set) var assigned: [CalendarID: String]

    public init(assigned: [CalendarID: String] = [:]) {
        self.assigned = assigned
    }

    public var isEmpty: Bool {
        assigned.isEmpty
    }

    /// The calendar's symbol, or nil for the color dot.
    public func symbol(for calendar: CalendarID) -> CalendarSymbol? {
        assigned[calendar].flatMap(CalendarSymbol.named)
    }

    /// The symbol an event shows: its own calendar's, else the first of the other calendars
    /// it was merged from that has one.
    public func symbol(for event: Event) -> CalendarSymbol? {
        for calendar in [event.id.calendar] + event.calendars {
            if let symbol = symbol(for: calendar) { return symbol }
        }
        return nil
    }

    /// The symbol of the calendar the next event sits on, as the Lock Screen's inline and
    /// circular families name that event. Nil when nothing is ahead or its calendar has no
    /// symbol. `events` are merged events from visible calendars, as `nextEvents` takes.
    public func nextEventSymbol(
        events: [Event], now: Date, calendar: Calendar
    ) -> CalendarSymbol? {
        guard !isEmpty,
            let next = nextEvents(events: events, now: now, calendar: calendar).next
        else { return nil }
        return symbol(for: next)
    }

    /// The symbol that leads the Mac menu bar label: the calendar of the event the label's
    /// text is about (`menuBarEvent`). Nil when the label is the `calendar` symbol alone, or
    /// that calendar has no symbol, which leaves the text as it is.
    public func menuBarSymbol(
        next: NextEvents, now: Date, calendar: Calendar
    ) -> CalendarSymbol? {
        guard !isEmpty, let event = menuBarEvent(next: next, now: now, calendar: calendar)
        else { return nil }
        return symbol(for: event)
    }

    /// Sets the calendar's symbol; nil goes back to the color dot.
    public mutating func set(_ symbol: CalendarSymbol?, for calendar: CalendarID) {
        assigned[calendar] = symbol?.name
    }

    /// Drops a removed account's symbols, as its visibility toggles are dropped.
    public mutating func forget(_ account: AccountID) {
        assigned = assigned.filter { $0.key.account != account }
    }

    // A list of pairs rather than a dictionary, because `CalendarID` is not a string and a
    // dictionary keyed by it encodes as an unreadable flat array. Sorted, so rewriting an
    // unchanged map produces the same bytes.
    struct Entry: Codable {
        var calendar: CalendarID
        var symbol: String
    }

    enum CodingKeys: String, CodingKey {
        case symbols
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try c.decodeIfPresent([Entry].self, forKey: .symbols) ?? []
        assigned = Dictionary(
            entries.map { ($0.calendar, $0.symbol) }, uniquingKeysWith: { _, last in last })
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let entries = assigned.sorted { $0.key < $1.key }.map {
            Entry(calendar: $0.key, symbol: $0.value)
        }
        try c.encode(entries, forKey: .symbols)
    }

    // MARK: The file

    /// The map on disk; empty when there is no file or it cannot be read, so a damaged file
    /// costs the symbols and never the calendar.
    public static func read(from cache: CacheDirectory) -> CalendarSymbolMap {
        cache.read(CalendarSymbolMap.self, from: fileName) ?? CalendarSymbolMap()
    }

    public func write(to cache: CacheDirectory) throws {
        try cache.write(self, to: Self.fileName)
    }
}
