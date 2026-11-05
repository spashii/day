import Foundation

extension Fixture {
    /// What a surface is handed from this fixture: events from the calendars that are on in
    /// Google (`selected`), in the order the accounts were added so `merged` keeps the
    /// first-added account's copy of a duplicate, merged across accounts. day-cli and the
    /// golden tests read the invented week through it.
    public func visibleEvents() -> [Event] {
        let hidden = Set(calendars.filter { !$0.selected }.map(\.id))
        let order = Dictionary(
            uniqueKeysWithValues: accounts.sorted { $0.addedAt < $1.addedAt }.enumerated()
                .map { ($1.id, $0) })
        let ordered = events.enumerated()
            .filter { !hidden.contains($0.element.id.calendar) }
            .sorted { a, b in
                (order[a.element.account] ?? .max, a.offset) < (order[b.element.account] ?? .max, b.offset)
            }
            .map(\.element)
        return merged(ordered)
    }
}
