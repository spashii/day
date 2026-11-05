import AuthenticationServices
import DayCore
import Foundation
import Network
import Observation
import OSLog
// WebAuthenticationSession comes from the AuthenticationServices and SwiftUI overlay.
import SwiftUI

#if os(iOS)
    import WidgetKit
#else
    import AppKit
#endif

/// The real `CalendarStore`: Google's calendars through `SyncEngine`, drawn from the cache at
/// once and refreshed behind the screen. Views never wait on the network, and nothing here
/// spins over data that is already on screen.
///
/// What it does, and when (`docs/SYNC.md` has the costs and the limits):
/// - Launch: reads the cache synchronously in `init`, so the first frame already knows the
///   accounts (the first-run screen is decided from them) and shows cached events.
/// - Refresh: `sceneDidBecomeActive()` on launch and return to the foreground, `refresh()` for
///   pull to refresh and Command-R, every 3 minutes while running, on the Mac after wake, and
///   when the network comes back. Each one reads only what changed since the last (the
///   engine's sync tokens), so a refresh that finds nothing costs one small call per
///   calendar. As the app leaves, `sceneDidEnterBackground()` reads the widget's days inside
///   the few seconds the system grants, unless a refresh began within the last minute;
///   `refreshInBackground()` is the background refresh task's body, which has 20 seconds and
///   stops when the system cancels it.
/// - The widget: its timelines are reloaded only when the snapshot changed in a way it shows
///   (`WidgetSnapshot.needsReload`), so the daily reload budget goes to real changes.
/// - Toggles and removal apply on screen at once and are written by the engine in order, so
///   the person's last toggle always wins and the widget fetches what the app shows.
/// - The Month scrolling past the covered days asks `events(in:)` for days the cache does not
///   hold; the model then fetches the missing stretch on its own, in steps of about six
///   months, so a fast scroll never asks Google for years at once.
/// - The clock: `now` advances each minute on the minute and again after the device clock,
///   zone or locale changes, so every surface that reads it stays correct.
///
/// `FixtureStore` stands in while no Google client exists (`AppModel.live()` returns nil
/// then).
@MainActor
@Observable
final class AppModel: CalendarStore {
    // MARK: CalendarStore

    var accounts: [Account] { derived.data.accounts }
    var calendars: [CalendarInfo] { derived.calendars }
    var lastFetchedAt: Date? { derived.data.lastFetchedAt }
    private(set) var now: Date
    private(set) var calendar: Calendar

    /// What the screen says about fetching. Every refresh's outcome shows until the next good
    /// one; `Loading…` shows only while a signed-in account has never been fetched.
    var status: StoreStatus {
        switch outcome {
        case .offline:
            return .offline
        case .unreachable:
            return .unreachable
        case .current, nil:
            // An account that arrived from another device waits here too, until its first read.
            let waiting = accounts.contains {
                !$0.signedOut && derived.data.fetchedAtByAccount[$0.id] == nil
            }
            return waiting ? .loading : .current
        }
    }

    // MARK: State

    /// The last refresh's answer; nil before the first one finishes.
    private(set) var outcome: SyncOutcome?
    private var derived: Derived

    // Bookkeeping that views never read, so changing it never redraws and is safe to touch
    // from `events(in:)` while a view's body runs.
    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let reloadWidgets: @MainActor () -> Void
    @ObservationIgnored private let autoRefreshInterval: Duration?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Engine writes, one after the other: a toggle, a removal, then the next toggle.
    @ObservationIgnored private var writes: Task<Void, Never>?
    /// Changes shown on screen that the engine has not written yet. A refresh that finishes
    /// in between must not draw them away again.
    @ObservationIgnored private var pendingVisibility: [CalendarID: PendingToggle] = [:]
    @ObservationIgnored private var pendingRemovals: Set<AccountID> = []
    /// Counts every change of accounts or toggles, once when it is made and once when the
    /// engine has written it. A fetch that finished while the count moved read the files
    /// before the change landed, so its answer is not drawn as it is.
    @ObservationIgnored private var changes = 0
    @ObservationIgnored private var lastRefreshAttempt: Date?
    @ObservationIgnored private var windowFetch: Task<Void, Never>?
    @ObservationIgnored private var extensionRetryAfter = Date.distantPast
    /// The snapshot the widget was last told to reload for, in this run. Nil until the first
    /// reload, so a new run reloads once.
    @ObservationIgnored private var reloadedFor: WidgetSnapshot?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// Whether the network was there at the last path update; nil before the first.
    @ObservationIgnored private var networkSatisfied: Bool?

