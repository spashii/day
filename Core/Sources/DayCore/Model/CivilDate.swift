import Foundation

/// A day on the wall calendar, with no time and no zone: `2026-11-04`.
///
/// All-day events are civil dates with an exclusive end, never a `Date` at UTC midnight:
/// that conversion is the usual off-by-one bug east or west of Greenwich. A civil date only
/// becomes an instant when a time zone is supplied, at the edge where it is drawn.
///
/// `Strideable` with an `Int` stride, so `ClosedRange<CivilDate>` is a collection of days.
public struct CivilDate: Hashable, Comparable, Strideable, Sendable, Codable,
    LosslessStringConvertible
{
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        self.init(date, in: CivilDate.gregorian(timeZone))
    }

    /// The day `date` falls on in `calendar`'s time zone.
    public init(_ date: Date, in calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// The first instant of this day in `timeZone`. Where a zone skips midnight for daylight
    /// saving, that is the first instant that exists.
    public func date(in timeZone: TimeZone) -> Date {
        date(in: CivilDate.gregorian(timeZone))
    }

    /// The first instant of this day in `calendar`'s time zone.
    public func date(in calendar: Calendar) -> Date {
        // Noon always exists, so start from it and let the calendar find the day's start.
        let noon = calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return calendar.startOfDay(for: noon)
    }

    public func adding(days: Int) -> CivilDate {
        advanced(by: days)
    }

    /// 1 is Sunday through 7 Saturday, as `Calendar` numbers weekdays.
    public var weekday: Int {
        // 1970-01-01 was a Thursday (5).
        let n = (dayNumber % 7 + 7) % 7
        return (n + 4) % 7 + 1
    }

    /// `2026-11-04`.
    public var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String {
        isoString
    }

    /// Parses `2026-11-04`; nil for anything else, including impossible days.
    public init?(_ description: String) {
        let parts = description.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
            (1...12).contains(m), (1...CivilDate.daysIn(month: m, year: y)).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = CivilDate(string) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a yyyy-MM-dd date: \(string)")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }

    public static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public func distance(to other: CivilDate) -> Int {
        other.dayNumber - dayNumber
    }

    public func advanced(by n: Int) -> CivilDate {
        CivilDate(dayNumber: dayNumber + n)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's
    /// days_from_civil), so day arithmetic never touches a time zone.
    var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    init(dayNumber: Int) {
        let z = dayNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(year: yoe + era * 400 + (m <= 2 ? 1 : 0), month: m, day: d)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
