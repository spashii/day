import Foundation

/// What a pass over the shared keychain changed in this device's account list.
public struct AccountChanges: Hashable, Sendable {
    /// Added on another device; listed here now, with no calendars until the next refresh.
    public var added: [AccountID] = []
    /// Removed on another device; dropped here with their cache and settings.
    public var removed: [AccountID] = []
    /// Signed out here and signed in again on another device: the shared item holds a new
    /// refresh token, so this device tries again with it.
    public var restored: [AccountID] = []

    public init() {}

    /// Whether the account list on screen changed.
    public var changesAccounts: Bool {
        !added.isEmpty || !removed.isEmpty || !restored.isEmpty
    }
}

/// What this device remembers about the shared items, in `account-items.json` beside the
/// cache. Never synced: each device keeps its own.
struct AccountItemsFile: Codable, Hashable, Sendable {
    static let fileName = "account-items.json"

    /// Accounts this device has seen in the shared keychain. Only these leave when their item
    /// is gone: an account that never had one here (a grant without calendar access, a build
    /// that keeps tokens per device) is never mistaken for one removed elsewhere.
    var seen: Set<String> = []
    /// For each account signed out here, the fingerprint of the refresh token Google refused,
    /// written by the refresh that signed it out (`SyncEngine.performRefresh`), so a sign-in
    /// elsewhere that lands before this device looks again still differs from it. Another
    /// token in the shared item means another device signed the account in again.
    var refused: [String: String] = [:]
}

/// The account list as the shared keychain says it should be, decided without touching any
/// file, so every rule is tested on its own.
enum AccountRoster {
    struct Outcome: Hashable {
        var accounts: [Account]
        var file: AccountItemsFile
        var changes: AccountChanges
    }

    /// - `accounts`: this device's list, in the order added.
    /// - `items`: every shared item, read in full.
    /// - `legacy`: accounts with an old per-device item still on this device.
    static func reconcile(
        accounts: [Account], items: [AccountItem], legacy: Set<AccountID>,
        file: AccountItemsFile
    ) -> Outcome {
        let bySub = Dictionary(items.map { ($0.sub, $0) }, uniquingKeysWith: { first, _ in first })
        var file = file
        var changes = AccountChanges()
        var next: [Account] = []
        for var account in accounts {
            let sub = account.id.sub
            guard let item = bySub[sub] else {
                // Gone from the shared keychain after this device saw it there, with no old item
                // to fall back on: another device removed it. Anything else stays as it is.
                if file.seen.contains(sub), !legacy.contains(account.id) {
                    changes.removed.append(account.id)
                    file.seen.remove(sub)
                    file.refused[sub] = nil
                } else {
                    next.append(account)
                }
                continue
            }
            file.seen.insert(sub)
            // Google's address can change; the item carries the newest sign-in's.
            account.email = item.email
            if account.signedOut {
                // Only a token other than the refused one is worth trying. An account signed
                // out before any fingerprint was kept has nothing to compare, so it tries the
                // shared token once; a refusal records its fingerprint and ends the trying.
                let current = SharedTokenStore.fingerprint(item.refreshToken)
                if file.refused[sub] != current, item.grantsCalendar {
                    account.signedOut = false
                    file.refused[sub] = nil
                    changes.restored.append(account.id)
                }
            } else {
                file.refused[sub] = nil
            }
            next.append(account)
        }
        let listed = Set(next.map(\.id.sub))
        let joining = items.filter { !listed.contains($0.sub) }
            .sorted { ($0.addedAt, $0.sub) < ($1.addedAt, $1.sub) }
        for item in joining {
            next.append(
                Account(
                    id: item.id, email: item.email, addedAt: item.addedAt,
                    signedOut: !item.grantsCalendar))
            file.seen.insert(item.sub)
            changes.added.append(item.id)
        }
        return Outcome(accounts: next, file: file, changes: changes)
    }
}

// MARK: - The engine's side

