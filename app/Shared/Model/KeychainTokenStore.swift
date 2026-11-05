import DayCore
import Foundation
import Security
import os

/// Google tokens in the keychain: sign in once, on any device with the same Apple ID.
///
/// `SharedTokenStore` in Core decides what goes where; this file is its Security-framework
/// side, four kinds of generic-password item keyed by the account's `sub`:
/// - Shared: service `io.github.spashii.day.account`, synchronizable, in the access group
///   `JMCP69LCSU.io.github.spashii.day.shared`, which the iPhone app, the Lock Screen widget
///   and the Mac app all claim (`keychain-access-groups` in app/project.yml). One item per
///   account with the refresh token, the address and the `sub`; these items are the account
///   list, and iCloud Keychain carries them, end-to-end encrypted, to every device.
/// - Device: service `io.github.spashii.day.access`, same group, never synced: this device's
///   access token, so the hourly refresh on one device never rewrites the shared item.
/// - Old: service `io.github.spashii.day.google`, the per-device items of earlier builds (the
///   Mac's login keychain, the iPhone's App Group). Read until a refresh has shown that
///   Google accepts them and the app has copied them into shared items. A build that cannot
///   reach the group keeps everything in its own service `io.github.spashii.day.google.local`
///   instead.
/// - Revocation: service `io.github.spashii.day.revoke`, same group, never synced: the
///   refresh token of a removed account until Google has confirmed the revocation.
///
/// Readable after the first unlock: the widget reads Google on every timeline reload and the
/// background refresh task runs, both mostly while the phone is locked. Before the first
/// unlock after a restart nothing is readable, the read throws, and both keep the data they
/// have until it is.
///
/// Mac: the shared and device items need the data protection keychain, which only a build
/// signed with a provisioning profile granting the group may use. A build without one (the
/// Debug build, signed with "Blend Dev") is told so by its own signature (`holdsSharedGroup`)
/// and never asks the keychain, so it does not depend on which status the system would answer
/// with. It keeps its tokens in the login keychain, under its own service, so the build that
/// holds the group never moves its items into the shared keychain and it never reads what that
/// build left behind. The desktop widget never reads tokens and claims no keychain group.
///
/// This file is compiled into the widget too, so it uses DayCore and Security only.
struct KeychainTokenStore: TokenStore {
    /// One per process, so what it remembers about tokens it has read is shared by every
    /// caller in the process.
    static let shared: SharedTokenStore = {
        guard holdsSharedGroup else {
            Failure.log.notice(
                "no shared keychain group in this build: tokens stay in the login keychain")
            return SharedTokenStore(
                shared: UnavailableKeychain(), device: UnavailableKeychain(),
                legacy: SecItemKeychain.local,
                revocations: SecItemKeychain.localRevocations)
        }
        return SharedTokenStore(
            shared: SecItemKeychain(
                service: "io.github.spashii.day.account", group: sharedGroup, sync: true,
                accessible: .afterFirstUnlock),
            device: SecItemKeychain(
                service: "io.github.spashii.day.access", group: sharedGroup, sync: false,
                accessible: .afterFirstUnlockThisDeviceOnly),
            legacy: SecItemKeychain.legacy,
            revocations: SecItemKeychain(
                service: SecItemKeychain.revocationService, group: sharedGroup, sync: false,
                accessible: .afterFirstUnlockThisDeviceOnly))
    }()

    /// Whether this build claims `sharedGroup`. Every iPhone build does; on the Mac only the
    /// build signed with the provisioning profile that grants it does (Release), and macOS
    /// kills a build that claims the group without one, so the Debug build claims none.
    static let holdsSharedGroup: Bool = {
        #if os(macOS)
            guard let task = SecTaskCreateFromSelf(nil) else { return false }
            let entitlement = "keychain-access-groups" as CFString
            return SecTaskCopyValueForEntitlement(task, entitlement, nil) != nil
        #else
            return true
        #endif
    }()

    /// `app/project.yml` repeats it in each target that reads tokens; change them together.
    static let sharedGroup = "JMCP69LCSU.io.github.spashii.day.shared"

    let store: SharedTokenStore

    init(store: SharedTokenStore = KeychainTokenStore.shared) {
        self.store = store
    }

    /// The account's token, or nil when there is no item. Nil is also the answer when the
    /// caller cannot see the item at all: an extension signed for another access group finds
    /// nothing and no error. Only the app treats nil as a sign-out (and only after comparing
    /// the refresh token it used); the widget leaves the account as the app last left it.
    func token(for account: AccountID) throws -> StoredToken? {
        try Failure.wrapping(.read) { try store.token(for: account) }
    }

    func save(_ token: StoredToken, for account: AccountID) throws {
        try Failure.wrapping(.save) { try store.save(token, for: account) }
    }

    func signIn(_ token: StoredToken, for account: AccountID) throws {
        try Failure.wrapping(.save) { try store.signIn(token, for: account) }
    }

    func removeToken(for account: AccountID) throws {
        try Failure.wrapping(.remove) { try store.removeToken(for: account) }
    }

    var sharedStore: SharedTokenStore? { store }
}

/// One kind of Day's keychain items through `SecItem`.
struct SecItemKeychain: KeychainBackend {
    enum Accessible: Sendable {
        case afterFirstUnlock
        case afterFirstUnlockThisDeviceOnly

