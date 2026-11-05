import DayCore
import Foundation
import WidgetKit

/// One desktop widget timeline entry: the content of all three families at `date`.
struct TodayEntry: TimelineEntry, Sendable {
    var date: Date
    var content: TodayContent
}

/// Reads the snapshot the Mac app copies into the App Group and builds the entries from it.
///
/// The Mac widget never reads Google: the app keeps running in the menu bar, refreshes every
/// few minutes and asks for a reload whenever the snapshot changes what the widget shows. So
/// the timeline only has to stay true on its own between those reloads: an entry at every
/// event's start and end, at each local midnight, and when the data turns 2 and 24 hours old,
/// over the next 24 hours. The system asks again after the last one.
struct TodayProvider: TimelineProvider {
    /// Synchronous: touches neither disk nor network. The system draws it redacted while the
    /// gallery loads, so the events only need to be the shape of real ones.
    func placeholder(in context: Context) -> TodayEntry {
        let now = Date.now
        let calendar = Calendar.current
        return TodayEntry(
            date: now,
            content: TodayContent.at(
                now, events: TodaySource.placeholderEvents(around: now, calendar: calendar),
                fetchedAt: now, signedOutAccounts: 0, calendar: calendar))
    }

    /// The gallery gets the invented week through the real rules; the desktop gets the first
    /// entry of the real timeline.
    func getSnapshot(in context: Context, completion: @escaping @Sendable (TodayEntry) -> Void) {
        let now = Date.now
        if context.isPreview, let demo = NextDemo.loadAlways(now: now) {
            completion(Self.entries(.found(demo.snapshot), now: now, calendar: demo.calendar)[0])
        } else {
            completion(Self.timeline(now: now).entries[0])
        }
    }

    func getTimeline(
        in context: Context, completion: @escaping @Sendable (Timeline<TodayEntry>) -> Void
    ) {
        completion(Self.timeline(now: .now))
    }

    /// Asks again after the last entry. A timeline of one entry (a state line) has nothing
    /// ahead of it, and `.atEnd` would then ask again at once; it waits an hour instead,
    /// since the app asks for a reload as soon as it writes a snapshot.
    static func timeline(now: Date) -> Timeline<TodayEntry> {
        let entries = entries(TodaySource.read(), now: now, calendar: .current)
        let last = entries.last?.date ?? now
        return Timeline(
            entries: entries,
            policy: last > now ? .atEnd : .after(now.addingTimeInterval(60 * 60)))
    }

    /// Every entry for a reload at `now`, in date order, never empty.
    static func entries(_ source: TodaySource, now: Date, calendar: Calendar) -> [TodayEntry] {
        let today = DayLink.day(CivilDate(now, in: calendar)).url
        switch source {
        case .missing:
            // No client yet: the invented week, as the app itself runs on it.
            if let demo = NextDemo.load(now: now) {
                return entries(.found(demo.snapshot), now: now, calendar: demo.calendar)
            }
            return [TodayEntry(date: now, content: .message(TodayContent.addAccount, url: today))]
        case .unreadable:
            return [TodayEntry(date: now, content: .message(TodayContent.openToUpdate, url: today))]
        case .found(let snapshot):
            guard snapshot.accountCount > 0 else {
                return [TodayEntry(date: now, content: .message(TodayContent.addAccount, url: today))]
            }
            return dates(
                events: snapshot.events, now: now, fetchedAt: snapshot.fetchedAt,
                calendar: calendar
            ).map { date in
                TodayEntry(
                    date: date,
                    content: TodayContent.at(
                        date, events: snapshot.events, fetchedAt: snapshot.fetchedAt,
                        signedOutAccounts: snapshot.signedOutAccounts, calendar: calendar))
            }
        }
    }

    /// `now`, then every moment in the next 24 hours where some family changes: each timed
    /// event's start and end (a row moves to Earlier, the next event moves on, a gap begins),
    /// each local midnight (a new day), and the moments the data turns 2 and 24 hours old.
    static func dates(events: [Event], now: Date, fetchedAt: Date, calendar: Calendar) -> [Date] {
        let horizon = now.addingTimeInterval(24 * 60 * 60)
        var changes: Set<Date> = []
        func add(_ date: Date) {
            if date > now, date <= horizon { changes.insert(date) }
        }
        for event in events {
            if case .timed(let start, let end, _) = event.time {
                add(start)
                add(end)
            }
        }
        let today = CivilDate(now, in: calendar)
        for days in 1...2 {
            add(today.adding(days: days).date(in: calendar))
        }
        add(fetchedAt.addingTimeInterval(TodayContent.staleAfter + 1))
        add(fetchedAt.addingTimeInterval(TodayContent.expiredAfter + 1))
        return [now] + changes.sorted()
    }
}

/// What reading the App Group container found.
enum TodaySource: Sendable {
    /// No file: the app has not written one, which means no account yet, or a build that may
    /// not use the group.
    case missing
    /// A file the widget cannot decode.
    case unreadable
    case found(WidgetSnapshot)

    static func read() -> TodaySource {
        guard let cache = MacWidgetGroup.cache() else { return .missing }
        if let snapshot = WidgetSnapshot.read(from: cache) { return .found(snapshot) }
        let exists = FileManager.default.fileExists(
            atPath: cache.fileURL(WidgetSnapshot.fileName).path(percentEncoded: false))
        return exists ? .unreadable : .missing
    }

    /// Invented events in code, for the placeholder: the shape of an afternoon.
    static func placeholderEvents(around now: Date, calendar: Calendar) -> [Event] {
        let day = CivilDate(now, in: calendar).date(in: calendar)
        let id = CalendarID(account: AccountID("placeholder"), googleID: "placeholder")
        func event(_ n: Int, _ title: String, hour: Int, minutes: Int, recurring: Bool) -> Event {
            let start = calendar.date(byAdding: .hour, value: hour, to: day) ?? day
            return Event(
                id: EventID(calendar: id, googleID: "\(n)"), iCalUID: "\(n)", title: title,
                time: .timed(
                    start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                    authoredZone: nil),
                isRecurring: recurring, colorKey: .blue)
        }
        return [
            event(1, "Investor call", hour: 14, minutes: 60, recurring: false),
            event(2, "Weekly planning", hour: 16, minutes: 60, recurring: true),
            event(3, "Standup", hour: 33, minutes: 15, recurring: true),
        ]
    }
}
