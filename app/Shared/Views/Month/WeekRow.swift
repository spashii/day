import DayCore
import SwiftUI

/// One week of a month page: seven equal columns, a hairline above, the numerals, the bar
/// lanes, the titled lines and the dots. Days of the neighbouring month are empty cells. The
/// iPhone row takes the height its page gives it and fits its titled lines to that; the Mac
/// row is at least as tall as its content, so nothing hides.
struct WeekRow: View {
    @EnvironmentStore private var store
    @Environment(\.handoff) private var handoff

    let layout: WeekLayout
    let today: CivilDate
    /// One column's width, which decides what the size-drop rule keeps.
    let columnWidth: CGFloat
    /// The row's sizes at the current text size, shared with the grid.
    let metrics: MonthMetrics
    /// The iPhone row's height, its share of the page. The Mac row ignores it.
    var height: CGFloat = 0
    /// The selected day: a quiet ring around the numeral on the iPhone, a tint over the
    /// cell on the Mac.
    var selection: CivilDate?
    /// The iPhone's zoom source for the Day pushed from a cell.
    var zoom: Namespace.ID?
    let onSelect: (CivilDate) -> Void

    private var numeralRow: CGFloat { metrics.numeralRow }
    private var numeralCircle: CGFloat { metrics.numeralCircle }
    private var barHeight: CGFloat { metrics.barHeight }
    private var titleLine: CGFloat { metrics.titleLine }

    /// The Mac event whose popover is open.
    @State private var shownEvent: EventID?

