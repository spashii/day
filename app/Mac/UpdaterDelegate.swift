import Foundation
import Sparkle

/// Marks the feed request on the author's own Macs with `self=1`, so apps.idea2prod.in, which
/// counts update checks, can tell them from everyone else's. `OwnerMac` is a user default that
/// only the author sets, from outside the app; on any other Mac it is unset and the request
/// goes out plain.
///
/// No system profile is ever sent: `SUEnableSystemProfiling` is not set in Info.plist, and
/// `sendingSystemProfile` is ignored here, so nothing can add it through this delegate.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    static let ownerKey = "OwnerMac"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func feedParameters(
        for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool
    ) -> [[String: String]] {
        defaults.bool(forKey: Self.ownerKey) ? [["key": "self", "value": "1"]] : []
    }
}
