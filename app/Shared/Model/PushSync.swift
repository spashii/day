import DayCore
import Foundation
import OSLog

#if os(iOS)
    import UIKit
    import WidgetKit
#else
    import AppKit
#endif

/// Instant sync on this device: the APNs token, the background push, and the Google channels
/// that make the relay send it (`push/README.md`, `PushCoordinator`).
///
/// - A background push runs the app's incremental sync with its background budget, which
///   writes the snapshot and reloads widgets only when what they show changed. Pushes that
///   arrive while a sync runs share one more sync after it (`SyncCoalescer`).
/// - After every sync, at launch and when the token arrives, the channels are checked and
///   renewed when due; nothing goes over the network unless something is due.
/// - The timers in `AppModel` stay as they are: a push that never comes only makes Day as
///   slow as it was before.
/// - Every sync also feeds the latency log (`LatencyRecorder`), so the site's claims about
///   speed rest on measurements.
///
/// Inert on the fixture and without a Google client, where there is no model.
@MainActor
final class PushSync {
    static let shared = PushSync()

    enum Outcome {
        case newData, noData, failed
    }

    /// How long a background push waits for its sync, and then for the latency probe. iOS
    /// gives a background push about 30 seconds; the sync's own budget is 20.
    static let syncWait: Duration = .seconds(22)
    static let latencyWait: Duration = .seconds(3)
    /// A first push this soon after launch started the process, and a change up to this much
    /// older than the push can still be the one it announces.
    static let launchedByPush: TimeInterval = 10
    static let pushHeadroom: TimeInterval = 60

    private static let log = Logger(subsystem: DayIdentifiers.bundleID, category: "push")

    let environment = PushEnvironment.detect()
    private weak var model: AppModel?
    private var engine: SyncEngine?
    private var coordinator: PushCoordinator?
    private var recorder: LatencyRecorder?
    private var appToken: String?
    private var asked = false
    private var reconciling: Task<Void, Never>?
    private var reconcileAgain = false
    private var timer: Task<Void, Never>?
    /// Background pushes of the last hour, for the latency log.
    private var pushes: [Date] = []
    /// When the engine's latest refresh began, taken from what it fetched.
    private var lastRunStart: Date?
    private var lastChange: Date?
    private var lastOutcome: SyncOutcome?
    private var latencyWork: Task<Void, Never>?
    /// The last moment this process could receive a push: its launch, moved later by a wake
    /// or the network coming back. A change older than this was found by catching up, not by
    /// a push, and is left out of the latency log (`LatencyRecorder.syncFinished`).
    private var receivingSince = Date()
    private lazy var coalescer = SyncCoalescer { [weak self] in await self?.syncForPush() }

    private init() {}

    // MARK: Hooks

