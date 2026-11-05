import Foundation

/// The three read-only Calendar API v3 calls Day makes: `calendarList.list`, `calendars.get`
/// (for event labels) and `events.list` over a window. Each takes an access token and
/// returns Google's shapes from `GoogleTypes.swift`; `GoogleDecoding` turns those into the
/// model.
public struct CalendarAPI: Sendable {
    public static let base = URL(string: "https://www.googleapis.com/calendar/v3")!

    /// Only the event fields the views use, which keeps the widget's fetch small.
    /// `eventLabelId` is how labelled events name their label.
    static let eventFields =
        "nextPageToken,items(id,iCalUID,status,summary,description,location,htmlLink,"
        + "colorId,eventLabelId,start,end,originalStartTime,recurringEventId,transparency,"
        + "eventType,organizer(self),attendees(email,self,resource,responseStatus),"
        + "hangoutLink,conferenceData/entryPoints(entryPointType,uri))"
    static let calendarListFields =
        "nextPageToken,items(id,summary,summaryOverride,backgroundColor,selected,primary,"
        + "accessRole,timeZone,deleted,hidden)"
    /// Google's own limit per page; a 155-day window rarely needs a second page.
    static let maxResults = 2500
    /// A runaway guard: no window Day asks for comes near this many pages.
    static let maxPages = 20

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

    /// Every calendar on the account's list, all pages.
    public func calendarList(accessToken: String) async throws -> [GoogleCalendarListEntry] {
        try await pages(accessToken: accessToken) { pageToken in
            calendarListRequest(pageToken: pageToken, accessToken: accessToken)
        }
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

    /// Every instance overlapping `from..<to`, recurring series expanded by Google
    /// (`singleEvents=true`), in start order, all pages.
    public func events(
        calendarID: String, from: Date, to: Date, accessToken: String
    ) async throws -> [GoogleEvent] {
        do {
            return try await pages(accessToken: accessToken) { pageToken in
                eventsRequest(
                    calendarID: calendarID, from: from, to: to, pageToken: pageToken,
                    accessToken: accessToken)
            }
        } catch CalendarAPIError.badRequest {
            // A 400 here can only be the fields mask naming a field Google has renamed or
            // withdrawn (labels are new). The whole resource is a larger answer, not a
            // broken one, so the window still loads.
            return try await pages(accessToken: accessToken) { pageToken in
                eventsRequest(
                    calendarID: calendarID, from: from, to: to, pageToken: pageToken,
                    accessToken: accessToken, fields: nil)
            }
        }
    }

    // MARK: Requests

    func calendarListRequest(pageToken: String?, accessToken: String) -> URLRequest {
        var items = [
            URLQueryItem(name: "maxResults", value: "250"),
            URLQueryItem(name: "fields", value: CalendarAPI.calendarListFields),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return request(path: ["users", "me", "calendarList"], query: items, accessToken: accessToken)
    }

    func calendarRequest(_ calendarID: String, accessToken: String) -> URLRequest {
        request(path: ["calendars", calendarID], query: [], accessToken: accessToken)
    }

    func eventsRequest(
        calendarID: String, from: Date, to: Date, pageToken: String?, accessToken: String,
        fields: String? = CalendarAPI.eventFields
    ) -> URLRequest {
        var items = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "timeMin", value: CalendarAPI.rfc3339(from)),
            URLQueryItem(name: "timeMax", value: CalendarAPI.rfc3339(to)),
            URLQueryItem(name: "maxResults", value: String(CalendarAPI.maxResults)),
            URLQueryItem(name: "eventLabelVersion", value: "1"),
        ]
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
        // "+" in a query value reads as a space to Google; page tokens and times may hold one.
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

    private func pages<Item: Decodable & Sendable>(
        accessToken: String, request: (String?) -> URLRequest
    ) async throws -> [Item] {
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
            guard let next = page.nextPageToken, !next.isEmpty else { return items }
            pageToken = next
        }
        return items
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
        case 404, 410:
            throw CalendarAPIError.notFound
        case 429, 500...599:
            throw CalendarAPIError.unavailable(status: status)
        case 403 where GoogleHTTP.shouldRetry(status: status, body: data):
            throw CalendarAPIError.unavailable(status: status)
        default:
            throw CalendarAPIError.http(status: status, reason: reasons.sorted().first)
        }
    }
}

public enum CalendarAPIError: Error, Hashable, Sendable {
    /// 400. For events this only happens if the fields mask is refused.
    case badRequest
    /// 401: the access token expired early or was revoked. Refresh once and try again.
    case unauthorized
    /// 403 for a missing scope: the grant lacks calendar access, so the account must sign
    /// in again.
    case insufficientScope
    /// 404 or 410: the calendar was deleted or is no longer shared with this account.
    case notFound
    /// Rate limits or server errors that outlasted every retry.
    case unavailable(status: Int)
    /// Any other status, with Google's reason when it sent one (the first, in alphabetical
    /// order, when it sent several).
    case http(status: Int, reason: String?)
    /// The body did not decode as Google's JSON.
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
    /// empty every calendar at once while the screen says nothing is wrong.
    var meansCalendarUnreadable: Bool {
        switch self {
        case .notFound:
            true
        case .http(403, let reason?):
            CalendarAPIError.calendarOnlyReasons.contains(reason)
        default:
            false
        }
    }
}
