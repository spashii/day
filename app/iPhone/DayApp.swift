import DayCore
import SwiftUI

/// The iPhone entry point. It picks the store, hands it to `RootView` and drives the model's
/// life cycle: a refresh at launch and on every return to the front (pull to refresh is the
/// views' own), a last read of the widget's days as the app leaves, and the background
/// refresh task, asked for again on every change of phase so a request is always pending.
///
/// The invented fixture runs when `-UseFixtures` is passed or no Google client is
/// configured; otherwise `AppModel` runs on the real engine.
@main
struct DayApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .calendarStore(AppLaunch.shared.store)
                .environment(\.handoff, .phone)
                .environment(\.openURL, PhoneOpener.action)
                .task { AppLaunch.shared.model?.start() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            AppLaunch.shared.scenePhaseDidChange(to: phase)
        }
        .backgroundTask(.appRefresh(DayIdentifiers.refreshTask)) {
            await BackgroundRefresh.perform()
        }
    }
}

/// The store this run uses, made once: the scene, the background task and the life cycle all
/// read the same one.
@MainActor
final class AppLaunch {
    static let shared = AppLaunch()

    let store: any CalendarStore
    /// Nil on the fixture, which has nothing to fetch.
    let model: AppModel?

    private init() {
        if let fixture = FixtureStore.fromLaunchArguments() {
            store = fixture
            model = nil
        } else if let live = AppModel.live() {
            store = live
            model = live
        } else {
            store = FixtureStore()
            model = nil
        }
    }

    func scenePhaseDidChange(to phase: ScenePhase) {
        guard let model else { return }
        switch phase {
        case .active:
            model.sceneDidBecomeActive()
            BackgroundRefresh.schedule(for: model)
        case .background:
            BackgroundRefresh.schedule(for: model)
            BackgroundTime.run("Final refresh") { await model.sceneDidEnterBackground() }
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}
