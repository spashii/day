import Foundation

/// What one calendar's read brought back, to be written onto the account's cache.
enum CalendarFetchResult: Sendable {
    /// Every event over `days`, read by window, with the token Google issued on the last
    /// page (nil if it sent none). `wipe` when the read replaces a token Google refused.
    case full(
        events: [Event], token: String?, window: DateInterval, days: ClosedRange<CivilDate>,
        wipe: Bool)
    /// What changed since `since`, and the token after it.
    case changes([EventChange], since: String, next: String)
    /// Nothing was asked: the calendar has no token and was read in full recently.
    case unchanged
    /// Gone, or no longer shared with this account: its events are dropped.
    case unreadable
    /// The account's cache keeps this calendar as it was, and the next refresh tries again.
    case failed(AccountProblem)
}

/// What one calendar's read brought back for the widget, which keeps nothing but the
/// snapshot.
enum WidgetFetchResult: Sendable {
    case changes([EventChange])
    case window([Event])
    case unreadable
}

// MARK: - Reading, off the actor

extension SyncEngine {
    /// One account's calendar list. Read incrementally from the stored token, and in full
    /// when there is none, when Google refuses it (410), or once a day, because an
    /// incremental read leaves out changes to a calendar's own properties. Labels are read
    /// again once a day and for any calendar new to the list; a label read that fails keeps
    /// the labels already known.
    static func fetchCalendarList(
        account: AccountID, authorizer: AccountAuthorizer, api: CalendarAPI,
        previous: CalendarsFile?, now: Date
    ) async throws -> CalendarsFile {
        var labels: [String: [String: LabelInfo]] = [:]
        for info in previous?.calendars ?? [] { labels[info.id.googleID] = info.labels }

        let interval = CalendarSync.fullSyncInterval(for: account.sub)
        var changed: CalendarListResult?
        if let previous, let token = previous.syncToken, let fullAt = previous.fullSyncAt,
            (0..<interval).contains(now.timeIntervalSince(fullAt))
        {
            do {
                let result = try await authorizer.authorized {
                    try await api.calendarList(accessToken: $0, syncToken: token)
                }
                if result.nextSyncToken != nil { changed = result }
            } catch let error as CalendarAPIError where error.needsFullSync {
                // Google refused the token; the full read below starts over.
            }
        }

        let isFull = changed == nil
        var calendars: [CalendarInfo]
        let next: String?
        if let changed, let previous {
            calendars = previous.calendars
            for entry in changed.entries {
                let info = GoogleDecoding.calendarInfo(
                    entry, account: account, labels: labels[entry.id] ?? [:])
                if let i = calendars.firstIndex(where: { $0.id.googleID == entry.id }) {
                    if let info { calendars[i] = info } else { calendars.remove(at: i) }
                } else if let info {
                    calendars.append(info)
                }
            }
            calendars = calendars.filter(\.isPrimary) + calendars.filter { !$0.isPrimary }
            next = changed.nextSyncToken
        } else {
            let result = try await authorizer.authorized { try await api.calendarList(accessToken: $0) }
            calendars = GoogleDecoding.calendars(result.entries, account: account, labels: labels)
            next = result.nextSyncToken
        }

        let known = Set(previous?.calendars.map(\.id.googleID) ?? [])
        let stale = previous?.labelsFetchedAt.map {
            !(0..<interval).contains(now.timeIntervalSince($0))
        } ?? true
        let wanted = calendars.filter {
            GoogleDecoding.mayHaveLabels($0) && (stale || !known.contains($0.id.googleID))
        }
        await withTaskGroup(of: (String, [String: LabelInfo]?).self) { group in
            for info in wanted {
                let id = info.id.googleID
                group.addTask {
                    let resource = try? await authorizer.authorized {
                        try await api.calendar(id, accessToken: $0)
                    }
                    return (id, resource.map(GoogleDecoding.labels))
                }
            }
            for await (id, found) in group {
                if let found { labels[id] = found }
            }
        }
        // A label read that was cancelled looks like one that failed. Stamping the labels as
        // fresh then would leave a new calendar without them for a day.
        try Task.checkCancellation()
        for i in calendars.indices {
            calendars[i].labels = labels[calendars[i].id.googleID] ?? [:]
        }
        return CalendarsFile(
            fetchedAt: now,
            labelsFetchedAt: stale ? now : previous?.labelsFetchedAt,
            calendars: calendars,
            syncToken: next,
            fullSyncAt: isFull ? now : previous?.fullSyncAt)
    }

