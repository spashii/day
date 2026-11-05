import DayCore
import SwiftUI

// How every view reaches the store. The app entry points set it once at the root with
// `.calendarStore(store)`; views read it with `@EnvironmentStore`. The same modifier sets the
// calendar, zone and locale the store's rules run in, so a fixture written in Amsterdam
// reads the same in previews, screenshots and on a device set to India.

private struct CalendarStoreKey: EnvironmentKey {
    static var defaultValue: (any CalendarStore)? { nil }
}

extension EnvironmentValues {
    /// The store the views read. Nil only when a root forgot `.calendarStore(_:)`.
    var calendarStore: (any CalendarStore)? {
        get { self[CalendarStoreKey.self] }
        set { self[CalendarStoreKey.self] = newValue }
    }
}

extension View {
    /// Puts `store` in the environment with its calendar, zone and locale. Call it once at
    /// the root of each window, sheet host and menu bar panel.
    func calendarStore(_ store: any CalendarStore) -> some View {
        environment(\.calendarStore, store)
            .environment(\.calendar, store.calendar)
            .environment(\.timeZone, store.calendar.timeZone)
            .environment(\.locale, store.calendar.locale ?? .autoupdatingCurrent)
    }
}

/// Reads the store from the environment. Missing it is a programming error at the root, so
/// it stops there loudly rather than drawing an empty calendar that looks like a bug in the
/// data.
@MainActor
@propertyWrapper
struct EnvironmentStore: DynamicProperty {
    @Environment(\.calendarStore) private var store

    var wrappedValue: any CalendarStore {
        guard let store else {
            preconditionFailure("No CalendarStore in the environment: call .calendarStore(_:) at the root")
        }
        return store
    }
}

/// What `Choose Calendars…` does: the iPhone opens the Calendars sheet, the Mac opens
/// Settings. Each root sets it; without one the button is not shown.
struct ChooseCalendarsAction {
    let handler: @MainActor () -> Void

    @MainActor
    func callAsFunction() {
        handler()
    }
}

private struct ChooseCalendarsKey: EnvironmentKey {
    static var defaultValue: ChooseCalendarsAction? { nil }
}

extension EnvironmentValues {
    var chooseCalendars: ChooseCalendarsAction? {
        get { self[ChooseCalendarsKey.self] }
        set { self[ChooseCalendarsKey.self] = newValue }
    }
}

/// What a tap on an event row does on the iPhone: the root shows the event sheet, so the app
/// shows one sheet at a time and a widget link replaces whichever sheet is open. `zoom` is
/// the row's namespace, so the sheet still grows out of the row it came from. Without one, as
/// in previews, the list presents the sheet itself.
struct PresentEventAction {
    let handler: @MainActor (Event, Namespace.ID) -> Void

    @MainActor
    func callAsFunction(_ event: Event, zoom: Namespace.ID) {
        handler(event, zoom)
    }
}

private struct PresentEventKey: EnvironmentKey {
    static var defaultValue: PresentEventAction? { nil }
}

extension EnvironmentValues {
    var presentEvent: PresentEventAction? {
        get { self[PresentEventKey.self] }
        set { self[PresentEventKey.self] = newValue }
    }
}

/// The spacing scale from the brief: 4 inside a row, 8 between a cell's elements, 16 between
/// blocks, 24 above section breaks. Nothing else is used.
enum Spacing {
    static let row: CGFloat = 4
    static let cell: CGFloat = 8
    static let block: CGFloat = 16
    static let section: CGFloat = 24
}

enum Platform {
    #if os(macOS)
        static let isMac = true
    #else
        static let isMac = false
    #endif
}
