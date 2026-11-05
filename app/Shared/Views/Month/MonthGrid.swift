import DayCore
import SwiftUI

/// One month page: the month's own week rows, four to six, with the neighbouring months' days
/// left empty and bars cut off at the month's edge. The rows fill the height they are given,
/// as equal as their weeks allow: a busy week takes the room it needs to draw every mark and
/// the quieter weeks share the rest. On the Mac a page whose weeks need more than the window
/// scrolls; on the iPhone the fullest days fold their last titles into `+2`.
struct MonthGrid: View {
    @EnvironmentStore private var store

    /// The first day of the month.
    let month: CivilDate
    /// The height of the iPhone page. The Mac passes nil and the rows fill whatever height
    /// the window offers them.
    var height: CGFloat? = nil
    var selection: CivilDate?
    var zoom: Namespace.ID?
    let onSelect: (CivilDate) -> Void

    @State private var width: CGFloat = 0

    // Scaled with the text size up to the grid's cap, and handed to every row.
    @ScaledMetric(relativeTo: .callout) private var numeralRow = MonthMetrics.numeralRow
    @ScaledMetric(relativeTo: .callout) private var numeralCircle = MonthMetrics.numeralCircle
    @ScaledMetric(relativeTo: .caption2) private var barHeight = MonthMetrics.barHeight
    @ScaledMetric(relativeTo: .caption2) private var titleLine = MonthMetrics.titleLine
    @ScaledMetric(relativeTo: .caption2) private var minTitledWidth = MonthMetrics.minTitledWidth
    @ScaledMetric(relativeTo: .caption2) private var minBarTitleWidth = MonthMetrics.minBarTitleWidth

    private var metrics: MonthMetrics {
        MonthMetrics(
            numeralRow: numeralRow, numeralCircle: numeralCircle, barHeight: barHeight,
            titleLine: titleLine, minTitledWidth: minTitledWidth,
            minBarTitleWidth: minBarTitleWidth)
    }

    var body: some View {
        let calendar = store.calendar
        let days = MonthScroll.days(of: month)
        let layouts = MonthScroll.weeks(of: month, calendar: calendar).map { week in
            WeekLayout(
                start: week,
                events: store.events(in: week...week.adding(days: 6)),
                shown: days,
                calendar: calendar,
                maxLanes: Platform.isMac ? nil : 2,
                mark: { store.monthMark($0) })
        }
        Group {
            if let height {
                let heights = phoneHeights(layouts, total: height)
                VStack(spacing: 0) {
                    ForEach(layouts.indices, id: \.self) { index in
                        row(layouts[index], height: heights[index])
                    }
                }
                .frame(height: height, alignment: .top)
                .preference(key: MonthGridLeast.self, value: least(layouts).reduce(0, +))
            } else {
                FillRowsLayout {
                    ForEach(layouts, id: \.start) { layout in
                        row(layout, height: 0)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func row(_ layout: WeekLayout, height: CGFloat) -> some View {
        WeekRow(
            layout: layout,
            today: store.today,
            columnWidth: width / 7,
            metrics: metrics,
            height: height,
            selection: selection,
            zoom: zoom,
            onSelect: onSelect)
    }

    /// The iPhone rows' heights. When the weeks need more than the page has, every week
    /// still gets its numerals, bars, dots and one titled line, and the fuller days fold the
    /// rest into `+2`. The page asks for at least that much (`MonthGridLeast`); only on a
    /// screen too short to give it does each week give up room in proportion.
    private func phoneHeights(_ layouts: [WeekLayout], total: CGFloat) -> [CGFloat] {
        let needs = layouts.map { metrics.phoneHeight($0, columnWidth: width / 7) }
        if needs.reduce(0, +) <= total {
            return MonthMetrics.share(total, needs: needs)
        }
        let least = least(layouts)
        let needed = least.reduce(0, +)
        if needed <= total {
            return MonthMetrics.share(total, needs: least)
        }
        return least.map { $0 * total / needed }
    }

    /// Each iPhone week's height with at most one titled line per day.
    private func least(_ layouts: [WeekLayout]) -> [CGFloat] {
        layouts.map { metrics.phoneHeight($0, columnWidth: width / 7, lines: 1) }
    }
}

/// The least height an iPhone month page can draw its weeks in: numerals, bars, dots and one
/// titled line a day. The month view grows the grid to the largest of the loaded pages, which
/// matters only at the largest text sizes.
struct MonthGridLeast: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Stacks the Mac's week rows to fill the height it is offered, as equal as their content
/// allows. A week whose content needs more than an equal share keeps its content height and
/// the others share what is left. Its ideal height is the content's, so `ViewThatFits` can
/// tell when the weeks need more than the window has and put them in a scroll view instead.
struct FillRowsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let needed = needs(width: width, subviews: subviews).reduce(0, +)
        let offered = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return CGSize(width: width, height: max(needed, offered))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let heights = MonthMetrics.share(bounds.height, needs: needs(width: bounds.width, subviews: subviews))
        var y = bounds.minY
        for (subview, rowHeight) in zip(subviews, heights) {
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: rowHeight))
            y += rowHeight
        }
    }

    /// Each week's content height at `width`.
    private func needs(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }
}
