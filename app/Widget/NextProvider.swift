import DayCore
import Foundation
import WidgetKit

/// One Lock Screen timeline entry. It carries the text for all three families, so one
/// provider serves them and a family never recomputes what another shows.
struct NextEntry: TimelineEntry, Sendable {
    var content: WidgetEntry

    var date: Date {
        content.date
    }
}

/// Reads what the app wrote, hands it to `widgetTimeline`, and asks to run again in 30
/// minutes. About 48 reloads a day sits inside the 40 to 70 the system grants a widget that
/// is looked at often, and each reload is a chance to pick up new invitations.
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
                let entries = NextData.entries(
                    snapshot: .found(demo.snapshot), now: now, calendar: demo.calendar)
                completion(NextEntry(content: entries[0]))
            } else {
                let timeline = await Self.timeline(now: now)
                completion(timeline.entries[0])
            }
        }
    }

    func getTimeline(
        in context: Context, completion: @escaping @Sendable (Timeline<NextEntry>) -> Void
    ) {
        Task {
            completion(await Self.timeline(now: .now))
        }
    }

    /// One reload: read the snapshot, let stage two refresh it first when that is on, then
    /// build every entry from now on. Always at least one entry.
    static func timeline(now: Date) async -> Timeline<NextEntry> {
        var snapshot = NextData.readSnapshot()
        if WidgetFetch.isEnabled, let fresh = await WidgetFetch.refresh() {
            snapshot = .found(fresh)
        }
        let entries = NextData.entries(snapshot: snapshot, now: now, calendar: .current)
        return Timeline(
            entries: entries.map(NextEntry.init(content:)),
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
