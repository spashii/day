import CryptoKit
import Foundation
import Synchronization

/// One Google account as every device on the Apple ID sees it: the shared keychain item's
/// data. It holds only what a device never changes on its own (the refresh token, the address
/// and Google's user ID), so refreshing an access token on one device never writes it and
/// iCloud Keychain carries it only when the person signs in.
public struct AccountItem: Codable, Hashable, Sendable {
    /// Google's user ID, the `sub` claim. Also the item's account name.
    public var sub: String
    public var email: String
    public var refreshToken: String
    /// The scopes Google granted, space separated.
    public var scope: String
    /// When the account was first added on any device, so every device lists accounts in
    /// one order.
    public var addedAt: Date

    enum CodingKeys: String, CodingKey {
        case sub
        case email
        case refreshToken = "refresh_token"
        case scope
        case addedAt = "added_at"
    }

    public init(sub: String, email: String, refreshToken: String, scope: String, addedAt: Date) {
        self.sub = sub
        self.email = email
        self.refreshToken = refreshToken
        self.scope = scope
        self.addedAt = addedAt
    }

    public var id: AccountID { AccountID(sub: sub) }

    public var grantsCalendar: Bool {
        StoredToken(refreshToken: refreshToken, email: email, scope: scope).grantsCalendar
    }

    func encoded() throws -> Data {
        try DayJSON.encoder().encode(self)
    }

    init(encoded data: Data) throws {
        self = try DayJSON.decoder().decode(AccountItem.self, from: data)
    }
}

/// This device's access token for one account, in an item that never leaves the device. It
/// names the refresh token it came from by fingerprint, so a token another device has since
/// replaced is never paired with an access token from the old one.
struct DeviceAccess: Codable, Hashable, Sendable {
    var accessToken: String
    var accessExpiry: Date
    var refreshFingerprint: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accessExpiry = "access_expiry"
        case refreshFingerprint = "for"
    }
}

/// Google tokens for every device on the Apple ID: sign in once, on any of them.
///
/// Four kinds of item, each a `KeychainBackend` the app supplies:
/// - `shared`: one synchronizable item per account (`AccountItem`) in the access group the
///   iPhone app, its widget and the Mac app all claim. These items are the account list.
/// - `device`: this device's access token per account, never synced, in the same group so
///   the widget reads it too.
/// - `legacy`: the per-device items from before (the Mac's login keychain, the iPhone's App
///   Group). Read until `settleLegacyItems` has moved them, and used for everything when this
///   build cannot reach the shared group at all.
/// - `revocations`: refresh tokens whose grant at Google still has to be revoked, on this
///   device only.
///
/// Only a sign-in (`signIn`) or the move of an old item (`settleLegacyItems`) creates a shared
/// item. A refresh (`save`) never does, so a refresh that lands after the account was removed
/// cannot put it back into iCloud Keychain on every device.
///
/// Without iCloud Keychain the shared items still work and simply stay on the device, so
/// each device signs in on its own, as before.
public final class SharedTokenStore: TokenStore {
    let shared: any KeychainBackend
    let device: any KeychainBackend
    let legacy: any KeychainBackend
    let revocations: (any KeychainBackend)?
    let clock: @Sendable () -> Date
    /// Refresh tokens this process has read or written, by `sub`. A save carrying one of these
    /// is a refreshed access token for a token already stored, so it never puts that token
    /// back over one another device has written since.
    private let known = Mutex<[String: Set<String>]>([:])

    public init(
        shared: any KeychainBackend, device: any KeychainBackend, legacy: any KeychainBackend,
        revocations: (any KeychainBackend)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.shared = shared
        self.device = device
        self.legacy = legacy
        self.revocations = revocations
        self.clock = clock
    }

    /// A save that wrote the shared item and read back something else. Nothing was lost: the
    /// item that was there before, if any, is what every device still reads.
    public struct NotKept: Error, Hashable, Sendable {}

    // MARK: TokenStore

    public var sharedStore: SharedTokenStore? { self }

