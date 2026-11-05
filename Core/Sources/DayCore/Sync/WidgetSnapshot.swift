import Foundation

/// Reading and writing `widget-snapshot.json`. Two processes write it: the app after every
/// refresh, and the widget after its own incremental read on each timeline reload. A writer
/// replaces the file only when its data is at least as new as what is there, so a slow
/// widget read can never put older events over the app's.
extension WidgetSnapshot {
    /// Under this age the widget builds its timeline from the file without reading Google.
    /// Short, because an incremental read that finds nothing costs one small call per
    /// calendar; it only spares the reload the app asks for right after writing the file.
    public static let freshFor: TimeInterval = 60

    /// A file whose `fetchedAt` lies further than this in the future was written before the
    /// clock moved back. It loses to any writer, or a wrong clock would freeze the widget on
    /// it until the clock caught up.
    public static let clockTolerance: TimeInterval = 5 * 60

    /// The widget's age lines (`As of 9:12` after 2 hours, `Open to update` after 24) are
    /// timed from the `fetchedAt` it last read. Reloading when the data has moved on by this
    /// much keeps those lines away while the data is fresh, at one reload an hour at most
    /// when nothing else changed.
    public static let reanchorAfter: TimeInterval = 60 * 60

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

    /// Whether the widget should rebuild its timelines for this snapshot, given the one it
    /// last built them from: anything it shows changed, or the age it times its lines from
    /// moved by `reanchorAfter`. A refresh that found nothing new asks for no reload, so the
    /// widget's daily reload budget goes to real changes.
    public func needsReload(after loaded: WidgetSnapshot?) -> Bool {
        guard let loaded else { return true }
        if events != loaded.events || accountCount != loaded.accountCount
            || signedOutAccounts != loaded.signedOutAccounts
        {
            return true
        }
        return abs(fetchedAt.timeIntervalSince(loaded.fetchedAt)) >= WidgetSnapshot.reanchorAfter
    }

    /// The snapshot on disk, or nil when there is none or it cannot be read.
    public static func read(from cache: CacheDirectory) -> WidgetSnapshot? {
        cache.read(WidgetSnapshot.self, from: fileName)
    }

    /// Whether this snapshot may replace `current`. An equal `fetchedAt` is the same fetch
    /// seen again (after a calendar was hidden or an account removed), so it is written. A
    /// newer `current` wins unless it claims a fetch from the future.
    func replaces(_ current: WidgetSnapshot, now: Date) -> Bool {
        current.fetchedAt <= fetchedAt
            || current.fetchedAt > now.addingTimeInterval(WidgetSnapshot.clockTolerance)
    }

    /// Replaces the file unless the one there is newer, and returns whether it did. `force`
    /// skips the check, for changes the person made that must show even over newer data.
    ///
    /// The check and the write run inside one file coordination, which the app and the
    /// widget both take, so neither can slip a write between the other's read and replace.
    /// Coordination is held only for the read and the rename; it is not a file lock, so a
    /// process suspended right after cannot block the other or be killed for holding it.
    @discardableResult
    public func write(
        to cache: CacheDirectory, force: Bool = false, now: Date = Date()
    ) throws -> Bool {
        try FileManager.default.createDirectory(at: cache.url, withIntermediateDirectories: true)
        var result: Result<Bool, any Error> = .success(false)
        var coordination: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: cache.fileURL(WidgetSnapshot.fileName), options: .forReplacing,
            error: &coordination
        ) { _ in
            do {
                if !force, let current = WidgetSnapshot.read(from: cache),
                    !replaces(current, now: now)
                {
                    result = .success(false)
                    return
                }
                try cache.write(self, to: WidgetSnapshot.fileName)
                result = .success(true)
            } catch {
                result = .failure(error)
            }
        }
        if let coordination { throw coordination }
        return try result.get()
    }
}
