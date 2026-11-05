import DayCore
import SwiftUI

/// One day as a plain system `List`: the summary and its status lines, the all-day lines,
/// the Earlier row, the now line, the event rows and the gap rows. The iPhone Day, the Mac
/// day pane and the Mac menu bar panel all draw it, so there is one day design.
///
/// It redraws every minute inside `TimelineView`, reading the time from the store, so a
/// fixture's `-Now` holds still for screenshots while a live store moves.
struct DayList: View {
    @EnvironmentStore private var store
    @Environment(\.dayListMargin) private var margin
    @Environment(\.presentEvent) private var presentEvent
    @Environment(\.dynamicTypeSize) private var typeSize

    let day: CivilDate
    /// The day above the summary. The Mac inspector writes `Wednesday 4 November` in Title 2;
    /// the iPhone, whose large title is the weekday, writes `4 November` under it.
    var showsHeader = false
    var showsSummary = true
    /// The Mac's selected event, which Tab moves and Return opens. Nil keeps it inside.
    var selection: Binding<EventID?>? = nil
    /// The event whose sheet (iPhone) or popover (Mac) is open. Nil keeps it inside.
    var presented: Binding<EventID?>? = nil
    /// Replaces opening the event here: the menu bar panel opens the main window instead.
    var onOpen: ((Event) -> Void)? = nil

