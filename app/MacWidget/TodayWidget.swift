import SwiftUI
import WidgetKit

/// The Mac's desktop widget "Today": today's events from every Google calendar, in the small,
/// medium and large families. Read-only; a click opens Day on the day it shows. One kind, so
/// one entry in the gallery and one reload budget.
@main
struct TodayWidget: Widget {
    /// The widget's kind. Not shown anywhere; the gallery shows the display name.
    static let kind = "Today"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today's events from all your Google calendars.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