        var value: CFString {
            switch self {
            case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
            case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    let service: String
    /// Nil: the Mac's login keychain, which has no access groups.
    let group: String?
    let sync: Bool
    /// Nil leaves the keychain's default, as the Mac's login keychain items always had.
    let accessible: Accessible?
    let dataProtection: Bool

    init(service: String, group: String?, sync: Bool, accessible: Accessible?, dataProtection: Bool = true) {
        self.service = service
        self.group = group
        self.sync = sync
        self.accessible = accessible
        self.dataProtection = dataProtection
    }

    /// The items earlier builds wrote, exactly as they wrote them: on the iPhone in the App
    /// Group (which iOS accepts as a keychain access group) at After First Unlock This Device
    /// Only, on the Mac in the login keychain with no group.
    static let legacy: SecItemKeychain = {
        #if os(iOS)
            return SecItemKeychain(
                service: DayIdentifiers.keychainService, group: DayIdentifiers.appGroup,
                sync: false, accessible: .afterFirstUnlockThisDeviceOnly)
        #else
            return SecItemKeychain(
                service: DayIdentifiers.keychainService, group: nil, sync: false,
                accessible: nil, dataProtection: false)
        #endif
    }()

    /// The Mac build that cannot use the shared group keeps its tokens here, in the login
    /// keychain under a service of its own: the build that can use the group moves the items
    /// of `legacy` into the shared keychain, and must not take these with them.
    static let local = SecItemKeychain(
        service: DayIdentifiers.keychainService + localSuffix, group: nil, sync: false,
        accessible: nil, dataProtection: false)

    static let revocationService = "io.github.spashii.day.revoke"

    static let localRevocations = SecItemKeychain(
        service: revocationService + localSuffix, group: nil, sync: false, accessible: nil,
        dataProtection: false)

    private static let localSuffix = ".local"

    func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw Failure(.read, status: errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw problem(.read, status)
        }
    }

    func accounts() throws -> [String] {
        var query = query(nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw problem(.read, status)
        }
    }

    func write(_ data: Data, account: String, label: String) throws {
        var attributes: [String: Any] = [kSecValueData as String: data]
        if let accessible { attributes[kSecAttrAccessible as String] = accessible.value }
        let query = query(account)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrLabel as String] = label
            status = SecItemAdd(item as CFDictionary, nil)
            // The app and the widget can both save a refreshed token at once; the one that
            // lost the add updates the item the other just made.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw problem(.save, status) }
    }

    func replace(_ data: Data, account: String) throws -> Bool {
        var attributes: [String: Any] = [kSecValueData as String: data]
        if let accessible { attributes[kSecAttrAccessible as String] = accessible.value }
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw problem(.save, status)
        }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw problem(.remove, status)
        }
    }

    /// Without `kSecAttrSynchronizable` a query matches only items that stay on the device,
    /// so the shared items and the others never answer for each other.
    private func query(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let group { query[kSecAttrAccessGroup as String] = group }
        if sync { query[kSecAttrSynchronizable as String] = true }
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    /// A build that claims the group but is refused it answers `errSecMissingEntitlement`; the
    /// store then keeps tokens per device, which is no failure worth a log line. A build that
    /// does not claim the group never gets here (`KeychainTokenStore.holdsSharedGroup`).
    private func problem(_ operation: KeychainTokenStore.Failure.Operation, _ status: OSStatus) -> any Error {
        status == errSecMissingEntitlement
            ? KeychainUnavailable() : KeychainTokenStore.Failure(operation, status: status)
    }

    private typealias Failure = KeychainTokenStore.Failure
}

extension KeychainTokenStore {
    /// A keychain call that failed. `localizedDescription` is the line a failed sign-in shows,
    /// so it is a plain sentence about what Day could not do (`Day could not save your sign-in
    /// on this device.`); the OSStatus and the system's own explanation go to the log, where a
    /// bug report can use them, and never to the screen.
    struct Failure: LocalizedError, CustomStringConvertible {
        enum Operation: String, Sendable {
            case read, save, remove
        }

        let operation: Operation
        let status: OSStatus

        static let log = Logger(subsystem: DayIdentifiers.bundleID, category: "keychain")

        init(_ operation: Operation, status: OSStatus) {
            self.operation = operation
            self.status = status
            Failure.log.error(
                "keychain \(operation.rawValue, privacy: .public) failed: \(Failure.message(status), privacy: .public) (OSStatus \(status, privacy: .public))"
            )
        }

        /// Runs `body`, turning Core's own errors into a failure of `operation`, so callers
        /// see one error type with a line fit for the screen.
        static func wrapping<Value>(_ operation: Operation, _ body: () throws -> Value) throws -> Value {
            do {
                return try body()
            } catch let failure as Failure {
                throw failure
            } catch is KeychainUnavailable {
                throw Failure(operation, status: errSecMissingEntitlement)
            } catch {
                // A shared item that did not read back as written, or one that does not decode.
                throw Failure(operation, status: errSecDecode)
            }
        }

        var errorDescription: String? {
            switch operation {
            case .read: "Day could not read your sign-in on this device."
            case .save: "Day could not save your sign-in on this device."
            case .remove: "Day could not remove your sign-in from this device."
            }
        }

        /// For logs and debugger output.
        var description: String {
            "Keychain \(operation.rawValue): \(Failure.message(status)) (OSStatus \(status))"
        }

        private static func message(_ status: OSStatus) -> String {
            SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        }
    }
}
