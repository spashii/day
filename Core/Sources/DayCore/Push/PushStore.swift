import Foundation

/// The install's identity and its push state, in Day's own folder (the App Group on iPhone,
/// so the widget extension can read the install ID; Application Support on the Mac).
///
/// Both files are kept out of backups. A backup restored onto another device would otherwise
/// bring this install's ID and channels with it, and two devices would then overwrite each
/// other's push tokens at the relay.
public struct PushStore: Sendable {
    public static let installFile = "push-install.txt"
    static let stateFile = "push-state.json"
    static let widgetTokenFile = "push-widget-token.txt"

    public let directory: CacheDirectory

    public init(directory: CacheDirectory) {
        self.directory = directory
    }

    // MARK: Install ID

    /// The install ID if one was made, without making one.
    public func existingInstall() -> String? {
        guard let data = try? Data(contentsOf: directory.fileURL(Self.installFile)),
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let uuid = UUID(uuidString: text)
        else { return nil }
        return uuid.uuidString.lowercased()
    }

    /// The install ID, made on first use: a random UUID, lower case as the relay writes it,
    /// never derived from the Apple ID or the device. The app and the widget extension may
    /// both ask at once, so the file is linked into place only if absent and whoever loses
    /// reads the winner's.
    public func install() throws -> String {
        if let existing = existingInstall() { return existing }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory.url, withIntermediateDirectories: true)
        let candidate = UUID().uuidString.lowercased()
        let temporary = directory.fileURL(".\(Self.installFile).\(UUID().uuidString).tmp")
        try Data(candidate.utf8).write(to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        let destination = directory.fileURL(Self.installFile)
        if link(temporary.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0 {
            excludeFromBackup(destination)
            return candidate
        }
        guard errno == EEXIST, let winner = existingInstall() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return winner
    }

    // MARK: State

    func state() -> PushState {
        directory.read(PushState.self, from: Self.stateFile) ?? PushState()
    }

    func save(_ state: PushState) {
        guard (try? directory.write(state, to: Self.stateFile)) != nil else { return }
        excludeFromBackup(directory.fileURL(Self.stateFile))
    }

    // MARK: The widget's push token

    /// The Lock Screen widget's token as the extension last received it, for the app to send
    /// along with its own. Nil when the widget has not reported one.
    public func widgetToken() -> String? {
        guard let data = try? Data(contentsOf: directory.fileURL(Self.widgetTokenFile)) else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// Kept by the extension; an empty file means the widget is on no Lock Screen.
    public func saveWidgetToken(_ hex: String?) {
        try? directory.write(Data((hex ?? "").utf8), to: Self.widgetTokenFile)
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// What this install has open and what the relay last accepted. Device-private: it names
/// calendars, and none of it but channel IDs and expiries ever leaves the device.
struct PushState: Codable, Hashable, Sendable {
    /// The relay's channel token for this install, put in every watch.
    var channelToken: String?
    var channels: [WatchedChannel] = []
    /// The last registration the relay answered 200 to.
    var registered: Registered?
    /// Targets whose last watch failed, and when to try again.
    var waiting: [Waiting] = []
    /// The install was registered, then every account went, and the relay has not yet
    /// confirmed forgetting it.
    var pendingDelete = false

    struct Registered: Codable, Hashable, Sendable {
        var app: String?
        var widget: String?
        var environment: PushEnvironment
        var channels: [String]
        var at: Date
    }

    struct Waiting: Codable, Hashable, Sendable {
        var target: WatchTarget
        var until: Date
        var failures: Int
    }
}