    /// Refreshing again within this many seconds of the last try is skipped when the trigger
    /// is only the app coming to the front, so flicking between apps costs no requests. The
    /// same span spares the read of the widget's days as the app leaves: a visit that began
    /// with a refresh costs one round of requests, not two.
    static let foregroundThrottle: TimeInterval = 60
    /// How long the background task spends on one refresh. The system gives such a task about
    /// thirty seconds and ends the app when the work outlasts it, so the rest is left for
    /// writing the files and asking for the widget reload.
    static let backgroundBudget: Duration = .seconds(20)
    /// Months scroll in steps this long, never more at once.
    static let extensionStep = 183
    /// The Month never asks for days further from today than this.
    static let extensionLimit = 730

    init(
        engine: SyncEngine,
        calendar: Calendar = .autoupdatingCurrent,
        clock: @escaping @Sendable () -> Date = { Date() },
        autoRefreshInterval: Duration? = AppModel.refreshInterval,
        reloadWidgets: @escaping @MainActor () -> Void = AppModel.reloadSystemWidgets
    ) {
        self.engine = engine
        self.calendar = calendar
        self.clock = clock
        self.autoRefreshInterval = autoRefreshInterval
        self.reloadWidgets = reloadWidgets
        now = clock()
        derived = Derived(data: engine.load(), calendar: calendar)
    }

    /// How often the data is read again while the app runs. An incremental read that finds
    /// nothing costs one small call per calendar and per account list, so this can be short
    /// enough that a change made elsewhere shows before anyone thinks to pull.
    static let refreshInterval: Duration = .seconds(3 * 60)

    /// The store over the real engine and the Google client from `GoogleClientID`, with
    /// tokens in the keychain and files in the shared folder. Nil while the client is the
    /// placeholder, which is when the apps run on `FixtureStore`.
    static func live(bundle: Bundle = .main) -> AppModel? {
        guard let auth = GoogleAuth(bundle: bundle) else { return nil }
        let engine = SyncEngine(
            auth: auth, tokens: KeychainTokenStore(), cache: cacheDirectory())
        let model = AppModel(engine: engine)
        model.shareSettings()
        return model
    }

    /// The shared folder (the App Group on iPhone, so the widget reads it too). A build
    /// signed without the App Group still runs, from its own container, with no widget data.
    private static func cacheDirectory() -> CacheDirectory {
        if let shared = try? CacheDirectory.shared() { return shared }
        let support = URL.applicationSupportDirectory.appending(
            path: "Day", directoryHint: .isDirectory)
        return CacheDirectory(url: support)
    }

    // MARK: Events

    func events(in days: ClosedRange<CivilDate>) -> [Event] {
        requestWindow(days)
        let from = days.lowerBound.date(in: calendar)
        let to = days.upperBound.adding(days: 1).date(in: calendar)
        let derived = derived
        // Sorted by start, so only events starting between the longest span before `from` and
        // `to` can overlap the days; everything earlier ended before they began.
        var i = derived.firstIndex(startingAtOrAfter: from.addingTimeInterval(-derived.longestSpan))
        var found: [Event] = []
        while i < derived.events.count, derived.starts[i] < to {
            let event = derived.events[i]
            if derived.ends[i] > from || derived.starts[i] >= from { found.append(event) }
            i += 1
        }
        return found
    }

    func isVisible(_ id: CalendarID) -> Bool {
        derived.visible.contains(id)
    }