    /// Every calendar of one account at once, each by its own plan: changes since its token,
    /// a full read over `fullDays`, or nothing. One calendar failing never stops the others,
    /// so the ones that answered are written.
    static func fetchCalendars(
        _ plans: [(info: CalendarInfo, plan: CalendarPlan)], fullDays: ClosedRange<CivilDate>,
        calendar: Calendar, authorizer: AccountAuthorizer, api: CalendarAPI
    ) async -> [CalendarID: CalendarFetchResult] {
        await withTaskGroup(of: (CalendarID, CalendarFetchResult).self) { group in
            for item in plans {
                group.addTask {
                    let result = await fetchCalendar(
                        item.info, plan: item.plan, fullDays: fullDays, calendar: calendar,
                        authorizer: authorizer, api: api)
                    return (item.info.id, result)
                }
            }
            var results: [CalendarID: CalendarFetchResult] = [:]
            for await (id, result) in group { results[id] = result }
            return results
        }
    }

    /// One calendar. With a token: the changes since it, all pages, until the last page
    /// brings the next token. A 410, a 400 for the token, or a last page with no token
    /// means the token cannot be read from any more: the calendar is wiped and read in full,
    /// in this same refresh, and no other calendar is touched.
    ///
    /// A change set that rewrites a series is not applied: the calendar is read by window
    /// instead (see `editsASeries`), which asks Google for nothing it has not documented.
    static func fetchCalendar(
        _ info: CalendarInfo, plan: CalendarPlan, fullDays: ClosedRange<CivilDate>,
        calendar: Calendar, authorizer: AccountAuthorizer, api: CalendarAPI
    ) async -> CalendarFetchResult {
        let token: String
        switch plan {
        case .wait:
            return .unchanged
        case .full:
            return await fullRead(
                info, days: fullDays, wipe: false, calendar: calendar, authorizer: authorizer,
                api: api)
        case .changes(let since):
            token = since
        }
        do {
            let list = try await authorizer.authorized {
                try await api.events(
                    calendarID: info.id.googleID, query: .changes(since: token), accessToken: $0)
            }
            if let next = list.nextSyncToken {
                if editsASeries(list.items) {
                    return await fullRead(
                        info, days: fullDays, wipe: false, calendar: calendar,
                        authorizer: authorizer, api: api)
                }
                return .changes(
                    list.items.map { GoogleDecoding.change($0, on: info) }, since: token,
                    next: next)
            }
        } catch let error as CalendarAPIError where error.needsFullSync {
            // Falls through to the full read.
        } catch {
            return failure(error)
        }
        return await fullRead(
            info, days: fullDays, wipe: true, calendar: calendar, authorizer: authorizer, api: api)
    }

    /// Whether one change set carries two or more different instances of the same series,
    /// which a single edited occurrence never does.
    ///
    /// Changing a series for all events, or from one event on, gives every instance in the
    /// window a new ID (`<series>_<original start>`) or moves them to a new series. Google
    /// documents that with `singleEvents` and deleted items both on, "only single instances
    /// of deleted events (but not the underlying recurring events) are returned", and does
    /// not say the old instance IDs come back cancelled. If they do not, applying the
    /// change set would show the old and the new instances side by side until the next full
    /// read. So the window is read again: one more call for a rare edit, and correct whichever
    /// way Google answers.
    static func editsASeries(_ items: [GoogleEvent]) -> Bool {
        var firstInstance: [String: String] = [:]
        for item in items where item.status != "cancelled" {
            guard let series = item.recurringEventId, !series.isEmpty else { continue }
            if let seen = firstInstance[series] {
                if seen != item.id { return true }
            } else {
                firstInstance[series] = item.id
            }
        }
        return false
    }

    /// Every instance overlapping `days`, read by window, keeping the token from the last
    /// page.
    static func fullRead(
        _ info: CalendarInfo, days: ClosedRange<CivilDate>, wipe: Bool, calendar: Calendar,
        authorizer: AccountAuthorizer, api: CalendarAPI
    ) async -> CalendarFetchResult {
        let window = interval(days, calendar: calendar)
        do {
            let list = try await authorizer.authorized {
                try await api.events(
                    calendarID: info.id.googleID,
                    query: .window(from: window.start, to: window.end), accessToken: $0)
            }
            return .full(
                events: GoogleDecoding.events(list.items, on: info), token: list.nextSyncToken,
                window: window, days: days, wipe: wipe)
        } catch {
            return failure(error)
        }
    }

    /// A calendar Google no longer lets this account read (gone, or a 403 `forbidden`)
    /// empties rather than failing the account. Any other failure, including a
    /// project-wide 403 such as `accessNotConfigured`, keeps the calendar's cache, and the
    /// screen says `Couldn't reach Google`.
    static func failure(_ error: any Error) -> CalendarFetchResult {
        if let api = error as? CalendarAPIError, api.meansCalendarUnreadable { return .unreadable }
        return .failed(AccountProblem(error))
    }

