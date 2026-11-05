import DayCore
import SwiftUI
import WidgetKit

/// The widget's content for the family it is placed in. No color anywhere: the Lock Screen
/// renders vibrant, so hierarchy comes from weight and from white against secondary gray.
/// The inline and circular families wear the symbol the person gave the next event's
/// calendar, when there is one; the rectangular family has no room for it.
struct NextWidgetView: View {
    let entry: NextEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        content
            // Required of every widget. The Lock Screen draws no background of its own, and
            // the circular family adds its `AccessoryWidgetBackground` inside its content.
            .containerBackground(.clear, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        let widget = entry.content
        switch family {
        case .accessoryInline:
            NextInlineView(
                text: widget.inline, showsEvent: widget.showsEvent,
                symbol: widget.showsEvent ? entry.symbol : nil
            )
            .widgetURL(widget.url)
        case .accessoryRectangular:
            NextRectangularView(lines: widget.rectangular, isLuminanceReduced: isLuminanceReduced)
                .widgetURL(widget.rectangular.url ?? widget.url)
        case .accessoryCircular:
            NextCircularView(
                content: widget.circular,
                symbol: widget.circular.isTime ? entry.symbol : nil
            )
            .widgetURL(widget.url)
        default:
            // Only the three Lock Screen families are supported, so nothing else is asked for.
            EmptyView()
        }
    }
}

extension CircularContent {
    /// A start time shows, as opposed to the `calendar` symbol that stands in when nothing
    /// is ahead. Only a start time belongs to an event, so only it can wear its calendar's
    /// symbol.
    var isTime: Bool {
        if case .time = self { return true }
        return false
    }
}

extension WidgetEntry {
    /// An event is on screen, as opposed to a state line such as `Add a Google account`.
    /// Only an event's words are private: the rectangular tap target is the event's own URL,
    /// so it is set exactly when an event shows.
    var showsEvent: Bool {
        rectangular.url != nil
    }
}

/// Above the clock. One `Text`, time first so the tail of the title is what truncates. The
/// system keeps the date on this line, so it is never repeated. When the next event's
/// calendar has a symbol, it leads the line, before the time. It is private with the title:
/// a symbol such as `cross.case` says what kind of event is coming.
struct NextInlineView: View {
    let text: String
    let showsEvent: Bool
    /// The next event's calendar symbol; nil for none.
    var symbol: NextSymbol? = nil

    var body: some View {
        if let symbol {
            Label {
                Text(verbatim: text)
            } icon: {
                Image(systemName: symbol.name)
                    .accessibilityLabel(Text(verbatim: symbol.label))
            }
            .privacySensitive(showsEvent)
        } else {
            Text(verbatim: text)
                .privacySensitive(showsEvent)
        }
    }
}

/// Below the clock: three separate one-line `Text` views in a `VStack`, because a single
/// `Text` in this family is cut to two lines on iOS 26. Line 1 is the headline and carries
/// the accent, lines 2 and 3 are the subheadline with tabular digits, and line 3 is
/// secondary gray, which the vibrant renderer draws as an opaque gray.
///
/// Under Always-On (`isLuminanceReduced`) line 3 goes and line 2 shows clock times only, so
/// no countdown can freeze into a wrong one.
struct NextRectangularView: View {
    let lines: RectangularLines
    let isLuminanceReduced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: lines.title)
                .font(.headline)
                // A state line (`Nothing in the next 7 days`) is wider than 160 pt and has
                // an empty line 2 below it, so it may take two lines; an event title
                // truncates at the tail on one.
                .lineLimit(showsEvent ? 1 : 2)
                .widgetAccentable()
                .privacySensitive(showsEvent)
            if let when = lines.when {
                whenText(when)
                    .font(.subheadline)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if !isLuminanceReduced, let after = lines.after {
                Text(verbatim: after)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .privacySensitive(lines.afterNamesEvent)
            }
        }
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsEvent: Bool {
        lines.url != nil
    }

    /// Line 2. Within the hour the relative part is the system's own self-updating text, so
    /// it counts down between timeline entries with no reload. `.reference(to:)` rather than
    /// `Text(date, style: .relative)`: the latter adds seconds (`in 20 min, 20 sec`) and
    /// overflows the 160 pt line, where `12:30 · in 20 minutes` fits. Tabular digits make
    /// every two-digit count as wide as that one, so it is the widest countdown.
    private func whenText(_ when: WhenLine) -> Text {
        if isLuminanceReduced {
            return Text(verbatim: when.reduced)
        }
        guard let start = when.relativeTo else {
            return Text(verbatim: when.text)
        }
        return Text("\(when.text) · \(Text(.currentDate, format: .reference(to: start)))")
    }
}

/// Below the clock, round: only a start time, as Apple's own circular Calendar widget shows
/// it. The next event's calendar symbol sits above the time when it has one, with `THU`
/// beside it when the event is not today, and the period below in 12-hour locales. The
/// generic `calendar` symbol stands in when there is nothing to name, so the slot does not
/// look broken. No ring, no title, no color.
struct NextCircularView: View {
    let content: CircularContent
    /// The next event's calendar symbol; nil for none. Ignored when there is no start time
    /// to put it above.
    var symbol: NextSymbol? = nil

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            switch content {
            case .time(let time, let weekday, let period):
                VStack(spacing: 0) {
                    if symbol != nil || weekday != nil {
                        HStack(spacing: 2) {
                            if let symbol {
                                Image(systemName: symbol.name)
                                    .font(.footnote)
                                    .accessibilityLabel(Text(verbatim: symbol.label))
                                    .privacySensitive()
                            }
                            if let weekday {
                                Text(verbatim: weekday)
                                    .font(.caption2)
                                    .textCase(.uppercase)
                            }
                        }
                        .minimumScaleFactor(0.8)
                    }
                    Text(verbatim: time)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                    if let period {
                        Text(verbatim: period)
                            .font(.caption2)
                    }
                }
                .lineLimit(1)
            case .symbol:
                Image(systemName: "calendar")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
// The symbol in the two families that wear it: the circular one with the event today, on
// another day, and in a 12-hour locale where the period sits below the time, and the inline
// line. The timeline previews in NextPreviews.swift build entries without symbols, so these
// draw the views directly.
#Preview("Symbol, inline and circular", traits: .fixedLayout(width: 260, height: 120)) {
    VStack(alignment: .leading, spacing: 8) {
        NextInlineView(
            text: "14:00 Investor call", showsEvent: true,
            symbol: NextSymbol(name: "briefcase", label: "Work"))
            .frame(width: 234, height: 26, alignment: .leading)
        HStack(spacing: 8) {
            NextCircularView(
                content: .time("14:00", weekday: nil, period: nil),
                symbol: NextSymbol(name: "briefcase", label: "Work")
            )
            .frame(width: 72, height: 72)
            NextCircularView(
                content: .time("9:30", weekday: "Thu", period: nil),
                symbol: NextSymbol(name: "cross.case", label: "Health")
            )
            .frame(width: 72, height: 72)
            NextCircularView(
                content: .time("2:00", weekday: "Thu", period: "PM"),
                symbol: NextSymbol(name: "figure.run", label: "Running")
            )
            .frame(width: 72, height: 72)
        }
    }
    .padding(8)
}
#endif
