import Foundation
import Synchronization

/// Google's `updated` time for each change a sync applied, which is where every latency is
/// counted from.
///
/// The sync itself does not ask for `updated`: its fields mask carries only what the views
/// draw. So after a sync that changed something, each changed calendar is read once more
/// from the token it had before the sync, with a mask of only `id` and `updated`. A sync token
/// can be read from more than once (the widget's own read does the same), so this changes
/// nothing for the next sync. It costs one small request per changed calendar, and none when
/// nothing changed. Changes Google does not list from that token (a window that moved, a
/// calendar read in full) are not changes anyone made, and are left out of the log.
struct LatencyProbe: Sendable {
    static let fields = "nextPageToken,items(id,updated)"

    let auth: GoogleAuth
    let tokens: any TokenStore
    let api: CalendarAPI
    let clock: @Sendable () -> Date

    init(engine: SyncEngine, auth: GoogleAuth) {
        self.auth = auth.with(retry: .once)
        tokens = engine.tokens
        api = engine.api.with(retry: .once)
        clock = engine.clock
    }

    /// The `updated` time of each candidate Google lists, within `limit`; whatever has not
    /// answered by then is left out.
    func updated(_ candidates: [LatencyCandidate], limit: Duration) async -> [EventID: Date] {
        var asks: [CalendarID: String] = [:]
        for candidate in candidates { asks[candidate.event.calendar] = candidate.token }
        let wanted = Set(candidates.map(\.event))
        let found = Found()
        _ = try? await SyncEngine.withDeadline(limit) { [asks] in
            await read(asks, into: found)
        }
        return found.times.withLock { $0 }.filter { wanted.contains($0.key) }
    }

    /// Answers as they arrive, so a deadline keeps the calendars that did answer.
    private final class Found: Sendable {
        let times = Mutex<[EventID: Date]>([:])
    }

    private func read(_ asks: [CalendarID: String], into found: Found) async {
        let api = api
        await withTaskGroup(of: Void.self) { group in
            for (account, calendars) in Dictionary(grouping: asks.keys, by: \.account) {
                guard let stored = try? tokens.token(for: account) else { continue }
                let authorizer = AccountAuthorizer(
                    account: account, token: stored, auth: auth, tokens: tokens, clock: clock)
                for calendar in calendars {
                    guard let token = asks[calendar] else { continue }
                    group.addTask {
                        guard
                            let items = try? await authorizer.authorized({ access in
                                try await Self.items(
                                    calendar, token: token, accessToken: access, api: api)
                            })
                        else { return }
                        found.times.withLock { found in
                            for item in items {
                                guard let text = item.updated, let date = Self.date(text) else {
                                    continue
                                }
                                found[EventID(calendar: calendar, googleID: item.id)] = date
                            }
                        }
                    }
                }
            }
        }
    }

    struct Item: Decodable, Sendable {
        var id: String
        var updated: String?
    }

    /// The first page is enough: a change set of more than 2500 events is a full read in
    /// disguise, not a change to time.
    static func items(
        _ calendar: CalendarID, token: String, accessToken: String, api: CalendarAPI
    ) async throws -> [Item] {
        let request = api.eventsRequest(
            calendarID: calendar.googleID, query: .changes(since: token), pageToken: nil,
            accessToken: accessToken, fields: fields)
        let (data, response) = try await GoogleHTTP.send(request, using: api.transport, retry: api.retry)
        switch response.statusCode {
        case 200..<300:
            return (try? JSONDecoder().decode(GooglePage<Item>.self, from: data))?.items ?? []
        case 401:
            throw CalendarAPIError.unauthorized
        default:
            throw CalendarAPIError.http(status: response.statusCode, reason: nil)
        }
    }

    /// RFC 3339 as Google writes `updated`, with milliseconds.
    static func date(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: .iso8601)
    }
}

/// What the app calls after each sync: finds the changes the sync applied, asks Google when
/// each was made, and logs them (`LatencyLog`). Off the main thread, and best effort: a probe
/// that fails or runs out of time only leaves those changes out of the log.
public struct LatencyRecorder: Sendable {
    public let log: LatencyLog
    let probe: LatencyProbe?

    /// `directory` is where the log lives, which on the Mac is the App Group the desktop
    /// widget also writes to; the probe uses the engine's own Google client and tokens.
    public init(directory: CacheDirectory, engine: SyncEngine) {
        log = LatencyLog(directory: directory)
        probe = engine.auth.map { LatencyProbe(engine: engine, auth: $0) }
    }

    /// `appShown` gives the moment the Mac app drew the new data; nil on the iPhone, whose
    /// app is not one of the timed surfaces.
    ///
    /// `receivingSince` is the last moment this process could receive a push: on the Mac the
    /// later of launch and the last wake (and network return), on the iPhone the launch. A
    /// change Google stamped earlier was made while the process could not hear about it, so
    /// the sync that finds it is a catch-up, not the push path, and timing it would measure
    /// how long the Mac slept or the app was closed. Such changes are left out of the log.
    public func syncFinished(
        from before: CalendarData, to after: CalendarData, at synced: Date, pushes: [Date],
        limit: Duration = .seconds(4), appShown: (@Sendable () async -> Date)? = nil,
        receivingSince: Date? = nil
    ) async {
        let candidates = LatencyDiff.candidates(from: before, to: after)
        guard !candidates.isEmpty, let probe else { return }
        let shown = await appShown?()
        let updated = await probe.updated(candidates, limit: limit)
        let changes = candidates.compactMap { candidate -> LatencyChange? in
            guard let time = updated[candidate.event] else { return nil }
            if let receivingSince, time < receivingSince { return nil }
            return LatencyChange(key: candidate.key, after: candidate.after, updated: time)
        }
        log.recordSync(changes, synced: synced, pushes: pushes, appShown: shown)
    }
}
