import Foundation

/// Fetches every account's calendars from Google and keeps the cache files and the widget
/// snapshot current. The real store draws from `load()` at once and calls `refresh()` on
/// launch, return to foreground, pull to refresh, Command-R and the Mac's timer; views never
/// wait on it.
///
/// A refresh, per account and in parallel: a valid access token (refreshing it when it has
/// under a minute left), `calendarList.list`, `calendars.get` for labels once a day, then,
/// after shared calendars are folded to one account, `events.list` for each visible calendar
/// over today minus 35 days through today plus 120. One account failing never touches
/// another: `invalid_grant` or a missing calendar scope marks only that account signed out,
/// and its cached events stay on screen.
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

    /// Today minus 35 days through today plus 120: the month's rows above and below, without
    /// ever asking Google to expand endless series without a bound.
    public static func defaultWindow(today: CivilDate) -> ClosedRange<CivilDate> {
        today.adding(days: -35)...today.adding(days: 120)
    }

    // MARK: Reading

    /// Everything cached, read straight from disk. Safe from any thread and fast enough for
    /// launch, which draws from it before any fetch.
    public nonisolated func load() -> CalendarData {
        SyncEngine.load(from: cache)
    }

    static func load(from cache: CacheDirectory) -> CalendarData {
        let accounts = cache.read([Account].self, from: CacheFile.accounts) ?? []
        var data = CalendarData(
            accounts: accounts,
            visibility: cache.read(CalendarVisibility.self, from: CacheFile.visibility)
                ?? CalendarVisibility())
        for account in accounts {
            if let file = cache.read(CalendarsFile.self, from: CacheFile.calendars(account.id)) {
                data.calendarsByAccount[account.id] = file.calendars
            }
            if let file = cache.read(EventsFile.self, from: CacheFile.events(account.id)) {
                data.eventsByAccount[account.id] = file.events
                data.fetchedAtByAccount[account.id] = file.fetchedAt
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

    /// Forgets the account on this device: its tokens, calendars, events and toggles.
    /// Nothing changes in Google.
    public func removeAccount(_ id: AccountID) throws {
        try tokens.removeToken(for: id)
        var accounts = cache.read([Account].self, from: CacheFile.accounts) ?? []
        accounts.removeAll { $0.id == id }
        try cache.write(accounts, to: CacheFile.accounts)
        cache.remove(CacheFile.calendars(id))
        cache.remove(CacheFile.events(id))
        var visibility = cache.read(CalendarVisibility.self, from: CacheFile.visibility)
            ?? CalendarVisibility()
        visibility.forget(id)
        try cache.write(visibility, to: CacheFile.visibility)
        generation += 1
        writeWidgetSnapshot(force: true)
    }

    /// The person's toggle for one calendar. Showing a calendar that has never been fetched
    /// needs a `refresh()` before its events appear.
    public func setVisible(_ visible: Bool, calendar id: CalendarID) throws {
        var visibility = cache.read(CalendarVisibility.self, from: CacheFile.visibility)
            ?? CalendarVisibility()
        visibility.set(visible, for: id)
        try cache.write(visibility, to: CacheFile.visibility)
        generation += 1
        writeWidgetSnapshot(force: true)
    }

    /// Rebuilds the widget snapshot from the cache and writes it (newer wins unless
    /// `force`). Returns the snapshot when it was written. The app then reloads the widget's
    /// timelines.
    @discardableResult
    public func writeWidgetSnapshot(force: Bool = false) -> WidgetSnapshot? {
        guard let snapshot = load().widgetSnapshot(now: clock(), calendar: calendar),
            (try? snapshot.write(to: cache, force: force)) == true
        else { return nil }
        return snapshot
    }

    // MARK: Refresh

    /// Fetches every signed-in account again and rewrites the cache and the snapshot.
    /// Calls that arrive while one is running share its result, unless accounts or
    /// visibility changed since it started.
    public func refresh() async -> SyncReport {
        while let running = inFlight {
            let report = await running.task.value
            if inFlight?.task == running.task { inFlight = nil }
            if running.generation == generation { return report }
        }
        let task = Task { await self.performRefresh() }
        inFlight = (task, generation)
        let report = await task.value
        if inFlight?.task == task { inFlight = nil }
        return report
    }

    /// Fetches the days of `days` the cache does not cover yet, for the Month scrolling past
    /// the window. Days already covered are not fetched again.
    public func extendWindow(toInclude days: ClosedRange<CivilDate>) async -> SyncReport {
        if let running = inFlight { _ = await running.task.value }
        return await performExtension(days)
    }

    private func performRefresh() async -> SyncReport {
        let now = clock()
        let start = load()
        guard let auth else { return SyncReport(outcome: .current, data: start) }
        let window = SyncEngine.defaultWindow(today: CivilDate(now, in: calendar))
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

        // Calendar lists and labels, all accounts at once.
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

        // Shared calendars fold to one account; only visible calendars are fetched.
        var calendarLists = start.calendarsByAccount
        for (id, file) in lists { calendarLists[id] = file.calendars }
        let visibility = cache.read(CalendarVisibility.self, from: CacheFile.visibility)
            ?? CalendarVisibility()
        let kept = CalendarData.deduplicated(start.accounts.map { calendarLists[$0.id] ?? [] })
        let range = SyncEngine.interval(window, calendar: calendar)

        var fetched: [AccountID: AccountEvents] = [:]
        await withTaskGroup(of: (AccountID, Result<AccountEvents, AccountProblem>).self) { group in
            for id in lists.keys {
                guard let authorizer = authorizers[id] else { continue }
                let wanted = kept.filter { $0.id.account == id && visibility.isVisible($0) }
                group.addTask { [api] in
                    do {
                        let events = try await SyncEngine.fetchEvents(
                            calendars: wanted, range: range, authorizer: authorizer, api: api)
                        return (id, .success(events))
                    } catch {
                        return (id, .failure(AccountProblem(error)))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let events): fetched[id] = events
                case .failure(let problem): problems[id] = problem
                }
            }
        }

        // Write each account's file from the current file on disk, with no suspension
        // between reading and writing, so a concurrent window extension is never lost.
        for (id, result) in fetched where accountsNow.contains(id) {
            let previous = cache.read(EventsFile.self, from: CacheFile.events(id))
            let listed = Set(kept.filter { $0.id.account == id }.map(\.id))
            let file = SyncEngine.updated(
                previous, with: result, listed: listed, window: window, fetchedAt: now,
                calendar: calendar)
            try? cache.write(file, to: CacheFile.events(id))
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
            _ = try? snapshot.write(to: cache)
        }
        let failures = problems.values.compactMap { problem -> Bool? in
            if case .failed(let offline) = problem { return offline }
            return nil
        }
        let outcome: SyncOutcome =
            failures.isEmpty ? .current : failures.allSatisfy { $0 } ? .offline : .unreachable
        return SyncReport(outcome: outcome, data: data, newlySignedOut: newlySignedOut)
    }

    private func performExtension(_ days: ClosedRange<CivilDate>) async -> SyncReport {
        let start = load()
        guard let auth else { return SyncReport(outcome: .current, data: start) }
        let kept = start.calendars.filter { start.visibility.isVisible($0) }
        var problems: [AccountProblem] = []
        for account in start.accounts where !account.signedOut {
            guard let previous = cache.read(EventsFile.self, from: CacheFile.events(account.id))
            else { continue }
            let slices = SyncEngine.missing(days, from: previous.window)
            guard !slices.isEmpty else { continue }
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
            let wanted = kept.filter { $0.id.account == account.id }
            for slice in slices {
                do {
                    let result = try await SyncEngine.fetchEvents(
                        calendars: wanted, range: SyncEngine.interval(slice, calendar: calendar),
                        authorizer: authorizer, api: api)
                    guard
                        let current = cache.read(EventsFile.self, from: CacheFile.events(account.id))
                    else { break }
                    let listed = Set(start.calendars.filter { $0.id.account == account.id }.map(\.id))
                    let file = SyncEngine.updated(
                        current, with: result, listed: listed, window: slice,
                        fetchedAt: current.fetchedAt, calendar: calendar)
                    try? cache.write(file, to: CacheFile.events(account.id))
                } catch {
                    problems.append(AccountProblem(error))
                    break
                }
            }
        }
        let failures = problems.compactMap { problem -> Bool? in
            if case .failed(let offline) = problem { return offline }
            return nil
        }
        let outcome: SyncOutcome =
            failures.isEmpty ? .current : failures.allSatisfy { $0 } ? .offline : .unreachable
        return SyncReport(outcome: outcome, data: load())
    }

    // MARK: Widget, stage two

    /// The widget's own fetch: when the snapshot is older than `maxAge`, fetch today through
    /// eight days ahead for every visible calendar, one try per call and the whole fetch cut
    /// off at `deadline`, then write the snapshot (newer wins). Falls back to the snapshot
    /// on disk on any failure, which may be nil when the app has never written one. Reads
    /// the app's files but writes only the snapshot and refreshed tokens.
    public func refreshWidgetSnapshot(
        maxAge: TimeInterval = WidgetSnapshot.freshFor, deadline: Duration = .seconds(5)
    ) async -> WidgetSnapshot? {
        let now = clock()
        let existing = WidgetSnapshot.read(from: cache)
        if let existing, existing.isFresh(at: now, maxAge: maxAge) { return existing }
        let data = load()
        guard let auth, !data.accounts.isEmpty else { return existing }

        let days = WidgetSnapshot.days(from: CivilDate(now, in: calendar))
        let range = SyncEngine.interval(days, calendar: calendar)
        let shown = data.calendars.filter { data.visibility.isVisible($0) }
        let quickAuth = auth.with(retry: .once)
        let quickAPI = api.with(retry: .once)
        var authorizers: [AccountID: AccountAuthorizer] = [:]
        var fresh = data
        for (i, account) in data.accounts.enumerated() where !account.signedOut {
            let stored: StoredToken?
            do {
                stored = try tokens.token(for: account.id)
            } catch {
                // The keychain is unreadable (before first unlock): keep what is on disk.
                return existing
            }
            guard let token = stored else {
                fresh.accounts[i].signedOut = true
                continue
            }
            authorizers[account.id] = AccountAuthorizer(
                account: account.id, token: token, auth: quickAuth, tokens: tokens, clock: clock)
        }
        guard !authorizers.isEmpty else {
            return existing ?? fresh.widgetSnapshot(now: now, calendar: calendar)
        }

        let work = authorizers
        do {
            let results = try await SyncEngine.withDeadline(deadline) {
                try await withThrowingTaskGroup(of: (AccountID, AccountEvents?).self) { group in
                    for (id, authorizer) in work {
                        let wanted = shown.filter { $0.id.account == id }
                        group.addTask {
                            do {
                                return (
                                    id,
                                    try await SyncEngine.fetchEvents(
                                        calendars: wanted, range: range, authorizer: authorizer,
                                        api: quickAPI)
                                )
                            } catch {
                                // Signed out shows as a count on line 3; anything else falls
                                // back to the snapshot on disk.
                                guard AccountProblem(error) == .signedOut else { throw error }
                                return (id, nil)
                            }
                        }
                    }
                    var results: [AccountID: AccountEvents?] = [:]
                    for try await (id, events) in group { results.updateValue(events, forKey: id) }
                    return results
                }
            }
            for (id, events) in results {
                if let events {
                    fresh.eventsByAccount[id] = events.events
                } else if let i = fresh.accounts.firstIndex(where: { $0.id == id }) {
                    fresh.accounts[i].signedOut = true
                }
            }
            let snapshot = WidgetSnapshot(
                fetchedAt: now,
                accountCount: fresh.accounts.count,
                signedOutAccounts: fresh.accounts.filter(\.signedOut).count,
                events: fresh.events(in: days, calendar: calendar))
            if (try? snapshot.write(to: cache)) == true { return snapshot }
            return WidgetSnapshot.read(from: cache) ?? snapshot
        } catch {
            return existing
        }
    }

    // MARK: Fetching, off the actor

    /// One account's calendar list, with labels read again once a day and for any calendar
    /// not seen before. A label read that fails keeps the labels already known.
    static func fetchCalendarList(
        account: AccountID, authorizer: AccountAuthorizer, api: CalendarAPI,
        previous: CalendarsFile?, now: Date
    ) async throws -> CalendarsFile {
        let entries = try await authorizer.authorized { try await api.calendarList(accessToken: $0) }
        var labels: [String: [String: LabelInfo]] = [:]
        for info in previous?.calendars ?? [] { labels[info.id.googleID] = info.labels }
        let stale = previous?.labelsFetchedAt.map { !(0..<86_400).contains(now.timeIntervalSince($0)) }
            ?? true
        let wanted = entries.filter {
            GoogleDecoding.mayHaveLabels($0) && (stale || labels[$0.id] == nil)
        }
        await withTaskGroup(of: (String, [String: LabelInfo]?).self) { group in
            for entry in wanted {
                group.addTask {
                    let resource = try? await authorizer.authorized {
                        try await api.calendar(entry.id, accessToken: $0)
                    }
                    return (entry.id, resource.map(GoogleDecoding.labels))
                }
            }
            for await (id, found) in group {
                if let found { labels[id] = found }
            }
        }
        return CalendarsFile(
            fetchedAt: now,
            labelsFetchedAt: stale ? now : previous?.labelsFetchedAt,
            calendars: GoogleDecoding.calendars(entries, account: account, labels: labels))
    }

    /// Events for `calendars` over `range`, all calendars at once. A calendar Google no
    /// longer lets this account read (gone, or a 403 `forbidden`) comes back empty rather than
    /// failing the account. Any other failure, including a project-wide 403 such as
    /// `accessNotConfigured`, throws, so the account keeps its cached events and the screen
    /// says `Couldn't reach Google`.
    static func fetchEvents(
        calendars: [CalendarInfo], range: DateInterval, authorizer: AccountAuthorizer,
        api: CalendarAPI
    ) async throws -> AccountEvents {
        try await withThrowingTaskGroup(of: (CalendarID, [Event]).self) { group in
            for info in calendars {
                group.addTask {
                    do {
                        let google = try await authorizer.authorized {
                            try await api.events(
                                calendarID: info.id.googleID, from: range.start, to: range.end,
                                accessToken: $0)
                        }
                        return (info.id, GoogleDecoding.events(google, on: info))
                    } catch let error as CalendarAPIError where error.meansCalendarUnreadable {
                        return (info.id, [])
                    }
                }
            }
            var result = AccountEvents(events: [], calendars: [])
            for try await (id, events) in group {
                result.calendars.insert(id)
                result.events += events
            }
            return result
        }
    }

    /// The account's new file: what was fetched, plus the old events still worth keeping
    /// (outside the fetched days, or on listed calendars not fetched this time, such as
    /// hidden ones, so showing them again is instant). Calendars gone from the list drop out.
    static func updated(
        _ previous: EventsFile?, with result: AccountEvents, listed: Set<CalendarID>,
        window: ClosedRange<CivilDate>, fetchedAt: Date, calendar: Calendar
    ) -> EventsFile {
        let fetchedRange = interval(window, calendar: calendar)
        var covered = window
        if let old = previous?.window,
            old.lowerBound <= window.upperBound.adding(days: 1),
            window.lowerBound <= old.upperBound.adding(days: 1)
        {
            covered = min(old.lowerBound, window.lowerBound)...max(old.upperBound, window.upperBound)
        }
        let coveredRange = interval(covered, calendar: calendar)
        let kept = (previous?.events ?? []).filter { event in
            guard listed.contains(event.id.calendar),
                overlaps(event, coveredRange, calendar: calendar)
            else { return false }
            return !result.calendars.contains(event.id.calendar)
                || !overlaps(event, fetchedRange, calendar: calendar)
        }
        var seen = Set<EventID>()
        let events = (result.events + kept)
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let l = lhs.time.start(in: calendar)
                let r = rhs.time.start(in: calendar)
                return l != r ? l < r : lhs.id < rhs.id
            }
        return EventsFile(fetchedAt: fetchedAt, window: covered, events: events)
    }

    /// The parts of `days` outside `covered`, at most one on each side.
    static func missing(
        _ days: ClosedRange<CivilDate>, from covered: ClosedRange<CivilDate>
    ) -> [ClosedRange<CivilDate>] {
        var slices: [ClosedRange<CivilDate>] = []
        if days.lowerBound < covered.lowerBound {
            slices.append(days.lowerBound...min(days.upperBound, covered.lowerBound.adding(days: -1)))
        }
        if days.upperBound > covered.upperBound {
            slices.append(max(days.lowerBound, covered.upperBound.adding(days: 1))...days.upperBound)
        }
        return slices
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

    public init(outcome: SyncOutcome, data: CalendarData, newlySignedOut: [AccountID] = []) {
        self.outcome = outcome
        self.data = data
        self.newlySignedOut = newlySignedOut
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

/// One account's fetched events and the calendars they came from.
struct AccountEvents: Sendable {
    var events: [Event]
    var calendars: Set<CalendarID>
}

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

    /// A token with more than a minute left, never `rejected`.
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
        let refreshed = try await task.value
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
