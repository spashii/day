import AppKit
import DayCore
import SwiftUI
import WidgetKit

/// Draws the desktop widget's own views (`TodayFamilyView`) in the small, medium and large
/// families to PNG files, on the invented week only, for tools/screenshots.sh. Launched
/// with `-ShotsTo <folder>`; it writes `index.html`, `timeline.txt` and `done.txt` (file, tab,
/// caption per line) last, which is what the script waits for.
///
/// The content comes from `TodayProvider.entries` exactly as on the desktop. What differs is
/// the drawing: an ordinary render at the families' Mac sizes, with the widget background and
/// margins drawn here, since only WidgetKit draws a widget's container. The desktop's dimmed
/// (vibrant) and accented styles are composited by the system and cannot be rendered here;
/// the "without color" pictures stand in for them by dropping the background and every color,
/// which is the part of those styles the layout has to survive. The accented and clear looks
/// go one step further and set the accented rendering mode, but WidgetKit alone puts the accent
/// group (`widgetAccentable`) in the tint, so there too the symbols and rules are seen
/// without it: what these pictures prove is that nothing relies on color to be seen.
@main
struct MacWidgetShots {
    @MainActor static func main() {
        guard let path = UserDefaults.standard.string(forKey: "ShotsTo") else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Shots(folder: folder).run()
    }
}

@MainActor
struct Shots {
    let folder: URL

    private static let fixture: Fixture = {
        guard let url = Bundle.main.url(forResource: "invented-week", withExtension: "json"),
            let fixture = try? Fixture.load(from: url)
        else { preconditionFailure("invented-week.json is not in the bundle") }
        return fixture
    }()

    /// One picture: the moment, how old the data is, and what is in it.
    struct Row {
        var file: String
        var caption: String
        var clock: String
        var age: TimeInterval = 5 * 60
        var signedOut = 0
        var accounts: Int? = nil
        var events: [Event]? = nil
        /// Whether the invented calendar symbols are chosen: the work calendar, the personal
        /// one and the birthdays wear one, the holidays do not.
        var symbols = false
    }

    enum Look: String, CaseIterable {
        case light, dark, dimmed, accented, clear

        var scheme: ColorScheme { self == .light ? .light : .dark }
    }

