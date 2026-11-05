import DayCore
import SwiftUI
import WidgetKit

/// Draws the Lock Screen widget's own views (`NextInlineView`, `NextRectangularView`,
/// `NextCircularView`) for every row of the golden Lock Screen table and every widget state,
/// one PNG per row, for tools/screenshots.sh. Launched with `-ShotsTo <folder>`; it writes
/// `done.txt` (file, tab, caption per line) last, which is what the script waits for.
///
/// The widget's text comes from `widgetTimeline` through `NextData`, exactly as on the Lock
/// Screen. What differs is the rendering: these are ordinary SwiftUI renders on a black
/// ground, not the Lock Screen's vibrant mode.
@main
struct WidgetShotsApp: App {
    var body: some Scene {
        WindowGroup {
            Text(verbatim: "Drawing the widget views")
                .task { await WidgetShots.run() }
        }
    }
}

@MainActor
enum WidgetShots {
    private static let fixture: Fixture = {
        guard let url = Bundle.main.url(forResource: "invented-week", withExtension: "json"),
            let fixture = try? Fixture.load(from: url)
        else { preconditionFailure("invented-week.json is not in the bundle") }
        return fixture
    }()

    /// One row of the picture: the moment, how old the data is, and what is in it.
    struct Row {
        var file: String
        var caption: String
        var clock: String
        var age: TimeInterval = 5 * 60
        var signedOut = 0
        var accounts: Int? = nil
        var events: [Event]? = nil
        /// The next event's calendar symbol, as the provider attaches it.
        var symbol: NextSymbol? = nil
    }

    static func run() async {
        guard let folder = UserDefaults.standard.string(forKey: "ShotsTo") else { return }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        var rows: [Row] = []
        let golden = ["07:50", "09:20", "11:40", "14:10", "16:20", "17:30"]
        for clock in golden {
            rows.append(
                Row(
                    file: "golden-\(clock.replacingOccurrences(of: ":", with: "")).png",
                    caption: "\(clock), the golden Lock Screen table", clock: clock))
        }
        rows += [
            Row(
                file: "symbol-1210.png",
                caption: "12:10 with a symbol on the next event's calendar (Work)", clock: "12:10",
                symbol: NextSymbol(name: "briefcase", label: "Work")),
            Row(file: "state-no-account.png", caption: "No account", clock: "12:10", accounts: 0),
            Row(file: "state-nothing-ahead.png", caption: "Nothing in the next 7 days", clock: "12:10", events: []),
            Row(file: "state-signed-out.png", caption: "One account signed out, at 12:10", clock: "12:10", signedOut: 1),
            Row(file: "state-as-of.png", caption: "Data 3 hours old, at 12:10", clock: "12:10", age: 3 * 3600),
            Row(file: "state-open-to-update.png", caption: "Data 25 hours old, at 12:10", clock: "12:10", age: 25 * 3600),
        ]

        var done: [String] = []
        for row in rows {
            let content = entry(for: row)
            let image = render(WidgetRow(entry: content, symbol: row.symbol))
            if let png = image?.pngData() {
                try? png.write(to: url.appending(path: row.file), options: .atomic)
                done.append("\(row.file)\t\(row.caption): \(content.inline)")
            }
        }
        try? done.joined(separator: "\n").appending("\n")
            .write(to: url.appending(path: "done.txt"), atomically: true, encoding: .utf8)
    }

    /// The first entry the provider would build at the row's moment on Wednesday 4 November.
    ///
    /// Line 2's countdown is `Text(.currentDate, format: .reference(to:))`, which reads the
    /// device clock when it draws and cannot be handed a fixed time. For a row that shows it,
    /// the whole day is moved so the row's moment is the real now, and drawn in a zone whose
    /// offset keeps every clock time as written; only the date changes, and no such row names
    /// a weekday.
    private static func entry(for row: Row) -> WidgetEntry {
        let calendar = fixture.calendar
        let moment = time(row.clock, calendar: calendar)
        let first = entries(row, now: moment, calendar: calendar)
        guard first.rectangular.when?.relativeTo != nil else { return first }

        // Whole seconds, so every clock time lands exactly on its minute; 20 seconds ahead, so
        // `in 10 min` still reads 10 when the render lands.
        let shift = Date.now.addingTimeInterval(20).timeIntervalSince(moment).rounded()
        let now = moment.addingTimeInterval(shift)
        let offset = calendar.timeZone.secondsFromGMT(for: moment)
        var seconds = offset - Int(shift)
        while seconds > 14 * 3600 { seconds -= 86_400 }
        while seconds < -12 * 3600 { seconds += 86_400 }
        var moved = calendar
        moved.timeZone = TimeZone(secondsFromGMT: seconds) ?? calendar.timeZone
        let events = (row.events ?? baseEvents).map { shifted($0, by: shift) }
        var copy = row
        copy.events = events
        return entries(copy, now: now, calendar: moved)
    }

    private static var baseEvents: [Event] {
        NextDemo.snapshot(from: fixture, now: fixture.now).events
    }

    private static func entries(_ row: Row, now: Date, calendar: Calendar) -> WidgetEntry {
        let accounts = row.accounts ?? fixture.accounts.count
        guard accounts > 0 else { return noAccountWidgetEntry(now: now, calendar: calendar) }
        let snapshot = WidgetSnapshot(
            fetchedAt: now.addingTimeInterval(-row.age), accountCount: accounts,
            signedOutAccounts: row.signedOut, events: row.events ?? baseEvents)
        return NextData.entries(snapshot: .found(snapshot), now: now, calendar: calendar)[0]
    }

    private static func shifted(_ event: Event, by seconds: TimeInterval) -> Event {
        var event = event
        if case .timed(let start, let end, let zone) = event.time {
            event.time = .timed(
                start: start.addingTimeInterval(seconds), end: end.addingTimeInterval(seconds),
                authoredZone: zone)
        }
        event.originalStart = event.originalStart?.addingTimeInterval(seconds)
        return event
    }

    private static func time(_ clock: String, calendar: Calendar) -> Date {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 4, hour: parts[0], minute: parts[1]))!
    }

    private static func render(_ view: some View) -> UIImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 3
        return renderer.uiImage
    }
}

/// The three families at their Lock Screen sizes on a 393 pt iPhone, plus the rectangular one
/// under Always-On, side by side with their names under them.
private struct WidgetRow: View {
    let entry: WidgetEntry
    var symbol: NextSymbol? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            slot("Inline") {
                NextInlineView(
                    text: entry.inline, showsEvent: entry.showsEvent,
                    symbol: entry.showsEvent ? symbol : nil)
                    .lineLimit(1)
                    .frame(width: 234, height: 26, alignment: .leading)
            }
            slot("Rectangular") {
                NextRectangularView(lines: entry.rectangular, isLuminanceReduced: false)
                    .frame(width: 160, height: 72, alignment: .topLeading)
            }
            slot("Circular") {
                NextCircularView(content: entry.circular, symbol: entry.circular.isTime ? symbol : nil)
                    .frame(width: 72, height: 72)
            }
            slot("Rectangular, Always-On") {
                NextRectangularView(lines: entry.rectangular, isLuminanceReduced: true)
                    .frame(width: 160, height: 72, alignment: .topLeading)
                    .environment(\.isLuminanceReduced, true)
            }
        }
        .padding(20)
        .foregroundStyle(.primary)
        .background(Color.black)
    }

    private func slot(_ name: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
            Text(verbatim: name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
