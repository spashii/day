import DayCore
import Foundation
import Security

/// The iCloud key-value store behind `CloudCalendarSettings`: one store per Apple ID, named by
/// `com.apple.developer.ubiquity-kvstore-identifier`, which app/project.yml sets to the same
/// string on the iPhone and the Mac so both apps read one store. The widgets never read it;
/// they read the copies the app keeps in the shared folder.
final class UbiquitousSettings: SettingsCloud, @unchecked Sendable {
    static let shared = UbiquitousSettings()

    /// Whether this build may use the store. The Mac's Debug build is signed without the
    /// entitlement (app/project.yml), so it keeps its settings in the files alone, as before;
    /// every iPhone build carries it.
    static let isAvailable: Bool = {
        #if os(macOS)
            guard let task = SecTaskCreateFromSelf(nil) else { return false }
            let identifier = "com.apple.developer.ubiquity-kvstore-identifier" as CFString
            return SecTaskCopyValueForEntitlement(task, identifier, nil) != nil
        #else
            return true
        #endif
    }()

    // NSUbiquitousKeyValueStore is documented as safe to use from any thread.
    private let store = NSUbiquitousKeyValueStore.default

    func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    func setData(_ data: Data?, forKey key: String) {
        if let data {
            store.set(data, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    func keys() -> [String] {
        Array(store.dictionaryRepresentation.keys)
    }

    /// Tells `changed` why the store changed from outside, each time iCloud delivers changes,
    /// and asks iCloud for what changed while the app was not running. The reason matters:
    /// the first download and an account switch report keys that are not yet here as
    /// changed, and only a `ServerChange` says another device removed anything.
    func observe(_ changed: @escaping @Sendable (SettingsChange) -> Void) -> SettingsObservation {
        // Removing an observer is safe from any thread.
        nonisolated(unsafe) let observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store,
            queue: .main
        ) { notification in
            let info = notification.userInfo
            let keys = info?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            let reason = info?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            changed(Self.change(reason: reason, keys: keys))
        }
        store.synchronize()
        return SettingsObservation {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// A missing or unknown reason is treated like the first download: nothing is taken for
    /// removed, because losing the settings in the files is worse than missing a removal,
    /// which an account's removal covers anyway.
    static func change(reason: Int?, keys: [String]) -> SettingsChange {
        switch reason ?? -1 {
        case NSUbiquitousKeyValueStoreServerChange: .server(keys: keys)
        case NSUbiquitousKeyValueStoreQuotaViolationChange: .quotaViolation
        case NSUbiquitousKeyValueStoreAccountChange: .account
        default: .initialSync
        }
    }
}