    func setVisible(_ visible: Bool, calendar id: CalendarID) {
        guard isVisible(id) != visible else { return }
        // Several toggles of one calendar can be queued; it is settled only when the last
        // of them has been written.
        let version = (pendingVisibility[id]?.version ?? 0) + 1
        pendingVisibility[id] = PendingToggle(visible: visible, version: version)
        changes += 1
        apply(derived.data)
        settingsCloud?.setVisible(visible, for: id)
        enqueue { [self] in
            try? await engine.setVisible(visible, calendar: id)
            if pendingVisibility[id]?.version == version { pendingVisibility[id] = nil }
            changes += 1
            reloadWidgetsIfNeeded(engine.widgetSnapshot())
            // A calendar shown again reads what changed while it was hidden (or in full, if
            // it never was fetched) before it is current. It runs on its own, so the next
            // toggle's write is not held up behind the network.
            if visible { Task { await refresh() } }
        }
    }

    // MARK: Refreshing

    func refresh() async {
        // A task of its own, so a pull to refresh that SwiftUI cancels when the list redraws
        // does not end the read half way. Only the background task is cut short on purpose.
        let report = await Task { await sync() }.value
        reloadWidgetsIfNeeded(report.snapshot)
    }

    /// Reads what changed for every visible calendar and draws the result. In the background
    /// the engine's own budget applies, and cancelling the caller stops the read; a read cut
    /// short says nothing about Google, so it leaves the line on screen as it was.
    private func sync(inBackground: Bool = false) async -> SyncReport {
        lastRefreshAttempt = clock()
        // Accounts added or removed on another device join or leave first, so a removed one
        // is never read and marked signed out.
        await reconcileAccounts()
        let mark = changes
        let report = inBackground
            ? await engine.refreshInBackground(within: Self.backgroundBudget)
            : await engine.refresh()
        if !Task.isCancelled { outcome = report.outcome }
        PushSync.shared.didSync(self, engine: engine, from: derived.data, report: report)
        apply(report.data, startedAt: mark)
        // Calendars this read listed for the first time pick up the settings other devices
        // gave them.
        reconcileSettings()
        retryRevocations()
        let accounts = report.data.accounts
        Self.refreshLog.notice(
            "refresh \(String(describing: report.outcome), privacy: .public): \(accounts.count, privacy: .public) accounts, \(accounts.filter(\.signedOut).count, privacy: .public) signed out"
        )
        return report
    }

    /// One line per refresh in the log (subsystem `io.github.spashii.day`, category
    /// `refresh`): whether Google answered and how many accounts are signed out, with no
    /// addresses or events, so a bug report or a check after an update can tell that Day is
    /// still signed in and current without opening it.
    private static let refreshLog = Logger(subsystem: DayIdentifiers.bundleID, category: "refresh")

    /// The app came to the front, including at launch: refresh the clock at once and the
    /// data unless it was tried within the last minute. A last try stamped in the future
    /// (the clock moved back) does not hold the refresh off.
    func sceneDidBecomeActive() {
        tick()
        if let last = lastRefreshAttempt,
            (0..<Self.foregroundThrottle).contains(clock().timeIntervalSince(last))
        {
            // No read this time, but an account another device added or removed still shows,
            // and one it added is read at once.
            Task {
                let found = await reconcileAccounts()
                if !found.added.isEmpty || !found.restored.isEmpty { await refresh() }
            }
            return
        }
        Task { await refresh() }
    }

    /// The app is leaving the front: a short read of the widget's days, then a widget reload
    /// if that changed anything, so the Lock Screen starts from the freshest data the app
    /// has. The full refresh is not run here: the system can end the background time
    /// mid-read, and then the reload would never run. The cut-off of eight seconds leaves the
    /// reload room inside the time the caller asked the system for.
    func sceneDidEnterBackground() async {
        await writesFinished()
        // A refresh within the foreground throttle has just written a snapshot (and asked for
        // its reload); reading again would only repeat it.
        let justTried = lastRefreshAttempt.map {
            (0..<Self.foregroundThrottle).contains(clock().timeIntervalSince($0))
        } ?? false
        let snapshot =
            justTried
            ? engine.widgetSnapshot()
            : await engine.refreshWidgetSnapshot(maxAge: 0, deadline: .seconds(8))
        reloadWidgetsIfNeeded(snapshot)
    }