extension SyncEngine {
    /// Brings this device's accounts in line with the shared keychain, on launch, on return to
    /// the front and before every refresh. An account added on another device joins the list,
    /// one removed on another device leaves with its cache and toggles, and one signed out
    /// here comes back when another device signed it in again. Never deletes a shared item
    /// and never revokes anything: that is only for the person removing an account on this
    /// device. The old per-device items are not touched here: they move once a refresh has
    /// shown that Google accepts them (`settleLegacyItems`), and an account with one is never
    /// taken for removed.
    ///
    /// Nothing changes when the token store is not the shared one, when this build cannot
    /// reach the shared group, or when the keychain cannot be read (before the first unlock):
    /// an unreadable list is never taken for an empty one.
    public func reconcileAccounts() -> AccountChanges {
        guard let store = tokens.sharedStore else { return AccountChanges() }
        let accounts = cache.read([Account].self, from: CacheFile.accounts) ?? []
        guard let items = try? store.accountItems(), let legacy = try? store.legacyAccounts()
        else { return AccountChanges() }
        let file = cache.read(AccountItemsFile.self, from: AccountItemsFile.fileName)
            ?? AccountItemsFile()
        let outcome = AccountRoster.reconcile(
            accounts: accounts, items: items, legacy: legacy, file: file)
        let changes = outcome.changes

        if outcome.file != file {
            try? cache.write(outcome.file, to: AccountItemsFile.fileName)
        }
        guard outcome.accounts != accounts else { return changes }
        do {
            try cache.write(outcome.accounts, to: CacheFile.accounts)
        } catch {
            // The list on disk is as it was; the next pass decides again.
            return AccountChanges()
        }
        if !changes.removed.isEmpty {
            var visibility = storedVisibility()
            for id in changes.removed {
                cache.removeAccount(id)
                visibility.forget(id)
                store.forgetOnThisDevice(id)
            }
            try? cache.write(visibility, to: CacheFile.visibility)
        }
        writeWidgetSnapshot(force: true)
        return changes
    }

    /// The person's calendar toggles as they are on disk.
    public nonisolated func storedVisibility() -> CalendarVisibility {
        cache.read(CalendarVisibility.self, from: CacheFile.visibility) ?? CalendarVisibility()
    }

    /// Replaces every calendar toggle at once, with what another device chose, and rewrites
    /// the widget snapshot from them.
    public func replaceVisibility(_ visibility: CalendarVisibility) throws {
        guard visibility != storedVisibility() else { return }
        try cache.write(visibility, to: CacheFile.visibility)
        writeWidgetSnapshot(force: true)
    }

    /// The account's tokens as stored now, or nil when there are none or the keychain cannot
    /// be read. Read before removing an account, for the push client and the revocation.
    public nonisolated func storedToken(for account: AccountID) -> StoredToken? {
        try? tokens.token(for: account)
    }

    /// Notes which refresh token Google refused for each account a refresh just signed out
    /// (`AccountItemsFile.refused`). Written in the same step as the sign-out, before the list
    /// says signed out.
    func noteRefused(_ refused: [(account: AccountID, refreshToken: String)]) {
        guard tokens.sharedStore != nil, !refused.isEmpty else { return }
        var file = cache.read(AccountItemsFile.self, from: AccountItemsFile.fileName)
            ?? AccountItemsFile()
        for (account, refreshToken) in refused {
            file.refused[account.sub] = SharedTokenStore.fingerprint(refreshToken)
        }
        try? cache.write(file, to: AccountItemsFile.fileName)
    }

