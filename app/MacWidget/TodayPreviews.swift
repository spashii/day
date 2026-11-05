#if DEBUG
import DayCore
import SwiftUI
import WidgetKit

// One preview per family, stepping through the invented Wednesday at the golden Lock Screen
// times and then the states. Xcode's canvas switches between the full-color, accented and
// vibrant rendering modes, which is the one place those can be seen before the desktop.

/// Entries built by the real rules from the invented week, at fixed times on Wednesday
/// 4 November in the fixture's zone.
enum TodayPreviewData {
    private final class BundleToken {}

    static let times = ["07:50", "09:20", "11:40", "14:10", "16:20", "17:30"]

    private static let fixture: Fixture = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "invented-week", withExtension: "json"),
            let fixture = try? Fixture.load(from: url)
        else { preconditionFailure("invented-week.json is not in the widget bundle") }
        return fixture
    }()

    static func time(_ clock: String) -> Date {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return fixture.calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 4, hour: parts[0], minute: parts[1]))!
    }

    /// The first entry the provider would build at `clock`, `age` after the data was fetched.
    static func entry(
        at clock: String, age: TimeInterval = 5 * 60, signedOut: Int = 0, accounts: Int? = nil,
        events: [Event]? = nil
    ) -> TodayEntry {
        let now = time(clock)
        let snapshot = WidgetSnapshot(
            fetchedAt: now.addingTimeInterval(-age),
            accountCount: accounts ?? fixture.accounts.count, signedOutAccounts: signedOut,
            events: events ?? NextDemo.snapshot(from: fixture, now: fixture.now).events)
        return TodayProvider.entries(.found(snapshot), now: now, calendar: fixture.calendar)[0]
    }

    static var all: [TodayEntry] {
        times.map { entry(at: $0) } + [
            entry(at: "12:10", events: []),
            entry(at: "12:10", signedOut: 1),
            entry(at: "12:10", age: 3 * 3600),
            entry(at: "12:10", age: 25 * 3600),
            entry(at: "12:10", accounts: 0),
        ]
    }
}

#Preview("Small", as: .systemSmall) {
    TodayWidget()
} timeline: {
    for entry in TodayPreviewData.all { entry }
}

#Preview("Medium", as: .systemMedium) {
    TodayWidget()
} timeline: {
    for entry in TodayPreviewData.all { entry }
}

#Preview("Large", as: .systemLarge) {
    TodayWidget()
} timeline: {
    for entry in TodayPreviewData.all { entry }
}
#endif
