import DayCore
import SwiftUI

/// The month: one continuous vertical scroll of week rows that snaps to rows and opens with
/// the current week on top. One-offs that matter are bars and titled lines, routine is gray
/// dots, today is the red numeral. Shared by the iPhone root and the Mac window; the parent
/// supplies the title, the toolbar and what a tap on a day does.
struct MonthView: View {
    @EnvironmentStore private var store

    /// The scroll position and the shown month, owned by the parent.
    @Bindable var scroll: MonthScroll
    /// The Mac's selected day, tinted. The iPhone passes nil.
    var selection: CivilDate? = nil
    /// The iPhone's zoom namespace, so the pushed Day grows out of its cell.
    var zoom: Namespace.ID? = nil
    /// The iPhone draws the month's name as its large title, and a tap on it opens Go to
    /// Date. The Mac passes nil and names the month in its window toolbar.
    var onTitle: (() -> Void)? = nil
    /// A tap on a day cell: the iPhone pushes the Day, the Mac selects it.
    let onSelect: (CivilDate) -> Void

    @State private var width: CGFloat = 0

    var body: some View {
        let calendar = store.calendar
        let today = store.today
        let weeks = scroll.weeks(today: today, calendar: calendar)
        let current = MonthScroll.weekStart(of: today, calendar: calendar)

        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(weeks, id: \.self) { week in
                    WeekRow(
                        layout: layout(week: week, calendar: calendar),
                        today: today,
                        columnWidth: width / 7,
                        selection: selection,
                        zoom: zoom,
                        onSelect: onSelect)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(
            id: Binding(
                get: { scroll.topWeek ?? current },
                set: { scroll.topWeek = $0 }),
            anchor: .top
        )
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        .onScrollTargetVisibilityChange(idType: CivilDate.self, threshold: 0.5) { weeks in
            scroll.visibleWeeks = weeks.sorted()
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.cell) {
                if let onTitle {
                    // Pinned with the weekday letters rather than the navigation bar's own
                    // large title: the month opens scrolled to this week, not to the top of
                    // its content, so a navigation bar title would start collapsed, and this
                    // one changes as the weeks scroll under it.
                    Button(action: onTitle) {
                        Text(verbatim: scroll.title(today: today, now: store.now, calendar: calendar))
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .scenePadding(.horizontal)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHint(Text("Go to date"))
                }
                WeekdayHeader(calendar: calendar)
            }
            // Opaque, so the week scrolling up never shows through the title or the status
            // bar: a translucent bar blurs it instead of cutting it off. On the Mac the
            // fill stops at the toolbar, which draws its own.
            .background(.background, ignoresSafeAreaEdges: Platform.isMac ? [] : .top)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Larger text belongs to the Day list; the grid has one layout and stops growing here.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func layout(week: CivilDate, calendar: Calendar) -> WeekLayout {
        WeekLayout(
            start: week,
            events: store.events(in: week...week.adding(days: 6)),
            calendar: calendar,
            maxLanes: Platform.isMac ? nil : 2,
            mark: { store.monthMark($0) })
    }
}

/// `M T W T F S S` on iPhone, `Mon Tue Wed` on the Mac, from the locale's first weekday.
struct WeekdayHeader: View {
    let calendar: Calendar

    var body: some View {
        let symbols = Platform.isMac ? calendar.shortWeekdaySymbols : calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = (0..<7).map { symbols[(first + $0) % 7] }
        HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(verbatim: symbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, Platform.isMac ? 8 : 0)
                    .frame(maxWidth: .infinity, alignment: Platform.isMac ? .leading : .center)
            }
        }
        .padding(.top, Platform.isMac ? 6 : 0)
        .padding(.bottom, 6)
        .accessibilityHidden(true)
    }
}

#Preview("Month") {
    @Previewable @State var scroll = MonthScroll()
    let store = PreviewStore.make()
    NavigationStack {
        MonthView(scroll: scroll, onTitle: {}) { _ in }
        #if os(iOS)
            .toolbarVisibility(.hidden, for: .navigationBar)
        #endif
    }
    .calendarStore(store)
}

#Preview("Month, dark") {
    @Previewable @State var scroll = MonthScroll()
    let store = PreviewStore.make()
    NavigationStack {
        MonthView(scroll: scroll) { _ in }
            .navigationTitle(scroll.title(today: store.today, now: store.now, calendar: store.calendar))
    }
    .calendarStore(store)
    .preferredColorScheme(.dark)
}
