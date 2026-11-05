import AppKit
import DayCore
import SwiftUI
import WidgetKit

/// The desktop widget in the family it is placed in, on the system's own widget background.
///
/// System fonts and colors only, with the Day list's row: times, the 2 pt rule in the event's
/// color, the title in Semibold for one-offs and Regular for recurring. The desktop dims a
/// widget (vibrant) whenever a window is in front, and draws it accented in the tinted and
/// clear styles; both drop the background and the colors, so the hierarchy rests on weight
/// and on primary against secondary text, and the rules join the accent group so they keep
/// standing apart from the text.
struct TodayWidgetView: View {
    let entry: TodayEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        TodayFamilyView(family: family, content: entry.content)
            .containerBackground(.background, for: .widget)
    }
}

/// One family's content. Takes the family as a value rather than reading it, so the shots
/// harness can draw every family outside a widget, where the environment cannot be set.
struct TodayFamilyView: View {
    let family: WidgetFamily
    let content: TodayContent

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                TodaySmallView(content: content)
            case .systemMedium:
                TodayMediumView(content: content)
            default:
                TodayLargeView(content: content)
            }
        }
        .environment(\.todaySymbols, symbols)
        .widgetURL(url)
    }

    private var symbols: CalendarSymbolMap {
        if case .day(let day) = content { return day.symbols }
        return CalendarSymbolMap()
    }

    /// A click anywhere opens Day on the day shown: the small family's event's day (which is
    /// tomorrow once today is over), today otherwise.
    private var url: URL {
        if family == .systemSmall, case .day(let day) = content, let next = day.next {
            return next.url
        }
        return content.url
    }
}

// MARK: - Families

/// The next event: its times, its title on up to three lines and the one unusual thing about
/// it, beside its calendar's rule. The title is larger than the list's, because it is the
/// whole widget.
struct TodaySmallView: View {
    let content: TodayContent

    var body: some View {
        switch content {
        case .message(let text, _):
            TodayMessage(text: text)
        case .day(let day):
            if let next = day.next {
                TodayNextView(next: next)
            } else {
                TodayMessage(text: day.emptyMessage)
            }
        }
    }
}

/// Today's events still to come, as many as fit, with the all-day lines while there is room.
struct TodayMediumView: View {
    let content: TodayContent

    var body: some View {
        switch content {
        case .message(let text, _):
            TodayMessage(text: text)
        case .day(let day):
            VStack(alignment: .leading, spacing: Spacing.cell) {
                let layouts = day.mediumLayouts
                if layouts.isEmpty {
                    TodayMessage(text: day.emptyMessage)
                } else {
                    TodayFitting(layouts: layouts, calendar: day.calendar)
                }
                TodayStatus(text: day.status)
            }
        }
    }
}

/// All of today under its date, ended events dimmed in place or folded into the Earlier row.
struct TodayLargeView: View {
    let content: TodayContent

    var body: some View {
        switch content {
        case .message(let text, _):
            TodayMessage(text: text)
        case .day(let day):
            VStack(alignment: .leading, spacing: Spacing.cell) {
                Text(verbatim: Formatting.dayHeader(day.day, calendar: day.calendar))
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if day.allDay.isEmpty, day.ended.isEmpty, day.ahead.isEmpty {
                    TodayMessage(text: day.emptyMessage)
                } else {
                    TodayFitting(layouts: day.largeLayouts, calendar: day.calendar)
                }
                TodayStatus(text: day.status)
            }
        }
    }
}

// MARK: - Pieces

/// Draws the first layout that fits the height left, so a family shows as many rows as its
/// size and the system's text size allow, and cuts at a whole row, never mid-row.
struct TodayFitting: View {
    let layouts: [[TodayRow]]
    let calendar: Calendar

    var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach(layouts.indices, id: \.self) { index in
                TodayRows(rows: layouts[index], calendar: calendar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct TodayRows: View {
    let rows: [TodayRow]
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cell) {
            ForEach(rows) { row in
                TodayRowView(row: row, calendar: calendar)
            }
        }
    }
}

struct TodayRowView: View {
    let row: TodayRow
    let calendar: Calendar

    var body: some View {
        switch row {
        case .allDay(let event, let position):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                TodaySymbol(event: event)
                Text(verbatim: position.map { "\(event.title), \($0)" } ?? event.title)
                    .font(.subheadline)
                    .foregroundStyle(event.onHolidayCalendar ? .secondary : .primary)
                    .lineLimit(1)
                    .privacySensitive()
            }
        case .allDayMore(let text):
            TodayLine(text: text)
        case .earlier(let events):
            TodayLine(text: Formatting.earlier(events))
                .privacySensitive()
        case .past(let event):
            TodayEventRow(event: event, secondLine: nil, past: true, calendar: calendar)
        case .event(let event, let secondLine):
            TodayEventRow(event: event, secondLine: secondLine, calendar: calendar)
        case .nothingElse(let text):
            Text(verbatim: text)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .gap(let text, _), .more(let text):
            // Aligned with the titles, as the Day list's gap rows are.
            HStack(spacing: Spacing.cell) {
                TodayTimeColumn(calendar: calendar) { EmptyView() }
                Color.clear.frame(width: 2, height: 1)
                TodayLine(text: text)
            }
        }
    }
}

