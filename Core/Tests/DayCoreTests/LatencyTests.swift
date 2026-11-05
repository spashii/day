import Foundation
import Testing

@testable import DayCore

/// The latency log: which changes a sync applied, how the app's and the widgets' sightings of
/// one change are joined under one random number, and the percentiles read from it. Every
/// event here is invented.
struct LatencyTests {
    typealias T = TestData

    static let calendar = T.amsterdam
    static let token = "token-before"

    static func data(
        _ events: [Event], token: String? = LatencyTests.token, personal: [Event] = []
    ) -> CalendarData {
        let sync = CalendarSync(
            calendar: T.workCalendar.id, token: token, tokenFrom: .distantPast, tokenTo: .distantFuture,
            fullSyncAt: .distantPast, syncedAt: .distantPast, days: T.day("2026-10-01")...T.day("2027-03-01"))
        return CalendarData(
            accounts: [T.work, T.personal],
            calendarsByAccount: [T.work.id: [T.workCalendar], T.personal.id: [T.personalCalendar]],
            eventsByAccount: [T.work.id: events, T.personal.id: personal],
            syncByAccount: [T.work.id: [sync]])
    }

    static func folder() -> CacheDirectory {
        CacheDirectory(
            url: FileManager.default.temporaryDirectory.appending(path: "day-latency-\(UUID().uuidString)"))
    }

    static func snapshot(_ events: [Event], at date: Date) -> WidgetSnapshot {
        WidgetSnapshot(fetchedAt: date, accountCount: 1, signedOutAccounts: 0, events: events)
    }

    static let review = T.event("Design review", "2026-11-04 14:00", "2026-11-04 15:00", id: "review")
    static let lunch = T.event("Lunch", "2026-11-04 12:30", "2026-11-04 13:15", id: "lunch")
    static let planning = T.event("Weekly planning", "2026-11-04 16:00", "2026-11-04 17:00", id: "planning")

    // MARK: Which changes a sync applied