    /// Moves the old per-device items of accounts Google just accepted into the shared
    /// keychain, and deletes those of accounts it refused (`SharedTokenStore.settleLegacyItems`).
    /// Accepted means a refresh request with that token was answered during this refresh, not
    /// that a calendar call worked: an access token can outlive a revoked grant.
    func settleLegacyItems(
        authorizers: [AccountID: AccountAuthorizer], refreshTokens: [AccountID: String],
        problems: [AccountID: AccountProblem], newlySignedOut: [AccountID]
    ) async {
        guard let store = tokens.sharedStore else { return }
        var accepted: [AccountID] = []
        for (id, authorizer) in authorizers where problems[id] != .signedOut {
            if await authorizer.refreshAccepted { accepted.append(id) }
        }
        // No suspension from here to the copy, so an account removed while the refresh ran is
        // not on the list read here and is not put back.
        let listed = Dictionary(
            (cache.read([Account].self, from: CacheFile.accounts) ?? [])
                .filter { !$0.signedOut }.map { ($0.id, $0.addedAt) },
            uniquingKeysWith: { first, _ in first })
        var refused: [AccountID: String] = [:]
        for id in newlySignedOut { refused[id] = refreshTokens[id] }
        let moved = store.settleLegacyItems(
            accepted: listed.filter { accepted.contains($0.key) }, refused: refused)
        // An account now in the shared keychain counts as seen there at once, so one removed
        // on another device before the next pass over the keychain still leaves this one.
        guard !moved.isEmpty else { return }
        var file = cache.read(AccountItemsFile.self, from: AccountItemsFile.fileName)
            ?? AccountItemsFile()
        file.seen.formUnion(moved.map(\.sub))
        try? cache.write(file, to: AccountItemsFile.fileName)
    }

    /// Ends the grant at Google, so the refresh token stops working on every device. One try;
    /// `queueRevocation` keeps the token for more. Returns whether Google confirmed.
    @discardableResult
    public nonisolated func revoke(_ token: StoredToken) async -> Bool {
        guard let auth else { return false }
        return (try? await auth.with(retry: .once).revoke(token)) != nil
    }

    /// Keeps the account's refresh token in a device-only keychain item until Google has
    /// confirmed the revocation, so a removal made offline is retried. Call before the
    /// account's items are deleted. False when the item could not be kept; revoke at once then.
    public nonisolated func queueRevocation(_ token: StoredToken, for account: AccountID) -> Bool {
        tokens.sharedStore?.queueRevocation(token, for: account) ?? false
    }

    /// Drops the queued revocation of an account that was not removed after all.
    public nonisolated func cancelRevocation(for account: AccountID) {
        tokens.sharedStore?.revocationDone(for: account)
    }

    /// Tries every queued revocation, on launch, after each refresh and right after a removal.
    /// A token Google confirms (200) or no longer knows (400) leaves the queue. An account
    /// that is signed in again is skipped: its new sign-in may share the grant, and revoking
    /// would sign it out. Its queued token is replaced by the next removal.
    public func retryRevocations() async {
        guard let store = tokens.sharedStore, auth != nil, !retryingRevocations else {
            return
        }
        retryingRevocations = true
        defer { retryingRevocations = false }
        for pending in store.pendingRevocations() {
            let listed = (cache.read([Account].self, from: CacheFile.accounts) ?? [])
                .contains { $0.id == pending.account }
            let signedIn = ((try? store.token(for: pending.account)) ?? nil) != nil
            if listed || signedIn { continue }
            if await revoke(pending.token) { store.revocationDone(for: pending.account) }
        }
    }
}

// MARK: - Revocation

extension GoogleAuth {
    static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Revokes the grant behind `token` (https://developers.google.com/identity/protocols/oauth2/native-app#tokenrevoke).
    /// Google answers 400 for a token it no longer knows, which is the outcome wanted too.
    public func revoke(_ token: StoredToken) async throws {
        var request = URLRequest(url: GoogleAuth.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(GoogleAuth.formEncoded(["token": token.refreshToken]).utf8)
        let (_, response) = try await GoogleHTTP.send(request, using: transport, retry: retry)
        guard response.statusCode == 200 || response.statusCode == 400 else {
            throw OAuthError.tokenEndpoint(status: response.statusCode, error: nil)
        }
    }
}
