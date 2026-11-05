import DayCore
import SwiftUI

/// The one window: the Month filling it and the selected day in the trailing system inspector,
/// with the month's name leading in the toolbar, previous, Today and next in the center and
/// the inspector toggle trailing. No sidebar, no view switcher, no plus and no search.
///
/// Until an account exists the window shows the first-run screen instead, with `Open at
/// login` under it so the choice is offered once and never made silently.
struct MainWindow: View {
    @EnvironmentStore private var store
    @Environment(\.openSettings) private var openSettings

    @Bindable var state: MacState
    let login: OpenAtLogin

    @State private var firstRun: Bool
    @FocusState private var focused: Bool

    /// The smallest window. At 720 pt the Month keeps 60 pt per day beside the pane at its
    /// ideal 300 pt, so the pane never has to collapse on its own: it stays until the person
    /// hides it with the toolbar button or Option-Command-I.
    static let minimumSize = CGSize(width: 720, height: 480)

    init(state: MacState, login: OpenAtLogin) {
        self.state = state
        self.login = login
        _firstRun = State(initialValue: state.store.needsFirstRun)
    }

    var body: some View {
        Group {
            if firstRun {
                firstRunScreen
            } else {
                calendarScreen
            }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .navigationTitle(firstRun ? "Day" : state.title)
        .toolbar {
            if !firstRun {
                ToolbarItemGroup(placement: .principal) {
                    navigation
                }
                ToolbarItem(placement: .primaryAction) {
                    paneToggle
                }
            }
        }
        .environment(
            \.chooseCalendars,
            ChooseCalendarsAction {
                state.settingsTab = .accounts
                openSettings()
            }
        )
        .focusedSceneValue(\.dayWindow, state)
        .onChange(of: store.needsFirstRun) { _, needs in
            if needs { firstRun = true }
        }
        .onAppear {
            state.windowIsOpen = true
            login.refresh()
        }
        .onDisappear { state.windowIsOpen = false }
        .sheet(isPresented: $state.showsGoToDate) {
            GoToDateSheet(initial: state.day) { state.goTo($0) }
                .calendarStore(store)
        }
    }

    // MARK: Month and day pane

    private var calendarScreen: some View {
        MonthView(scroll: state.scroll, selection: state.day) { day in
            state.select(day)
        }
        // The page always holds the selected day. Arrow keys, Previous Week and the menu
        // bar's reveal move the day without naming a month, so the page follows the day here;
        // the toolbar and Go to Date move both together and this does nothing.
        .onChange(of: state.day, initial: true) { _, day in
            let scroll = state.scroll
            guard MonthScroll.firstOfMonth(day) != scroll.shown(today: store.today) else { return }
            scroll.show(day, today: store.today, calendar: store.calendar)
        }
        .inspector(isPresented: $state.showsDayPane) {
            DayView(day: state.day, selection: $state.selectedEvent, presented: $state.presentedEvent)
                // A new day starts folded and scrolled to the top, with no popover left open.
                .id(state.day)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        // Return opens the popover, from the grid or from the pane. The focus rides on the
        // window's content so the key reaches it wherever the last click landed.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.return) {
            guard state.canShowEvent else { return .ignored }
            state.showEvent()
            return .handled
        }
    }

    // MARK: Toolbar

    /// Previous, Today and next as one joined control, as Apple Calendar draws them. Previous
    /// and next move by month, the unit the title names.
    private var navigation: some View {
        ControlGroup {
            Button {
                state.moveMonth(by: -1)
            } label: {
                Label("Previous Month", systemImage: "chevron.left")
            }
            .help("Previous Month")
            Button("Today") {
                state.goToToday()
            }
            .help("Go to Today")
            Button {
                state.moveMonth(by: 1)
            } label: {
                Label("Next Month", systemImage: "chevron.right")
            }
            .help("Next Month")
        }
    }

    /// The inspector toggle. One fixed title, `Show Day Pane`, as the menu item has: the state
    /// is the button being pressed, not a second title that swaps in.
    private var paneToggle: some View {
        Toggle(isOn: $state.showsDayPane) {
            Label("Show Day Pane", systemImage: "sidebar.trailing")
        }
        .help("Show Day Pane")
    }

    // MARK: First run

    private var firstRunScreen: some View {
        FirstRunView { leaveFirstRun() }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .safeAreaInset(edge: .bottom) {
                Toggle(
                    "Open at login",
                    isOn: Binding(get: { login.isOn }, set: { login.set($0) })
                )
                .toggleStyle(.checkbox)
                .scenePadding([.horizontal, .bottom])
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
    }

    private func leaveFirstRun() {
        firstRun = false
        state.goToToday()
    }
}

#Preview("Window") {
    let store = PreviewStore.make()
    MainWindow(state: MacState(store: store), login: OpenAtLogin())
        .calendarStore(store)
        .frame(width: 1080, height: 720)
}

#Preview("First run") {
    let store = PreviewStore.make(state: .noAccount)
    MainWindow(state: MacState(store: store), login: OpenAtLogin())
        .calendarStore(store)
        .frame(width: 720, height: 480)
}
