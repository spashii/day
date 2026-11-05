import Foundation

/// What the app hands the Lock Screen widget: `widget-snapshot.json` in the App Group
/// container. The widget builds every timeline from it with `widgetTimeline`, and in stage
/// two refreshes it itself. Two writers share the file, so a writer replaces it only when its
/// `fetchedAt` is newer; reading and writing the file is Sync's job.
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    public static let fileName = "widget-snapshot.json"

    /// When Google last answered for this data. Drives `As of 9:12` after 2 hours and
    /// `Open to update` after 24.
    public var fetchedAt: Date
    /// Accounts added in the app. Zero means `Add a Google account`.
    public var accountCount: Int
    /// Accounts that need signing in again: `1 account signed out` on line 3.
    public var signedOutAccounts: Int
    /// Merged events from visible calendars, today through the end of the seventh day
    /// ahead. The rules filter candidates themselves.
    public var events: [Event]

    public init(fetchedAt: Date, accountCount: Int, signedOutAccounts: Int, events: [Event]) {
        self.fetchedAt = fetchedAt
        self.accountCount = accountCount
        self.signedOutAccounts = signedOutAccounts
        self.events = events
    }
}
