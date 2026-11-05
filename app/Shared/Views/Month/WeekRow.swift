import DayCore
import SwiftUI

/// One week of the month: seven equal columns, a hairline above, the numerals, the bar
/// lanes, the titled lines and the dots. The iPhone row has one fixed height so the grid
/// reads as a grid; the Mac row grows until nothing hides.
struct WeekRow: View {
    @EnvironmentStore private var store
    @Environment(\.handoff) private var handoff

    let layout: WeekLayout
    let today: CivilDate
    /// One column's width, which decides what the size-drop rule keeps.
    let columnWidth: CGFloat
    /// The Mac's selected day, tinted.
    var selection: CivilDate?
    /// The iPhone's zoom source for the Day pushed from a cell.
    var zoom: Namespace.ID?
    let onSelect: (CivilDate) -> Void

    // Sizes from the mockup at the default text size, scaled with it up to the grid's cap.
    @ScaledMetric(relativeTo: .caption2) private var rowHeight: CGFloat = Metrics.rowHeight
    @ScaledMetric(relativeTo: .callout) private var numeralRow: CGFloat = Metrics.numeralRow
    @ScaledMetric(relativeTo: .callout) private var numeralCircle: CGFloat = Metrics.numeralCircle
    @ScaledMetric(relativeTo: .caption2) private var barHeight: CGFloat = Metrics.barHeight
    @ScaledMetric(relativeTo: .caption2) private var titleLine: CGFloat = Metrics.titleLine
    /// Narrower than this and one-off titles drop to their colored rules (step one).
    @ScaledMetric(relativeTo: .caption2) private var minTitledWidth: CGFloat = 40
    /// Narrower than this and a bar keeps its fill but drops its title (step two).
    @ScaledMetric(relativeTo: .caption2) private var minBarTitleWidth: CGFloat = 28

    /// The Mac event whose popover is open.
    @State private var shownEvent: EventID?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if Platform.isMac {
                macRow
            } else {
                phoneRow
            }
        }
    }

    // MARK: iPhone

    private var phoneRow: some View {
        HStack(spacing: 0) {
            ForEach(layout.cells) { cell in
                Button {
                    onSelect(cell.day)
                } label: {
                    phoneCell(cell)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(sentence(for: cell))
                .modifier(ZoomSource(id: cell.day, namespace: zoom))
            }
        }
        .frame(height: rowHeight)
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
                .padding(.top, Metrics.gap)
            Spacer(minLength: 0)
            dots(cell.dotCount)
                .frame(height: Metrics.dotsRow, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
    }

    /// As many titled lines as the fixed row has room for; when they do not all fit, the
    /// last line becomes `+2`. Hidden bars count into it.
    @ViewBuilder
    private func phoneTitles(_ cell: WeekLayout.Cell) -> some View {
        let room = rowHeight - numeralRow - lanesHeight(cell) - Metrics.dotsRow - Metrics.gap
        let capacity = max(0, Int((room + Metrics.gap) / (titleLine + Metrics.gap)))
        let extra = cell.hiddenBars
        let needed = cell.titled.count + (extra > 0 ? 1 : 0)
        let shown = needed <= capacity ? cell.titled.count : max(0, capacity - 1)
        let more = cell.titled.count - shown + extra

        if columnWidth >= minTitledWidth || columnWidth == 0 {
            VStack(alignment: .leading, spacing: Metrics.gap) {
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
                macCell(cell)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
            VStack(alignment: .leading, spacing: Metrics.gap) {
                ForEach(cell.titled) { event in
                    eventButton(event) {
                        titledLine(event)
                    }
                    .frame(height: titleLine)
                }
            }
            .padding(.top, Metrics.gap)
            dots(cell.dotCount)
                .padding(.leading, 8)
                .padding(.top, 2)
                .frame(height: Metrics.dotsRow, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if cell.day == selection {
                Rectangle().fill(.tint.opacity(0.09))
            }
        }
        .contentShape(.rect)
        .onTapGesture { onSelect(cell.day) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sentence(for: cell))
        .accessibilityAddTraits(.isButton)
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

    /// The day's numeral, `1 Dec` on the first of a month, bold on a red circle for today:
    /// the only red in the grid.
    private func numeral(_ day: CivilDate) -> some View {
        let isToday = day == today
        let label = day.day == 1 ? Formatting.firstOfMonth(day, calendar: store.calendar) : String(day.day)
        return Text(verbatim: label)
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
                }
            }
    }

    /// The room the bars over a day take, so its titled lines start right under them.
    private func lanesHeight(_ cell: WeekLayout.Cell) -> CGFloat {
        CGFloat(cell.lanesUsed) * (barHeight + Metrics.gap)
    }

    /// Bars in fixed lanes at the top of the row, each spanning its days.
    private var lanes: some View {
        VStack(spacing: Metrics.gap) {
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
        .padding(.top, Metrics.gap)
    }

    /// The event color at 20 percent with the title in the label color. Square where the
    /// span continues into the next or previous row, rounded where it starts or ends.
    private func barView(_ bar: WeekLayout.Bar) -> some View {
        let start: CGFloat = bar.continuesBefore ? 0 : 4
        let end: CGFloat = bar.continuesAfter ? 0 : 4
        let width = columnWidth * CGFloat(bar.columns.count)
        let showsTitle = columnWidth == 0 || width >= minBarTitleWidth
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
                    .frame(width: Metrics.dot, height: Metrics.dot)
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

    private enum Metrics {
        #if os(macOS)
            static let rowHeight: CGFloat = 98
            static let numeralRow: CGFloat = 27
            static let numeralCircle: CGFloat = 22
            static let barHeight: CGFloat = 15
            static let titleLine: CGFloat = 13
            static let dotsRow: CGFloat = 14
            static let dot: CGFloat = 4.5
            /// Between bar lanes and between titled lines.
            static let gap: CGFloat = 2
        #else
            static let rowHeight: CGFloat = 96
            static let numeralRow: CGFloat = 34
            static let numeralCircle: CGFloat = 30
            static let barHeight: CGFloat = 16
            static let titleLine: CGFloat = 13
            static let dotsRow: CGFloat = 14
            static let dot: CGFloat = 5
            /// Between bar lanes and between titled lines: one point, so a day under one bar
            /// still has two titled lines in the 96 pt row, and a day under two bars one.
            static let gap: CGFloat = 1
        #endif
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