    /// The shared item with this device's access token, else the old per-device item. When
    /// the shared group is out of reach and there is no old item either, it throws rather
    /// than answer nil, because nil would mark the account signed out.
    public func token(for account: AccountID) throws -> StoredToken? {
        var unavailable = false
        do {
            if let item = try sharedItem(account.sub) {
                remember(item.refreshToken, for: account.sub)
                var token = StoredToken(
                    refreshToken: item.refreshToken, email: item.email, scope: item.scope)
                if let access = try? deviceAccess(account.sub),
                    access.refreshFingerprint == Self.fingerprint(item.refreshToken)
                {
                    token.accessToken = access.accessToken
                    token.accessExpiry = access.accessExpiry
                }
                return token
            }
        } catch is KeychainUnavailable {
            unavailable = true
        }
        guard let data = try legacy.read(account.sub) else {
            if unavailable { throw KeychainUnavailable() }
            return nil
        }
        let token = try StoredToken(encoded: data)
        remember(token.refreshToken, for: account.sub)
        return token
    }

    /// A sign-in: adds the account to the shared keychain, or replaces the item when this is
    /// another refresh token, reading it back before trusting it; the access token goes to
    /// this device's own item. A build that cannot reach the shared group keeps the whole
    /// token in the old per-device item, as before.
    public func signIn(_ token: StoredToken, for account: AccountID) throws {
        try signIn(token, for: account, addedAt: nil)
    }

    func signIn(_ token: StoredToken, for account: AccountID, addedAt: Date?) throws {
        do {
            let existing = try currentItem(account.sub)
            let changed =
                existing.map {
                    $0.refreshToken != token.refreshToken || $0.email != token.email
                        || $0.grantedScopes != token.grantedScopes
                } ?? true
            if changed {
                try put(
                    token, sub: account.sub,
                    addedAt: existing?.addedAt ?? addedAt ?? Self.wholeSeconds(clock()))
                // The shared item now serves this account, so an old item would only be read
                // in its place if the shared one ever went missing.
                if (try? legacy.accounts().contains(account.sub)) == true {
                    try? legacy.delete(account.sub)
                }
            } else {
                remember(token.refreshToken, for: account.sub)
                writeDeviceAccess(token, sub: account.sub)
            }
            return
        } catch is KeychainUnavailable {}
        try legacy.write(try token.encoded(), account: account.sub, label: Self.label(token.email))
        remember(token.refreshToken, for: account.sub)
    }

    /// A refreshed access token. It goes to this device's own item and never creates the
    /// shared one: an account with no shared item was removed (here or on another device) or
    /// has not been moved yet, and a refresh that finishes late must not undo either. The
    /// shared item changes only for a refresh token this process has never seen, which is one
    /// Google sent instead of the old one, and only while the item is still there.
    public func save(_ token: StoredToken, for account: AccountID) throws {
        let sub = account.sub
        let existing: AccountItem?
        do {
            existing = try currentItem(sub)
        } catch is KeychainUnavailable {
            try updateLegacy(token, sub: sub)
            return
        }
        guard let existing else {
            try updateLegacy(token, sub: sub)
            return
        }
        if existing.refreshToken != token.refreshToken {
            // One this process read before is stale, because another device has since signed
            // the account in again.
            guard !isKnown(token.refreshToken, for: sub) else { return }
            let item = AccountItem(
                sub: sub, email: existing.email, refreshToken: token.refreshToken,
                scope: token.scope, addedAt: existing.addedAt)
            let data = try item.encoded()
            guard try shared.replace(data, account: sub) else { return }
            guard try shared.read(sub) == data else { throw NotKept() }
        }
        remember(token.refreshToken, for: sub)
        writeDeviceAccess(token, sub: sub)
    }

    /// Removes the account everywhere: the shared item (iCloud Keychain carries the deletion
    /// to every device), this device's access token and any old item. Every delete is tried;
    /// the first failure is thrown after.
    public func removeToken(for account: AccountID) throws {
        var failure: (any Error)?
        for backend in [shared, device, legacy] {
            do {
                try backend.delete(account.sub)
            } catch is KeychainUnavailable {
            } catch {
                failure = failure ?? error
            }
        }
        _ = known.withLock { $0.removeValue(forKey: account.sub) }
        if let failure { throw failure }
    }

