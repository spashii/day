import Foundation

/// The app's own URLs, built by the widget and handled by the app's `onOpenURL`, defined once
/// here so the two ends cannot drift.
///
/// - `day://day/2026-11-04` opens that day.
/// - `day://event/<account sub>/<calendar ID>/<event ID>` opens the event sheet. Calendar IDs
///   contain `#`, `@` and `+`, so every path component is percent-encoded.
public enum DayLink: Hashable, Sendable {
    case day(CivilDate)
    case event(EventID)

    public var url: URL {
        var components = URLComponents()
        components.scheme = DayIdentifiers.urlScheme
        switch self {
        case .day(let day):
            components.host = "day"
            components.percentEncodedPath = "/" + DayLink.encode(day.isoString)
        case .event(let id):
            components.host = "event"
            components.percentEncodedPath = "/" + [
                id.account.sub, id.calendar.googleID, id.googleID,
            ].map(DayLink.encode).joined(separator: "/")
        }
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == DayIdentifiers.urlScheme,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let parts = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { String($0).removingPercentEncoding }
        switch components.host {
        case "day":
            guard parts.count == 1, let day = CivilDate(parts[0]) else { return nil }
            self = .day(day)
        case "event":
            guard parts.count == 3 else { return nil }
            let calendar = CalendarID(account: AccountID(parts[0]), googleID: parts[1])
            self = .event(EventID(calendar: calendar, googleID: parts[2]))
        default:
            return nil
        }
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: unreserved)!
    }
}
