import SwiftUI

/// The sizes of a week row at the current text size, up to the grid's cap. The iPhone grid
/// reads them to share its height out among its weeks and the rows draw with the same
/// numbers, so a week is never given less room than it draws in when the page has it.
struct MonthMetrics {
    var numeralRow: CGFloat
    var numeralCircle: CGFloat
    var barHeight: CGFloat
    var titleLine: CGFloat
    /// Narrower than this and one-off titles drop to their colored rules (step one of the
    /// size-drop rule).
    var minTitledWidth: CGFloat
    /// Narrower than this and a bar keeps its fill but drops its title (step two).
    var minBarTitleWidth: CGFloat

    // Sizes from the mockup at the default text size; the grid scales the first six.
    #if os(macOS)
        static let numeralRow: CGFloat = 27
        static let numeralCircle: CGFloat = 22
        static let barHeight: CGFloat = 15
        static let titleLine: CGFloat = 13
        static let dotsRow: CGFloat = 14
        static let dot: CGFloat = 4.5
        /// Between bar lanes and between titled lines.
        static let gap: CGFloat = 2
    #else
        static let numeralRow: CGFloat = 31
        static let numeralCircle: CGFloat = 28
        static let barHeight: CGFloat = 16
        static let titleLine: CGFloat = 13
        /// The dots sit in the middle of it, clear of the last titled line and the hairline.
        static let dotsRow: CGFloat = 13
        static let dot: CGFloat = 5
        /// Between bar lanes and between titled lines: one point, so a busy week asks the
        /// page for as little room as it can.
        static let gap: CGFloat = 1
    #endif
    static let minTitledWidth: CGFloat = 40
    static let minBarTitleWidth: CGFloat = 28

    /// The room the bars over a day take, so its titled lines start right under them.
    func lanesHeight(_ cell: WeekLayout.Cell) -> CGFloat {
        CGFloat(cell.lanesUsed) * (barHeight + Self.gap)
    }

    /// Whether a column this wide still draws one-off titles, or only their colored rules.
    func drawsTitles(columnWidth: CGFloat) -> Bool {
        columnWidth == 0 || columnWidth >= minTitledWidth
    }

    /// How many titled lines, `+2` included, fit in an iPhone cell `height` tall.
    func titleCapacity(_ cell: WeekLayout.Cell, height: CGFloat) -> Int {
        let room = height - numeralRow - lanesHeight(cell) - Self.dotsRow - Self.gap
        // A hair over, so a row given exactly what its lines need is not a line short to
        // rounding.
        return max(0, Int((room + Self.gap) / (titleLine + Self.gap) + 0.01))
    }

    /// The height an iPhone week needs to draw every mark of its busiest day: the numeral,
    /// the bars over the day, each titled line (or the one line of rules once columns are
    /// too narrow for titles), a `+2` for bars that found no lane, and the dots. With
    /// `lines`, titled lines stop at that many: one is the least a week can draw in, where
    /// every fuller day folds into `+2`.
    func phoneHeight(_ layout: WeekLayout, columnWidth: CGFloat, lines limit: Int? = nil) -> CGFloat {
        let titles = drawsTitles(columnWidth: columnWidth)
        let cells = layout.cells.filter(\.isShown).map { cell -> CGFloat in
            var lines = titles
                ? cell.titled.count + (cell.hiddenBars > 0 ? 1 : 0)
                : (cell.titled.isEmpty ? 0 : 1)
            if let limit { lines = min(lines, limit) }
            let block = lines == 0
                ? 0
                : Self.gap + CGFloat(lines) * titleLine + CGFloat(lines - 1) * Self.gap
            return numeralRow + lanesHeight(cell) + block + Self.dotsRow
        }
        return cells.max() ?? numeralRow + Self.dotsRow
    }

    /// Shares `total` out among rows that need `needs`: as equal as the needs allow. A row
    /// that needs more than an equal share keeps its need and the others share what is left.
    /// When the needs add up to more than `total`, the rows keep their needs and the caller
    /// decides: the Mac scrolls, the iPhone squeezes.
    static func share(_ total: CGFloat, needs: [CGFloat]) -> [CGFloat] {
        var remaining = total
        var count = needs.count
        for need in needs.sorted(by: >) where count > 0 {
            guard need > remaining / CGFloat(count) else { break }
            remaining -= need
            count -= 1
        }
        let level = count > 0 ? remaining / CGFloat(count) : 0
        return needs.map { max($0, level) }
    }
}
