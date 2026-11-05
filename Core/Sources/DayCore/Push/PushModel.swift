import Foundation

// The device half of instant sync: Google watch channels that point at Day's push relay
// (`push/README.md`), and the registration that tells the relay where this install can be
// woken. The relay never sees a Google token or an event; it only learns that something
// changed and sends an Apple push, and the device then runs its own incremental sync.

/// What one Google watch channel follows: an account's calendar list, or one calendar's
/// events. A calendar shared into two accounts is watched once, under the account that
/// sync reads it from.
public enum WatchTarget: Codable, Hashable, Sendable {
    case calendarList(AccountID)
    case events(CalendarID)

    public var account: AccountID {
        switch self {
        case .calendarList(let account): account
        case .events(let calendar): calendar.account
        }
    }
}

/// The channels this install should have open: one `calendarList.watch` per signed-in
/// account and one `events.watch` per calendar shown, which are the calendars sync reads.
public struct WatchSet: Hashable, Sendable {
    public var targets: Set<WatchTarget>
    /// Signed-in accounts whose calendar list is not known on this run (a file that could
    /// not be read, say before the first unlock). Their event channels are left exactly as
    /// they are, so an unreadable file never stops a channel that is still wanted.
    public var unknownCalendars: Set<AccountID>

    public init(targets: Set<WatchTarget>, unknownCalendars: Set<AccountID> = []) {
        self.targets = targets
        self.unknownCalendars = unknownCalendars
    }

    /// From what the screen shows: `calendars` is every calendar once (shared ones folded to
    /// one account), and `isVisible` the person's toggles over Google's own.
    public init(
        accounts: [Account], calendars: [CalendarInfo], isVisible: (CalendarID) -> Bool
    ) {
        let signedIn = Set(accounts.filter { !$0.signedOut }.map(\.id))
        var targets = Set(signedIn.map(WatchTarget.calendarList))
        var listed: Set<AccountID> = []
        for info in calendars where signedIn.contains(info.id.account) {
            listed.insert(info.id.account)
            if isVisible(info.id) { targets.insert(.events(info.id)) }
        }
        self.init(targets: targets, unknownCalendars: signedIn.subtracting(listed))
    }

    public init(_ data: CalendarData) {
        self.init(accounts: data.accounts, calendars: data.calendars) { data.isVisible($0) }
    }

    /// An event channel of an account whose calendars are unknown on this run: kept as it is.
    func keepsBlind(_ target: WatchTarget) -> Bool {
        guard case .events(let calendar) = target else { return false }
        return unknownCalendars.contains(calendar.account)
    }
}

/// A channel this install opened with Google. Only `id` and `expirationMillis` ever go to
/// the relay; the target, which names a calendar, stays on the device.
public struct WatchedChannel: Codable, Hashable, Sendable {
    /// The channel ID Day gave Google: a random UUID, lower case.
    public var id: String
    /// Google's ID for the watched resource, which `channels.stop` needs with `id`.
    public var resourceID: String
    public var target: WatchTarget
    /// The channel token it was opened with. A channel opened with an older token than the
    /// relay now issues is refused by the relay, so it is opened again.
    public var token: String
    public var created: Date
    /// Google's `expiration`, milliseconds since 1970, kept as Google sent it so the relay
    /// gets the same number back.
    public var expirationMillis: Int64

    public init(
        id: String, resourceID: String, target: WatchTarget, token: String, created: Date,
        expirationMillis: Int64
    ) {
        self.id = id
        self.resourceID = resourceID
        self.target = target
        self.token = token
        self.created = created
        self.expirationMillis = expirationMillis
    }

    public var expiration: Date {
        Date(timeIntervalSince1970: TimeInterval(expirationMillis) / 1000)
    }
}

public enum PushPlatform: String, Codable, Hashable, Sendable {
    case ios
    case macos

    #if os(iOS)
        public static let current = PushPlatform.ios
    #else
        public static let current = PushPlatform.macos
    #endif
}

/// Which APNs host the relay uses for this install's tokens. It follows the signature: a
/// development signature gets sandbox tokens, everything Apple distributes or Developer ID
/// signs gets production ones.
public enum PushEnvironment: String, Codable, Hashable, Sendable {
    case sandbox
    case production

    /// Read from the provisioning profile inside `bundle`. The App Store and TestFlight strip
    /// the profile, and those builds are production; a profile that says `development` is
    /// sandbox. The simulator has no profile and only sandbox tokens.
    public static func detect(bundle: Bundle = .main) -> PushEnvironment {
        #if targetEnvironment(simulator)
            return .sandbox
        #else
            guard let value = profileEntitlement(bundle: bundle) else { return .production }
            return value == "development" ? .sandbox : .production
        #endif
    }

    static func profileEntitlement(bundle: Bundle) -> String? {
        #if os(iOS)
            let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
        #else
            let url: URL? = bundle.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #endif
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return apsEnvironment(inProfile: data)
    }

    /// A profile is a signed message around a property list; the list is found by its
    /// markers rather than by verifying the signature, which the system already did.
    static func apsEnvironment(inProfile data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plist = data[start.lowerBound..<end.upperBound]
        guard
            let root = try? PropertyListSerialization.propertyList(from: plist, format: nil)
                as? [String: Any],
            let entitlements = root["Entitlements"] as? [String: Any]
        else { return nil }
        return (entitlements["aps-environment"]
            ?? entitlements["com.apple.developer.aps-environment"]) as? String
    }
}

extension Data {
    /// Lower-case hex, the form APNs tokens take on the wire.
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