    func run() {
        var rows: [Row] = []
        for clock in ["07:50", "09:20", "11:40", "14:10", "16:20", "17:30"] {
            rows.append(
                Row(
                    file: "today-\(clock.replacingOccurrences(of: ":", with: ""))",
                    caption: "Wednesday \(clock), the invented week", clock: clock))
        }
        for clock in ["09:20", "12:10", "17:30"] {
            rows.append(
                Row(
                    file: "symbols-\(clock.replacingOccurrences(of: ":", with: ""))",
                    caption: "Wednesday \(clock) with calendar symbols chosen", clock: clock,
                    symbols: true))
        }
        rows.append(
            Row(
                file: "busy-1210", caption: "12:10 on a crowded day, cut behind 2 more",
                clock: "12:10", events: crowdedDay()))
        rows += [
            Row(file: "state-nothing", caption: "Nothing scheduled", clock: "12:10", events: []),
            Row(file: "state-signed-out", caption: "One account signed out, at 12:10", clock: "12:10", signedOut: 1),
            Row(file: "state-as-of", caption: "Data 3 hours old, at 12:10", clock: "12:10", age: 3 * 3600),
            Row(file: "state-open-to-update", caption: "Data 25 hours old, at 12:10", clock: "12:10", age: 25 * 3600),
            Row(file: "state-no-account", caption: "No account", clock: "12:10", accounts: 0),
        ]

        var done: [String] = []
        for row in rows {
            let content = entry(for: row).content
            for look in Look.allCases
            where look == .light || look == .dark
                || (look == .dimmed && (row.file.hasPrefix("today") || row.symbols))
                || ((look == .accented || look == .clear) && row.symbols)
            {
                let file = "\(row.file)-\(look.rawValue).png"
                let view = FamiliesRow(content: content, look: look)
                if write(view, to: file) {
                    done.append("\(file)\t\(row.caption), \(caption(look)). Opens \(urls(content))")
                }
            }
        }

        try? timeline().write(
            to: folder.appending(path: "timeline.txt"), atomically: true, encoding: .utf8)
        try? index(done).write(
            to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try? done.joined(separator: "\n").appending("\n")
            .write(to: folder.appending(path: "done.txt"), atomically: true, encoding: .utf8)
    }

    private func caption(_ look: Look) -> String {
        switch look {
        case .light: "light"
        case .dark: "dark"
        case .dimmed: "without color or background, standing in for the dimmed and accented styles"
        case .accented: "accented rendering mode on a dark desktop, without color or background (the system's tint is not drawn here)"
        case .clear: "clear style over a wallpaper, without color (the system's glass and tint are not drawn here)"
        }
    }

    /// Where a click goes, per family.
    private func urls(_ content: TodayContent) -> String {
        var small = content.url
        if case .day(let day) = content, let next = day.next { small = next.url }
        return "small \(small.absoluteString), medium and large \(content.url.absoluteString)"
    }

    // MARK: Data

    /// The first entry the provider would build at the row's moment on Wednesday 4 November.
    private func entry(for row: Row) -> TodayEntry {
        let now = time(row.clock)
        let accounts = row.accounts ?? Self.fixture.accounts.count
        let snapshot = WidgetSnapshot(
            fetchedAt: now.addingTimeInterval(-row.age), accountCount: accounts,
            signedOutAccounts: row.signedOut, events: row.events ?? baseEvents)
        return TodayProvider.entries(
            .found(snapshot, symbols: row.symbols ? inventedSymbols : CalendarSymbolMap()), now: now,
            calendar: Self.fixture.calendar)[0]
    }

    /// Symbols for three of the fixture's calendars; the holidays are left on their rule alone.
    private var inventedSymbols: CalendarSymbolMap {
        var map = CalendarSymbolMap()
        let chosen = [
            ("you@acme.com", "briefcase"), ("you@gmail.com", "house"),
            ("addressbook#contacts@group.v.calendar.google.com", "birthday.cake"),
        ]
        for calendar in Self.fixture.calendars {
            if let name = chosen.first(where: { $0.0 == calendar.id.googleID })?.1 {
                map.set(CalendarSymbol.named(name), for: calendar.id)
            }
        }
        return map
    }

    private var baseEvents: [Event] {
        NextDemo.snapshot(from: Self.fixture, now: Self.fixture.now).events
    }

    /// The invented Wednesday with eight more invented meetings, one every half hour from
    /// 12:30, so the medium and large families have more than fits.
    private func crowdedDay() -> [Event] {
        guard let template = baseEvents.first(where: { !$0.isAllDay }) else { return baseEvents }
        let titles = [
            "Hiring sync", "Roadmap review", "Vendor call", "Board prep", "Office hours",
            "Pairing", "Retro", "Planning poker",
        ]
        let extra = titles.enumerated().map { index, title -> Event in
            var event = template
            event.id = EventID(calendar: template.id.calendar, googleID: "crowded-\(index)")
            event.iCalUID = "crowded-\(index)"
            event.originalStart = nil
            event.title = title
            event.isRecurring = index.isMultiple(of: 2)
            event.location = nil
            event.attendeeCount = 0
            let start = time("12:30").addingTimeInterval(TimeInterval(index) * 30 * 60)
            event.time = .timed(start: start, end: start.addingTimeInterval(25 * 60), authoredZone: nil)
            event.colorKey = [.teal, .orange, .purple, .green][index % 4]
            return event
        }
        return baseEvents + extra
    }

    private func time(_ clock: String) -> Date {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return Self.fixture.calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 4, hour: parts[0], minute: parts[1]))!
    }

    /// The timeline a reload at 07:50 builds, one line per entry, to check its dates by eye:
    /// every start and end, each midnight, and the data's 2 and 24 hour marks.
    private func timeline() -> String {
        let calendar = Self.fixture.calendar
        let now = time("07:50")
        let snapshot = WidgetSnapshot(
            fetchedAt: now.addingTimeInterval(-5 * 60), accountCount: 2, signedOutAccounts: 0,
            events: baseEvents)
        let entries = TodayProvider.entries(.found(snapshot), now: now, calendar: calendar)
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: calendar.timeZone)
        return entries.map { entry in
            var line = entry.date.formatted(format)
            switch entry.content {
            case .message(let text, _):
                line += "\t\(text)"
            case .day(let day):
                line += "\tsmall: \(day.next.map { "\($0.start) \($0.event.title)" } ?? TodayContent.nothingScheduled)"
                line += "\tahead: \(day.ahead.filter(\.isEvent).count), ended: \(day.ended.count)"
                if let status = day.status { line += "\t\(status)" }
            }
            return line
        }.joined(separator: "\n") + "\n"
    }

    // MARK: Drawing

    private func write(_ view: some View, to file: String) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: folder.appending(path: file), options: .atomic)) != nil
    }

    private func index(_ done: [String]) -> String {
        let items = done.map { line -> String in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return "<figure><img src=\"\(parts[0])\" width=\"50%\"><figcaption>\(parts.count > 1 ? parts[1] : "")</figcaption></figure>"
        }
        return """
            <!doctype html><meta charset="utf-8"><title>Day desktop widget</title>
            <style>body{font:14px -apple-system,system-ui;margin:24px;background:#f4f4f4}figure{margin:0 0 32px}img{display:block;min-width:600px}</style>
            <p>Desktop widget "Today", invented week, drawn by tools/shots/MacWidget. <a href="timeline.txt">timeline.txt</a></p>
            \(items.joined(separator: "\n"))
            """
    }
}