    // MARK: The account list

    /// Every account in the shared keychain, or nil when this build cannot reach it. Throws
    /// when the keychain refuses for now (before the first unlock) or an item does not decode,
    /// so a caller never mistakes an unreadable list for an empty one.
    public func accountItems() throws -> [AccountItem]? {
        let names: [String]
        do {
            names = try shared.accounts()
        } catch is KeychainUnavailable {
            return nil
        }
        return try names.compactMap { name in
            try shared.read(name).map(AccountItem.init(encoded:))
        }
    }

    /// Whether `token(for:)` serves this account from an old item that is due to move into
    /// the shared keychain: it has no shared item, and the shared group can be reached. A
    /// build that cannot reach the group keeps its old items for good and has nothing to move.
    public func readsOldItem(_ account: AccountID) -> Bool {
        guard (try? legacy.accounts().contains(account.sub)) == true,
            (try? shared.accounts()) != nil
        else { return false }
        return ((try? sharedItem(account.sub)) ?? nil) == nil
    }

    /// The accounts that still have an old per-device item.
    public func legacyAccounts() throws -> Set<AccountID> {
        Set(try legacy.accounts().map(AccountID.init(sub:)))
    }

    /// Settles the old per-device items once a refresh has told whether Google accepts them.
    ///
    /// - `accepted`: accounts whose refresh token Google took in a refresh just now, with when
    ///   each was added. Each old item moves into the shared keychain: copy, read the copy
    ///   back, and only then delete the old item. An account another device already moved
    ///   keeps that device's item. Any failure leaves the old item where it is for the next
    ///   refresh, so nothing here can sign an account out.
    /// - `refused`: accounts signed out here, with the refresh token Google refused. An old
    ///   item still holding that token is deleted and never copied, because copying it would
    ///   hand the refusal to every device.
    ///
    /// An old item is not copied before Google has accepted it: a token revoked on a device
    /// that moved first would otherwise come back into iCloud Keychain and sit on every device
    /// as an account that cannot sign in. Until then `token(for:)` reads the old item itself.
    /// An account that is not listed, or only signed out, is left alone. Returns the accounts
    /// moved.
    public func settleLegacyItems(
        accepted: [AccountID: Date], refused: [AccountID: String]
    ) -> [AccountID] {
        guard let names = try? legacy.accounts(), !names.isEmpty else { return [] }
        let reachable = (try? shared.accounts()) != nil
        var moved: [AccountID] = []
        for name in names {
            let id = AccountID(sub: name)
            if let refusedToken = refused[id] {
                if let data = try? legacy.read(name), let token = try? StoredToken(encoded: data),
                    token.refreshToken == refusedToken
                {
                    try? legacy.delete(name)
                }
                continue
            }
            guard reachable, let addedAt = accepted[id] else { continue }
            do {
                guard let data = try legacy.read(name) else { continue }
                let token = try StoredToken(encoded: data)
                if try sharedItem(name) == nil {
                    try put(token, sub: name, addedAt: addedAt)
                }
                try legacy.delete(name)
                remember(token.refreshToken, for: name)
                moved.append(id)
            } catch {
                continue
            }
        }
        return moved
    }

    /// Drops what this device keeps for an account another device removed: its access token
    /// and any old item. The shared item is already gone and is not touched, so an account
    /// added back in the meantime survives.
    public func forgetOnThisDevice(_ account: AccountID) {
        try? device.delete(account.sub)
        try? legacy.delete(account.sub)
        _ = known.withLock { $0.removeValue(forKey: account.sub) }
    }

    // MARK: Revocation

    /// A grant at Google that still has to be revoked: the refresh token of an account that
    /// was removed here.
    public struct PendingRevocation: Hashable, Sendable {
        public let account: AccountID
        public let token: StoredToken
    }

    /// Keeps the refresh token in a device-only keychain item until Google has confirmed the
    /// revocation (`revocationDone`), so a removal made offline is retried and the grant does
    /// not outlive the account. The token is held in the keychain alone, never in a file.
    /// False when the item could not be written: the caller then revokes at once and has
    /// nothing to retry.
    public func queueRevocation(_ token: StoredToken, for account: AccountID) -> Bool {
        guard let revocations else { return false }
        var token = token
        token.accessToken = nil
        token.accessExpiry = nil
        do {
            let data = try token.encoded()
            try revocations.write(data, account: account.sub, label: Self.label(token.email))
            return try revocations.read(account.sub) == data
        } catch {
            return false
        }
    }

