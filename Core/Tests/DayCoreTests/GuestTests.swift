import Foundation
import Testing

@testable import DayCore

/// The guest list of the event sheet: what Google's attendees decode into, who is shown in
/// what order, the line above them, and the cache format that makes events saved before
/// guests were kept read again. Every person here is invented.
struct GuestTests {
    static let account = AccountID("100000000000000000002")
    static let calendarInfo = CalendarInfo(
        id: CalendarID(account: account, googleID: "you@acme.com"), name: "Work", colorHex: "#4285F4")

    static func decode(_ attendees: String, organizer: String = "") throws -> Event {
        let json = #"""
            {"id": "x", "start": {"dateTime": "2026-11-04T10:00:00Z"}, "end": {"dateTime": "2026-11-04T11:00:00Z"},
             \#(organizer) "attendees": [\#(attendees)]}
            """#
        let google = try JSONDecoder().decode(GoogleEvent.self, from: Data(json.utf8))
        return try #require(GoogleDecoding.event(google, on: calendarInfo))
    }

    static func guest(
        _ name: String?, _ email: String, _ response: Response = .accepted,
        organizer: Bool = false, me: Bool = false, room: Bool = false, optional: Bool = false
    ) -> Attendee {
        Attendee(
            email: email, displayName: name, isOrganizer: organizer, isSelf: me, isResource: room,
            isOptional: optional, response: response)
    }

    /// Ines organizes; Sam is the account holder; the rest are in Google's order.
    static let team: [Attendee] = [
        guest("Tom Berg", "tom@acme.com", .accepted),
        guest("Priya Rao", "priya@acme.com", .declined),
        guest("Sam", "you@acme.com", .needsAction, me: true),
        guest("Ines Vos", "ines@harbor.example", .accepted, organizer: true),
        guest(nil, "maya@harbor.example", .tentative, optional: true),
        guest("Lobby", "c_1@resource.calendar.google.com", .accepted, room: true),
    ]

    // MARK: Decoding

    @Test func everyAttendeeFieldDecodes() throws {
        let event = try Self.decode(
            #"""
            {"email": "ines@harbor.example", "displayName": "Ines Vos", "organizer": true, "responseStatus": "accepted"},
            {"email": "you@acme.com", "displayName": "Sam", "self": true, "responseStatus": "needsAction"},
            {"email": "maya@harbor.example", "optional": true, "responseStatus": "tentative"},
            {"email": "tom@acme.com", "responseStatus": "declined"},
            {"email": "c_1@resource.calendar.google.com", "displayName": "Lobby", "resource": true, "responseStatus": "accepted"}
            """#)
        #expect(event.attendees.map(\.email) == [
            "ines@harbor.example", "you@acme.com", "maya@harbor.example", "tom@acme.com",
            "c_1@resource.calendar.google.com",
        ])
        let ines = event.attendees[0]
        #expect(ines.displayName == "Ines Vos")
        #expect(ines.isOrganizer && !ines.isSelf && !ines.isResource && !ines.isOptional)
        #expect(ines.response == .accepted)
        let sam = event.attendees[1]
        #expect(sam.isSelf && sam.response == .needsAction)
        let maya = event.attendees[2]
        #expect(maya.isOptional && maya.displayName == nil && maya.response == .tentative)
        #expect(event.attendees[3].response == .declined)
        #expect(event.attendees[4].isResource)
        // What the rest of the app reads from the same list is unchanged.
        #expect(event.attendeeCount == 4)
        #expect(event.response == .needsAction)
    }

    @Test func aGuestWithNoAnswerIsAwaitingAndARoomByAddressIsAResource() throws {
        let event = try Self.decode(
            #"""
            {"email": "tom@acme.com"},
            {"email": "c_9@resource.calendar.google.com"},
            {"displayName": "  "},
            {"email": "  ", "displayName": " Priya Rao "}
            """#)
        #expect(event.attendees.count == 3)
        #expect(event.attendees[0].response == .needsAction)
        #expect(event.attendees[1].isResource)
        // Nothing to show for an entry with no address and no name; a padded name is trimmed.
        #expect(event.attendees[2].displayName == "Priya Rao")
        #expect(event.attendees[2].email == "")
    }

    @Test func noAttendeesDecodeToNoList() throws {
        let google = try JSONDecoder().decode(
            GoogleEvent.self,
            from: Data(#"{"id": "x", "start": {"dateTime": "2026-11-04T10:00:00Z"}}"#.utf8))
        let event = try #require(GoogleDecoding.event(google, on: Self.calendarInfo))
        #expect(event.attendees.isEmpty)
        #expect(event.guests == nil)
    }

    @Test func theFieldsMaskAsksForEveryAttendeeField() throws {
        let mask = CalendarAPI.eventFields
        let start = try #require(mask.range(of: "attendees("))
        let end = try #require(mask[start.upperBound...].firstIndex(of: ")"))
        let fields = Set(mask[start.upperBound..<end].split(separator: ",").map(String.init))
        #expect(fields == [
            "email", "displayName", "organizer", "self", "resource", "optional", "responseStatus",
        ])
        // The sync token still has to come back with every page.
        #expect(mask.contains("nextSyncToken"))
    }

    @Test func eventsFromACacheWithoutGuestsStillDecode() throws {
        var event = TestData.event("Sync", "2026-11-04 10:00", "2026-11-04 11:00", attendees: 5)
        event.attendees = Self.team
        let data = try DayJSON.encoder().encode(event)
        #expect(try DayJSON.decoder().decode(Event.self, from: data) == event)

        // The same event as an older Day wrote it: no `attendees` key at all.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["attendees"] = nil
        let old = try DayJSON.decoder().decode(
            Event.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.attendees.isEmpty)
        #expect(old.attendeeCount == 5)
        #expect(old.guests == nil)
    }

    @Test func savedGuestsKeepOnlyWhatDiffersFromTheDefault() throws {
        let plain = Attendee(email: "tom@acme.com")
        let text = try #require(String(data: DayJSON.encoder().encode(plain), encoding: .utf8))
        #expect(text == #"{"email":"tom@acme.com"}"#)
        let full = Self.guest("Ines", "ines@harbor.example", .declined, organizer: true, me: true, room: true, optional: true)
        #expect(try DayJSON.decoder().decode(Attendee.self, from: DayJSON.encoder().encode(full)) == full)
    }

    // MARK: Order

    @Test func theOrganizerComesFirstThenYouThenGoogleOrder() throws {
        let list = try #require(GuestList(Self.team))
        #expect(list.rows.map(\.name) == ["Ines Vos", "You", "Tom Berg", "Priya Rao", "maya@harbor.example"])
        #expect(list.rows.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test func whenYouOrganizeYouAreFirstAndMarked() throws {
        let list = try #require(GuestList([
            Self.guest("Tom", "tom@acme.com"),
            Self.guest("Sam", "you@acme.com", organizer: true, me: true),
            Self.guest("Priya", "priya@acme.com"),
        ]))
        #expect(list.rows.map(\.name) == ["You", "Tom", "Priya"])
        #expect(list.rows[0].marks == ["Organizer"])
        #expect(list.rows[0].spoken == "You, yes, Organizer")
    }

    @Test func aGuestIsShownByNameElseByAddressAndRoomsAreLeftOut() throws {
        let list = try #require(GuestList(Self.team))
        #expect(list.rows.contains { $0.name == "maya@harbor.example" })
        #expect(!list.rows.contains { $0.name == "Lobby" || $0.email.contains("resource.calendar") })
        #expect(list.count == 5)
        // A blank name falls back to the address too.
        let blank = try #require(GuestList([Self.guest("  ", "a@x.example"), Self.guest("B", "b@x.example")]))
        #expect(blank.rows[0].name == "a@x.example")
    }

    @Test func optionalGuestsAreMarkedAndOrganizerAndOptionalBothSpoken() throws {
        let list = try #require(GuestList(Self.team))
        let maya = try #require(list.rows.first { $0.email == "maya@harbor.example" })
        #expect(maya.marks == ["Optional"])
        #expect(maya.isOptional)
        let both = try #require(GuestList([
            Self.guest("Ines", "i@x.example", organizer: true, optional: true), Self.guest("Tom", "t@x.example"),
        ]))
        #expect(both.rows[0].marks == ["Organizer", "Optional"])
        #expect(both.rows[0].spoken == "Ines, yes, Organizer, Optional")
    }

    // MARK: Counts

    @Test func theSummaryLineCountsInGoogleWords() throws {
        let five = try #require(GuestList([
            Self.guest("A", "a@x.example", .accepted), Self.guest("B", "b@x.example", .accepted),
            Self.guest("C", "c@x.example", .accepted), Self.guest("D", "d@x.example", .declined),
            Self.guest("E", "e@x.example", .needsAction),
        ]))
        #expect(five.summary == "5 guests: 3 yes, 1 no, 1 awaiting")
        // Tentative is maybe, and a count of 0 is left out.
        let mixed = try #require(GuestList([
            Self.guest("A", "a@x.example", .tentative), Self.guest("B", "b@x.example", .tentative),
            Self.guest("C", "c@x.example", .needsAction),
        ]))
        #expect(mixed.summary == "3 guests: 2 maybe, 1 awaiting")
        let allYes = try #require(GuestList([
            Self.guest("A", "a@x.example"), Self.guest("B", "b@x.example"),
        ]))
        #expect(allYes.summary == "2 guests: 2 yes")
    }

    @Test func theSummaryDoesNotCountRooms() throws {
        let list = try #require(GuestList(Self.team))
        #expect(list.summary == "5 guests: 2 yes, 1 no, 1 maybe, 1 awaiting")
    }

    @Test func answersUseGoogleWords() {
        #expect(GuestAnswer(.accepted).word == "yes")
        #expect(GuestAnswer(.declined).word == "no")
        #expect(GuestAnswer(.tentative).word == "maybe")
        #expect(GuestAnswer(.needsAction).word == "awaiting")
        #expect(GuestAnswer(.none).word == "awaiting")
    }

    @Test func eachGuestIsSpokenAsNameAnswerAndMark() throws {
        let list = try #require(GuestList(Self.team))
        #expect(list.rows.map(\.spoken) == [
            "Ines Vos, yes, Organizer", "You, awaiting", "Tom Berg, yes", "Priya Rao, no",
            "maya@harbor.example, maybe, Optional",
        ])
    }

    // MARK: Show All

    @Test func moreThanEightGuestsShowEightAndShowAllRevealsTheRest() throws {
        func list(_ n: Int) throws -> GuestList {
            try #require(GuestList((0..<n).map { Self.guest("G\($0)", "g\($0)@x.example") }))
        }
        let eight = try list(8)
        #expect(!eight.isLong)
        #expect(eight.shown(all: false).count == 8)

        let eleven = try list(11)
        #expect(eleven.isLong)
        #expect(eleven.shown(all: false).map(\.name) == (0..<8).map { "G\($0)" })
        #expect(eleven.shown(all: true).count == 11)
        // The summary is for everyone, not only the eight shown.
        #expect(eleven.summary == "11 guests: 11 yes")
    }

    // MARK: A hidden list

    /// With `guestsCanSeeOtherGuests` false Google sends the account holder's own entry
    /// only. That is one person, so there is no list and no note about it.
    @Test func aHiddenListShowsOnlyWhatGoogleReturns() throws {
        let hidden = try Self.decode(#"{"email": "you@acme.com", "self": true, "responseStatus": "accepted"}"#)
        #expect(hidden.guests == nil)
        #expect(!hidden.hasOtherAttendees)

        // When Google does return the organizer beside him, those two are what is shown.
        let two = try Self.decode(
            #"""
            {"email": "ines@harbor.example", "displayName": "Ines Vos", "organizer": true, "responseStatus": "accepted"},
            {"email": "you@acme.com", "self": true, "responseStatus": "needsAction"}
            """#)
        let list = try #require(two.guests)
        #expect(list.rows.map(\.name) == ["Ines Vos", "You"])
        #expect(list.summary == "2 guests: 1 yes, 1 awaiting")
    }

    @Test func aListOfRoomsAndOnePersonIsNotAGuestList() {
        #expect(GuestList([Self.guest("Sam", "you@acme.com", me: true), Self.guest("Lobby", "r@x.example", room: true)]) == nil)
    }

    // MARK: Cache format

    @Test func aSyncFileWithoutAFormatIsFormatOne() throws {
        let old = #"{"fetchedAt": "2026-11-04T08:00:00Z", "calendars": []}"#
        #expect(try DayJSON.decoder().decode(SyncFile.self, from: Data(old.utf8)).format == 1)
        let fresh = SyncFile(fetchedAt: nil, calendars: [])
        #expect(fresh.format == CacheFormat.current)
        #expect(CacheFormat.current > 1)
    }

    @Test func eventsFromAnOlderFormatStayButReadAsNeverSynced() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "day-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = CacheDirectory(url: folder)
        let id = AccountID("100000000000000000001")
        let calendarID = CalendarID(account: id, googleID: "you@gmail.com")
        let at = Date(timeIntervalSince1970: 1_793_797_000)
        let days = CivilDate(year: 2026, month: 11, day: 3)...CivilDate(year: 2026, month: 11, day: 14)
        let state = CalendarSync(
            calendar: calendarID, token: "t1", tokenFrom: at, tokenTo: at, fullSyncAt: at, syncedAt: at, days: days)
        let event = TestData.event("Sync", "2026-11-04 10:00", "2026-11-04 11:00", attendees: 3)

        try cache.write(EventsFile(events: [event]), to: CacheFile.events(id))
        try cache.write(SyncFile(fetchedAt: at, calendars: [state], format: CacheFormat.current - 1), to: CacheFile.sync(id))
        let old = try #require(cache.account(id))
        #expect(old.events == [event])
        #expect(old.sync.isEmpty)
        #expect(old.fetchedAt == at)

        try cache.write(SyncFile(fetchedAt: at, calendars: [state]), to: CacheFile.sync(id))
        #expect(try #require(cache.account(id)).sync == [state])
    }

    /// An app that has just gained guests finds a cache of the old format: the next refresh
    /// must read every calendar's window instead of asking for changes since a token, and
    /// the events it brings keep their guests.
    @Test func theNextRefreshAfterAFormatChangeReadsTheWindowAndKeepsGuests() async throws {
        let h = try SyncTests.Harness()
        h.scriptInitialSync()
        _ = await h.engine.refresh()
        #expect(try h.event("coffee10")?.attendees.isEmpty == true)

        // Mark the saved sync file as written in the format before guests.
        let name = CacheFile.sync(SyncTests.account)
        var file = try #require(h.cache.read(SyncFile.self, from: name))
        file.format = CacheFormat.current - 1
        try h.cache.write(file, to: name)

        h.advance(180)
        let before = h.stub.requests.count
        h.google.answer("list:l1", #"{"items": [], "nextSyncToken": "l2"}"#)
        h.google.answer(
            "you@gmail.com:\(SyncTests.fullFrom)",
            #"""
            {"nextSyncToken": "s9", "items": [
              {"id": "coffee10", "status": "confirmed", "summary": "Coffee with Ana",
               "start": {"dateTime": "2026-11-10T10:30:00+01:00", "timeZone": "Europe/Amsterdam"},
               "end": {"dateTime": "2026-11-10T11:00:00+01:00", "timeZone": "Europe/Amsterdam"},
               "attendees": [
                 {"email": "you@gmail.com", "self": true, "organizer": true, "responseStatus": "accepted"},
                 {"email": "ana@harbor.example", "displayName": "Ana Costa", "responseStatus": "needsAction"}
               ]}
            ]}
            """#)
        h.google.answer("family7k@group.calendar.google.com:\(SyncTests.fullFrom)", SyncTests.Script.familyFull)
        h.google.answer("club3m@group.calendar.google.com:\(SyncTests.fullFrom)", SyncTests.Script.clubFull)
        let report = await h.engine.refresh()
        #expect(report.outcome == .current)
        #expect(h.google.misses.isEmpty)

        let keys = h.keys(from: before)
        #expect(keys.contains("you@gmail.com:\(SyncTests.fullFrom)"))
        #expect(keys.contains("family7k@group.calendar.google.com:\(SyncTests.fullFrom)"))
        #expect(!keys.contains { $0.hasSuffix(":s1") || $0.hasSuffix(":f1") || $0.hasSuffix(":c1") })

        let coffee = try #require(try h.event("coffee10"))
        #expect(coffee.attendees.map(\.email) == ["you@gmail.com", "ana@harbor.example"])
        #expect(coffee.guests?.summary == "2 guests: 1 yes, 1 awaiting")
        #expect(try h.stored().state(of: SyncTests.personal)?.token == "s9")
        #expect(h.cache.read(SyncFile.self, from: name)?.format == CacheFormat.current)

        // From here on the calendars are read by token again.
        h.advance(180)
        let again = h.stub.requests.count
        h.scriptQuiet(list: "l2", personal: "s9", family: "f1", club: "c1")
        _ = await h.engine.refresh()
        #expect(h.keys(from: again).contains("you@gmail.com:s9"))
    }
}
