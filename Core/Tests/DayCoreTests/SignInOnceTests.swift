import Foundation
import Synchronization
import Testing

@testable import DayCore

/// Sign in once: the shared keychain items that are the account list, the move from each
/// device's old items, what one device's change does on another, and the calendar settings
/// in the iCloud key-value store. Keychains and the cloud are in memory; two devices share
/// one `MemoryKeychain` and one `MemorySettingsCloud` the way two devices on one Apple ID
/// share iCloud. Google is the recorded, invented script from `DecodingTests`.
struct SignInOnceTests {
    typealias Recorded = DecodingTests.Recorded
    typealias Stub = DecodingTests.Stub
    typealias Shared = DecodingTests.Shared

    static let gmail = DecodingTests.gmail
    static let acme = DecodingTests.acme

    /// What the apps give the engine: a store that wraps the shared one and hands it on.
    struct Wrapper: TokenStore {
        let store: SharedTokenStore
        func token(for account: AccountID) throws -> StoredToken? { try store.token(for: account) }
        func save(_ token: StoredToken, for account: AccountID) throws { try store.save(token, for: account) }
        func signIn(_ token: StoredToken, for account: AccountID) throws { try store.signIn(token, for: account) }
        func removeToken(for account: AccountID) throws { try store.removeToken(for: account) }
        var sharedStore: SharedTokenStore? { store }
    }

    /// One device: its own folder and its own device-only and old items, with the shared
    /// items it is given.
    final class Device: Sendable {
        let folder: URL
        let cache: CacheDirectory
        let shared: MemoryKeychain
        let local = MemoryKeychain()
        let legacy: MemoryKeychain
        let revocations = MemoryKeychain()
        let store: SharedTokenStore
        let stub = Stub(Recorded.google())
        let clock: Shared<Date>
        let engine: SyncEngine
        let fixture: Fixture

        /// With `unreachable`, the build does not claim the shared group and is never asked
        /// for it (`UnavailableKeychain`).
        init(
            shared: MemoryKeychain, legacy: MemoryKeychain = MemoryKeychain(), unreachable: Bool = false,
            wrapped: Bool = false
        ) throws {
            fixture = try DecodingTests.fixture()
            folder = FileManager.default.temporaryDirectory.appending(path: "day-signin-\(UUID().uuidString)")
            cache = CacheDirectory(url: folder)
            self.shared = shared
            self.legacy = legacy
            let clock = Shared(fixture.now)
            self.clock = clock
            store = SharedTokenStore(
                shared: unreachable ? UnavailableKeychain() : shared,
                device: unreachable ? UnavailableKeychain() : local, legacy: legacy,
                revocations: revocations, clock: { clock.value })
            engine = SyncEngine(
                auth: GoogleAuth(clientID: Recorded.clientID, transport: stub, retry: .noWait),
                tokens: wrapped ? Wrapper(store: store) : store, cache: cache, api: CalendarAPI(transport: stub, retry: .noWait),
                calendar: fixture.calendar, clock: { clock.value })
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
        }

        var accounts: [Account] {
            engine.load().accounts
        }