    /// The `BGAppRefreshTask` body: the same incremental refresh as in the front, which keeps
    /// the app's own cache and tokens current for the next launch and writes the widget's
    /// snapshot, then a widget reload if the snapshot changed. Usually a few small calls; a
    /// daily full read is the slow case, and the calendars' reads are spread over the day so
    /// it rarely meets more than one. One try per request and `backgroundBudget` for the
    /// whole refresh; when the system ends the task first it cancels this one, every request
    /// stops, and what already answered is kept. Returns whether every account answered.
    @discardableResult
    func refreshInBackground() async -> Bool {
        guard accounts.contains(where: { !$0.signedOut }) else { return true }
        let report = await sync(inBackground: true)
        reloadWidgetsIfNeeded(report.snapshot)
        return report.outcome == .current
    }

    // MARK: The clock and the schedule

    /// Starts the minute clock and the repeating refresh. Call once, when the app starts.
    func start() {
        guard !started else { return }
        started = true
        PushSync.shared.start(model: self, engine: engine)
        retryRevocations()

        tasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    guard let wait = self?.untilNextMinute() else { return }
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled, let self else { return }
                    tick()
                }
            })

        if let interval = autoRefreshInterval {
            tasks.append(
                Task { [weak self] in
                    while !Task.isCancelled {
                        // Tolerance lets the system batch the wake-up with others, which the
                        // Mac's App Nap would otherwise do on its own terms.
                        try? await Task.sleep(for: interval, tolerance: .seconds(20))
                        guard !Task.isCancelled, let self else { return }
                        await refresh()
                    }
                })
        }

        // The network coming back is when an `Offline` line can go away; waiting for the
        // timer would leave it up to three minutes longer than it needs to be.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkDidChange(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.spashii.day.network"))
        pathMonitor = monitor

        // A changed clock, day, zone or locale moves every time on screen.
        observe([
            .NSSystemClockDidChange, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
            NSLocale.currentLocaleDidChangeNotification,
        ]) { [weak self] in self?.environmentDidChange() }

        #if os(macOS)
            // A Mac that slept has stale data and a stale clock when it wakes.
            observe([NSWorkspace.didWakeNotification], center: NSWorkspace.shared.notificationCenter) {
                [weak self] in
                PushSync.shared.canReceivePushAgain()
                self?.tick()
                Task { await self?.refresh() }
            }
        #endif
    }

    /// Stops the timers and observers. The apps never call it; tests do.
    func stop() {
        started = false
        tasks.forEach { $0.cancel() }
        tasks = []
        pathMonitor?.cancel()
        pathMonitor = nil
        networkSatisfied = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        #if os(macOS)
            observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        #endif
        observers = []
    }

    /// Sets `now` to the device clock. Every minute, and whenever the app comes to the front.
    func tick() {
        now = clock()
    }

    /// Seconds to the next minute boundary, plus a hair so the tick lands after it.
    func untilNextMinute() -> Duration {
        let seconds = clock().timeIntervalSince1970
        let remaining = 60 - seconds.truncatingRemainder(dividingBy: 60)
        return .milliseconds(Int(remaining * 1000) + 50)
    }

    /// Refreshes when the network returns: a path that was unsatisfied is satisfied again.
    /// The first update only records the state, since launch refreshes anyway.
    private func networkDidChange(satisfied: Bool) {
        defer { networkSatisfied = satisfied }
        guard satisfied, networkSatisfied == false else { return }
        PushSync.shared.canReceivePushAgain()
        Task { await refresh() }
    }

    private func environmentDidChange() {
        // Assigning again redraws whatever reads the calendar, even though the autoupdating
        // calendar is the same value: its zone and locale are what changed.
        calendar = .autoupdatingCurrent
        derived = Derived(data: derived.data, calendar: calendar)
        tick()
        // A new day, zone or clock moves "today", and with it the days the engine keeps
        // current and the age the widget is timed from; a refresh puts both right at once.
        Task { await refresh() }
    }

    private func observe(
        _ names: [Notification.Name], center: NotificationCenter = .default,
        _ handler: @escaping @MainActor () -> Void
    ) {
        for name in names {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { handler() }
                })
        }
    }

    // MARK: Accounts

    func addAccount(using session: WebAuthenticationSession) async throws {
        try await signIn(using: session, loginHint: nil, repairing: nil)
    }

    func signInAgain(_ id: AccountID, using session: WebAuthenticationSession) async throws {
        guard let account = account(id) else { return }
        try await signIn(using: session, loginHint: account.email, repairing: account)
    }

    private func signIn(
        using session: WebAuthenticationSession, loginHint: String?, repairing: Account?
    ) async throws {
        try await signIn(loginHint: loginHint, repairing: repairing) { request in
            try await session.authenticate(
                using: request.url, callback: .customScheme(request.callbackScheme),
                // Google's account chooser can then offer the accounts the browser is in.
                preferredBrowserSession: .shared, additionalHeaderFields: [:])
        }
    }

    /// The sign-in with the browser step passed in, so everything around it can run without
    /// a window. Closing the sheet or choosing Cancel on Google's screen throws
    /// `CancellationError`; every other failure throws an error whose description is the
    /// line to show, in plain words (`SignInFailure`).
    func signIn(
        loginHint: String?, repairing: Account?,
        authenticate: @MainActor (AuthorizationRequest) async throws -> URL
    ) async throws {
        // A removal still being written must land before the account is added back.
        await writesFinished()
        do {
            let request = try engine.authorizationRequest(loginHint: loginHint)
            let callback = try await authenticate(request)
            try await engine.completeSignIn(request, callback: callback, repairing: repairing?.id)
        } catch {
            throw SignInFailure.describing(error, repairing: repairing)
        }
        changes += 1
        apply(engine.load())
        // The list shows the account at once; its calendars and events follow.
        Task { await refresh() }
    }

    /// Removes the account everywhere: its shared keychain item (iCloud Keychain carries the
    /// deletion to every device), its push channels, its settings in iCloud and, last, its
    /// grant at Google. Each other device then drops it on its next pass over the keychain.
    /// Queued like the toggles, so adding the account back waits until its old grant is
    /// revoked and cannot be caught by the revocation.
    ///
    /// The refresh token goes into a device-only keychain item before anything is deleted and
    /// leaves it only when Google confirms the revocation, so a removal made offline is
    /// retried (`retryRevocations`) and the grant does not outlive the account.
    func removeAccount(_ id: AccountID) {
        pendingRemovals.insert(id)
        changes += 1
        apply(derived.data)
        enqueue { [self] in
            // Channels first, while the token is still in the keychain and Google honours it.
            let token = engine.storedToken(for: id)
            await stopPushChannels?(id, token)
            let queued = token.map { engine.queueRevocation($0, for: id) } ?? false
            let removed = (try? await engine.removeAccount(id)) != nil
            pendingRemovals.remove(id)
            changes += 1
            apply(engine.load())
            reloadWidgetsIfNeeded(engine.widgetSnapshot())
            guard removed else {
                // A token that is still in the keychain is still in use: revoking it would
                // sign the account out everywhere.
                if queued, engine.storedToken(for: id) != nil { engine.cancelRevocation(for: id) }
                return
            }
            settingsCloud?.forget(id)
            CalendarSymbols.shared.forget(account: id)
            if queued {
                await engine.retryRevocations()
            } else if let token {
                await engine.revoke(token)
            }
        }
    }

    /// Tries the revocations that could not reach Google before: on launch and after each
    /// refresh. Cheap when there are none.
    private func retryRevocations() {
        Task { [engine] in await engine.retryRevocations() }
    }

    // MARK: Accounts on every device

    /// The person's calendar settings in iCloud, shared with their other devices. Nil until
    /// `shareSettings()`, so tests and previews never write to iCloud.
    @ObservationIgnored private(set) var settingsCloud: CloudCalendarSettings?
    @ObservationIgnored private var settingsObserver: SettingsObservation?

    /// The push client's hook for an account leaving this device. Removed here, it runs before
    /// anything is deleted, with the account's tokens still in the keychain and passed in, and
    /// is awaited, so the client can stop the account's channels with Google before the grant
    /// is revoked. Removed on another device, it gets nil after the account has left: that
    /// device revoked the grant, so the channels can only lapse, and the client drops them
    /// from its own records.
    @ObservationIgnored var stopPushChannels: (@MainActor (AccountID, StoredToken?) async -> Void)?

    /// Shares toggles and symbols through the iCloud key-value store: each change is written
    /// there as well as to the files, and changes from other devices are laid over the files
    /// as iCloud delivers them. The first pass copies this device's files into iCloud. A build
    /// without the store's entitlement keeps settings in the files alone.
    func shareSettings() {
        guard settingsCloud == nil, UbiquitousSettings.isAvailable else { return }
        let cloud = CloudCalendarSettings(cloud: UbiquitousSettings.shared)
        settingsCloud = cloud
        CalendarSymbols.shared.cloud = cloud
        settingsObserver = UbiquitousSettings.shared.observe { [weak self] change in
            Task { @MainActor [weak self] in self?.settingsDidChange(change) }
        }
        reconcileSettings()
    }

    /// iCloud changed the key-value store. Why decides what to do (`removedKeys(for:)`): the
    /// first download and an account switch make the store look empty, which must not clear
    /// the settings in the files, so they reconcile again instead, which gives the store the
    /// settings it lacks now that it has finished.
    private func settingsDidChange(_ change: SettingsChange) {
        guard let cloud = settingsCloud else { return }
        guard let removed = cloud.removedKeys(for: change) else {
            Self.settingsLog.notice("iCloud settings are over their quota; the change is skipped")
            return
        }
        reconcileSettings(removed: removed)
    }

    private static let settingsLog = Logger(subsystem: DayIdentifiers.bundleID, category: "settings")

    /// Brings the account list in line with the shared keychain (`SyncEngine.reconcileAccounts`)
    /// and draws the result: on every refresh, and on return to the front when the refresh is
    /// skipped. An account removed on another device leaves with its cache and settings here.
    @discardableResult
    func reconcileAccounts() async -> AccountChanges {
        let found = await engine.reconcileAccounts()
        guard found.changesAccounts else { return found }
        changes += 1
        apply(engine.load())
        for id in found.removed { CalendarSymbols.shared.forget(account: id) }
        reloadWidgetsIfNeeded(engine.widgetSnapshot())
        // Not awaited: the refresh this pass usually precedes should not wait on the push
        // server.
        if let stop = stopPushChannels {
            for id in found.removed { Task { await stop(id, nil) } }
        }
        return found
    }

    /// Lays the settings other devices chose over this device's files and gives iCloud the
    /// ones only this device has (`CloudCalendarSettings.reconcile`). `removed` are keys
    /// another device just removed. Queued behind the toggles, so the toggle file it reads
    /// already holds the person's last toggle.
    func reconcileSettings(removed: Set<String> = []) {
        guard let cloud = settingsCloud else { return }
        enqueue { [self] in
            let data = derived.data
            let known = data.accounts.flatMap { data.calendarsByAccount[$0.id] ?? [] }.map(\.id)
            let local = CalendarSettings(
                visibility: engine.storedVisibility(), symbols: CalendarSymbols.shared.map)
            let next = cloud.reconcile(local, known: known, removed: removed)
            // Before any suspension, so a symbol chosen meanwhile is not written over.
            if next.symbols != local.symbols { CalendarSymbols.shared.replace(with: next.symbols) }
            guard next.visibility != local.visibility else { return }
            let shownBefore = derived.visible
            try? await engine.replaceVisibility(next.visibility)
            changes += 1
            var current = derived.data
            current.visibility = next.visibility
            apply(current)
            reloadWidgetsIfNeeded(engine.widgetSnapshot())
            // A calendar another device showed reads its events now, as a toggle here would.
            if !derived.visible.isSubset(of: shownBefore) { Task { await refresh() } }
        }
    }

    // MARK: Applying data

    /// Draws the answer of a fetch that began when `changes` read `mark`. If accounts or toggles
    /// changed meanwhile, the answer may predate them, so the files are read again instead.
    private func apply(_ data: CalendarData, startedAt mark: Int) {
        apply(mark == changes ? data : engine.load())
    }

    /// Draws `data`, with the changes the engine has not written yet laid over it.
    private func apply(_ data: CalendarData) {
        var data = data
        if !pendingRemovals.isEmpty {
            data.accounts.removeAll { pendingRemovals.contains($0.id) }
        }
        for (id, toggle) in pendingVisibility {
            data.visibility.set(toggle.visible, for: id)
        }
        derived = Derived(data: data, calendar: calendar)
    }

    /// A toggle shown on screen and not yet written. `version` counts the toggles made of
    /// the same calendar, so an earlier write finishing does not settle a later toggle.
    private struct PendingToggle {
        let visible: Bool
        let version: Int
    }

    /// Runs `work` after every earlier write has finished.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = writes
        writes = Task {
            await previous?.value
            await work()
        }
    }

    private func writesFinished() async {
        await writes?.value
    }

    // MARK: The Month's window

    /// Called from `events(in:)`, which views call while they draw. Starts a fetch for days
    /// beyond the covered days and returns at once; the answer arrives as new data and the
    /// view asks again. The covered days come from the engine's own record, so a daily full
    /// read that narrows them sends the Month back for the stretch it is showing.
    private func requestWindow(_ days: ClosedRange<CivilDate>) {
        guard let covered = derived.data.syncedDays, windowFetch == nil,
            clock() >= extensionRetryAfter,
            derived.data.accounts.contains(where: { !$0.signedOut })
        else { return }
        let today = CivilDate(clock(), in: calendar)
        let limit = today.adding(days: -Self.extensionLimit)...today.adding(days: Self.extensionLimit)
        let asked = days.clamped(to: limit)
        // A fortnight of margin, so the rows just past the edge are there before they scroll in.
        let wanted = asked.lowerBound.adding(days: -14)...asked.upperBound.adding(days: 14)
        guard wanted.lowerBound < covered.lowerBound || wanted.upperBound > covered.upperBound
        else { return }

        var lower = covered.lowerBound
        var upper = covered.upperBound
        if wanted.lowerBound < lower {
            lower = max(wanted.lowerBound, lower.adding(days: -Self.extensionStep))
        }
        if wanted.upperBound > upper {
            upper = min(wanted.upperBound, upper.adding(days: Self.extensionStep))
        }
        let target = lower...upper
        guard target != covered else { return }

        windowFetch = Task { [weak self] in
            guard let self else { return }
            let mark = changes
            let report = await engine.extendWindow(toInclude: target)
            windowFetch = nil
            apply(report.data, startedAt: mark)
            if report.outcome != .current {
                outcome = report.outcome
                extensionRetryAfter = clock().addingTimeInterval(60)
            } else if report.data.syncedDays == covered {
                // Nothing widened (every calendar was already past it, or none is fetched
                // yet); asking again at once would loop.
                extensionRetryAfter = clock().addingTimeInterval(60)
            }
        }
    }

    // MARK: Widgets

    /// Reloads the widget when `snapshot` differs from the one it last reloaded for in what
    /// it shows, or in the age its lines are timed from. Nothing on disk means nothing for the
    /// widget to read either.
    private func reloadWidgetsIfNeeded(_ snapshot: WidgetSnapshot?) {
        #if os(macOS)
            WidgetSnapshotWriter.publish(snapshot, symbols: CalendarSymbols.shared.map)
        #endif
        guard let snapshot, snapshot.needsReload(after: reloadedFor) else { return }
        reloadedFor = snapshot
        reloadWidgets()
    }

    /// Asks WidgetKit to rebuild the Lock Screen timelines from the snapshot. On the Mac the
    /// desktop widget reads its own copy in the App Group, and `WidgetSnapshotWriter` asks for
    /// its reload when it writes that copy.
    static func reloadSystemWidgets() {
        #if os(iOS)
            WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

// MARK: - The drawn data

extension AppModel {
    /// Everything `events(in:)`, `isVisible` and `calendars` answer from, built once per change
    /// of data, so a Month drawing a dozen week rows does no merging or sorting.
    struct Derived {
        let data: CalendarData
        /// Every calendar once, accounts in order.
        let calendars: [CalendarInfo]
        let visible: Set<CalendarID>
        /// Merged events from visible calendars, sorted by start (the merge order breaks ties).
        let events: [Event]
        let starts: [Date]
        let ends: [Date]
        /// The longest event in `events`, which bounds how far before a day an event can
        /// start and still reach into it.
        let longestSpan: TimeInterval

        init(data: CalendarData, calendar: Calendar) {
            let calendars = data.calendars
            let visible = Set(calendars.filter(data.visibility.isVisible).map(\.id))
            let shown = data.accounts
                .flatMap { data.eventsByAccount[$0.id] ?? [] }
                .filter { visible.contains($0.id.calendar) }
            var entries: [(offset: Int, event: Event, span: DateInterval)] = []
            for (offset, event) in merged(shown).enumerated() {
                entries.append((offset, event, event.time.interval(in: calendar)))
            }
            entries.sort { ($0.span.start, $0.offset) < ($1.span.start, $1.offset) }
            self.data = data
            self.calendars = calendars
            self.visible = visible
            events = entries.map { $0.event }
            starts = entries.map { $0.span.start }
            ends = entries.map { $0.span.end }
            longestSpan = entries.map { $0.span.duration }.max() ?? 0
        }

        /// The first position whose start is `date` or later, by binary search.
        func firstIndex(startingAtOrAfter date: Date) -> Int {
            var low = 0
            var high = starts.count
            while low < high {
                let middle = (low + high) / 2
                if starts[middle] < date { low = middle + 1 } else { high = middle }
            }
            return low
        }
    }
}

// MARK: - Sign-in failures

/// A sign-in that failed, with the whole line the screen shows. The raw errors from Core read
/// as `OAuthError error 3`, and Google's codes, HTTP statuses and tokens mean nothing to the
/// person reading the line, so they go to the log (`Console.app`, subsystem
/// `io.github.spashii.day`, category `sign-in`) and the line says what happened in plain
/// words. Nothing shown here names a status, a code, a token, OAuth or an API.
struct SignInFailure: LocalizedError, Equatable {
    let line: String

    var errorDescription: String? { line }

    /// Where the codes go that the line does not show.
    private static let log = Logger(subsystem: DayIdentifiers.bundleID, category: "sign-in")

    /// What the person reads when Google ended the sign-in without a usable answer, and when
    /// nothing better is known.
    static let unfinished = "Google did not finish the sign-in."

    /// What the person reads when the client Day signs in with is missing or refused.
    private static let noClient = "This copy of Day cannot reach Google."

    /// The error to throw for `error`: `CancellationError` when the person backed out,
    /// otherwise a failure whose line says what happened.
    static func describing(_ error: any Error, repairing: Account?) -> any Error {
        switch error {
        case is CancellationError:
            return error
        case let error as ASWebAuthenticationSessionError where error.code == .canceledLogin:
            return CancellationError()
        case let error as OAuthError:
            return oauth(error, repairing: repairing)
        case SyncError.noGoogleClient:
            log.error("no Google client: GoogleClientID is missing or the placeholder")
            return SignInFailure(line: noClient)
        case is KeychainTokenStore.Failure:
            // Its own description is a plain sentence; the status is in the log already.
            return error
        case let error as URLError:
            // The system's reason (`The Internet connection appears to be offline.`) is for
            // the log; the person gets the one sentence that says what to do.
            log.error("sign-in could not reach Google: \(error.localizedDescription, privacy: .public)")
            return SignInFailure(line: "Couldn't reach Google. Check your connection and try again.")
        default:
            log.error("sign-in failed: \(String(describing: error), privacy: .public)")
            return SignInFailure(line: unfinished)
        }
    }

    private static func oauth(_ error: OAuthError, repairing: Account?) -> any Error {
        switch error {
        case .accessDenied:
            return CancellationError()
        case .differentAccount(let email):
            let expected = repairing?.email ?? "the account"
            return SignInFailure(
                line: "You chose \(email). Choose \(expected) to sign this account back in.")
        case .partialGrant:
            return SignInFailure(
                line:
                    "Day didn't get access to your calendars. Try again and leave the calendar box checked."
            )
        case .clientRejected(let code):
            log.error("Google refused the client: \(code, privacy: .public)")
            return SignInFailure(line: noClient)
        case .authorizationFailed(let code):
            log.error("Google ended the sign-in with \(code, privacy: .public)")
        case .stateMismatch:
            log.error("Google's answer was for another sign-in")
        case .invalidGrant(let subtype):
            log.error("Google refused the grant: \(subtype ?? "none", privacy: .public)")
        case .tokenEndpoint(let status, let code):
            log.error(
                "Google answered the sign-in with \(status, privacy: .public) \(code ?? "none", privacy: .public)"
            )
        case .malformedResponse(let detail):
            log.error("Google's sign-in answer was unusable: \(detail, privacy: .public)")
        }
        return SignInFailure(line: unfinished)
    }
}
