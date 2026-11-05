import Foundation

/// Everything Day has cached, as one value: what the real store draws from at launch and
/// after every fetch, with no network in sight. `SyncEngine.load()` reads it from disk;
/// every fetch returns a new one.
public struct CalendarData: Hashable, Sendable {
    /// In the order added.
    public var accounts: [Account]
    /// Each account's calendar list as Google sent it, before shared calendars are folded.
    public var calendarsByAccount: [AccountID: [CalendarInfo]]
    /// Each account's fetched events, not merged across accounts.
    public var eventsByAccount: [AccountID: [Event]]
    /// When every shown calendar of each account last answered in the same refresh.
    public var fetchedAtByAccount: [AccountID: Date]
    /// How each fetched calendar is kept current, per account: its sync token and the days
    /// its events are complete for.
    public var syncByAccount: [AccountID: [CalendarSync]]
    public var visibility: CalendarVisibility

    public init(
        accounts: [Account] = [],
        calendarsByAccount: [AccountID: [CalendarInfo]] = [:],
        eventsByAccount: [AccountID: [Event]] = [:],
        fetchedAtByAccount: [AccountID: Date] = [:],
        syncByAccount: [AccountID: [CalendarSync]] = [:],
        visibility: CalendarVisibility = CalendarVisibility()
    ) {
        self.accounts = accounts
        self.calendarsByAccount = calendarsByAccount
        self.eventsByAccount = eventsByAccount
        self.fetchedAtByAccount = fetchedAtByAccount
        self.syncByAccount = syncByAccount
        self.visibility = visibility
    }

    /// Every calendar once, accounts in order and each account's calendars in Google's order.
    /// A calendar shared into several accounts stays under the one with the highest access
    /// role (the first-added account on a tie) and is fetched only there.
    public var calendars: [CalendarInfo] {
        CalendarData.deduplicated(accounts.map { calendarsByAccount[$0.id] ?? [] })
    }

    public func calendarInfo(_ id: CalendarID) -> CalendarInfo? {
        calendarsByAccount[id.account]?.first { $0.id == id }
    }

    /// Shown in Day: the person's toggle, else Google's `selected` flag. A calendar folded
    /// into another account's copy is never shown under this one.
    public func isVisible(_ id: CalendarID) -> Bool {
        guard let info = calendars.first(where: { $0.id == id }) else { return false }
        return visibility.isVisible(info)
    }

    /// The oldest full fetch among accounts still signed in, which is how old the data on
    /// screen may be: `Offline. Showing events as of 9:40.` Signed-out accounts count only
    /// when every account is signed out. Nil before the first fetch.
    public var lastFetchedAt: Date? {
        let signedIn = accounts.filter { !$0.signedOut }.compactMap { fetchedAtByAccount[$0.id] }
        if let oldest = signedIn.min() { return oldest }
        return accounts.compactMap { fetchedAtByAccount[$0.id] }.min()
    }

    /// The days every shown calendar of the signed-in accounts has complete events for: what
    /// the Month can draw without asking for more. A shown calendar never fetched yet is left
    /// out, since the next refresh reads it in full. Nil before the first fetch, and when the
    /// calendars cover days that do not meet.
    public var syncedDays: ClosedRange<CivilDate>? {
        let signedIn = Set(accounts.filter { !$0.signedOut }.map(\.id))
        var lower: CivilDate?
        var upper: CivilDate?
        for info in calendars where signedIn.contains(info.id.account) && visibility.isVisible(info) {
            guard let days = syncByAccount[info.id.account]?.first(where: { $0.calendar == info.id })?.days
            else { continue }
            lower = max(lower ?? days.lowerBound, days.lowerBound)
            upper = min(upper ?? days.upperBound, days.upperBound)
        }
        guard let lower, let upper, lower <= upper else { return nil }
        return lower...upper
    }

    /// Merged events from visible calendars whose time overlaps any of `days` in
    /// `calendar`'s zone, sorted by start: what `CalendarStore.events(in:)` returns. Events
    /// go into `merged` in account order, first-added first, which is its last tiebreak.
    public func events(in days: ClosedRange<CivilDate>, calendar: Calendar) -> [Event] {
        let from = days.lowerBound.date(in: calendar)
        let to = days.upperBound.adding(days: 1).date(in: calendar)
        let shown = Set(calendars.filter(visibility.isVisible).map(\.id))
        let ordered = accounts.flatMap { eventsByAccount[$0.id] ?? [] }
            .filter { shown.contains($0.id.calendar) }
        return merged(ordered)
            .filter { event in
                let interval = event.time.interval(in: calendar)
                return interval.start < to && (interval.end > from || interval.start >= from)
            }
            .sorted { $0.time.start(in: calendar) < $1.time.start(in: calendar) }
    }

    /// What the Lock Screen widget needs, from this data: merged visible events from today
    /// through `WidgetSnapshot.days(from:)`, the account counts, and the age of the data.
    /// Nil while accounts exist but none has been fetched, since there is nothing to show
    /// yet. With no accounts it is an empty snapshot dated now, so the widget says
    /// `Add a Google account` at once.
    public func widgetSnapshot(now: Date, calendar: Calendar) -> WidgetSnapshot? {
        guard !accounts.isEmpty else {
            return WidgetSnapshot(fetchedAt: now, accountCount: 0, signedOutAccounts: 0, events: [])
        }
        guard let fetchedAt = lastFetchedAt else { return nil }
        let today = CivilDate(now, in: calendar)
        return WidgetSnapshot(
            fetchedAt: fetchedAt,
            accountCount: accounts.count,
            signedOutAccounts: accounts.filter(\.signedOut).count,
            events: events(in: WidgetSnapshot.days(from: today), calendar: calendar))
    }

    /// Folds calendars shared between accounts: one copy per Google calendar ID, the highest
    /// access role winning and the earlier list winning a tie. `lists` is in account order.
    public static func deduplicated(_ lists: [[CalendarInfo]]) -> [CalendarInfo] {
        var best: [String: CalendarInfo] = [:]
        for info in lists.joined() {
            if let current = best[info.id.googleID], current.accessRole >= info.accessRole {
                continue
            }
            best[info.id.googleID] = info
        }
        return lists.joined().filter { best[$0.id.googleID]?.id == $0.id }
    }
}
