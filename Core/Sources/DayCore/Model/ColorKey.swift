import Foundation

/// The system color an event or calendar draws in. Google's hex is mapped to the nearest of
/// thirteen system colors, so light, dark and Increase Contrast variants come from the
/// system and Google's pale yellows never meet a white background. `Colors.swift` in the app
/// turns a key into a SwiftUI `Color`; Core never imports SwiftUI.
public enum ColorKey: String, Codable, Hashable, Sendable, CaseIterable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    /// Maps `#rrggbb` (or `rrggbb`) by hue. Colors with little chroma go to gray, and dark,
    /// muted oranges and reds go to brown, which is how Google's "Cocoa" and "Birch" read.
    /// Nil when the string is not a hex color.
    public init?(hex: String) {
        guard let (r, g, b) = ColorKey.components(hex) else { return nil }
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let chroma = maxC - minC
        if chroma < 0.12 {
            self = .gray
            return
        }
        var hue: Double
        if maxC == r {
            hue = 60 * ((g - b) / chroma).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            hue = 60 * ((b - r) / chroma + 2)
        } else {
            hue = 60 * ((r - g) / chroma + 4)
        }
        if hue < 0 { hue += 360 }
        let saturation = chroma / maxC
        let value = maxC

        if hue < 50 || hue >= 345, value < 0.72, saturation < 0.8 {
            self = .brown
            return
        }
        // Hue bands, in degrees, chosen so Google's modern event palette and its calendar
        // colors each land on the system color a person would name them by.
        switch hue {
        case 345..<360, 0..<12: self = .red
        case 12..<40: self = .orange
        case 40..<70: self = .yellow
        case 70..<160: self = .green
        case 160..<178: self = .mint
        case 178..<192: self = .teal
        case 192..<208: self = .cyan
        case 208..<228: self = .blue
        case 228..<255: self = .indigo
        case 255..<300: self = .purple
        default: self = .pink
        }
    }

    static func components(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        return (
            Double((n >> 16) & 0xFF) / 255,
            Double((n >> 8) & 0xFF) / 255,
            Double(n & 0xFF) / 255
        )
    }
}
