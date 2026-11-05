import DayCore
import Foundation
import WidgetKit

/// One Lock Screen timeline entry. It carries the text for all three families and the next
/// event's calendar symbol, so one provider serves them and a family never recomputes what
/// another shows.
struct NextEntry: TimelineEntry, Sendable {
    var content: WidgetEntry
    /// The symbol of the next event's calendar; nil for none.
    var symbol: NextSymbol? = nil

    var date: Date {
        content.date
    }
}

/// Reads Google's changes (stage two, `WidgetFetch`), falls back to what the app wrote, hands
/// the snapshot to `widgetTimeline`, and asks to run again in 30 minutes. About 48 reloads a
/// day sits inside the 40 to 70 the system grants a widget that is looked at often, and each
/// reload picks up whatever changed since, including new invitations. The app adds a reload
/// only when its own refresh changed what the widget shows.
struct NextProvider: TimelineProvider {
    /// How long until the system should call `getTimeline` again.
    static let reloadAfter: TimeInterval = 30 * 60

    /// Synchronous: touches neither disk nor network. The system redacts it for the
    /// gallery's loading state, so the words only need to be the shape of the real ones.
    func placeholder(in context: Context) -> NextEntry {
        NextEntry(content: Self.placeholderContent(now: .now))
    }

    /// The gallery gets invented events through the real rules; the Lock Screen gets the
    /// first entry of the real timeline.
    func getSnapshot(in context: Context, completion: @escaping @Sendable (NextEntry) -> Void) {
        let isPreview = context.isPreview
        Task {
            let now = Date.now
            if isPreview, let demo = NextDemo.loadAlways(now: now) {
                // Invented calendars, which no symbol is chosen for.
                let entries = NextData.entries(
                    snapshot: .found(demo.snapshot), now: now, calendar: demo.calendar)
                completion(NextEntry(content: entries[0]))
            } else {
                // The system wants this one quickly (transitions, the edit sheet), so it
                // draws from the file and leaves reading Google to the timeline.
                let timeline = await Self.timeline(now: now, fetch: false)
                completion(timeline.entries[0])
            }
        }
    }

    func getTimeline(
        in context: Context, completion: @escaping @Sendable (Timeline<NextEntry>) -> Void
    ) {
        Task {
            completion(await Self.timeline(now: .now))
            LatencyLog.widgetDrew(.iphoneWidget, in: try? CacheDirectory.shared())
        }
    }

    /// One reload: read the snapshot, let stage two refresh it first with its hard deadline,
    /// then build every entry from now on. Always at least one entry.
    static func timeline(now: Date, fetch: Bool = true) async -> Timeline<NextEntry> {
        var snapshot = NextData.readSnapshot()
        if fetch, WidgetFetch.isEnabled, let fresh = await WidgetFetch.refresh() {
            snapshot = .found(fresh)
        }
        let entries = NextData.entries(snapshot: snapshot, now: now, calendar: .current)
        let source = NextData.source(snapshot: snapshot, now: now, calendar: .current)
        let symbols = NextSymbol.resolve(
            entries, events: source?.events, calendar: source?.calendar ?? .current)
        return Timeline(
            entries: zip(entries, symbols).map { NextEntry(content: $0, symbol: $1) },
            policy: .after(now.addingTimeInterval(reloadAfter)))
    }

    /// Invented, fixed text in the shape of a real entry. Built in code so it needs no file.
    static func placeholderContent(now: Date) -> WidgetEntry {
        WidgetEntry(
            date: now,
            inline: "14:00 Investor call",
            rectangular: RectangularLines(
                title: "Investor call",
                when: WhenLine(text: "14:00 to 15:00"),
                after: "16:00 Weekly planning"),
            circular: .time("14:00", weekday: nil, period: nil),
            url: nil)
    }
}