/// The Day list's event row: start and end in the time column, the rule, the title and one
/// unusual second line. An ended event is drawn in the secondary color, as the Day list's
/// unfolded Earlier rows are.
struct TodayEventRow: View {
    let event: Event
    let secondLine: String?
    var past = false
    let calendar: Calendar

    @Environment(\.todaySymbols) private var symbols

    var body: some View {
        let start = Formatting.time(event.time.start(in: calendar), calendar: calendar)
        let end = Formatting.time(event.time.end(in: calendar), calendar: calendar)
        HStack(alignment: .top, spacing: Spacing.cell) {
            TodayTimeColumn(calendar: calendar) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: start)
                        .foregroundStyle(past ? .secondary : .primary)
                    Text(verbatim: end)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .monospacedDigit()
            }
            TodayRule(color: event.markColor)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                    TodaySymbol(event: event, past: past)
                    Text(event.title)
                        .font(.body)
                        .fontWeight(event.isRecurring ? .regular : .semibold)
                        .foregroundStyle(past ? .secondary : .primary)
                        .lineLimit(1)
                        .privacySensitive()
                }
                if let secondLine {
                    Text(verbatim: secondLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(verbatim: [event.title, "\(start) to \(end)", secondLine, symbolLabel].compactMap { $0 }
                .joined(separator: ", ")))
    }

    private var symbolLabel: String? {
        symbols.symbol(for: event).flatMap { $0.isDrawableOnMac ? $0.label : nil }
    }
}

/// The small family's event, in the Day list's stacked form: `14:00 to 15:00` above the title,
/// or `Tomorrow 9:30` once it is not today.
struct TodayNextView: View {
    let next: TodayNext

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.cell) {
            TodayRule(color: next.event.markColor)
            VStack(alignment: .leading, spacing: Spacing.row) {
                // The title wraps over three lines, so the symbol leads the line above it.
                HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                    TodaySymbol(event: next.event)
                    when
                        .font(.subheadline)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Text(next.event.title)
                    .font(.title2)
                    .fontWeight(next.event.isRecurring ? .regular : .semibold)
                    .lineLimit(3)
                    .privacySensitive()
                if let secondLine = next.secondLine {
                    Text(verbatim: secondLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .privacySensitive()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var when: Text {
        guard let end = next.end else { return Text(verbatim: next.start) }
        return Text("\(Text(verbatim: next.start)) to \(Text(verbatim: end).foregroundStyle(.secondary))")
    }
}

/// The symbols the person gave their calendars, for the rows of the family being drawn.
private struct TodaySymbolsKey: EnvironmentKey {
    static var defaultValue: CalendarSymbolMap { CalendarSymbolMap() }
}

extension EnvironmentValues {
    var todaySymbols: CalendarSymbolMap {
        get { self[TodaySymbolsKey.self] }
        set { self[TodaySymbolsKey.self] = newValue }
    }
}

extension CalendarSymbol {
    /// Whether this system can draw the symbol; one it cannot would leave an empty space.
    var isDrawableOnMac: Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}

/// The symbol of an event's calendar, small, leading its title or time. Nothing when the
/// calendar has none, so that row is as it was.
///
/// Drawn in the calendar's color in the full-color style. The dimmed, accented and clear styles
/// drop every color, and a dark calendar color would then all but vanish, so outside full
/// color the symbol is primary, as the title is, and joins the accent group as the rule does:
/// the tint sets it apart from the text, and it stays visible when the color is gone. An
/// ended event's symbol is secondary, like its title. The symbol is private with the title,
/// because it says what kind of event is coming.
struct TodaySymbol: View {
    let event: Event
    var past = false

    @Environment(\.todaySymbols) private var symbols
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if let symbol = symbols.symbol(for: event), symbol.isDrawableOnMac {
            Image(systemName: symbol.name)
                .font(.subheadline)
                .foregroundStyle(style)
                .widgetAccentable()
                .privacySensitive()
                .accessibilityHidden(true)
        }
    }

    private var style: AnyShapeStyle {
        if past { return AnyShapeStyle(.secondary) }
        return renderingMode == .fullColor ? AnyShapeStyle(event.markColor) : AnyShapeStyle(.primary)
    }
}

/// The 2 pt rule in the event's color, as tall as its row. In the accent group, so the
/// accented style draws it in the tint and it still reads as the row's mark.
struct TodayRule: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .widgetAccentable()
    }
}

/// The fixed-width time column of the Day list: as wide as the widest time the locale writes
/// (`22:00`, or `10:00 PM`), so every rule lines up.
struct TodayTimeColumn<Content: View>: View {
    let calendar: Calendar
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(verbatim: template)
                .font(.subheadline)
                .monospacedDigit()
                .hidden()
                .accessibilityHidden(true)
            content
        }
    }

    private var template: String {
        let today = CivilDate(Date.now, in: calendar).date(in: calendar)
        return Formatting.time(today.addingTimeInterval(22 * 3600), calendar: calendar)
    }
}

/// A secondary line: Earlier, a gap, `2 more`.
struct TodayLine: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A state where the events would be: `Nothing scheduled`, `Add a Google account`,
/// `Open to update`.
struct TodayMessage: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// `As of 9:12` or `1 account signed out` at the foot, when there is one.
struct TodayStatus: View {
    let text: String?

    var body: some View {
        if let text {
            Text(verbatim: text)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The Day list's spacing scale (`Spacing` in the app), which the extension does not compile.
enum Spacing {
    static let row: CGFloat = 4
    static let cell: CGFloat = 8
}
