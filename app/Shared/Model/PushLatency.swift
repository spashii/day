import DayCore
import Foundation

/// Where this device keeps its latency log (`LatencyLog`), and how a TestFlight build lets
/// it out.
enum PushLatency {
    /// The folder every timed process can write to. On the Mac that is the App Group the
    /// desktop widget shares, when this build may use it; otherwise the app's own folder,
    /// and the desktop widget, which then has no data either, writes nothing. On iPhone it is
    /// the App Group, where the app and the Lock Screen widget both write.
    static func directory() -> CacheDirectory? {
        #if os(macOS)
            if let group = MacWidgetGroup.cache() { return group }
        #endif
        return try? BuildFolder.cache()
    }

    #if os(iOS)
        static let reportName = "latency.txt"

        /// Copies the log, and its percentiles as text, into Documents, which the Files app
        /// shows under On My iPhone (`UIFileSharingEnabled`), so a TestFlight build can share
        /// them. Neither file holds a title or an ID. Skipped when the copy is already as new
        /// as the log.
        static func exportForSharing() {
            guard let directory = directory() else { return }
            let log = LatencyLog(directory: directory)
            let fileManager = FileManager.default
            let documents = URL.documentsDirectory
            let copy = documents.appending(path: LatencyLog.fileName)
            guard let source = modified(log.url, fileManager) else { return }
            if let copied = modified(copy, fileManager), copied >= source { return }
            guard let data = try? Data(contentsOf: log.url) else { return }
            try? fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
            try? data.write(to: copy, options: .atomic)
            let report = LatencyReport(lines: LatencyLog.lines(at: log.url)).text
            try? Data(report.utf8).write(to: documents.appending(path: reportName), options: .atomic)
        }

        private static func modified(_ url: URL, _ fileManager: FileManager) -> Date? {
            (try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false)))?[
                .modificationDate] as? Date
        }
    #endif
}
