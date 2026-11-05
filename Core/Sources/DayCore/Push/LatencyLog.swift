import Foundation

/// The latency log: how long each change took from Google to every surface, so the site can
/// name a speed only once it has been measured.
///
/// `latency.jsonl` holds one line per stage of a change, `{"at":<ms>,"n":<number>,"stage":
/// "synced"}`. `n` is a random number per change; nothing else about the change is written,
/// no title, no ID, no calendar. The file is safe to share and `LatencyReport` reads it.
///
/// The app writes a change's first lines once its sync has applied the change and Google has
/// said when it was made (`updated`, `push`, `synced`, and on the Mac `mac-app`). Each widget
/// writes its own line when it first draws the change. Either may come first: the Lock Screen
/// widget reads Google on its own and often draws a change before the app has synced it. So
/// `latency-keys.json` links them: per change, digests of the event and of what it now shows,
/// the change's number once the app has one, and what the widgets drew before that. That file
/// never leaves the device and its entries go after two days.
///
/// The app and the widget extensions write in one folder (the App Group on both platforms;
/// Application Support on a Mac build that may not use the group), each change under a file
/// coordination on the keys file, so two processes never lose each other's entries.
public struct LatencyLog: Sendable {
    public static let fileName = "latency.jsonl"
    static let keysFile = "latency-keys.json"

    /// Clocks differ: Google stamps `updated`, the device stamps the rest. A surface time
    /// earlier than `updated` by more than this belongs to an earlier state of the event.
    static let tolerance: TimeInterval = 5
    static let keepEntries: TimeInterval = 2 * 24 * 3600
    static let maxEntries = 2000
    /// The log is cut to its newer half past this size.
    static let maxBytes = 2 << 20

    public let directory: CacheDirectory

    public init(directory: CacheDirectory) {
        self.directory = directory
    }

    public var url: URL {
        directory.fileURL(Self.fileName)
    }

    // MARK: Reading

