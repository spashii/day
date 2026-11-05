import Foundation

/// Keeps this install's Google channels and its registration with the relay in step with the
/// accounts and calendars shown, in the order `push/README.md` asks for: register to get the
/// channel token, watch, then register again with the channels and their expiries.
///
/// `reconcile` is cheap when nothing is due (no network at all), so the app calls it after
/// every refresh, at launch and when a push token changes. Channels are renewed a day before
/// Google's expiry (`ChannelPlan`); a channel that lapses anyway, because the device was off,
/// is opened again by the next call. Every failure leaves what works in place and backs off:
/// the timers keep Day current meanwhile, so a missing channel only makes it slower.
///
/// Calls run one after another, so a removal never interleaves with a reconcile.
public actor PushCoordinator {
    public struct Tokens: Hashable, Sendable {
        /// The app's APNs token, hex. Without one nothing can wake this install, so no
        /// channel is opened.
        public var app: String?
        /// The Lock Screen widget's WidgetKit push token, hex; nil when not known here.
        public var widget: String?

        public init(app: String?, widget: String? = nil) {
            self.app = app
            self.widget = widget
        }
    }

    /// The relay is told the whole set again at least this often, which keeps its record of
    /// the install from going stale.
    static let reregisterAfter: TimeInterval = 24 * 3600

    let store: PushStore
    let server: PushServer
    let watcher: WatchClient
    let auth: GoogleAuth?
    let tokens: any TokenStore
    let platform: PushPlatform
    let environment: PushEnvironment
    let clock: @Sendable () -> Date
    private var serverWait: (until: Date, failures: Int)?
    private var tail: Task<Void, Never>?

    /// Uses the engine's own Google client, token store, folder and clock, so a channel is
    /// opened with exactly the sign-in the sync reads with. Two tries per Google call: a
    /// channel that fails is tried again on a later check anyway.
    public init(
        engine: SyncEngine, server: PushServer = PushServer(),
        platform: PushPlatform = .current, environment: PushEnvironment,
        retry: RetryPolicy = RetryPolicy(maxAttempts: 2)
    ) {
        store = PushStore(directory: engine.cache)
        self.server = server
        watcher = WatchClient(api: engine.api.with(retry: retry))
        auth = engine.auth?.with(retry: retry)
        tokens = engine.tokens
        self.platform = platform
        self.environment = environment
        clock = engine.clock
    }

    // MARK: Public calls

    /// Brings the channels and the registration in line with `wanted`. Returns when to call
    /// again at the latest (the next renewal or retry), or nil when nothing is pending.
    @discardableResult
    public func reconcile(_ wanted: WatchSet, tokens push: Tokens) async -> Date? {
        await serialized { await self.performReconcile(wanted, push) }
    }

    /// Stops `account`'s channels with Google using `token`, the account's sign-in while it
    /// is still valid, and tells the relay. With no token (the account was removed on another
    /// device, which revoked the grant) the channels are only dropped and lapse at Google's
    /// expiry. With `lastAccount`, the install is forgotten at the relay too.
    public func accountRemoved(_ account: AccountID, token: StoredToken?, lastAccount: Bool) async {
        await serialized {
            await self.performRemoval(account, token: token, lastAccount: lastAccount)
        }
    }

    /// Every account is gone: stops every channel this device can still stop, then asks the
    /// relay to forget the install. The install ID stays, so a new sign-in registers again.
    public func forget() async {
        await serialized { await self.performForget() }
    }

    /// Forgets the install only when the account file says, readably, that no account is
    /// left. A file that cannot be read yet (before the first unlock) also shows no accounts
    /// to the app, and must not stop a single channel.
    public func forgetIfNoAccounts() async {
        guard store.directory.read([Account].self, from: CacheFile.accounts)?.isEmpty == true
        else { return }
        await forget()
    }

    /// The widget's token as its extension last saved it.
    public nonisolated var savedWidgetToken: String? {
        store.widgetToken()
    }

    /// The channels open now, for tests and the brief's numbers.
    public var openChannels: [WatchedChannel] {
        store.state().channels
    }

    private func serialized<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    // MARK: Reconcile

    private func performReconcile(_ wanted: WatchSet, _ push: Tokens) async -> Date? {
        let now = clock()
        guard push.app != nil, auth != nil else { return nil }
        if let wait = serverWait, now < wait.until { return wait.until }
        guard let install = try? store.install() else { return nil }
        let stored = store.state()
        var state = stored
        state.pendingDelete = false
        defer { if state != stored { store.save(state) } }

        if state.channelToken == nil {
            guard await register(install, push, channels: nil, state: &state) else {
                return serverWait?.until
            }
        }
        // A second pass only when the relay answered the final registration with another
        // channel token than the channels carry, which happens once after its key changes.
        for _ in 0..<2 {
            guard let token = state.channelToken else { break }
            await applyPlan(wanted, token: token, now: clock(), state: &state)
            if needsRegistration(state, push, now: clock()) {
                _ = await register(install, push, channels: state.channels, state: &state)
            }
            if state.channels.allSatisfy({ $0.token == state.channelToken }) { break }
        }
        return nextCheck(state, now: clock())
    }

    /// Opens, renews and stops channels per `ChannelPlan`. The relay hears of the new set
    /// through `needsRegistration`, which compares it with the last one registered.
    private func applyPlan(
        _ wanted: WatchSet, token: String, now: Date, state: inout PushState
    ) async {
        state.waiting.removeAll { $0.until <= now && !wanted.targets.contains($0.target) }
        let waiting = Set(state.waiting.filter { $0.until > now }.map(\.target))
        let plan = ChannelPlan.make(
            wanted: wanted, channels: state.channels, token: token, now: now, waiting: waiting)
        guard !plan.isEmpty else { return }

        var channels = state.channels.filter { !plan.expired.contains($0) }
        var leaving = plan.stop
        let results = await open(plan.watch, token: token, now: now)
        for target in plan.watch {
            switch results[target] {
            case .success(let channel):
                channels.append(channel)
                if let old = plan.replacing[target] { leaving.append(old) }
                state.waiting.removeAll { $0.target == target }
            case .failure(let error):
                wait(target, after: error, now: now, state: &state)
            case nil:
                break
            }
        }
        channels.removeAll { leaving.contains($0) }
        state.channels = channels
        // Saved before the stops, so an app ended mid-way still knows what it opened.
        store.save(state)
        await stop(leaving, tokens: storedTokens(for: leaving))
    }

    /// Opens a channel on each target, every account's at once, each with that account's
    /// access token.
    private func open(_ targets: [WatchTarget], token: String, now: Date) async
        -> [WatchTarget: Result<WatchedChannel, any Error>]
    {
        guard let auth, !targets.isEmpty else { return [:] }
        let byAccount = Dictionary(grouping: targets, by: \.account)
        var authorizers: [AccountID: AccountAuthorizer] = [:]
        var results: [WatchTarget: Result<WatchedChannel, any Error>] = [:]
        for (account, list) in byAccount {
            do {
                guard let stored = try tokens.token(for: account) else {
                    throw OAuthError.invalidGrant(subtype: nil)
                }
                authorizers[account] = AccountAuthorizer(
                    account: account, token: stored, auth: auth, tokens: tokens, clock: clock)
            } catch {
                for target in list { results[target] = .failure(error) }
            }
        }
        let watcher = watcher
        let address = server.webhook
        await withTaskGroup(of: (WatchTarget, Result<WatchedChannel, any Error>).self) { group in
            for target in targets {
                guard let authorizer = authorizers[target.account] else { continue }
                group.addTask {
                    let id = UUID().uuidString.lowercased()
                    do {
                        let opened = try await authorizer.authorized { access in
                            try await watcher.watch(
                                target, channelID: id, token: token, address: address,
                                accessToken: access)
                        }
                        let millis = opened.expiration.flatMap { Int64($0) }
                            ?? Int64((now.timeIntervalSince1970 + 6 * 3600) * 1000)
                        return (
                            target,
                            .success(
                                WatchedChannel(
                                    id: opened.id, resourceID: opened.resourceId, target: target,
                                    token: token, created: now, expirationMillis: millis))
                        )
                    } catch {
                        return (target, .failure(error))
                    }
                }
            }
            for await (target, result) in group { results[target] = result }
        }
        return results
    }

    /// The sign-in of each account in `channels` that this device still holds.
    private func storedTokens(for channels: [WatchedChannel]) -> [AccountID: StoredToken] {
        var found: [AccountID: StoredToken] = [:]
        for account in Set(channels.map(\.target.account)) {
            if let stored = try? tokens.token(for: account) { found[account] = stored }
        }
        return found
    }

    /// Stops channels with Google, best effort: a channel whose account has no token in
    /// `signIns`, or whose stop fails, simply lapses at its expiry.
    private func stop(_ channels: [WatchedChannel], tokens signIns: [AccountID: StoredToken]) async {
        guard let auth else { return }
        let watcher = watcher
        let tokens = tokens
        let clock = clock
        await withTaskGroup(of: Void.self) { group in
            for (account, list) in Dictionary(grouping: channels, by: \.target.account) {
                guard let stored = signIns[account] else { continue }
                let authorizer = AccountAuthorizer(
                    account: account, token: stored, auth: auth, tokens: tokens, clock: clock)
                for channel in list {
                    group.addTask {
                        _ = try? await authorizer.authorized { access in
                            try await watcher.stop(channel, accessToken: access)
                        }
                    }
                }
            }
        }
    }

    /// Backs a target off after a failed watch: a minute and doubling up to an hour for what
    /// clears by itself (network, Google busy), an hour and doubling up to a day for what
    /// needs a change first (the calendar cannot be watched, the sign-in was refused).
    private func wait(_ target: WatchTarget, after error: any Error, now: Date, state: inout PushState) {
        let failures = (state.waiting.first { $0.target == target }?.failures ?? 0) + 1
        let transient: Bool =
            switch error {
            case CalendarAPIError.unavailable, CalendarAPIError.malformed, is URLError: true
            default: false
            }
        let base: TimeInterval = transient ? 60 : 3600
        let cap: TimeInterval = transient ? 3600 : 24 * 3600
        let delay = min(base * pow(2, Double(min(failures - 1, 10))), cap)
        state.waiting.removeAll { $0.target == target }
        state.waiting.append(
            PushState.Waiting(target: target, until: now.addingTimeInterval(delay), failures: failures))
    }

    // MARK: Registration

    private func needsRegistration(_ state: PushState, _ push: Tokens, now: Date) -> Bool {
        guard let last = state.registered else { return true }
        return last.app != push.app
            || (push.widget != nil && last.widget != push.widget)
            || last.environment != environment
            || last.channels != state.channels.map(\.id).sorted()
            || now.timeIntervalSince(last.at) >= Self.reregisterAfter
            || now < last.at
    }

    /// One `POST /day/devices`. With `channels` nil the relay keeps its set; the tokens are
    /// set when known and otherwise left as the relay has them. Returns whether it answered.
    @discardableResult
    private func register(
        _ install: String, _ push: Tokens, channels: [WatchedChannel]?, state: inout PushState
    ) async -> Bool {
        let registration = PushRegistration(
            install: install, platform: platform, environment: environment,
            app: push.app.map(PushRegistration.Token.set) ?? .keep,
            widget: push.widget.map(PushRegistration.Token.set) ?? .keep,
            channels: channels)
        do {
            let token = try await server.register(registration)
            serverWait = nil
            state.channelToken = token
            let previous = state.registered
            state.registered = PushState.Registered(
                app: push.app ?? previous?.app, widget: push.widget ?? previous?.widget,
                environment: environment,
                channels: (channels ?? []).map(\.id).sorted(), at: clock())
            return true
        } catch {
            let failures = (serverWait?.failures ?? 0) + 1
            let delay = min(60 * pow(2, Double(min(failures - 1, 10))), 3600)
            serverWait = (clock().addingTimeInterval(delay), failures)
            return false
        }
    }

    private func nextCheck(_ state: PushState, now: Date) -> Date? {
        var dates = state.waiting.map(\.until)
        if let renewal = ChannelPlan.nextRenewal(of: state.channels) { dates.append(renewal) }
        if let last = state.registered { dates.append(last.at.addingTimeInterval(Self.reregisterAfter)) }
        if let wait = serverWait { dates.append(wait.until) }
        return dates.map { max($0, now) }.min()
    }

    // MARK: Removal

    private func performRemoval(_ account: AccountID, token: StoredToken?, lastAccount: Bool) async {
        var state = store.state()
        let leaving = state.channels.filter { $0.target.account == account }
        state.channels.removeAll { $0.target.account == account }
        state.waiting.removeAll { $0.target.account == account }
        store.save(state)
        if let token { await stop(leaving, tokens: [account: token]) }
        if lastAccount {
            await performForget()
        } else if !leaving.isEmpty, state.registered != nil, let install = store.existingInstall() {
            _ = await register(install, Tokens(app: nil), channels: state.channels, state: &state)
            store.save(state)
        }
    }

    private func performForget() async {
        var state = store.state()
        guard !state.channels.isEmpty || state.registered != nil || state.pendingDelete else {
            return
        }
        await stop(state.channels, tokens: storedTokens(for: state.channels))
        state = PushState(pendingDelete: true)
        store.save(state)
        guard let install = store.existingInstall() else {
            store.save(PushState())
            return
        }
        do {
            try await server.delete(install: install)
            store.save(PushState())
        } catch {
            // Kept as pending: the next call with no accounts asks again.
        }
    }
}
