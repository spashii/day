import Foundation

/// The three read-only Calendar API v3 calls Day makes: `calendarList.list`, `calendars.get`
/// (for event labels) and `events.list`. Each takes an access token and returns Google's
/// shapes from `GoogleTypes.swift`; `GoogleDecoding` turns those into the model.
///
/// Both lists sync incrementally, as Google's guide describes
/// (developers.google.com/workspace/calendar/api/guides/sync): a full read whose last page
/// carries `nextSyncToken`, then reads with `syncToken` that return only what changed,
/// deleted and cancelled items included. Google refuses `timeMin`, `timeMax` and `orderBy`
/// beside a sync token and asks every other parameter to stay the same as in the full read,
/// so the two kinds of request differ only in the window and the token.
public struct CalendarAPI: Sendable {
    public static let base = URL(string: "https://www.googleapis.com/calendar/v3")!

    /// Only the event fields the views use, which keeps the widget's fetch small.
    /// `eventLabelId` is how labelled events name their label. `nextSyncToken` must be in
    /// the mask, or Google leaves it out and every refresh becomes a full read.
    static let eventFields =
        "nextPageToken,nextSyncToken,items(id,iCalUID,status,summary,description,location,"
        + "htmlLink,colorId,eventLabelId,start,end,originalStartTime,recurringEventId,"
        + "transparency,eventType,organizer(self),"
        + "attendees(email,displayName,organizer,self,resource,optional,responseStatus),"
        + "hangoutLink,conferenceData/entryPoints(entryPointType,uri))"
    static let calendarListFields =
        "nextPageToken,nextSyncToken,items(id,summary,summaryOverride,backgroundColor,selected,"
        + "primary,accessRole,timeZone,deleted,hidden)"
    /// Google's own limit per page; a five-month window rarely needs a second page.
    static let maxResults = 2500
    /// A runaway guard: no window or change set Day asks for comes near this many pages.
    static let maxPages = 40

    let transport: any HTTPTransport
    public var retry: RetryPolicy

    public init(transport: any HTTPTransport = GoogleHTTP.session, retry: RetryPolicy = .standard) {
        self.transport = transport
        self.retry = retry
    }

    /// The same client with another retry policy; the widget uses `.once`.
    public func with(retry: RetryPolicy) -> CalendarAPI {
        var copy = self
        copy.retry = retry
        return copy
    }

    // MARK: Calls

    /// The account's calendar list: every entry when `syncToken` is nil, otherwise only the
    /// entries changed since it, with deleted and hidden ones marked so. All pages.
    public func calendarList(accessToken: String, syncToken: String? = nil) async throws
        -> CalendarListResult
    {
        let (entries, next): ([GoogleCalendarListEntry], String?) = try await pages { pageToken in
            calendarListRequest(syncToken: syncToken, pageToken: pageToken, accessToken: accessToken)
        }
        return CalendarListResult(entries: entries, nextSyncToken: next)
    }

    /// One calendar's own resource, which carries its event labels.
    public func calendar(_ calendarID: String, accessToken: String) async throws
        -> GoogleCalendarResource
    {
        let data = try await perform(calendarRequest(calendarID, accessToken: accessToken))
        do {
            return try JSONDecoder().decode(GoogleCalendarResource.self, from: data)
        } catch {
            throw CalendarAPIError.malformed
        }
    }

    /// Events of one calendar, recurring series expanded by Google (`singleEvents=true`), all
    /// pages. A `.window` read returns every instance overlapping the window and, on its last
    /// page, a token; `.changes` returns what changed since the token, `cancelled` items
    /// included, and the next token.
    public func events(calendarID: String, query: EventQuery, accessToken: String) async throws
        -> EventList
    {
        do {
            let (items, next): ([GoogleEvent], String?) = try await pages { pageToken in
                eventsRequest(
                    calendarID: calendarID, query: query, pageToken: pageToken,
                    accessToken: accessToken)
            }
            return EventList(items: items, nextSyncToken: next)
        } catch CalendarAPIError.badRequest {
            // A 400 here is most likely the fields mask naming a field Google has renamed or
            // withdrawn (labels are new). The whole resource is a larger answer, not a broken
            // one. A second 400 without the mask is about the token itself and is thrown.
            let (items, next): ([GoogleEvent], String?) = try await pages { pageToken in
                eventsRequest(
                    calendarID: calendarID, query: query, pageToken: pageToken,
                    accessToken: accessToken, fields: nil)
            }
            return EventList(items: items, nextSyncToken: next)
        }
    }

