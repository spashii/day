import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636) with the S256 method, which Google requires of
/// native apps. The verifier never leaves the device until the code exchange, so a code
/// intercepted on its way back through the custom URL scheme is useless to anyone else.
public struct PKCE: Hashable, Sendable {
    /// 43 characters of base64url from 32 random bytes, inside RFC 7636's 43 to 128.
    public let verifier: String
    /// `base64url(SHA256(verifier))`, sent with the authorization request.
    public let challenge: String
    public static let method = "S256"

    public init() {
        self.init(verifier: PKCE.randomString(bytes: 32))
    }

    public init(verifier: String) {
        self.verifier = verifier
        challenge = PKCE.challenge(for: verifier)
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Random bytes as base64url, for the verifier and the `state` value. The system
    /// generator is the platform's cryptographic one on Apple platforms.
    public static func randomString(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    /// Base64 with the URL-safe alphabet and no padding (RFC 4648 section 5).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The inverse, tolerant of missing padding, for reading an id_token's payload.
    static func data(base64URL text: some StringProtocol) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
