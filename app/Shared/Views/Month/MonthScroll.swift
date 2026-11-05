import DayCore
import Foundation
import Observation

/// Where the month is scrolled and which month it shows. The parent owns it, so the iPhone
/// title, the Mac toolbar and the Mac menu commands can read and move the same scroll.
@MainActor
@Observable
final class MonthScroll {
    /// The first day of the week row at the top. Nil until something moves the scroll; the
    /// month then opens with the current week as the top row.
    var topWeek: CivilDate?
    /// Week rows at least half on screen, top to bottom.
    var visibleWeeks: [CivilDate] = []

    /// The rows the scroll holds, as offsets in weeks from the current week. A jump outside
    /// widens them, so Go to Date reaches any year.
    private(set) var weeksBefore = 52
    private(set) var weeksAfter = 104

    init() {}

    /// Every week row, top to bottom.
    func weeks(today: CivilDate, calendar: Calendar) -> [CivilDate] {
        let current = MonthScroll.weekStart(of: today, calendar: calendar)
        return Array(
            stride(
                from: current.adding(days: -7 * weeksBefore),
                through: current.adding(days: 7 * weeksAfter),
                by: 7))
    }

    /// Puts the week holding `day` at the top.
    func show(_ day: CivilDate, today: CivilDate, calendar: Calendar) {
        let week = MonthScroll.weekStart(of: day, calendar: calendar)
        let current = MonthScroll.weekStart(of: today, calendar: calendar)
        let offset = current.distance(to: week) / 7
        weeksBefore = max(weeksBefore, -offset + 8)
        weeksAfter = max(weeksAfter, offset + 8)
        topWeek = week
    }

    /// Puts the week holding the first of the shown month, moved by `months`, at the top:
    /// the Mac's previous and next month.
    func showMonth(offset months: Int, today: CivilDate, calendar: Calendar) {
        let shown = month(today: today, calendar: calendar)
        let index = shown.year * 12 + (shown.month - 1) + months
        let first = CivilDate(year: index / 12, month: index % 12 + 1, day: 1)
        show(first, today: today, calendar: calendar)
    }

    /// The month holding most of the visible days; on a tie the earlier one, which is the
    /// one the top rows belong to.
    func month(today: CivilDate, calendar: Calendar) -> (year: Int, month: Int) {
        var weeks = visibleWeeks
        if weeks.isEmpty {
            let top = topWeek ?? MonthScroll.weekStart(of: today, calendar: calendar)
            weeks = (0..<6).map { top.adding(days: 7 * $0) }
        }
        var counts: [Int: Int] = [:]
        for week in weeks {
            for offset in 0..<7 {
                let day = week.adding(days: offset)
                counts[day.year * 12 + day.month - 1, default: 0] += 1
            }
        }
        let best = counts.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }!.key
        return (best / 12, best % 12 + 1)
    }

    /// The day the date picker opens on: today when today sits in the shown month, else the
    /// first of it. The picker then always shows the month in the title that was tapped,
    /// wherever the top row is.
    func goToDateStart(today: CivilDate, calendar: Calendar) -> CivilDate {
        let shown = month(today: today, calendar: calendar)
        if today.year == shown.year && today.month == shown.month {
            return today
        }
        return CivilDate(year: shown.year, month: shown.month, day: 1)
    }

    /// `November`, `January 2027` outside the current year, or always with the year for the
    /// Mac toolbar: `November 2026`.
    func title(today: CivilDate, now: Date, calendar: Calendar, alwaysYear: Bool = false) -> String {
        let shown = month(today: today, calendar: calendar)
        return Formatting.monthTitle(
            year: shown.year, month: shown.month, now: now, calendar: calendar,
            alwaysYear: alwaysYear)
    }

    /// The first day of the week holding `day`, where the locale starts weeks.
    static func weekStart(of day: CivilDate, calendar: Calendar) -> CivilDate {
        day.adding(days: -((day.weekday - calendar.firstWeekday + 7) % 7))
    }
}
