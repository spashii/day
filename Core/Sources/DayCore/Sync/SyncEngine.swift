import Foundation
import Synchronization

/// Keeps every account's calendars current from Google, and the cache files and the widget
/// snapshot with them. The real store draws from `load()` at once and calls `refresh()` on
/// launch, return to the front, pull to refresh, Command-R, wake, network return and the
/// timer; views never wait on it.
///
/// A refresh, per account and in parallel: a valid access token (refreshed when under a
/// minute is left), the calendar list read incrementally, then, after shared calendars are
/// folded to one account, each visible calendar read incrementally from its sync token. A
/// calendar with no usable token is read in full over today minus 35 days through today plus
/// 127, which issues one. Usable means: Google has not refused it, its window still holds
/// today minus 35 through plus 120, and its full read is under a day old (a few hours less,
/// differently for each calendar, so the daily reads do not all fall in one refresh). A calendar
/// Google issued no token for is read in full once an hour. `docs/SYNC.md` has the whole story.
///
/// A refresh can be cancelled: the caller that started it stops it, every request in flight
/// ends, and whatever calendars already answered are written. The background task relies on
/// that, because the system ends its time without further notice.
///
/// One account failing never touches another, and one calendar failing never touches
/// another: `invalid_grant` or a missing calendar scope marks only that account signed out,
/// its cached events stay on screen, and the calendars that answered are written.
///
/// Sign-in is two calls around the app's `WebAuthenticationSession`:
///
/// ```swift
/// let request = try engine.authorizationRequest()
/// let callback = try await session.authenticate(
///     using: request.url, callback: .customScheme(request.callbackScheme),
///     preferredBrowserSession: .shared, additionalHeaderFields: [:])
/// let account = try await engine.completeSignIn(request, callback: callback)
/// ```
public actor SyncEngine {
    public let cache: CacheDirectory
    /// Nil while no OAuth client is configured; nothing is fetched then.
    public let auth: GoogleAuth?
    /// The zone "today" and the fetch window are counted in.
    public let calendar: Calendar
    let tokens: any TokenStore
    let api: CalendarAPI
    let clock: @Sendable () -> Date

    /// Bumped by every change to accounts or visibility, so a refresh started before the
    /// change is not handed out as the answer to one asked for after it.
    private var generation = 0
    private var inFlight: (task: Task<SyncReport, Never>, generation: Int)?

    public init(
        auth: GoogleAuth?,
        tokens: any TokenStore,
        cache: CacheDirectory,
        api: CalendarAPI = CalendarAPI(),
        calendar: Calendar = .autoupdatingCurrent,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.auth = auth
        self.tokens = tokens
        self.cache = cache
        self.api = api
        self.calendar = calendar
        self.clock = clock
    }

    /// Today minus 35 days through today plus 120: the days every refresh keeps current, the
    /// month's rows above and below, without ever asking Google to expand endless series
    /// without a bound.
    public static func defaultWindow(today: CivilDate) -> ClosedRange<CivilDate> {
        today.adding(days: -35)...today.adding(days: 120)
    }

    /// The days a full read asks for: the default window and a week more ahead, so a token
    /// still holds the days the default window slides into before the next daily full read.
    static func syncWindow(today: CivilDate) -> ClosedRange<CivilDate> {
        today.adding(days: -35)...today.adding(days: 127)
    }

    /// Yesterday through ten days ahead: what the near file holds. The widget needs today
    /// through eight days ahead (`WidgetSnapshot.days`), and the extra days on both sides keep
    /// it off the full cache for the two days the app may go unopened.
    static func nearDays(today: CivilDate) -> ClosedRange<CivilDate> {
        today.adding(days: -1)...today.adding(days: 10)
    }

    // MARK: Reading

    /// Everything cached, read straight from disk. Safe from any thread and fast enough for
    /// launch, which draws from it before any fetch.
    public nonisolated func load() -> CalendarData {
        SyncEngine.load(from: cache)
    }

    /// The widget's snapshot as it is on disk, which the app compares with the one the
    /// widget last reloaded for.
    public nonisolated func widgetSnapshot() -> WidgetSnapshot? {
        WidgetSnapshot.read(from: cache)
    }

    /// What the widget needs: the same as `load()` but each account's events and tokens from
    /// its near file when that holds `days`, so the extension never decodes the whole cache
    /// while the app keeps the near file written. An account with no usable near file (a
    /// file from before it existed, one written for other days) reads in full.
    nonisolated func loadForWidget(days: ClosedRange<CivilDate>) -> CalendarData {
        SyncEngine.load(from: cache, near: days)
    }

    static func load(from cache: CacheDirectory, near days: ClosedRange<CivilDate>? = nil)
        -> CalendarData
    {
        let accounts = cache.read([Account].self, from: CacheFile.accounts) ?? []
        var data = CalendarData(
            accounts: accounts,
            visibility: cache.read(CalendarVisibility.self, from: CacheFile.visibility)
                ?? CalendarVisibility())
        for account in accounts {
            if let file = cache.read(CalendarsFile.self, from: CacheFile.calendars(account.id)) {
                data.calendarsByAccount[account.id] = file.calendars
            }
            if let days, let near = cache.near(account.id), near.covers(days) {
                data.eventsByAccount[account.id] = near.events
                data.syncByAccount[account.id] = near.sync
                data.fetchedAtByAccount[account.id] = near.fetchedAt
            } else if let stored = cache.account(account.id) {
                data.eventsByAccount[account.id] = stored.events
                data.syncByAccount[account.id] = stored.sync
                data.fetchedAtByAccount[account.id] = stored.fetchedAt
            }
        }
        return data
    }

    // MARK: Accounts

    /// A fresh sign-in request. Pass the account's email as `loginHint` for Sign In Again.
    public nonisolated func authorizationRequest(loginHint: String? = nil) throws
        -> AuthorizationRequest
    {
        guard let auth else { throw SyncError.noGoogleClient }
        return auth.authorizationRequest(loginHint: loginHint)
    }

    /// Trades the redirect for tokens and adds the account, or brings it back when it was
    /// already on the list. With `repairing`, a different Google account is refused, so Sign
    /// In Again cannot quietly swap one account for another. A grant without calendar access
    /// still adds the account, signed out, so the list can say so. Call `refresh()` after.
    /// An account signed in again keeps its sync tokens: the next refresh reads only what
    /// changed while it was signed out.
    @discardableResult
    public func completeSignIn(
        _ request: AuthorizationRequest, callback: URL, repairing expected: AccountID? = nil
    ) async throws -> Account {
        guard let auth else { throw SyncError.noGoogleClient }
        let signIn = try await auth.exchange(callback: callback, for: request, now: clock())
        if let expected, signIn.account != expected {
            throw OAuthError.differentAccount(email: signIn.email)
        }
        if signIn.grantsCalendar {
            try tokens.save(signIn.token, for: signIn.account)
        }
        var accounts = cache.read([Account].self, from: CacheFile.accounts) ?? []
        let account: Account
        if let i = accounts.firstIndex(where: { $0.id == signIn.account }) {
            accounts[i].email = signIn.email
            accounts[i].signedOut = !signIn.grantsCalendar
            account = accounts[i]
        } else {
            account = Account(
                id: signIn.account, email: signIn.email, addedAt: clock(),
                signedOut: !signIn.grantsCalendar)
            accounts.append(account)
        }
        try cache.write(accounts, to: CacheFile.accounts)
        generation += 1
        return account
    }

    /// Forgets the account on this device: its tokens, calendars, events, sync tokens and
    /// toggles. Nothing changes in Google.
    public func removeAccount(_ id: AccountID) throws {
        try tokens.removeToken(for: id)
        var accounts = cache.read([Account].self, from: CacheFile.accounts) ?? []
        accounts.removeAll { $0.id == id }
        try cache.write(accounts, to: CacheFile.accounts)
        cache.removeAccount(id)
        var visibility = cache.read(CalendarVisibility.self, from: CacheFile.visibility)
            ?? CalendarVisibility()
        visibility.forget(id)
        try cache.write(visibility, to: CacheFile.visibility)
        generation += 1
        writeWidgetSnapshot(force: true)
    }

    /// The person's toggle for one calendar. A calendar shown again resumes from its own
    /// token on the next `refresh()`, reading only what changed while it was hidden; one
    /// never fetched is read in full then.
    public func setVisible(_ visible: Bool, calendar id: CalendarID) throws {
        var visibility = cache.read(CalendarVisibility.self, from: CacheFile.visibility)
            ?? CalendarVisibility()
        visibility.set(visible, for: id)
        try cache.write(visibility, to: CacheFile.visibility)
        generation += 1
        writeWidgetSnapshot(force: true)
    }

    /// Rebuilds the widget snapshot from the cache and writes it (newer wins unless
    /// `force`). Returns the snapshot when it was written.
    @discardableResult
    public func writeWidgetSnapshot(force: Bool = false) -> WidgetSnapshot? {
        let now = clock()
        guard let snapshot = load().widgetSnapshot(now: now, calendar: calendar),
            (try? snapshot.write(to: cache, force: force, now: now)) == true
        else { return nil }
        return snapshot
    }

    // MARK: Refresh

    /// Reads every signed-in account's changes and rewrites the cache and the snapshot.
    /// Calls that arrive while one is running share its result, unless accounts or
    /// visibility changed since it started.
    ///
    /// Cancelling the caller that started a refresh cancels it: every request ends, calendars
    /// that had already answered are written, and the report says Google was not reached.
    /// A caller that joined a refresh already running stops waiting when it is cancelled and
    /// leaves the run to its starter; if the starter is cancelled, the callers still waiting
    /// start a refresh of their own. `retry` replaces the client's retry policy for a refresh
    /// this call starts.
    public func refresh(retry: RetryPolicy? = nil) async -> SyncReport {
        while let running = inFlight {
            guard let shared = await SyncEngine.wait(for: running.task) else {
                return report(.unreachable)
            }
            if inFlight?.task == running.task { inFlight = nil }
            // A run that was cancelled says nothing about Google: callers that joined it
            // start their own.
            if running.task.isCancelled { continue }
            if running.generation == generation { return shared }
        }
        let task = Task { await self.performRefresh(retry: retry) }
        inFlight = (task, generation)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inFlight?.task == task { inFlight = nil }
        return result
    }

    /// The refresh for a background task, which the system ends without notice when its time
    /// runs out and punishes by ending the app when work goes on past that. One try per
    /// request, so a failing call costs seconds and not a minute of backoff, and `limit` for
    /// the whole refresh: at the limit every request is cancelled, what answered is written,
    /// and the report says Google was not reached. The next refresh reads from there.
    public func refreshInBackground(within limit: Duration = .seconds(20)) async -> SyncReport {
        do {
            return try await SyncEngine.withDeadline(limit) { await self.refresh(retry: .once) }
        } catch {
            return report(.unreachable)
        }
    }

    /// Waits for a refresh another caller started, or gives up with nil when this caller is
    /// cancelled first. Awaiting a task's value alone would hold a cancelled caller until the
    /// run ended, which for a background task is the one thing it cannot do.
    private static func wait(for task: Task<SyncReport, Never>) async -> SyncReport? {
        let gate = Gate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SyncReport?, Never>) in
                gate.arm(continuation)
                Task { gate.finish(await task.value) }
            }
        } onCancel: {
            gate.finish(nil)
        }
    }

    /// Resumes a waiter exactly once, with whichever comes first: the run's report or the
    /// waiter's cancellation.
    private final class Gate: Sendable {
        private enum State {
            case idle
            case armed(CheckedContinuation<SyncReport?, Never>)
            case done(SyncReport?)
        }

        private let state = Mutex(State.idle)

        func arm(_ continuation: CheckedContinuation<SyncReport?, Never>) {
            state.withLock { state in
                if case .done(let value) = state {
                    continuation.resume(returning: value)
                } else {
                    state = .armed(continuation)
                }
            }
        }

        func finish(_ value: SyncReport?) {
            state.withLock { state in
                switch state {
                case .idle:
                    state = .done(value)
                case .armed(let continuation):
                    state = .done(value)
                    continuation.resume(returning: value)
                case .done:
                    break
                }
            }
        }
    }

    /// Fetches the days of `days` the cache does not cover yet, for the Month scrolling past
    /// the window. Days already covered are not fetched again; incremental reads keep them
    /// current.
    public func extendWindow(toInclude days: ClosedRange<CivilDate>) async -> SyncReport {
        if let running = inFlight { _ = await running.task.value }
        return await performExtension(days)
    }

    private func performRefresh(retry: RetryPolicy?) async -> SyncReport {
        let now = clock()
        let start = load()
        guard let configured = auth else { return report(.current) }
        let auth = retry.map { configured.with(retry: $0) } ?? configured
        let api = retry.map { self.api.with(retry: $0) } ?? self.api
        let today = CivilDate(now, in: calendar)
        let neededDays = SyncEngine.defaultWindow(today: today)
        let needed = SyncEngine.interval(neededDays, calendar: calendar)
        let fullDays = SyncEngine.syncWindow(today: today)
        var problems: [AccountID: AccountProblem] = [:]

        // Tokens, read once; the refresh token in use is remembered so an account signed in
        // again during this fetch is not marked signed out by its old token's failure.
        var authorizers: [AccountID: AccountAuthorizer] = [:]
        var refreshTokens: [AccountID: String] = [:]
        for account in start.accounts where !account.signedOut {
            do {
                guard let token = try tokens.token(for: account.id) else {
                    problems[account.id] = .signedOut
                    continue
                }
                authorizers[account.id] = AccountAuthorizer(
                    account: account.id, token: token, auth: auth, tokens: tokens, clock: clock)
                refreshTokens[account.id] = token.refreshToken
            } catch {
                // The keychain refused (for example before first unlock): try again later.
                problems[account.id] = .failed(offline: false)
            }
        }

        // Calendar lists, all accounts at once.
        var lists: [AccountID: CalendarsFile] = [:]
        await withTaskGroup(of: (AccountID, Result<CalendarsFile, AccountProblem>).self) { group in
            for (id, authorizer) in authorizers {
                let previous = cache.read(CalendarsFile.self, from: CacheFile.calendars(id))
                group.addTask { [api] in
                    do {
                        let file = try await SyncEngine.fetchCalendarList(
                            account: id, authorizer: authorizer, api: api, previous: previous,
                            now: now)
                        return (id, .success(file))
                    } catch {
                        return (id, .failure(AccountProblem(error)))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let file): lists[id] = file
                case .failure(let problem): problems[id] = problem
                }
            }
        }
        let accountsNow = Set((cache.read([Account].self, from: CacheFile.accounts) ?? []).map(\.id))
        for (id, file) in lists where accountsNow.contains(id) {
            try? cache.write(file, to: CacheFile.calendars(id))
        }

        // Shared calendars fold to one account; only visible calendars are read. A calendar
        // whose own entry changed in a way its events decode from (its color, labels, zone or
        // access) is read in full, because an incremental read would only bring the events
        // that changed.
        var calendarLists = start.calendarsByAccount
        for (id, file) in lists { calendarLists[id] = file.calendars }
        let visibility = cache.read(CalendarVisibility.self, from: CacheFile.visibility)
            ?? CalendarVisibility()
        let kept = CalendarData.deduplicated(start.accounts.map { calendarLists[$0.id] ?? [] })
        let before = Dictionary(
            start.calendarsByAccount.values.joined().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var fetched: [AccountID: [CalendarID: CalendarFetchResult]] = [:]
        await withTaskGroup(of: (AccountID, [CalendarID: CalendarFetchResult]).self) { group in
            for id in lists.keys {
                guard let authorizer = authorizers[id] else { continue }
                let stored = cache.account(id)
                let plans = kept.filter { $0.id.account == id && visibility.isVisible($0) }
                    .map { info -> (info: CalendarInfo, plan: CalendarPlan) in
                        let changed = before[info.id].map {
                            GoogleDecoding.decodesDifferently($0, info)
                        } ?? false
                        guard !changed, let state = stored?.state(of: info.id) else {
                            return (info, .full)
                        }
                        return (info, state.plan(needed: needed, neededDays: neededDays, now: now))
                    }
                group.addTask { [calendar] in
                    let results = await SyncEngine.fetchCalendars(
                        plans, fullDays: fullDays, calendar: calendar, authorizer: authorizer,
                        api: api)
                    return (id, results)
                }
            }
            for await (id, results) in group { fetched[id] = results }
        }

        // Each account's cache is rebuilt from what is on disk now, with no suspension
        // between reading and writing, so a concurrent window extension is never lost.
        for (id, results) in fetched where accountsNow.contains(id) {
            let previous = cache.account(id)
            var account = previous ?? AccountCache()
            var failures: [AccountProblem] = []
            for (calendarID, result) in results {
                switch result {
                case .full(let events, let token, let window, let days, let wipe):
                    let state = CalendarSync(
                        calendar: calendarID, token: token, tokenFrom: window.start,
                        tokenTo: window.end, fullSyncAt: now, syncedAt: now, days: days)
                    account.replace(calendarID, with: events, state: state, wipe: wipe, calendar: calendar)
                case .changes(let changes, let since, let next):
                    // Only this engine writes tokens and refreshes never overlap, so a token
                    // that moved meanwhile means the account was removed and added again.
                    // The changes are dropped and the next refresh reads from what is there.
                    if !account.apply(changes, to: calendarID, since: since, next: next, at: now, calendar: calendar) {
                        failures.append(.failed(offline: false))
                    }
                case .unchanged:
                    break
                case .unreadable:
                    account.forget(calendarID)
                case .failed(let problem):
                    failures.append(problem)
                }
            }
            account.retain(listed: Set(kept.filter { $0.id.account == id }.map(\.id)))
            account.expireStretches(at: now)
            if let problem = AccountProblem.combined(failures) {
                problems[id] = problem
            } else {
                account.fetchedAt = now
            }
            account.sortEvents(calendar: calendar)
            store(account, for: id, previous: previous, now: now)
        }

        var newlySignedOut: [AccountID] = []
        var accounts = cache.read([Account].self, from: CacheFile.accounts) ?? []
        for (id, problem) in problems where problem == .signedOut {
            guard let i = accounts.firstIndex(where: { $0.id == id }), !accounts[i].signedOut
            else { continue }
            let current = (try? tokens.token(for: id))?.refreshToken
            guard current == refreshTokens[id] else { continue }
            accounts[i].signedOut = true
            newlySignedOut.append(id)
        }
        if !newlySignedOut.isEmpty {
            try? cache.write(accounts, to: CacheFile.accounts)
        }

        let data = load()
        if let snapshot = data.widgetSnapshot(now: now, calendar: calendar) {
            _ = try? snapshot.write(to: cache, now: now)
        }
        return report(SyncEngine.outcome(Array(problems.values)), data: data, newlySignedOut: newlySignedOut)
    }

    private func performExtension(_ days: ClosedRange<CivilDate>) async -> SyncReport {
        let start = load()
        guard let auth else { return report(.current, data: start) }
        let shown = start.calendars.filter { start.visibility.isVisible($0) }
        var problems: [AccountProblem] = []
        for account in start.accounts where !account.signedOut {
            // A calendar never fetched is the next refresh's to read in full.
            let states = start.syncByAccount[account.id] ?? []
            var work: [(info: CalendarInfo, days: ClosedRange<CivilDate>)] = []
            for info in shown where info.id.account == account.id {
                guard let state = states.first(where: { $0.calendar == info.id }) else { continue }
                for slice in SyncEngine.missing(days, from: state.days) {
                    work.append((info, slice))
                }
            }
            guard !work.isEmpty else { continue }
            let token: StoredToken
            do {
                guard let stored = try tokens.token(for: account.id) else { continue }
                token = stored
            } catch {
                problems.append(.failed(offline: false))
                continue
            }
            let authorizer = AccountAuthorizer(
                account: account.id, token: token, auth: auth, tokens: tokens, clock: clock)
            let results = await withTaskGroup(
                of: (CalendarID, ClosedRange<CivilDate>, Result<[Event], AccountProblem>).self
            ) { group in
                for item in work {
                    group.addTask { [api, calendar] in
                        let result = await SyncEngine.fetchStretch(
                            item.info, days: item.days, calendar: calendar,
                            authorizer: authorizer, api: api)
                        return (item.info.id, item.days, result)
                    }
                }
                var all: [(CalendarID, ClosedRange<CivilDate>, Result<[Event], AccountProblem>)] = []
                for await result in group { all.append(result) }
                return all
            }
            guard let previous = cache.account(account.id) else { continue }
            var current = previous
            for (id, slice, result) in results {
                switch result {
                case .success(let events):
                    // A calendar dropped from the list meanwhile is not brought back.
                    guard current.state(of: id) != nil else { continue }
                    current.merge(events, of: id, over: slice, at: clock(), calendar: calendar)
                case .failure(let problem):
                    problems.append(problem)
                }
            }
            current.sortEvents(calendar: calendar)
            store(current, for: account.id, previous: previous, now: clock())
        }
        return report(SyncEngine.outcome(problems))
    }

    /// Writes one account's cache: the events, then the sync file, then the near file the
    /// widget reads. Readers take them in the opposite order (`CacheDirectory.account(_:)`).
    private func store(_ account: AccountCache, for id: AccountID, previous: AccountCache?, now: Date) {
        do {
            try cache.write(account, for: id, previous: previous)
            try cache.writeNear(
                account, for: id, days: SyncEngine.nearDays(today: CivilDate(now, in: calendar)),
                calendar: calendar)
        } catch {
            // The files keep what they held; the next refresh writes them again.
        }
    }

    private func report(
        _ outcome: SyncOutcome, data: CalendarData? = nil, newlySignedOut: [AccountID] = []
    ) -> SyncReport {
        SyncReport(
            outcome: outcome, data: data ?? load(), newlySignedOut: newlySignedOut,
            snapshot: WidgetSnapshot.read(from: cache))
    }

    /// Nothing, `Offline`, or `Couldn't reach Google`, from every account's problem.
    /// Signed-out accounts have their own line and do not count here.
    static func outcome(_ problems: [AccountProblem]) -> SyncOutcome {
        let failures = problems.compactMap { problem -> Bool? in
            if case .failed(let offline) = problem { return offline }
            return nil
        }
        return failures.isEmpty ? .current : failures.allSatisfy { $0 } ? .offline : .unreachable
    }

    // MARK: Days and windows

    /// What to fetch so the covered days reach `days`: at most one stretch on each side,
    /// each starting at the covered edge, so a request beyond a gap fills the gap too and the
    /// covered days stay one unbroken range.
    static func missing(
        _ days: ClosedRange<CivilDate>, from covered: ClosedRange<CivilDate>
    ) -> [ClosedRange<CivilDate>] {
        var slices: [ClosedRange<CivilDate>] = []
        if days.lowerBound < covered.lowerBound {
            slices.append(days.lowerBound...covered.lowerBound.adding(days: -1))
        }
        if days.upperBound > covered.upperBound {
            slices.append(covered.upperBound.adding(days: 1)...days.upperBound)
        }
        return slices
    }

    /// The two ranges as one, when they touch or overlap; nil when a gap lies between.
    public static func union(_ a: ClosedRange<CivilDate>, _ b: ClosedRange<CivilDate>)
        -> ClosedRange<CivilDate>?
    {
        guard a.lowerBound <= b.upperBound.adding(days: 1),
            b.lowerBound <= a.upperBound.adding(days: 1)
        else { return nil }
        return min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
    }

    /// Midnight at the start of the first day to midnight after the last, in `calendar`.
    static func interval(_ days: ClosedRange<CivilDate>, calendar: Calendar) -> DateInterval {
        DateInterval(
            start: days.lowerBound.date(in: calendar),
            end: days.upperBound.adding(days: 1).date(in: calendar))
    }

    /// Google's own test for `timeMin` and `timeMax`: ends after the start and starts before
    /// the end. A zero-length event at the start counts.
    static func overlaps(_ event: Event, _ range: DateInterval, calendar: Calendar) -> Bool {
        let span = event.time.interval(in: calendar)
        return span.start < range.end && (span.end > range.start || span.start >= range.start)
    }

    /// Runs `operation`, giving up with `SyncError.deadline` after `limit`. The operation is
    /// cancelled, which stops its URL requests at once.
    static func withDeadline<Value: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw SyncError.deadline
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SyncError.deadline }
            return first
        }
    }
}