        func list(_ accounts: [Account]) throws {
            try cache.write(accounts, to: CacheFile.accounts)
        }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: cache.fileURL(name).path(percentEncoded: false))
        }
    }

    static func token(_ refresh: String, email: String = "you@gmail.com", access: String? = nil, expiry: Date? = nil) -> StoredToken {
        StoredToken(refreshToken: refresh, accessToken: access, accessExpiry: expiry, email: email, scope: Recorded.fullScope)
    }

    static func item(_ data: Data?) throws -> AccountItem {
        try AccountItem(encoded: try #require(data))
    }

    // MARK: Moving the old items

    /// A later hour, when the access token the old item held has run out and a refresh asks
    /// Google about the refresh token itself.
    static func hoursLater(_ device: Device) {
        device.clock.update { $0 = $0.addingTimeInterval(2 * 3600) }
    }

    @Test func theMacsOldItemsMoveIntoTheSharedKeychainOnceGoogleAcceptsThem() async throws {
        let legacy = MemoryKeychain()
        try legacy.write(Self.token("refresh-gmail").encoded(), account: Self.gmail.sub, label: "")
        try legacy.write(Self.token("refresh-acme", email: "you@acme.com").encoded(), account: Self.acme.sub, label: "")
        let mac = try Device(shared: MemoryKeychain(), legacy: legacy)
        try mac.list(mac.fixture.accounts)

        // Nothing moves before Google has said anything, and nobody is signed out meanwhile.
        let changes = await mac.engine.reconcileAccounts()
        #expect(!changes.changesAccounts)
        #expect(legacy.items.count == 2)
        #expect(mac.shared.items.isEmpty)
        #expect(try mac.store.token(for: Self.gmail)?.refreshToken == "refresh-gmail")

        let report = await mac.engine.refresh()
        #expect(report.newlySignedOut.isEmpty)
        #expect(report.data.accounts.allSatisfy { !$0.signedOut })
        #expect(legacy.items.isEmpty)
        let moved = try Self.item(mac.shared.items[Self.gmail.sub])
        #expect(moved.refreshToken == "refresh-gmail")
        #expect(moved.email == "you@gmail.com")
        #expect(moved.sub == Self.gmail.sub)
        #expect(moved.addedAt == mac.fixture.accounts.first { $0.id == Self.gmail }?.addedAt)
        // The access token Google just gave stays on this device and is still used.
        let token = try #require(try mac.store.token(for: Self.gmail))
        #expect(token.refreshToken == "refresh-gmail")
        #expect(token.accessToken == "access-gmail")
        #expect(mac.accounts == mac.fixture.accounts)
    }

    @Test func anOldItemStaysUntilItsCopyReadsBack() async throws {
        let legacy = MemoryKeychain()
        try legacy.write(Self.token("refresh-gmail").encoded(), account: Self.gmail.sub, label: "")
        let shared = MemoryKeychain()
        shared.keepsWrites = false
        let mac = try Device(shared: shared, legacy: legacy)
        try mac.list(mac.fixture.accounts.filter { $0.id == Self.gmail })

        _ = await mac.engine.refresh()
        #expect(legacy.items[Self.gmail.sub] != nil)
        #expect(try mac.store.token(for: Self.gmail)?.refreshToken == "refresh-gmail")
        #expect(mac.accounts.map(\.id) == [Self.gmail])

        shared.keepsWrites = true
        Self.hoursLater(mac)
        let report = await mac.engine.refresh()
        #expect(report.newlySignedOut.isEmpty)
        #expect(legacy.items.isEmpty)
        #expect(try Self.item(shared.items[Self.gmail.sub]).refreshToken == "refresh-gmail")
        #expect(mac.accounts.map(\.id) == [Self.gmail])
    }

    @Test func aValidAccessTokenDoesNotStandInForGoogleTakingTheRefreshToken() async throws {
        let legacy = MemoryKeychain()
        let mac = try Device(shared: MemoryKeychain(), legacy: legacy)
        // The access token is one Google's stub accepts and has an hour left, so the calendar
        // calls need no token call. The refresh token is still asked of Google before it moves.
        try legacy.write(
            Self.token("refresh-gmail", access: "access-gmail", expiry: mac.fixture.now.addingTimeInterval(3600)).encoded(),
            account: Self.gmail.sub, label: "")
        try mac.list(mac.fixture.accounts.filter { $0.id == Self.gmail })

        let report = await mac.engine.refresh()
        #expect(report.outcome == .current)
        let asked = mac.stub.requests.filter { $0.url?.path(percentEncoded: false) == "/token" }
        #expect(asked.count == 1)
        #expect(Recorded.form(try #require(asked.first))["refresh_token"] == "refresh-gmail")
        #expect(legacy.items.isEmpty)
        #expect(try Self.item(mac.shared.items[Self.gmail.sub]).refreshToken == "refresh-gmail")

        // Once moved, a valid access token needs no token call at all.
        let again = await mac.engine.refresh()
        #expect(again.outcome == .current)
        let tokenCalls = mac.stub.requests.filter { $0.url?.path(percentEncoded: false) == "/token" }
        #expect(tokenCalls.count == 1)
    }

    @Test func aRevokedTokenWithAnAccessTokenThatStillWorksIsNeverCopied() async throws {
        let legacy = MemoryKeychain()
        let mac = try Device(shared: MemoryKeychain(), legacy: legacy)
        try legacy.write(
            Self.token("refresh-revoked", access: "access-gmail", expiry: mac.fixture.now.addingTimeInterval(3600)).encoded(),
            account: Self.gmail.sub, label: "")
        try mac.list(mac.fixture.accounts.filter { $0.id == Self.gmail })

        let report = await mac.engine.refresh()
        #expect(report.newlySignedOut == [Self.gmail])
        #expect(mac.shared.items.isEmpty)
        #expect(legacy.items.isEmpty)
    }

    @Test func aBuildWithoutTheSharedGroupKeepsTokensPerDeviceAsBefore() async throws {
        let legacy = MemoryKeychain()
        let now = try DecodingTests.fixture().now
        try legacy.write(
            Self.token("refresh-gmail", access: "access-gmail", expiry: now.addingTimeInterval(3600)).encoded(),
            account: Self.gmail.sub, label: "")
        // A build that never asks the keychain for the group, and one the keychain refuses.
        for refused in [true, false] {
            let shared = MemoryKeychain()
            shared.isUnavailable = true
            let mac =
                refused
                ? try Device(shared: shared, legacy: legacy)
                : try Device(shared: MemoryKeychain(), legacy: legacy, unreachable: true)
            try mac.list(mac.fixture.accounts)

            let changes = await mac.engine.reconcileAccounts()
            #expect(changes == AccountChanges())
            #expect(mac.accounts == mac.fixture.accounts)
            #expect(try mac.store.token(for: Self.gmail)?.refreshToken == "refresh-gmail")
            #expect(try mac.store.accountItems() == nil)

            // It never asks Google to prove a token it has nowhere to move.
            _ = await mac.engine.refresh()
            let tokenCalls = mac.stub.requests.filter { $0.url?.path(percentEncoded: false) == "/token" }
            #expect(tokenCalls.isEmpty)

            // A sign-in and a refresh land in the old item, access token and all.
            try mac.store.signIn(Self.token("refresh-acme", email: "you@acme.com", access: "access-acme", expiry: mac.fixture.now), for: Self.acme)
            #expect(try StoredToken(encoded: #require(legacy.items[Self.acme.sub])).accessToken == "access-acme")
            try mac.store.save(Self.token("refresh-acme", email: "you@acme.com", access: "access-acme-2", expiry: mac.fixture.now), for: Self.acme)
            #expect(try StoredToken(encoded: #require(legacy.items[Self.acme.sub])).accessToken == "access-acme-2")
            try mac.store.removeToken(for: Self.acme)
            #expect(legacy.items[Self.acme.sub] == nil)
            // A refresh that lands after the removal adds nothing.
            try mac.store.save(Self.token("refresh-acme", email: "you@acme.com", access: "access-acme-3", expiry: mac.fixture.now), for: Self.acme)
            #expect(legacy.items[Self.acme.sub] == nil)
            // An account it holds no item for reads as a keychain failure, never as signed out.
            #expect(throws: KeychainUnavailable.self) { try mac.store.token(for: Self.acme) }
        }
    }

    @Test func anAccountAnotherDeviceMovedFirstKeepsThatDevicesItem() async throws {
        let shared = MemoryKeychain()
        let phoneItem = AccountItem(
            sub: Self.gmail.sub, email: "you@gmail.com", refreshToken: "refresh-gmail",
            scope: Recorded.fullScope, addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try shared.write(phoneItem.encoded(), account: Self.gmail.sub, label: "")
        let legacy = MemoryKeychain()
        try legacy.write(Self.token("refresh-old").encoded(), account: Self.gmail.sub, label: "")
        let mac = try Device(shared: shared, legacy: legacy)
        try mac.list(mac.fixture.accounts.filter { $0.id == Self.gmail })

        let report = await mac.engine.refresh()
        #expect(report.newlySignedOut.isEmpty)
        #expect(legacy.items.isEmpty)
        #expect(try Self.item(shared.items[Self.gmail.sub]) == phoneItem)
    }

    @Test func anOldItemOfAnAccountSignedOutHereOrNotListedIsNotCopied() async throws {
        let legacy = MemoryKeychain()
        try legacy.write(Self.token("refresh-refused").encoded(), account: Self.gmail.sub, label: "")
        try legacy.write(Self.token("refresh-acme", email: "you@acme.com").encoded(), account: Self.acme.sub, label: "")
        let mac = try Device(shared: MemoryKeychain(), legacy: legacy)
        var gmail = try #require(mac.fixture.accounts.first { $0.id == Self.gmail })
        gmail.signedOut = true
        try mac.list([gmail])

        _ = await mac.engine.reconcileAccounts()
        _ = await mac.engine.refresh()
        #expect(mac.shared.items.isEmpty)
        #expect(legacy.items.count == 2)
        #expect(mac.accounts == [gmail])
    }

    @Test func aTokenGoogleRefusesIsNeverCopiedAndItsOldItemGoes() async throws {
        let legacy = MemoryKeychain()
        try legacy.write(Self.token("refresh-revoked").encoded(), account: Self.gmail.sub, label: "")
        try legacy.write(Self.token("refresh-acme", email: "you@acme.com").encoded(), account: Self.acme.sub, label: "")
        let phone = try Device(shared: MemoryKeychain(), legacy: legacy)
        try phone.list(phone.fixture.accounts)

        let report = await phone.engine.refresh()
        #expect(report.newlySignedOut == [Self.gmail])
        // The refused token reaches no other device; the accepted one moves.
        #expect(try phone.store.accountItems()?.map(\.sub) == [Self.acme.sub])
        #expect(legacy.items.isEmpty)
        #expect(phone.accounts.first { $0.id == Self.gmail }?.signedOut == true)
        #expect(phone.accounts.first { $0.id == Self.acme }?.signedOut == false)
    }

    @Test func aRemovalOnAnUpgradedDeviceIsNotUndoneByADeviceStillOnTheOldBuild() async throws {
        // The Mac moved on; the phone is still on the build whose items are per device.
        let shared = MemoryKeychain()
        let mac = try Device(shared: shared)
        try mac.list(mac.fixture.accounts.filter { $0.id == Self.gmail })
        try mac.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)
        // The Mac removes the account: the shared item goes, and Google revokes the grant.
        try await mac.engine.removeAccount(Self.gmail)
        #expect(shared.items.isEmpty)

        let legacy = MemoryKeychain()
        try legacy.write(Self.token("refresh-revoked").encoded(), account: Self.gmail.sub, label: "")
        let phone = try Device(shared: shared, legacy: legacy)
        try phone.list(phone.fixture.accounts.filter { $0.id == Self.gmail })
        let changes = await phone.engine.reconcileAccounts()
        #expect(!changes.changesAccounts)
        _ = await phone.engine.refresh()

        // Nothing came back into iCloud Keychain, so the Mac never lists the account again.
        #expect(shared.items.isEmpty)
        let again = await mac.engine.reconcileAccounts()
        #expect(again.added.isEmpty)
        #expect(mac.accounts.isEmpty)
    }

    // MARK: Across devices

    @Test func anAccountAddedOnOneDeviceAppearsOnTheOther() async throws {
        let shared = MemoryKeychain()
        let mac = try Device(shared: shared)
        let phone = try Device(shared: shared)
        let request = try mac.engine.authorizationRequest()
        let callback = URL(string: "\(request.callbackScheme):/oauth2redirect?state=\(request.state)&code=code-acme")!
        let added = try await mac.engine.completeSignIn(request, callback: callback)

        phone.clock.update { $0 = $0.addingTimeInterval(600) }
        let changes = await phone.engine.reconcileAccounts()
        #expect(changes.added == [Self.acme])
        #expect(phone.accounts == [added])
        let token = try #require(try phone.store.token(for: Self.acme))
        #expect(token.refreshToken == "refresh-acme")
        // The Mac's access token stayed on the Mac.
        #expect(token.accessToken == nil)
        #expect(try mac.store.token(for: Self.acme)?.accessToken == "access-acme")

        let report = await phone.engine.refresh()
        #expect(report.outcome == .current)
        #expect(report.data.calendars.contains { $0.id.account == Self.acme })
    }

    @Test func anAccountRemovedOnOneDeviceLeavesTheOtherWithItsCacheAndToggles() async throws {
        let shared = MemoryKeychain()
        let mac = try Device(shared: shared)
        let phone = try Device(shared: shared)
        for device in [mac, phone] {
            try device.list(device.fixture.accounts.filter { $0.id == Self.gmail })
        }
        try mac.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)
        _ = await phone.engine.reconcileAccounts()
        _ = await phone.engine.refresh()
        let personal = CalendarID(account: Self.gmail, googleID: "you@gmail.com")
        try await phone.engine.setVisible(false, calendar: personal)
        #expect(phone.exists(CacheFile.events(Self.gmail)))
        #expect(phone.local.items[Self.gmail.sub] != nil)

        try await mac.engine.removeAccount(Self.gmail)
        #expect(shared.items.isEmpty)

        let changes = await phone.engine.reconcileAccounts()
        #expect(changes.removed == [Self.gmail])
        #expect(phone.accounts.isEmpty)
        for name in [CacheFile.events(Self.gmail), CacheFile.calendars(Self.gmail), CacheFile.sync(Self.gmail), CacheFile.near(Self.gmail)] {
            #expect(!phone.exists(name))
        }
        #expect(phone.engine.storedVisibility().overrides.isEmpty)
        #expect(phone.local.items.isEmpty)
        #expect(WidgetSnapshot.read(from: phone.cache)?.accountCount == 0)
    }

    @Test func anAccountAddedBackBeforeTheOtherDeviceLookedStays() async throws {
        let shared = MemoryKeychain()
        let mac = try Device(shared: shared)
        let phone = try Device(shared: shared)
        try phone.list(phone.fixture.accounts.filter { $0.id == Self.gmail })
        try mac.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)
        _ = await phone.engine.reconcileAccounts()

        try mac.store.removeToken(for: Self.gmail)
        try mac.store.signIn(Self.token("refresh-gmail-2"), for: Self.gmail)
        let changes = await phone.engine.reconcileAccounts()
        #expect(changes.removed.isEmpty)
        #expect(try phone.store.token(for: Self.gmail)?.refreshToken == "refresh-gmail-2")
    }

    @Test func anAccountThisDeviceNeverSawSharedIsNeverRemoved() async throws {
        let phone = try Device(shared: MemoryKeychain())
        // A grant without calendar access: listed, signed out, no item anywhere.
        let narrow = Account(id: AccountID("100000000000000000003"), email: "you@studio.example", addedAt: phone.fixture.now, signedOut: true)
        try phone.list([narrow])
        let changes = await phone.engine.reconcileAccounts()
        #expect(changes.removed.isEmpty)
        #expect(phone.accounts == [narrow])
    }

    @Test func aListTheKeychainRefusesToReadChangesNothing() async throws {
        let shared = MemoryKeychain()
        let phone = try Device(shared: shared)
        try phone.list(phone.fixture.accounts.filter { $0.id == Self.gmail })
        try phone.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)
        _ = await phone.engine.reconcileAccounts()

        // Before the first unlock after a restart.
        shared.isLocked = true
        let changes = await phone.engine.reconcileAccounts()
        #expect(changes == AccountChanges())
        #expect(phone.accounts.map(\.id) == [Self.gmail])
    }

    @Test func aRefusedRefreshSignsOutOnlyThisDeviceAndASignInElsewhereBringsItBack() async throws {
        let shared = MemoryKeychain()
        let mac = try Device(shared: shared)
        let phone = try Device(shared: shared)
        for device in [mac, phone] {
            try device.list(device.fixture.accounts.filter { $0.id == Self.gmail })
        }
        // A token Google refuses, as after a Workspace session limit.
        try mac.store.signIn(Self.token("refresh-revoked"), for: Self.gmail)
        _ = await phone.engine.reconcileAccounts()

        let refused = await phone.engine.refresh()
        #expect(refused.newlySignedOut == [Self.gmail])
        #expect(phone.accounts.first?.signedOut == true)
        // The shared item stays, and the Mac is not told anything.
        #expect(try Self.item(shared.items[Self.gmail.sub]).refreshToken == "refresh-revoked")
        #expect(mac.accounts.first?.signedOut == false)

        // The next pass finds the same token in the shared item: nothing changes yet.
        var changes = await phone.engine.reconcileAccounts()
        #expect(changes.restored.isEmpty)
        #expect(phone.accounts.first?.signedOut == true)

        // The person signs in again on the Mac: a new refresh token in the shared item.
        try mac.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)
        changes = await phone.engine.reconcileAccounts()
        #expect(changes.restored == [Self.gmail])
        #expect(phone.accounts.first?.signedOut == false)
        let report = await phone.engine.refresh()
        #expect(report.newlySignedOut.isEmpty)
        #expect(report.outcome == .current)
    }

    @Test func aSignInElsewhereThatLandsBeforeThisDeviceLooksAgainStillBringsItBack() async throws {
        let shared = MemoryKeychain()
        let mac = try Device(shared: shared)
        let phone = try Device(shared: shared)
        for device in [mac, phone] {
            try device.list(device.fixture.accounts.filter { $0.id == Self.gmail })
        }
        try mac.store.signIn(Self.token("refresh-revoked"), for: Self.gmail)
        _ = await phone.engine.reconcileAccounts()

        // The refusal is noted with the refresh that finds it, not on a later pass.
        let refused = await phone.engine.refresh()
        #expect(refused.newlySignedOut == [Self.gmail])
        let file = try #require(phone.cache.read(AccountItemsFile.self, from: AccountItemsFile.fileName))
        #expect(file.refused[Self.gmail.sub] == SharedTokenStore.fingerprint("refresh-revoked"))

        // The phone goes to the background for hours. The person signs in again on the Mac,
        // and the phone's very next pass is the first to look at the keychain.
        try mac.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)
        let changes = await phone.engine.reconcileAccounts()
        #expect(changes.restored == [Self.gmail])
        #expect(phone.accounts.first?.signedOut == false)
        #expect(try Self.item(shared.items[Self.gmail.sub]).refreshToken == "refresh-gmail")
        let report = await phone.engine.refresh()
        #expect(report.newlySignedOut.isEmpty)
    }

    @Test func anAccountSignedOutBeforeAnyFingerprintWasKeptTriesTheSharedTokenOnce() async throws {
        let shared = MemoryKeychain()
        let phone = try Device(shared: shared)
        var gmail = try #require(phone.fixture.accounts.first { $0.id == Self.gmail })
        gmail.signedOut = true
        try phone.list([gmail])
        try phone.store.signIn(Self.token("refresh-revoked"), for: Self.gmail)

        // Nothing to compare with: the shared token gets its one try, and Google's refusal
        // is noted so it is not tried again.
        var changes = await phone.engine.reconcileAccounts()
        #expect(changes.restored == [Self.gmail])
        let refused = await phone.engine.refresh()
        #expect(refused.newlySignedOut == [Self.gmail])
        changes = await phone.engine.reconcileAccounts()
        #expect(changes.restored.isEmpty)
        #expect(phone.accounts.first?.signedOut == true)
    }

    @Test func aRefreshedAccessTokenNeverWritesTheSharedItem() throws {
        let shared = MemoryKeychain()
        let mac = try Device(shared: shared)
        let phone = try Device(shared: shared)
        try mac.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)
        let written = shared.items

        // The phone reads the token and refreshes its access token.
        var token = try #require(try phone.store.token(for: Self.gmail))
        token.accessToken = "access-phone"
        token.accessExpiry = phone.fixture.now.addingTimeInterval(3600)
        try phone.store.save(token, for: Self.gmail)
        #expect(shared.items == written)
        #expect(try phone.store.token(for: Self.gmail)?.accessToken == "access-phone")

        // Meanwhile the Mac signs the account in again; the phone's refresh with the token it
        // read before lands after, and must not put the old token back.
        try mac.store.signIn(Self.token("refresh-new"), for: Self.gmail)
        token.accessToken = "access-phone-2"
        try phone.store.save(token, for: Self.gmail)
        let now = try #require(try phone.store.token(for: Self.gmail))
        #expect(now.refreshToken == "refresh-new")
        // The access token came from the old refresh token, so it is not paired with the new.
        #expect(now.accessToken == nil)
    }

    @Test func aRefreshThatLandsAfterARemovalNeverBringsTheAccountBack() throws {
        let shared = MemoryKeychain()
        let mac = try Device(shared: shared)
        let phone = try Device(shared: shared)
        try mac.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)

        // The widget's process reads the token and, its access token near expiry, starts to
        // refresh it.
        var token = try #require(try phone.store.token(for: Self.gmail))
        // The person removes the account on the Mac: the shared item is deleted.
        try mac.store.removeToken(for: Self.gmail)
        #expect(shared.items.isEmpty)

        // The refresh finishes and saves: with a fresh access token, and with the token
        // Google has just been told to revoke.
        token.accessToken = "access-late"
        token.accessExpiry = phone.fixture.now.addingTimeInterval(3600)
        try phone.store.save(token, for: Self.gmail)
        #expect(shared.items.isEmpty)
        #expect(phone.local.items.isEmpty)
        #expect(phone.legacy.items.isEmpty)
        #expect(try phone.store.accountItems()?.isEmpty == true)
    }

    @Test func aRefreshTokenGoogleSendsInsteadReplacesTheItemOnlyWhileItExists() throws {
        let shared = MemoryKeychain()
        let mac = try Device(shared: shared)
        try mac.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)
        let added = try Self.item(shared.items[Self.gmail.sub]).addedAt

        var rotated = try #require(try mac.store.token(for: Self.gmail))
        rotated.refreshToken = "refresh-rotated"
        rotated.accessToken = "access-rotated"
        rotated.accessExpiry = mac.fixture.now.addingTimeInterval(3600)
        try mac.store.save(rotated, for: Self.gmail)
        let item = try Self.item(shared.items[Self.gmail.sub])
        #expect(item.refreshToken == "refresh-rotated")
        #expect(item.addedAt == added)

        // The account is removed; a later save of yet another token adds nothing.
        try mac.store.removeToken(for: Self.gmail)
        rotated.refreshToken = "refresh-rotated-again"
        try mac.store.save(rotated, for: Self.gmail)
        #expect(shared.items.isEmpty)
    }

    @Test func aSignInReplacesTheItemAndAnAccountAddedByASignInKeepsItsDate() throws {
        let shared = MemoryKeychain()
        let mac = try Device(shared: shared)
        try mac.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)
        let added = try Self.item(shared.items[Self.gmail.sub]).addedAt
        mac.clock.update { $0 = $0.addingTimeInterval(86_400) }
        try mac.store.signIn(Self.token("refresh-gmail-2"), for: Self.gmail)
        let item = try Self.item(shared.items[Self.gmail.sub])
        #expect(item.refreshToken == "refresh-gmail-2")
        #expect(item.addedAt == added)
    }

    @Test func removingAnAccountDeletesEveryItemOfIt() throws {
        let legacy = MemoryKeychain()
        let phone = try Device(shared: MemoryKeychain(), legacy: legacy)
        try phone.store.signIn(Self.token("refresh-gmail", access: "a", expiry: phone.fixture.now), for: Self.gmail)
        try legacy.write(Self.token("refresh-old").encoded(), account: Self.gmail.sub, label: "")
        try phone.store.removeToken(for: Self.gmail)
        #expect(phone.shared.items.isEmpty)
        #expect(phone.local.items.isEmpty)
        #expect(legacy.items.isEmpty)
    }

    @Test func revokingSendsTheRefreshTokenToGoogle() async throws {
        let stub = Stub { request in
            (200, Data(), [:])
        }
        let auth = try #require(GoogleAuth(clientID: Recorded.clientID, transport: stub, retry: .noWait))
        try await auth.revoke(Self.token("refresh-gmail"))
        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(request.httpMethod == "POST")
        #expect(Recorded.form(request) == ["token": "refresh-gmail"])

        // A token Google no longer knows is gone, which is what was asked.
        let gone = Stub { _ in (400, Data(#"{"error": "invalid_token"}"#.utf8), [:]) }
        try await #require(GoogleAuth(clientID: Recorded.clientID, transport: gone, retry: .noWait)).revoke(Self.token("x"))
    }

    @Test func theEngineWorksThroughAStoreThatWrapsTheSharedOne() async throws {
        let shared = MemoryKeychain()
        let mac = try Device(shared: shared)
        let legacy = MemoryKeychain()
        try legacy.write(Self.token("refresh-gmail").encoded(), account: Self.gmail.sub, label: "")
        try legacy.write(Self.token("refresh-revoked", email: "you@acme.com").encoded(), account: Self.acme.sub, label: "")
        let phone = try Device(shared: shared, legacy: legacy, wrapped: true)
        try phone.list(phone.fixture.accounts)

        // The old items move when Google takes them, and a refused one is dropped and noted.
        let report = await phone.engine.refresh()
        #expect(report.newlySignedOut == [Self.acme])
        #expect(legacy.items.isEmpty)
        #expect(try Self.item(shared.items[Self.gmail.sub]).refreshToken == "refresh-gmail")
        let file = try #require(phone.cache.read(AccountItemsFile.self, from: AccountItemsFile.fileName))
        #expect(file.refused[Self.acme.sub] == SharedTokenStore.fingerprint("refresh-revoked"))

        // An account the Mac removes leaves the phone, and a revocation can be queued.
        try await mac.engine.removeAccount(Self.gmail)
        let changes = await phone.engine.reconcileAccounts()
        #expect(changes.removed == [Self.gmail])
        #expect(phone.engine.queueRevocation(Self.token("refresh-gmail"), for: Self.gmail))
        #expect(phone.revocations.items[Self.gmail.sub] != nil)
    }

    // MARK: Revocation

    /// A Google that is unreachable until `online` is set.
    final class Network: Sendable {
        private let online = Mutex(false)
        func setOnline(_ value: Bool) { online.withLock { $0 = value } }
        var isOnline: Bool { online.withLock { $0 } }
    }

    static func revoker(_ network: Network, status: Int = 200) -> (Stub, GoogleAuth) {
        let stub = Stub { _ in
            guard network.isOnline else { throw URLError(.notConnectedToInternet) }
            return (status, Data(), [:])
        }
        return (stub, GoogleAuth(clientID: Recorded.clientID, transport: stub, retry: .noWait)!)
    }

    @Test func aRevocationMadeOfflineWaitsInTheKeychainAndIsRetried() async throws {
        let shared = MemoryKeychain()
        let phone = try Device(shared: shared)
        let network = Network()
        let (stub, auth) = Self.revoker(network)
        let engine = SyncEngine(
            auth: auth, tokens: phone.store, cache: phone.cache,
            api: CalendarAPI(transport: stub, retry: .noWait), calendar: phone.fixture.calendar,
            clock: { phone.clock.value })
        try phone.list(phone.fixture.accounts.filter { $0.id == Self.gmail })
        try phone.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)

        // The removal: the token is kept first, then every item goes.
        let token = try #require(engine.storedToken(for: Self.gmail))
        #expect(engine.queueRevocation(token, for: Self.gmail))
        try await engine.removeAccount(Self.gmail)
        #expect(shared.items.isEmpty)
        let pending = try #require(phone.revocations.items[Self.gmail.sub])
        #expect(try StoredToken(encoded: pending).refreshToken == "refresh-gmail")
        // The token is in the keychain and in no file of the cache.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: phone.folder.path(percentEncoded: false))) ?? [] {
            let contents = (try? String(contentsOf: phone.folder.appending(path: name), encoding: .utf8)) ?? ""
            #expect(!contents.contains("refresh-gmail"))
        }

        // Offline, the try fails and the item stays.
        await engine.retryRevocations()
        #expect(phone.revocations.items[Self.gmail.sub] != nil)

        // Back online, the next retry (on launch or after a sync) revokes and clears it.
        network.setOnline(true)
        await engine.retryRevocations()
        #expect(phone.revocations.items.isEmpty)
        let request = try #require(stub.requests.last)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(Recorded.form(request) == ["token": "refresh-gmail"])
    }

    @Test func aTokenGoogleNoLongerKnowsLeavesTheQueueToo() async throws {
        let phone = try Device(shared: MemoryKeychain())
        let network = Network()
        network.setOnline(true)
        let (stub, auth) = Self.revoker(network, status: 400)
        let engine = SyncEngine(
            auth: auth, tokens: phone.store, cache: phone.cache,
            api: CalendarAPI(transport: stub, retry: .noWait), calendar: phone.fixture.calendar,
            clock: { phone.clock.value })
        #expect(engine.queueRevocation(Self.token("refresh-gone"), for: Self.gmail))
        await engine.retryRevocations()
        #expect(phone.revocations.items.isEmpty)
    }

    @Test func aRevocationIsNotTriedForAnAccountThatIsSignedInAgain() async throws {
        let phone = try Device(shared: MemoryKeychain())
        let network = Network()
        network.setOnline(true)
        let (stub, auth) = Self.revoker(network)
        let engine = SyncEngine(
            auth: auth, tokens: phone.store, cache: phone.cache,
            api: CalendarAPI(transport: stub, retry: .noWait), calendar: phone.fixture.calendar,
            clock: { phone.clock.value })
        #expect(engine.queueRevocation(Self.token("refresh-old"), for: Self.gmail))
        // The account was added back meanwhile; its grant may be the one the old token shares.
        try phone.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)
        await engine.retryRevocations()
        #expect(stub.requests.isEmpty)
        #expect(phone.revocations.items[Self.gmail.sub] != nil)
    }

    @Test func aRemovalThatFailedKeepsItsTokenOutOfTheQueue() throws {
        let phone = try Device(shared: MemoryKeychain())
        try phone.store.signIn(Self.token("refresh-gmail"), for: Self.gmail)
        #expect(phone.store.queueRevocation(Self.token("refresh-gmail"), for: Self.gmail))
        phone.store.revocationDone(for: Self.gmail)
        #expect(phone.revocations.items.isEmpty)
        // A store with nowhere to keep it says so, and the caller revokes at once.
        let bare = SharedTokenStore(shared: MemoryKeychain(), device: MemoryKeychain(), legacy: MemoryKeychain())
        #expect(!bare.queueRevocation(Self.token("refresh-gmail"), for: Self.gmail))
    }

    // MARK: Calendar settings in iCloud

    static let personal = CalendarID(account: gmail, googleID: "you@gmail.com")
    static let holidays = CalendarID(account: gmail, googleID: "en.dutch#holiday@group.v.calendar.google.com")
    static let work = CalendarID(account: acme, googleID: "you@acme.com")

    static func settings(
        _ visibility: [CalendarID: Bool] = [:], _ symbols: [CalendarID: String] = [:]
    ) -> CalendarSettings {
        CalendarSettings(
            visibility: CalendarVisibility(overrides: visibility),
            symbols: CalendarSymbolMap(assigned: symbols))
    }

    @Test func keysAndEntriesCarryNoAddressOrCalendarID() throws {
        let cloud = MemorySettingsCloud()
        let settings = CloudCalendarSettings(cloud: cloud)
        settings.setVisible(false, for: Self.personal)
        settings.setSymbol("briefcase", for: Self.personal)
        settings.setSymbol("house", for: Self.work)
        let visibleKey = CloudCalendarSettings.visibilityKey(for: Self.personal)
        let symbolKey = CloudCalendarSettings.symbolKey(for: Self.personal)
        #expect(visibleKey.hasPrefix("v.") && symbolKey.hasPrefix("s."))
        #expect(visibleKey.dropFirst(2) == symbolKey.dropFirst(2))
        #expect(visibleKey.count <= 64 && symbolKey.count <= 64)
        #expect(visibleKey == CloudCalendarSettings.visibilityKey(for: CalendarID(account: Self.gmail, googleID: "you@gmail.com")))
        #expect(visibleKey != CloudCalendarSettings.visibilityKey(for: CalendarID(account: Self.acme, googleID: "you@gmail.com")))
        // Two keys for the calendar, and nothing else.
        #expect(Set(cloud.keys()) == [visibleKey, symbolKey, CloudCalendarSettings.symbolKey(for: Self.work)])
        for name in cloud.keys() {
            let stored = name + String(decoding: try #require(cloud.data(forKey: name)), as: UTF8.self)
            for secret in ["you@", "gmail", "acme", "holiday", Self.gmail.sub, Self.acme.sub] {
                #expect(!stored.contains(secret))
            }
        }
        #expect(settings.visible(for: Self.personal) == false)
        #expect(settings.symbol(for: Self.personal) == "briefcase")
    }

    @Test func theFirstPassCopiesThisDevicesFilesIntoTheCloud() {
        let cloud = MemorySettingsCloud()
        let settings = CloudCalendarSettings(cloud: cloud)
        let local = Self.settings([Self.holidays: false], [Self.personal: "house"])
        let next = settings.reconcile(local, known: [Self.personal, Self.holidays, Self.work])
        #expect(next == local)
        #expect(settings.visible(for: Self.holidays) == false)
        #expect(settings.symbol(for: Self.personal) == "house")
        #expect(settings.visible(for: Self.work) == nil)
        #expect(!settings.hasSymbolEntry(for: Self.work))
        // Only what exists is written: no toggle for the iconed calendar, no icon for the hidden.
        #expect(cloud.data(forKey: CloudCalendarSettings.visibilityKey(for: Self.personal)) == nil)
        #expect(cloud.data(forKey: CloudCalendarSettings.symbolKey(for: Self.holidays)) == nil)
    }

    @Test func anotherDevicesSettingWinsForItsCalendarOnly() {
        let cloud = MemorySettingsCloud()
        let mac = CloudCalendarSettings(cloud: cloud)
        let phone = CloudCalendarSettings(cloud: cloud)
        _ = phone.reconcile(Self.settings([:], [Self.personal: "house"]), known: [Self.personal])
        mac.setVisible(false, for: Self.holidays)
        mac.setSymbol("briefcase", for: Self.work)

        let next = phone.reconcile(
            Self.settings([:], [Self.personal: "house"]),
            known: [Self.personal, Self.holidays, Self.work])
        #expect(next == Self.settings([Self.holidays: false], [Self.personal: "house", Self.work: "briefcase"]))
    }

    @Test func anIconAndAToggleMadeOnTwoDevicesNeverEraseEachOther() {
        // The Mac is offline on a flight and gives the calendar an icon; meanwhile the phone
        // hides the calendar. Each is its own key, so both survive in either landing order.
        for macLandsLast in [true, false] {
            let cloud = MemorySettingsCloud()
            let mac = CloudCalendarSettings(cloud: cloud)
            let phone = CloudCalendarSettings(cloud: cloud)
            if macLandsLast {
                phone.setVisible(false, for: Self.personal)
                mac.setSymbol("airplane", for: Self.personal)
            } else {
                mac.setSymbol("airplane", for: Self.personal)
                phone.setVisible(false, for: Self.personal)
            }
            let next = phone.reconcile(Self.settings(), known: [Self.personal])
            #expect(next == Self.settings([Self.personal: false], [Self.personal: "airplane"]))
        }
    }

    @Test func choosingNoSymbolLeavesAnEntrySoADeviceThatWasOffCannotBringItBack() {
        let cloud = MemorySettingsCloud()
        let mac = CloudCalendarSettings(cloud: cloud)
        let phone = CloudCalendarSettings(cloud: cloud)
        let phoneLocal = Self.settings([:], [Self.personal: "house"])
        _ = phone.reconcile(phoneLocal, known: [Self.personal])
        mac.setSymbol(nil, for: Self.personal)
        #expect(mac.hasSymbolEntry(for: Self.personal))
        // The phone was off: it launches with its old file and no change notification.
        let next = phone.reconcile(phoneLocal, known: [Self.personal])
        #expect(next.symbols.isEmpty)
        #expect(mac.symbol(for: Self.personal) == nil)
    }

    @Test func aKeyAnotherDeviceRemovedClearsThatSettingHere() {
        let cloud = MemorySettingsCloud()
        let settings = CloudCalendarSettings(cloud: cloud)
        let local = Self.settings([Self.personal: false], [Self.personal: "house"])
        _ = settings.reconcile(local, known: [Self.personal])
        let key = CloudCalendarSettings.symbolKey(for: Self.personal)
        cloud.setData(nil, forKey: key)
        let next = settings.reconcile(local, known: [Self.personal], removed: [key])
        // Only the icon went; the toggle has its own key.
        #expect(next == Self.settings([Self.personal: false]))
        #expect(cloud.data(forKey: key) == nil)
    }

    @Test func removingAnAccountClearsOnlyItsEntriesIncludingOnesThisDeviceNeverListed() {
        let cloud = MemorySettingsCloud()
        let settings = CloudCalendarSettings(cloud: cloud)
        settings.setVisible(false, for: Self.personal)
        settings.setSymbol("house", for: Self.personal)
        settings.setSymbol("gift", for: CalendarID(account: Self.gmail, googleID: "elsewhere@group.calendar.google.com"))
        settings.setVisible(false, for: CalendarID(account: Self.gmail, googleID: "elsewhere@group.calendar.google.com"))
        settings.setSymbol("briefcase", for: Self.work)
        cloud.setData(Data("not ours".utf8), forKey: "other")
        settings.forget(Self.gmail)
        #expect(Set(cloud.keys()) == [CloudCalendarSettings.symbolKey(for: Self.work), "other"])
    }

    @Test func aSymbolThisVersionDoesNotKnowIsKeptAndReadsAsNone() {
        let cloud = MemorySettingsCloud()
        let settings = CloudCalendarSettings(cloud: cloud)
        settings.setSymbol("sparkles.rectangle.stack.later", for: Self.personal)
        let next = settings.reconcile(Self.settings(), known: [Self.personal])
        #expect(next.symbols.assigned[Self.personal] == "sparkles.rectangle.stack.later")
        #expect(next.symbols.symbol(for: Self.personal) == nil)
    }

    @Test func anEntryALaterVersionWroteIsNeitherReadNorWrittenOver() {
        let key = CloudCalendarSettings.visibilityKey(for: Self.personal)
        let cloud = MemorySettingsCloud([key: Data(#"{"a": 7}"#.utf8)])
        let settings = CloudCalendarSettings(cloud: cloud)
        let local = Self.settings([Self.personal: false])
        #expect(settings.reconcile(local, known: [Self.personal]) == local)
        #expect(cloud.data(forKey: key) == Data(#"{"a": 7}"#.utf8))
    }

    // MARK: Why the store changed

    /// What an observer heard, in order.
    final class Heard: Sendable {
        private let changes = Mutex<[SettingsChange]>([])
        func append(_ change: SettingsChange) { changes.withLock { $0.append(change) } }
        var all: [SettingsChange] { changes.withLock { $0 } }
    }

    /// What the app does for each notification: ask the settings what to treat as removed,
    /// then reconcile the files with the store.
    static func apply(
        _ change: SettingsChange, to local: CalendarSettings, known: [CalendarID],
        through settings: CloudCalendarSettings
    ) -> CalendarSettings {
        guard let removed = settings.removedKeys(for: change) else { return local }
        return settings.reconcile(local, known: known, removed: removed)
    }

    @Test func theFirstDownloadNeverWipesTheTogglesAndIconsOfThisDevice() {
        // The first launch of this build: the store is still downloading, so what this device
        // writes into it is dropped, and the notification lists keys that are not here yet.
        let cloud = MemorySettingsCloud()
        cloud.isDownloading = true
        let settings = CloudCalendarSettings(cloud: cloud)
        let local = Self.settings([Self.holidays: false], [Self.personal: "house", Self.work: "briefcase"])
        let known = [Self.personal, Self.holidays, Self.work]
        let heard = Heard()
        let observation = cloud.observe { heard.append($0) }

        var current = settings.reconcile(local, known: known)
        #expect(current == local)
        #expect(cloud.keys().isEmpty)

        cloud.finishInitialDownload()
        let changes = heard.all
        #expect(changes == [.initialSync])
        for change in changes {
            current = Self.apply(change, to: current, known: known, through: settings)
        }
        // Every setting is still here, and now the store has them for the other devices.
        #expect(current == local)
        #expect(settings.visible(for: Self.holidays) == false)
        #expect(settings.symbol(for: Self.personal) == "house")
        #expect(settings.symbol(for: Self.work) == "briefcase")
        observation.cancel()
    }

    @Test func theFirstDownloadBringsWhatOtherDevicesChose() {
        let cloud = MemorySettingsCloud()
        cloud.isDownloading = true
        let settings = CloudCalendarSettings(cloud: cloud)
        let local = Self.settings([:], [Self.personal: "house"])
        let known = [Self.personal, Self.holidays]
        let other = MemorySettingsCloud()
        let phone = CloudCalendarSettings(cloud: other)
        phone.setVisible(false, for: Self.holidays)
        phone.setSymbol("gift", for: Self.personal)

        _ = settings.reconcile(local, known: known)
        let arrived = Dictionary(
            uniqueKeysWithValues: other.keys().compactMap { key in other.data(forKey: key).map { (key, $0) } })
        cloud.finishInitialDownload(bringing: arrived)
        let next = Self.apply(.initialSync, to: local, known: known, through: settings)
        // The other device's setting wins for its calendars; this device's other settings stay.
        #expect(next == Self.settings([Self.holidays: false], [Self.personal: "gift"]))
    }

    @Test func anAccountSwitchIsHandledLikeTheFirstDownload() {
        let cloud = MemorySettingsCloud()
        let settings = CloudCalendarSettings(cloud: cloud)
        let local = Self.settings([Self.holidays: false], [Self.personal: "house"])
        let known = [Self.personal, Self.holidays]
        // Another Apple ID's store is empty: this device's files give it their settings.
        let next = Self.apply(.account, to: local, known: known, through: settings)
        #expect(next == local)
        #expect(settings.visible(for: Self.holidays) == false)
        #expect(settings.symbol(for: Self.personal) == "house")
    }

    @Test func anotherDevicesChangeStillClearsWhatItRemoved() throws {
        let cloud = MemorySettingsCloud()
        let settings = CloudCalendarSettings(cloud: cloud)
        let local = Self.settings([Self.holidays: false], [Self.personal: "house"])
        let known = [Self.personal, Self.holidays]
        _ = settings.reconcile(local, known: known)

        let gone = CloudCalendarSettings.visibilityKey(for: Self.holidays)
        let heard = Heard()
        let observation = cloud.observe { heard.append($0) }
        cloud.deliver(.server(keys: [gone]), setting: [gone: nil])
        let change = try #require(heard.all.first)
        #expect(change == .server(keys: [gone]))
        #expect(settings.removedKeys(for: change) == [gone])
        let next = Self.apply(change, to: local, known: known, through: settings)
        #expect(next == Self.settings([:], [Self.personal: "house"]))
        // A key that is still there is not a removal.
        let kept = CloudCalendarSettings.symbolKey(for: Self.personal)
        #expect(settings.removedKeys(for: .server(keys: [kept])) == [])
        observation.cancel()
    }

    @Test func aStoreOverItsQuotaIsSkipped() {
        let cloud = MemorySettingsCloud()
        let settings = CloudCalendarSettings(cloud: cloud)
        #expect(settings.removedKeys(for: .quotaViolation) == nil)
        let local = Self.settings([Self.holidays: false])
        #expect(Self.apply(.quotaViolation, to: local, known: [Self.holidays], through: settings) == local)
        #expect(cloud.keys().isEmpty)
    }
}