    /// Every instance overlapping `from..<to`, without keeping the token: the widget's days
    /// and the Month's stretches beyond the synced window.
    public func events(
        calendarID: String, from: Date, to: Date, accessToken: String
    ) async throws -> [GoogleEvent] {
        try await events(
            calendarID: calendarID, query: .window(from: from, to: to), accessToken: accessToken
        ).items
    }

    // MARK: Requests

    func calendarListRequest(syncToken: String?, pageToken: String?, accessToken: String)
        -> URLRequest
    {
        var items = [
            URLQueryItem(name: "maxResults", value: "250"),
            URLQueryItem(name: "fields", value: CalendarAPI.calendarListFields),
        ]
        // Deleted and hidden entries come back on their own with a token; Google refuses
        // `showDeleted=false` or `showHidden=false` beside one, so neither is ever sent.
        if let syncToken { items.append(URLQueryItem(name: "syncToken", value: syncToken)) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return request(path: ["users", "me", "calendarList"], query: items, accessToken: accessToken)
    }

    func calendarRequest(_ calendarID: String, accessToken: String) -> URLRequest {
        request(path: ["calendars", calendarID], query: [], accessToken: accessToken)
    }

    /// The same parameters for the full read and every incremental read after it, as Google
    /// asks, except the window, which it refuses beside a token. No `orderBy`: Google refuses
    /// it beside a token, and a full read that sends it gets no token back. No `showDeleted`:
    /// a token always brings deletions, and the full read has no use for them.
    func eventsRequest(
        calendarID: String, query: EventQuery, pageToken: String?, accessToken: String,
        fields: String? = CalendarAPI.eventFields
    ) -> URLRequest {
        var items = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "maxResults", value: String(CalendarAPI.maxResults)),
            URLQueryItem(name: "eventLabelVersion", value: "1"),
        ]
        switch query {
        case .window(let from, let to):
            items.append(URLQueryItem(name: "timeMin", value: CalendarAPI.rfc3339(from)))
            items.append(URLQueryItem(name: "timeMax", value: CalendarAPI.rfc3339(to)))
        case .changes(let token):
            items.append(URLQueryItem(name: "syncToken", value: token))
        }
        if let fields { items.append(URLQueryItem(name: "fields", value: fields)) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return request(
            path: ["calendars", calendarID, "events"], query: items, accessToken: accessToken)
    }

