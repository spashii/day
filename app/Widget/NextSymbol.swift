import DayCore
import Foundation
import UIKit

/// The calendar symbol the Lock Screen names an entry's event with.
///
/// The inline and circular families always show the next event, so the symbol is the one of
/// the calendar that event sits on, read from `calendar-symbols.json` in the App Group
/// container where the app writes it. The provider resolves it once per reload, for every
/// entry, from the same events and the same `nextEvents` rule the entry's text came from, so
/// the symbol and the time always belong to one event. With no symbol chosen on any calendar,
/// which is the default, nothing but that one small file is read.
struct NextSymbol: Hashable, Sendable {
    /// The SF Symbol name.
    var name: String
    /// What VoiceOver reads for it: the symbol's own name in the picker (`Work`).
    var label: String

    /// One symbol per entry, in the entries' order; nil where there is none to show: no
    /// symbol chosen, nothing ahead, or a symbol this system cannot draw.
    static func resolve(
        _ entries: [WidgetEntry], events: [Event]?, calendar: Calendar
    ) -> [NextSymbol?] {
        guard let events, let cache = try? CacheDirectory.shared() else {
            return entries.map { _ in nil }
        }
        let symbols = CalendarSymbolMap.read(from: cache)
        guard !symbols.isEmpty else { return entries.map { _ in nil } }
        return entries.map { entry in
            guard
                let symbol = symbols.nextEventSymbol(
                    events: events, now: entry.date, calendar: calendar),
                UIImage(systemName: symbol.name) != nil
            else { return nil }
            return NextSymbol(name: symbol.name, label: symbol.label)
        }
    }
}
