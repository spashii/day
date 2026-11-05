import DayCore
import Observation
import SwiftUI

#if os(iOS)
    import UIKit
    import WidgetKit
#else
    import AppKit
#endif

/// The symbols the person has given their calendars, as the views read and change them.
///
/// Shared by every device on the Apple ID through the iCloud key-value store, one entry per
/// calendar (`CloudCalendarSettings`), and never kept in Google. This device's copy is
/// `calendar-symbols.json` in the shared folder, which the widgets read. On iPhone that folder
/// is the App Group container, so the Lock Screen widget reads the same file; a change asks
/// WidgetKit to redraw it. On the Mac the folder is the app's own, so a copy of the file goes
/// to the App Group for the desktop widget (`WidgetSnapshotWriter`). A calendar with no symbol
/// wears its color dot.
///
/// A single `shared` instance serves the whole app, so views need no injection; previews and
/// screenshots hand a private in-memory one to the environment instead, which writes nothing.
@MainActor
@Observable
final class CalendarSymbols {
    static let shared = CalendarSymbols(cache: try? BuildFolder.cache())

    private(set) var map: CalendarSymbolMap

    @ObservationIgnored private let cache: CacheDirectory?
    /// Where a symbol the person chooses goes for the other devices. `AppModel.live()` sets it;
    /// previews, screenshots and the fixture leave it nil, so they never write to iCloud.
    @ObservationIgnored var cloud: CloudCalendarSettings?

    /// Reads the file in `cache` now, so the first frame already draws the symbols. A nil
    /// `cache` keeps everything in memory, starting from `map`.
    init(cache: CacheDirectory?, map: CalendarSymbolMap = CalendarSymbolMap()) {
        self.cache = cache
        if let cache {
            self.map = CalendarSymbolMap.read(from: cache)
        } else {
            self.map = map
        }
    }

    /// An in-memory store for previews and screenshots.
    convenience init(_ assigned: [CalendarID: CalendarSymbol]) {
        var map = CalendarSymbolMap()
        for (calendar, symbol) in assigned { map.set(symbol, for: calendar) }
        self.init(cache: nil, map: map)
    }

    func symbol(for calendar: CalendarID) -> CalendarSymbol? {
        map.symbol(for: calendar)
    }

    /// Sets the calendar's symbol, nil for the color dot. It shows at once and is written
    /// behind the screen.
    func set(_ symbol: CalendarSymbol?, for calendar: CalendarID) {
        var next = map
        next.set(symbol, for: calendar)
        guard next != map else { return }
        save(next)
        cloud?.setSymbol(symbol?.name, for: calendar)
    }

    /// Takes the symbols another device chose, as `CloudCalendarSettings.reconcile` laid them
    /// over this device's.
    func replace(with next: CalendarSymbolMap) {
        save(next)
    }

    /// Drops a removed account's symbols on this device, so adding it back starts from color
    /// dots. The account's entries in iCloud are cleared where it is removed.
    func forget(account: AccountID) {
        var next = map
        next.forget(account)
        save(next)
    }

    private func save(_ next: CalendarSymbolMap) {
        guard next != map else { return }
        map = next
        guard let cache else { return }
        // A failed write keeps the symbol for this launch and loses it at the next; there is
        // nothing the person could do about it, so it is not worth a message.
        try? next.write(to: cache)
        #if os(iOS)
            WidgetCenter.shared.reloadTimelines(ofKind: DayIdentifiers.widgetKind)
        #else
            // The desktop widget cannot read the app's folder, so it gets its own copy.
            WidgetSnapshotWriter.publish(symbols: next)
        #endif
    }
}

// MARK: - Environment

private struct CalendarSymbolsKey: EnvironmentKey {
    static var defaultValue: CalendarSymbols? { nil }
}

extension EnvironmentValues {
    /// An override of the shared store, for previews and screenshots. Nil in the apps.
    var calendarSymbols: CalendarSymbols? {
        get { self[CalendarSymbolsKey.self] }
        set { self[CalendarSymbolsKey.self] = newValue }
    }
}

extension View {
    /// Draws this view's calendar symbols from `symbols` instead of the shared store.
    func calendarSymbols(_ symbols: CalendarSymbols) -> some View {
        environment(\.calendarSymbols, symbols)
    }
}

/// Reads the symbols from the environment, else the shared store.
@MainActor
@propertyWrapper
struct EnvironmentSymbols: DynamicProperty {
    @Environment(\.calendarSymbols) private var injected

    var wrappedValue: CalendarSymbols {
        injected ?? .shared
    }
}

extension CalendarSymbol {
    /// Whether this system can draw the symbol. Each of the thirty exists since iOS 16 and
    /// macOS 13, so today this is always true; it keeps a symbol added to the set later, and
    /// chosen on a phone a release ahead of the Mac, from drawing as an empty space on the
    /// older system. The mark falls back to the color dot instead.
    var isDrawable: Bool {
        #if os(iOS)
            UIImage(systemName: name) != nil
        #else
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #endif
    }
}