    /// Events of one calendar over `days`, by window with no token: the Month's stretches
    /// beyond the covered days. Unreadable reads as empty.
    static func fetchStretch(
        _ info: CalendarInfo, days: ClosedRange<CivilDate>, calendar: Calendar,
        authorizer: AccountAuthorizer, api: CalendarAPI
    ) async -> Result<[Event], AccountProblem> {
        let range = interval(days, calendar: calendar)
        do {
            let google = try await authorizer.authorized {
                try await api.events(
                    calendarID: info.id.googleID, from: range.start, to: range.end,
                    accessToken: $0)
            }
            return .success(GoogleDecoding.events(google, on: info))
        } catch let error as CalendarAPIError where error.meansCalendarUnreadable {
            return .success([])
        } catch {
            return .failure(AccountProblem(error))
        }
    }

    /// One calendar for the widget: the changes since the app's token when its window holds
    /// the widget's days, else those days by window. A token Google refuses, and a change set
    /// that rewrites a series, fall back to the window too; the app reads that calendar in
    /// full on its next refresh. Throws for
    /// anything that should leave the snapshot as it is.
    static func fetchForWidget(
        _ info: CalendarInfo, token: String?, days: DateInterval, authorizer: AccountAuthorizer,
        api: CalendarAPI
    ) async throws -> WidgetFetchResult {
        do {
            if let token {
                do {
                    let list = try await authorizer.authorized {
                        try await api.events(
                            calendarID: info.id.googleID, query: .changes(since: token),
                            accessToken: $0)
                    }
                    if list.nextSyncToken != nil, !editsASeries(list.items) {
                        return .changes(list.items.map { GoogleDecoding.change($0, on: info) })
                    }
                } catch let error as CalendarAPIError where error.needsFullSync {
                    // Falls through to the window.
                }
            }
            let google = try await authorizer.authorized {
                try await api.events(
                    calendarID: info.id.googleID, from: days.start, to: days.end,
                    accessToken: $0)
            }
            return .window(GoogleDecoding.events(google, on: info))
        } catch let error as CalendarAPIError where error.meansCalendarUnreadable {
            return .unreadable
        }
    }
}

// MARK: - Accounts

/// Why one account's fetch stopped.
enum AccountProblem: Error, Hashable, Sendable {
    /// Google refused the grant or it lacks calendar access: `Sign In Again…`.
    case signedOut
    /// Anything else; the account's cache stays and the next refresh tries again.
    case failed(offline: Bool)

    init(_ error: any Error) {
        switch error {
        case let problem as AccountProblem:
            self = problem
        case let oauth as OAuthError where oauth.signsOut:
            self = .signedOut
        case let api as CalendarAPIError where api == .insufficientScope:
            self = .signedOut
        default:
            self = .failed(offline: GoogleHTTP.isOffline(error))
        }
    }

    /// Several calendars' problems as the account's one: signed out wins, then offline only
    /// when every failure was offline.
    static func combined(_ problems: [AccountProblem]) -> AccountProblem? {
        guard !problems.isEmpty else { return nil }
        if problems.contains(.signedOut) { return .signedOut }
        return .failed(offline: problems.allSatisfy { $0 == .failed(offline: true) })
    }
}

/// Hands out one account's access token, refreshing it when it is about to expire or Google
/// rejected it, and saving the refreshed token for the next launch and for the widget.
/// Concurrent requests for a new token share one refresh.
actor AccountAuthorizer {
    let account: AccountID
    let auth: GoogleAuth
    let tokens: any TokenStore
    let clock: @Sendable () -> Date
    private(set) var token: StoredToken
    private var refreshing: Task<StoredToken, any Error>?

    init(
        account: AccountID, token: StoredToken, auth: GoogleAuth, tokens: any TokenStore,
        clock: @escaping @Sendable () -> Date
    ) {
        self.account = account
        self.token = token
        self.auth = auth
        self.tokens = tokens
        self.clock = clock
    }

    /// A token with more than a minute left, never `rejected`. The expiry is counted on this
    /// device's clock from Google's `expires_in`, so a clock that jumps ahead costs an early
    /// refresh and one that jumps back costs a 401, which `authorized` answers with a
    /// refresh.
    func accessToken(rejecting rejected: String? = nil) async throws -> String {
        if let valid = token.validAccessToken(at: clock()), valid != rejected {
            return valid
        }
        if let refreshing {
            return try await refreshing.value.accessToken ?? ""
        }
        let task = Task { [auth, token, clock] in try await auth.refresh(token, now: clock()) }
        refreshing = task
        defer { refreshing = nil }
        // The token call is a task of its own so concurrent requests can share it; a caller
        // that is cancelled ends it, or its retries would outlast the cancellation by up to
        // a minute.
        let refreshed = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        token = refreshed
        try? tokens.save(refreshed, for: account)
        return refreshed.accessToken ?? ""
    }

    /// Runs `call` with a token; on a 401, once more with a new one.
    nonisolated func authorized<Value: Sendable>(
        _ call: @Sendable (String) async throws -> Value
    ) async throws -> Value {
        let access = try await accessToken()
        do {
            return try await call(access)
        } catch CalendarAPIError.unauthorized {
            return try await call(try await accessToken(rejecting: access))
        }
    }
}
