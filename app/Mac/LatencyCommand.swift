import DayCore
import Foundation

/// `Day --latency [file]`: prints the 50th and 90th percentile of each stage of the latency
/// log and exits before any window opens. Without a file it reads this Mac's own log; a file
/// shared from the iPhone (`latency.jsonl` in Files, On My iPhone, Day) can be passed as is.
///
///     /Applications/Day.app/Contents/MacOS/Day --latency
enum LatencyCommand {
    static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: "--latency") else { return }
        let given = arguments.dropFirst(index + 1).first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        guard
            let url = given.map({ URL(filePath: ($0 as NSString).expandingTildeInPath) })
                ?? PushLatency.directory().map({ LatencyLog(directory: $0).url })
        else {
            FileHandle.standardError.write(Data("No latency log on this Mac.\n".utf8))
            exit(1)
        }
        print(LatencyReport(lines: LatencyLog.lines(at: url)).text, terminator: "")
        exit(0)
    }
}
