import Foundation
import Synchronization

/// One account's Google tokens: the keychain item's data, as JSON with Google's own key
/// names. The access token is kept with its expiry so the widget can usually skip the
/// refresh call. Google does not rotate refresh tokens, so the app and the widget may both
/// refresh at once; whichever writes last leaves a valid access token either way.
public struct StoredToken: Codable, Hashable, Sendable {
    public var refreshToken: String
    public var accessToken: String?
    public var accessExpiry: Date?
    /// The account's address when the token was granted, so a keychain item can be told
    /// apart without the accounts file.
    public var email: String
    /// The scopes Google granted, space separated, as the token endpoint returns them.
    public var scope: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case accessToken = "access_token"
        case accessExpiry = "access_expiry"
        case email
        case scope
    }

    public init(
        refreshToken: String, accessToken: String? = nil, accessExpiry: Date? = nil,
        email: String, scope: String
    ) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.accessExpiry = accessExpiry
        self.email = email
        self.scope = scope
    }

    public var grantedScopes: Set<String> {
        Set(scope.split(separator: " ").map(String.init))
    }

    /// False for a partial grant: the person unticked calendar access on Google's consent
    /// screen. The account then shows as signed out with `Sign In Again…`.
    public var grantsCalendar: Bool {
        grantedScopes.contains(GoogleAuth.calendarScope)
    }

    /// The access token while it has more than a minute left, so a request never starts
    /// with a token that expires in flight.
    public func validAccessToken(at now: Date) -> String? {
        guard let accessToken, let accessExpiry, accessExpiry.timeIntervalSince(now) > 60
        else { return nil }
        return accessToken
    }

    /// The keychain item's bytes.
    public func encoded() throws -> Data {
        try DayJSON.encoder().encode(self)
    }

    public init(encoded data: Data) throws {
        self = try DayJSON.decoder().decode(StoredToken.self, from: data)
    }
}

/// Where tokens live: the keychain in the apps and the widget (`KeychainTokenStore` in
/// app/Shared/Model, shared with the widget through the App Group on iPhone), memory in
/// tests. Keyed by the account's `sub`, which never changes even when the email does.
public protocol TokenStore: Sendable {
    func token(for account: AccountID) throws -> StoredToken?
    /// A refreshed access token for an account that is already signed in. It never adds an
    /// account: a refresh that finishes after the account was removed must leave nothing
    /// behind.
    func save(_ token: StoredToken, for account: AccountID) throws
    /// A token from a sign-in: the only way an account is added.
    func signIn(_ token: StoredToken, for account: AccountID) throws
    func removeToken(for account: AccountID) throws
    /// The shared keychain store behind this one, when there is one. The account list, the
    /// move of old items, the refused-token note and the revocation queue work on it, so a
    /// store that wraps another (the apps' `KeychainTokenStore`) must hand it on: the engine
    /// is given the wrapper and would otherwise find none of it. Required, with no default,
    /// so a new store cannot forget.
    var sharedStore: SharedTokenStore? { get }
}

/// Tokens in memory, for tests and for running without a keychain.
public final class MemoryTokenStore: TokenStore {
    private let tokens: Mutex<[AccountID: StoredToken]>

    public init(_ tokens: [AccountID: StoredToken] = [:]) {
        self.tokens = Mutex(tokens)
    }

    public func token(for account: AccountID) throws -> StoredToken? {
        tokens.withLock { $0[account] }
    }

    public func save(_ token: StoredToken, for account: AccountID) throws {
        tokens.withLock { $0[account] = token }
    }

    public func signIn(_ token: StoredToken, for account: AccountID) throws {
        tokens.withLock { $0[account] = token }
    }

    public func removeToken(for account: AccountID) throws {
        _ = tokens.withLock { $0.removeValue(forKey: account) }
    }

    public var sharedStore: SharedTokenStore? { nil }
}
