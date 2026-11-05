import Foundation

/// The 50th and 90th percentile of each stage, counted from Google's `updated` time, over the
/// changes in a latency log. A stage only counts changes that reached it: a change outside
/// the Lock Screen's days is in the `synced` row and not in `iphone-widget`.
public struct LatencyReport: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        public var stage: LatencyStage
        public var count: Int
        /// Seconds after `updated`; nil when no change reached the stage.
        public var p50: Double?
        public var p90: Double?
    }

    /// Changes with an `updated` time, which are the ones that can be timed.
    public var changes: Int
    public var rows: [Row]

    public init(lines: [LatencyLine]) {
        var first: [UInt32: [LatencyStage: Int64]] = [:]
        for line in lines {
            let current = first[line.n]?[line.stage]
            if current == nil || line.at < current! {
                first[line.n, default: [:]][line.stage] = line.at
            }
        }
        let timed = first.values.filter { $0[.updated] != nil }
        changes = timed.count
        rows = LatencyStage.allCases.filter { $0 != .updated }.map { stage in
            let seconds = timed.compactMap { stages -> Double? in
                guard let at = stages[stage], let updated = stages[.updated] else { return nil }
                return Double(at - updated) / 1000
            }.sorted()
            return Row(
                stage: stage, count: seconds.count,
                p50: LatencyReport.percentile(seconds, 50), p90: LatencyReport.percentile(seconds, 90))
        }
    }

    /// Nearest rank: the smallest value with at least `p` percent of the values at or below
    /// it. Nil for no values.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// Plain text for a terminal or a shared file.
    public var text: String {
        func seconds(_ value: Double?) -> String {
            value.map { String(format: "%.1f s", $0) } ?? "-"
        }
        func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
            let space = String(repeating: " ", count: max(0, width - text.count))
            return left ? text + space : space + text
        }
        var lines = ["\(changes) changes timed from Google's updated time"]
        lines.append(pad("stage", 14, left: true) + pad("count", 6) + pad("p50", 10) + pad("p90", 10))
        for row in rows {
            lines.append(
                pad(row.stage.rawValue, 14, left: true) + pad(String(row.count), 6)
                    + pad(seconds(row.p50), 10) + pad(seconds(row.p90), 10))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
