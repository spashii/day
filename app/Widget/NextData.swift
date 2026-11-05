import DayCore
import Foundation

/// Where one reload of the widget gets its events, and how they become timeline entries.
///
/// Order: the snapshot the app wrote, else invented data while no Google client exists, else
/// the `Add a Google account` state. Every text on screen comes from `widgetTimeline` and
/// `noAccountWidgetEntry`; nothing here words anything except the one `Open to update` line
/// for a snapshot that cannot be read.
enum NextData {
    /// What reading the App Group container found.
    enum Snapshot {
        /// No file: the app has never written one, which means no account yet.
        case missing
        /// A file the widget cannot decode.
        case unreadable
        case found(WidgetSnapshot)
    }

    /// Every entry for a reload at `now`, in date order, never empty.
    static func entries(snapshot: Snapshot, now: Date, calendar: Calendar) -> [WidgetEntry] {
        switch snapshot {
        case .missing:
            if let demo = NextDemo.load(now: now) {
                return timeline(demo.snapshot, now: now, calendar: demo.calendar)
            }
            return [noAccountWidgetEntry(now: now, calendar: calendar)]
        case .unreadable:
            return [openToUpdate(now: now, calendar: calendar)]
        case .found(let snapshot):
            guard snapshot.accountCount > 0 else {
                return [noAccountWidgetEntry(now: now, calendar: calendar)]
            }
            return timeline(snapshot, now: now, calendar: calendar)
        }
    }

    /// Reads `widget-snapshot.json` from the App Group container, where the app writes it
    /// and, in stage two, `WidgetFetch` does too.
    static func readSnapshot() -> Snapshot {
        // No container means a build without the App Group entitlement, which can share
        // nothing, so it reads as no snapshot.
        guard let cache = try? CacheDirectory.shared() else { return .missing }
        if let snapshot = WidgetSnapshot.read(from: cache) { return .found(snapshot) }
        let exists = FileManager.default.fileExists(
            atPath: cache.fileURL(WidgetSnapshot.fileName).path(percentEncoded: false))
        return exists ? .unreadable : .missing
    }

    private static func timeline(
        _ snapshot: WidgetSnapshot, now: Date, calendar: Calendar
    ) -> [WidgetEntry] {
        let entries = widgetTimeline(
            events: snapshot.events, now: now, fetchedAt: snapshot.fetchedAt,
            signedOutAccounts: snapshot.signedOutAccounts, calendar: calendar)
        // The rules always return at least the entry for now; this guards the Lock Screen
        // against a blank slot if that ever stops holding.
        guard !entries.isEmpty else { return [openToUpdate(now: now, calendar: calendar)] }
        return entries.sorted { $0.date < $1.date }
    }

    /// A snapshot exists but cannot be used: inline reads `Open to update`, the circular
    /// slot shows the symbol, and a tap opens the app, which rewrites the file.
    private static func openToUpdate(now: Date, calendar: Calendar) -> WidgetEntry {
        let today = DayLink.day(CivilDate(now, in: calendar)).url
        return WidgetEntry(
            date: now,
            inline: "Open to update",
            rectangular: RectangularLines(title: "Open to update"),
            circular: .symbol,
            url: today)
    }
}