    var body: some View {
        Group {
            if Platform.isMac {
                macRow
            } else {
                phoneRow
            }
        }
        // Drawn over the row's top edge rather than stacked above it, so the rows of a page
        // add up to exactly the page's height.
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: iPhone

    private var phoneRow: some View {
        HStack(spacing: 0) {
            ForEach(layout.cells) { cell in
                if cell.isShown {
                    Button {
                        onSelect(cell.day)
                    } label: {
                        phoneCell(cell)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(sentence(for: cell))
                    .accessibilityAddTraits(cell.day == selection ? .isSelected : [])
                    .modifier(ZoomSource(id: cell.day, namespace: zoom))
                } else {
                    emptyCell
                }
            }
        }
        .frame(height: height)
        .overlay(alignment: .top) {
            lanes
                .padding(.top, numeralRow)
                .allowsHitTesting(false)
        }
    }

    private func phoneCell(_ cell: WeekLayout.Cell) -> some View {
        VStack(spacing: 0) {
            numeral(cell.day)
                .frame(height: numeralRow)
            Color.clear
                .frame(height: lanesHeight(cell))
            phoneTitles(cell)
                .padding(.top, MonthMetrics.gap)
            Spacer(minLength: 0)
            dots(cell.dotCount)
                .frame(height: MonthMetrics.dotsRow)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(.rect)
    }

    /// As many titled lines as the row has room for; when they do not all fit, the last
    /// line becomes `+2`. Hidden bars count into it. The selected day's list under the page
    /// names everything a `+2` stands for.
    @ViewBuilder
    private func phoneTitles(_ cell: WeekLayout.Cell) -> some View {
        let capacity = metrics.titleCapacity(cell, height: height)
        let extra = cell.hiddenBars
        let needed = cell.titled.count + (extra > 0 ? 1 : 0)
        let shown = needed <= capacity ? cell.titled.count : max(0, capacity - 1)
        let more = cell.titled.count - shown + extra

        if metrics.drawsTitles(columnWidth: columnWidth) {
            VStack(alignment: .leading, spacing: MonthMetrics.gap) {
                ForEach(cell.titled.prefix(shown)) { event in
                    titledLine(event)
                        .frame(height: titleLine)
                }
                if more > 0, capacity > 0 {
                    Text(verbatim: "+\(more)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: titleLine)
                }
            }
        } else if !cell.titled.isEmpty {
            // Step one of the size-drop rule: the titles go, the colored rules stay, so a
            // one-off is still told apart from routine.
            HStack(spacing: 3) {
                ForEach(cell.titled.prefix(5)) { event in
                    rule(event.markColor)
                        .frame(height: titleLine - 2)
                }
            }
            .frame(height: titleLine)
        }
    }

    // MARK: Mac

    private var macRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(layout.cells) { cell in
                if cell.isShown {
                    macCell(cell)
                } else {
                    emptyCell
                }
            }
        }
        .overlay(alignment: .top) {
            lanes
                .padding(.top, numeralRow)
        }
    }

    private func macCell(_ cell: WeekLayout.Cell) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            numeral(cell.day)
                .padding(.top, 3)
                .padding(.leading, 2)
                .frame(height: numeralRow, alignment: .topLeading)
            Color.clear
                .frame(height: lanesHeight(cell))
            VStack(alignment: .leading, spacing: MonthMetrics.gap) {
                ForEach(cell.titled) { event in
                    eventButton(event) {
                        titledLine(event)
                    }
                    .frame(height: titleLine)
                }
            }
            .padding(.top, MonthMetrics.gap)
            // The dots keep to the bottom of the cell however tall the window makes the row,
            // and clear of the last titled line when the row is only as tall as its content.
            Spacer(minLength: MonthMetrics.gap)
            dots(cell.dotCount)
                .padding(.leading, 8)
                .padding(.top, 2)
                .frame(height: MonthMetrics.dotsRow, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if cell.day == selection {
                Rectangle().fill(.tint.opacity(0.09))
            }
        }
        .contentShape(.rect)
        .onTapGesture { onSelect(cell.day) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sentence(for: cell))
        .accessibilityAddTraits(cell.day == selection ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect(cell.day) }
    }

    /// A titled line or bar on the Mac: a click selects its day and opens its popover;
    /// a secondary click or touch and hold offers Join and Open in Google Calendar.
    private func eventButton(_ event: Event, @ViewBuilder label: () -> some View) -> some View {
        Button {
            onSelect(coveredDays(event, calendar: store.calendar).lowerBound)
            shownEvent = event.id
        } label: {
            label()
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: Binding(
                get: { shownEvent == event.id },
                set: { if !$0, shownEvent == event.id { shownEvent = nil } }),
            arrowEdge: .bottom
        ) {
            EventPopover(event: event)
                .calendarStore(store)
        }
        .contextMenu {
            EventMenuItems(event: event)
        }
    }

    // MARK: Shared parts

    /// A day of the neighbouring month: no numeral, no marks and nothing to tap, so the page
    /// reads as one month.
    private var emptyCell: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    /// The day's numeral, bold on a red circle for today: the only red in the grid. On the
    /// iPhone the selected day, when it is not today, gets a ring in the secondary color:
    /// color in the grid means a calendar, and today's red already marks it when selected.
    private func numeral(_ day: CivilDate) -> some View {
        let isToday = day == today
        let isRinged = !Platform.isMac && day == selection && !isToday
        return Text(verbatim: String(day.day))
            .font(Platform.isMac ? .body : .callout)
            .fontWeight(isToday ? .bold : .regular)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(isToday ? Color.white : Color.primary)
            .padding(.horizontal, Platform.isMac ? 6 : 4)
            .frame(minWidth: numeralCircle, minHeight: numeralCircle)
            .background {
                if isToday {
                    Capsule().fill(.red)
                } else if isRinged {
                    Capsule().strokeBorder(.secondary, lineWidth: 1.5)
                }
            }
    }

    private func lanesHeight(_ cell: WeekLayout.Cell) -> CGFloat {
        metrics.lanesHeight(cell)
    }

    /// Bars in fixed lanes at the top of the row, each spanning its days.
    private var lanes: some View {
        VStack(spacing: MonthMetrics.gap) {
            ForEach(0..<layout.laneCount, id: \.self) { lane in
                ColumnSpanLayout {
                    ForEach(layout.bars(inLane: lane)) { bar in
                        Group {
                            if Platform.isMac {
                                eventButton(bar.event) { barView(bar) }
                            } else {
                                barView(bar)
                            }
                        }
                        .layoutValue(key: ColumnSpan.self, value: bar.columns)
                    }
                }
                .frame(height: barHeight)
            }
        }
        .padding(.top, MonthMetrics.gap)
    }

    /// The event color at 20 percent with the title in the label color. Square where the
    /// span continues into the next or previous row, rounded where it starts or ends.
    private func barView(_ bar: WeekLayout.Bar) -> some View {
        let start: CGFloat = bar.continuesBefore ? 0 : 4
        let end: CGFloat = bar.continuesAfter ? 0 : 4
        let width = columnWidth * CGFloat(bar.columns.count)
        let showsTitle = columnWidth == 0 || width >= metrics.minBarTitleWidth
        return UnevenRoundedRectangle(
            topLeadingRadius: start, bottomLeadingRadius: start, bottomTrailingRadius: end,
            topTrailingRadius: end
        )
        .fill(bar.event.markColor.opacity(0.2))
        .overlay(alignment: .leading) {
            if showsTitle {
                Text(bar.event.title)
                    .font(Platform.isMac ? .caption : .caption2)
                    .foregroundStyle(bar.event.onHolidayCalendar ? .secondary : .primary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.leading, bar.continuesBefore ? 0 : (Platform.isMac ? 3 : 2))
        .padding(.trailing, bar.continuesAfter ? 0 : (Platform.isMac ? 3 : 2))
    }

    /// A 2 pt rule in the event color, then the title. The Mac puts the start time first.
    private func titledLine(_ event: Event) -> some View {
        HStack(spacing: Platform.isMac ? 4 : 3) {
            rule(event.markColor)
                .padding(.vertical, 1)
            if Platform.isMac {
                Text(verbatim: Formatting.time(event.time.start(in: store.calendar), calendar: store.calendar))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Text(event.title)
                .lineLimit(1)
        }
        .font(Platform.isMac ? .caption : .caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Platform.isMac ? 7 : 3)
        .padding(.trailing, Platform.isMac ? 4 : 2)
    }

    private func rule(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2)
    }

    /// Up to five gray dots: routine, never a calendar color.
    private func dots(_ count: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<min(count, 5), id: \.self) { _ in
                Circle()
                    .fill(.secondary)
                    .frame(width: MonthMetrics.dot, height: MonthMetrics.dot)
            }
        }
        .frame(maxWidth: .infinity, alignment: Platform.isMac ? .leading : .center)
    }

    /// One sentence per cell: "Thursday 26 November. Out of office. Investor call at 14:00.
    /// Three recurring."
    private func sentence(for cell: WeekLayout.Cell) -> String {
        let calendar = store.calendar
        var parts = [Formatting.dayHeader(cell.day, calendar: calendar)]
        parts += cell.barTitles
        parts += cell.titled.map { event in
            "\(event.title) at \(Formatting.time(event.time.start(in: calendar), calendar: calendar))"
        }
        if !cell.recurring.isEmpty {
            parts.append("\(Formatting.countCapitalized(cell.recurring.count)) recurring")
        }
        return parts.map { $0 + "." }.joined(separator: " ")
    }
}

/// Marks a cell as the source the Day zooms out of. Applied only when a namespace is given,
/// because the Mac has no push to zoom into.
private struct ZoomSource: ViewModifier {
    let id: CivilDate
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        #if os(iOS)
            if let namespace {
                content.matchedTransitionSource(id: id, in: namespace)
            } else {
                content
            }
        #else
            content
        #endif
    }
}

/// Which columns of the week a subview spans.
struct ColumnSpan: LayoutValueKey {
    static let defaultValue: ClosedRange<Int> = 0...0
}

/// Seven equal fractions of the width, each subview placed across the columns it spans.
/// Fractions rather than points, so resized iPhone windows and the Duo's outer display keep
/// a whole week on screen.
struct ColumnSpanLayout: Layout {
    var columns = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let column = width / CGFloat(columns)
        let height = subviews.map { subview in
            let span = subview[ColumnSpan.self]
            return subview.sizeThatFits(
                ProposedViewSize(width: column * CGFloat(span.count), height: proposal.height)
            ).height
        }.max() ?? 0
        return CGSize(width: width, height: proposal.height ?? height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let column = bounds.width / CGFloat(columns)
        for subview in subviews {
            let span = subview[ColumnSpan.self]
            subview.place(
                at: CGPoint(x: bounds.minX + column * CGFloat(span.lowerBound), y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: column * CGFloat(span.count), height: bounds.height))
        }
    }
}
