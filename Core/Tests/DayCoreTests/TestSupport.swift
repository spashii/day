import Foundation
import Testing

@testable import DayCore

/// Shared builders for the rule tests: the invented week, calendars in chosen zones and
/// locales, and short event constructors, so a test reads as the day it describes.
enum TestData {
    static func loadFixture() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "invented-week", withExtension: "json", subdirectory: "Fixtures"))
        return try Fixture.load(from: url)
    }

    /// Gregorian in `zone` and `locale`, weeks from Monday.
    static func calendar(_ zone: String = "Europe/Amsterdam", locale: String = "en_GB") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: locale)
        calendar.firstWeekday = 2
        return calendar
    }

    static let amsterdam = calendar()

    /// `2026-11-04 12:10` read in `calendar`'s zone.
    static func date(_ text: String, in calendar: Calendar = amsterdam) -> Date {
        let parts = text.split(separator: " ")
        let day = CivilDate(String(parts[0]))!
        let clock = parts[1].split(separator: ":").map { Int($0)! }
        let seconds = clock.count > 2 ? clock[2] : 0
        return calendar.date(
            from: DateComponents(
                year: day.year, month: day.month, day: day.day,
                hour: clock[0], minute: clock[1], second: seconds))!
    }

    static func day(_ text: String) -> CivilDate {
        CivilDate(text)!
    }

    // MARK: Accounts and calendars

    static let work = Account(
        id: AccountID("A"), email: "you@acme.com", addedAt: Date(timeIntervalSince1970: 1_000))
    static let personal = Account(
        id: AccountID("P"), email: "you@gmail.com", addedAt: Date(timeIntervalSince1970: 500))

    static let workCalendar = CalendarInfo(
        id: CalendarID(account: work.id, googleID: "you@acme.com"), name: "you@acme.com",
        colorHex: "#4285F4", isPrimary: true, accessRole: .owner)
    static let personalCalendar = CalendarInfo(
        id: CalendarID(account: personal.id, googleID: "you@gmail.com"), name: "Personal",
        colorHex: "#039BE5", isPrimary: true, accessRole: .owner)

    // MARK: Events

    /// A timed event on the work account's calendar. Times are `2026-11-04 14:00` read in
    /// `zone` (default Amsterdam).
    static func event(
        _ title: String,
        _ start: String,
        _ end: String,
        zone: Calendar = amsterdam,
        id: String? = nil,
        uid: String? = nil,
        account: Account = work,
        kind: EventKind = .default,
        status: EventStatus = .confirmed,
        recurring: Bool = false,
        response: Response = .none,
        organizer: Bool = false,
        attendees: Int = 0,
        domains: [String] = [],
        free: Bool = false,
        location: String? = nil,
        join: String? = nil,
        original: String? = nil
    ) -> Event {
        let calendarID = account.id == work.id ? workCalendar.id : personalCalendar.id
        let startDate = date(start, in: zone)
        return Event(
            id: EventID(calendar: calendarID, googleID: id ?? "\(title)-\(start)"),
            iCalUID: uid ?? "\(title)@\(start)",
            originalStart: original.map { date($0, in: zone) },
            title: title,
            time: .timed(start: startDate, end: date(end, in: zone), authoredZone: zone.timeZone.identifier),
            kind: kind,
            status: status,
            isRecurring: recurring,
            response: response,
            isOrganizer: organizer,
            attendeeCount: attendees,
            attendeeDomains: domains,
            isFree: free,
            location: location,
            joinURL: join.flatMap(URL.init(string:)),
            htmlLink: nil,
            description: nil,
            colorKey: .blue)
    }

    /// An all-day event, `2026-11-03` to `2026-11-06` exclusive.
    static func allDay(
        _ title: String,
        _ start: String,
        _ endExclusive: String,
        account: Account = work,
        googleCalendar: String? = nil,
        kind: EventKind = .default,
        status: EventStatus = .confirmed,
        recurring: Bool = false,
        response: Response = .none,
        free: Bool = true
    ) -> Event {
        let calendarID =
            googleCalendar.map { CalendarID(account: account.id, googleID: $0) }
            ?? (account.id == work.id ? workCalendar.id : personalCalendar.id)
        return Event(
            id: EventID(calendar: calendarID, googleID: "\(title)-\(start)"),
            iCalUID: "\(title)@\(start)",
            title: title,
            time: .allDay(start: day(start), endExclusive: day(endExclusive)),
            kind: kind,
            status: status,
            isRecurring: recurring,
            response: response,
            isFree: free,
            colorKey: .blue)
    }

    // MARK: The invented Wednesday

    /// The merged events of the invented week from calendars that are on.
    static func inventedEvents() throws -> [Event] {
        try loadFixture().visibleEvents()
    }

    /// 4 November 2026 at `time`, in Amsterdam.
    static func wednesday(_ time: String) -> Date {
        date("2026-11-04 \(time)")
    }

    /// Characters only: the system puts a no-break space before AM and PM.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

extension WidgetEntry {
    /// The three rectangular lines as the widget view writes them, line 2 with its relative
    /// part as `Text(.currentDate, format: .reference(to:))` renders it. Empty lines are nil.
    func rectangularText(now: Date, calendar: Calendar) -> [String?] {
        var second: String?
        if let when = rectangular.when {
            second = when.text
            if let start = when.relativeTo {
                second! += " · \(Self.systemCountdown(to: start, from: now))"
            }
        }
        return [rectangular.title, second, rectangular.after]
    }

    /// What `Text(.currentDate, format: .reference(to:))` writes inside the hour: `in 10
    /// minutes`, `in 1 minute`. The system's words, not Day's: the widget never abbreviates
    /// them.
    static func systemCountdown(to start: Date, from now: Date) -> String {
        let minutes = Int((max(0, start.timeIntervalSince(now)) / 60).rounded(.up))
        return minutes == 1 ? "in 1 minute" : "in \(minutes) minutes"
    }

    /// The circular family as the design's table writes it: `THU 9:30`, `9:30`, or `symbol`.
    var circularText: String {
        switch circular {
        case .symbol: "symbol"
        case .time(let time, let weekday, let period):
            [weekday, time, period].compactMap { $0 }.joined(separator: " ")
        }
    }
}
