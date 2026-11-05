import DayCore
import SwiftUI

// The pieces of the Day list. Every row lines up on the same three columns: times, the 2 pt
// rule, then titles, so gap rows and the now line sit where the eye already is.
//
// At the accessibility text sizes the columns give way: a time column that wide would leave
// a title a few characters, so each event puts its times above its title, and titles and
// second lines wrap instead of truncating. The month grid stops at xxxLarge; this list is
// where the largest sizes are read.

/// The fixed-width time column. Its width is the widest time the locale writes (`22:00`, or
/// `10:00 PM`), so every row's rule lands in the same place at every text size up to the
/// accessibility sizes, where the column is only as wide as what it holds.
struct TimeColumn<Content: View>: View {
    @EnvironmentStore private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let content: Content

    var body: some View {
        if typeSize.isAccessibilitySize {
            content
        } else {
            ZStack(alignment: .topLeading) {
                Text(verbatim: template)
                    .font(.subheadline)
                    .monospacedDigit()
                    .hidden()
                    .accessibilityHidden(true)
                content
            }
        }
    }

    private var template: String {
        let evening = store.today.date(in: store.calendar).addingTimeInterval(22 * 3600)
        return Formatting.time(evening, calendar: store.calendar)
    }
}

/// The symbol of the event's calendar, small and monochrome in the secondary color, which
/// leads the title of a row. A calendar with no symbol, or one this system cannot draw, adds
/// nothing, so its row is as it was. The calendar's name is in the row's spoken label, so the
/// symbol itself is decoration.
struct EventSymbol: View {
    @EnvironmentSymbols private var symbols
    let event: Event

    var body: some View {
        if let symbol = symbols.map.symbol(for: event), symbol.isDrawable {
            Image(systemName: symbol.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// An event: start and end, the colored rule, the title in Semibold for one-offs and
/// Regular for recurring, one unusual second line, and Join in its window. The title is led
/// by its calendar's symbol when it has one.
struct EventRowContent: View {
    @EnvironmentStore private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    let event: Event
    let secondLine: String?
    /// The unfolded Earlier rows are drawn in the secondary color: they are done.
    var past = false

    var body: some View {
        let calendar = store.calendar
        let start = Formatting.time(event.time.start(in: calendar), calendar: calendar)
        let end = Formatting.time(event.time.end(in: calendar), calendar: calendar)
        let stacked = typeSize.isAccessibilitySize
        HStack(alignment: .top, spacing: Spacing.cell) {
            if !stacked {
                TimeColumn {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: start)
                            .foregroundStyle(past ? .secondary : .primary)
                        Text(verbatim: end)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                }
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(event.markColor)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: stacked ? Spacing.row : 0) {
                if stacked {
                    Text("\(Text(verbatim: start)) to \(Text(verbatim: end).foregroundStyle(.secondary))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(past ? .secondary : .primary)
                }
                HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                    EventSymbol(event: event)
                    Text(event.title)
                        .font(.body)
                        .fontWeight(event.isRecurring ? .regular : .semibold)
                        .foregroundStyle(past ? .secondary : .primary)
                        .lineLimit(stacked ? nil : 1)
                }
                if let secondLine {
                    Text(verbatim: secondLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(stacked ? nil : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let calendar = store.calendar
        let start = Formatting.time(event.time.start(in: calendar), calendar: calendar)
        let end = Formatting.time(event.time.end(in: calendar), calendar: calendar)
        var parts = [event.title, "\(start) to \(end)"]
        if let secondLine { parts.append(secondLine) }
        if let name = store.calendarInfo(event.id.calendar)?.name { parts.append(name) }
        return parts.joined(separator: ", ")
    }
}

/// The system prominent button, from 10 minutes before the start until the end. In the
/// content layer, so prominent rather than glass. Small on the Mac, where the pointer is
/// precise; the regular size on the iPhone, where it is the most hurried tap in the app and
/// the small one was a 27 pt target.
struct JoinButton: View {
    @EnvironmentStore private var store
    @Environment(\.handoff) private var handoff
    let event: Event

    var body: some View {
        if let url = event.joinURL {
            Button("Join") {
                handoff(url, account: store.account(event.account))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            #if os(macOS)
                .controlSize(.small)
            #endif
            .fontWeight(.semibold)
        }
    }
}

/// The red now line: the time in red in the time column and a red hairline across. Drawn
/// before the day starts and in gaps, never through an event.
struct NowLineRow: View {
    @EnvironmentStore private var store
    let date: Date

    var body: some View {
        HStack(spacing: Spacing.cell) {
            TimeColumn {
                Text(verbatim: Formatting.time(date, calendar: store.calendar))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.red)
            }
            Rectangle()
                .fill(.red)
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Now, \(Formatting.time(date, calendar: store.calendar))"))
    }
}

/// `1 h free`, `1 h 30 min free`, `Free until 16:00`, aligned with the titles.
struct GapRow: View {
    let text: String

    var body: some View {
        HStack(spacing: Spacing.cell) {
            TimeColumn { EmptyView() }
            Color.clear.frame(width: 2, height: 1)
            Text(verbatim: text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// `Earlier: Standup, Design review`. Folded by default, so at 15:00 the first screen is
/// what is next; a tap unfolds the finished rows.
struct EarlierRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let events: [Event]
    @Binding var unfolded: Bool

    var body: some View {
        Button {
            withAnimation { unfolded.toggle() }
        } label: {
            HStack(spacing: Spacing.cell) {
                Text(verbatim: Formatting.earlier(events))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: unfolded ? "chevron.up" : "chevron.down")
                    .imageScale(.small)
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One all-day item: `Lisbon, day 2 of 3`. Holiday calendars in the secondary color.
struct AllDayRowContent: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let event: Event
    let position: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
            EventSymbol(event: event)
            Text(verbatim: position.map { "\(event.title), \($0)" } ?? event.title)
                .font(.subheadline)
                .foregroundStyle(event.onHolidayCalendar ? .secondary : .primary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}
