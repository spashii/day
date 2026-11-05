import Foundation

/// How hard a notification asks for attention. Everything is `active` except the one at the
/// start of a call, which breaks through a Focus when the person allows it.
public enum ReminderLevel: String, Hashable, Sendable {
    case active
    case timeSensitive
}

/// Which notification of an event this is.
public enum ReminderKind: Hashable, Sendable {
    /// One of Google's reminders, this many minutes before the start. For an all-day event
    /// the minutes count back from midnight at the start of its first day.
    case lead(minutes: Int)
    /// The extra notification of a call, at its start.
    case start
}

/// One local notification Day wants pending, fully worked out: when it fires, what it says
/// and what its actions do. `ReminderSchedule.plan` makes them from the cache alone, and the
/// app turns each into a `UNNotificationRequest`.
public struct PlannedReminder: Hashable, Sendable {
    /// Stable for the event and the kind, never for the time: an event that moves keeps the
    /// identifier of its reminder and changes its `signature`, which is how the diff against
    /// the pending requests finds it without removing and adding everything.
    public var identifier: String
    /// The notifications of one event share this, so the system groups them.
    public var thread: String
    public var event: EventID
    public var kind: ReminderKind
    public var fireDate: Date
    public var title: String
    public var body: String
    public var level: ReminderLevel
    /// The event's meeting link. When set, the notification has a `Join` action that opens it.
    public var joinURL: URL?
    /// The address of the account the event sits on, which the Mac adds to Google links so
    /// the right account opens.
    public var accountEmail: String?
    /// `day://event/...`, what tapping the notification opens.
    public var link: URL
    /// A fingerprint of everything that decides what the person sees and when. A pending
    /// request whose signature differs from the plan's is replaced.
    public var signature: String
}

/// A pending request as the diff sees it: its identifier and the signature it was added with.
public struct PendingReminder: Hashable, Sendable {
    public var identifier: String
    public var signature: String?

    public init(identifier: String, signature: String?) {
        self.identifier = identifier
        self.signature = signature
    }
}

/// What to do to the pending requests to make them match a plan.
public struct ReminderChanges: Hashable, Sendable {
    /// New or changed, earliest first. Adding under an existing identifier replaces it.
    public var add: [PlannedReminder]
    /// Identifiers of Day's reminders that are no longer wanted.
    public var remove: [String]

    public var isEmpty: Bool {
        add.isEmpty && remove.isEmpty
    }
}
