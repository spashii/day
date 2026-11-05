import Foundation
import Synchronization
import Testing

@testable import DayCore

/// The relay and Google's channel endpoints as one scripted network, for the push tests.
/// Every account, calendar and token here is invented.
final class PushNet: HTTPTransport {
    struct Sent {
        var method: String
        var url: URL
        var body: [String: Any]?
        var text: String

        var host: String { url.host() ?? "" }
        var path: String { url.path(percentEncoded: true) }
    }

    /// Answers by (method, path suffix); anything unscripted is a 404.
    typealias Answer = @Sendable (URLRequest, [String: Any]?) -> (Int, String)

    private let log = Mutex<[SentBox]>([])
    private let answers = Mutex<[(String, String, Answer)]>([])
    private let counter = Counter()

    /// Google's channel lifetime in these tests: a week, as Google's default.
    static let lifetime: TimeInterval = 7 * 24 * 3600
    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
        answer("POST", "/day/devices") { request, body in
            let install = body?["install"] as? String ?? "?"
            return (200, #"{"channelToken":"\#(install).c2lnbmVk"}"#)
        }
        answer("DELETE", "/day/devices/") { _, _ in (204, "") }
        let watch: Answer = { [counter, now] _, body in
            let id = body?["id"] as? String ?? "?"
            let n = counter.next()
            let expiry = Int64((now().timeIntervalSince1970 + PushNet.lifetime) * 1000)
            return (
                200,
                #"{"kind":"api#channel","id":"\#(id)","resourceId":"resource-\#(n)","resourceUri":"https://www.googleapis.com/calendar/v3/invented","expiration":"\#(expiry)"}"#
            )
        }
        answer("POST", "/events/watch", watch)
        answer("POST", "/calendarList/watch", watch)
        answer("POST", "/channels/stop") { _, _ in (204, "") }
    }

    /// Replaces the answer for requests whose path ends with `suffix` (or contains it, for
    /// the relay's DELETE).
    func answer(_ method: String, _ suffix: String, _ answer: @escaping Answer) {
        answers.withLock { list in
            list.removeAll { $0.0 == method && $0.1 == suffix }
            list.insert((method, suffix, answer), at: 0)
        }
    }

    var sent: [Sent] {
        log.withLock { $0.map(\.sent) }
    }

    func clear() {
        log.withLock { $0 = [] }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let text = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        log.withLock {
            $0.append(SentBox(sent: Sent(method: method, url: url, body: body, text: text)))
        }
        let path = url.path(percentEncoded: true)
        let match = answers.withLock { list in
            list.first { $0.0 == method && (path.hasSuffix($0.1) || path.contains($0.1)) }?.2
        }
        let (status, answer) = match?(request, body) ?? (404, "")
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (Data(answer.utf8), response)
    }

    final class Counter: Sendable {
        private let value = Mutex(0)

        func next() -> Int {
            value.withLock { $0 += 1; return $0 }
        }
    }

    /// `Sent` holds a JSON dictionary, which is not Sendable; it is only read after the fact.
    private struct SentBox: @unchecked Sendable {
        var sent: Sent
    }
}

/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date) {
        current = Mutex(start)
    }

    var now: Date {
        current.withLock { $0 }
    }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// An engine with two signed-in invented accounts, their tokens valid for a long time, and a
/// coordinator over it that talks to `PushNet`.
struct PushFixture {
    static let clientID = "123456789012-abcdefghijklmnop.apps.googleusercontent.com"
    static let noWait = RetryPolicy(maxAttempts: 1, sleep: { _ in })
    static let appToken = String(repeating: "a1", count: 32)
    static let widgetToken = String(repeating: "b2", count: 32)

    static let work = Account(id: AccountID("117000000000000000001"), email: "you@acme.com", addedAt: .distantPast)
    static let home = Account(id: AccountID("117000000000000000002"), email: "you@gmail.com", addedAt: .distantPast)
    static let workPrimary = CalendarInfo(
        id: CalendarID(account: work.id, googleID: "you@acme.com"), name: "you@acme.com",
        colorHex: "#4285F4", isPrimary: true, accessRole: .owner)
    static let holidays = CalendarInfo(
        id: CalendarID(account: work.id, googleID: "en.dutch#holiday@group.v.calendar.google.com"),
        name: "Holidays", colorHex: "#0B8043", isPrimary: false, accessRole: .reader)
    static let homePrimary = CalendarInfo(
        id: CalendarID(account: home.id, googleID: "you@gmail.com"), name: "Personal",
        colorHex: "#039BE5", isPrimary: true, accessRole: .owner)

    let clock: TestClock
    let net: PushNet
    let engine: SyncEngine
    let coordinator: PushCoordinator
    let folder: URL
    let tokens: MemoryTokenStore

    init(start: Date = Date(timeIntervalSince1970: 1_793_800_000)) throws {
        let clock = TestClock(start)
        self.clock = clock
        net = PushNet(now: { clock.now })
        folder = FileManager.default.temporaryDirectory.appending(path: "day-push-\(UUID().uuidString)")
        let auth = try #require(GoogleAuth(clientID: Self.clientID, transport: net, retry: Self.noWait))
        let valid = start.addingTimeInterval(365 * 24 * 3600)
        tokens = MemoryTokenStore([
            Self.work.id: StoredToken(
                refreshToken: "refresh-work", accessToken: "access-work", accessExpiry: valid,
                email: Self.work.email, scope: GoogleAuth.calendarScope),
            Self.home.id: StoredToken(
                refreshToken: "refresh-home", accessToken: "access-home", accessExpiry: valid,
                email: Self.home.email, scope: GoogleAuth.calendarScope),
        ])
        engine = SyncEngine(
            auth: auth, tokens: tokens, cache: CacheDirectory(url: folder),
            api: CalendarAPI(transport: net, retry: Self.noWait), clock: { clock.now })
        coordinator = PushCoordinator(
            engine: engine, server: PushServer(transport: net, retry: Self.noWait),
            platform: .ios, environment: .production, retry: Self.noWait)
    }

    var store: PushStore {
        PushStore(directory: CacheDirectory(url: folder))
    }

    /// Both accounts, their primary calendars shown, the holiday calendar too unless hidden.
    static func wanted(holidays shown: Bool = true, accounts: [Account] = [work, home]) -> WatchSet {
        WatchSet(accounts: accounts, calendars: [workPrimary, holidays, homePrimary]) { id in
            id != holidays.id || shown
        }
    }

    static var tokens: PushCoordinator.Tokens {
        PushCoordinator.Tokens(app: appToken)
    }
}
