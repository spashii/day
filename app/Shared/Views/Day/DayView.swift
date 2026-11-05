import DayCore
import SwiftUI

/// One day. On the iPhone it is a page of `DayPager`, whose navigation bar carries the
/// weekday with the date right under it; on the Mac it is the inspector, with
/// `Wednesday 4 November` in Title 2 above the summary. The same `DayList` either way, so
/// there is one day design.
struct DayView: View {
    @EnvironmentStore private var store

    let day: CivilDate
    /// The Mac's selected event and open popover, for the keyboard commands.
    var selection: Binding<EventID?>? = nil
    var presented: Binding<EventID?>? = nil

    var body: some View {
        DayList(day: day, showsHeader: true, selection: selection, presented: presented)
        .refreshable { await store.refresh() }
        .scrollEdgeEffectStyle(.hard, for: .top)
    }
}

#if os(iOS)
    /// The iPhone Day: system paging sideways between days, the weekday as the large title
    /// with the date under it, and `Today` in the bottom toolbar when the page is not today.
    struct DayPager: View {
        @EnvironmentStore private var store

        /// The day the pager opened on.
        let start: CivilDate
        @State private var page: CivilDate?
        /// The scene's leading margin, measured outside the horizontal scroll view.
        @State private var margin: CGFloat?

        init(start: CivilDate) {
            self.start = start
            _page = State(initialValue: start)
        }

        var body: some View {
            let calendar = store.calendar
            let today = store.today
            let current = page ?? start
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(days(today: today), id: \.self) { day in
                        DayView(day: day)
                            .environment(\.dayListMargin, margin)
                            .containerRelativeFrame([.horizontal, .vertical])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .background(alignment: .topLeading) {
                // A list inside a horizontal scroll view loses the scene's margins and falls
                // back to 8 pt. This measures the system margin here, where it is still known,
                // so each page's rows line up under the large title as on any other screen.
                Color.clear
                    .frame(width: 0, height: 0)
                    .scenePadding(.leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { margin = $0 }
            }
            .navigationTitle(Formatting.weekday(current, calendar: calendar))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if current != today {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Today") {
                            withAnimation { page = today }
                        }
                    }
                }
            }
        }

        /// Five weeks back to four months ahead of the opening day and of today: the
        /// window sync keeps, so every page has its events.
        private func days(today: CivilDate) -> [CivilDate] {
            let first = min(start, today).adding(days: -35)
            let last = max(start, today).adding(days: 120)
            return Array(first...last)
        }
    }

    #Preview("Day, 12:10") {
        let store = PreviewStore.make(at: "12:10")
        NavigationStack {
            DayPager(start: store.today)
        }
        .calendarStore(store)
    }

    #Preview("Day, 9:25, dark") {
        let store = PreviewStore.make(at: "9:25")
        NavigationStack {
            DayPager(start: store.today)
        }
        .calendarStore(store)
        .preferredColorScheme(.dark)
    }
#endif
