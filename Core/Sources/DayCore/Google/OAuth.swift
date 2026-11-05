import Foundation

/// Google sign-in for an iOS-type OAuth client with no secret: authorization code with
/// PKCE, the code exchange, refresh, and the id_token's `sub` and `email`. One client serves
/// the iPhone and the Mac, because Google says macOS apps use the iOS client type.
///
/// The browser step stays outside Core: the app opens `AuthorizationRequest.url` in its
/// `WebAuthenticationSession` with `.customScheme(request.callbackScheme)` and hands the
/// callback URL to `exchange(callback:for:)`. Core then needs no UI framework, and the whole
/// flow is testable with recorded answers.
public struct GoogleAuth: Sendable {
    public static let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"
    /// One sensitive scope that can read the calendar list, events and event labels, plus
    /// `openid email` for the account's `sub` and address.
    public static let scopes = ["openid", "email", calendarScope]

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let clientSuffix = ".apps.googleusercontent.com"
    static let issuers: Set = ["accounts.google.com", "https://accounts.google.com"]

    /// `<id>.apps.googleusercontent.com`.
    public let clientID: String
    /// The reversed client ID, `com.googleusercontent.apps.<id>`, registered as a URL scheme
    /// on the iPhone and given to the authentication session on both platforms.
    public let callbackScheme: String
    /// `com.googleusercontent.apps.<id>:/oauth2redirect`, with one slash, as Google expects
    /// for iOS clients.
    public let redirectURI: String
    let transport: any HTTPTransport
    var retry: RetryPolicy

    /// Nil for the placeholder that ships until a real client exists, or for anything that
    /// is not a Google client ID, so the apps fall back to the fixture rather than open a
    /// sign-in page that can only fail.
    public init?(
        clientID: String, transport: any HTTPTransport = GoogleHTTP.session,
        retry: RetryPolicy = .standard
    ) {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != DayIdentifiers.googleClientPlaceholder, id.hasSuffix(GoogleAuth.clientSuffix)
        else { return nil }
        let prefix = String(id.dropLast(GoogleAuth.clientSuffix.count))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !prefix.isEmpty, prefix.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        self.clientID = id
        callbackScheme = "com.googleusercontent.apps." + prefix
        redirectURI = callbackScheme + ":/oauth2redirect"
        self.transport = transport
        self.retry = retry
    }

    /// The client from the `GoogleClientID` Info.plist key, which app/project.yml sets in
    /// all three targets.
    public init?(
        bundle: Bundle = .main, transport: any HTTPTransport = GoogleHTTP.session,
        retry: RetryPolicy = .standard
    ) {
        guard let id = bundle.object(forInfoDictionaryKey: DayIdentifiers.googleClientIDKey)
            as? String
        else { return nil }
        self.init(clientID: id, transport: transport, retry: retry)
    }

    /// The same client with another retry policy; the widget uses `.once`.
    public func with(retry: RetryPolicy) -> GoogleAuth {
        var copy = self
        copy.retry = retry
        return copy
    }

    // MARK: Authorization

    /// A fresh request: new verifier, challenge and state each time. `loginHint` is the
    /// account's email when signing a known account in again, so Google preselects it.
    public func authorizationRequest(loginHint: String? = nil) -> AuthorizationRequest {
        let pkce = PKCE()
        let state = PKCE.randomString(bytes: 16)
        var components = URLComponents(
            url: GoogleAuth.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleAuth.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCE.method),
            URLQueryItem(name: "state", value: state),
            // The account chooser every time, so adding a second account never silently
            // reuses the one the browser is already signed in to.
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        if let loginHint, !loginHint.isEmpty {
            items.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        components.queryItems = items
        // URLComponents leaves "+" alone in queries; "+" never appears in these values, but
        // an email login hint may carry one, and Google would read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return AuthorizationRequest(
            url: components.url!, callbackScheme: callbackScheme, state: state, pkce: pkce,
            loginHint: loginHint)
    }