/// What a fetch found and the cache now holds.
public struct SyncReport: Sendable {
    /// What the screen says about fetching: nothing, `Offline. Showing events as of 9:40.`,
    /// or `Couldn't reach Google. Showing events as of 9:40.`
    public var outcome: SyncOutcome
    /// Everything cached after the fetch, to draw from.
    public var data: CalendarData
    /// Accounts this fetch found signed out, for `Google signed out you@acme.com.`
    public var newlySignedOut: [AccountID]
    /// The widget's snapshot on disk after the fetch, which may be the widget's own when it
    /// was newer. The app reloads the widget only when this differs from what it last
    /// reloaded for.
    public var snapshot: WidgetSnapshot?

    public init(
        outcome: SyncOutcome, data: CalendarData, newlySignedOut: [AccountID] = [],
        snapshot: WidgetSnapshot? = nil
    ) {
        self.outcome = outcome
        self.data = data
        self.newlySignedOut = newlySignedOut
        self.snapshot = snapshot
    }
}

public enum SyncOutcome: Hashable, Sendable {
    /// Every signed-in account answered.
    case current
    /// The device has no network.
    case offline
    /// The network is there but Google did not answer, or answered with an error.
    case unreachable
}

public enum SyncError: Error, Hashable, Sendable {
    /// `GoogleClientID` holds the placeholder, so there is no client to sign in with.
    case noGoogleClient
    /// The widget's fetch ran out of time.
    case deadline
}
