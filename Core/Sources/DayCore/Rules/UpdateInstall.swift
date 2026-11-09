import Foundation

/// One of the Mac app's own windows, as the update rule sees it. The menu bar item itself
/// is not one: it is always on screen, so the caller leaves it out.
public struct AppWindow: Hashable, Sendable {
    public var isKey: Bool
    /// On screen where the person can see it, not merely ordered in.
    public var isVisible: Bool

    public init(isKey: Bool, isVisible: Bool) {
        self.isKey = isKey
        self.isVisible = isVisible
    }
}

/// How far either side of an event's start the Mac app never relaunches for an update.
public let updateQuietMargin: TimeInterval = 2 * 60

/// Whether the Mac app may quit and relaunch now to install an update Sparkle has already
/// downloaded. A menu bar app is almost never quit, so an update that waits for a quit can
/// wait for weeks; this is the moment to install it instead.
///
/// It is idle when Day is not the active app, none of its windows (the menu bar panel
/// included) is key or visible, and no event from `next` starts within `updateQuietMargin`
/// of now, before or after. So the relaunch never takes Day away while someone looks at it,
/// and never lands just before or at the start of a meeting, when its Join and reminder
/// matter most. An event that started longer ago is under way and does not hold it back.
/// `next` is the same `nextEvents` the menu bar label reads.
public func isIdleForUpdate(
    appIsActive: Bool, windows: [AppWindow], next: NextEvents, now: Date
) -> Bool {
    if appIsActive || windows.contains(where: { $0.isKey || $0.isVisible }) {
        return false
    }
    let starts = [next.current, next.next].compactMap { event -> Date? in
        guard case .timed(let start, _, _) = event?.time else { return nil }
        return start
    }
    return !starts.contains { abs($0.timeIntervalSince(now)) <= updateQuietMargin }
}
