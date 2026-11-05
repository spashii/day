import Foundation

/// Which local notifications this device should have pending, worked out from the cache
/// alone: no server, no network, and the same answer from the same cache on every launch.
///
/// - Source: each event's own Google popup reminders. `useDefault` follows the calendar's
///   `defaultReminders`; otherwise the event's `overrides` apply.
/// - Left out: cancelled and declined events, and calendars the person has hidden.
/// - Calls: an event with a join link that has reminders gets an extra notification at its
///   start, at the time-sensitive level, and every notification of such an event carries the
///   link for a `Join` action. The reminder at 0 minutes is not repeated beside it.
/// - A rolling window: only notifications firing within `horizon` of now, the earliest
///   `limit` of them. The system keeps at most 64 pending per app, and the window slides
///   forward at every refresh.
public enum ReminderSchedule {
    /// Prefix of every identifier Day gives a notification, which is how the app tells its
    /// own pending requests from any other.
    public static let identifierPrefix = "day.reminder."
    /// How far ahead notifications are scheduled.
    public static let defaultHorizon: TimeInterval = 48 * 3600
    /// The most notifications pending at once. iOS refuses more than 64.
    public static let defaultLimit = 60
    /// Google's longest reminder is four weeks. Events up to that far past the window are
    /// still looked at, because an all-day event can remind that long before it.
    static let longestLeadDays = 28

    /// The notifications to have pending at `now`, earliest first.
    public static func plan(
        _ data: CalendarData, now: Date, calendar: Calendar,
        horizon: TimeInterval = defaultHorizon, limit: Int = defaultLimit
    ) -> [PlannedReminder] {
        guard limit > 0 else { return [] }
        let until = now.addingTimeInterval(horizon)
        let days =
            CivilDate(now, in: calendar)...CivilDate(until, in: calendar).adding(days: longestLeadDays)
        let emails = Dictionary(
            data.accounts.map { ($0.id, $0.email) }, uniquingKeysWith: { first, _ in first })

        var planned: [PlannedReminder] = []
        for event in data.events(in: days, calendar: calendar) {
            planned += reminders(
                for: event, defaults: data.calendarInfo(event.id.calendar)?.defaultReminders ?? [],
                email: emails[event.account], now: now, until: until, calendar: calendar)
        }
        planned.sort { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }
        return Array(planned.prefix(limit))
    }

    /// What has to change for the pending requests to match `planned`. Only identifiers with
    /// Day's prefix are touched. A request is added when it is missing or its signature
    /// differs, and removed when it is no longer in the plan; one that matches is left alone.
    public static func changes(planned: [PlannedReminder], pending: [PendingReminder])
        -> ReminderChanges
    {
        var ours: [String: PendingReminder] = [:]
        for request in pending where request.identifier.hasPrefix(identifierPrefix) {
            ours[request.identifier] = request
        }
        let wanted = Set(planned.map(\.identifier))
        let add = planned.filter { reminder in
            guard let existing = ours[reminder.identifier] else { return true }
            return existing.signature != reminder.signature
        }
        let remove = ours.keys.filter { !wanted.contains($0) }.sorted()
        return ReminderChanges(add: add, remove: remove)
    }

    // MARK: One event

    static func reminders(
        for event: Event, defaults: [Int], email: String?, now: Date, until: Date,
        calendar: Calendar
    ) -> [PlannedReminder] {
        guard event.status != .cancelled, event.response != .declined,
            let own = event.reminders
        else { return [] }
        let minutes = own.minutes(calendarDefaults: defaults, isAllDay: event.isAllDay)
        guard !minutes.isEmpty else { return [] }

        func make(
            _ kind: ReminderKind, at fire: Date, body: String, level: ReminderLevel = .active
        ) -> PlannedReminder {
            reminder(
                event, kind, at: fire, body: body, level: level, email: email, calendar: calendar)
        }

        switch event.time {
        case .timed(let start, let end, _):
            guard start > now else { return [] }
            let isCall = event.joinURL != nil
            var found: [PlannedReminder] = []
            for lead in minutes where lead >= 0 {
                // The start notification already speaks at that moment.
                if lead == 0, isCall { continue }
                let fire = start.addingTimeInterval(-TimeInterval(lead) * 60)
                guard fire > now, fire <= until else { continue }
                found.append(
                    make(
                        .lead(minutes: lead), at: fire,
                        body: ReminderText.lead(
                            minutes: lead, event: event, start: start, end: end,
                            calendar: calendar)))
            }
            if isCall, start <= until {
                found.append(
                    make(
                        .start, at: start, body: ReminderText.startingNow,
                        level: .timeSensitive))
            }
            return found

        case .allDay(let first, _):
            var found: [PlannedReminder] = []
            for lead in minutes {
                guard let (fire, daysAhead) = allDayFire(first: first, minutes: lead, calendar: calendar),
                    fire > now, fire <= until
                else { continue }
                found.append(
                    make(
                        .lead(minutes: lead), at: fire,
                        body: ReminderText.allDay(
                            daysAhead: daysAhead, day: first, calendar: calendar)))
            }
            return found
        }
    }

    /// When an all-day event's reminder fires, and how many days before the event that is.
    ///
    /// Google counts the minutes back from midnight at the start of the first day, which is
    /// how "1 day before at 9:00" becomes 900. They are worked out as days and a time of day
    /// and set on the wall clock, so the reminder keeps its hour across a change to or from
    /// daylight saving instead of drifting by the hour that day gains or loses. A reminder
    /// that would fall after the event's day began returns nil unless it is on that day.
    static func allDayFire(first: CivilDate, minutes: Int, calendar: Calendar)
        -> (fire: Date, daysAhead: Int)?
    {
        let daysAhead = Int((Double(minutes) / 1440).rounded(.up))
        guard daysAhead >= 0 else { return nil }
        let minuteOfDay = daysAhead * 1440 - minutes
        let day = first.adding(days: -daysAhead)
        guard
            let fire = calendar.date(
                from: DateComponents(
                    year: day.year, month: day.month, day: day.day,
                    hour: minuteOfDay / 60, minute: minuteOfDay % 60))
        else { return nil }
        return (fire, daysAhead)
    }

    private static func reminder(
        _ event: Event, _ kind: ReminderKind, at fire: Date, body: String, level: ReminderLevel,
        email: String?, calendar: Calendar
    ) -> PlannedReminder {
        let thread = Fingerprint.of([
            event.id.calendar.account.sub, event.id.calendar.googleID, event.id.googleID,
        ])
        let suffix: String
        switch kind {
        case .lead(let minutes): suffix = "m\(minutes)"
        case .start: suffix = "start"
        }
        let link = DayLink.event(event.id).url
        let signature = Fingerprint.of([
            String(Int(fire.timeIntervalSince1970.rounded(.down))), event.title, body,
            level.rawValue, event.joinURL?.absoluteString ?? "", email ?? "", link.absoluteString,
            calendar.timeZone.identifier,
        ])
        return PlannedReminder(
            identifier: identifierPrefix + thread + "." + suffix, thread: thread,
            event: event.id, kind: kind, fireDate: fire, title: event.title, body: body,
            level: level, joinURL: event.joinURL, accountEmail: email, link: link,
            signature: signature)
    }
}

/// A short stable name for a list of strings. Not `hashValue`, which differs on every
/// launch: a pending request's identifier has to be the same one the next launch computes.
enum Fingerprint {
    /// FNV-1a over the parts, 16 hex digits.
    static func of(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for part in parts {
            for byte in part.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
            // A separator no part can contain, so ["ab", "c"] and ["a", "bc"] differ.
            hash = (hash ^ 0x1F) &* 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
