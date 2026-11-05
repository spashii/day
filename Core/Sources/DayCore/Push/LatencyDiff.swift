import CryptoKit
import Foundation

// What counts as one change, for latency: an event that appeared, went away, or changed what
// a surface shows of it (title, time, place, status). The surfaces know events only after
// merging across accounts, so a change is named by the merge key, `iCalUID` and the
// instance's original start, which every copy of a meeting shares. Both names are digests,
// so the files that link a change across processes never hold a title or an ID.

/// Where a change is timed: Google's own `updated` time, the app's background push, the end
/// of the sync that applied it, and each surface that drew it.
public enum LatencyStage: String, Codable, CodingKeyRepresentable, CaseIterable, Hashable, Sendable {
    case updated
    case push
    case synced
    case macApp = "mac-app"
    case macWidget = "mac-widget"
    case iphoneWidget = "iphone-widget"
}

enum LatencyDigest {
    /// The same event on every surface and in every account.
    static func key(_ event: Event) -> String {
        let original = event.originalStart.map { String($0.timeIntervalSince1970) } ?? "-"
        return digest("\(event.iCalUID)|\(original)")
    }

    /// What a surface shows of it. Not the response or the colour, which differ between the
    /// copies that merging folds into one.
    static func content(_ event: Event) -> String {
        let time: String =
            switch event.time {
            case .allDay(let start, let end): "d \(start.isoString) \(end.isoString)"
            case .timed(let start, let end, _):
                "t \(start.timeIntervalSince1970) \(end.timeIntervalSince1970)"
            }
        return digest("\(event.title)|\(time)|\(event.location ?? "")|\(event.status.rawValue)")
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// One change a sync applied, before Google has said when it was made.
struct LatencyCandidate: Hashable, Sendable {
    var event: EventID
    /// The calendar's sync token before the sync, which reads the same change again with
    /// its `updated` time.
    var token: String
    var key: String
    /// Nil when the event went away.
    var after: String?
}

enum LatencyDiff {
    /// A daily full read can move hundreds of events in or out of the window at once; none of
    /// those is a change anyone made, and the probe would drop them anyway.
    static let limit = 300

    /// The changes between two states of the cache, per calendar that had a sync token
    /// before. Calendars read in full for the first time have nothing to compare with.
    static func candidates(from before: CalendarData, to after: CalendarData) -> [LatencyCandidate] {
        var found: [LatencyCandidate] = []
        let accounts = Set(before.accounts.map(\.id)).intersection(after.accounts.map(\.id))
        for account in accounts.sorted() {
            let old = before.eventsByAccount[account] ?? []
            let new = after.eventsByAccount[account] ?? []
            if old == new { continue }
            var tokens: [CalendarID: String] = [:]
            for state in before.syncByAccount[account] ?? [] {
                if let token = state.token { tokens[state.calendar] = token }
            }
            let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in Set(oldByID.keys).union(newByID.keys).sorted() {
                guard let token = tokens[id.calendar] else { continue }
                let was = oldByID[id]
                let now = newByID[id]
                let wasContent = was.map(LatencyDigest.content)
                let nowContent = now.map(LatencyDigest.content)
                guard wasContent != nowContent, let event = now ?? was else { continue }
                found.append(
                    LatencyCandidate(
                        event: id, token: token, key: LatencyDigest.key(event), after: nowContent))
                if found.count >= limit { return found }
            }
        }
        return found
    }
}

/// What one surface drew, kept until its next draw so the two can be compared.
struct LatencyRender: Codable, Hashable, Sendable {
    struct Shown: Codable, Hashable, Sendable {
        var content: String
        var start: Date
        var end: Date
    }

    var at: Date
    var from: CivilDate
    var through: CivilDate
    var events: [String: Shown]

    /// The events of `snapshot` that fall in the days the surface shows at `at`: the Lock
    /// Screen's days for the iPhone widget, today for the Mac's.
    init(_ stage: LatencyStage, snapshot: WidgetSnapshot, at: Date, calendar: Calendar) {
        let today = CivilDate(at, in: calendar)
        let days = stage == .macWidget ? today...today : WidgetSnapshot.days(from: today)
        self.at = at
        from = days.lowerBound
        through = days.upperBound
        let range = SyncEngine.interval(days, calendar: calendar)
        var events: [String: Shown] = [:]
        for event in snapshot.events where SyncEngine.overlaps(event, range, calendar: calendar) {
            let span = event.time.interval(in: calendar)
            events[LatencyDigest.key(event)] = Shown(
                content: LatencyDigest.content(event), start: span.start, end: span.end)
        }
        self.events = events
    }

    /// What changed between two draws, for days both covered: a day that only one draw
    /// covered is the window moving, not a change.
    static func appearances(
        from previous: LatencyRender, to current: LatencyRender, calendar: Calendar
    ) -> [(key: String, after: String?)] {
        let lower = max(previous.from, current.from)
        let upper = min(previous.through, current.through)
        guard lower <= upper else { return [] }
        let both = SyncEngine.interval(lower...upper, calendar: calendar)
        func inBoth(_ shown: Shown) -> Bool {
            shown.start < both.end && (shown.end > both.start || shown.start >= both.start)
        }
        var found: [(key: String, after: String?)] = []
        for (key, shown) in current.events.sorted(by: { $0.key < $1.key })
        where inBoth(shown) && previous.events[key]?.content != shown.content {
            found.append((key, shown.content))
        }
        for (key, shown) in previous.events.sorted(by: { $0.key < $1.key })
        where current.events[key] == nil && inBoth(shown) {
            found.append((key, nil))
        }
        return found
    }
}
