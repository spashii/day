import Foundation
import Synchronization

/// One kind of keychain item, as `SharedTokenStore` sees it: data by account name, under a
/// service, access group and sync setting the conforming type fixes. The apps use the
/// Security framework (`KeychainTokenStore` in app/Shared/Model); tests use `MemoryKeychain`.
public protocol KeychainBackend: Sendable {
    /// The item's data, or nil when there is none.
    func read(_ account: String) throws -> Data?
    /// The account name of every item. Reads attributes only, which on the Mac's login
    /// keychain never asks the person for access.
    func accounts() throws -> [String]
    /// Adds the item, or replaces its data when it exists. `label` names a new item in
    /// Keychain Access.
    func write(_ data: Data, account: String, label: String) throws
    /// Replaces the data of an item that exists and reports whether there was one. Unlike
    /// `write` it never adds, so a delete that landed first is not undone.
    func replace(_ data: Data, account: String) throws -> Bool
    /// Deletes the item. No error when there is none.
    func delete(_ account: String) throws
}

/// What a backend throws when this build may not use its items at all: the access group is
/// not in the signature's entitlements (`errSecMissingEntitlement`). On the Mac that is a
/// build without the provisioning profile that grants the shared group, which then keeps
/// tokens in the login keychain per device, as before.
public struct KeychainUnavailable: Error, Hashable, Sendable {
    public init() {}
}

/// A backend this build may not use: every call throws `KeychainUnavailable`. The Mac build
/// signed without the profile that grants the shared access group is given this instead of
/// asking the keychain, so it never depends on which status the system answers with.
public struct UnavailableKeychain: KeychainBackend {
    public init() {}

    public func read(_ account: String) throws -> Data? { throw KeychainUnavailable() }
    public func accounts() throws -> [String] { throw KeychainUnavailable() }
    public func write(_ data: Data, account: String, label: String) throws { throw KeychainUnavailable() }
    public func replace(_ data: Data, account: String) throws -> Bool { throw KeychainUnavailable() }
    public func delete(_ account: String) throws { throw KeychainUnavailable() }
}

/// Keychain items in memory, for tests. Two stores given the same instance behave like two
/// devices on one iCloud Keychain: what one writes or deletes, the other reads at once.
public final class MemoryKeychain: KeychainBackend {
    private struct State {
        var items: [String: Data]
        var unavailable = false
        var locked = false
        var keepsWrites = true
    }

    private let state: Mutex<State>

    public init(_ items: [String: Data] = [:]) {
        state = Mutex(State(items: items))
    }

    /// Thrown while `isLocked`: a read refused for now, as before the first unlock.
    public struct Locked: Error, Hashable, Sendable {}

    /// Every call throws `KeychainUnavailable`, as in a build without the entitlement.
    public var isUnavailable: Bool {
        get { state.withLock { $0.unavailable } }
        set { state.withLock { $0.unavailable = newValue } }
    }

    /// Every call throws `Locked`.
    public var isLocked: Bool {
        get { state.withLock { $0.locked } }
        set { state.withLock { $0.locked = newValue } }
    }

    /// False: a write reports success and keeps nothing, the failure a read-back exists for.
    public var keepsWrites: Bool {
        get { state.withLock { $0.keepsWrites } }
        set { state.withLock { $0.keepsWrites = newValue } }
    }

    public var items: [String: Data] {
        state.withLock { $0.items }
    }

    public func read(_ account: String) throws -> Data? {
        try state.withLock { state in
            try Self.check(state)
            return state.items[account]
        }
    }

    public func accounts() throws -> [String] {
        try state.withLock { state in
            try Self.check(state)
            return state.items.keys.sorted()
        }
    }

    public func write(_ data: Data, account: String, label: String) throws {
        try state.withLock { state in
            try Self.check(state)
            if state.keepsWrites { state.items[account] = data }
        }
    }

    public func replace(_ data: Data, account: String) throws -> Bool {
        try state.withLock { state in
            try Self.check(state)
            guard state.items[account] != nil else { return false }
            if state.keepsWrites { state.items[account] = data }
            return true
        }
    }

    public func delete(_ account: String) throws {
        try state.withLock { state in
            try Self.check(state)
            state.items[account] = nil
        }
    }

    private static func check(_ state: State) throws {
        if state.unavailable { throw KeychainUnavailable() }
        if state.locked { throw Locked() }
    }
}
