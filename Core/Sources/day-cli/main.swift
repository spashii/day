import DayCore
import Foundation

// Prints a fixture's days and months through the shared rules, so the rules can be read and
// checked without a simulator:
//
//   day-cli day [yyyy-mm-dd] [--now 12:10 | 2026-11-04T12:10] [--fixture invented-week.json]
//               [--fetched 9:12] [--signed-out 1] [--timeline]
//   day-cli month yyyy-mm [--now ...] [--fixture ...] [--all]
//
// `day` prints the summary, the rows, the menu bar label and the three Lock Screen families
// as of `now`; `--timeline` adds every entry the widget would schedule. The widget reads the
// data as fetched at `now` unless `--fetched` says otherwise (which brings out `As of 9:12`
// and `Open to update`), and `--signed-out` sets the number of signed-out accounts. `month`
// prints the
// mark of each event on each day: bars, titled lines and a count of dots; `--all` adds the
// hidden ones. A bare time in `--now` is on the given day, else on the fixture's own day.

struct Options {
    var command = ""
    var positional: [String] = []
    var now: String?
    var fixture = "invented-week.json"
    var timeline = false
    var all = false
    var fetched: String?
    var signedOut = 0
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message): message
        }
    }
}

enum Help {
    static let usage = """
        usage:
          day-cli day [yyyy-mm-dd] [--now 12:10 | 2026-11-04T12:10] [--fixture invented-week.json]
                      [--fetched 9:12] [--signed-out 1] [--timeline]
          day-cli month yyyy-mm [--now ...] [--fixture ...] [--all]
        """
}

func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--now":
            guard let value = iterator.next() else { throw CLIError.usage("--now needs a value") }
            options.now = value
        case "--fixture":
            guard let value = iterator.next() else { throw CLIError.usage("--fixture needs a value") }
            options.fixture = value
        case "--fetched":
            guard let value = iterator.next() else { throw CLIError.usage("--fetched needs a value") }
            options.fetched = value
        case "--signed-out":
            guard let value = iterator.next(), let count = Int(value) else {
                throw CLIError.usage("--signed-out needs a number")
            }
            options.signedOut = count
        case "--timeline":
            options.timeline = true
        case "--all":
            options.all = true
        case "-h", "--help":
            throw CLIError.usage(Help.usage)
        default:
            if argument.hasPrefix("--") { throw CLIError.usage("unknown option \(argument)\n\(Help.usage)") }
            if options.command.isEmpty {
                options.command = argument
            } else {
                options.positional.append(argument)
            }
        }
    }
    return options
}

