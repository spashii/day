import Foundation

/// How one calendar is kept current: Google's sync token, the window of the full read that
/// issued it, and the days its cached events are complete for. Kept in the account's
/// `sync-<sub>.json`, written after the events it describes.
public struct CalendarSync: Codable, Hashable, Sendable {
    public var calendar: CalendarID
    /// `nextSyncToken` from the last read. Nil when Google sent none: the calendar is then
    /// read in full again once `tokenlessRetry` has passed, never on every refresh.
    public var token: String?
    /// The `timeMin` and `timeMax` of the full read that issued the token. Google does not
    /// say whether a token remembers its window, so changes are relied on only for days
    /// inside it, and a full read starts over once the days Day keeps current leave it.
    public var tokenFrom: Date
    public var tokenTo: Date
    /// When that full read ran. About a day later (`fullSyncInterval(for:)`) the calendar is
    /// read in full again.
    public var fullSyncAt: Date
    /// When Google last answered for this calendar, in full or with changes.
    public var syncedAt: Date
    /// The days its events are complete for: the full read's days, plus any stretch the
    /// Month fetched next to them. Counted in the device's zone when fetched.
    public var from: CivilDate
    public var through: CivilDate
    /// The days of the full read alone, which `from` and `through` return to when the
    /// stretches beyond them expire. Nil in a file written before stretches expired.
    public var readFrom: CivilDate?
    public var readThrough: CivilDate?
    /// When the oldest stretch still counted in `from` and `through` was fetched. Nil while
    /// the covered days are only the full read's.
    public var stretchedAt: Date?

    public init(
        calendar: CalendarID, token: String?, tokenFrom: Date, tokenTo: Date, fullSyncAt: Date,
        syncedAt: Date, days: ClosedRange<CivilDate>
    ) {
        self.calendar = calendar
        self.token = token
        self.tokenFrom = tokenFrom
        self.tokenTo = tokenTo
        self.fullSyncAt = fullSyncAt
        self.syncedAt = syncedAt
        from = days.lowerBound
        through = days.upperBound
        readFrom = days.lowerBound
        readThrough = days.upperBound
    }

    public var days: ClosedRange<CivilDate> {
        from...max(from, through)
    }

    /// The longest a calendar goes between full reads. It costs about one refresh of round
    /// one per calendar per day, and it repairs what incremental reads cannot carry: an
    /// event moved out of the token's window, a calendar's renamed list entry, and any drift
    /// nobody has found yet.
    public static let fullSyncPeriod: TimeInterval = 24 * 3600

    /// How far each calendar's full read is moved earlier than the day, at most. Every
    /// calendar's first full read happens in the same refresh, so without a spread they
    /// would all come due together, every day, in one refresh that has to read them all: the
    /// slow one that a background task cannot always finish.
    public static let fullSyncSpread: TimeInterval = 6 * 3600

    /// How long a calendar that Google gave no token is left alone after a full read. It
    /// cannot be read incrementally, so every look is a full window, and one an hour keeps
    /// that to a few kilobytes per refresh on average rather than a window every 3 minutes.
    public static let tokenlessRetry: TimeInterval = 3600

    /// How long a stretch the Month fetched beyond the full read is trusted. If Google does
    /// not report a token's changes outside the window it was issued for, nothing else
    /// keeps such a stretch current, so it is read again when the Month draws it after this.
    public static let stretchLife: TimeInterval = 3600

    /// `fullSyncPeriod`, less a fixed share of `fullSyncSpread` that depends only on `key`
    /// (a calendar or an account), so the same calendar keeps its slot across launches.
    public static func fullSyncInterval(for key: String) -> TimeInterval {
        // FNV-1a: `hashValue` differs on every launch, and the slot must not.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        let share = Double(hash % 10_000) / 10_000
        return fullSyncPeriod - share * fullSyncSpread
    }

    /// This calendar's own full read interval.
    var ownFullSyncInterval: TimeInterval {
        CalendarSync.fullSyncInterval(for: "\(calendar.account.sub)/\(calendar.googleID)")
    }

