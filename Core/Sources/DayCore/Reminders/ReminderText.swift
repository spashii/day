import Foundation

/// The words of a reminder, from the event and the device's own time formatting.
///
/// A body opens with the first of these that fits, counted from when the notification fires:
/// `Starting now` at the start, `In 10 min` under an hour ahead, then the day: `Today`,
/// `Tomorrow`, the weekday up to six days ahead (`Friday`), the weekday and date beyond
/// (`Friday 13 November`). Past the first hour the day word says it, so there is no span in
/// hours (`In 24 h`).
public enum ReminderText {
    /// The action on a call's notifications.
    public static let join = "Join"
    /// The opening of a body at the start itself, a call's start notification included.
    public static let startingNow = "Starting now"
    /// The opening of a body on the day itself.
    public static let today = "Today"
    /// The opening of a body the day before.
    public static let tomorrow = "Tomorrow"
    /// Up to this many days ahead the weekday alone is clear; further, it needs the date.
    static let weekdayOnlyDays = 6

    /// `In 10 min, 9:30 to 10:00`, with the place on a second line when there is one.
    ///
    /// `minutes` is how long before `start` the notification fires. A zero-length event shows
    /// its start alone. The time uses the device's clock style, so the line reads like the
    /// rest of Day.
    public static func lead(
        minutes: Int, event: Event, start: Date, end: Date, calendar: Calendar
    ) -> String {
        let opening: String
        switch minutes {
        case ...0:
            opening = startingNow
        case 1..<60:
            opening = "In \(Formatting.duration(TimeInterval(minutes) * 60))"
        default:
            let fire = start.addingTimeInterval(-TimeInterval(minutes) * 60)
            let eventDay = CivilDate(start, in: calendar)
            let daysAhead = CivilDate(fire, in: calendar).distance(to: eventDay)
            opening = day(daysAhead: daysAhead, day: eventDay, calendar: calendar)
        }
        let first = Formatting.time(start, calendar: calendar)
        let times = end > start ? "\(first) to \(Formatting.time(end, calendar: calendar))" : first
        var body = "\(opening), \(times)"
        if let place = Formatting.place(event) {
            body += "\n\(place)"
        }
        return body
    }

    /// An all-day reminder: the day word alone, with no times.
    public static func allDay(daysAhead: Int, day: CivilDate, calendar: Calendar) -> String {
        Self.day(daysAhead: daysAhead, day: day, calendar: calendar)
    }

    /// `Today`, `Tomorrow`, `Friday`, then `Friday 13 November`.
    static func day(daysAhead: Int, day: CivilDate, calendar: Calendar) -> String {
        switch daysAhead {
        case ...0: today
        case 1: tomorrow
        case 2...weekdayOnlyDays: Formatting.weekday(day, calendar: calendar)
        default: Formatting.dayHeader(day, calendar: calendar)
        }
    }
}
