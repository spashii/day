import AuthenticationServices
import DayCore
import Foundation
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
/// What it does, and when:
/// - Launch: reads the cache synchronously in `init`, so the first frame already knows the
///   accounts (the first-run screen is decided from them) and shows cached events.
/// - Refresh: `sceneDidBecomeActive()` on launch and return to the foreground, `refresh()` for
///   pull to refresh and Command-R, every 15 minutes while running, on the Mac after wake.
///   As the app leaves, `sceneDidEnterBackground()` fetches only the widget's days (today
///   through eight days ahead) inside the few seconds the system grants, then reloads the
///   widget; the full window waits for the next time the app is in front. Every refresh ends
///   with `WidgetCenter.reloadAllTimelines()` on iPhone.
/// - Toggles and removal apply on screen at once and are written by the engine in order, so
///   the person's last toggle always wins and the widget fetches what the app shows.
/// - The Month scrolling past the cached window asks `events(in:)` for days the cache does not
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
    /// one; `Loading…` shows only while an account exists and nothing has ever been fetched.
    var status: StoreStatus {
        switch outcome {
        case .offline:
            return .offline
        case .unreachable:
            return .unreachable
        case .current, nil:
            let waiting = derived.data.lastFetchedAt == nil && accounts.contains { !$0.signedOut }
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
    /// The days the cache holds for every account, as far as this run knows.
    @ObservationIgnored private var covered: ClosedRange<CivilDate>?
    @ObservationIgnored private var windowFetch: Task<Void, Never>?
    @ObservationIgnored private var extensionRetryAfter = Date.distantPast

    /// Refreshing again within this many seconds of the last try is skipped when the trigger
    /// is only the app coming to the front, so flicking between apps costs no requests.
    static let foregroundThrottle: TimeInterval = 60
    /// Months scroll in steps this long, never more at once.
    static let extensionStep = 183
    /// The Month never asks for days further from today than this.
    static let extensionLimit = 730

    init(
        engine: SyncEngine,
        calendar: Calendar = .autoupdatingCurrent,
        clock: @escaping @Sendable () -> Date = { Date() },
        autoRefreshInterval: Duration? = .seconds(15 * 60),
        reloadWidgets: @escaping @MainActor () -> Void = AppModel.reloadSystemWidgets
    ) {
        self.engine = engine
        self.calendar = calendar
        self.clock = clock
        self.autoRefreshInterval = autoRefreshInterval
        self.reloadWidgets = reloadWidgets
        now = clock()
        derived = Derived(data: engine.load(), calendar: calendar)
        if derived.data.lastFetchedAt != nil {
            covered = SyncEngine.defaultWindow(today: CivilDate(now, in: calendar))
        }
    }

    /// The store over the real engine and the Google client from `GoogleClientID`, with
    /// tokens in the keychain and files in the shared folder. Nil while the client is the
    /// placeholder, which is when the apps run on `FixtureStore`.
    static func live(bundle: Bundle = .main) -> AppModel? {
        guard let auth = GoogleAuth(bundle: bundle) else { return nil }
        let engine = SyncEngine(
            auth: auth, tokens: KeychainTokenStore(), cache: cacheDirectory())
        return AppModel(engine: engine)
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
        enqueue { [self] in
            try? await engine.setVisible(visible, calendar: id)
            if pendingVisibility[id]?.version == version { pendingVisibility[id] = nil }
            changes += 1
            reloadWidgets()
            // Events of a calendar that was hidden were never fetched, so showing it needs a
            // fetch before anything appears. It runs on its own, so the next toggle's write is
            // not held up behind the network.
            if visible { Task { await refresh() } }
        }
    }

    // MARK: Refreshing

    func refresh() async {
        await sync()
        reloadWidgets()
    }

    /// Fetches every visible calendar and draws the result. Does not reload the widget, so
    /// the callers that do it themselves reload exactly once.
    private func sync() async {
        lastRefreshAttempt = clock()
        let mark = changes
        let report = await engine.refresh()
        outcome = report.outcome
        apply(report.data, startedAt: mark)
        if report.outcome == .current {
            let window = SyncEngine.defaultWindow(today: CivilDate(clock(), in: calendar))
            covered = covered.flatMap { Self.union($0, window) } ?? window
        }
    }

    /// The app came to the front, including at launch: refresh the clock at once and the
    /// data unless it was tried within the last minute.
    func sceneDidBecomeActive() {
        tick()
        if let last = lastRefreshAttempt, clock().timeIntervalSince(last) < Self.foregroundThrottle {
            return
        }
        Task { await refresh() }
    }

    /// The app is leaving the front: a short fetch of the widget's days, then the final widget
    /// reload, so the Lock Screen starts from the freshest data the app has. The full window
    /// is not fetched here: the system can end the background time mid-fetch, and then the
    /// reload would never run and the Lock Screen would keep the older snapshot. The cut-off
    /// of eight seconds leaves the reload room inside the time the caller asked the system for.
    func sceneDidEnterBackground() async {
        await writesFinished()
        // A refresh that began moments ago has just written a snapshot; fetching again would
        // only repeat it when someone flicks between apps.
        let justTried = lastRefreshAttempt.map { clock().timeIntervalSince($0) <= 15 } ?? false
        if !justTried {
            _ = await engine.refreshWidgetSnapshot(maxAge: 0, deadline: .seconds(8))
        }
        reloadWidgets()
    }

    /// The `BGAppRefreshTask` body: today through eight days ahead for every visible
    /// calendar, written to the widget's snapshot, then a widget reload. Draws nothing: the
    /// app is not on screen, and the next launch refreshes everything. Returns whether a
    /// snapshot is in place.
    @discardableResult
    func refreshInBackground() async -> Bool {
        guard accounts.contains(where: { !$0.signedOut }) else { return true }
        let snapshot = await engine.refreshWidgetSnapshot(maxAge: 0, deadline: .seconds(20))
        reloadWidgets()
        return snapshot != nil
    }

    // MARK: The clock and the schedule

    /// Starts the minute clock and the repeating refresh. Call once, when the app starts.
    func start() {
        guard !started else { return }
        started = true

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
                        try? await Task.sleep(for: interval)
                        guard !Task.isCancelled, let self else { return }
                        await refresh()
                    }
                })
        }

        // A changed clock, day, zone or locale moves every time on screen.
        observe([
            .NSSystemClockDidChange, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
            NSLocale.currentLocaleDidChangeNotification,
        ]) { [weak self] in self?.environmentDidChange() }

        #if os(macOS)
            // A Mac that slept has stale data and a stale clock when it wakes.
            observe([NSWorkspace.didWakeNotification], center: NSWorkspace.shared.notificationCenter) {
                [weak self] in
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

    private func environmentDidChange() {
        // Assigning again redraws whatever reads the calendar, even though the autoupdating
        // calendar is the same value: its zone and locale are what changed.
        calendar = .autoupdatingCurrent
        derived = Derived(data: derived.data, calendar: calendar)
        tick()
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
    /// `CancellationError`; every other failure throws an error whose description reads
    /// after `Couldn't sign in to Google: `.
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
        // The new account's window is the default one, whatever the Month had reached.
        covered = SyncEngine.defaultWindow(today: CivilDate(clock(), in: calendar))
        // The list shows the account at once; its calendars and events follow.
        Task { await refresh() }
    }

    func removeAccount(_ id: AccountID) {
        pendingRemovals.insert(id)
        changes += 1
        apply(derived.data)
        enqueue { [self] in
            try? await engine.removeAccount(id)
            pendingRemovals.remove(id)
            changes += 1
            apply(engine.load())
            reloadWidgets()
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
    /// beyond the cache and returns at once; the answer arrives as new data and the view
    /// asks again.
    private func requestWindow(_ days: ClosedRange<CivilDate>) {
        guard let covered, windowFetch == nil, clock() >= extensionRetryAfter,
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
            if report.outcome == .current {
                self.covered = self.covered.flatMap { Self.union($0, target) } ?? target
            } else {
                outcome = report.outcome
                extensionRetryAfter = clock().addingTimeInterval(60)
            }
        }
    }

    /// The two windows as one, when they touch or overlap; nil when a gap lies between.
    static func union(_ a: ClosedRange<CivilDate>, _ b: ClosedRange<CivilDate>)
        -> ClosedRange<CivilDate>?
    {
        guard a.lowerBound <= b.upperBound.adding(days: 1),
            b.lowerBound <= a.upperBound.adding(days: 1)
        else { return nil }
        return min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
    }

    // MARK: Widgets

    /// Asks WidgetKit to rebuild the Lock Screen timelines from the snapshot. The Mac has no
    /// widget.
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

/// A sign-in that failed, worded for the line the screen shows after
/// `Couldn't sign in to Google: `. The raw errors from Core read as `OAuthError error 3`, and
/// Google's codes and HTTP statuses mean nothing to the person reading the line, so they go to
/// the log and the line says what happened in plain words.
struct SignInFailure: LocalizedError, Equatable {
    let reason: String

    var errorDescription: String? { reason }

    /// Where the codes go that the line does not show.
    private static let log = Logger(subsystem: DayIdentifiers.bundleID, category: "sign-in")

    /// What the person reads when Google ended the sign-in without a usable answer.
    private static let unfinished = "Google did not finish the sign-in."

    /// The error to throw for `error`: `CancellationError` when the person backed out,
    /// otherwise a failure with a sentence that says what happened.
    static func describing(_ error: any Error, repairing: Account?) -> any Error {
        switch error {
        case is CancellationError:
            return error
        case let error as ASWebAuthenticationSessionError where error.code == .canceledLogin:
            return CancellationError()
        case let error as OAuthError:
            switch error {
            case .accessDenied:
                return CancellationError()
            case .differentAccount(let email):
                let expected = repairing?.email ?? "the account"
                return SignInFailure(reason: "you chose \(email) instead of \(expected).")
            case .authorizationFailed(let code):
                log.error("Google ended the sign-in with \(code, privacy: .public)")
                return SignInFailure(reason: unfinished)
            case .stateMismatch:
                return SignInFailure(reason: "Google's answer was for another sign-in.")
            case .invalidGrant:
                return SignInFailure(reason: "Google refused the sign-in.")
            case .clientRejected:
                return SignInFailure(reason: "Google refused this copy of Day.")
            case .partialGrant:
                return SignInFailure(reason: "Day needs access to your calendars.")
            case .tokenEndpoint(let status, let code):
                log.error(
                    "Google answered the sign-in with \(status, privacy: .public) \(code ?? "none", privacy: .public)"
                )
                return SignInFailure(reason: unfinished)
            case .malformedResponse(let detail):
                log.error("Google's sign-in answer was unusable: \(detail, privacy: .public)")
                return SignInFailure(reason: unfinished)
            }
        case SyncError.noGoogleClient:
            return SignInFailure(reason: "this copy of Day cannot reach Google.")
        default:
            // The system's own reason, as in `The Internet connection appears to be offline.`
            return error
        }
    }
}
