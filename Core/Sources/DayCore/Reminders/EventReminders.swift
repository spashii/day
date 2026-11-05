import Foundation

/// The reminders Google keeps on one event, reduced to what Day schedules: popup reminders
/// only, because an email reminder is Google's to send and not a notification on a device.
///
/// An event whose reminders come to nothing (none set, or only email ones) keeps no value at
/// all, so the cache does not carry an empty record for every event.
public struct EventReminders: Codable, Hashable, Sendable {
    /// `reminders.useDefault`: the reminders are the calendar's own `defaultReminders`, and
    /// `overrides` is not read.
    public var useDefault: Bool
    /// Minutes before the start of each popup reminder in `reminders.overrides`, ascending
    /// and without repeats.
    public var overrides: [Int]

    public init(useDefault: Bool = false, overrides: [Int] = []) {
        self.useDefault = useDefault
        self.overrides = Array(Set(overrides)).sorted()
    }

    // Optional keys default, so a cache written by another version still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            useDefault: try c.decodeIfPresent(Bool.self, forKey: .useDefault) ?? false,
            overrides: try c.decodeIfPresent([Int].self, forKey: .overrides) ?? [])
    }

    /// The minutes this event reminds at, given the popup minutes of its calendar's defaults.
    ///
    /// A timed event with `useDefault` takes `calendarDefaults`. An all-day event with
    /// `useDefault` takes nothing: Google keeps the reminders for all-day events apart from
    /// the calendar's defaults and `calendarList` does not return them, so applying the
    /// timed defaults would mean minutes before midnight, a reminder at 23:50 the night before.
    /// Its own overrides still count.
    public func minutes(calendarDefaults: [Int], isAllDay: Bool) -> [Int] {
        if useDefault {
            return isAllDay ? [] : Array(Set(calendarDefaults)).sorted()
        }
        return overrides
    }
}