    /// Asks for the APNs token. Called by the iPhone's app delegate at launch (a launch in
    /// the background for a push included) and by `AppModel.start()` on both platforms.
    func start(model: AppModel?, engine: SyncEngine? = nil) {
        guard let model = model ?? self.model else { return }
        self.model = model
        model.stopPushChannels = { [weak self] id, token in
            await self?.accountLeft(id, token: token)
        }
        if let engine { attach(engine) }
        guard !asked else { return }
        asked = true
        Self.log.notice("asking for a push token")
        #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
            PushLatency.exportForSharing()
        #else
            NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func didRegister(deviceToken: Data) {
        Self.log.notice("push token received, \(self.environment.rawValue, privacy: .public)")
        appToken = deviceToken.hexString
        reconcile()
    }

    /// A build without the push entitlement ends here, as does a device that cannot reach
    /// APNs. No channel is opened then, since nothing could wake this install.
    func didFailToRegister(_ error: any Error) {
        Self.log.notice("no push token: \(error.localizedDescription, privacy: .public)")
    }

    /// The Mac woke or the network returned: pushes sent while it was away are held or lost,
    /// so changes made before now are caught up on, not pushed.
    func canReceivePushAgain() {
        receivingSince = Date()
    }

    /// A background push: Google said a watched calendar or calendar list changed. Returns
    /// within `syncWait` and `latencyWait` whatever the network does.
    func pushArrived() async -> Outcome {
        let arrived = Date()
        // One line per push, with nothing from it, so a check can tell a push woke this
        // install and a sync followed (the `refresh` line).
        Self.log.notice("background push")
        #if os(iOS)
            // A push that arrives as the process starts is what started it: the device was
            // reachable before the launch, so the change it announces is not a catch-up.
            if pushes.isEmpty, arrived.timeIntervalSince(receivingSince) < Self.launchedByPush {
                receivingSince = arrived.addingTimeInterval(-Self.pushHeadroom)
            }
        #endif
        pushes.append(arrived)
        pushes.removeAll { arrived.timeIntervalSince($0) > 3600 }
        guard model != nil else { return .noData }
        let coalescer = coalescer
        let finished: Void? = await PushTiming.wait(upTo: Self.syncWait) {
            await coalescer.request()
        }
        if let latencyWork {
            _ = await PushTiming.wait(upTo: Self.latencyWait) { await latencyWork.value }
        }
        guard finished != nil, lastOutcome == .current else { return .failed }
        return (lastChange ?? .distantPast) >= arrived ? .newData : .noData
    }

    /// Called by `AppModel` after each sync, before it draws `report`: `before` is what it
    /// drew until now.
    func didSync(_ model: AppModel, engine: SyncEngine, from before: CalendarData, report: SyncReport) {
        self.model = model
        attach(engine)
        let now = Date()
        if let start = report.data.fetchedAtByAccount.values.max() { lastRunStart = start }
        lastOutcome = report.outcome
        if before.eventsByAccount != report.data.eventsByAccount { lastChange = now }
        recordLatency(from: before, to: report.data, at: now)
        reconcile()
    }

    /// `AppModel.stopPushChannels`: an account is leaving this device. Removed here, `token`
    /// is its sign-in, still valid, and its channels are stopped with Google; removed on
    /// another device it is nil and they are only dropped. When it is the last account, the
    /// relay forgets this install as well. Waits a few seconds at most, since removal waits
    /// on it.
    private func accountLeft(_ id: AccountID, token: StoredToken?) async {
        guard let coordinator, let model else { return }
        let last = model.accounts.allSatisfy { $0.id == id }
        _ = await PushTiming.wait(upTo: .seconds(8)) {
            await coordinator.accountRemoved(id, token: token, lastAccount: last)
        }
    }

    // MARK: Syncing

    private func attach(_ engine: SyncEngine) {
        guard self.engine == nil else { return }
        self.engine = engine
        coordinator = PushCoordinator(engine: engine, environment: environment)
        recorder = PushLatency.directory().map { LatencyRecorder(directory: $0, engine: engine) }
    }

    /// One coalesced sync. The engine hands a refresh already running to anyone who asks
    /// meanwhile, and that one may have read Google before the change this push is about,
    /// so a second runs when the first began before the push. In the background on iPhone
    /// there is no time for a second; the widget's own read and the next push cover it.
    private func syncForPush() async {
        guard let model else { return }
        let requested = Date()
        await model.refreshInBackground()
        guard let start = lastRunStart, start < requested, canRunAgain else { return }
        await model.refreshInBackground()
    }

    private var canRunAgain: Bool {
        #if os(iOS)
            UIApplication.shared.applicationState == .active
        #else
            true
        #endif
    }

    // MARK: Latency

    private func recordLatency(from before: CalendarData, to after: CalendarData, at synced: Date) {
        guard let recorder else { return }
        let pushes = pushes
        let receivingSince = receivingSince
        #if os(macOS)
            // Runs once `AppModel` has drawn the new data, which it does right after this call.
            let drawn = Task { @MainActor in Date() }
            let appShown: (@Sendable () async -> Date)? = { await drawn.value }
        #else
            let appShown: (@Sendable () async -> Date)? = nil
        #endif
        let previous = latencyWork
        latencyWork = Task.detached(priority: .utility) {
            await previous?.value
            await recorder.syncFinished(
                from: before, to: after, at: synced, pushes: pushes, limit: .seconds(3),
                appShown: appShown, receivingSince: receivingSince)
            #if os(iOS)
                PushLatency.exportForSharing()
            #endif
        }
    }

    // MARK: Channels

    private func reconcile() {
        guard coordinator != nil else { return }
        if reconciling != nil {
            reconcileAgain = true
            return
        }
        reconciling = Task { [weak self] in
            var next: Date?
            repeat {
                self?.reconcileAgain = false
                next = await self?.reconcileOnce()
            } while self?.reconcileAgain == true
            self?.reconciling = nil
            self?.schedule(next)
        }
    }

    private func reconcileOnce() async -> Date? {
        guard let coordinator, let model else { return nil }
        guard !model.accounts.isEmpty else {
            await coordinator.forgetIfNoAccounts()
            return nil
        }
        guard let appToken else { return nil }
        let visible = Set(model.calendars.map(\.id).filter { model.isVisible($0) })
        let wanted = WatchSet(accounts: model.accounts, calendars: model.calendars) {
            visible.contains($0)
        }
        let widget = await widgetToken(coordinator)
        return await coordinator.reconcile(wanted, tokens: .init(app: appToken, widget: widget))
    }

    private func widgetToken(_ coordinator: PushCoordinator) async -> String? {
        #if os(iOS)
            return await Self.currentWidgetToken() ?? coordinator.savedWidgetToken
        #else
            return nil
        #endif
    }

    #if os(iOS)
        /// WidgetKit's own copy of the Lock Screen widget's token; nil while no widget is on
        /// a Lock Screen.
        nonisolated private static func currentWidgetToken() async -> String? {
            await WidgetCenter.shared.currentPushInfo?.token.hexString
        }
    #endif

    /// Checks again when the next channel is due. Only a running app keeps the timer; the
    /// iPhone checks after its own syncs instead.
    private func schedule(_ next: Date?) {
        timer?.cancel()
        guard let next else { return }
        let delay = min(max(next.timeIntervalSinceNow, 60), 12 * 3600)
        timer = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
            self?.reconcile()
        }
    }
}