    /// Every line of the log at `url`, skipping any that does not read (a line cut by a
    /// write in progress).
    public static func lines(at url: URL) -> [LatencyLine] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(LatencyLine.self, from: Data($0))
        }
    }

    public func lines() -> [LatencyLine] {
        Self.lines(at: url)
    }

    // MARK: The app's sync

    /// Changes the app's sync applied, each with Google's `updated` time. `pushes` are the
    /// background pushes that arrived lately; a change is timed from the first one after it
    /// was made. `appShown` is when the Mac app drew the synced data.
    func recordSync(
        _ changes: [LatencyChange], synced: Date, pushes: [Date], appShown: Date?,
        random: () -> UInt32 = { UInt32.random(in: 1...UInt32.max) }
    ) {
        guard !changes.isEmpty else { return }
        update(now: synced) { entries in
            var lines: [LatencyLine] = []
            var done: Set<[String?]> = []
            for change in changes where done.insert([change.key, change.after]).inserted {
                let index = entries.firstIndex { $0.key == change.key && $0.after == change.after }
                var entry = index.map { entries[$0] }
                    ?? LatencyEntry(key: change.key, after: change.after, created: synced)
                if entry.n != nil, entry.updated == change.updated { continue }
                let n = entry.n ?? random()
                entry.n = n
                entry.updated = change.updated
                let earliest = change.updated.addingTimeInterval(-Self.tolerance)
                lines.append(LatencyLine(n: n, stage: .updated, at: change.updated))
                if let push = pushes.filter({ $0 >= earliest && $0 <= synced }).min() {
                    lines.append(LatencyLine(n: n, stage: .push, at: push))
                }
                lines.append(LatencyLine(n: n, stage: .synced, at: synced))
                if let appShown {
                    lines.append(LatencyLine(n: n, stage: .macApp, at: appShown))
                    entry.logged.insert(.macApp)
                }
                for (stage, at) in entry.seen.sorted(by: { $0.value < $1.value })
                where at >= earliest && !entry.logged.contains(stage) {
                    lines.append(LatencyLine(n: n, stage: stage, at: at))
                    entry.logged.insert(stage)
                }
                entry.seen = [:]
                if let index { entries[index] = entry } else { entries.append(entry) }
            }
            return lines
        }
    }

    // MARK: A widget's draw

    /// The one call each widget makes after handing WidgetKit a timeline: reads the snapshot
    /// it was built from in `directory` and records the draw. Nil does nothing, for a build
    /// that may not use the App Group.
    public static func widgetDrew(_ stage: LatencyStage, in directory: CacheDirectory?) {
        guard let directory else { return }
        LatencyLog(directory: directory).recordRender(
            stage, snapshot: WidgetSnapshot.read(from: directory))
    }

    /// A widget built a timeline from `snapshot` at `at`. Compared with its previous draw,
    /// what changed is either logged under the change's number or kept until the app's sync
    /// gives it one.
    public func recordRender(
        _ stage: LatencyStage, snapshot: WidgetSnapshot?, at: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard let snapshot, snapshot.accountCount > 0 else { return }
        let file = "latency-render-\(stage.rawValue).json"
        let current = LatencyRender(stage, snapshot: snapshot, at: at, calendar: calendar)
        let previous = directory.read(LatencyRender.self, from: file)
        try? directory.write(current, to: file)
        guard let previous, previous.at <= at else { return }
        let appeared = LatencyRender.appearances(from: previous, to: current, calendar: calendar)
        guard !appeared.isEmpty else { return }
        update(now: at) { entries in
            var lines: [LatencyLine] = []
            for (key, after) in appeared {
                guard let index = entries.firstIndex(where: { $0.key == key && $0.after == after })
                else {
                    var entry = LatencyEntry(key: key, after: after, created: at)
                    entry.seen[stage] = at
                    entries.append(entry)
                    continue
                }
                var entry = entries[index]
                if let n = entry.n {
                    let earliest = (entry.updated ?? .distantPast).addingTimeInterval(-Self.tolerance)
                    if !entry.logged.contains(stage), at >= earliest {
                        lines.append(LatencyLine(n: n, stage: stage, at: at))
                        entry.logged.insert(stage)
                    }
                } else if entry.seen[stage] == nil {
                    entry.seen[stage] = at
                }
                entries[index] = entry
            }
            return lines
        }
    }

    // MARK: Files

    /// Reads the keys, lets `change` edit them and name the lines to log, then writes both,
    /// all inside one coordinated write so the app and a widget take turns.
    private func update(now: Date, _ change: (inout [LatencyEntry]) -> [LatencyLine]) {
        try? FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        withoutActuallyEscaping(change) { change in
            var coordination: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: directory.fileURL(Self.keysFile), options: .forReplacing,
                error: &coordination
            ) { _ in
                var entries = directory.read([LatencyEntry].self, from: Self.keysFile) ?? []
                entries.removeAll { now.timeIntervalSince($0.created) > Self.keepEntries }
                let lines = change(&entries)
                if entries.count > Self.maxEntries {
                    entries.removeFirst(entries.count - Self.maxEntries)
                }
                try? directory.write(entries, to: Self.keysFile)
                append(lines)
            }
        }
    }

    private func append(_ lines: [LatencyLine]) {
        guard !lines.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = Data()
        for line in lines {
            guard let encoded = try? encoder.encode(line) else { continue }
            data += encoded
            data.append(UInt8(ascii: "\n"))
        }
        let path = url.path(percentEncoded: false)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            #if os(iOS)
                // Readable after the first unlock, like the cache: widgets draw while locked.
                let attributes: [FileAttributeKey: Any] = [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ]
            #else
                let attributes: [FileAttributeKey: Any] = [:]
            #endif
            fileManager.createFile(atPath: path, contents: nil, attributes: attributes)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return }
        try? handle.write(contentsOf: data)
        if end + UInt64(data.count) > UInt64(Self.maxBytes) {
            trim()
        }
    }

    /// Keeps the newer half of the log, cut at a line.
    private func trim() {
        guard let data = try? Data(contentsOf: url) else { return }
        let half = data.suffix(Self.maxBytes / 2)
        guard let newline = half.firstIndex(of: UInt8(ascii: "\n")) else { return }
        try? directory.write(Data(half[half.index(after: newline)...]), to: Self.fileName)
    }
}

/// One line of `latency.jsonl`.
public struct LatencyLine: Codable, Hashable, Sendable {
    public var n: UInt32
    public var stage: LatencyStage
    /// Milliseconds since 1970.
    public var at: Int64

    public init(n: UInt32, stage: LatencyStage, at: Date) {
        self.n = n
        self.stage = stage
        self.at = Int64((at.timeIntervalSince1970 * 1000).rounded())
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(at) / 1000)
    }
}

/// A change a sync applied, with Google's time for it.
struct LatencyChange: Hashable, Sendable {
    var key: String
    var after: String?
    var updated: Date
}

/// The link between a change's digests and its number. Device-private.
struct LatencyEntry: Codable, Hashable, Sendable {
    var key: String
    var after: String?
    var n: UInt32?
    var created: Date
    var updated: Date?
    /// Surfaces that drew the change before the app gave it a number.
    var seen: [LatencyStage: Date] = [:]
    /// Surfaces already in the log for `n`.
    var logged: Set<LatencyStage> = []

    init(key: String, after: String?, created: Date) {
        self.key = key
        self.after = after
        self.created = created
    }
}
