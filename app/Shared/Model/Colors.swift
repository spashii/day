import DayCore
import SwiftUI

// Core names a color; the app turns the name into a system color here and nowhere else, so
// light, dark, Increase Contrast and the glass slider all come from the system with no
// palette of our own.

extension ColorKey {
    /// The system color with this name.
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }
}

extension Event {
    /// The color of the event's bar fill and rule. Holiday calendars draw gray with no
    /// calendar color, so a public holiday never reads as one of his own events.
    var markColor: Color {
        id.calendar.isHoliday ? .gray : colorKey.color
    }

    /// Holiday calendars set their titles in the secondary color, in the month and the day.
    var onHolidayCalendar: Bool {
        id.calendar.isHoliday
    }
}

extension CalendarInfo {
    /// The mark beside the calendar's name in the accounts list and the event sheet.
    var markColor: Color {
        colorKey.color
    }
}
