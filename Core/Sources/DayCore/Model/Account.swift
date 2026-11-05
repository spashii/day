import Foundation

/// A Google account, identified by the `sub` claim of its id_token. The email can change in
/// Google; the sub cannot, so it keys the keychain item, the cache files and every route.
public struct AccountID: Codable, Hashable, Comparable, Sendable, CodingKeyRepresentable {
    public var sub: String

    public init(sub: String) {
        self.sub = sub
    }

    public init(_ sub: String) {
        self.sub = sub
    }

    public static func < (lhs: AccountID, rhs: AccountID) -> Bool {
        lhs.sub < rhs.sub
    }

    // A bare string in JSON, so fixtures and cache files read "account": "1001" and a
    // dictionary keyed by account encodes as an object rather than an array of pairs.
    public init(from decoder: any Decoder) throws {
        sub = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(sub)
    }

    public var codingKey: any CodingKey {
        AnyCodingKey(sub)
    }

    public init?<T: CodingKey>(codingKey: T) {
        sub = codingKey.stringValue
    }
}

/// One signed-in Google account, in the order it was added. Order matters: it is the order
/// of the accounts list and the last tiebreak when the same event arrives from two accounts.
public struct Account: Codable, Hashable, Identifiable, Sendable {
    public var id: AccountID
    public var email: String
    public var addedAt: Date
    /// Google refused the refresh token (`invalid_grant`, including Workspace
    /// `invalid_rapt`) or the grant lacks the calendar scope. Cached events stay on screen.
    public var signedOut: Bool

    public init(id: AccountID, email: String, addedAt: Date, signedOut: Bool = false) {
        self.id = id
        self.email = email
        self.addedAt = addedAt
        self.signedOut = signedOut
    }

    /// The part after the @, lowercased: `acme.com`. Month rule 4 compares attendee domains
    /// against it to tell outside guests from colleagues.
    public var domain: String {
        guard let at = email.lastIndex(of: "@") else { return "" }
        return email[email.index(after: at)...].lowercased()
    }

    /// A personal Google account rather than a Workspace one. Month rule 4 titles every
    /// one-off on it, because personal events are never short internal calls.
    public var isConsumer: Bool {
        domain == "gmail.com" || domain == "googlemail.com"
    }
}

/// A string coding key, for types that encode as dictionary keys.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
