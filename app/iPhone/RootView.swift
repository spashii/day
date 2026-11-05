import DayCore
import SwiftUI

/// The iPhone app: a `NavigationStack` with the Month at the root and today's Day pushed on
/// launch, so the back chevron reads the month and launch lands on today. The Day zooms out
/// of its Month cell. First run, the Calendars sheet, Go to Date and the widget's links all
/// start here.
///
/// It handles `day://day/<date>` and `day://event/<account>/<calendar>/<event>` itself, so a
/// widget tap works with no wiring in the app entry point.
struct RootView: View {
    @EnvironmentStore private var store

    @State private var path: [CivilDate] = []
    @State private var scroll = MonthScroll()
    @State private var launched = false
    @State private var firstRun = false
    @State private var showsCalendars = false
    @State private var showsGoToDate = false
    /// The event a widget link opened, shown over whichever day is underneath.
    @State private var linkedEvent: Event?
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
        .sheet(item: $linkedEvent) { event in
            EventSheet(event: event)
                .calendarStore(store)
        }
    }

    private var stack: some View {
        let today = store.today
        let calendar = store.calendar
        let calendarsBinding = $showsCalendars
        return NavigationStack(path: $path) {
            MonthView(scroll: scroll, zoom: zoom, onTitle: { showsGoToDate = true }) { day in
                path.append(day)
            }
            // The month draws its own large title above the weekday letters, so the root's
            // navigation bar is hidden: a bar left in place keeps its soft edge and the week
            // scrolling up shows through it. The navigation title stays set for the back
            // button and the app switcher.
            .navigationTitle(scroll.title(today: today, now: store.now, calendar: calendar))
            .toolbarVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("Today") {
                        withAnimation { scroll.show(today, today: today, calendar: calendar) }
                    }
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Calendars") { showsCalendars = true }
                }
            }
            .refreshable { await store.refresh() }
            .navigationDestination(for: CivilDate.self) { day in
                DayPager(start: day)
                    .id(pagerToken)
                    .modifier(ZoomFromCell(day: day, namespace: zoom))
            }
        }
        .sheet(isPresented: $showsCalendars) {
            CalendarsSheet()
                .calendarStore(store)
        }
        .sheet(isPresented: $showsGoToDate) {
            GoToDateSheet(initial: scroll.goToDateStart(today: today, calendar: calendar)) { day in
                scroll.show(day, today: today, calendar: calendar)
            }
            .calendarStore(store)
        }
        .environment(\.chooseCalendars, ChooseCalendarsAction { calendarsBinding.wrappedValue = true })
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
        pagerToken += 1
        path = [route.day(in: store)]
        if case .event(let event) = route {
            linkedEvent = event
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
