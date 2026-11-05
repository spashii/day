import DayCore
import Foundation
import Observation

/// Which month is on screen. The month is one page per month with only its own weeks: the
/// iPhone pages sideways between months, the Mac moves with its toolbar, menus and keys. The
/// parent owns it, so the iPhone title, the Mac toolbar and the Mac menu commands read and
/// move the same page.
@MainActor
@Observable
final class MonthScroll {
    /// The first day of the month on screen. Nil until something moves it; the month then
    /// opens on today's, and follows today into the next month at midnight.
    private(set) var page: CivilDate?

    /// The months the iPhone pager holds, as offsets from the current month. A jump outside
    /// widens them, so Go to Date reaches any year.
    private(set) var monthsBefore = 24
    private(set) var monthsAfter = 60

    init() {}

    /// The first day of the month on screen.
    func shown(today: CivilDate) -> CivilDate {
        page ?? MonthScroll.firstOfMonth(today)
    }

    /// The month on screen.
    func month(today: CivilDate, calendar: Calendar) -> (year: Int, month: Int) {
        let first = shown(today: today)
        return (first.year, first.month)
    }

    /// Every month the iPhone pager holds, as the first day of each, oldest first.
    func months(today: CivilDate) -> [CivilDate] {
        let current = MonthScroll.firstOfMonth(today)
        return (-monthsBefore...monthsAfter).map { MonthScroll.month(current, offset: $0) }
    }

    /// Turns to the month holding `day`.
    func show(_ day: CivilDate, today: CivilDate, calendar: Calendar) {
        let first = MonthScroll.firstOfMonth(day)
        let offset = MonthScroll.months(from: MonthScroll.firstOfMonth(today), to: first)
        monthsBefore = max(monthsBefore, -offset + 2)
        monthsAfter = max(monthsAfter, offset + 2)
        turn(to: first, calendar: calendar)
    }

    /// Turns by `months` from the month on screen: the Mac's previous and next month.
    func showMonth(offset months: Int, today: CivilDate, calendar: Calendar) {
        show(MonthScroll.month(shown(today: today), offset: months), today: today, calendar: calendar)
    }

    /// Puts the page whose first day is `first` on screen. The iPhone pager calls it as the
    /// page settles; everything else goes through `show`.
    func turn(to first: CivilDate, calendar: Calendar) {
        if page != first { page = first }
    }

    /// The day the date picker opens on: today when today sits in the shown month, else the
    /// first of it, so the picker shows the month in the title that was tapped.
    func goToDateStart(today: CivilDate, calendar: Calendar) -> CivilDate {
        let first = shown(today: today)
        return MonthScroll.firstOfMonth(today) == first ? today : first
    }

    /// `November`, `January 2027` outside the current year, or always with the year for the
    /// Mac toolbar: `November 2026`.
    func title(today: CivilDate, now: Date, calendar: Calendar, alwaysYear: Bool = false) -> String {
        let shown = month(today: today, calendar: calendar)
        return Formatting.monthTitle(
            year: shown.year, month: shown.month, now: now, calendar: calendar,
            alwaysYear: alwaysYear)
    }

    // MARK: Month arithmetic

    /// The first day of the week holding `day`, where the locale starts weeks.
    static func weekStart(of day: CivilDate, calendar: Calendar) -> CivilDate {
        day.adding(days: -((day.weekday - calendar.firstWeekday + 7) % 7))
    }

    static func firstOfMonth(_ day: CivilDate) -> CivilDate {
        CivilDate(year: day.year, month: day.month, day: 1)
    }

    /// The first day of the month `offset` months from the one starting on `first`.
    static func month(_ first: CivilDate, offset: Int) -> CivilDate {
        let index = first.year * 12 + (first.month - 1) + offset
        return CivilDate(year: index / 12, month: index % 12 + 1, day: 1)
    }

    static func months(from a: CivilDate, to b: CivilDate) -> Int {
        (b.year * 12 + b.month) - (a.year * 12 + a.month)
    }

    /// Every day of the month starting on `first`.
    static func days(of first: CivilDate) -> ClosedRange<CivilDate> {
        first...month(first, offset: 1).adding(days: -1)
    }

    /// The month's own week rows: four to six, the first holding its first day and the last
    /// its last day. No trailing weeks of the next month.
    static func weeks(of first: CivilDate, calendar: Calendar) -> [CivilDate] {
        let days = days(of: first)
        return Array(
            stride(
                from: weekStart(of: days.lowerBound, calendar: calendar),
                through: days.upperBound,
                by: 7))
    }
}
