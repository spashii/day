import Foundation
import Synchronization
import Testing

@testable import DayCore

/// Incremental sync against recorded, invented Google answers, step by step: the initial full
/// read with paging, then incremental reads that insert, update, delete, cancel an instance
/// of a series, move an instance and move an event to another calendar, a 410 that resets one
/// calendar, a calendar removed from the list, and the failures around them. Every person,
/// event and token here is invented.
///
/// Google is a script: each answer is keyed by the calendar, the token or window start, and
/// the page. A request with no scripted answer fails the step that sent it.
struct SyncTests {
    typealias Shared = DecodingTests.Shared
    typealias Stub = DecodingTests.Stub
    typealias Recorded = DecodingTests.Recorded

    static let account = AccountID(Recorded.gmailSub)
    static let personal = CalendarID(account: account, googleID: "you@gmail.com")
    static let family = CalendarID(account: account, googleID: "family7k@group.calendar.google.com")
    static let club = CalendarID(account: account, googleID: "club3m@group.calendar.google.com")
    /// `timeMin` of the full read on Wednesday 4 November: 30 September, Amsterdam midnight.
    static let fullFrom = "2026-09-29T22:00:00Z"
    /// `timeMax` of that read: the end of 11 March, today plus 127.
    static let fullTo = "2027-03-11T23:00:00Z"

    // MARK: Google as a script

    final class Google: Sendable {
        private let answers = Mutex<[String: (Int, String)]>([:])
        private let unscripted = Mutex<[String]>([])
        let offline = Shared(false)

        func answer(_ key: String, _ json: String, status: Int = 200) {
            answers.withLock { $0[key] = (status, json) }
        }

        var misses: [String] {
            unscripted.withLock { $0 }
        }

        /// `<calendar>:<syncToken or timeMin>` plus `+<pageToken>`, `list:<syncToken or full>`
        /// for the calendar list, `labels:<calendar>` for `calendars.get`.
        static func key(_ request: URLRequest) -> String {
            let url = request.url!
            let path = url.path(percentEncoded: false)
            let query = SyncTests.query(request)
            let page = query["pageToken"].map { "+" + $0 } ?? ""
            if path.hasSuffix("/users/me/calendarList") {
                return "list:" + (query["syncToken"] ?? "full") + page
            }
            let parts = path.dropFirst("/calendar/v3/".count).split(separator: "/").map(String.init)
            if parts.count == 3, parts[2] == "events" {
                return parts[1] + ":" + (query["syncToken"] ?? query["timeMin"] ?? "?") + page
            }
            return "labels:" + (parts.last ?? "")
        }