    /// Every revocation still waiting on Google.
    public func pendingRevocations() -> [PendingRevocation] {
        guard let revocations, let names = try? revocations.accounts() else { return [] }
        return names.compactMap { name in
            guard let data = try? revocations.read(name),
                let token = try? StoredToken(encoded: data)
            else { return nil }
            return PendingRevocation(account: AccountID(sub: name), token: token)
        }
    }

    /// Google confirmed the revocation, or the removal that queued it did not happen.
    public func revocationDone(for account: AccountID) {
        try? revocations?.delete(account.sub)
    }

    // MARK: Inside

    /// Writes the shared item and reads it back; the caller decides whether it may exist.
    private func put(_ token: StoredToken, sub: String, addedAt: Date) throws {
        let item = AccountItem(
            sub: sub, email: token.email, refreshToken: token.refreshToken, scope: token.scope,
            addedAt: addedAt)
        let data = try item.encoded()
        try shared.write(data, account: sub, label: Self.label(item.email))
        guard try shared.read(sub) == data else { throw NotKept() }
        remember(token.refreshToken, for: sub)
        writeDeviceAccess(token, sub: sub)
    }

    /// Keeps the whole token in the old per-device item, when there is one: a refresh updates
    /// it in place and never adds it.
    private func updateLegacy(_ token: StoredToken, sub: String) throws {
        guard (try legacy.accounts()).contains(sub) else { return }
        try legacy.write(try token.encoded(), account: sub, label: Self.label(token.email))
        remember(token.refreshToken, for: sub)
    }

    /// The shared item, nil when there is none or it does not decode (a damaged item is
    /// replaced by the next sign-in). Throws `KeychainUnavailable` when the group is out of
    /// reach and the keychain's own error when it refuses for now.
    private func currentItem(_ sub: String) throws -> AccountItem? {
        do {
            return try sharedItem(sub)
        } catch is DecodingError {
            return nil
        }
    }

    private func sharedItem(_ sub: String) throws -> AccountItem? {
        try shared.read(sub).map(AccountItem.init(encoded:))
    }

    private func deviceAccess(_ sub: String) throws -> DeviceAccess? {
        try device.read(sub).map { try DayJSON.decoder().decode(DeviceAccess.self, from: $0) }
    }

    /// Caches the access token on this device. A failure only costs a refresh call later.
    private func writeDeviceAccess(_ token: StoredToken, sub: String) {
        guard let accessToken = token.accessToken, let accessExpiry = token.accessExpiry else {
            return
        }
        let access = DeviceAccess(
            accessToken: accessToken, accessExpiry: accessExpiry,
            refreshFingerprint: Self.fingerprint(token.refreshToken))
        guard let data = try? DayJSON.encoder().encode(access) else { return }
        try? device.write(data, account: sub, label: Self.label(token.email))
    }

    private func remember(_ refreshToken: String, for sub: String) {
        known.withLock { _ = $0[sub, default: []].insert(refreshToken) }
    }

    private func isKnown(_ refreshToken: String, for sub: String) -> Bool {
        known.withLock { $0[sub]?.contains(refreshToken) ?? false }
    }

    /// The item's dates are written in whole seconds, so one read back equals what was made.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// What Keychain Access shows in its Name column on the Mac.
    static func label(_ email: String) -> String {
        "Day: \(email)"
    }

    /// A refresh token's fingerprint: enough to tell two tokens apart, useless for anything
    /// else, so it can sit beside an access token and in a plain file.
    public static func fingerprint(_ refreshToken: String) -> String {
        String(PKCE.base64URL(Data(SHA256.hash(data: Data(refreshToken.utf8)))).prefix(22))
    }
}

extension AccountItem {
    var grantedScopes: Set<String> {
        Set(scope.split(separator: " ").map(String.init))
    }
}
