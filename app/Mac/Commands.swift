import AppKit
import DayCore
import SwiftUI

/// The menus, with Apple Calendar's keyboard map. Every shortcut is a menu item and no key
/// works without one, so nothing is hidden: the arrow keys and Tab are View and Event items
/// like any other. Return, which opens
/// the same popover as Command-I, is the one alias, and the window handles it.
///
/// - Day (system): About, Settings…, Quit.
/// - File (system): Close.
/// - Edit: Copy.
/// - View: Go to Today, Go to Date…, the day, week and month steps, Show Day Pane, Refresh.
/// - Event: Show Event, Join Meeting, Open in Google Calendar, Next Event, Previous Event.
/// - Window and Help (system).
///
/// There is no text size item: macOS has no Dynamic Type and the shared views' text styles do
/// not follow the `dynamicTypeSize` environment on the Mac, so a Command-Plus would change
/// nothing. It returns when the views scale their own fonts from a value they read.
///
/// Items that move the selection are on only while the main window is in front, so Tab and
/// the arrow keys keep their own meaning in Settings and in the Go to Date sheet's picker.
/// Join Meeting works anywhere in the app, because the meeting does not need the window.
struct DayCommands: Commands {
    let state: MacState
    @FocusedValue(\.dayWindow) private var window: MacState?

    var body: some Commands {
        // Edit: Copy only, since nothing here can be cut, pasted, undone or formatted.
        CommandGroup(replacing: .undoRedo) {}
        CommandGroup(replacing: .pasteboard) {
            Button("Copy") {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("c")
        }
        CommandGroup(replacing: .textEditing) {}
        CommandGroup(replacing: .textFormatting) {}

        // View: no sidebar, and no toolbar to hide or customize.
        CommandGroup(replacing: .sidebar) {}
        CommandGroup(replacing: .toolbar) {
            viewItems
        }

        CommandMenu("Event") {
            eventItems
        }

        // Day ships no help book, so Help keeps only the system's menu search.
        CommandGroup(replacing: .help) {}
    }

    /// Shift-Tab. The keyboard reports it as the back-tab character, not as Tab with Shift, so a
    /// menu item bound to Tab and Shift never sees it. The menu draws it as Shift-Tab.
    private static let backTab = KeyEquivalent("\u{19}")

    private var inFront: Bool {
        window != nil && !state.showsGoToDate
    }

    // MARK: View

    @ViewBuilder
    private var viewItems: some View {
        Button("Go to Today") { state.goToToday() }
            .keyboardShortcut("t")
            .disabled(!inFront)
        Button("Go to Date…") { state.showsGoToDate = true }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(window == nil)

        Divider()

        Button("Previous Day") { state.move(days: -1) }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!inFront)
        Button("Next Day") { state.move(days: 1) }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!inFront)
        Button("Previous Week") { state.move(days: -7) }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(!inFront)
        Button("Next Week") { state.move(days: 7) }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(!inFront)
        Button("Previous Month") { state.moveMonth(by: -1) }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!inFront)
        Button("Next Month") { state.moveMonth(by: 1) }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!inFront)

        Divider()

        // A checked item rather than Show and Hide swapping places, so the title is the one
        // the menu always carries.
        Toggle(
            "Show Day Pane",
            isOn: Binding(get: { state.showsDayPane }, set: { state.showsDayPane = $0 })
        )
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(window == nil)

        Divider()

        Button("Refresh") {
            Task { await state.store.refresh() }
        }
        .keyboardShortcut("r")
        .disabled(window == nil)
    }

    // MARK: Event

    @ViewBuilder
    private var eventItems: some View {
        Button("Show Event") { state.showEvent() }
            .keyboardShortcut("i")
            .disabled(!inFront || !state.canShowEvent)
        Button("Join Meeting") { state.join() }
            .keyboardShortcut("j")
            .disabled(state.joinable == nil)
        Button("Open in Google Calendar") { state.openSelectedInGoogle() }
            .keyboardShortcut("e")
            .disabled(!inFront || !state.canOpenSelectedInGoogle)

        Divider()

        Button("Next Event") { state.moveEvent(by: 1) }
            .keyboardShortcut(.tab, modifiers: [])
            .disabled(!inFront || !state.canShowEvent)
        Button("Previous Event") { state.moveEvent(by: -1) }
            .keyboardShortcut(Self.backTab, modifiers: [])
            .disabled(!inFront || !state.canShowEvent)
    }
}
