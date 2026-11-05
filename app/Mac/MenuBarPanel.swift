import AppKit
import DayCore
import SwiftUI

/// The menu bar item's label: plain text in the menu bar font with tabular digits, from the
/// same `nextEvents` as the Lock Screen widget so the two never disagree about what is next.
/// It follows the store's clock, which moves each minute on a live store. As short as the
/// rules can make it, because macOS hides the items that do not fit beside the notch:
///
/// - Quiet (next event today more than 15 minutes away): `14:00`.
/// - Within 15 minutes: `in 12 min`.
/// - In progress: `18 min left`.
/// - After the last event, or nothing today: the `calendar` symbol alone.
///
/// A title of 8 characters or fewer joins the text (`14:00 Standup`); a longer one is left
/// out, never cut.
struct MenuBarLabelView: View {
    @EnvironmentStore private var store

    var body: some View {
        let label = current
        HStack(spacing: Spacing.row) {
            if label.showsSymbol {
                Image(systemName: "calendar")
            }
            if let text = label.text {
                Text(verbatim: text)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label.text.map { "Day, \($0)" } ?? "Day"))
    }

    private var current: MenuBarLabel {
        let now = store.now
        let calendar = store.calendar
        let today = CivilDate(now, in: calendar)
        let next = nextEvents(
            events: store.events(in: today...today.adding(days: 8)), now: now, calendar: calendar)
        return menuBarLabel(next: next, now: now, calendar: calendar)
    }
}

/// The panel under the menu bar item, 320 pt wide: today's rows (all-day lines, Earlier row,
/// now line, `Join` in its 10-minute window), as tall as the day needs, and two
/// text buttons at the bottom. A click on a row opens the main window on that day with the
/// event's popover. No filters, no mini month, no settings gear.
///
/// With no account, or every account signed out, the first-run screen is what the window
/// shows, so the panel offers one line that opens it.
struct MenuBarPanel: View {
    @EnvironmentStore private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    let state: MacState

    static let width: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            if store.needsFirstRun {
                firstRunLine
            } else {
                StackedDayList(day: store.today, onOpen: open)
            }
            Divider()
            HStack {
                Button("Open Day") { openDay() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Spacing.block)
            .padding(.vertical, Spacing.cell)
        }
        .frame(width: Self.width)
        .environment(
            \.chooseCalendars,
            ChooseCalendarsAction {
                state.settingsTab = .accounts
                openSettings()
                NSApp.activate()
            }
        )
    }

    /// The state is a line of text where the content would be, and the line is the way out.
    private var firstRunLine: some View {
        Button(store.accounts.isEmpty ? "Add Google Account…" : "Sign In Again…") {
            openDay()
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.block)
    }

    private func openDay() {
        openWindow(id: DayWindowID.main)
        NSApp.activate()
    }

    private func open(_ event: Event) {
        state.reveal(event) {
            openWindow(id: DayWindowID.main)
            NSApp.activate()
        }
    }
}

#Preview("Panel, 12:10") {
    let store = PreviewStore.make(at: "12:10")
    MenuBarPanel(state: MacState(store: store))
        .calendarStore(store)
}

#Preview("Panel, 13:55") {
    let store = PreviewStore.make(at: "13:55")
    MenuBarPanel(state: MacState(store: store))
        .calendarStore(store)
}

#Preview("Panel, no account") {
    let store = PreviewStore.make(state: .noAccount)
    MenuBarPanel(state: MacState(store: store))
        .calendarStore(store)
}

#Preview("Panel, offline") {
    let store = PreviewStore.make(at: "9:25", state: .offline)
    MenuBarPanel(state: MacState(store: store))
        .calendarStore(store)
}

#Preview("Panel, signed out") {
    let store = PreviewStore.make(at: "12:10", state: .signedOut)
    MenuBarPanel(state: MacState(store: store))
        .calendarStore(store)
}

#Preview("Label, 13:55") {
    let store = PreviewStore.make(at: "13:55")
    MenuBarLabelView()
        .calendarStore(store)
        .padding()
}
