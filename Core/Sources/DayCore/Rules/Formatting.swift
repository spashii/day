import Foundation

/// Every piece of text the rules and views share. Times and dates come from the calendar's
/// locale and zone, so 24-hour time follows the system and the fixture reads the same on any
/// machine. Counts one to nine are words, 10 and up numerals.
///
/// Times are written without a leading zero in 24-hour locales (`9:30`, `14:00`), because the
/// design's copy reads that way and a Lock Screen line has no room to spare. 12-hour locales
/// use the system's own pattern (`9:30 AM`), which this file never rewrites.
public enum Formatting {
    // MARK: Counts and durations

    /// `one` to `nine`, then `10`.
    public static func count(_ n: Int) -> String {
        (1...9).contains(n) ? words[n - 1] : String(n)
    }

    /// Sentence-initial: `One` to `Nine`, then `10`.
    public static func countCapitalized(_ n: Int) -> String {
        let word = count(n)
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// `2 more`. A numeral at every size, as the all-day line and the Earlier row write it.
    public static func more(_ n: Int) -> String {
        "\(n) more"
    }

    /// `25 min`, `1 h`, `1 h 30 min`, rounded to the nearest minute. For spans between two
    /// events, which are whole minutes already.
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded())
        return minutesText(minutes)
    }

    /// A remaining span rounded up to the minute, so a countdown never reads `0 min` while
    /// something is still ahead: `in 20 min`, `ends in 1 h 5 min`.
    public static func countdown(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded(.up))
        return minutesText(minutes)
    }

    /// `1 h free`, `1 h 30 min free`: the text of a gap row.
    public static func free(_ interval: TimeInterval) -> String {
        "\(duration(interval)) free"
    }

    /// `1 account signed out`, `2 accounts signed out`.
    public static func signedOut(accounts n: Int) -> String {
        n == 1 ? "1 account signed out" : "\(n) accounts signed out"
    }

    // MARK: Times

    /// `9:30`, `14:00` in 24-hour locales; `9:30 AM` in 12-hour ones.
    public static func time(_ date: Date, calendar: Calendar) -> String {
        if uses24Hour(calendar) {
            return clock(date, calendar: calendar).digits
        }
        return date.formatted(style(calendar).hour(.defaultDigits(amPM: .abbreviated)).minute())
    }

    /// The digits of a time and, in 12-hour locales, its period apart: `("9:30", "AM")`. The
    /// circular widget stacks the two; everything else uses `time`.
    public static func clock(_ date: Date, calendar: Calendar) -> (digits: String, period: String?) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        if uses24Hour(calendar) {
            return (String(format: "%d:%02d", hour, minute), nil)
        }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        let period = hour < 12 ? calendar.amSymbol : calendar.pmSymbol
        return (String(format: "%d:%02d", twelve, minute), period)
    }

    /// `Thu 9:30`.
    public static func weekdayTime(_ date: Date, calendar: Calendar) -> String {
        "\(shortWeekday(date, calendar: calendar)) \(time(date, calendar: calendar))"
    }

    /// `Tomorrow 9:30` for the next day, `Thu 9:30` for any later one, and `9:30` for today.
    /// The Lock Screen's line 2 and 3 and the inline form use it for events that are not today.
    public static func dayTime(_ date: Date, relativeTo now: Date, calendar: Calendar) -> String {
        let today = CivilDate(now, in: calendar)
        let day = CivilDate(date, in: calendar)
        switch today.distance(to: day) {
        case ...0: return time(date, calendar: calendar)
        case 1: return "Tomorrow \(time(date, calendar: calendar))"
        default: return weekdayTime(date, calendar: calendar)
        }
    }

    /// `Thu`.
    public static func shortWeekday(_ date: Date, calendar: Calendar) -> String {
        date.formatted(style(calendar).weekday(.abbreviated))
    }

    /// `THU`, for the circular widget's caption.
    public static func shortWeekdayCapitalized(_ date: Date, calendar: Calendar) -> String {
        shortWeekday(date, calendar: calendar).uppercased(with: calendar.locale)
    }

    // MARK: Days and months

    /// `Europe/Amsterdam` to `Amsterdam`, `America/New_York` to `New York`.
    public static func city(zoneIdentifier: String) -> String {
        let last = zoneIdentifier.split(separator: "/").last.map(String.init) ?? zoneIdentifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// `Wednesday`.
    public static func weekday(_ day: CivilDate, calendar: Calendar) -> String {
        day.date(in: calendar).formatted(style(calendar).weekday(.wide))
    }

    /// `4 November`.
    public static func dayAndMonth(_ day: CivilDate, calendar: Calendar) -> String {
        day.date(in: calendar).formatted(style(calendar).day().month(.wide))
    }

    /// `Wednesday 4 November`.
    public static func dayHeader(_ day: CivilDate, calendar: Calendar) -> String {
        day.date(in: calendar).formatted(style(calendar).weekday(.wide).day().month(.wide))
    }

    /// `November`, or `January 2027` outside the current year. The Mac toolbar always
    /// carries the year: `November 2026`.
    public static func monthTitle(
        year: Int, month: Int, now: Date, calendar: Calendar, alwaysYear: Bool = false
    ) -> String {
        let first = CivilDate(year: year, month: month, day: 1).date(in: calendar)
        let thisYear = calendar.component(.year, from: now) == year
        let format = alwaysYear || !thisYear
            ? style(calendar).month(.wide).year()
            : style(calendar).month(.wide)
        return first.formatted(format)
    }

    /// `1 Dec`, beside the numeral on the first of a month.
    public static func firstOfMonth(_ day: CivilDate, calendar: Calendar) -> String {
        day.date(in: calendar).formatted(style(calendar).day().month(.abbreviated))
    }

    // MARK: Event lines

    /// The event sheet's time line, written by the system's own interval formatter so the
    /// range mark, the digits and the order follow the device's language and region:
    /// `Wednesday 4 November, 14:00` to `15:00` for one day, both dates for an event that
    /// crosses midnight, and `Wednesday 4 November` to `Friday 6 November` for an all-day
    /// range. Day's other time strings are written by hand (`9:30`, `14:00 to
    /// 15:00`), so this line is the one place a 24-hour time may carry a leading zero.
    public static func eventWhen(_ event: Event, calendar: Calendar) -> String {
        let interval = Date.IntervalFormatStyle(
            locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        switch event.time {
        case .allDay(let start, let endExclusive):
            // The exclusive end is the day after the last one; a single day is a range of one.
            let last = max(start, endExclusive.adding(days: -1))
            return interval.weekday(.wide).day().month(.wide)
                .format(start.date(in: calendar)..<last.date(in: calendar))
        case .timed(let start, let end, _):
            return interval.weekday(.wide).day().month(.wide).hour().minute()
                .format(start..<max(start, end))
        }
    }

    /// `9:30 to 10:30 in Amsterdam`, only when the event was written in a zone whose offset
    /// differs from `calendar`'s at that moment.
    public static func authoredTime(_ event: Event, calendar: Calendar) -> String? {
        guard case .timed(let start, let end, let zone?) = event.time,
            let authored = TimeZone(identifier: zone),
            authored.secondsFromGMT(for: start) != calendar.timeZone.secondsFromGMT(for: start)
        else { return nil }
        var there = calendar
        there.timeZone = authored
        return "\(time(start, calendar: there)) to \(time(end, calendar: there)) in \(city(zoneIdentifier: zone))"
    }

    /// `5 guests · No reply yet`, `5 guests · Going`, `5 guests · Maybe`; nil without guests.
    public static func guests(_ event: Event) -> String? {
        guard event.hasOtherAttendees else { return nil }
        let count = "\(event.attendeeCount) guests"
        switch event.response {
        case .needsAction: return "\(count) · No reply yet"
        case .accepted: return "\(count) · Going"
        case .tentative: return "\(count) · Maybe"
        case .declined, .none: return count
        }
    }

    /// `Earlier: Standup, Design review`, or `Earlier: Standup, Design review and 2 more`.
    public static func earlier(_ events: [Event]) -> String {
        let names = events.prefix(2).map(\.title).joined(separator: ", ")
        let rest = events.count - 2
        return rest > 0 ? "Earlier: \(names) and \(more(rest))" : "Earlier: \(names)"
    }

    /// The location's first line when it is a place rather than a link; nil otherwise.
    public static func place(_ event: Event) -> String? {
        guard let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            !location.isEmpty, !looksLikeLink(location)
        else { return nil }
        return location.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    // MARK: Private

    private static let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    private static func minutesText(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }

    /// One token that is a URL or a bare host with a path: `https://zoom.us/j/1`,
    /// `meet.google.com/abc-defg`. Anything with a space (`Café Nord`, `Room 4.12`) is a
    /// place, so a place is never mistaken for a link because it contains a dot.
    private static func looksLikeLink(_ location: String) -> Bool {
        guard !location.contains(where: \.isWhitespace) else { return false }
        let lower = location.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return true }
        return lower.range(
            of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(:\d+)?(/.*)?$"#,
            options: .regularExpression) != nil
    }

    private static func style(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(
            locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    }

    private static func uses24Hour(_ calendar: Calendar) -> Bool {
        switch (calendar.locale ?? .current).hourCycle {
        case .zeroToTwentyThree, .oneToTwentyFour: true
        default: false
        }
    }
}