    /// Builds the URL with each path segment percent-encoded on its own. Calendar IDs carry
    /// `#`, `@` and `+` (`en.dutch#holiday@group.v.calendar.google.com`), and string
    /// interpolation into a path turns the `#` into a fragment and answers 404.
    func request(path: [String], query: [URLQueryItem], accessToken: String) -> URLRequest {
        var components = URLComponents(url: CalendarAPI.base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath =
            components.percentEncodedPath + "/"
            + path.map(CalendarAPI.encodeSegment).joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        // "+" in a query value reads as a space to Google; page tokens, sync tokens and times
        // may hold one.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Day (gzip)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func encodeSegment(_ segment: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: unreserved)!
    }

    /// RFC 3339 in UTC, `2026-09-29T22:00:00Z`, as `timeMin` and `timeMax` require.
    static func rfc3339(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    // MARK: Paging and status

    /// Every page of one list, and the sync token from the last. Each page repeats the first
    /// request with only `pageToken` added, which is what Google requires of a paged
    /// incremental read. Stopping early would hand back part of a window as if it were all of
    /// it, so running past the guard is an error rather than a short answer.
    private func pages<Item: Decodable & Sendable>(
        request: (String?) -> URLRequest
    ) async throws -> ([Item], String?) {
        var items: [Item] = []
        var pageToken: String?
        for _ in 0..<CalendarAPI.maxPages {
            let data = try await perform(request(pageToken))
            let page: GooglePage<Item>
            do {
                page = try JSONDecoder().decode(GooglePage<Item>.self, from: data)
            } catch {
                throw CalendarAPIError.malformed
            }
            items += page.items
            guard let next = page.nextPageToken, !next.isEmpty else {
                return (items, page.nextSyncToken.flatMap { $0.isEmpty ? nil : $0 })
            }
            pageToken = next
        }
        throw CalendarAPIError.malformed
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await GoogleHTTP.send(request, using: transport, retry: retry)
        let status = response.statusCode
        if (200..<300).contains(status) { return data }
        let detail = GoogleErrorBody.parse(data)
        let reasons = Set(detail?.errors?.compactMap(\.reason) ?? [])
        switch status {
        case 400:
            throw CalendarAPIError.badRequest
        case 401:
            throw CalendarAPIError.unauthorized
        case 403 where reasons.contains("insufficientPermissions")
            || detail?.message?.localizedCaseInsensitiveContains("insufficient authentication scopes")
                == true:
            throw CalendarAPIError.insufficientScope
        case 404:
            throw CalendarAPIError.notFound
        case 410:
            throw CalendarAPIError.fullSyncRequired
        case 429, 500...599:
            throw CalendarAPIError.unavailable(status: status)
        case 403 where GoogleHTTP.shouldRetry(status: status, body: data):
            throw CalendarAPIError.unavailable(status: status)
        default:
            throw CalendarAPIError.http(status: status, reason: reasons.sorted().first)
        }
    }
}

/// What an `events.list` call asks for.
public enum EventQuery: Hashable, Sendable {
    /// Every instance overlapping `from..<to`. The last page carries a sync token.
    case window(from: Date, to: Date)
    /// Only what changed since the token, `cancelled` items included.
    case changes(since: String)
}

/// The items of every page of one `events.list` call.
public struct EventList: Hashable, Sendable {
    public var items: [GoogleEvent]
    /// From the last page. Nil when Google sent none, which a window read with `orderBy` or a
    /// fields mask without `nextSyncToken` would cause.
    public var nextSyncToken: String?

    public init(items: [GoogleEvent], nextSyncToken: String?) {
        self.items = items
        self.nextSyncToken = nextSyncToken
    }
}

/// The entries of every page of one `calendarList.list` call.
public struct CalendarListResult: Hashable, Sendable {
    public var entries: [GoogleCalendarListEntry]
    public var nextSyncToken: String?

    public init(entries: [GoogleCalendarListEntry], nextSyncToken: String?) {
        self.entries = entries
        self.nextSyncToken = nextSyncToken
    }
}

public enum CalendarAPIError: Error, Hashable, Sendable {
    /// 400. For events this happens if the fields mask is refused, or if Google no longer
    /// accepts a sync token in this shape; both end in a full read.
    case badRequest
    /// 401: the access token expired early or was revoked. Refresh once and try again.
    case unauthorized
    /// 403 for a missing scope: the grant lacks calendar access, so the account must sign
    /// in again.
    case insufficientScope
    /// 404: the calendar was deleted or is no longer shared with this account.
    case notFound
    /// 410 Gone: Google invalidated the sync token (it expired, or the calendar's sharing
    /// changed). The calendar is read again in full, with no token.
    case fullSyncRequired
    /// Rate limits or server errors that outlasted every retry.
    case unavailable(status: Int)
    /// Any other status, with Google's reason when it sent one (the first, in alphabetical
    /// order, when it sent several).
    case http(status: Int, reason: String?)
    /// The body did not decode as Google's JSON, or a list ran past the page guard.
    case malformed
}

extension CalendarAPIError {
    /// The 403 reasons that speak about one calendar: it is no longer shared with this
    /// account, or shared with less access than reading events takes. Every other 403 is
    /// about the account or the project (`accessNotConfigured` when the Calendar API is not
    /// enabled, a quota that ran out, a Workspace block), and says nothing about any single
    /// calendar.
    static let calendarOnlyReasons: Set<String> = ["forbidden", "requiredAccessLevel"]

    /// Whether this failure only means one calendar cannot be read any more, so the
    /// account's other calendars are still good. Treating a project-wide 403 this way would
    /// empty every calendar at once while the screen says nothing is wrong. A 410 counts
    /// here only when a full read with no token gets it, since a token's 410 is answered by
    /// a full read first.
    var meansCalendarUnreadable: Bool {
        switch self {
        case .notFound, .fullSyncRequired:
            true
        case .http(403, let reason?):
            CalendarAPIError.calendarOnlyReasons.contains(reason)
        default:
            false
        }
    }

    /// Whether a sync token must be dropped and the calendar read in full again.
    var needsFullSync: Bool {
        self == .fullSyncRequired || self == .badRequest
    }
}