    /// The authorization code from the redirect, after checking it answers this request.
    public func authorizationCode(
        from callback: URL, for request: AuthorizationRequest
    ) throws(OAuthError) -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error") {
            throw error == "access_denied" ? .accessDenied : .authorizationFailed(error)
        }
        guard value("state") == request.state else { throw .stateMismatch }
        guard let code = value("code"), !code.isEmpty else {
            throw .malformedResponse("no code in the redirect")
        }
        return code
    }

    /// Trades the redirect's code for tokens and reads who signed in. A grant without
    /// calendar access is returned, not thrown, with `grantsCalendar` false: the account is
    /// still known and shows as signed out with `Sign In Again…`.
    public func exchange(
        callback: URL, for request: AuthorizationRequest, now: Date = Date()
    ) async throws -> SignIn {
        let code = try authorizationCode(from: callback, for: request)
        let response = try await tokenRequest([
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": request.pkce.verifier,
        ])
        guard let idToken = response.idToken else {
            throw OAuthError.malformedResponse("no id_token")
        }
        let claims = try IDTokenClaims(jwt: idToken, audience: clientID)
        guard let refreshToken = response.refreshToken else {
            throw OAuthError.malformedResponse("no refresh_token")
        }
        let token = StoredToken(
            refreshToken: refreshToken,
            accessToken: response.accessToken,
            accessExpiry: response.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            email: claims.email,
            scope: response.scope ?? GoogleAuth.scopes.joined(separator: " "))
        return SignIn(account: AccountID(sub: claims.sub), email: claims.email, token: token)
    }

    // MARK: Refresh

    /// A new access token. Throws `invalidGrant` when Google has signed the account out
    /// (revoked, expired, or a Workspace session limit with subtype `invalid_rapt`), and
    /// `partialGrant` when the grant no longer includes calendar access.
    public func refresh(_ token: StoredToken, now: Date = Date()) async throws -> StoredToken {
        let response = try await tokenRequest([
            "client_id": clientID,
            "refresh_token": token.refreshToken,
            "grant_type": "refresh_token",
        ])
        guard let access = response.accessToken else {
            throw OAuthError.malformedResponse("no access_token")
        }
        var refreshed = token
        refreshed.accessToken = access
        refreshed.accessExpiry = now.addingTimeInterval(TimeInterval(response.expiresIn ?? 3599))
        if let scope = response.scope { refreshed.scope = scope }
        // Google keeps the refresh token; if it ever sends a new one, the new one wins.
        if let newRefresh = response.refreshToken { refreshed.refreshToken = newRefresh }
        guard refreshed.grantsCalendar else {
            throw OAuthError.partialGrant(granted: refreshed.scope)
        }
        return refreshed
    }

    // MARK: Token endpoint

    struct TokenResponse: Decodable {
        var accessToken: String?
        var expiresIn: Int?
        var refreshToken: String?
        var scope: String?
        var idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
            case idToken = "id_token"
        }
    }

    struct OAuthErrorBody: Decodable {
        var error: String?
        var errorDescription: String?
        var errorSubtype: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
            case errorSubtype = "error_subtype"
        }
    }

    func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: GoogleAuth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(GoogleAuth.formEncoded(form).utf8)
        let (data, response) = try await GoogleHTTP.send(
            request, using: transport, retry: retry)
        guard (200..<300).contains(response.statusCode) else {
            let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
            switch body?.error {
            case "invalid_grant":
                throw OAuthError.invalidGrant(subtype: body?.errorSubtype)
            case "invalid_client", "unauthorized_client", "deleted_client":
                throw OAuthError.clientRejected(body?.error ?? "")
            default:
                throw OAuthError.tokenEndpoint(status: response.statusCode, error: body?.error)
            }
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthError.malformedResponse("token response does not decode")
        }
    }

    /// `application/x-www-form-urlencoded`, keys sorted so a request is reproducible.
    static func formEncoded(_ form: [String: String]) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return form.keys.sorted().map { key in
            let value = form[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
            return "\(key)=\(value)"
        }.joined(separator: "&")
    }
}

/// One sign-in attempt, kept by the caller between opening the browser and the redirect.
public struct AuthorizationRequest: Hashable, Sendable {
    /// Open this in the authentication session.
    public let url: URL
    /// Give this to the session as `.customScheme(callbackScheme)`.
    public let callbackScheme: String
    public let state: String
    public let pkce: PKCE
    /// The email Google was asked to preselect, when signing a known account in again.
    public let loginHint: String?
}

/// Who signed in and the tokens Google gave them.
public struct SignIn: Hashable, Sendable {
    public var account: AccountID
    public var email: String
    public var token: StoredToken

    /// False when calendar access was unticked on the consent screen.
    public var grantsCalendar: Bool {
        token.grantsCalendar
    }
}

/// The id_token claims Day reads. The token comes straight from Google's token endpoint over
/// TLS, which OpenID Connect accepts in place of checking the signature (Core 1.0, 3.1.3.7);
/// the issuer and audience are still checked so a token for another client is refused.
public struct IDTokenClaims: Hashable, Sendable, Decodable {
    /// The account's stable identifier: it keys the keychain item, the cache files and links.
    public var sub: String
    public var email: String
    public var iss: String?
    public var aud: String?

    public init(jwt: String, audience: String) throws(OAuthError) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = PKCE.data(base64URL: parts[1]),
            let claims = try? JSONDecoder().decode(IDTokenClaims.self, from: payload)
        else { throw .malformedResponse("id_token does not decode") }
        guard claims.aud == audience, claims.iss.map({ GoogleAuth.issuers.contains($0) }) ?? false
        else {
            throw .malformedResponse("id_token is for another client")
        }
        guard !claims.sub.isEmpty, claims.email.contains("@") else {
            throw .malformedResponse("id_token lacks sub or email")
        }
        self = claims
    }
}

public enum OAuthError: Error, Hashable, Sendable {
    /// The person chose Cancel on Google's consent screen.
    case accessDenied
    /// Google's redirect carried another `error`.
    case authorizationFailed(String)
    /// The redirect answers a different request; it is ignored.
    case stateMismatch
    /// Google refused the refresh token: revoked, expired, or a Workspace reauthentication
    /// policy (`invalid_rapt`). Only this account is signed out; its events stay.
    case invalidGrant(subtype: String?)
    /// The OAuth client itself was refused, for example deleted in the Cloud Console.
    case clientRejected(String)
    /// The grant lacks calendar access. `granted` is the scope Google did grant.
    case partialGrant(granted: String)
    /// Sign In Again picked a different Google account than the one being repaired.
    case differentAccount(email: String)
    /// Any other answer from the token endpoint.
    case tokenEndpoint(status: Int, error: String?)
    case malformedResponse(String)

    /// The account needs `Sign In Again…`; nothing a retry can fix.
    public var signsOut: Bool {
        switch self {
        case .invalidGrant, .clientRejected, .partialGrant: true
        default: false
        }
    }
}
