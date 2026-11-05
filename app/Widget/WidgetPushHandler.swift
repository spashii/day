import DayCore
import WidgetKit

/// Receives the Lock Screen widget's WidgetKit push token. A push to it (`content-changed`)
/// makes WidgetKit reload the timeline, and the reload runs the widget's own read of Google
/// (`WidgetFetch`), so the Lock Screen catches up even when iOS does not wake the app.
/// WidgetKit rations these pushes like reloads; the 30-minute timeline stays the fallback.
struct DayWidgetPushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        // No widget on any Lock Screen: the relay need not push to it.
        let token = widgets.isEmpty ? nil : pushInfo.token
        guard let cache = try? CacheDirectory.shared() else { return }
        Task {
            await WidgetPushToken.publish(
                token, store: PushStore(directory: cache), environment: .detect())
        }
    }
}
