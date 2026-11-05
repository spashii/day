import DayCore
import SwiftUI

// The pieces of the Day list. Every row lines up on the same three columns: times, the 2 pt
// rule, then titles, so gap rows and the now line sit where the eye already is.

/// The fixed-width time column. Its width is the widest time the locale writes (`22:00`, or
/// `10:00 PM`), so every row's rule lands in the same place at every text size.
struct TimeColumn<Content: View>: View {
    @EnvironmentStore private var store
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
        let evening = store.today.date(in: store.calendar).addingTimeInterval(22 * 3600)
        return Formatting.time(evening, calendar: store.calendar)
    }
}

/// An event: start and end, the colored rule, the title in Semibold for one-offs and
/// Regular for recurring, one unusual second line, and Join in its window.
struct EventRowContent: View {
    @EnvironmentStore private var store
    let event: Event
    let secondLine: String?
    /// The unfolded Earlier rows are drawn in the secondary color: they are done.
    var past = false

    var body: some View {
        let calendar = store.calendar
        HStack(alignment: .top, spacing: Spacing.cell) {
            TimeColumn {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: Formatting.time(event.time.start(in: calendar), calendar: calendar))
                        .foregroundStyle(past ? .secondary : .primary)
                    Text(verbatim: Formatting.time(event.time.end(in: calendar), calendar: calendar))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .monospacedDigit()
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(event.markColor)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(.body)
                    .fontWeight(event.isRecurring ? .regular : .semibold)
                    .foregroundStyle(past ? .secondary : .primary)
                    .lineLimit(1)
                if let secondLine {
                    Text(verbatim: secondLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

/// The system prominent button, from 10 minutes before the start until the end.
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
            .controlSize(.small)
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
    let events: [Event]
    @Binding var unfolded: Bool

    var body: some View {
        Button {
            withAnimation { unfolded.toggle() }
        } label: {
            HStack(spacing: Spacing.cell) {
                Text(verbatim: Formatting.earlier(events))
                    .lineLimit(1)
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
    let event: Event
    let position: String?

    var body: some View {
        Text(verbatim: position.map { "\(event.title), \($0)" } ?? event.title)
            .font(.subheadline)
            .foregroundStyle(event.onHolidayCalendar ? .secondary : .primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }
}

/// The summary: one paragraph of plain text, sentence one in the label color and sentence
/// two in the secondary color. No card, no icon, no greeting.
struct SummaryParagraph: View {
    let summary: Summary

    var body: some View {
        Text(text)
            .font(.title3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: AttributedString {
        var text = AttributedString(summary.first)
        if let second = summary.second {
            var tail = AttributedString(" " + second)
            tail.foregroundColor = .secondary
            text += tail
        }
        return text
    }
}
