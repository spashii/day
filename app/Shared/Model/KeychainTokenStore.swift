import DayCore
import Foundation
import Security
import os

/// Google tokens in the keychain: one generic-password item per account, service
/// `io.github.spashii.day.google`, account the `sub`, data the `StoredToken` JSON.
///
/// iPhone: the App Group doubles as the keychain access group, which iOS allows without a
/// separate Keychain Sharing entitlement, so the widget reads the same items. Items are
/// readable after the first unlock and never leave the device: the widget reads Google on
/// every timeline reload and the background refresh task runs, both mostly while the phone
/// is locked. Before the first unlock after a restart nothing is readable, the read throws,
/// and both keep the data they have until it is.
///
/// Mac: the login keychain, with no access group. The desktop widget never reads tokens, and
/// an access group there would need a provisioning profile.
///
/// This file is compiled into the widget too, so it uses DayCore and Security only.
struct KeychainTokenStore: TokenStore {
    let service: String

    init(service: String = DayIdentifiers.keychainService) {
        self.service = service
    }

    /// The account's token, or nil when there is no item. Nil is also the answer when the
    /// caller cannot see the item at all: an extension signed for another access group, or a
    /// profile that does not carry the App Group, finds nothing and no error. Only the app
    /// treats nil as a sign-out (and only after comparing the refresh token it used); the
    /// widget leaves the account as the app last left it.
    func token(for account: AccountID) throws -> StoredToken? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw Failure(.read, status: errSecDecode) }
            return try StoredToken(encoded: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(.read, status: status)
        }
    }

    func save(_ token: StoredToken, for account: AccountID) throws {
        var attributes: [String: Any] = [kSecValueData as String: try token.encoded()]
        #if os(iOS)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let query = baseQuery(account)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            // What Keychain Access shows in its Name column on the Mac.
            item[kSecAttrLabel as String] = "Day: \(token.email)"
            status = SecItemAdd(item as CFDictionary, nil)
            // The app and the widget can both save a refreshed token at once; the one that
            // lost the add updates the item the other just made.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw Failure(.save, status: status) }
    }

    func removeToken(for account: AccountID) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(.remove, status: status)
        }
    }

    private func baseQuery(_ account: AccountID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.sub,
        ]
        #if os(iOS)
            query[kSecAttrAccessGroup as String] = DayIdentifiers.appGroup
            query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
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

        private static let log = Logger(subsystem: DayIdentifiers.bundleID, category: "keychain")

        init(_ operation: Operation, status: OSStatus) {
            self.operation = operation
            self.status = status
            Failure.log.error(
                "keychain \(operation.rawValue, privacy: .public) failed: \(Failure.message(status), privacy: .public) (OSStatus \(status, privacy: .public))"
            )
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
