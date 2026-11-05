import DayCore
import SwiftUI

/// The iPhone app: a `NavigationStack` with the Month at the root and today's Day pushed on
/// launch, so the back chevron reads the month and launch lands on today. The Month lists its
/// selected day under the grid; a second tap on that day opens its Day, which zooms out of
/// the cell. First run, the Calendars sheet, Go to Date, the event sheet and the widget's
/// links all start here.
///
/// It handles `day://day/<date>` and `day://event/<account>/<calendar>/<event>` itself, so a
/// widget tap works with no wiring in the app entry point.
struct RootView: View {
    @EnvironmentStore private var store

    @State private var path: [CivilDate] = []
    @State private var scroll = MonthScroll()
    /// The day listed under the month grid; nil follows today, so it moves on at midnight.
    @State private var chosenDay: CivilDate?
    @State private var launched = false
    @State private var firstRun = false
    /// The one sheet on screen. A single `sheet(item:)` holds them all, so a widget link that
    /// arrives over Calendars, Go to Date or another event replaces that sheet with its own.
    @State private var sheet: RootSheet?
    /// Bumped by a link, so the Day pager restarts on the linked day even when the stack
    /// already shows a page of the same push.
    @State private var pagerToken = 0
    @Namespace private var zoom

    var body: some View {
        Group {
            if !launched {
                Color.clear
            } else if firstRun {
                FirstRunView { leaveFirstRun() }
            } else {
                stack
            }
        }
        .onAppear(perform: launch)
        .onChange(of: store.needsFirstRun) { _, needs in
            if needs { firstRun = true }
        }
        .onOpenURL(perform: open)
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
                .calendarStore(store)
        }
        .environment(\.presentEvent, PresentEventAction { event, zoom in
            sheet = .event(event, zoom: zoom)
        })
    }

    @ViewBuilder
    private func sheetContent(_ sheet: RootSheet) -> some View {
        let today = store.today
        let calendar = store.calendar
        switch sheet {
        case .calendars:
            CalendarsSheet()
        case .goToDate:
            GoToDateSheet(initial: scroll.goToDateStart(today: today, calendar: calendar)) { day in
                select(day)
                scroll.show(day, today: today, calendar: calendar)
            }
        case .event(let event, let zoom):
            if let zoom {
                EventSheet(event: event)
                    .navigationTransition(.zoom(sourceID: event.id, in: zoom))
            } else {
                EventSheet(event: event)
            }
        }
    }

    /// The day the month lists and rings.
    private var selectedDay: CivilDate {
        chosenDay ?? store.today
    }

    private var stack: some View {
        let today = store.today
        let calendar = store.calendar
        return NavigationStack(path: $path) {
            MonthView(
                scroll: scroll, selection: selectedDay, zoom: zoom,
                onOpen: { path.append($0) }
            ) { day in
                if day == selectedDay {
                    path.append(day)
                } else {
                    withAnimation { select(day) }
                }
            }
            // The system bar names the page's month. Inline, because the month itself does
            // not scroll: a large title would never collapse and would take the height the
            // selected day needs, and a title collapsing with the day's list would resize the
            // grid under the finger. The title also names the back button on the Day.
            .navigationTitle(scroll.title(today: today, now: store.now, calendar: calendar))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("Today") {
                        withAnimation {
                            select(today)
                            scroll.show(today, today: today, calendar: calendar)
                        }
                    }
                }
                // Text and a symbol in one capsule read as one action, so they stand apart.
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Go to Date…", systemImage: "calendar") { sheet = .goToDate }
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Calendars") { sheet = .calendars }
                }
            }
            // A page turned by a swipe lists today when it holds today, else its first day.
            // A jump that already picked a day in the new month (Today, Go to Date, a widget
            // link) keeps it.
            .onChange(of: scroll.page) { _, page in
                guard let page, MonthScroll.firstOfMonth(selectedDay) != page else { return }
                withAnimation {
                    select(MonthScroll.firstOfMonth(today) == page ? today : page)
                }
            }
            .navigationDestination(for: CivilDate.self) { day in
                DayPager(start: day)
                    .id(pagerToken)
                    .modifier(ZoomFromCell(day: day, namespace: zoom))
            }
        }
        .environment(\.chooseCalendars, ChooseCalendarsAction { sheet = .calendars })
    }

    private func select(_ day: CivilDate) {
        chosenDay = day == store.today ? nil : day
    }

    /// Lands on today with no push animation: the stack is built for the first time with
    /// today already on it.
    private func launch() {
        guard !launched else { return }
        if store.needsFirstRun {
            firstRun = true
        } else {
            path = [store.today]
        }
        launched = true
    }

    private func leaveFirstRun() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            path = [store.today]
            firstRun = false
        }
    }

    /// A widget tap. The inline and circular widgets open a day; the rectangular widget opens
    /// the event's sheet over its day, never a blind join. `Route` checks the link against the
    /// cache, so a link to an event no longer there lands on today.
    private func open(_ url: URL) {
        guard !firstRun, let route = store.route(for: url) else { return }
        let day = route.day(in: store)
        pagerToken += 1
        // Back from the linked Day lands on its month with that day listed.
        select(day)
        scroll.show(day, today: store.today, calendar: store.calendar)
        path = [day]
        if case .event(let event) = route {
            sheet = .event(event, zoom: nil)
        } else {
            sheet = nil
        }
    }
}

/// The root's sheets, one at a time.
private enum RootSheet: Identifiable {
    case calendars
    case goToDate
    /// An event from a row, which zooms out of it, or from a widget link, which has no row.
    case event(Event, zoom: Namespace.ID?)

    var id: String {
        switch self {
        case .calendars: "calendars"
        case .goToDate: "go-to-date"
        case .event(let event, _): "event-\(event.id)"
        }
    }
}

/// The Day grows out of its Month cell, the app's one motion of its own. Under Reduce Motion
/// it is the system push instead, which the system then draws as a crossfade.
private struct ZoomFromCell: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let day: CivilDate
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.navigationTransition(.zoom(sourceID: day, in: namespace))
        }
    }
}

#Preview("iPhone, 12:10") {
    let store = PreviewStore.make(at: "12:10")
    RootView()
        .calendarStore(store)
}

#Preview("iPhone, first run") {
    let store = PreviewStore.make(state: .noAccount)
    RootView()
        .calendarStore(store)
}
