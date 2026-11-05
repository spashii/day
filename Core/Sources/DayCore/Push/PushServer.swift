import Foundation

/// One `POST /day/devices` body, as `push/README.md` defines it. Nothing in it names a
/// calendar or an account: the install is a random UUID, the channels are random IDs with
/// their expiry, and the tokens are Apple's.
public struct PushRegistration: Encodable, Hashable, Sendable {
    /// What to tell the relay about one push token. The relay keeps a token it is not told
    /// about, so the widget extension can send its own without knowing the app's.
    public enum Token: Hashable, Sendable {
        case keep
        case clear
        case set(String)
    }

    public var install: String
    public var platform: PushPlatform
    public var environment: PushEnvironment
    public var app: Token
    public var widget: Token
    /// The install's whole set, which replaces the relay's. Nil leaves the relay's set alone.
    public var channels: [WatchedChannel]?

    public init(
        install: String, platform: PushPlatform, environment: PushEnvironment,
        app: Token = .keep, widget: Token = .keep, channels: [WatchedChannel]? = nil
    ) {
        self.install = install
        self.platform = platform
        self.environment = environment
        self.app = app
        self.widget = widget
        self.channels = channels
    }

    /// The relay accepts at most this many channels per install.
    public static let maxChannels = 300

    enum CodingKeys: String, CodingKey {
        case install, platform, environment, tokens, channels
    }

    enum TokenKeys: String, CodingKey {
        case app, widget
    }

    enum ChannelKeys: String, CodingKey {
        case id, expiration
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(install, forKey: .install)
        try container.encode(platform, forKey: .platform)
        try container.encode(environment, forKey: .environment)
        var tokens = container.nestedContainer(keyedBy: TokenKeys.self, forKey: .tokens)
        try Self.encode(app, to: &tokens, forKey: .app)
        try Self.encode(widget, to: &tokens, forKey: .widget)
        if let channels {
            var list = container.nestedUnkeyedContainer(forKey: .channels)
            for channel in channels.prefix(Self.maxChannels) {
                var item = list.nestedContainer(keyedBy: ChannelKeys.self)
                try item.encode(channel.id, forKey: .id)
                // A string, as Google writes it in the watch answer.
                try item.encode(String(channel.expirationMillis), forKey: .expiration)
            }
        }
    }

    private static func encode(
        _ token: Token, to container: inout KeyedEncodingContainer<TokenKeys>, forKey key: TokenKeys
    ) throws {
        switch token {
        case .keep: break
        case .clear: try container.encodeNil(forKey: key)
        case .set(let hex): try container.encode(hex, forKey: key)
        }
    }
}

/// Day's push relay at `apps.idea2prod.in`, the Worker in `push/`.
public struct PushServer: Sendable {
    public static let production = URL(string: "https://apps.idea2prod.in/day")!

    /// Where Google posts its notifications; the `address` of every watch.
    public let webhook: URL
    let devices: URL
    let transport: any HTTPTransport
    let retry: RetryPolicy

    public init(
        base: URL = PushServer.production, transport: any HTTPTransport = GoogleHTTP.session,
        retry: RetryPolicy = RetryPolicy(maxAttempts: 2)
    ) {
        webhook = base.appending(path: "push")
        devices = base.appending(path: "devices")
        self.transport = transport
        self.retry = retry
    }

    /// Registers or refreshes the install and returns the channel token for every watch. The
    /// token is the same for the life of the install unless the relay's key changes.
    public func register(_ registration: PushRegistration) async throws -> String {
        var request = URLRequest(url: devices)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(registration)
        let (data, response) = try await GoogleHTTP.send(request, using: transport, retry: retry)
        try Self.check(response.statusCode, data)
        struct Answer: Decodable { var channelToken: String }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
            !answer.channelToken.isEmpty, answer.channelToken.count <= 256
        else { throw PushServerError.malformed }
        return answer.channelToken
    }

    /// Forgets the install, its channels and any pending push.
    public func delete(install: String) async throws {
        var request = URLRequest(url: devices.appending(path: install))
        request.httpMethod = "DELETE"
        let (data, response) = try await GoogleHTTP.send(request, using: transport, retry: retry)
        try Self.check(response.statusCode, data)
    }

    static func check(_ status: Int, _ data: Data) throws {
        switch status {
        case 200..<300:
            return
        case 400..<500 where status != 429:
            struct Problem: Decodable { var error: String? }
            let reason = (try? JSONDecoder().decode(Problem.self, from: data))?.error
            throw PushServerError.rejected(status: status, reason: reason)
        default:
            throw PushServerError.unavailable(status: status)
        }
    }
}

public enum PushServerError: Error, Hashable, Sendable {
    /// The relay refused the request as malformed; retrying the same body will not help.
    case rejected(status: Int, reason: String?)
    /// 429, 5xx, or storage down: try again later.
    case unavailable(status: Int)
    case malformed
}
