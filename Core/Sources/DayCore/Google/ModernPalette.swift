import Foundation

/// Google Calendar's "modern" event palette, keyed by an event's `colorId`. The API's
/// `colors.get` returns the older "classic" hex values for the same IDs (7 Peacock is
/// `#46D6DB` there, `#039BE5` in the web app), so Day ships the table the web app paints
/// with and never calls `colors.get`. Source: the classic and modern table at
/// google-calendar-simple-api.readthedocs.io/en/v2.1.0/colors.html.
public enum ModernPalette {
    public struct Color: Hashable, Sendable {
        public var name: String
        public var hex: String
    }

    public static let event: [String: Color] = [
        "1": Color(name: "Lavender", hex: "#7986CB"),
        "2": Color(name: "Sage", hex: "#33B679"),
        "3": Color(name: "Grape", hex: "#8E24AA"),
        "4": Color(name: "Flamingo", hex: "#E67C73"),
        "5": Color(name: "Banana", hex: "#F6BF26"),
        "6": Color(name: "Tangerine", hex: "#F4511E"),
        "7": Color(name: "Peacock", hex: "#039BE5"),
        "8": Color(name: "Graphite", hex: "#616161"),
        "9": Color(name: "Blueberry", hex: "#3F51B5"),
        "10": Color(name: "Basil", hex: "#0B8043"),
        "11": Color(name: "Tomato", hex: "#D50000"),
    ]

    /// The hex for an event `colorId`, nil for an ID outside the table.
    public static func eventHex(_ colorID: String) -> String? {
        event[colorID]?.hex
    }
}
