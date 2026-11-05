import Foundation

/// The words of a reminder, from the event and the device's own time formatting.
public enum ReminderText {
    /// The action on a call's notifications.
    public static let join = "Join"
    /// The body of the notification at the start of a call.
    public static let startingNow = "Starting now"
    /// The body of an all-day reminder fired on the day itself.
    public static let today = "Today"
    /// The body of an all-day reminder fired the day before.
    public static let tomorrow = "Tomorrow"

    /// `In 10 min, 9:30 to 10:00`, with the place on a second line when there is one.
    ///
    /// A reminder at the start itself (0 minutes) opens with `Now`. A zero-length event shows
    /// its start alone. The time uses the device's clock style, the span its unit
    /// (`In 1 h 30 min`), so the line reads like the rest of Day.
    public static func lead(
        minutes: Int, event: Event, start: Date, end: Date, calendar: Calendar
    ) -> String {
        let opening = minutes == 0
            ? "Now" : "In \(Formatting.duration(TimeInterval(minutes) * 60))"
        let first = Formatting.time(start, calendar: calendar)
        let times = end > start ? "\(first) to \(Formatting.time(end, calendar: calendar))" : first
        var body = "\(opening), \(times)"
        if let place = Formatting.place(event) {
            body += "\n\(place)"
        }
        return body
    }

    /// `Today` or `Tomorrow`; a reminder further ahead names the day (`Friday 6 November`).
    public static func allDay(daysAhead: Int, day: CivilDate, calendar: Calendar) -> String {
        switch daysAhead {
        case 0: today
        case 1: tomorrow
        default: Formatting.dayHeader(day, calendar: calendar)
        }
    }
}
