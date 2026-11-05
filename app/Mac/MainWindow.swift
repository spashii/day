import AppKit
import DayCore
import SwiftUI

/// The one window: the Month filling it and the selected day in the trailing system inspector,
/// with the month's name leading in the toolbar, previous, Today and next in the center and
/// the inspector toggle trailing. No sidebar, no view switcher, no plus and no search.
///
/// Until an account exists the window is the small first-run window instead (`FirstRunWindow`),
/// and it becomes this one as soon as the first account is added.
struct MainWindow: View {
    @EnvironmentStore private var store
    @Environment(\.openSettings) private var openSettings

    @Bindable var state: MacState
    let login: OpenAtLogin

    @State private var firstRun: Bool
    @State private var window: NSWindow?
    @FocusState private var focused: Bool

    /// The smallest window. At 720 pt the Month keeps 60 pt per day beside the pane at its
    /// ideal 300 pt, so the pane never has to collapse on its own: it stays until the person
    /// hides it with the toolbar button or Option-Command-I.
    static let minimumSize = CGSize(width: 720, height: 480)
    /// The size it opens at, and the size it grows to when first run ends.
    static let idealSize = CGSize(width: 1080, height: 720)

    init(state: MacState, login: OpenAtLogin) {
        self.state = state
        self.login = login
        _firstRun = State(initialValue: state.store.needsFirstRun)
    }

    var body: some View {
        Group {
            if firstRun {
                FirstRunWindow(login: login)
            } else {
                calendarScreen
                    .frame(
                        minWidth: Self.minimumSize.width, idealWidth: Self.idealSize.width,
                        maxWidth: .infinity,
                        minHeight: Self.minimumSize.height, idealHeight: Self.idealSize.height,
                        maxHeight: .infinity)
            }
        }
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
        .background(WindowReader { window = $0 })
        .focusedSceneValue(\.dayWindow, state)
        // The first account ends first run at once; the window is the Month from then on. When
        // every account is signed out it is the small window again, until one signs back in.
        .onChange(of: store.needsFirstRun) { _, needs in
            if needs {
                firstRun = true
            } else if firstRun {
                leaveFirstRun()
            }
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

    private func leaveFirstRun() {
        firstRun = false
        state.goToToday()
        growWindow()
    }

    /// The window follows its content from the first-run size only as far as the Month's
    /// minimum. First run is over, so the Month opens at the size it opens at on any other
    /// launch, centered where the small window was.
    private func growWindow() {
        // After the content change has landed and the window has taken its new limits.
        DispatchQueue.main.async {
            guard let window, let screen = window.screen else { return }
            let area = screen.visibleFrame
            // The ideal size is the content's, below the title bar and the toolbar.
            var size = Self.idealSize
            size.height += window.frame.height - window.contentLayoutRect.height
            size.width = min(size.width, area.width)
            size.height = min(size.height, area.height)
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
            origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
            origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
            window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        }
    }
}

/// Hands the window that hosts a view to `onWindow`, once it exists.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
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
}