    /// What the next refresh should do for this calendar. A full read is due when the token's
    /// window no longer holds `needed`, the covered days no longer hold `neededDays`, or the
    /// last full read is as old as this calendar's interval. A full read stamped in the
    /// future means the clock moved back since, and counts as due rather than trusted for
    /// longer. With no token, nothing is read until `tokenlessRetry` has passed.
    func plan(needed: DateInterval, neededDays: ClosedRange<CivilDate>, now: Date) -> CalendarPlan {
        let age = now.timeIntervalSince(fullSyncAt)
        guard tokenFrom <= needed.start, tokenTo >= needed.end,
            from <= neededDays.lowerBound, through >= neededDays.upperBound,
            (0..<ownFullSyncInterval).contains(age)
        else { return .full }
        guard let token else { return age < CalendarSync.tokenlessRetry ? .wait : .full }
        return .changes(since: token)
    }

    /// Back to the full read's days once the oldest stretch is `stretchLife` old. The events
    /// stay on screen; the Month asks for the stretch again when it draws it.
    mutating func expireStretch(at now: Date) {
        guard let stretchedAt, let readFrom, let readThrough,
            !(0..<CalendarSync.stretchLife).contains(now.timeIntervalSince(stretchedAt))
        else { return }
        from = readFrom
        through = readThrough
        self.stretchedAt = nil
    }
}

/// What a refresh does for one calendar.
enum CalendarPlan: Hashable, Sendable {
    /// Read what changed since this token.
    case changes(since: String)
    /// Read the whole window, which issues a new token.
    case full
    /// Leave it for now: no token to read changes from, and its last full read is recent.
    case wait
}

/// What one item of an incremental answer does to the cache.
public enum EventChange: Hashable, Sendable {
    /// Store this event, replacing any copy with the same ID.
    case upsert(Event)
    /// Remove the event with this Google ID. If it names a whole series, its instances
    /// (`<series>_<start>`) go too: Google's generated IDs never hold `_`, so the prefix can
    /// only match instances of that series. With `singleEvents` Google documents sending
    /// single instances of deleted events and not the series itself, so this is a second
    /// line behind the re-read of an edited series (`SyncEngine.editsASeries`).
    case remove(googleID: String)
}

// MARK: - Changing one account's events

extension AccountCache {
    /// A full read of one calendar over `state.days`. Its events overlapping those days are
    /// replaced and its sync state starts over with the new token. With `wipe` (Google
    /// invalidated the token) every event of the calendar goes first, as Google's guide asks.
    /// Without it, events beyond the read (stretches the Month fetched by window) stay on
    /// screen but no longer count as covered, so the Month fetches them again when it draws
    /// them; the daily full read then never blanks a month someone is looking at.
    mutating func replace(
        _ id: CalendarID, with fetched: [Event], state: CalendarSync, wipe: Bool,
        calendar: Calendar
    ) {
        let range = SyncEngine.interval(state.days, calendar: calendar)
        let ids = Set(fetched.map(\.id))
        events.removeAll { event in
            event.id.calendar == id
                && (wipe || ids.contains(event.id)
                    || SyncEngine.overlaps(event, range, calendar: calendar))
        }
        events += fetched
        sync.removeAll { $0.calendar == id }
        sync.append(state)
    }

    /// Changes read since `token`, then `next` as the calendar's token. Returns false and
    /// changes nothing when the file no longer holds `token` for the calendar, because then
    /// the changes were read against events this file no longer has.
    @discardableResult
    mutating func apply(
        _ changes: [EventChange], to id: CalendarID, since token: String, next: String,
        at now: Date, calendar: Calendar
    ) -> Bool {
        guard let i = sync.firstIndex(where: { $0.calendar == id }), sync[i].token == token
        else { return false }
        applyChanges(changes, to: id, within: sync[i].days, calendar: calendar)
        sync[i].token = next
        sync[i].syncedAt = now
        return true
    }

