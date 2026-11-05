import DayCore
import Foundation

/// What one week row of the month draws, worked out from the week's events before any view
/// exists: which bars sit in which lane, and per day the titled lines and the dots.
struct WeekLayout {
    /// A bar's piece inside this week row. A bar that continues into the next or previous
    /// row has a square end there; its title is drawn once per row.
    struct Bar: Identifiable {
        let event: Event
        /// Columns 0 to 6, inclusive.
        let columns: ClosedRange<Int>
        let lane: Int
        let continuesBefore: Bool
        let continuesAfter: Bool

        var id: EventID { event.id }
    }

    struct Cell: Identifiable {
        let day: CivilDate
        /// Titled one-offs starting this day, by start time.
        var titled: [Event] = []
        /// Recurring events: one gray dot each.
        var recurring: [Event] = []
        /// Short internal one-offs (month rule 5): also gray dots.
        var shortOneOffs: [Event] = []
        /// Titles of the bars covering this day, drawn or not, for VoiceOver.
        var barTitles: [String] = []
        /// Bars covering this day that found no lane. The iPhone counts them into `+2`.
        var hiddenBars = 0
        /// Lanes this day's titled lines must clear: one past the lowest bar over this day.
        /// A day under one bar keeps the room a second lane takes elsewhere in the week.
        var lanesUsed = 0

        var id: CivilDate { day }
        var dotCount: Int { recurring.count + shortOneOffs.count }
    }

    let start: CivilDate
    private(set) var cells: [Cell]
    private(set) var bars: [Bar] = []
    private(set) var laneCount = 0

    /// - Parameters:
    ///   - events: merged events overlapping the week, from visible calendars.
    ///   - maxLanes: bar lanes the row may use: two on iPhone; nil on the Mac, where rows
    ///     grow so nothing hides.
    ///   - mark: the month mark of an event (`CalendarStore.monthMark`).
    init(
        start: CivilDate, events: [Event], calendar: Calendar, maxLanes: Int?,
        mark: (Event) -> MonthMark
    ) {
        self.start = start
        let end = start.adding(days: 6)
        var cells = (0..<7).map { Cell(day: start.adding(days: $0)) }
        var pending: [(event: Event, covered: ClosedRange<CivilDate>, columns: ClosedRange<Int>)] = []

        for event in events {
            let kind = mark(event)
            if kind == .hidden { continue }
            let covered = coveredDays(event, calendar: calendar)
            if kind == .bar {
                let first = max(covered.lowerBound, start)
                let last = min(covered.upperBound, end)
                guard first <= last else { continue }
                pending.append((event, covered, start.distance(to: first)...start.distance(to: last)))
                continue
            }
            let column = start.distance(to: covered.lowerBound)
            guard (0..<7).contains(column) else { continue }
            switch kind {
            case .titled:
                cells[column].titled.append(event)
            case .dot where event.isRecurring:
                cells[column].recurring.append(event)
            default:
                cells[column].shortOneOffs.append(event)
            }
        }

        for i in cells.indices {
            cells[i].titled.sort { $0.time.start(in: calendar) < $1.time.start(in: calendar) }
        }

        // Earliest first, then the longest, so a long bar takes the top lane and keeps it.
        pending.sort { a, b in
            if a.columns.lowerBound != b.columns.lowerBound {
                return a.columns.lowerBound < b.columns.lowerBound
            }
            if a.columns.count != b.columns.count { return a.columns.count > b.columns.count }
            return a.event.title < b.event.title
        }
        var laneEnds: [Int] = []
        var bars: [Bar] = []
        for item in pending {
            for column in item.columns {
                cells[column].barTitles.append(item.event.title)
            }
            var lane = laneEnds.firstIndex { $0 < item.columns.lowerBound }
            if lane == nil, maxLanes.map({ laneEnds.count < $0 }) ?? true {
                laneEnds.append(-1)
                lane = laneEnds.count - 1
            }
            guard let lane else {
                for column in item.columns { cells[column].hiddenBars += 1 }
                continue
            }
            laneEnds[lane] = item.columns.upperBound
            for column in item.columns {
                cells[column].lanesUsed = max(cells[column].lanesUsed, lane + 1)
            }
            bars.append(
                Bar(
                    event: item.event, columns: item.columns, lane: lane,
                    continuesBefore: item.covered.lowerBound < start,
                    continuesAfter: item.covered.upperBound > end))
        }

        self.cells = cells
        self.bars = bars
        laneCount = laneEnds.count
    }

    /// Bars in one lane, left to right.
    func bars(inLane lane: Int) -> [Bar] {
        bars.filter { $0.lane == lane }
    }
}
