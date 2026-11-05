import DayCore
import SwiftUI

/// The month: one page per month holding only its own weeks. One-offs that matter are bars
/// and titled lines, routine is gray dots, today is the red numeral.
///
/// On the iPhone the pages turn sideways under the weekday letters, and the selected day sits
/// under the grid: its date line, its summary and its rows. On the Mac the page fills the
/// window and the parent shows the selected day in its inspector. The parent supplies the
/// title, the toolbar and what a tap on a day does.
struct MonthView: View {
    @EnvironmentStore private var store

    /// The page on screen, owned by the parent.
    let scroll: MonthScroll
    /// The selected day: ringed and listed under the iPhone grid, tinted on the Mac.
    let selection: CivilDate
    /// The iPhone's zoom namespace, so the pushed Day grows out of its cell.
    var zoom: Namespace.ID? = nil
    /// A tap on the selected day's date line under the iPhone grid: the full Day.
    var onOpen: ((CivilDate) -> Void)? = nil
    /// A tap on a day cell: the iPhone selects it, or opens it when it is already selected;
    /// the Mac selects it.
    let onSelect: (CivilDate) -> Void

    /// The iPhone's height under the weekday letters, for the grid and the day together.
    @State private var available: CGFloat = 0
    /// The least height the loaded iPhone pages can draw their weeks in.
    @State private var pagesNeed: CGFloat = 0

    var body: some View {
        Group {
            if Platform.isMac {
                macPage
            } else {
                phonePage
            }
        }
    }

    // MARK: iPhone

    /// The grid takes two thirds of the height under the weekday letters, the selected day the
    /// rest, so a six-week month still leaves the summary and the first rows in view. Every
    /// month gets the same grid height, so the day stays put while the pages turn. At the
    /// largest text sizes the grid grows to what its pages need, up to three quarters.
    private var gridHeight: CGFloat {
        let share = min(max(available * 2 / 3, 6 * Self.minPhoneRow), 6 * Self.maxPhoneRow)
        return max(share, min(pagesNeed, available * 3 / 4))
    }

    /// The grid stays between six rows of 64 and six rows of 96 points, so a small iPhone
    /// keeps a usable month and a large one does not hand the grid room the day could use.
    private static let minPhoneRow: CGFloat = 64
    private static let maxPhoneRow: CGFloat = 96

    private var phonePage: some View {
        let calendar = store.calendar
        let today = store.today
        return VStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(scroll.months(today: today), id: \.self) { month in
                        MonthGrid(
                            month: month, height: gridHeight, selection: selection, zoom: zoom,
                            onSelect: onSelect)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(
                id: Binding(
                    get: { scroll.shown(today: today) },
                    set: { month in
                        if let month { scroll.turn(to: month, calendar: calendar) }
                    })
            )
            .scrollIndicators(.hidden)
            // A pinned header over a dense grid is the case the hard edge is for: the
            // weekday letters stay legible over the bars of a turning page.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .frame(height: gridHeight)
            .onPreferenceChange(MonthGridLeast.self) { need in
                MainActor.assumeIsolated { pagesNeed = need }
            }
            // Larger text belongs to the Day list; the grid has one layout and stops here.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Divider()
            // A ZStack, so the outgoing day fades out where the incoming one fades in rather
            // than the two stacking for the length of the fade.
            ZStack {
                MonthDayPane(day: selection) { onOpen?(selection) }
                    .id(selection)
                    .transition(.opacity)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { available = $0 }
        // The weekday letters under the system's title bar. No background of their own: the
        // bar's scroll edge is what keeps them apart from the grid.
        .safeAreaBar(edge: .top, spacing: 0) {
            WeekdayHeader(calendar: calendar)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
    }

    // MARK: Mac

    /// One page filling the window under the weekday letters. It scrolls only when a busy
    /// month in a short window needs more than the window has.
    private var macPage: some View {
        let month = scroll.shown(today: store.today)
        return VStack(spacing: 0) {
            WeekdayHeader(calendar: store.calendar)
            ViewThatFits(in: .vertical) {
                MonthGrid(month: month, selection: selection, onSelect: onSelect)
                ScrollView {
                    MonthGrid(month: month, selection: selection, onSelect: onSelect)
                }
                .scrollEdgeEffectStyle(.hard, for: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
        MonthView(scroll: scroll, selection: store.today) { _ in }
            .navigationTitle(scroll.title(today: store.today, now: store.now, calendar: store.calendar))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    .calendarStore(store)
}

#Preview("Month, dark") {
    @Previewable @State var scroll = MonthScroll()
    let store = PreviewStore.make()
    NavigationStack {
        MonthView(scroll: scroll, selection: store.today.adding(days: 2)) { _ in }
            .navigationTitle(scroll.title(today: store.today, now: store.now, calendar: store.calendar))
    }
    .calendarStore(store)
    .preferredColorScheme(.dark)
}
