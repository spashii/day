import Foundation

/// Reading and writing `widget-snapshot.json`. Two processes write it: the app after every
/// fetch, and in stage two the widget after its own. A writer replaces the file only when its
/// data is at least as new as what is there, so a slow widget fetch can never put older
/// events over the app's.
extension WidgetSnapshot {
    /// Under this age the widget builds its timeline from the file without fetching.
    public static let freshFor: TimeInterval = 15 * 60

    /// The days a snapshot holds: today through eight days ahead. The rules look seven days
    /// past each timeline entry, and the timeline runs up to a day ahead of the fetch.
    public static func days(from today: CivilDate) -> ClosedRange<CivilDate> {
        today...today.adding(days: 8)
    }

    /// Fetched less than `maxAge` ago. A `fetchedAt` in the future (the clock moved back)
    /// counts as stale, so a wrong clock costs a fetch rather than a frozen widget.
    public func isFresh(at now: Date, maxAge: TimeInterval = WidgetSnapshot.freshFor) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < maxAge
    }

    /// The snapshot on disk, or nil when there is none or it cannot be read.
    public static func read(from cache: CacheDirectory) -> WidgetSnapshot? {
        cache.read(WidgetSnapshot.self, from: fileName)
    }

    /// Replaces the file unless the one there was fetched later. An equal `fetchedAt` is the
    /// same fetch seen again, after a calendar was hidden or an account removed, so it is
    /// written. `force` skips the check, for changes the person made that must show even
    /// over newer data. Returns whether the file was written.
    @discardableResult
    public func write(to cache: CacheDirectory, force: Bool = false) throws -> Bool {
        if !force, let current = WidgetSnapshot.read(from: cache), current.fetchedAt > fetchedAt {
            return false
        }
        try cache.write(self, to: WidgetSnapshot.fileName)
        return true
    }
}
