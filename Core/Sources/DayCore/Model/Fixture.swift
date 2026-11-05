import Foundation

/// An invented calendar on disk: two accounts, their calendars and their events, as each
/// account's fetch would return them (duplicates not yet merged). Tests, day-cli, previews,
/// screenshots and the simulator all run on it, because no real data may leave the device.
public struct Fixture: Codable, Hashable, Sendable {
    /// The zone the invented times are written in. Rules and views run in it, so the
    /// fixture reads the same on any machine.
    public var timeZone: String
    /// Locale for formatting, `en_GB`: 24-hour time, weeks from Monday.
    public var locale: String
    /// The clock the fixture is written around, used unless a test or `-Now` gives another.
    public var now: Date
    /// When the invented data was "fetched".
    public var fetchedAt: Date
    public var accounts: [Account]
    public var calendars: [CalendarInfo]
    public var events: [Event]

    public init(
        timeZone: String,
        locale: String,
        now: Date,
        fetchedAt: Date,
        accounts: [Account],
        calendars: [CalendarInfo],
        events: [Event]
    ) {
        self.timeZone = timeZone
        self.locale = locale
        self.now = now
        self.fetchedAt = fetchedAt
        self.accounts = accounts
        self.calendars = calendars
        self.events = events
    }

    public static func load(from url: URL) throws -> Fixture {
        try DayJSON.decoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Gregorian in the fixture's zone and locale, with the week starting where the locale
    /// starts it.
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        let locale = Locale(identifier: locale)
        calendar.locale = locale
        calendar.firstWeekday = Fixture.weekdayNumber(locale.firstDayOfWeek)
        return calendar
    }

    static func weekdayNumber(_ weekday: Locale.Weekday) -> Int {
        switch weekday {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        @unknown default: 2
        }
    }
}