/// The three families side by side at their Mac sizes, each on its own widget background.
private struct FamiliesRow: View {
    let content: TodayContent
    let look: Shots.Look

    /// Sizes in points. The HIG gives no macOS table; these are its largest iPhone sizes,
    /// close to the desktop's. The layout takes whatever height it gets, so a few points
    /// either way change only how many rows fit.
    static let sizes: [(WidgetFamily, CGSize)] = [
        (.systemSmall, CGSize(width: 170, height: 170)),
        (.systemMedium, CGSize(width: 364, height: 170)),
        (.systemLarge, CGSize(width: 364, height: 382)),
    ]

    /// The content margin. WidgetKit sets it only inside a widget and publishes no macOS
    /// value; the HIG says the desktop's is smaller than the usual 16 and names 11 as the
    /// tighter margin, so the pictures use that.
    static let margin: CGFloat = 11

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(Self.sizes.indices, id: \.self) { index in
                widget(Self.sizes[index].0, size: Self.sizes[index].1)
            }
        }
        .padding(24)
        .background(ground)
        .environment(\.colorScheme, look.scheme)
    }

    @ViewBuilder
    private func widget(_ family: WidgetFamily, size: CGSize) -> some View {
        let face = TodayFamilyView(family: family, content: content)
            .padding(Self.margin)
            .frame(width: size.width, height: size.height)
        switch look {
        case .light, .dark:
            face.background(.background, in: .rect(cornerRadius: 22, style: .continuous))
        case .dimmed:
            face
                .environment(\.widgetRenderingMode, .vibrant)
                .grayscale(1)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 22, style: .continuous))
        case .accented:
            face
                .environment(\.widgetRenderingMode, .accented)
                .grayscale(1)
                .background(.white.opacity(0.14), in: .rect(cornerRadius: 22, style: .continuous))
        case .clear:
            face
                .environment(\.widgetRenderingMode, .accented)
                .grayscale(1)
                .background(.white.opacity(0.22), in: .rect(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1))
        }
    }

    @ViewBuilder
    private var ground: some View {
        switch look {
        case .light: Color(white: 0.86)
        case .dark: Color(white: 0.12)
        case .dimmed: Color(red: 0.22, green: 0.27, blue: 0.36)
        case .accented: Color(red: 0.16, green: 0.20, blue: 0.30)
        case .clear:
            LinearGradient(
                colors: [Color(red: 0.95, green: 0.62, blue: 0.40), Color(red: 0.30, green: 0.35, blue: 0.62)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