    /// Changes onto the events alone. An upserted event outside `days` is dropped, with any
    /// old copy, so the result is what a full read of those days would give: Google may
    /// return changes anywhere in time, and an event moved out of the covered days must not
    /// linger at its old time.
    mutating func applyChanges(
        _ changes: [EventChange], to id: CalendarID, within days: ClosedRange<CivilDate>,
        calendar: Calendar
    ) {
        guard !changes.isEmpty else { return }
        let covered = SyncEngine.interval(days, calendar: calendar)
        // The last change to an ID wins, as if they had been applied one by one.
        var removed: Set<String> = []
        var upserted: [String: Event] = [:]
        var order: [String] = []
        var ordered: Set<String> = []
        for change in changes {
            switch change {
            case .remove(let googleID):
                removed.insert(googleID)
                upserted[googleID] = nil
            case .upsert(let event):
                let googleID = event.id.googleID
                if ordered.insert(googleID).inserted { order.append(googleID) }
                removed.remove(googleID)
                upserted[googleID] = event
            }
        }
        let series = removed.map { $0 + "_" }
        events.removeAll { event in
            guard event.id.calendar == id else { return false }
            let googleID = event.id.googleID
            if removed.contains(googleID) || upserted[googleID] != nil { return true }
            return event.isRecurring && series.contains { googleID.hasPrefix($0) }
        }
        for googleID in order {
            guard let event = upserted[googleID],
                SyncEngine.overlaps(event, covered, calendar: calendar)
            else { continue }
            events.append(event)
        }
    }

    /// A stretch read by window with no token: the Month scrolling past the covered days, or
    /// the widget's own days. The calendar's events overlapping `days` are replaced. When the
    /// stretch touches the covered days they grow to include it, and the oldest such stretch
    /// is stamped `now` so it expires after `CalendarSync.stretchLife`; a stretch that does
    /// not touch them (a full read moved them meanwhile) still replaces its events but adds no
    /// coverage, so it is fetched again when drawn.
    mutating func merge(
        _ fetched: [Event], of id: CalendarID, over days: ClosedRange<CivilDate>, at now: Date,
        calendar: Calendar
    ) {
        let range = SyncEngine.interval(days, calendar: calendar)
        let ids = Set(fetched.map(\.id))
        events.removeAll { event in
            event.id.calendar == id
                && (ids.contains(event.id) || SyncEngine.overlaps(event, range, calendar: calendar))
        }
        events += fetched
        if let i = sync.firstIndex(where: { $0.calendar == id }),
            let joined = SyncEngine.union(sync[i].days, days)
        {
            let grew = joined != sync[i].days
            sync[i].from = joined.lowerBound
            sync[i].through = joined.upperBound
            if grew, sync[i].readFrom != nil, sync[i].stretchedAt == nil {
                sync[i].stretchedAt = now
            }
        }
    }

    /// Stretches the Month fetched are good for `CalendarSync.stretchLife`. Past that the
    /// covered days fall back to the full read's, so the Month fetches what it draws there
    /// again; nothing leaves the screen meanwhile.
    mutating func expireStretches(at now: Date) {
        for i in sync.indices {
            sync[i].expireStretch(at: now)
        }
    }

    /// Keeps only calendars still on the account's list. A calendar removed from the list,
    /// unsubscribed, deleted or folded into another account's copy, takes its events and its
    /// token with it.
    mutating func retain(listed: Set<CalendarID>) {
        events.removeAll { !listed.contains($0.id.calendar) }
        sync.removeAll { !listed.contains($0.calendar) }
    }

    /// A calendar Google no longer lets this account read: its events and token go, so if
    /// access returns it starts with a full read.
    mutating func forget(_ id: CalendarID) {
        events.removeAll { $0.id.calendar == id }
        sync.removeAll { $0.calendar == id }
    }

    /// By start, then by ID, so rewriting unchanged data writes the same bytes.
    mutating func sortEvents(calendar: Calendar) {
        events.sort { lhs, rhs in
            let l = lhs.time.start(in: calendar)
            let r = rhs.time.start(in: calendar)
            return l != r ? l < r : lhs.id < rhs.id
        }
    }
}
