import Foundation

/// The one JSON configuration for fixtures, cache files and the widget snapshot, so a file
/// written by the app always reads back in the widget and in day-cli.
public enum DayJSON {
    /// Dates as ISO 8601 with offset (`2026-11-04T09:30:00+01:00` reads; writes use `Z`).
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Sorted keys, so rewriting an unchanged file produces the same bytes.
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
