import DayCore
import SwiftUI
import WidgetKit

/// The Lock Screen widget "Next": the next event from every Google calendar, in the three
/// Lock Screen families. One kind, so one entry in the gallery and one reload budget.
@main
struct NextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DayIdentifiers.widgetKind, provider: NextProvider()) { entry in
            NextWidgetView(entry: entry)
        }
        .configurationDisplayName("Next")
        .description("Your next event, from every Google calendar.")
        .supportedFamilies([.accessoryInline, .accessoryRectangular, .accessoryCircular])
        .pushHandler(DayWidgetPushHandler.self)
    }
}
