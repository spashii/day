import Foundation

/// Google's push channels for the Calendar API: `events.watch`, `calendarList.watch` and
/// `channels.stop` (developers.google.com/workspace/calendar/api/guides/push). Each call
/// uses the account's own access token; `calendar.readonly` covers all three.
struct WatchClient: Sendable {
    let api: CalendarAPI

    /// What a watch answer carries that Day keeps. `resourceUri` is left undecoded: it names
    /// the calendar, and nothing here needs it.
    struct Opened: Decodable, Hashable, Sendable {
        var id: String
        var resourceId: String
        var expiration: String?
    }

    /// Opens a channel on `target` that delivers to `address` with `token` echoed back.
    func watch(
        _ target: WatchTarget, channelID: String, token: String, address: URL, accessToken: String
    ) async throws -> Opened {
        let data = try await perform(
            watchRequest(
                target, channelID: channelID, token: token, address: address,
                accessToken: accessToken))
        guard let opened = try? JSONDecoder().decode(Opened.self, from: data),
            opened.id == channelID
        else { throw CalendarAPIError.malformed }
        return opened
    }

    /// Stops a channel. One Google no longer knows (expired, or stopped before) counts as
    /// stopped.
    func stop(_ channel: WatchedChannel, accessToken: String) async throws {
        do {
            _ = try await perform(stopRequest(channel, accessToken: accessToken))
        } catch CalendarAPIError.notFound {
            return
        }
    }

    func watchRequest(
        _ target: WatchTarget, channelID: String, token: String, address: URL, accessToken: String
    ) -> URLRequest {
        let path: [String] =
            switch target {
            case .calendarList: ["users", "me", "calendarList", "watch"]
            case .events(let calendar): ["calendars", calendar.googleID, "events", "watch"]
            }
        // No `params.ttl`: Google picks the lifetime and says it in `expiration`, which is
        // what renewal is timed from.
        let body: [String: String] = [
            "id": channelID, "type": "web_hook", "address": address.absoluteString, "token": token,
        ]
        return post(path: path, body: body, accessToken: accessToken)
    }

    func stopRequest(_ channel: WatchedChannel, accessToken: String) -> URLRequest {
        post(
            path: ["channels", "stop"], body: ["id": channel.id, "resourceId": channel.resourceID],
            accessToken: accessToken)
    }

    private func post(path: [String], body: [String: String], accessToken: String) -> URLRequest {
        var request = api.request(path: path, query: [], accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try? encoder.encode(body)
        return request
    }

    /// The same status reading as the sync calls, so the account's authorizer refreshes the
    /// token on a 401 exactly as it does for a read.
    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await GoogleHTTP.send(
            request, using: api.transport, retry: api.retry)
        let status = response.statusCode
        if (200..<300).contains(status) { return data }
        let reasons = GoogleErrorBody.reasons(in: data)
        switch status {
        case 400: throw CalendarAPIError.http(status: 400, reason: reasons.sorted().first)
        case 401: throw CalendarAPIError.unauthorized
        case 404: throw CalendarAPIError.notFound
        case 429, 500...599: throw CalendarAPIError.unavailable(status: status)
        case 403 where GoogleHTTP.shouldRetry(status: status, body: data):
            throw CalendarAPIError.unavailable(status: status)
        default: throw CalendarAPIError.http(status: status, reason: reasons.sorted().first)
        }
    }
}
