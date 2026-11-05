import DayCore
import SwiftUI

/// Fixture stores for `#Preview`, on the invented week. Previews never see real data.
@MainActor
enum PreviewStore {
    /// The invented Wednesday at `time` (`"12:10"`), or on another day with a full
    /// `"2026-11-05T09:00"`.
    static func make(at time: String = "12:10", state: FixtureStore.State = .normal) -> FixtureStore {
        let store = FixtureStore(state: state)
        let text = time.contains("T") ? time : "\(store.today.isoString)T\(time)"
        if let now = FixtureStore.parseNow(text, calendar: store.calendar) {
            store.now = now
        }
        return store
    }
}
