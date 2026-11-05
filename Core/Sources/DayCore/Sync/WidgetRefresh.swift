import Foundation

// MARK: - Widget, stage two

extension SyncEngine {
    /// The widget's own read, on every timeline reload: for each visible calendar, the
    /// changes since the app's sync token when its window holds the widget's days, else
    /// those days by window, all cut off at `deadline` with one try per call. The changes are
    /// laid over the app's cached events in memory and only the snapshot is written (newer
    /// wins). The app's files and tokens are never written here, so the app stays the one
    /// writer of its cache, and its next refresh reads the same changes again from the same
    /// token, which is harmless.
    ///
    /// The events and tokens come from the app's near file, a few days of events in one small
    /// file, so a reload decodes kilobytes and not the whole five-month cache. Only an account
    /// with no usable near file is read in full.
    ///
    /// A snapshot under `maxAge` old comes back as it is, which spares the reload the app
    /// asks for right after writing one. On a deadline or any failure that is not Google
    /// refusing the grant, the snapshot on disk is what renders; it is nil when the app never
    /// wrote one. Whether an account is signed out is the app's to decide from its own
    /// refresh, which compares the refresh token it used with the one in the keychain; a
    /// token the widget cannot find proves nothing, since the keychain answers the same way
    /// when the extension cannot see the app's items.
    public func refreshWidgetSnapshot(
        maxAge: TimeInterval = WidgetSnapshot.freshFor, deadline: Duration = .seconds(5)
    ) async -> WidgetSnapshot? {
        let now = clock()
        let existing = WidgetSnapshot.read(from: cache)
        if let existing, existing.isFresh(at: now, maxAge: maxAge) { return existing }
        let days = WidgetSnapshot.days(from: CivilDate(now, in: calendar))
        var data = loadForWidget(days: days)
        guard let auth, !data.accounts.isEmpty else { return existing }

        let range = SyncEngine.interval(days, calendar: calendar)
        let shown = data.calendars.filter { data.visibility.isVisible($0) }
        let quickAuth = auth.with(retry: .once)
        let quickAPI = api.with(retry: .once)
        var work: [(account: AccountID, authorizer: AccountAuthorizer, plans: [(CalendarInfo, String?)])] = []
        // Whether this read found anything the snapshot on disk does not say.
        var learned = false
        for account in data.accounts where !account.signedOut {
            let stored: StoredToken?
            do {
                stored = try tokens.token(for: account.id)
            } catch {
                // The keychain is unreadable (before first unlock): keep what is on disk.
                return existing
            }
            // No item: this account keeps the app's events and its place in the snapshot, and
            // the others are still read. The widget does not decide an account is signed out
            // from a missing item.
            guard let token = stored else { continue }
            let states = data.syncByAccount[account.id] ?? []
            let plans = shown.filter { $0.id.account == account.id }.map { info in
                // The app's token serves only when its window and covered days hold the
                // widget's days; its age does not matter here, since the daily full read is
                // the app's to make.
                let usable = states.first { $0.calendar == info.id }.flatMap { state in
                    state.tokenFrom <= range.start && state.tokenTo >= range.end
                        && state.from <= days.lowerBound && state.through >= days.upperBound
                        ? state.token : nil
                }
                return (info, usable)
            }
            work.append(
                (
                    account.id,
                    AccountAuthorizer(
                        account: account.id, token: token, auth: quickAuth, tokens: tokens,
                        clock: clock),
                    plans
                ))
        }
        guard !work.isEmpty else {
            return existing ?? data.widgetSnapshot(now: now, calendar: calendar)
        }

        let jobs = work
        let results: [AccountID: Result<[CalendarID: WidgetFetchResult], AccountProblem>]
        do {
            results = try await SyncEngine.withDeadline(deadline) {
                await withTaskGroup(
                    of: (AccountID, Result<[CalendarID: WidgetFetchResult], AccountProblem>).self
                ) { group in
                    for job in jobs {
                        group.addTask {
                            do {
                                var found: [CalendarID: WidgetFetchResult] = [:]
                                try await withThrowingTaskGroup(
                                    of: (CalendarID, WidgetFetchResult).self
                                ) { calendars in
                                    for (info, token) in job.plans {
                                        calendars.addTask {
                                            let result = try await SyncEngine.fetchForWidget(
                                                info, token: token, days: range,
                                                authorizer: job.authorizer, api: quickAPI)
                                            return (info.id, result)
                                        }
                                    }
                                    for try await (id, result) in calendars { found[id] = result }
                                }
                                return (job.account, .success(found))
                            } catch {
                                return (job.account, .failure(AccountProblem(error)))
                            }
                        }
                    }
                    var all: [AccountID: Result<[CalendarID: WidgetFetchResult], AccountProblem>] = [:]
                    for await (id, result) in group { all[id] = result }
                    return all
                }
            }
        } catch {
            return existing
        }

        for (id, result) in results {
            switch result {
            case .success(let found):
                var account = AccountCache(
                    fetchedAt: data.fetchedAtByAccount[id], events: data.eventsByAccount[id] ?? [],
                    sync: data.syncByAccount[id] ?? [])
                for (calendarID, fetched) in found {
                    switch fetched {
                    case .changes(let changes):
                        let covered = account.state(of: calendarID)?.days ?? days
                        account.applyChanges(changes, to: calendarID, within: covered, calendar: calendar)
                    case .window(let events):
                        account.merge(events, of: calendarID, over: days, at: now, calendar: calendar)
                    case .unreadable:
                        account.forget(calendarID)
                    }
                }
                data.eventsByAccount[id] = account.events
                data.fetchedAtByAccount[id] = now
                learned = true
            case .failure(.signedOut):
                // Shows as a count on line 3; its cached events stay.
                if let i = data.accounts.firstIndex(where: { $0.id == id }) {
                    data.accounts[i].signedOut = true
                    learned = true
                }
            case .failure:
                // Keeps its cached events and the age they have.
                break
            }
        }
        guard learned else { return existing }
        guard let snapshot = data.widgetSnapshot(now: now, calendar: calendar) else { return existing }
        if (try? snapshot.write(to: cache, now: now)) == true { return snapshot }
        return WidgetSnapshot.read(from: cache) ?? snapshot
    }
}
