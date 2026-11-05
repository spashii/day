import DayCore
import SwiftUI

/// Today for the menu bar panel: the same summary, status lines and row views as `DayList`,
/// stacked in a scroll view instead of laid out in a `List`.
///
/// A `List` has no height of its own, so inside a panel that sizes itself to its content it
/// needs a guess, and a three-line summary or a wrapped signed-out line is always taller than
/// the guess. Stacked rows have a real height: the panel is exactly as tall as the day, up to
/// 480 pt, and only a longer day scrolls.
///
/// The rows are the shared ones (`EventRowContent`, `JoinButton`, `NowLineRow`, `GapRow`,
/// `EarlierRow`, `AllDayRowContent`), so a row reads the same here as in the day pane. Only the
/// spacing between them is this file's, standing in for the list's row insets and separators.
struct StackedDayList: View {
    @EnvironmentStore private var store

    let day: CivilDate
    /// A click on an event row. The panel opens the main window on that event.
    let onOpen: (Event) -> Void

    @State private var unfoldsEarlier = false

    /// The tallest the list gets before it scrolls.
    static let maxHeight: CGFloat = 480

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let rows = dayRows(
                day: day, events: store.dayEvents(day), now: store.now, calendar: store.calendar)
            let items = items(rows)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DaySummary(day: day)
                        .padding(.bottom, Spacing.cell)
                    ForEach(items) { item in
                        row(item)
                        if separated(item, in: items) {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, Spacing.block)
                .padding(.vertical, Spacing.cell)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.maxHeight)
            // The scroll view reports its content as its ideal height, so the cap above is
            // the only thing that ever sets the panel's height.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .row(.allDay(let event, let position)):
            openButton(event) {
                AllDayRowContent(event: event, position: position)
            }
            .padding(.vertical, Spacing.row)
        case .row(.allDayMore(let text)):
            Text(verbatim: text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, Spacing.row)
        case .row(.earlier(let events)):
            EarlierRow(events: events, unfolded: $unfoldsEarlier)
                .padding(.vertical, Spacing.cell)
        case .past(let event):
            openButton(event) {
                EventRowContent(event: event, secondLine: nil, past: true)
            }
            .padding(.vertical, Spacing.cell)
        case .row(.nowLine(let date)):
            NowLineRow(date: date)
                .padding(.vertical, 2)
        case .row(.event(let event, let secondLine, let showsJoin)):
            HStack(spacing: Spacing.cell) {
                openButton(event) {
                    EventRowContent(event: event, secondLine: secondLine)
                }
                if showsJoin {
                    JoinButton(event: event)
                }
            }
            .padding(.vertical, Spacing.cell)
        case .row(.gap(let text, _)):
            GapRow(text: text)
                .padding(.vertical, Spacing.cell)
        }
    }

    private func openButton(_ event: Event, @ViewBuilder label: () -> some View) -> some View {
        Button {
            onOpen(event)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .contextMenu {
            EventMenuItems(event: event)
        }
    }

    /// A hairline under an event row, as the list draws between events. Not after the last
    /// row, and not under the all-day lines, the Earlier row, the now line or a gap, which
    /// the list leaves bare.
    private func separated(_ item: Item, in items: [Item]) -> Bool {
        guard item.id != items.last?.id else { return false }
        switch item {
        case .past, .row(.event): return true
        default: return false
        }
    }

    /// The rules' rows, with the finished events spliced in after the Earlier row while it
    /// is unfolded.
    private func items(_ rows: [DayRow]) -> [Item] {
        rows.flatMap { row -> [Item] in
            if case .earlier(let events) = row, unfoldsEarlier {
                return [.row(row)] + events.map(Item.past)
            }
            return [.row(row)]
        }
    }

    private enum Item: Identifiable {
        case row(DayRow)
        case past(Event)

        enum ID: Hashable {
            case row(DayRow.ID)
            case past(EventID)
        }

        var id: ID {
            switch self {
            case .row(let row): .row(row.id)
            case .past(let event): .past(event.id)
            }
        }
    }
}

#Preview("Stacked, 12:10") {
    let store = PreviewStore.make(at: "12:10")
    StackedDayList(day: store.today) { _ in }
        .frame(width: 320)
        .calendarStore(store)
}

#Preview("Stacked, offline") {
    let store = PreviewStore.make(at: "9:25", state: .offline)
    StackedDayList(day: store.today) { _ in }
        .frame(width: 320)
        .calendarStore(store)
}