/// Where a fixture name resolves: as given, then the test fixtures folder found from the
/// working directory or from this source file, so `--fixture invented-week.json` works from
/// anywhere in a checkout.
func fixtureURL(_ name: String) throws -> URL {
    let fileManager = FileManager.default
    var candidates = [URL(fileURLWithPath: name)]
    let fixtures = "Tests/DayCoreTests/Fixtures"
    let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    candidates.append(cwd.appendingPathComponent("\(fixtures)/\(name)"))
    candidates.append(cwd.appendingPathComponent("Core/\(fixtures)/\(name)"))
    let source = URL(fileURLWithPath: #filePath)
    candidates.append(
        source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("\(fixtures)/\(name)"))
    for url in candidates {
        for candidate in [url, url.appendingPathExtension("json")]
        where fileManager.fileExists(atPath: candidate.path) && !candidate.hasDirectoryPath {
            return candidate
        }
    }
    throw CLIError.usage("fixture not found: \(name)")
}

func parseNow(_ text: String, day: CivilDate?, fixture: Fixture, calendar: Calendar) throws -> Date {
    let bad = CLIError.usage("cannot read --now \(text): use 12:10 or 2026-11-04T12:10")
    func atTime(_ time: Substring, on date: CivilDate) throws -> Date {
        let parts = time.split(separator: ":")
        guard parts.count == 2 || parts.count == 3, let hour = Int(parts[0]), let minute = Int(parts[1]),
            (0...23).contains(hour), (0...59).contains(minute),
            let result = calendar.date(
                bySettingHour: hour, minute: minute, second: 0, of: date.date(in: calendar))
        else { throw bad }
        return result
    }
    if text.contains("T") {
        if let exact = try? Date(text, strategy: .iso8601) { return exact }
        let parts = text.split(separator: "T", maxSplits: 1)
        guard parts.count == 2, let date = CivilDate(String(parts[0])) else { throw bad }
        return try atTime(parts[1], on: date)
    }
    return try atTime(Substring(text), on: day ?? CivilDate(fixture.now, in: calendar))
}

func printDay(
    _ day: CivilDate, now: Date, fetchedAt: Date, fixture: Fixture, events: [Event], options: Options
) {
    let calendar = fixture.calendar
    let time = { (date: Date) in Formatting.time(date, calendar: calendar) }

    print("\(Formatting.dayHeader(day, calendar: calendar)) \(day.year), now \(Formatting.dayHeader(CivilDate(now, in: calendar), calendar: calendar)) \(time(now)) (\(fixture.timeZone), \(fixture.locale))")

    let summary = summarize(day: day, events: events, now: now, calendar: calendar)
    print("\nSummary")
    print("  \(summary.first)")
    if let second = summary.second { print("  \(second)") }

    print("\nRows")
    for row in dayRows(day: day, events: events, now: now, calendar: calendar) {
        switch row {
        case .allDay(let event, let position):
            print("  all-day      \(event.title)\(position.map { ", \($0)" } ?? "")")
        case .allDayMore(let text):
            print("  all-day      \(text)")
        case .earlier(let earlier):
            print("  \(Formatting.earlier(earlier))")
        case .nowLine(let at):
            print("  \(time(at).padding(toLength: 12, withPad: " ", startingAt: 0)) ---- now")
        case .event(let event, let second, let join):
            let range = "\(time(event.time.start(in: calendar)))-\(time(event.time.end(in: calendar)))"
            var line = "  \(range.padding(toLength: 12, withPad: " ", startingAt: 0)) \(event.title)"
            if let second { line += "   \(second)" }
            if join { line += "   [Join]" }
            print(line)
        case .gap(let text, _):
            print("               \(text)")
        }
    }

    let upcoming = nextEvents(events: events, now: now, calendar: calendar)
    let label = menuBarLabel(next: upcoming, now: now, calendar: calendar)
    print("\nMenu bar")
    print("  \(label.showsSymbol ? "[calendar] " : "")\(label.text ?? "")")
    if let join = joinableEvent(next: upcoming, now: now) { print("  Command-J joins: \(join.title)") }

    let entries = widgetTimeline(
        events: events, now: now, fetchedAt: fetchedAt, signedOutAccounts: options.signedOut,
        calendar: calendar)
    print("\nLock Screen as of \(time(now))")
    if let entry = entries.first { printEntry(entry, now: now, calendar: calendar, indent: "  ") }
    if options.timeline {
        print("\nTimeline, \(entries.count) entries")
        for entry in entries {
            print("  \(time(entry.date))  \(entry.inline) | \(entry.rectangular.title) | \(circularText(entry.circular))")
        }
    }
}

func circularText(_ circular: CircularContent) -> String {
    switch circular {
    case .symbol: "[calendar]"
    case .time(let time, let weekday, let period):
        [weekday, time, period].compactMap { $0 }.joined(separator: " ")
    }
}

func printEntry(_ entry: WidgetEntry, now: Date, calendar: Calendar, indent: String) {
    print("\(indent)inline       \(entry.inline)")
    let lines = entry.rectangular
    print("\(indent)rectangular  \(lines.title)")
    if let when = lines.when {
        var text = when.text
        if let start = when.relativeTo {
            text += " · in \(Formatting.countdown(start.timeIntervalSince(now)))"
        }
        print("\(indent)             \(text)")
        if when.reduced != when.text { print("\(indent)             always-on: \(when.reduced)") }
    }
    if let after = lines.after { print("\(indent)             \(after)") }
    print("\(indent)circular     \(circularText(entry.circular))")
}

func printMonth(year: Int, month: Int, now: Date, fixture: Fixture, events: [Event], options: Options) {
    let calendar = fixture.calendar
    let accounts = Dictionary(uniqueKeysWithValues: fixture.accounts.map { ($0.id, $0) })
    let calendars = Dictionary(uniqueKeysWithValues: fixture.calendars.map { ($0.id, $0) })
    let today = CivilDate(now, in: calendar)
    let first = CivilDate(year: year, month: month, day: 1)
    let nextMonth = month == 12
        ? CivilDate(year: year + 1, month: 1, day: 1) : CivilDate(year: year, month: month + 1, day: 1)
    let last = nextMonth.adding(days: -1)

    print("\(Formatting.monthTitle(year: year, month: month, now: now, calendar: calendar, alwaysYear: true)) (\(fixture.timeZone), today \(today))")
    for day in first...last {
        var bars: [String] = []
        var lines: [(Date, String)] = []
        var dots = 0
        var hidden: [String] = []
        for event in events where coveredDays(event, calendar: calendar).contains(day) {
            guard let account = accounts[event.account], let info = calendars[event.id.calendar] else {
                continue
            }
            let mark = monthMark(event, account: account, calendar: info, in: calendar)
            let color = info.isHoliday ? ColorKey.gray : event.colorKey
            switch mark {
            case .hidden:
                hidden.append(event.title)
            case .bar:
                let covered = coveredDays(event, calendar: calendar)
                let span = covered.count > 1
                    ? " \(covered.lowerBound.distance(to: day) + 1)/\(covered.count)" : ""
                bars.append("bar \(event.title)\(span) [\(color.rawValue)]")
            case .titled:
                let start = event.time.start(in: calendar)
                lines.append((start, "line \(Formatting.time(start, calendar: calendar)) \(event.title) [\(color.rawValue)]"))
            case .dot:
                dots += 1
            }
        }
        let marker = day == today ? "*" : " "
        let weekday = Formatting.shortWeekday(day.date(in: calendar), calendar: calendar)
        var parts = bars + lines.sorted { $0.0 < $1.0 }.map { $0.1 }
        if dots > 0 { parts.append("dots \(dots)") }
        if options.all && !hidden.isEmpty { parts.append("hidden: \(hidden.joined(separator: ", "))") }
        print("\(day.isoString) \(weekday)\(marker) \(parts.joined(separator: "; "))"
            .trimmingCharacters(in: .whitespaces))
    }
}

func run() throws {
    let options = try parse(Array(CommandLine.arguments.dropFirst()))
    let fixture = try Fixture.load(from: fixtureURL(options.fixture))
    let calendar = fixture.calendar
    let events = fixture.visibleEvents()

    switch options.command {
    case "day":
        let day = try options.positional.first.map { text -> CivilDate in
            guard let day = CivilDate(text) else { throw CLIError.usage("not a date: \(text)") }
            return day
        }
        let now = try options.now.map { try parseNow($0, day: day, fixture: fixture, calendar: calendar) }
            ?? fixture.now
        let fetchedAt = try options.fetched.map {
            try parseNow($0, day: CivilDate(now, in: calendar), fixture: fixture, calendar: calendar)
        } ?? now
        printDay(
            day ?? CivilDate(now, in: calendar), now: now, fetchedAt: fetchedAt, fixture: fixture,
            events: events, options: options)
    case "month":
        let parts = options.positional.first?.split(separator: "-") ?? []
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month)
        else { throw CLIError.usage("month needs yyyy-mm\n\(Help.usage)") }
        let now = try options.now.map { try parseNow($0, day: nil, fixture: fixture, calendar: calendar) }
            ?? fixture.now
        printMonth(year: year, month: month, now: now, fixture: fixture, events: events, options: options)
    default:
        throw CLIError.usage(Help.usage)
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}