    @Test func aChangeIsWhatASurfaceShows() throws {
        var moved = Self.review
        moved.time = .timed(
            start: T.wednesday("15:00"), end: T.wednesday("16:00"), authoredZone: "Europe/Amsterdam")
        var described = Self.lunch
        described.description = "Bring the numbers."
        let added = T.event("Investor call", "2026-11-05 10:00", "2026-11-05 11:00", id: "call")

        let found = LatencyDiff.candidates(
            from: Self.data([Self.review, Self.lunch, Self.planning]),
            to: Self.data([moved, described, added], token: "token-after"))
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.event.googleID, $0) })
        // Moved, added and removed count; a new description shows nowhere a timer runs.
        #expect(Set(byID.keys) == ["review", "call", "planning"])
        #expect(byID["review"]?.after == LatencyDigest.content(moved))
        #expect(byID["call"]?.after == LatencyDigest.content(added))
        #expect(byID["planning"]?.after == nil)
        // Each is read again from the token the calendar had before the sync.
        #expect(found.allSatisfy { $0.token == Self.token })
        #expect(byID["review"]?.key == LatencyDigest.key(Self.review))
    }

    @Test func aCalendarWithNoTokenBeforeHasNothingToCompare() {
        let added = T.event("Dentist", "2026-11-04 09:00", "2026-11-04 09:30", id: "dentist", account: T.personal)
        let found = LatencyDiff.candidates(
            from: Self.data([], personal: []), to: Self.data([], personal: [added]))
        #expect(found.isEmpty)
    }

    @Test func theSameMeetingInTwoAccountsIsOneKey() {
        let mine = T.event("Design review", "2026-11-04 14:00", "2026-11-04 15:00", id: "a1", uid: "shared@acme.com")
        let theirs = T.event(
            "Design review", "2026-11-04 14:00", "2026-11-04 15:00", id: "b2", uid: "shared@acme.com",
            account: T.personal)
        #expect(LatencyDigest.key(mine) == LatencyDigest.key(theirs))
        #expect(LatencyDigest.content(mine) == LatencyDigest.content(theirs))
    }

    // MARK: What a widget's draw shows

    @Test func onlyDaysBothDrawsCoveredCanChange() {
        let tuesday = T.event("Offsite", "2026-11-03 10:00", "2026-11-03 11:00", id: "offsite")
        let farAhead = T.event("Board", "2026-11-12 10:00", "2026-11-12 11:00", id: "board")
        var renamed = Self.review
        renamed.title = "Design review (moved room)"
        let monday = LatencyRender(
            .iphoneWidget, snapshot: Self.snapshot([tuesday, Self.review], at: T.date("2026-11-03 09:00")),
            at: T.date("2026-11-03 09:00"), calendar: Self.calendar)
        let wednesday = LatencyRender(
            .iphoneWidget,
            snapshot: Self.snapshot([renamed, farAhead], at: T.date("2026-11-04 09:00")),
            at: T.date("2026-11-04 09:00"), calendar: Self.calendar)
        let found = LatencyRender.appearances(from: monday, to: wednesday, calendar: Self.calendar)
        // Tuesday left the window and the 12th entered it; only the renamed review changed.
        #expect(found.count == 1)
        #expect(found.first?.key == LatencyDigest.key(Self.review))
        #expect(found.first?.after == LatencyDigest.content(renamed))
    }

    @Test func theMacWidgetOnlyCountsToday() {
        let render = LatencyRender(
            .macWidget, snapshot: Self.snapshot([Self.review, T.event("Board", "2026-11-05 10:00", "2026-11-05 11:00")], at: T.wednesday("09:00")),
            at: T.wednesday("09:00"), calendar: Self.calendar)
        #expect(render.events.count == 1)
    }

    // MARK: Joining one change across processes

    @Test func theAppFirstThenTheWidget() throws {
        let log = LatencyLog(directory: Self.folder())
        var renamed = Self.review
        renamed.title = "Design review, room 4"
        let updated = T.wednesday("10:00:00")
        log.recordRender(.iphoneWidget, snapshot: Self.snapshot([Self.review], at: T.wednesday("09:00")), at: T.wednesday("09:00"), calendar: Self.calendar)

        log.recordSync(
            [LatencyChange(key: LatencyDigest.key(renamed), after: LatencyDigest.content(renamed), updated: updated)],
            synced: T.wednesday("10:00:04"), pushes: [T.wednesday("09:30"), T.wednesday("10:00:02")],
            appShown: T.wednesday("10:00:05"), random: { 7 })
        log.recordRender(
            .iphoneWidget, snapshot: Self.snapshot([renamed], at: T.wednesday("10:00:06")),
            at: T.wednesday("10:00:09"), calendar: Self.calendar)

        let lines = log.lines()
        #expect(lines.allSatisfy { $0.n == 7 })
        #expect(
            lines.map(\.stage) == [.updated, .push, .synced, .macApp, .iphoneWidget])
        // The push that came after the change, not the one before it.
        #expect(lines[1].date == T.wednesday("10:00:02"))
        #expect(lines.last?.date == T.wednesday("10:00:09"))
    }

    @Test func theWidgetFirstThenTheApp() throws {
        let log = LatencyLog(directory: Self.folder())
        let added = T.event("Investor call", "2026-11-04 16:00", "2026-11-04 17:00", id: "call")
        log.recordRender(.iphoneWidget, snapshot: Self.snapshot([Self.review], at: T.wednesday("09:00")), at: T.wednesday("09:00"), calendar: Self.calendar)
        // The widget's own read found the new event before the app was woken.
        log.recordRender(
            .iphoneWidget, snapshot: Self.snapshot([Self.review, added], at: T.wednesday("10:00:03")),
            at: T.wednesday("10:00:03"), calendar: Self.calendar)
        #expect(log.lines().isEmpty)

        log.recordSync(
            [LatencyChange(key: LatencyDigest.key(added), after: LatencyDigest.content(added), updated: T.wednesday("10:00:00"))],
            synced: T.wednesday("10:00:30"), pushes: [], appShown: nil, random: { 9 })
        let lines = log.lines()
        #expect(lines.map(\.stage) == [.updated, .synced, .iphoneWidget])
        #expect(lines.last?.date == T.wednesday("10:00:03"))

        // Drawn again later, it is not counted twice.
        log.recordRender(
            .iphoneWidget, snapshot: Self.snapshot([Self.review], at: T.wednesday("11:00")),
            at: T.wednesday("11:00"), calendar: Self.calendar)
        log.recordRender(
            .iphoneWidget, snapshot: Self.snapshot([Self.review, added], at: T.wednesday("11:30")),
            at: T.wednesday("11:30"), calendar: Self.calendar)
        #expect(log.lines().filter { $0.stage == .iphoneWidget }.count == 1)
    }

    @Test func aSightingFromBeforeTheChangeIsNotCounted() throws {
        let log = LatencyLog(directory: Self.folder())
        log.recordRender(.iphoneWidget, snapshot: Self.snapshot([Self.review], at: T.wednesday("08:00")), at: T.wednesday("08:00"), calendar: Self.calendar)
        log.recordRender(.iphoneWidget, snapshot: Self.snapshot([], at: T.wednesday("08:30")), at: T.wednesday("08:30"), calendar: Self.calendar)
        // The same removal digest, but Google says it happened at ten.
        log.recordSync(
            [LatencyChange(key: LatencyDigest.key(Self.review), after: nil, updated: T.wednesday("10:00"))],
            synced: T.wednesday("10:00:05"), pushes: [], appShown: nil, random: { 3 })
        #expect(log.lines().map(\.stage) == [.updated, .synced])
    }

    @Test func theLogHoldsNoTitlesAndNoIDs() throws {
        let folder = Self.folder()
        let log = LatencyLog(directory: folder)
        log.recordRender(.iphoneWidget, snapshot: Self.snapshot([Self.review], at: T.wednesday("09:00")), at: T.wednesday("09:00"), calendar: Self.calendar)
        log.recordSync(
            [LatencyChange(key: LatencyDigest.key(Self.lunch), after: LatencyDigest.content(Self.lunch), updated: T.wednesday("10:00"))],
            synced: T.wednesday("10:00:05"), pushes: [], appShown: nil)
        log.recordRender(
            .iphoneWidget, snapshot: Self.snapshot([Self.review, Self.lunch], at: T.wednesday("10:00:06")),
            at: T.wednesday("10:00:06"), calendar: Self.calendar)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(!text.isEmpty)
        for secret in ["Lunch", "Design review", "lunch", "review", "you@acme.com", "Lunch@"] {
            #expect(!text.contains(secret))
        }
        for line in text.split(separator: "\n") {
            let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(Set(object.keys) == ["n", "stage", "at"])
        }
    }

    // MARK: Catching up is not the push path

    /// A recorder over a Google that dates each event as `updated` says.
    static func recorder(updated: [String: Date]) -> (LatencyRecorder, LatencyLog) {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let items = updated.sorted { $0.key < $1.key }
            .map { #"{"id": "\#($0.key)", "updated": "\#(stamp.string(from: $0.value))"}"# }
        let body = Data(#"{"items": [\#(items.joined(separator: ", "))]}"#.utf8)
        let stub = DecodingTests.Stub { _ in (200, body, ["Content-Type": "application/json"]) }
        let tokens = MemoryTokenStore([
            T.work.id: StoredToken(
                refreshToken: "refresh", accessToken: "access",
                accessExpiry: Date().addingTimeInterval(3600), email: "you@acme.com",
                scope: DecodingTests.Recorded.fullScope)
        ])
        let directory = folder()
        let engine = SyncEngine(
            auth: GoogleAuth(clientID: DecodingTests.Recorded.clientID, transport: stub, retry: .noWait),
            tokens: tokens, cache: directory, api: CalendarAPI(transport: stub, retry: .noWait),
            calendar: calendar)
        return (LatencyRecorder(directory: directory, engine: engine), LatencyLog(directory: directory))
    }

    @Test func changesMadeWhileTheMacSleptAreNotTimed() async throws {
        // Last night's change and this morning's, both found by the sync at wake.
        let (recorder, log) = Self.recorder(updated: [
            "review": T.wednesday("07:00:00"), "lunch": T.wednesday("09:30:00"),
        ])
        var moved = Self.review
        moved.time = .timed(
            start: T.wednesday("15:00"), end: T.wednesday("16:00"), authoredZone: "Europe/Amsterdam")
        var renamed = Self.lunch
        renamed.title = "Lunch with Ines"

        await recorder.syncFinished(
            from: Self.data([Self.review, Self.lunch]),
            to: Self.data([moved, renamed], token: "token-after"),
            at: T.wednesday("09:30:04"), pushes: [T.wednesday("09:30:02")], appShown: nil,
            receivingSince: T.wednesday("09:00:00"))
        let lines = log.lines()
        // Only the change made after the wake is in the log, from its own `updated` time.
        #expect(Set(lines.map(\.n)).count == 1)
        #expect(lines.map(\.stage) == [.updated, .push, .synced])
        #expect(lines.first?.date == T.wednesday("09:30:00"))
        #expect(LatencyReport(lines: lines).changes == 1)
    }

    @Test func withoutAWakeEveryChangeIsTimed() async throws {
        let (recorder, log) = Self.recorder(updated: ["review": T.wednesday("07:00:00")])
        var moved = Self.review
        moved.time = .timed(
            start: T.wednesday("15:00"), end: T.wednesday("16:00"), authoredZone: "Europe/Amsterdam")
        await recorder.syncFinished(
            from: Self.data([Self.review]), to: Self.data([moved], token: "token-after"),
            at: T.wednesday("07:00:03"), pushes: [], appShown: nil)
        #expect(log.lines().map(\.stage) == [.updated, .synced])
    }

    // MARK: The report

    @Test func percentilesAreNearestRank() {
        let values = (1...10).map(Double.init)
        #expect(LatencyReport.percentile(values, 50) == 5)
        #expect(LatencyReport.percentile(values, 90) == 9)
        #expect(LatencyReport.percentile([4], 90) == 4)
        #expect(LatencyReport.percentile([], 50) == nil)
    }

    @Test func theReportTimesEachStageFromUpdated() {
        let base = T.wednesday("10:00")
        var lines: [LatencyLine] = []
        for n in UInt32(1)...10 {
            lines.append(LatencyLine(n: n, stage: .updated, at: base))
            lines.append(LatencyLine(n: n, stage: .synced, at: base.addingTimeInterval(Double(n))))
            if n <= 4 {
                lines.append(LatencyLine(n: n, stage: .macWidget, at: base.addingTimeInterval(Double(n) + 1)))
            }
        }
        // A line with no `updated` cannot be timed, and a cut line is skipped when read.
        lines.append(LatencyLine(n: 99, stage: .synced, at: base))
        let report = LatencyReport(lines: lines)
        #expect(report.changes == 10)
        let synced = report.rows.first { $0.stage == .synced }
        #expect(synced?.count == 10)
        #expect(synced?.p50 == 5)
        #expect(synced?.p90 == 9)
        #expect(report.rows.first { $0.stage == .macWidget }?.p90 == 5)
        #expect(report.rows.first { $0.stage == .iphoneWidget }?.p50 == nil)
        #expect(report.text.contains("mac-widget"))
    }

    @Test func aCutLineIsSkippedWhenRead() throws {
        let folder = Self.folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let text = #"{"at":1,"n":1,"stage":"updated"}"# + "\n" + #"{"at":2,"n":1,"sta"#
        try Data(text.utf8).write(to: folder.fileURL(LatencyLog.fileName))
        #expect(LatencyLog(directory: folder).lines().count == 1)
    }
}