        var handler: Stub.Handler {
            { [self] request in
                if offline.value { throw URLError(.notConnectedToInternet) }
                if request.url?.host() == "oauth2.googleapis.com" {
                    return try Recorded.google()(request)
                }
                let key = Google.key(request)
                if let (status, json) = answers.withLock({ $0[key] }) {
                    return (status, Data(json.utf8), ["Content-Type": "application/json"])
                }
                if key.hasPrefix("labels:") {
                    return (200, Data(#"{"id": "\#(key.dropFirst(7))"}"#.utf8), [:])
                }
                unscripted.withLock { $0.append(key) }
                return (404, Data(), [:])
            }
        }
    }

    static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    /// One account with Personal, Family and Club, over a temporary folder and a clock the
    /// test moves.
    final class Harness: Sendable {
        let folder: URL
        let cache: CacheDirectory
        let google = Google()
        let stub: Stub
        let tokens = MemoryTokenStore()
        let clock: Shared<Date>
        let engine: SyncEngine
        let calendar: Calendar

        /// `wrapping` puts something between the engine and the recorded stub, such as a
        /// transport that never answers.
        init(wrapping wrap: (Stub) -> any HTTPTransport = { $0 }) throws {
            let fixture = try DecodingTests.fixture()
            calendar = fixture.calendar
            folder = FileManager.default.temporaryDirectory.appending(path: "day-sync-\(UUID().uuidString)")
            cache = CacheDirectory(url: folder)
            stub = Stub(google.handler)
            let transport = wrap(stub)
            let clock = Shared(fixture.now)
            self.clock = clock
            engine = SyncEngine(
                auth: GoogleAuth(clientID: Recorded.clientID, transport: transport, retry: .noWait),
                tokens: tokens, cache: cache, api: CalendarAPI(transport: transport, retry: .noWait),
                calendar: fixture.calendar, clock: { clock.value })
            try cache.write([Account(id: SyncTests.account, email: "you@gmail.com", addedAt: fixture.now)], to: CacheFile.accounts)
            try tokens.save(
                StoredToken(refreshToken: "refresh-gmail", email: "you@gmail.com", scope: Recorded.fullScope),
                for: SyncTests.account)
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
        }

        func advance(_ seconds: TimeInterval) {
            clock.update { $0 = $0.addingTimeInterval(seconds) }
        }

        /// Calendar requests from `index` on, as keys.
        func keys(from index: Int) -> [String] {
            stub.requests[index...].filter { $0.url?.host() == "www.googleapis.com" }.map(Google.key)
        }

        func stored() throws -> AccountCache {
            try #require(cache.account(SyncTests.account))
        }

        func titles(_ calendar: CalendarID) throws -> [String] {
            try stored().events.filter { $0.id.calendar == calendar }.map(\.title)
        }

        func event(_ googleID: String) throws -> Event? {
            try stored().events.first { $0.id.googleID == googleID }
        }

        /// The initial full read: the list, Personal in two pages, Family and Club in one.
        func scriptInitialSync() {
            google.answer("list:full", Script.list)
            google.answer("you@gmail.com:\(SyncTests.fullFrom)", Script.personalPage1)
            google.answer("you@gmail.com:\(SyncTests.fullFrom)+p2", Script.personalPage2)
            google.answer("family7k@group.calendar.google.com:\(SyncTests.fullFrom)", Script.familyFull)
            google.answer("club3m@group.calendar.google.com:\(SyncTests.fullFrom)", Script.clubFull)
        }

        /// The next read of every calendar and the list finds nothing new.
        func scriptQuiet(list: String, personal: String, family: String, club: String?) {
            google.answer("list:\(list)", #"{"items": [], "nextSyncToken": "\#(list)+"}"#)
            google.answer("you@gmail.com:\(personal)", #"{"items": [], "nextSyncToken": "\#(personal)+"}"#)
            google.answer("family7k@group.calendar.google.com:\(family)", #"{"items": [], "nextSyncToken": "\#(family)+"}"#)
            if let club {
                google.answer("club3m@group.calendar.google.com:\(club)", #"{"items": [], "nextSyncToken": "\#(club)+"}"#)
            }
        }
    }

    // MARK: The sequence

    @Test func initialSyncPagesUntilTheSyncTokenAndStoresItBesideTheEvents() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        let report = await h.engine.refresh()
        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)

        // Both pages of Personal, then the token from the last one.
        #expect(try Set(h.titles(SyncTests.personal)) == ["Standup", "Dentist", "Coffee with Ana", "Quarterly planning"])
        #expect(try h.titles(SyncTests.personal).count == 6)
        let state = try #require(try h.stored().state(of: SyncTests.personal))
        #expect(state.token == "s1")
        #expect(state.fullSyncAt == report.data.lastFetchedAt)
        #expect(state.days == CivilDate(year: 2026, month: 9, day: 30)...CivilDate(year: 2027, month: 3, day: 11))
        #expect(try h.stored().state(of: SyncTests.family)?.token == "f1")
        #expect(h.cache.read(CalendarsFile.self, from: CacheFile.calendars(SyncTests.account))?.syncToken == "l1")

        // The full read sends the window and no order; page 2 repeats it with the page token.
        let reads = h.stub.requests.filter { $0.url?.path(percentEncoded: false).contains("/you@gmail.com/events") == true }
        #expect(reads.count == 2)
        for request in reads {
            let query = SyncTests.query(request)
            #expect(query["timeMin"] == SyncTests.fullFrom)
            #expect(query["timeMax"] == SyncTests.fullTo)
            #expect(query["singleEvents"] == "true")
            #expect(query["orderBy"] == nil)
            #expect(query["syncToken"] == nil)
            #expect(query["showDeleted"] == nil)
        }
        #expect(SyncTests.query(reads[1])["pageToken"] == "p2")

        // Tokens sit in their own small file beside the events.
        let files = try FileManager.default.contentsOfDirectory(atPath: h.folder.path(percentEncoded: false))
        #expect(files.contains("sync-\(Recorded.gmailSub).json"))
        #expect(files.contains("events-\(Recorded.gmailSub).json"))
        #expect(report.data.syncedDays == state.days)
    }

    @Test func incrementalReadsInsertAndUpdateWithOnlyTheToken() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(180)
        let before = h.stub.requests.count
        h.google.answer("list:l1", #"{"items": [], "nextSyncToken": "l2"}"#)
        h.google.answer("you@gmail.com:s1", Script.personalInsertAndUpdate1)
        h.google.answer("you@gmail.com:s1+q2", Script.personalInsertAndUpdate2)
        h.google.answer("family7k@group.calendar.google.com:f1", #"{"items": [], "nextSyncToken": "f2"}"#)
        h.google.answer("club3m@group.calendar.google.com:c1", #"{"items": [], "nextSyncToken": "c2"}"#)
        let report = await h.engine.refresh()
        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)
        #expect(Set(h.keys(from: before)) == [
            "list:l1", "you@gmail.com:s1", "you@gmail.com:s1+q2",
            "family7k@group.calendar.google.com:f1", "club3m@group.calendar.google.com:c1",
        ])

        // Google refuses the window and the order beside a token; everything else matches the
        // full read, and page 2 repeats the same token.
        for request in h.stub.requests[before...] where request.url?.path().hasSuffix("/events") == true {
            let query = SyncTests.query(request)
            #expect(query["timeMin"] == nil)
            #expect(query["timeMax"] == nil)
            #expect(query["orderBy"] == nil)
            #expect(query["singleEvents"] == "true")
            #expect(query["maxResults"] == "2500")
            #expect(query["fields"]?.contains("nextSyncToken") == true)
        }

        let lunch = try #require(try h.event("lunch04"))
        #expect(lunch.title == "Lunch with Maya")
        #expect(try h.event("board09")?.title == "Board call")
        let coffee = try #require(try h.event("coffee10"))
        #expect(coffee.title == "Coffee with Ana and Tom")
        #expect(coffee.time.start(in: h.calendar) == GoogleDecoding.instant("2026-11-10T10:30:00+01:00"))
        #expect(try h.stored().events.filter { $0.id.googleID == "coffee10" }.count == 1)
        #expect(try h.stored().state(of: SyncTests.personal)?.token == "s2")
        #expect(try h.stored().state(of: SyncTests.family)?.token == "f2")
        // No full read happened, so the full read's date stays.
        #expect(try h.stored().state(of: SyncTests.personal)?.fullSyncAt == h.clock.value.addingTimeInterval(-180))
        #expect(report.data.lastFetchedAt == h.clock.value)
        // The widget sees the insert.
        #expect(report.snapshot?.events.contains { $0.title == "Lunch with Maya" } == true)
    }

    @Test func deletionsCancelledInstancesAndMovesApply() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(180)
        h.google.answer("list:l1", #"{"items": [], "nextSyncToken": "l2"}"#)
        h.google.answer("you@gmail.com:s1", Script.personalInsertAndUpdate1)
        h.google.answer("you@gmail.com:s1+q2", Script.personalInsertAndUpdate2)
        h.google.answer("family7k@group.calendar.google.com:f1", #"{"items": [], "nextSyncToken": "f2"}"#)
        h.google.answer("club3m@group.calendar.google.com:c1", #"{"items": [], "nextSyncToken": "c2"}"#)
        _ = await h.engine.refresh()

        h.advance(180)
        h.google.answer("list:l2", #"{"items": [], "nextSyncToken": "l3"}"#)
        h.google.answer("you@gmail.com:s2", Script.personalCancellations)
        h.google.answer("family7k@group.calendar.google.com:f2", Script.familyReceivesPlanning)
        h.google.answer("club3m@group.calendar.google.com:c2", #"{"items": [], "nextSyncToken": "c3"}"#)
        let report = await h.engine.refresh()
        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)

        // A deleted one-off, carrying nothing but its ID, is gone.
        #expect(try h.event("dentist07") == nil)
        // The organizer's own deleted copy still carries its details; it is gone too.
        #expect(try h.event("lunch04") == nil)
        // One cancelled instance goes; the rest of the series stays.
        #expect(try h.event("standupx_20261105T083000Z") == nil)
        #expect(try h.event("standupx_20261104T083000Z") != nil)
        // A moved instance keeps its ID and its slot in the series, at the new time.
        let moved = try #require(try h.event("standupx_20261106T083000Z"))
        #expect(moved.time.start(in: h.calendar) == GoogleDecoding.instant("2026-11-06T11:00:00+01:00"))
        #expect(moved.originalStart == GoogleDecoding.instant("2026-11-06T09:30:00+01:00"))
        // An event moved past the covered days does not stay at its old time.
        #expect(try h.event("coffee10") == nil)
        // An event moved to another calendar leaves a cancelled item behind and arrives there.
        #expect(try h.titles(SyncTests.personal).contains("Quarterly planning") == false)
        #expect(try h.titles(SyncTests.family).contains("Quarterly planning"))
        // The day reads the change.
        let friday = CivilDate(year: 2026, month: 11, day: 6)
        let day = report.data.events(in: friday...friday, calendar: h.calendar)
        #expect(day.filter { $0.title == "Standup" }.count == 1)
    }

    /// Not a shape Google documents: with `singleEvents` it sends deleted instances, not the
    /// series itself. If a cancelled series ever does arrive, its instances must not stay.
    @Test func aCancelledSeriesTakesItsInstancesAsABelt() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(180)
        h.scriptQuiet(list: "l1", personal: "x", family: "f1", club: "c1")
        h.google.answer("you@gmail.com:s1", #"{"items": [{"id": "standupx", "status": "cancelled"}], "nextSyncToken": "s2"}"#)
        _ = await h.engine.refresh()
        #expect(try h.stored().events.contains { $0.title == "Standup" } == false)
        #expect(try h.event("dentist07") != nil)
    }

    @Test func goneResetsOnlyThatCalendarAndWipesIt() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()

        // The Month scrolls into April: every calendar gets a stretch by window, from the
        // covered edge, so the days in between come too.
        h.google.answer("you@gmail.com:2027-03-11T23:00:00Z", Script.personalApril)
        h.google.answer("family7k@group.calendar.google.com:2027-03-11T23:00:00Z", #"{"items": []}"#)
        h.google.answer("club3m@group.calendar.google.com:2027-03-11T23:00:00Z", #"{"items": []}"#)
        let april = CivilDate(year: 2027, month: 4, day: 1)...CivilDate(year: 2027, month: 4, day: 30)
        let extended = await h.engine.extendWindow(toInclude: april)
        #expect(extended.outcome == .current)
        #expect(try h.event("trip0410") != nil)
        #expect(extended.data.syncedDays?.upperBound == CivilDate(year: 2027, month: 4, day: 30))

        h.advance(180)
        let before = h.stub.requests.count
        h.google.answer("list:l1", #"{"items": [], "nextSyncToken": "l2"}"#)
        h.google.answer("you@gmail.com:s1", Script.gone, status: 410)
        h.google.answer("you@gmail.com:\(SyncTests.fullFrom)", Script.personalAfterReset)
        h.google.answer("family7k@group.calendar.google.com:f1", #"{"items": [], "nextSyncToken": "f2"}"#)
        h.google.answer("club3m@group.calendar.google.com:c1", #"{"items": [], "nextSyncToken": "c2"}"#)
        let report = await h.engine.refresh()
        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)
        #expect(h.keys(from: before).contains("you@gmail.com:\(SyncTests.fullFrom)"))
        #expect(!h.keys(from: before).contains { $0.hasPrefix("family7k") && $0.contains(SyncTests.fullFrom) })

        // Personal was wiped and read again: what the old token knew is gone, what the new
        // read holds is there, and the April stretch is gone with the rest.
        #expect(try Set(h.titles(SyncTests.personal)) == ["Standup", "Design review"])
        #expect(try h.event("trip0410") == nil)
        let personal = try #require(try h.stored().state(of: SyncTests.personal))
        #expect(personal.token == "s4")
        #expect(personal.fullSyncAt == h.clock.value)
        #expect(personal.days.upperBound == CivilDate(year: 2027, month: 3, day: 11))
        // Family kept its token, its events and its April stretch.
        let family = try #require(try h.stored().state(of: SyncTests.family))
        #expect(family.token == "f2")
        #expect(family.fullSyncAt == h.clock.value.addingTimeInterval(-180))
        #expect(family.days.upperBound == CivilDate(year: 2027, month: 4, day: 30))
        #expect(try h.titles(SyncTests.family) == ["Dinner with Maya"])
        // The Month now asks for April again, because Personal no longer covers it.
        #expect(report.data.syncedDays?.upperBound == CivilDate(year: 2027, month: 3, day: 11))
    }

    @Test func aCalendarRemovedFromTheListTakesItsEventsAndToken() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        #expect(try h.titles(SyncTests.club) == ["Match"])
        h.advance(180)
        let before = h.stub.requests.count
        h.google.answer("list:l1", #"{"items": [{"id": "club3m@group.calendar.google.com", "deleted": true}], "nextSyncToken": "l2"}"#)
        h.google.answer("you@gmail.com:s1", #"{"items": [], "nextSyncToken": "s2"}"#)
        h.google.answer("family7k@group.calendar.google.com:f1", #"{"items": [], "nextSyncToken": "f2"}"#)
        let report = await h.engine.refresh()
        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)
        #expect(!h.keys(from: before).contains { $0.hasPrefix("club3m") })
        #expect(try h.titles(SyncTests.club).isEmpty)
        #expect(try h.stored().state(of: SyncTests.club) == nil)
        #expect(!report.data.calendars.contains { $0.id == SyncTests.club })
        #expect(report.data.calendars.map(\.name) == ["Personal", "Family"])

        // Hiding a calendar in Google's list removes it the same way.
        h.advance(180)
        h.google.answer("list:l2", #"{"items": [{"id": "family7k@group.calendar.google.com", "summary": "Family", "hidden": true, "accessRole": "writer"}], "nextSyncToken": "l3"}"#)
        h.google.answer("you@gmail.com:s2", #"{"items": [], "nextSyncToken": "s3"}"#)
        let again = await h.engine.refresh()
        #expect(again.data.calendars.map(\.name) == ["Personal"])
        #expect(try h.titles(SyncTests.family).isEmpty)
    }

    // MARK: When a full read runs

    @Test func aDayLaterEveryCalendarAndTheListAreReadInFull() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(25 * 3600)
        // Thursday: the window starts a day later.
        let from = "2026-09-30T22:00:00Z"
        h.google.answer("list:full", Script.list)
        h.google.answer("you@gmail.com:\(from)", Script.personalAfterReset)
        h.google.answer("family7k@group.calendar.google.com:\(from)", Script.familyFull)
        h.google.answer("club3m@group.calendar.google.com:\(from)", Script.clubFull)
        let before = h.stub.requests.count
        let report = await h.engine.refresh()
        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)
        #expect(h.keys(from: before).filter { $0.hasSuffix(from) }.count == 3)
        #expect(h.keys(from: before).contains("list:full"))
        #expect(try h.stored().state(of: SyncTests.personal)?.token == "s4")
        // The daily full read leaves no event the new read does not hold.
        #expect(try h.event("dentist07") == nil)
    }

    @Test func aFullReadStampedInTheFutureIsDue() throws {
        let now = Date(timeIntervalSince1970: 1_793_797_000)
        let today = CivilDate(now, in: Calendar(identifier: .gregorian))
        let days = SyncEngine.defaultWindow(today: today)
        let needed = SyncEngine.interval(days, calendar: Calendar(identifier: .gregorian))
        func plan(fullSyncAt: Date, token: String? = "t", to: Date = needed.end) -> CalendarPlan {
            CalendarSync(
                calendar: SyncTests.personal, token: token, tokenFrom: needed.start, tokenTo: to,
                fullSyncAt: fullSyncAt, syncedAt: fullSyncAt, days: days
            ).plan(needed: needed, neededDays: days, now: now)
        }
        #expect(plan(fullSyncAt: now.addingTimeInterval(-3600)) == .changes(since: "t"))
        // The clock moved back since the full read.
        #expect(plan(fullSyncAt: now.addingTimeInterval(3600)) == .full)
        #expect(plan(fullSyncAt: now.addingTimeInterval(-25 * 3600)) == .full)
        // The window slid past the token's.
        #expect(plan(fullSyncAt: now, to: needed.end.addingTimeInterval(-86_400)) == .full)
    }

    @Test func aCalendarWithNoTokenWaitsAnHourBetweenFullReads() throws {
        let now = Date(timeIntervalSince1970: 1_793_797_000)
        let today = CivilDate(now, in: Calendar(identifier: .gregorian))
        let days = SyncEngine.defaultWindow(today: today)
        let needed = SyncEngine.interval(days, calendar: Calendar(identifier: .gregorian))
        func plan(age: TimeInterval) -> CalendarPlan {
            let at = now.addingTimeInterval(-age)
            return CalendarSync(
                calendar: SyncTests.personal, token: nil, tokenFrom: needed.start,
                tokenTo: needed.end, fullSyncAt: at, syncedAt: at, days: days
            ).plan(needed: needed, neededDays: days, now: now)
        }
        #expect(plan(age: 60) == .wait)
        #expect(plan(age: CalendarSync.tokenlessRetry - 1) == .wait)
        #expect(plan(age: CalendarSync.tokenlessRetry) == .full)
        // A clock that moved back is not waited out.
        #expect(plan(age: -3600) == .full)
    }

    @Test func aCalendarWithNoTokenIsReadInFullOnceAnHour() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        h.google.answer(
            "club3m@group.calendar.google.com:\(SyncTests.fullFrom)",
            #"{"items": [{"id": "match08", "status": "confirmed", "summary": "Match", "start": {"dateTime": "2026-11-08T11:00:00+01:00"}, "end": {"dateTime": "2026-11-08T12:30:00+01:00"}}]}"#)
        _ = await h.engine.refresh()
        #expect(try h.stored().state(of: SyncTests.club)?.token == nil)

        // Three minutes on, the others read their changes and this one is left alone, with its
        // events as they were.
        h.advance(180)
        h.scriptQuiet(list: "l1", personal: "s1", family: "f1", club: nil)
        var before = h.stub.requests.count
        let quiet = await h.engine.refresh()
        #expect(quiet.outcome == .current)
        #expect(!h.keys(from: before).contains { $0.hasPrefix("club3m") })
        #expect(h.google.misses.isEmpty)
        #expect(try h.titles(SyncTests.club) == ["Match"])
        #expect(quiet.data.lastFetchedAt == h.clock.value)

        // An hour on, it is read in full again.
        h.advance(3600)
        h.scriptQuiet(list: "l1+", personal: "s1+", family: "f1+", club: nil)
        before = h.stub.requests.count
        _ = await h.engine.refresh()
        #expect(h.keys(from: before).contains("club3m@group.calendar.google.com:\(SyncTests.fullFrom)"))
        #expect(h.google.misses.isEmpty)
    }

    // MARK: A day of full reads, spread

    @Test func fullReadsAreSpreadOverSixHoursAndStayWhereTheyAre() {
        let sub = Recorded.gmailSub
        let keys = [
            "\(sub)/you@gmail.com", "\(sub)/family7k@group.calendar.google.com",
            "\(sub)/club3m@group.calendar.google.com", sub,
        ]
        let intervals = keys.map { CalendarSync.fullSyncInterval(for: $0) }
        for interval in intervals {
            #expect(interval <= CalendarSync.fullSyncPeriod)
            #expect(interval > CalendarSync.fullSyncPeriod - CalendarSync.fullSyncSpread)
        }
        #expect(Set(intervals).count == keys.count)
        // The same calendar lands in the same place on every launch.
        #expect(keys.map { CalendarSync.fullSyncInterval(for: $0) } == intervals)
    }

    @Test func noSingleRefreshReadsEveryCalendarInFull() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        let sub = SyncTests.account.sub
        let due = ["you@gmail.com", "family7k@group.calendar.google.com", "club3m@group.calendar.google.com"]
            .map { ($0, CalendarSync.fullSyncInterval(for: "\(sub)/\($0)")) }
            .sorted { $0.1 < $1.1 }
        // Just after the earliest calendar's interval, and before the next one's.
        try #require(due[1].1 - due[0].1 > 600)
        h.advance(due[0].1 + 120)
        h.google.answer("list:full", Script.list)
        h.google.answer("list:l1", #"{"items": [], "nextSyncToken": "l2"}"#)
        h.google.answer("you@gmail.com:s1", #"{"items": [], "nextSyncToken": "s2"}"#)
        h.google.answer("family7k@group.calendar.google.com:f1", #"{"items": [], "nextSyncToken": "f2"}"#)
        h.google.answer("club3m@group.calendar.google.com:c1", #"{"items": [], "nextSyncToken": "c2"}"#)
        // A full read is the one request carrying a window and not a token.
        let before = h.stub.requests.count
        _ = await h.engine.refresh()
        let windowed = h.stub.requests[before...].filter {
            $0.url?.path(percentEncoded: false).hasSuffix("/events") == true
                && SyncTests.query($0)["timeMin"] != nil
        }
        #expect(windowed.count == 1)
        #expect(windowed.first?.url?.path(percentEncoded: false).contains("/\(due[0].0)/") == true)
        #expect(h.stub.requests[before...].filter { SyncTests.query($0)["syncToken"] != nil }.count >= 2)
    }

    @Test func aStretchTheMonthFetchedExpiresAfterAnHour() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.google.answer("you@gmail.com:2027-03-11T23:00:00Z", Script.personalApril)
        h.google.answer("family7k@group.calendar.google.com:2027-03-11T23:00:00Z", #"{"items": []}"#)
        h.google.answer("club3m@group.calendar.google.com:2027-03-11T23:00:00Z", #"{"items": []}"#)
        let april = CivilDate(year: 2027, month: 4, day: 1)...CivilDate(year: 2027, month: 4, day: 30)
        let extended = await h.engine.extendWindow(toInclude: april)
        #expect(extended.data.syncedDays?.upperBound == CivilDate(year: 2027, month: 4, day: 30))

        // Half an hour on, the stretch is still trusted.
        h.advance(1800)
        h.scriptQuiet(list: "l1", personal: "s1", family: "f1", club: "c1")
        let soon = await h.engine.refresh()
        #expect(soon.data.syncedDays?.upperBound == CivilDate(year: 2027, month: 4, day: 30))

        // An hour after it was fetched it is not: the covered days return to the full read's,
        // and the trip stays on screen until the Month reads the stretch again.
        h.advance(1860)
        h.scriptQuiet(list: "l1+", personal: "s1+", family: "f1+", club: "c1+")
        let later = await h.engine.refresh()
        #expect(later.outcome == .current)
        #expect(later.data.syncedDays?.upperBound == CivilDate(year: 2027, month: 3, day: 11))
        #expect(try h.event("trip0410") != nil)
        #expect(h.google.misses.isEmpty)

        // The Month draws April again: it is read again and trusted for another hour.
        let again = await h.engine.extendWindow(toInclude: april)
        #expect(again.outcome == .current)
        #expect(again.data.syncedDays?.upperBound == CivilDate(year: 2027, month: 4, day: 30))
        #expect(try h.stored().state(of: SyncTests.personal)?.stretchedAt == h.clock.value)
    }

    @Test func aBadTokenEndsInAFullReadOfThatCalendar() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(180)
        h.scriptQuiet(list: "l1", personal: "s1", family: "f1", club: "c1")
        h.google.answer("you@gmail.com:s1", DecodingTests.Recorded.error(400, reason: "invalid", domain: "global"), status: 400)
        h.google.answer("you@gmail.com:\(SyncTests.fullFrom)", Script.personalAfterReset)
        let report = await h.engine.refresh()
        #expect(report.outcome == .current)
        #expect(try h.stored().state(of: SyncTests.personal)?.token == "s4")
        #expect(try h.stored().state(of: SyncTests.family)?.token == "f1+")
    }

    @Test func aCalendarWhoseColorChangedIsReadInFull() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(180)
        h.scriptQuiet(list: "l1", personal: "s1", family: "f1", club: "c1")
        h.google.answer("list:l1", ##"{"items": [{"id": "family7k@group.calendar.google.com", "summary": "Family", "backgroundColor": "#d50000", "selected": true, "accessRole": "writer", "timeZone": "Europe/Amsterdam"}], "nextSyncToken": "l2"}"##)
        h.google.answer("family7k@group.calendar.google.com:\(SyncTests.fullFrom)", Script.familyFull)
        let before = h.stub.requests.count
        _ = await h.engine.refresh()
        #expect(h.keys(from: before).contains("family7k@group.calendar.google.com:\(SyncTests.fullFrom)"))
        #expect(try h.stored().events.first { $0.title == "Dinner with Maya" }?.colorKey == .red)
        #expect(h.google.misses.isEmpty)
    }

    // MARK: Failure

    @Test func offlineKeepsEveryTokenAndTheNextReadStartsFromThem() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        let tokens = try h.stored().sync
        h.advance(180)
        h.google.offline.update { $0 = true }
        let report = await h.engine.refresh()
        #expect(report.outcome == .offline)
        #expect(try h.stored().sync == tokens)
        #expect(report.data.lastFetchedAt == h.clock.value.addingTimeInterval(-180))

        h.google.offline.update { $0 = false }
        h.advance(180)
        h.scriptQuiet(list: "l1", personal: "s1", family: "f1", club: "c1")
        let back = await h.engine.refresh()
        #expect(back.outcome == .current)
        #expect(h.google.misses.isEmpty)
        #expect(back.data.lastFetchedAt == h.clock.value)
    }

    @Test func oneCalendarFailingKeepsWhatTheOthersBrought() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(180)
        h.google.answer("list:l1", #"{"items": [], "nextSyncToken": "l2"}"#)
        h.google.answer("you@gmail.com:s1", Script.personalInsertAndUpdate1)
        h.google.answer("you@gmail.com:s1+q2", Script.personalInsertAndUpdate2)
        h.google.answer("family7k@group.calendar.google.com:f1", "", status: 503)
        h.google.answer("club3m@group.calendar.google.com:c1", #"{"items": [], "nextSyncToken": "c2"}"#)
        let report = await h.engine.refresh()
        #expect(report.outcome == .unreachable)
        #expect(try h.event("lunch04") != nil)
        #expect(try h.stored().state(of: SyncTests.personal)?.token == "s2")
        #expect(try h.stored().state(of: SyncTests.family)?.token == "f1")
        // The age on screen stays at the last refresh in which every calendar answered.
        #expect(report.data.lastFetchedAt == h.clock.value.addingTimeInterval(-180))
    }

    @Test func aPartialGrantSignsOutTheAccountAndKeepsItsEventsAndTokens() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        let tokens = try h.stored().sync
        // The person unticked calendar access in Google's settings: the next refresh token
        // answer lacks the scope.
        try h.tokens.save(
            StoredToken(refreshToken: "refresh-narrow", email: "you@gmail.com", scope: Recorded.fullScope),
            for: SyncTests.account)
        h.advance(2 * 3600)
        let report = await h.engine.refresh()
        #expect(report.newlySignedOut == [SyncTests.account])
        #expect(report.data.accounts.first?.signedOut == true)
        #expect(try h.stored().sync == tokens)
        #expect(report.data.eventsByAccount[SyncTests.account]?.isEmpty == false)
        #expect(report.snapshot?.signedOutAccounts == 1)
    }

    // MARK: The widget

    @Test func theWidgetReadsChangesFromTheAppsTokensAndWritesOnlyTheSnapshot() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        let appFiles = try h.stored()
        h.advance(20 * 60)
        h.google.answer("you@gmail.com:s1", Script.personalInsertAndUpdate1)
        h.google.answer("you@gmail.com:s1+q2", Script.personalInsertAndUpdate2)
        h.google.answer("family7k@group.calendar.google.com:f1", #"{"items": [], "nextSyncToken": "f2"}"#)
        h.google.answer("club3m@group.calendar.google.com:c1", #"{"items": [], "nextSyncToken": "c2"}"#)
        let before = h.stub.requests.count
        let snapshot = try #require(await h.engine.refreshWidgetSnapshot())
        #expect(h.google.misses.isEmpty)
        #expect(snapshot.fetchedAt == h.clock.value)
        #expect(snapshot.events.contains { $0.title == "Lunch with Maya" })
        #expect(WidgetSnapshot.read(from: h.cache) == snapshot)
        // Only changes, for visible calendars: no list, no window.
        #expect(h.keys(from: before).allSatisfy { $0.contains(":s1") || $0.contains(":f1") || $0.contains(":c1") })
        // The app's events and tokens are as the app left them.
        #expect(try h.stored() == appFiles)
    }

    @Test func theWidgetFallsBackToItsDaysWhenATokenIsGone() async throws {
        let h = try Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        h.advance(20 * 60)
        h.google.answer("you@gmail.com:s1", Script.gone, status: 410)
        // Today through eight days ahead, Wednesday 4 November in Amsterdam.
        h.google.answer("you@gmail.com:2026-11-03T23:00:00Z", Script.personalAfterReset)
        h.google.answer("family7k@group.calendar.google.com:f1", #"{"items": [], "nextSyncToken": "f2"}"#)
        h.google.answer("club3m@group.calendar.google.com:c1", #"{"items": [], "nextSyncToken": "c2"}"#)
        let snapshot = try #require(await h.engine.refreshWidgetSnapshot())
        #expect(h.google.misses.isEmpty)
        #expect(snapshot.events.contains { $0.title == "Design review" })
        #expect(!snapshot.events.contains { $0.title == "Dentist" })
        #expect(snapshot.events.contains { $0.title == "Dinner with Maya" })
        // The app's token stays for the app to reset.
        #expect(try h.stored().state(of: SyncTests.personal)?.token == "s1")
    }

    @Test func aSnapshotFromTheFutureDoesNotFreezeTheWidget() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "day-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = CacheDirectory(url: folder)
        let now = Date(timeIntervalSince1970: 1_793_797_000)
        func snapshot(_ at: Date) -> WidgetSnapshot {
            WidgetSnapshot(fetchedAt: at, accountCount: 1, signedOutAccounts: 0, events: [])
        }
        // Written while the clock read a day ahead; once the clock is back, the next writer
        // replaces it although its own `fetchedAt` is older.
        #expect(try snapshot(now.addingTimeInterval(86_400)).write(to: cache, now: now.addingTimeInterval(86_400)))
        #expect(try snapshot(now).write(to: cache, now: now))
        #expect(WidgetSnapshot.read(from: cache)?.fetchedAt == now)
        #expect(try snapshot(now.addingTimeInterval(-60)).write(to: cache, now: now) == false)
        // A file a little ahead of this writer's clock is within the tolerance and still wins.
        #expect(try snapshot(now.addingTimeInterval(240)).write(to: cache, now: now))
        #expect(try snapshot(now.addingTimeInterval(120)).write(to: cache, now: now) == false)
    }

    @Test func twoWritersNeverPutOlderDataOverNewer() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "day-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = CacheDirectory(url: folder)
        let base = Date(timeIntervalSince1970: 1_793_797_000)
        let now = base.addingTimeInterval(1000)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    let snapshot = WidgetSnapshot(
                        fetchedAt: base.addingTimeInterval(TimeInterval(i)), accountCount: 1,
                        signedOutAccounts: 0, events: [])
                    _ = try? snapshot.write(to: cache, now: now)
                }
            }
        }
        #expect(WidgetSnapshot.read(from: cache)?.fetchedAt == base.addingTimeInterval(199))
    }

    @Test func theWidgetReloadsOnlyForWhatItShows() throws {
        let t = Date(timeIntervalSince1970: 1_793_797_000)
        let fixture = try DecodingTests.fixture()
        let event = try #require(fixture.events.first)
        func snapshot(_ at: Date, events: [Event] = [], signedOut: Int = 0) -> WidgetSnapshot {
            WidgetSnapshot(fetchedAt: at, accountCount: 2, signedOutAccounts: signedOut, events: events)
        }
        #expect(snapshot(t).needsReload(after: nil))
        // A refresh three minutes later that found nothing new.
        #expect(!snapshot(t.addingTimeInterval(180)).needsReload(after: snapshot(t)))
        #expect(snapshot(t.addingTimeInterval(180), events: [event]).needsReload(after: snapshot(t)))
        #expect(snapshot(t.addingTimeInterval(180), signedOut: 1).needsReload(after: snapshot(t)))
        // An hour on, so `As of` stays away while the data is fresh.
        #expect(snapshot(t.addingTimeInterval(3600)).needsReload(after: snapshot(t)))
    }
}

// MARK: - The recorded answers

extension SyncTests {
    enum Script {
        static let list = #"""
            {"kind": "calendar#calendarList", "nextSyncToken": "l1", "items": [
              {"id": "family7k@group.calendar.google.com", "summary": "Family", "backgroundColor": "#33b679", "selected": true, "accessRole": "writer", "timeZone": "Europe/Amsterdam"},
              {"id": "you@gmail.com", "summary": "you@gmail.com", "summaryOverride": "Personal", "backgroundColor": "#039be5", "selected": true, "accessRole": "owner", "primary": true, "timeZone": "Europe/Amsterdam"},
              {"id": "club3m@group.calendar.google.com", "summary": "Club", "backgroundColor": "#f6bf26", "selected": true, "accessRole": "reader", "timeZone": "Europe/Amsterdam"}
            ]}
            """#

        static let personalPage1 = #"""
            {"kind": "calendar#events", "nextPageToken": "p2", "items": [
              {"id": "standupx_20261104T083000Z", "status": "confirmed", "summary": "Standup",
               "start": {"dateTime": "2026-11-04T09:30:00+01:00", "timeZone": "Europe/Amsterdam"}, "end": {"dateTime": "2026-11-04T09:45:00+01:00", "timeZone": "Europe/Amsterdam"},
               "recurringEventId": "standupx", "originalStartTime": {"dateTime": "2026-11-04T09:30:00+01:00", "timeZone": "Europe/Amsterdam"}, "iCalUID": "standupx@google.com"},
              {"id": "standupx_20261105T083000Z", "status": "confirmed", "summary": "Standup",
               "start": {"dateTime": "2026-11-05T09:30:00+01:00", "timeZone": "Europe/Amsterdam"}, "end": {"dateTime": "2026-11-05T09:45:00+01:00", "timeZone": "Europe/Amsterdam"},
               "recurringEventId": "standupx", "originalStartTime": {"dateTime": "2026-11-05T09:30:00+01:00", "timeZone": "Europe/Amsterdam"}, "iCalUID": "standupx@google.com"},
              {"id": "standupx_20261106T083000Z", "status": "confirmed", "summary": "Standup",
               "start": {"dateTime": "2026-11-06T09:30:00+01:00", "timeZone": "Europe/Amsterdam"}, "end": {"dateTime": "2026-11-06T09:45:00+01:00", "timeZone": "Europe/Amsterdam"},
               "recurringEventId": "standupx", "originalStartTime": {"dateTime": "2026-11-06T09:30:00+01:00", "timeZone": "Europe/Amsterdam"}, "iCalUID": "standupx@google.com"},
              {"id": "dentist07", "status": "confirmed", "summary": "Dentist", "location": "Tandarts Oost",
               "start": {"dateTime": "2026-11-07T14:30:00+01:00"}, "end": {"dateTime": "2026-11-07T15:15:00+01:00"}, "iCalUID": "dentist07@google.com"}
            ]}
            """#

        static let personalPage2 = #"""
            {"kind": "calendar#events", "nextSyncToken": "s1", "items": [
              {"id": "coffee10", "status": "confirmed", "summary": "Coffee with Ana",
               "start": {"dateTime": "2026-11-10T10:00:00+01:00"}, "end": {"dateTime": "2026-11-10T10:30:00+01:00"}, "iCalUID": "coffee10@google.com"},
              {"id": "planning12", "status": "confirmed", "summary": "Quarterly planning",
               "start": {"dateTime": "2026-11-12T13:00:00+01:00"}, "end": {"dateTime": "2026-11-12T16:00:00+01:00"}, "iCalUID": "planning12@google.com"}
            ]}
            """#

        static let familyFull = #"""
            {"kind": "calendar#events", "nextSyncToken": "f1", "items": [
              {"id": "dinner07", "status": "confirmed", "summary": "Dinner with Maya",
               "start": {"dateTime": "2026-11-07T19:00:00+01:00"}, "end": {"dateTime": "2026-11-07T21:00:00+01:00"}, "iCalUID": "dinner07@google.com"}
            ]}
            """#

        static let clubFull = #"""
            {"kind": "calendar#events", "nextSyncToken": "c1", "items": [
              {"id": "match08", "status": "confirmed", "summary": "Match",
               "start": {"dateTime": "2026-11-08T11:00:00+01:00"}, "end": {"dateTime": "2026-11-08T12:30:00+01:00"}, "iCalUID": "match08@google.com"}
            ]}
            """#

        /// Changes since s1, in two pages: a new lunch, a new board call, and the coffee
        /// renamed and half an hour later.
        static let personalInsertAndUpdate1 = #"""
            {"kind": "calendar#events", "nextPageToken": "q2", "items": [
              {"id": "lunch04", "status": "confirmed", "summary": "Lunch with Maya", "location": "Café Nord",
               "start": {"dateTime": "2026-11-04T12:30:00+01:00"}, "end": {"dateTime": "2026-11-04T13:30:00+01:00"}, "iCalUID": "lunch04@google.com",
               "organizer": {"email": "you@gmail.com", "self": true}},
              {"id": "coffee10", "status": "confirmed", "summary": "Coffee with Ana and Tom",
               "start": {"dateTime": "2026-11-10T10:30:00+01:00"}, "end": {"dateTime": "2026-11-10T11:00:00+01:00"}, "iCalUID": "coffee10@google.com"}
            ]}
            """#

        static let personalInsertAndUpdate2 = #"""
            {"kind": "calendar#events", "nextSyncToken": "s2", "items": [
              {"id": "board09", "status": "confirmed", "summary": "Board call",
               "start": {"dateTime": "2026-11-09T15:00:00+01:00"}, "end": {"dateTime": "2026-11-09T16:00:00+01:00"}, "iCalUID": "board09@google.com"}
            ]}
            """#

        /// Changes since s2: a deleted one-off (only its ID), the organizer's deleted lunch
        /// (details kept), one cancelled instance of the series (ID, series and slot only),
        /// an instance moved to 11:00, the coffee moved to June 2027, past the covered days,
        /// and the planning moved to the Family calendar.
        static let personalCancellations = #"""
            {"kind": "calendar#events", "nextSyncToken": "s3", "items": [
              {"id": "dentist07", "status": "cancelled"},
              {"id": "lunch04", "status": "cancelled", "summary": "Lunch with Maya",
               "start": {"dateTime": "2026-11-04T12:30:00+01:00"}, "end": {"dateTime": "2026-11-04T13:30:00+01:00"},
               "organizer": {"email": "you@gmail.com", "self": true}},
              {"id": "standupx_20261105T083000Z", "status": "cancelled", "recurringEventId": "standupx",
               "originalStartTime": {"dateTime": "2026-11-05T09:30:00+01:00", "timeZone": "Europe/Amsterdam"}},
              {"id": "standupx_20261106T083000Z", "status": "confirmed", "summary": "Standup",
               "start": {"dateTime": "2026-11-06T11:00:00+01:00", "timeZone": "Europe/Amsterdam"}, "end": {"dateTime": "2026-11-06T11:15:00+01:00", "timeZone": "Europe/Amsterdam"},
               "recurringEventId": "standupx", "originalStartTime": {"dateTime": "2026-11-06T09:30:00+01:00", "timeZone": "Europe/Amsterdam"}, "iCalUID": "standupx@google.com"},
              {"id": "coffee10", "status": "confirmed", "summary": "Coffee with Ana and Tom",
               "start": {"dateTime": "2027-06-01T10:30:00+02:00"}, "end": {"dateTime": "2027-06-01T11:00:00+02:00"}, "iCalUID": "coffee10@google.com"},
              {"id": "planning12", "status": "cancelled"}
            ]}
            """#

        static let familyReceivesPlanning = #"""
            {"kind": "calendar#events", "nextSyncToken": "f3", "items": [
              {"id": "planning12", "status": "confirmed", "summary": "Quarterly planning",
               "start": {"dateTime": "2026-11-12T13:00:00+01:00"}, "end": {"dateTime": "2026-11-12T16:00:00+01:00"}, "iCalUID": "planning12@google.com"}
            ]}
            """#

        static let personalApril = #"""
            {"kind": "calendar#events", "items": [
              {"id": "trip0410", "status": "confirmed", "summary": "Porto",
               "start": {"date": "2027-04-10"}, "end": {"date": "2027-04-13"}, "iCalUID": "trip0410@google.com"}
            ]}
            """#

        static let gone = #"""
            {"error": {"code": 410, "message": "Sync token is no longer valid, a full sync is required.",
              "errors": [{"domain": "global", "reason": "fullSyncRequired", "message": "Sync token is no longer valid, a full sync is required."}]}}
            """#

        /// Personal read in full after the reset: the series and one new event.
        static let personalAfterReset = #"""
            {"kind": "calendar#events", "nextSyncToken": "s4", "items": [
              {"id": "standupx_20261104T083000Z", "status": "confirmed", "summary": "Standup",
               "start": {"dateTime": "2026-11-04T09:30:00+01:00", "timeZone": "Europe/Amsterdam"}, "end": {"dateTime": "2026-11-04T09:45:00+01:00", "timeZone": "Europe/Amsterdam"},
               "recurringEventId": "standupx", "originalStartTime": {"dateTime": "2026-11-04T09:30:00+01:00", "timeZone": "Europe/Amsterdam"}, "iCalUID": "standupx@google.com"},
              {"id": "review11", "status": "confirmed", "summary": "Design review",
               "start": {"dateTime": "2026-11-11T11:00:00+01:00"}, "end": {"dateTime": "2026-11-11T12:00:00+01:00"}, "iCalUID": "review11@google.com"}
            ]}
            """#
    }
}
