import Foundation

/// Sends one HTTP request and hands back the raw answer. `URLSession` is the real one; the
/// tests answer with recorded, invented responses, so nothing in the suite reaches Google.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Shared HTTP plumbing for the token endpoint and the Calendar API.
public enum GoogleHTTP {
    /// An ephemeral session: Google's answers carry calendar contents, and the shared session
    /// would also keep a copy in the URL cache on disk, outside the files Day manages.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = [
            // Google serves gzip only to clients that both accept it and say so in the user
            // agent (developers.google.com/workspace/calendar/api/guides/performance).
            "Accept-Encoding": "gzip",
            "User-Agent": "Day (gzip)",
        ]
        return URLSession(configuration: configuration)
    }()

    /// Sends `request`, retrying what Google asks clients to retry: 429, 5xx, a 403 whose
    /// reason is a rate limit, and a dropped connection. Every other answer, including a
    /// final failing one, is returned for the caller to read.
    static func send(
        _ request: URLRequest, using transport: any HTTPTransport, retry: RetryPolicy
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            let canRetry = attempt < retry.maxAttempts
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as URLError where canRetry && isTransient(error) {
                try await retry.sleep(retry.delay(afterAttempt: attempt, retryAfter: nil))
                continue
            }
            if canRetry, shouldRetry(status: response.statusCode, body: data) {
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Int.init).map { Duration.seconds($0) }
                try await retry.sleep(retry.delay(afterAttempt: attempt, retryAfter: retryAfter))
                continue
            }
            return (data, response)
        }
    }

    static func shouldRetry(status: Int, body: Data) -> Bool {
        switch status {
        case 429, 500...599:
            return true
        case 403:
            // Quota and rate limits arrive as 403 too; only these reasons clear with time.
            let reasons = GoogleErrorBody.reasons(in: body)
            if !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded"]) {
                return true
            }
            // Also under `usageLimits`, but only a person can clear these: a spent daily
            // quota, or the Calendar API not enabled in the project. Retrying would only
            // delay the line that says so by the whole backoff.
            let permanent: Set = ["dailyLimitExceeded", "quotaExceeded", "accessNotConfigured"]
            return GoogleErrorBody.domains(in: body).contains("usageLimits")
                && reasons.isDisjoint(with: permanent)
        default:
            return false
        }
    }

    /// A connection that dropped or stalled mid-request, worth one more try. Having no
    /// network at all is not: retrying only delays the `Offline` line.
    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed:
            true
        default:
            false
        }
    }

    /// Whether a failure means the device has no network, which the screen reports as
    /// `Offline` rather than `Couldn't reach Google`.
    public static func isOffline(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
            .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }
}

/// How often and how patiently to retry, per Google's advice: exponential backoff with
/// jitter, capped at 32 seconds (developers.google.com/workspace/calendar/api/guides/quota).
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    /// How a delay is waited out. Tests replace it so a retry costs no time.
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        maxAttempts: Int,
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(32),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.sleep = sleep
    }

    /// The app: up to five tries, about a minute in the worst case, off the main thread.
    public static let standard = RetryPolicy(maxAttempts: 5)
    /// The widget: one try, because its whole fetch has about five seconds.
    public static let once = RetryPolicy(maxAttempts: 1)

    /// `base * 2^(attempt - 1)` plus up to a second of jitter, capped; a `Retry-After` from
    /// Google wins when it is longer.
    func delay(afterAttempt attempt: Int, retryAfter: Duration?) -> Duration {
        let exponent = min(attempt - 1, 10)
        let backoff = baseDelay * (1 << exponent)
        let jitter = Duration.milliseconds(Int.random(in: 0...1000))
        let delay = min(backoff + jitter, maxDelay)
        if let retryAfter, retryAfter > delay { return min(retryAfter, maxDelay) }
        return delay
    }
}

/// Google's JSON error body: `{"error": {"code", "message", "status", "errors": [{"domain",
/// "reason"}]}}`. The OAuth token endpoint uses a different shape (`OAuthErrorBody`).
struct GoogleErrorBody: Decodable {
    struct Detail: Decodable {
        var code: Int?
        var message: String?
        var status: String?
        var errors: [Item]?
    }

    struct Item: Decodable {
        var domain: String?
        var reason: String?
    }

    var error: Detail?

    static func parse(_ data: Data) -> Detail? {
        (try? JSONDecoder().decode(GoogleErrorBody.self, from: data))?.error
    }

    static func reasons(in data: Data) -> Set<String> {
        Set(parse(data)?.errors?.compactMap(\.reason) ?? [])
    }

    static func domains(in data: Data) -> Set<String> {
        Set(parse(data)?.errors?.compactMap(\.domain) ?? [])
    }
}