    @State private var ownSelection: EventID?
    @State private var ownPresented: EventID?
    @State private var unfoldsEarlier = false
    @Namespace private var zoom

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let now = store.now
            let rows = dayRows(day: day, events: store.dayEvents(day), now: now, calendar: store.calendar)
            list(items(rows))
        }
        #if os(iOS)
            .sheet(item: presentedEvent) { event in
                EventSheet(event: event)
                    .calendarStore(store)
                    .navigationTransition(.zoom(sourceID: event.id, in: zoom))
            }
        #endif
    }

    @ViewBuilder
    private func list(_ items: [Item]) -> some View {
        // The system list, plain, with its own insets and separators. Only the minimum row
        // height goes, so the now line and the gap rows are lines rather than 44 pt rows.
        #if os(macOS)
            List(selection: selectionBinding) {
                content(items)
            }
            .listStyle(.plain)
            // One point, not zero: AppKit's table refuses a zero row height and logs an
            // error on every update; a point is still below every row the list draws.
            .environment(\.defaultMinListRowHeight, 1)
        #else
            List {
                content(items)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
        #endif
    }

    @ViewBuilder
    private func content(_ items: [Item]) -> some View {
        if showsHeader {
            #if os(macOS)
                Text(verbatim: Formatting.dayHeader(day, calendar: store.calendar))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            #else
                // The date sits in the list right under the large weekday rather than in
                // `navigationSubtitle`: with a subtitle, any toolbar item (here `Today`) makes
                // iOS 27 push the Day with its title collapsed, so the large title would come
                // and go depending on the day.
                Text(verbatim: Formatting.dayAndMonth(day, calendar: store.calendar))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.top, 0)
                    .listRowInsets(.horizontal, margin)
                    .accessibilityAddTraits(.isHeader)
            #endif
        }
        if showsSummary {
            DaySummary(day: day)
                .padding(.bottom, Spacing.cell)
                .listRowSeparator(.hidden)
                .listRowInsets(.horizontal, margin)
                .selectionDisabled()
        }
        ForEach(items) { item in
            row(item)
                .modifier(LastRow(isLast: item.id == items.last?.id))
        }
        .listRowInsets(.horizontal, margin)
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .row(.allDay(let event, let position)):
            openButton(event) {
                AllDayRowContent(event: event, position: position)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(.vertical, Spacing.row)
            .selectionDisabled()
        case .row(.allDayMore(let text)):
            Text(verbatim: text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
                .listRowInsets(.vertical, Spacing.row)
                .selectionDisabled()
        case .row(.earlier(let events)):
            EarlierRow(events: events, unfolded: $unfoldsEarlier)
                .listRowSeparator(.hidden)
                .selectionDisabled()
        case .past(let event):
            openButton(event) {
                EventRowContent(event: event, secondLine: nil, past: true)
            }
            .tag(event.id)
        case .row(.nowLine(let date)):
            NowLineRow(date: date)
                .listRowSeparator(.hidden)
                .listRowInsets(.vertical, 2)
                .selectionDisabled()
        case .row(.event(let event, let secondLine, let showsJoin)):
            // Join trails the row, or sits under it at the accessibility sizes, where the
            // title needs the whole width.
            let layout =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.cell))
                : AnyLayout(HStackLayout(spacing: Spacing.cell))
            layout {
                openButton(event) {
                    EventRowContent(event: event, secondLine: secondLine)
                }
                if showsJoin {
                    JoinButton(event: event)
                }
            }
            .tag(event.id)
        case .row(.gap(let text, _)):
            GapRow(text: text)
                .listRowSeparator(.hidden, edges: .bottom)
                .listRowInsets(.vertical, Spacing.cell)
                .selectionDisabled()
        }
    }

    /// The row's tap target. On the iPhone it opens the event sheet, zooming out of the row;
    /// on the Mac it selects the row and opens the popover anchored to it.
    private func openButton(_ event: Event, @ViewBuilder label: () -> some View) -> some View {
        Button {
            selectionBinding.wrappedValue = event.id
            if let onOpen {
                onOpen(event)
            } else if let presentEvent {
                presentEvent(event, zoom: zoom)
            } else {
                presentedBinding.wrappedValue = event.id
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        #if os(iOS)
            .matchedTransitionSource(id: event.id, in: zoom)
        #else
            .popover(
                isPresented: Binding(
                    get: { presentedBinding.wrappedValue == event.id },
                    set: { if !$0, presentedBinding.wrappedValue == event.id { presentedBinding.wrappedValue = nil } }),
                arrowEdge: .leading
            ) {
                EventPopover(event: event)
                    .calendarStore(store)
            }
            .contextMenu {
                EventMenuItems(event: event)
            }
        #endif
    }

    private var selectionBinding: Binding<EventID?> {
        selection ?? $ownSelection
    }

    private var presentedBinding: Binding<EventID?> {
        presented ?? $ownPresented
    }

    /// The presented event, looked up in the day so the sheet shows the same copy the row
    /// does.
    private var presentedEvent: Binding<Event?> {
        Binding(
            get: {
                guard let id = presentedBinding.wrappedValue else { return nil }
                return store.dayEvents(day).first { $0.id == id }
            },
            set: { presentedBinding.wrappedValue = $0?.id })
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

private struct DayListMarginKey: EnvironmentKey {
    static var defaultValue: CGFloat? { nil }
}

extension EnvironmentValues {
    /// The leading and trailing row inset for a day list that cannot see the scene's own
    /// margins, as inside the iPhone pager. Nil keeps the system's.
    var dayListMargin: CGFloat? {
        get { self[DayListMarginKey.self] }
        set { self[DayListMarginKey.self] = newValue }
    }
}

/// The list ends at its last row, with no rule under it. Applied only to the last row, so
/// every other row keeps the separators it set itself.
private struct LastRow: ViewModifier {
    let isLast: Bool

    func body(content: Content) -> some View {
        if isLast {
            content.listRowSeparator(.hidden, edges: .bottom)
        } else {
            content
        }
    }
}

/// The summary paragraph and the status lines under it, or the state that replaces them:
/// `Loading…` the first time, `No calendars shown.` when every calendar is hidden.
struct DaySummary: View {
    @EnvironmentStore private var store
    @Environment(\.chooseCalendars) private var chooseCalendars
    let day: CivilDate

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cell) {
            if store.allCalendarsHidden {
                SummaryParagraph(summary: Summary(first: String(localized: "No calendars shown.")))
                if let chooseCalendars {
                    Button("Choose Calendars…") { chooseCalendars() }
                        .buttonStyle(.borderless)
                }
            } else if store.status == .loading {
                SummaryParagraph(summary: Summary(first: String(localized: "Loading…")))
            } else {
                SummaryParagraph(
                    summary: summarize(
                        day: day, events: store.dayEvents(day), now: store.now,
                        calendar: store.calendar))
            }
            StatusLines()
        }
    }
}

#Preview("Day list, 12:10") {
    let store = PreviewStore.make(at: "12:10")
    DayList(day: store.today)
        .calendarStore(store)
}

#Preview("Day list, offline") {
    let store = PreviewStore.make(at: "9:25", state: .offline)
    DayList(day: store.today)
        .calendarStore(store)
}
