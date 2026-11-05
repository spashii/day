import Foundation

/// Folds the same event arriving from several calendars or accounts into one, so a meeting
/// never appears twice, or overlaps itself on the Lock Screen.
///
/// Events sharing `iCalUID` and `originalStart` (or start, for single events) are one event.
/// The kept copy is the one the account holder organizes, then the one they answered, then
/// the earliest in the input, so pass events in account order with the first-added account
/// first. The kept copy's `calendars` lists every calendar the event sat on, its own first.
public func merged(_ events: [Event]) -> [Event] {
    var order: [MergeKey] = []
    var groups: [MergeKey: [Event]] = [:]
    for event in events {
        let key = MergeKey(event)
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(event)
    }
    return order.map { key in
        let copies = groups[key]!
        var kept =
            copies.first(where: \.isOrganizer)
            ?? copies.first(where: { $0.response != .needsAction && $0.response != .none })
            ?? copies[0]
        var calendars = kept.calendars
        for copy in copies {
            for id in copy.calendars where !calendars.contains(id) {
                calendars.append(id)
            }
        }
        kept.calendars = calendars
        return kept
    }
}

private struct MergeKey: Hashable {
    enum Start: Hashable {
        case instant(Date)
        case day(CivilDate)
    }

    var uid: String
    var start: Start

    init(_ event: Event) {
        uid = event.iCalUID
        if let original = event.originalStart {
            start = .instant(original)
        } else {
            switch event.time {
            case .allDay(let day, _): start = .day(day)
            case .timed(let instant, _, _): start = .instant(instant)
            }
        }
    }
}
