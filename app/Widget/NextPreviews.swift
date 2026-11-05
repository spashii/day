#if DEBUG
import DayCore
import SwiftUI
import WidgetKit

// One preview per family. Xcode draws an accessory family in the vibrant rendering mode the
// Lock Screen uses, and steps through the timeline entries: the six times of the invented
// Wednesday that the brief's Lock Screen table fixes, then every state.

/// Entries built by the real rules from the invented week, at fixed times, so a preview, a
/// golden test and the brief's table can be compared by eye.
enum NextPreviewData {
    private final class BundleToken {}

    /// Wednesday 4 November 2026 and its hours: `07:50`, `09:20`, `11:40`, `14:10`,
    /// `16:20`, `17:30`.
    static let goldenTimes = ["07:50", "09:20", "11:40", "14:10", "16:20", "17:30"]

    private static let fixture: Fixture = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "invented-week", withExtension: "json"),
            let fixture = try? Fixture.load(from: url)
        else { preconditionFailure("invented-week.json is not in the widget bundle") }
        return fixture
    }()

    static var calendar: Calendar {
        fixture.calendar
    }

    /// The fixture's own day, 4 November, at `HH:mm` in its zone.
    static func time(_ clock: String) -> Date {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return calendar.date(
            from: DateComponents(
                year: 2026, month: 11, day: 4, hour: parts[0], minute: parts[1]))!
    }

    /// The first entry the provider would build for `clock`, `age` after the data was
    /// fetched, with `signedOut` accounts needing a new sign-in.
    static func entry(
        at clock: String, age: TimeInterval = 5 * 60, signedOut: Int = 0,
        events: [Event]? = nil
    ) -> NextEntry {
        let now = time(clock)
        let snapshot = WidgetSnapshot(
            fetchedAt: now.addingTimeInterval(-age), accountCount: fixture.accounts.count,
            signedOutAccounts: signedOut,
            events: events ?? NextDemo.snapshot(from: fixture, now: fixture.now).events)
        return NextEntry(
            content: NextData.entries(snapshot: .found(snapshot), now: now, calendar: calendar)[0])
    }

    static var goldens: [NextEntry] {
        goldenTimes.map { entry(at: $0) }
    }

    /// Every state the brief names: no account, nothing ahead, an account signed out, data
    /// over 2 hours old (`As of 9:10`), data from yesterday (`As of Tue 23:10`) and over 24
    /// hours old (`Open to update`).
    static var states: [NextEntry] {
        [
            NextEntry(content: noAccountWidgetEntry(now: time("12:10"), calendar: calendar)),
            entry(at: "12:10", events: []),
            entry(at: "12:10", signedOut: 1),
            entry(at: "12:10", age: 3 * 3600),
            entry(at: "12:10", age: 13 * 3600),
            entry(at: "12:10", age: 25 * 3600),
        ]
    }

    static var all: [NextEntry] {
        goldens + states
    }
}

#Preview("Inline", as: .accessoryInline) {
    NextWidget()
} timeline: {
    for entry in NextPreviewData.all { entry }
}

#Preview("Rectangular", as: .accessoryRectangular) {
    NextWidget()
} timeline: {
    for entry in NextPreviewData.all { entry }
}

#Preview("Circular", as: .accessoryCircular) {
    NextWidget()
} timeline: {
    for entry in NextPreviewData.all { entry }
}

// Always-On has no timeline preview of its own, so the rectangular view is drawn directly
// with the luminance flag the system sets there: line 3 gone, line 2 in clock times.
#Preview("Rectangular, Always-On", traits: .fixedLayout(width: 160, height: 72)) {
    NextRectangularView(
        lines: NextPreviewData.entry(at: "09:20").content.rectangular, isLuminanceReduced: true)
}
#endif
