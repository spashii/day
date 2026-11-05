import AppKit
import DayCore
import Observation
import SwiftUI

/// What the Mac window, its menus and the menu bar panel share: the selected day, the month's
/// scroll, the day pane and the selected event. One object, because a menu command, a toolbar
/// button and a click on a menu bar row must all move the same selection.
///
/// It holds no events of its own; every answer is asked of the store and the rules, so the
/// window, the menus and the menu bar can never disagree.
@MainActor
@Observable
final class MacState {
    enum SettingsTab: Hashable {
        case accounts
        case general
    }

    let store: any CalendarStore
    let scroll = MonthScroll()

    /// The day the person picked; nil follows today, so the pane moves on at midnight.
    private var chosenDay: CivilDate?
    var showsDayPane = true
    var showsGoToDate = false
    /// The event row Tab selected, which Command-E opens in Google Calendar.
    var selectedEvent: EventID?
    /// The event whose popover is open.
    var presentedEvent: EventID?
    var settingsTab = SettingsTab.accounts
    /// Whether the main window is on screen, so the menu bar panel knows if a popover can
    /// anchor at once or must wait for the window to draw.
    var windowIsOpen = false

    init(store: any CalendarStore) {
        self.store = store
    }

    // MARK: The selected day

    /// The day the pane shows and the grid tints.
    var day: CivilDate { chosenDay ?? store.today }

    /// Selects `day` without moving the scroll: a click, which is on screen already.
    func select(_ day: CivilDate) {
        chosenDay = day == store.today ? nil : day
        selectedEvent = nil
        presentedEvent = nil
    }

    /// Go to Today, Command-T.
    func goToToday() {
        select(store.today)
        show(store.today)
    }

    /// Go to Date…, Shift-Command-T.
    func goTo(_ day: CivilDate) {
        select(day)
        show(day)
    }

    /// An arrow key: the day moves by one or by a week, and the month scrolls only when the
    /// day would otherwise leave the screen.
    func move(days: Int) {
        let target = day.adding(days: days)
        select(target)
        keepOnScreen(target)
    }

    /// Previous and next month, Command-Left and Command-Right. The month scrolls to put its
    /// first week on top and the selection follows to the same day of the month, so the pane
    /// and the title never name different months.
    func moveMonth(by months: Int) {
        let calendar = store.calendar
        let shown = scroll.month(today: store.today, calendar: calendar)
        let index = shown.year * 12 + (shown.month - 1) + months
        let year = index / 12
        let month = index % 12 + 1
        let first = CivilDate(year: year, month: month, day: 1)
        let length = calendar.range(of: .day, in: .month, for: first.date(in: calendar))?.count ?? 28
        scroll.showMonth(offset: months, today: store.today, calendar: calendar)
        select(CivilDate(year: year, month: month, day: min(day.day, length)))
    }

    /// The month opens on the current week, but scrolling there before the rows above it have
    /// been measured lands the week a row too high, with its numerals under the toolbar. One
    /// step away and back, once the first frame exists, puts it where it belongs. A person
    /// who has already scrolled or picked a day keeps their place.
    func settleScroll() async {
        let today = store.today
        let calendar = store.calendar
        try? await Task.sleep(for: .milliseconds(250))
        let current = MonthScroll.weekStart(of: today, calendar: calendar)
        guard chosenDay == nil, scroll.topWeek == nil || scroll.topWeek == current else { return }
        scroll.show(today.adding(days: -7), today: today, calendar: calendar)
        try? await Task.sleep(for: .milliseconds(100))
        scroll.show(today, today: today, calendar: calendar)
    }

    /// The month's title for the window toolbar: `November 2026`.
    var title: String {
        scroll.title(today: store.today, now: store.now, calendar: store.calendar, alwaysYear: true)
    }

    private func show(_ day: CivilDate) {
        scroll.show(day, today: store.today, calendar: store.calendar)
    }

    /// Scrolls only if `day`'s week is off screen: to the top when it is above, to the bottom
    /// row when it is below. Before the grid has reported its rows there is nothing to do.
    private func keepOnScreen(_ day: CivilDate) {
        let week = MonthScroll.weekStart(of: day, calendar: store.calendar)
        let visible = scroll.visibleWeeks
        guard let first = visible.first, let last = visible.last else { return }
        if week < first {
            show(week)
        } else if week > last {
            show(week.adding(days: -7 * (visible.count - 1)))
        }
    }

    // MARK: Events in the day pane

    /// The event rows the pane draws, top to bottom: what Tab walks through.
    func paneEvents() -> [Event] {
        let rows = dayRows(
            day: day, events: store.dayEvents(day), now: store.now, calendar: store.calendar)
        return rows.compactMap { row -> Event? in
            if case .event(let event, _, _) = row { return event }
            return nil
        }
    }

    var canShowEvent: Bool {
        !paneEvents().isEmpty
    }

    /// The selected event, looked up in the pane's day.
    var selectedEventValue: Event? {
        guard let id = selectedEvent else { return nil }
        return store.dayEvents(day).first { $0.id == id }
    }

    /// Tab and Shift-Tab: the next or previous event in the pane. With nothing selected,
    /// Tab starts at the first and Shift-Tab at the last; at either end the selection stays.
    func moveEvent(by step: Int) {
        let events = paneEvents()
        guard !events.isEmpty else { return }
        showsDayPane = true
        let index = events.firstIndex { $0.id == selectedEvent }
        let target = index.map { min(max($0 + step, 0), events.count - 1) }
            ?? (step > 0 ? 0 : events.count - 1)
        selectedEvent = events[target].id
        presentedEvent = nil
    }

    /// Return and Command-I: the popover of the selected event. With nothing selected it
    /// takes the one that is under way or next, else the day's first.
    func showEvent() {
        let events = paneEvents()
        guard !events.isEmpty else { return }
        showsDayPane = true
        if selectedEventValue == nil {
            let now = store.now
            let calendar = store.calendar
            selectedEvent = (events.first { $0.time.end(in: calendar) > now } ?? events[0]).id
        }
        presentedEvent = selectedEvent
    }

    // MARK: Join and Google Calendar

    /// The event Command-J joins: the one under way while it has a link, else the next one
    /// from 10 minutes before it starts. The same answer as Join in the day list and in the
    /// menu bar panel.
    var joinable: Event? {
        let now = store.now
        let calendar = store.calendar
        let today = CivilDate(now, in: calendar)
        let next = nextEvents(
            events: store.events(in: today...today.adding(days: 8)), now: now, calendar: calendar)
        return joinableEvent(next: next, now: now)
    }

    func join() {
        guard let event = joinable, let url = event.joinURL else { return }
        open(url, for: event)
    }

    var canOpenSelectedInGoogle: Bool {
        selectedEventValue?.htmlLink != nil
    }

    /// Command-E: Apple Calendar's Edit key keeps its meaning, so editing happens in Google
    /// Calendar, on the account the event came from.
    func openSelectedInGoogle() {
        guard let event = selectedEventValue, let url = event.htmlLink else { return }
        open(url, for: event)
    }

    private func open(_ url: URL, for event: Event) {
        let handoff = HandoffAction.system
        handoff(url, account: store.account(event.account))
    }

    // MARK: From the menu bar panel

    /// Opens the main window on `event`: its day selected, the pane open, its row selected and
    /// its popover shown. `openWindow` brings the window forward; the popover waits for the
    /// window to draw the row it anchors to, longer when the window was closed.
    func reveal(_ event: Event, openWindow: () -> Void) {
        let calendar = store.calendar
        let days = coveredDays(event, calendar: calendar)
        let today = store.today
        let target = days.contains(today) ? today : days.lowerBound
        let wasOpen = windowIsOpen
        select(target)
        showsDayPane = true
        if !scroll.visibleWeeks.contains(MonthScroll.weekStart(of: target, calendar: calendar)) {
            show(target)
        }
        selectedEvent = event.id
        openWindow()
        Task {
            try? await Task.sleep(for: .milliseconds(wasOpen ? 150 : 450))
            presentedEvent = event.id
        }
    }
}

// MARK: - Focus

private struct DayWindowKey: FocusedValueKey {
    typealias Value = MacState
}

extension FocusedValues {
    /// Set by the main window, so the menu commands that move the selection are on only
    /// while the window is the one in front. In Settings, Tab and the arrow keys keep their
    /// own meaning.
    var dayWindow: MacState? {
        get { self[DayWindowKey.self] }
        set { self[DayWindowKey.self] = newValue }
    }
}

enum DayWindowID {
    static let main = "main"
}
