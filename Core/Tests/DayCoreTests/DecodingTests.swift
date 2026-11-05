import Foundation
import Synchronization
import Testing

@testable import DayCore

/// Google's JSON into the model, checked against the invented week: the recorded responses
/// below are invented Google answers for events that are also in `invented-week.json`, so
/// decoding them must give exactly the fixture's events. Then the rules around decoding
/// (join link order, colors, text), the OAuth helpers, the API client and the sync engine,
/// all on recorded answers with no network.
struct DecodingTests {
    static func fixture() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "invented-week", withExtension: "json", subdirectory: "Fixtures"))
        return try Fixture.load(from: url)
    }

    static let gmail = AccountID("100000000000000000001")
    static let acme = AccountID("100000000000000000002")

    static func decodePage<Item: Decodable & Sendable>(_ json: String, as: Item.Type) throws -> [Item] {
        try JSONDecoder().decode(GooglePage<Item>.self, from: Data(json.utf8)).items
    }

    /// Every calendar the recorded lists hold, decoded with the recorded labels, folded
    /// across accounts.
    static func recordedCalendars() throws -> [CalendarInfo] {
        let labels = GoogleDecoding.labels(
            try JSONDecoder().decode(GoogleCalendarResource.self, from: Data(Recorded.acmeCalendar.utf8)))
        let gmail = GoogleDecoding.calendars(
            try decodePage(Recorded.gmailCalendarList, as: GoogleCalendarListEntry.self),
            account: Self.gmail)
        let acme = GoogleDecoding.calendars(
            try decodePage(Recorded.acmeCalendarList, as: GoogleCalendarListEntry.self),
            account: Self.acme, labels: ["you@acme.com": labels])
        return CalendarData.deduplicated([gmail, acme])
    }

    @Test func calendarListsDecodeToTheFixtureCalendars() throws {
        let fixture = try Self.fixture()
        let calendars = try Self.recordedCalendars()
        #expect(calendars == fixture.calendars)
    }

    @Test func eventsDecodeToTheFixtureEvents() throws {
        let fixture = try Self.fixture()
        let calendars = try Self.recordedCalendars()
        let byID = Dictionary(uniqueKeysWithValues: fixture.events.map { ($0.id, $0) })
        var decoded: [Event] = []
        for (calendarID, json) in Recorded.events {
            let info = try #require(calendars.first { $0.id.googleID == calendarID.googleID && $0.id.account == calendarID.account })
            for page in json {
                decoded += GoogleDecoding.events(try Self.decodePage(page, as: GoogleEvent.self), on: info)
            }
        }
        #expect(decoded.count == 13)
        for event in decoded {
            let expected = try #require(byID[event.id], "\(event.id) is not in the fixture")
            #expect(event == expected)
        }
        // Both copies of the investor call, one per account, as each fetch returns them.
        #expect(decoded.filter { $0.iCalUID == "7hq2k4investor04@google.com" }.count == 2)
    }

    @Test func calendarEntryRules() throws {
        let entries = try Self.decodePage(
            #"""
            {"items": [
              {"id": "team@acme.com", "summary": "Team", "accessRole": "writerWithoutPrivateAccess", "backgroundColor": "#9fe1e7"},
              {"id": "you@acme.com", "summary": "you@acme.com", "primary": true, "selected": true, "accessRole": "owner", "backgroundColor": "#4285f4", "timeZone": "Europe/Amsterdam"},
              {"id": "gone@acme.com", "summary": "Gone", "deleted": true},
              {"id": "busy@acme.com", "summary": "Busy", "accessRole": "freeBusyReader", "timeZone": "Not/AZone"},
              {"summary": "no id, skipped"}
            ]}
            """#, as: GoogleCalendarListEntry.self)
        #expect(entries.count == 4)
        let infos = GoogleDecoding.calendars(entries, account: Self.acme)
        #expect(infos.map(\.id.googleID) == ["you@acme.com", "team@acme.com", "busy@acme.com"])
        #expect(infos[0].colorHex == "#4285F4")
        #expect(infos[0].isPrimary && infos[0].selected)
        #expect(infos[1].accessRole == .writer)
        // Google leaves `selected` out when it is false.
        #expect(!infos[1].selected)
        #expect(infos[2].accessRole == .freeBusyReader)
        #expect(infos[2].timeZone == "UTC")
        #expect(GoogleDecoding.mayHaveLabels(entries[1]))
        #expect(!GoogleDecoding.mayHaveLabels(entries[3]))
        #expect(
            !GoogleDecoding.mayHaveLabels(
                GoogleCalendarListEntry(id: "en.dutch#holiday@group.v.calendar.google.com")))
    }

    @Test func sharedCalendarStaysWithTheHighestRole() {
        func info(_ account: AccountID, _ id: String, _ role: AccessRole) -> CalendarInfo {
            CalendarInfo(id: CalendarID(account: account, googleID: id), name: id, colorHex: "#039BE5", accessRole: role)
        }
        let first = [info(Self.gmail, "shared@acme.com", .reader), info(Self.gmail, "tie", .reader)]
        let second = [info(Self.acme, "shared@acme.com", .owner), info(Self.acme, "tie", .reader)]
        let kept = CalendarData.deduplicated([first, second])
        #expect(kept.map(\.id) == [first[1].id, second[0].id])
    }

    @Test(arguments: [
        ("2026-11-04T14:00:00+01:00", 1_793_797_200.0),
        ("2026-11-04T13:00:00Z", 1_793_797_200.0),
        ("2026-11-04T08:00:00-05:00", 1_793_797_200.0),
        ("2026-11-04T13:00:00.250Z", 1_793_797_200.25),
        ("2026-11-04T18:30:00+05:30", 1_793_797_200.0),
    ])
    func rfc3339Instants(_ text: String, _ seconds: Double) {
        #expect(GoogleDecoding.instant(text) == Date(timeIntervalSince1970: seconds))
    }

    @Test(arguments: ["2026-11-04", "2026-11-04T14:00:00", "2026-13-04T14:00:00Z", "2026-02-30T14:00:00Z", "", "2026-11-04T14:00:00+0100"])
    func malformedInstantsAreRefused(_ text: String) {
        #expect(GoogleDecoding.instant(text) == nil)
    }

    @Test func allDayEventsAreCivilDatesWithAnExclusiveEnd() throws {
        let calendar = CalendarInfo(
            id: CalendarID(account: Self.gmail, googleID: "you@gmail.com"), name: "Personal",
            colorHex: "#039BE5", timeZone: "Asia/Kolkata")
        let oneDay = GoogleEvent(id: "a", start: .init(date: "2026-11-04"), end: .init(date: "2026-11-05"))
        let noEnd = GoogleEvent(id: "b", start: .init(date: "2026-11-04"))
        let noStart = GoogleEvent(id: "c")
        let day = CivilDate(year: 2026, month: 11, day: 4)
        #expect(GoogleDecoding.event(oneDay, on: calendar)?.time == .allDay(start: day, endExclusive: day.adding(days: 1)))
        #expect(GoogleDecoding.event(noEnd, on: calendar)?.time == .allDay(start: day, endExclusive: day.adding(days: 1)))
        #expect(GoogleDecoding.event(noStart, on: calendar) == nil)
        // A timed event with no zone of its own was written in its calendar's zone.
        let timed = GoogleEvent(id: "d", start: .init(dateTime: "2026-11-04T09:30:00+05:30"), end: .init(dateTime: "2026-11-04T10:00:00+05:30"))
        guard case .timed(_, _, let zone) = try #require(GoogleDecoding.event(timed, on: calendar)?.time) else {
            Issue.record("not timed")
            return
        }
        #expect(zone == "Asia/Kolkata")
    }

    @Test func colorIsLabelThenColorIDThenCalendar() {
        let calendar = CalendarInfo(
            id: CalendarID(account: Self.acme, googleID: "you@acme.com"), name: "you@acme.com",
            colorHex: "#4285F4", labels: ["customer": LabelInfo(name: "Customer", colorHex: "#F4511E")])
        #expect(GoogleDecoding.colorKey(labelID: "customer", colorID: "7", calendar: calendar) == .orange)
        #expect(GoogleDecoding.colorKey(labelID: "unknown", colorID: "7", calendar: calendar) == .cyan)
        #expect(GoogleDecoding.colorKey(labelID: nil, colorID: "99", calendar: calendar) == .blue)
        #expect(GoogleDecoding.colorKey(labelID: nil, colorID: nil, calendar: calendar) == .blue)
    }

    @Test(arguments: [
        ("1", ColorKey.indigo), ("2", .green), ("3", .purple), ("4", .red), ("5", .yellow),
        ("6", .orange), ("7", .cyan), ("8", .gray), ("9", .indigo), ("10", .green), ("11", .red),
    ])
    func modernPaletteMapsToSystemColors(_ id: String, _ key: ColorKey) throws {
        let hex = try #require(ModernPalette.eventHex(id))
        #expect(ColorKey(hex: hex) == key)
    }

    @Test func labelsWithoutAColorAreLeftOut() throws {
        let resource = try JSONDecoder().decode(
            GoogleCalendarResource.self,
            from: Data(
                #"""
                {"id": "you@acme.com", "labelProperties": {"eventLabels": [
                  {"id": "customer", "name": "Customer", "backgroundColor": "#f4511e"},
                  {"id": "internal", "name": "Internal", "colorId": "2"},
                  {"id": "broken", "name": "Broken", "backgroundColor": "teal"}
                ]}}
                """#.utf8))
        let labels = GoogleDecoding.labels(resource)
        #expect(labels["customer"] == LabelInfo(name: "Customer", colorHex: "#F4511E"))
        #expect(labels["internal"] == LabelInfo(name: "Internal", colorHex: "#33B679"))
        #expect(labels["broken"] == nil)
    }

    // MARK: Join links

    static func joinURL(_ json: String) throws -> String? {
        let event = try JSONDecoder().decode(GoogleEvent.self, from: Data(json.utf8))
        return GoogleDecoding.joinURL(event)?.absoluteString
    }

    @Test func joinLinkSourceOrder() throws {
        // The conference's video entry point wins over hangoutLink, a location and the
        // description.
        #expect(
            try Self.joinURL(
                #"""
                {"id": "1", "hangoutLink": "https://meet.google.com/aaa-bbbb-ccc",
                 "location": "https://zoom.us/j/111",
                 "conferenceData": {"entryPoints": [
                   {"entryPointType": "phone", "uri": "tel:+31-20-000-0000"},
                   {"entryPointType": "video", "uri": "https://acme.zoom.us/j/222?pwd=x"}]}}
                """#) == "https://acme.zoom.us/j/222?pwd=x")
        #expect(
            try Self.joinURL(
                #"{"id": "2", "hangoutLink": "https://meet.google.com/aaa-bbbb-ccc", "location": "https://zoom.us/j/111"}"#)
                == "https://meet.google.com/aaa-bbbb-ccc")
        #expect(
            try Self.joinURL(#"{"id": "3", "location": "Room 4 or https://whereby.com/acme-room"}"#)
                == "https://whereby.com/acme-room")
        // A maps link in the location is a place; the description's Teams link is the call.
        #expect(
            try Self.joinURL(
                #"""
                {"id": "4", "location": "https://maps.app.goo.gl/AbC123",
                 "description": "Agenda: https://docs.example/agenda<br>Join: <a href=\"https://teams.microsoft.com/l/meetup-join/19%3ameeting?context=a&amp;b=c\">Click here</a>"}
                """#) == "https://teams.microsoft.com/l/meetup-join/19%3ameeting?context=a&b=c")
        #expect(
            try Self.joinURL(#"{"id": "5", "description": "Slides at https://docs.example/slides and https://acme.webex.com/meet/you"}"#)
                == "https://acme.webex.com/meet/you")
        // A link that is not a known meeting service is not a call.
        #expect(try Self.joinURL(#"{"id": "6", "description": "Deck: https://harbor.example/deck/q4"}"#) == nil)
        #expect(try Self.joinURL(#"{"id": "7", "location": "Café Nord, Lisboa"}"#) == nil)
    }

    // MARK: Text

    @Test func descriptionsBecomePlainText() {
        let html = #"""
            <p>Q4 numbers&nbsp;and the <b>seed</b> extension.</p><ul><li>Deck: <a href="https://harbor.example/deck/q4">https://harbor.example/deck/q4</a></li><li><a href="https://harbor.example/notes">Notes</a></li></ul>Tom &amp; In&#233;s &lt;3&#x21;<br/><br><br>Bye
            """#
        #expect(
            GoogleDecoding.plainText(fromHTML: html)
                == "Q4 numbers and the seed extension.\n• Deck: https://harbor.example/deck/q4\n• Notes (https://harbor.example/notes)\n\nTom & Inés <3!\n\nBye")
        #expect(GoogleDecoding.plainText(fromHTML: "  Agenda in the planning doc.\nSecond line  ") == "Agenda in the planning doc.\nSecond line")
        #expect(GoogleDecoding.plainText(fromHTML: "a < b and c > d") == "a < b and c > d")
    }

    @Test func roomsAndTheAccountHolderAreNotGuests() throws {
        let event = try JSONDecoder().decode(
            GoogleEvent.self,
            from: Data(
                #"""
                {"id": "x", "start": {"dateTime": "2026-11-04T10:00:00Z"}, "end": {"dateTime": "2026-11-04T11:00:00Z"},
                 "attendees": [
                   {"email": "You@Acme.com", "self": true, "responseStatus": "accepted"},
                   {"email": "Priya@ACME.com", "responseStatus": "needsAction"},
                   {"email": "c_123@resource.calendar.google.com", "resource": true},
                   {"email": "lobby@acme.com", "resource": true},
                   {"email": "team@group.calendar.google.com"}
                 ]}
                """#.utf8))
        let info = CalendarInfo(id: CalendarID(account: Self.acme, googleID: "you@acme.com"), name: "w", colorHex: "#4285F4")
        let decoded = try #require(GoogleDecoding.event(event, on: info))
        #expect(decoded.attendeeCount == 3)
        #expect(decoded.attendeeDomains == ["acme.com"])
        #expect(decoded.response == .accepted)
        #expect(!decoded.isRecurring)
        #expect(decoded.title == "Busy")
    }

    @Test func untitledEventsAreBusyOnEveryCalendar() throws {
        func calendar(_ role: AccessRole) -> CalendarInfo {
            CalendarInfo(
                id: CalendarID(account: Self.acme, googleID: "team@acme.com"), name: "Team",
                colorHex: "#4285F4", accessRole: role)
        }
        func title(_ summary: String?, _ role: AccessRole) throws -> String {
            var object: [String: Any] = [
                "id": "x", "start": ["dateTime": "2026-11-04T16:00:00+01:00"],
                "end": ["dateTime": "2026-11-04T17:00:00+01:00"],
            ]
            if let summary { object["summary"] = summary }
            let event = try JSONDecoder().decode(
                GoogleEvent.self, from: JSONSerialization.data(withJSONObject: object))
            return try #require(GoogleDecoding.event(event, on: calendar(role))).title
        }
        // A title Google sends is data and passes through untouched, even on free/busy.
        #expect(try title("Weekly planning", .owner) == "Weekly planning")
        #expect(try title("Weekly planning ", .reader) == "Weekly planning ")
        #expect(try title("Busy", .freeBusyReader) == "Busy")
        // No summary, an empty one and a blank one are the same thing to Google Calendar, and
        // on a free/busy-only calendar too: one word everywhere.
        for missing in [nil, "", "   ", "\n"] {
            for role in [AccessRole.owner, .writer, .reader, .freeBusyReader] {
                #expect(try title(missing, role) == "Busy")
                #expect(try title(missing, role) == Event.untitled)
            }
        }
    }

    @Test func aCacheHoldingTheOldPlaceholderReadsBusy() throws {
        // Events cached before the placeholder became `Busy` still say `(No title)` on disk.
        func decode(_ title: String) throws -> Event {
            let stored = Event(
                id: EventID(calendar: CalendarID(account: Self.acme, googleID: "x"), googleID: "e1"),
                iCalUID: "e1", title: title,
                time: .timed(
                    start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600),
                    authoredZone: nil))
            return try JSONDecoder().decode(Event.self, from: JSONEncoder().encode(stored))
        }
        #expect(try decode("(No title)").title == "Busy")
        #expect(try decode("  ").title == "Busy")
        #expect(try decode("Dentist").title == "Dentist")
        // A title Google sent that only resembles the placeholder is data and is kept.
        #expect(try decode("(No title) review").title == "(No title) review")
    }
}

// MARK: - OAuth

extension DecodingTests {
    struct OAuth {
        static let clientID = Recorded.clientID

        @Test func pkceMatchesRFC7636() {
            // Appendix B of RFC 7636.
            let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
            let fresh = PKCE()
            #expect(fresh.verifier.count == 43)
            #expect(fresh.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            #expect(fresh.verifier != PKCE().verifier)
        }

        @Test func placeholderAndMalformedClientsAreRefused() {
            #expect(GoogleAuth(clientID: DayIdentifiers.googleClientPlaceholder) == nil)
            #expect(GoogleAuth(clientID: "$(DAY_GOOGLE_CLIENT_ID).apps.googleusercontent.com") == nil)
            #expect(GoogleAuth(clientID: "123-abc") == nil)
            let auth = GoogleAuth(clientID: Self.clientID)
            #expect(auth?.callbackScheme == "com.googleusercontent.apps.123456789012-abcdefghijklmnop")
            #expect(auth?.redirectURI == "com.googleusercontent.apps.123456789012-abcdefghijklmnop:/oauth2redirect")
        }

        @Test func authorizationURL() throws {
            let auth = try #require(GoogleAuth(clientID: Self.clientID))
            let request = auth.authorizationRequest(loginHint: "you+day@acme.com")
            let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
            let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(components.host == "accounts.google.com")
            #expect(components.path == "/o/oauth2/v2/auth")
            #expect(items["client_id"] == Self.clientID)
            #expect(items["redirect_uri"] == auth.redirectURI)
            #expect(items["response_type"] == "code")
            #expect(items["scope"] == "openid email https://www.googleapis.com/auth/calendar.readonly")
            #expect(items["code_challenge"] == request.pkce.challenge)
            #expect(items["code_challenge_method"] == "S256")
            #expect(items["state"] == request.state)
            #expect(items["prompt"] == "select_account")
            #expect(items["login_hint"] == "you+day@acme.com")
            #expect(request.url.absoluteString.contains("you%2Bday%40acme.com") || request.url.absoluteString.contains("you%2Bday@acme.com"))
            #expect(request.callbackScheme == auth.callbackScheme)
            #expect(auth.authorizationRequest().url.query()?.contains("login_hint") == false)
        }

        @Test func redirectIsCheckedAgainstTheRequest() throws {
            let auth = try #require(GoogleAuth(clientID: Self.clientID))
            let request = auth.authorizationRequest()
            let base = auth.redirectURI
            #expect(throws: OAuthError.accessDenied) {
                try auth.authorizationCode(from: URL(string: "\(base)?error=access_denied&state=\(request.state)")!, for: request)
            }
            #expect(throws: OAuthError.stateMismatch) {
                try auth.authorizationCode(from: URL(string: "\(base)?code=c&state=other")!, for: request)
            }
            #expect(try auth.authorizationCode(from: URL(string: "\(base)?code=4/0Ab-c&state=\(request.state)")!, for: request) == "4/0Ab-c")
        }

        @Test func exchangeSendsTheVerifierAndReadsTheIDToken() async throws {
            let stub = Stub(Recorded.google())
            let auth = try #require(GoogleAuth(clientID: Self.clientID, transport: stub, retry: .noWait))
            let request = auth.authorizationRequest()
            let callback = URL(string: "\(auth.redirectURI)?state=\(request.state)&code=code-acme&scope=email")!
            let now = Date(timeIntervalSince1970: 1_793_797_000)
            let signIn = try await auth.exchange(callback: callback, for: request, now: now)
            #expect(signIn.account == DecodingTests.acme)
            #expect(signIn.email == "you@acme.com")
            #expect(signIn.grantsCalendar)
            #expect(signIn.token.refreshToken == "refresh-acme")
            #expect(signIn.token.validAccessToken(at: now) == "access-acme")
            #expect(signIn.token.accessExpiry == now.addingTimeInterval(3599))

            let sent = try #require(stub.requests.first)
            #expect(sent.httpMethod == "POST")
            #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            let form = Recorded.form(sent)
            #expect(form["code_verifier"] == request.pkce.verifier)
            #expect(form["grant_type"] == "authorization_code")
            #expect(form["redirect_uri"] == auth.redirectURI)
            #expect(form["client_secret"] == nil)
        }

        @Test func partialGrantIsReturnedNotThrown() async throws {
            let auth = try #require(GoogleAuth(clientID: Self.clientID, transport: Stub(Recorded.google()), retry: .noWait))
            let request = auth.authorizationRequest()
            let signIn = try await auth.exchange(
                callback: URL(string: "\(auth.redirectURI)?state=\(request.state)&code=code-partial")!, for: request)
            #expect(!signIn.grantsCalendar)
        }

        @Test func idTokenForAnotherClientIsRefused() {
            let token = Recorded.idToken(sub: "1", email: "you@acme.com", audience: "999-other.apps.googleusercontent.com")
            #expect(throws: OAuthError.self) {
                try IDTokenClaims(jwt: token, audience: Self.clientID)
            }
            #expect(throws: OAuthError.self) {
                try IDTokenClaims(jwt: "not.a.token", audience: Self.clientID)
            }
            let ok = Recorded.idToken(sub: "42", email: "you@acme.com")
            #expect((try? IDTokenClaims(jwt: ok, audience: Self.clientID))?.sub == "42")
        }

        @Test func refreshKeepsTheRefreshTokenAndSignsOutOnInvalidGrant() async throws {
            let auth = try #require(GoogleAuth(clientID: Self.clientID, transport: Stub(Recorded.google()), retry: .noWait))
            let now = Date(timeIntervalSince1970: 1_793_797_000)
            let token = StoredToken(refreshToken: "refresh-gmail", email: "you@gmail.com", scope: Recorded.fullScope)
            let refreshed = try await auth.refresh(token, now: now)
            #expect(refreshed.refreshToken == "refresh-gmail")
            #expect(refreshed.validAccessToken(at: now) == "access-gmail")
            #expect(refreshed.validAccessToken(at: now.addingTimeInterval(3550)) == nil)

            let revoked = StoredToken(refreshToken: "refresh-rapt", email: "you@acme.com", scope: Recorded.fullScope)
            await #expect(throws: OAuthError.invalidGrant(subtype: "invalid_rapt")) {
                try await auth.refresh(revoked, now: now)
            }
            let narrowed = StoredToken(refreshToken: "refresh-narrow", email: "you@acme.com", scope: Recorded.fullScope)
            await #expect(throws: OAuthError.partialGrant(granted: "openid https://www.googleapis.com/auth/userinfo.email")) {
                try await auth.refresh(narrowed, now: now)
            }
            #expect(OAuthError.invalidGrant(subtype: nil).signsOut)
            #expect(!OAuthError.stateMismatch.signsOut)
        }

        @Test func storedTokenUsesGoogleKeyNames() throws {
            let token = StoredToken(
                refreshToken: "r", accessToken: "a", accessExpiry: Date(timeIntervalSince1970: 0),
                email: "you@acme.com", scope: Recorded.fullScope)
            let json = String(decoding: try token.encoded(), as: UTF8.self)
            #expect(json.contains(#""refresh_token":"r""#))
            #expect(json.contains(#""access_expiry":"1970-01-01T00:00:00Z""#))
            #expect(try StoredToken(encoded: token.encoded()) == token)
        }
    }
}

// MARK: - Calendar API

extension DecodingTests {
    struct API {
        @Test func eventsRequestEncodesTheCalendarIDAndAsksForLessAndGzip() throws {
            let api = CalendarAPI(transport: Stub(Recorded.google()))
            let from = Date(timeIntervalSince1970: 1_790_719_200)
            let to = Date(timeIntervalSince1970: 1_804_201_200)
            let request = api.eventsRequest(
                calendarID: "en.dutch#holiday@group.v.calendar.google.com", query: .window(from: from, to: to),
                pageToken: "p+1", accessToken: "access-gmail")
            let url = try #require(request.url)
            #expect(url.absoluteString.hasPrefix(
                "https://www.googleapis.com/calendar/v3/calendars/en.dutch%23holiday%40group.v.calendar.google.com/events?"))
            #expect(url.fragment == nil)
            let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(items["singleEvents"] == "true")
            // Google sends no sync token back to a read ordered by start, and refuses the
            // order beside a token.
            #expect(items["orderBy"] == nil)
            #expect(items["timeMin"] == "2026-09-29T22:00:00Z")
            #expect(items["timeMax"] == "2027-03-04T23:00:00Z")
            #expect(items["maxResults"] == "2500")
            #expect(items["eventLabelVersion"] == "1")
            #expect(items["fields"]?.contains("eventLabelId") == true)
            #expect(items["fields"]?.hasPrefix("nextPageToken,nextSyncToken,") == true)
            #expect(items["pageToken"] == "p+1")
            #expect(url.query()?.contains("p%2B1") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-gmail")
            #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "gzip")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("gzip") == true)
        }

        @Test func eventsFollowEveryPage() async throws {
            let stub = Stub(Recorded.google())
            let api = CalendarAPI(transport: stub, retry: .noWait)
            let events = try await api.events(
                calendarID: "you@gmail.com", from: .distantPast, to: .distantFuture, accessToken: "access-gmail")
            #expect(events.map(\.id) == ["1e813e74970635342528", "7hq2k4investor04", "abeaab179545e127c03f", "fd852fec28c581e323c9"])
            #expect(stub.requests.count == 2)
            #expect(stub.requests.last?.url?.query()?.contains("pageToken=page-2") == true)
        }

        @Test func rateLimitsAreRetriedAndScopeErrorsAreNot() async throws {
            let calls = Shared(0)
            let api = CalendarAPI(
                transport: Stub { request in
                    let n = calls.update { $0 += 1; return $0 }
                    if n == 1 { return (403, Data(Recorded.error(403, reason: "rateLimitExceeded", domain: "usageLimits").utf8), [:]) }
                    if n == 2 { return (503, Data(), [:]) }
                    return try Recorded.google()(request)
                }, retry: .noWait)
            let list = try await api.calendarList(accessToken: "access-gmail")
            #expect(list.entries.count == 3)
            #expect(list.nextSyncToken == "invented")
            #expect(calls.value == 3)

            let scoped = CalendarAPI(
                transport: Stub { _ in
                    (403, Data(Recorded.error(403, reason: "insufficientPermissions", domain: "global").utf8), [:])
                }, retry: .noWait)
            await #expect(throws: CalendarAPIError.insufficientScope) {
                try await scoped.calendarList(accessToken: "x")
            }
            let gone = CalendarAPI(transport: Stub { _ in (404, Data(), [:]) }, retry: .noWait)
            await #expect(throws: CalendarAPIError.notFound) {
                try await gone.events(calendarID: "gone", from: .now, to: .now, accessToken: "x")
            }
        }

        @Test func aProjectLevel403IsNotRetriedAndKeepsItsReason() async throws {
            let calls = Shared(0)
            let api = CalendarAPI(
                transport: Stub { _ in
                    calls.update { $0 += 1 }
                    return (403, Data(Recorded.accessNotConfigured.utf8), [:])
                }, retry: .noWait)
            await #expect(throws: CalendarAPIError.http(status: 403, reason: "accessNotConfigured")) {
                try await api.events(calendarID: "you@acme.com", from: .now, to: .now, accessToken: "x")
            }
            // Waiting does not enable an API, so the line saying so comes at once.
            #expect(calls.value == 1)
            #expect(!CalendarAPIError.http(status: 403, reason: "accessNotConfigured").meansCalendarUnreadable)
            #expect(!CalendarAPIError.http(status: 403, reason: "dailyLimitExceeded").meansCalendarUnreadable)
            #expect(!CalendarAPIError.http(status: 403, reason: nil).meansCalendarUnreadable)
            #expect(!CalendarAPIError.http(status: 500, reason: "forbidden").meansCalendarUnreadable)
            #expect(!CalendarAPIError.unavailable(status: 403).meansCalendarUnreadable)
            #expect(CalendarAPIError.http(status: 403, reason: "forbidden").meansCalendarUnreadable)
            #expect(CalendarAPIError.http(status: 403, reason: "requiredAccessLevel").meansCalendarUnreadable)
            #expect(CalendarAPIError.notFound.meansCalendarUnreadable)
        }

        @Test func aRefusedFieldsMaskFallsBackToTheWholeResource() async throws {
            let stub = Stub { request in
                if request.url?.query()?.contains("fields=") == true {
                    return (400, Data(Recorded.error(400, reason: "invalidParameter", domain: "global").utf8), [:])
                }
                return try Recorded.google()(request)
            }
            let api = CalendarAPI(transport: stub, retry: .noWait)
            let events = try await api.events(calendarID: "you@acme.com", from: .now, to: .now, accessToken: "access-acme")
            #expect(!events.isEmpty)
        }
    }
}

// MARK: - Sync

extension DecodingTests {
    struct Sync {
        /// A sync engine over a temporary folder, the recorded Google and a clock the test
        /// moves, with both fixture accounts added and their refresh tokens stored.
        final class Harness: Sendable {
            let folder: URL
            let cache: CacheDirectory
            let stub: Stub
            let tokens: MemoryTokenStore
            let clock: Shared<Date>
            let engine: SyncEngine
            let fixture: Fixture

            init(handler: @escaping Stub.Handler = Recorded.google(), accounts: Bool = true) throws {
                fixture = try DecodingTests.fixture()
                folder = FileManager.default.temporaryDirectory.appending(path: "day-wp1-\(UUID().uuidString)")
                cache = CacheDirectory(url: folder)
                stub = Stub(handler)
                tokens = MemoryTokenStore()
                let clock = Shared(fixture.now)
                self.clock = clock
                engine = SyncEngine(
                    auth: GoogleAuth(clientID: Recorded.clientID, transport: stub, retry: .noWait),
                    tokens: tokens, cache: cache, api: CalendarAPI(transport: stub, retry: .noWait),
                    calendar: fixture.calendar, clock: { clock.value })
                if accounts {
                    try cache.write(fixture.accounts, to: CacheFile.accounts)
                    try tokens.save(StoredToken(refreshToken: "refresh-gmail", email: "you@gmail.com", scope: Recorded.fullScope), for: DecodingTests.gmail)
                    try tokens.save(StoredToken(refreshToken: "refresh-acme", email: "you@acme.com", scope: Recorded.fullScope), for: DecodingTests.acme)
                }
            }

            deinit {
                try? FileManager.default.removeItem(at: folder)
            }

            func advance(_ seconds: TimeInterval) {
                clock.update { $0 = $0.addingTimeInterval(seconds) }
            }

            func paths(_ suffix: String) -> [String] {
                stub.requests.compactMap { $0.url?.path(percentEncoded: false) }.filter { $0.hasSuffix(suffix) }
            }
        }

        @Test func refreshFetchesFoldsAndWritesTheSnapshot() async throws {
            let h = try Harness()
            let report = await h.engine.refresh()
            #expect(report.outcome == .current)
            #expect(report.newlySignedOut.isEmpty)
            let data = report.data
            #expect(data.calendars == h.fixture.calendars)
            #expect(data.lastFetchedAt == h.fixture.now)

            // Events decode exactly as the fixture has them.
            let byID = Dictionary(uniqueKeysWithValues: h.fixture.events.map { ($0.id, $0) })
            let all = data.eventsByAccount.values.joined()
            #expect(all.count == 13)
            for event in all { #expect(event == byID[event.id]) }

            // The shared Personal calendar is fetched once, by the account that owns it; the
            // hidden Team offsites calendar is not fetched; Google's generated calendars are
            // not asked for labels.
            let eventPaths = h.paths("/events")
            #expect(eventPaths.filter { $0.contains("you@gmail.com") }.count == 2)
            #expect(!eventPaths.contains { $0.contains("offsites") })
            #expect(h.paths("").filter { $0.contains("#holiday") && !$0.hasSuffix("/events") }.isEmpty)
            #expect(h.paths("/calendars/you@acme.com").count == 1)
            for request in h.stub.requests where request.url?.path().hasSuffix("/events") == true {
                let personal = request.url?.path(percentEncoded: false).contains("you@gmail.com") == true
                #expect(request.value(forHTTPHeaderField: "Authorization") == (personal || request.url!.path(percentEncoded: false).contains("group.v.") ? "Bearer access-gmail" : "Bearer access-acme"))
            }

            // The day reads merged: one investor call on two calendars.
            let wednesday = CivilDate(year: 2026, month: 11, day: 4)
            let day = data.events(in: wednesday...wednesday, calendar: h.fixture.calendar)
            let investor = day.filter { $0.title == "Investor call" }
            #expect(investor.count == 1)
            #expect(investor.first?.calendars.count == 2)

            // Tokens were refreshed and saved for next time.
            #expect(try h.tokens.token(for: DecodingTests.acme)?.accessToken == "access-acme")

            let snapshot = try #require(WidgetSnapshot.read(from: h.cache))
            #expect(snapshot.fetchedAt == h.fixture.now)
            #expect(snapshot.accountCount == 2)
            #expect(snapshot.signedOutAccounts == 0)
            #expect(snapshot.events.filter { $0.iCalUID == "7hq2k4investor04@google.com" }.count == 1)
            #expect(!snapshot.events.contains { $0.title == "Customer office hours" })
            let window = SyncEngine.interval(WidgetSnapshot.days(from: wednesday), calendar: h.fixture.calendar)
            #expect(snapshot.events.allSatisfy { SyncEngine.overlaps($0, window, calendar: h.fixture.calendar) })
            let files = try FileManager.default.contentsOfDirectory(atPath: h.folder.path(percentEncoded: false))
            #expect(Set(files) == [
                "accounts.json", "calendars-100000000000000000001.json", "calendars-100000000000000000002.json",
                "events-100000000000000000001.json", "events-100000000000000000002.json",
                "sync-100000000000000000001.json", "sync-100000000000000000002.json",
                "near-100000000000000000001.json", "near-100000000000000000002.json", "widget-snapshot.json",
            ])
        }

        @Test func invalidGrantSignsOutOneAccountAndKeepsItsEvents() async throws {
            let rejected = Shared<Set<String>>([])
            let h = try Harness(handler: { request in
                if let token = Recorded.form(request)["refresh_token"], rejected.value.contains(token) {
                    return (400, Data(#"{"error": "invalid_grant", "error_description": "reauth related error (invalid_rapt)", "error_subtype": "invalid_rapt"}"#.utf8), [:])
                }
                return try Recorded.google()(request)
            })
            _ = await h.engine.refresh()
            rejected.update { _ = $0.insert("refresh-acme") }
            h.advance(2 * 3600)
            let report = await h.engine.refresh()
            #expect(report.outcome == .current)
            #expect(report.newlySignedOut == [DecodingTests.acme])
            #expect(report.data.accounts.first { $0.id == DecodingTests.acme }?.signedOut == true)
            #expect(report.data.accounts.first { $0.id == DecodingTests.gmail }?.signedOut == false)
            #expect(report.data.eventsByAccount[DecodingTests.acme]?.isEmpty == false)
            #expect(report.data.fetchedAtByAccount[DecodingTests.gmail] == h.fixture.now.addingTimeInterval(7200))
            // Signed-out accounts do not drag the age back; the gmail fetch is current.
            #expect(report.data.lastFetchedAt == h.fixture.now.addingTimeInterval(7200))
            let snapshot = try #require(WidgetSnapshot.read(from: h.cache))
            #expect(snapshot.signedOutAccounts == 1)
            #expect(snapshot.events.contains { $0.title == "Standup" })

            // A signed-out account is not fetched again until it signs in.
            let before = h.stub.requests.count
            _ = await h.engine.refresh()
            #expect(!h.stub.requests[before...].contains { Recorded.form($0)["refresh_token"] == "refresh-acme" })
        }

        @Test func offlineKeepsTheCacheAndSaysSo() async throws {
            let offline = Shared(false)
            let h = try Harness(handler: { request in
                if offline.value { throw URLError(.notConnectedToInternet) }
                return try Recorded.google()(request)
            })
            let first = await h.engine.refresh()
            offline.update { $0 = true }
            h.advance(2 * 3600)
            let report = await h.engine.refresh()
            #expect(report.outcome == .offline)
            #expect(report.data.eventsByAccount == first.data.eventsByAccount)
            #expect(report.data.lastFetchedAt == h.fixture.now)
            #expect(report.newlySignedOut.isEmpty)
            #expect(WidgetSnapshot.read(from: h.cache)?.fetchedAt == h.fixture.now)
        }

        /// The Calendar API off in the project, a spent daily quota, a Workspace block and a
        /// refusal with no Google body at all: each is refused for every calendar alike.
        @Test(arguments: [
            ("accessNotConfigured", Recorded.accessNotConfigured),
            ("domainPolicy", Recorded.error(403, reason: "domainPolicy", domain: "global")),
            ("dailyLimitExceeded", Recorded.error(403, reason: "dailyLimitExceeded", domain: "usageLimits")),
            ("no body", "<html>Forbidden</html>"),
        ])
        func aProjectWide403KeepsEveryCalendarAndSaysGoogleIsUnreachable(_ name: String, _ body: String) async throws {
            let refused = Shared(false)
            let h = try Harness(handler: { request in
                if refused.value, request.url?.path().hasSuffix("/events") == true {
                    return (403, Data(body.utf8), [:])
                }
                return try Recorded.google()(request)
            })
            let first = await h.engine.refresh()
            #expect(first.outcome == .current)
            refused.update { $0 = true }
            h.advance(2 * 3600)
            let before = h.stub.requests.count
            let report = await h.engine.refresh()
            #expect(report.outcome == .unreachable, "\(name)")
            #expect(report.newlySignedOut.isEmpty)
            #expect(report.data.accounts.allSatisfy { !$0.signedOut })
            #expect(report.data.eventsByAccount == first.data.eventsByAccount, "\(name)")
            #expect(report.data.eventsByAccount.values.joined().count == 13)
            // Events as of the last good fetch, which is what the status line names.
            #expect(report.data.lastFetchedAt == h.fixture.now)
            #expect(WidgetSnapshot.read(from: h.cache)?.fetchedAt == h.fixture.now)
            // One try per calendar: waiting does not enable an API or lift a block.
            let refusedCalls = h.stub.requests[before...]
                .filter { $0.url?.path().hasSuffix("/events") == true }
                .compactMap { $0.url?.path(percentEncoded: false) }
            #expect(!refusedCalls.isEmpty)
            #expect(Set(refusedCalls).count == refusedCalls.count, "\(name)")
        }

        @Test func aCalendarThatIsNoLongerSharedEmptiesOnlyItself() async throws {
            let revoked = Shared(false)
            let h = try Harness(handler: { request in
                if revoked.value, request.url?.path(percentEncoded: false).contains("/calendars/you@acme.com/events") == true {
                    return (403, Data(Recorded.error(403, reason: "forbidden", domain: "global").utf8), [:])
                }
                return try Recorded.google()(request)
            })
            let first = await h.engine.refresh()
            #expect(first.data.eventsByAccount[DecodingTests.acme]?.isEmpty == false)
            revoked.update { $0 = true }
            h.advance(2 * 3600)
            let report = await h.engine.refresh()
            #expect(report.outcome == .current)
            #expect(report.data.eventsByAccount[DecodingTests.acme]?.isEmpty == true)
            #expect(report.data.eventsByAccount[DecodingTests.gmail] == first.data.eventsByAccount[DecodingTests.gmail])
            #expect(report.data.fetchedAtByAccount[DecodingTests.acme] == h.fixture.now.addingTimeInterval(7200))
        }

        @Test func serverErrorsReadAsUnreachable() async throws {
            let h = try Harness(handler: { request in
                if request.url?.host() == "www.googleapis.com" { return (500, Data(), [:]) }
                return try Recorded.google()(request)
            })
            let report = await h.engine.refresh()
            #expect(report.outcome == .unreachable)
            #expect(report.data.lastFetchedAt == nil)
            #expect(WidgetSnapshot.read(from: h.cache) == nil)
        }

        @Test func anExpiredAccessTokenIsRefreshedOnceAndRetried() async throws {
            // Google answers 401 to the stale token although its expiry is half an hour away.
            let h = try Harness()
            try h.tokens.save(
                StoredToken(
                    refreshToken: "refresh-acme", accessToken: "stale-acme",
                    accessExpiry: h.fixture.now.addingTimeInterval(1800), email: "you@acme.com",
                    scope: Recorded.fullScope), for: DecodingTests.acme)
            let report = await h.engine.refresh()
            #expect(report.outcome == .current)
            #expect(try h.tokens.token(for: DecodingTests.acme)?.accessToken == "access-acme")
            #expect(report.data.eventsByAccount[DecodingTests.acme]?.contains { $0.title == "Standup" } == true)
        }

        @Test func signInAddsTheAccountAndSignInAgainRepairsIt() async throws {
            let h = try Harness(accounts: false)
            let request = try h.engine.authorizationRequest()
            let callback = URL(string: "\(request.callbackScheme):/oauth2redirect?state=\(request.state)&code=code-acme")!
            let account = try await h.engine.completeSignIn(request, callback: callback)
            #expect(account.id == DecodingTests.acme)
            #expect(account.email == "you@acme.com")
            #expect(!account.signedOut)
            #expect(account.addedAt == h.fixture.now)
            #expect(try h.tokens.token(for: DecodingTests.acme)?.refreshToken == "refresh-acme")
            #expect(h.engine.load().accounts == [account])

            let report = await h.engine.refresh()
            #expect(report.data.calendars.map(\.name) == ["you@acme.com", "Team offsites", "you@gmail.com"])

            // Sign In Again with the wrong Google account is refused and changes nothing.
            let again = try h.engine.authorizationRequest(loginHint: "you@gmail.com")
            await #expect(throws: OAuthError.differentAccount(email: "you@acme.com")) {
                try await h.engine.completeSignIn(
                    again, callback: URL(string: "\(again.callbackScheme):/oauth2redirect?state=\(again.state)&code=code-acme")!,
                    repairing: DecodingTests.gmail)
            }

            // A grant without calendar access adds the account, signed out, with no token.
            let partial = try h.engine.authorizationRequest()
            let narrow = try await h.engine.completeSignIn(
                partial, callback: URL(string: "\(partial.callbackScheme):/oauth2redirect?state=\(partial.state)&code=code-partial")!)
            #expect(narrow.signedOut)
            #expect(try h.tokens.token(for: narrow.id) == nil)
            #expect(h.engine.load().accounts.count == 2)
        }

        @Test func removingAnAccountForgetsEverythingOnDevice() async throws {
            let h = try Harness()
            _ = await h.engine.refresh()
            let personal = CalendarID(account: DecodingTests.gmail, googleID: "you@gmail.com")
            try await h.engine.setVisible(false, calendar: personal)
            try await h.engine.removeAccount(DecodingTests.gmail)
            let data = h.engine.load()
            #expect(data.accounts.map(\.id) == [DecodingTests.acme])
            #expect(data.calendarsByAccount[DecodingTests.gmail] == nil)
            #expect(data.eventsByAccount[DecodingTests.gmail] == nil)
            #expect(data.visibility.overrides.isEmpty)
            #expect(try h.tokens.token(for: DecodingTests.gmail) == nil)
            // The acme copy of the shared Personal calendar takes over, with Google's flag.
            #expect(data.calendars.contains { $0.id == CalendarID(account: DecodingTests.acme, googleID: "you@gmail.com") })
            let snapshot = try #require(WidgetSnapshot.read(from: h.cache))
            #expect(snapshot.accountCount == 1)
            #expect(!snapshot.events.contains { $0.account == DecodingTests.gmail })
        }

        @Test func hidingACalendarRewritesTheSnapshot() async throws {
            let h = try Harness()
            _ = await h.engine.refresh()
            let work = CalendarID(account: DecodingTests.acme, googleID: "you@acme.com")
            try await h.engine.setVisible(false, calendar: work)
            let data = h.engine.load()
            #expect(!data.isVisible(work))
            let wednesday = CivilDate(year: 2026, month: 11, day: 4)
            #expect(!data.events(in: wednesday...wednesday, calendar: h.fixture.calendar).contains { $0.title == "Standup" })
            let snapshot = try #require(WidgetSnapshot.read(from: h.cache))
            #expect(!snapshot.events.contains { $0.title == "Standup" })
            // Its events stay cached, so showing it again is instant.
            #expect(data.eventsByAccount[DecodingTests.acme]?.contains { $0.title == "Standup" } == true)
            try await h.engine.setVisible(true, calendar: work)
            #expect(h.engine.load().events(in: wednesday...wednesday, calendar: h.fixture.calendar).contains { $0.title == "Standup" })
        }

        @Test func theWindowExtendsWithoutRefetchingWhatIsCovered() async throws {
            let h = try Harness(handler: { request in
                if request.url?.path().hasSuffix("/events") == true,
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                    query.first(where: { $0.name == "timeMin" })?.value?.hasPrefix("2027") == true
                {
                    let personal = request.url!.path(percentEncoded: false).contains("/you@gmail.com/")
                    return (200, Data((personal ? Recorded.quarterClose : #"{"items": []}"#).utf8), [:])
                }
                return try Recorded.google()(request)
            })
            _ = await h.engine.refresh()
            let before = h.stub.requests.count
            let report = await h.engine.extendWindow(
                toInclude: CivilDate(year: 2027, month: 3, day: 1)...CivilDate(year: 2027, month: 4, day: 30))
            #expect(report.outcome == .current)
            let added = h.stub.requests[before...].filter { $0.url?.path().hasSuffix("/events") == true }
            #expect(!added.isEmpty)
            // The full read covered through today plus 127, so the stretch starts the day after.
            for request in added {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(query.first { $0.name == "timeMin" }?.value == "2027-03-11T23:00:00Z")
                #expect(query.first { $0.name == "timeMax" }?.value == "2027-04-30T22:00:00Z")
                #expect(query.first { $0.name == "syncToken" } == nil)
            }
            let file = try #require(h.cache.account(DecodingTests.gmail))
            let personal = CalendarID(account: DecodingTests.gmail, googleID: "you@gmail.com")
            #expect(file.state(of: personal)?.days == CivilDate(year: 2026, month: 9, day: 30)...CivilDate(year: 2027, month: 4, day: 30))
            #expect(report.data.syncedDays == CivilDate(year: 2026, month: 9, day: 30)...CivilDate(year: 2027, month: 4, day: 30))
            #expect(file.fetchedAt == h.fixture.now)
            #expect(file.events.contains { $0.title == "Quarter close" })
            #expect(file.events.filter { $0.title == "Lunch with Maya" }.count == 1)

            // Asking again for covered days fetches nothing.
            let again = h.stub.requests.count
            _ = await h.engine.extendWindow(toInclude: CivilDate(year: 2026, month: 12, day: 1)...CivilDate(year: 2027, month: 4, day: 1))
            #expect(h.stub.requests.count == again)
        }

        @Test func snapshotNewerWins() throws {
            let folder = FileManager.default.temporaryDirectory.appending(path: "day-wp1-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let cache = CacheDirectory(url: folder)
            let t = Date(timeIntervalSince1970: 1_793_797_000)
            func snapshot(_ at: Date, accounts: Int = 2) -> WidgetSnapshot {
                WidgetSnapshot(fetchedAt: at, accountCount: accounts, signedOutAccounts: 0, events: [])
            }
            let now = t.addingTimeInterval(120)
            #expect(try snapshot(t).write(to: cache, now: now))
            #expect(try snapshot(t.addingTimeInterval(-60)).write(to: cache, now: now) == false)
            #expect(WidgetSnapshot.read(from: cache)?.fetchedAt == t)
            #expect(try snapshot(t, accounts: 1).write(to: cache, now: now))
            #expect(WidgetSnapshot.read(from: cache)?.accountCount == 1)
            #expect(try snapshot(t.addingTimeInterval(60)).write(to: cache, now: now))
            #expect(try snapshot(t, accounts: 3).write(to: cache, force: true, now: now))
            #expect(WidgetSnapshot.read(from: cache)?.accountCount == 3)
            #expect(snapshot(t).isFresh(at: t.addingTimeInterval(59)))
            #expect(!snapshot(t).isFresh(at: t.addingTimeInterval(60)))
            #expect(!snapshot(t).isFresh(at: t.addingTimeInterval(-60)))
        }

        @Test func noAccountsWritesAnEmptySnapshotAtOnce() {
            let now = Date(timeIntervalSince1970: 1_793_797_000)
            let snapshot = CalendarData().widgetSnapshot(now: now, calendar: Calendar(identifier: .gregorian))
            #expect(snapshot == WidgetSnapshot(fetchedAt: now, accountCount: 0, signedOutAccounts: 0, events: []))
            let unfetched = CalendarData(accounts: [Account(id: DecodingTests.gmail, email: "you@gmail.com", addedAt: now)])
            #expect(unfetched.widgetSnapshot(now: now, calendar: Calendar(identifier: .gregorian)) == nil)
        }

        @Test func widgetUsesAFreshSnapshotWithoutTheNetwork() async throws {
            let h = try Harness()
            _ = await h.engine.refresh()
            let before = h.stub.requests.count
            h.advance(30)
            let snapshot = await h.engine.refreshWidgetSnapshot()
            #expect(snapshot?.fetchedAt == h.fixture.now)
            #expect(h.stub.requests.count == before)
        }

        @Test func widgetFetchesAStaleSnapshotWithinItsDeadline() async throws {
            let h = try Harness()
            _ = await h.engine.refresh()
            h.advance(3600)
            let before = h.stub.requests.count
            let snapshot = try #require(await h.engine.refreshWidgetSnapshot())
            #expect(snapshot.fetchedAt == h.fixture.now.addingTimeInterval(3600))
            #expect(WidgetSnapshot.read(from: h.cache) == snapshot)
            // No calendar list and no labels: only events, for visible calendars.
            let added = h.stub.requests[before...].compactMap { $0.url?.path(percentEncoded: false) }
            #expect(added.allSatisfy { $0.hasSuffix("/events") || $0 == "/token" })
            #expect(snapshot.events.contains { $0.title == "Standup" })
            // The app's own files are untouched.
            #expect(h.cache.account(DecodingTests.acme)?.fetchedAt == h.fixture.now)
        }

        @Test func widgetFallsBackWhenGoogleIsTooSlow() async throws {
            let slow = Shared(false)
            let h = try Harness(handler: { request in
                if slow.value { Thread.sleep(forTimeInterval: 0.3) }
                return try Recorded.google()(request)
            })
            _ = await h.engine.refresh()
            let old = WidgetSnapshot.read(from: h.cache)
            slow.update { $0 = true }
            h.advance(3 * 3600)
            let snapshot = await h.engine.refreshWidgetSnapshot(deadline: .milliseconds(100))
            #expect(snapshot == old)
            #expect(WidgetSnapshot.read(from: h.cache) == old)
        }

        @Test func overlappingRefreshesShareOneFetch() async throws {
            let h = try Harness(handler: { request in
                Thread.sleep(forTimeInterval: 0.02)
                return try Recorded.google()(request)
            })
            async let a = h.engine.refresh()
            async let b = h.engine.refresh()
            let (first, second) = await (a, b)
            #expect(first.data == second.data)
            #expect(h.paths("/calendarList").count == 2)
        }

        @Test func cacheFileNamesStayInsideTheFolder() {
            #expect(CacheFile.events(AccountID("../../etc")) == "events-______etc.json")
            #expect(CacheFile.calendars(DecodingTests.gmail) == "calendars-100000000000000000001.json")
        }

        @Test func visibilityRoundTrips() throws {
            var visibility = CalendarVisibility()
            let work = CalendarID(account: DecodingTests.acme, googleID: "you@acme.com")
            visibility.set(false, for: work)
            let again = try DayJSON.decoder().decode(CalendarVisibility.self, from: DayJSON.encoder().encode(visibility))
            #expect(again == visibility)
            let info = CalendarInfo(id: work, name: "w", colorHex: "#4285F4", selected: true)
            #expect(!again.isVisible(info))
            visibility.forget(DecodingTests.acme)
            #expect(visibility.isVisible(info))
        }
    }
}

// MARK: - Test doubles

extension RetryPolicy {
    /// Retries at once, so a test of backoff costs no time.
    static let noWait = RetryPolicy(maxAttempts: 3, sleep: { _ in })
}

extension DecodingTests {
    /// A value shared between a test and the closures it hands out.
    final class Shared<Value: Sendable>: Sendable {
        private let mutex: Mutex<Value>

        init(_ value: Value) {
            mutex = Mutex(value)
        }

        var value: Value {
            mutex.withLock { $0 }
        }

        func update<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
            mutex.withLock { body(&$0) }
        }
    }

    /// An HTTP transport that answers from a closure and remembers every request.
    final class Stub: HTTPTransport {
        typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])

        private let handler: Handler
        private let log = Mutex<[URLRequest]>([])

        init(_ handler: @escaping Handler) {
            self.handler = handler
        }

        var requests: [URLRequest] {
            log.withLock { $0 }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            // URLSession stops a cancelled task's request; so does the stub.
            try Task.checkCancellation()
            log.withLock { $0.append(request) }
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (data, response)
        }
    }

    /// Invented Google answers. Every person, address and account here is invented; the events
    /// mirror `invented-week.json` so decoding can be checked against it exactly.
    enum Recorded {
        static let clientID = "123456789012-abcdefghijklmnop.apps.googleusercontent.com"
        static let fullScope =
            "openid https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/userinfo.email"

        static func idToken(sub: String, email: String, audience: String = clientID) -> String {
            let header = PKCE.base64URL(Data(#"{"alg":"RS256","kid":"invented","typ":"JWT"}"#.utf8))
            let claims: [String: Any] = [
                "iss": "https://accounts.google.com", "aud": audience, "azp": audience, "sub": sub,
                "email": email, "email_verified": true, "iat": 1_793_797_000, "exp": 1_793_800_600,
            ]
            let payload = PKCE.base64URL(try! JSONSerialization.data(withJSONObject: claims))
            return "\(header).\(payload).aW52ZW50ZWQ"
        }

        static func form(_ request: URLRequest) -> [String: String] {
            guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return [:] }
            var form: [String: String] = [:]
            for pair in text.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                if parts.count == 2 { form[parts[0]] = parts[1] }
            }
            return form
        }

        static func error(_ code: Int, reason: String, domain: String) -> String {
            #"{"error": {"code": \#(code), "message": "\#(reason)", "errors": [{"domain": "\#(domain)", "reason": "\#(reason)"}]}}"#
        }

        /// What Google answers every Calendar call with while the API is off in the project.
        static let accessNotConfigured = #"""
            {"error": {"code": 403,
              "message": "Google Calendar API has not been used in project 123456789012 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/calendar-json.googleapis.com/overview?project=123456789012 then retry.",
              "errors": [{"message": "Google Calendar API has not been used in project 123456789012 before or it is disabled.", "domain": "usageLimits", "reason": "accessNotConfigured", "extendedHelp": "https://console.developers.google.com"}],
              "status": "PERMISSION_DENIED"}}
            """#

        static func token(access: String, refresh: String?, scope: String = fullScope, idToken: String? = nil) -> String {
            var fields = [#""access_token": "\#(access)""#, #""expires_in": 3599"#, #""scope": "\#(scope)""#, #""token_type": "Bearer""#]
            if let refresh { fields.append(#""refresh_token": "\#(refresh)""#) }
            if let idToken { fields.append(#""id_token": "\#(idToken)""#) }
            return "{" + fields.joined(separator: ", ") + "}"
        }

        /// Google, as far as the recorded data goes: the token endpoint, both accounts'
        /// calendar lists, the work calendar's labels and every calendar's events.
        static func google() -> Stub.Handler {
            { request in
                let url = request.url!
                let path = url.path(percentEncoded: false)
                let auth = request.value(forHTTPHeaderField: "Authorization")
                func ok(_ json: String) -> (Int, Data, [String: String]) {
                    (200, Data(json.utf8), ["Content-Type": "application/json"])
                }
                if url.host() == "oauth2.googleapis.com", path == "/token" {
                    let form = form(request)
                    switch (form["grant_type"] ?? "", form["refresh_token"] ?? form["code"] ?? "") {
                    case ("refresh_token", "refresh-gmail"): return ok(token(access: "access-gmail", refresh: nil))
                    case ("refresh_token", "refresh-acme"): return ok(token(access: "access-acme", refresh: nil))
                    case ("refresh_token", "refresh-narrow"):
                        return ok(token(access: "access-narrow", refresh: nil, scope: "openid https://www.googleapis.com/auth/userinfo.email"))
                    case ("authorization_code", "code-acme"):
                        return ok(token(access: "access-acme", refresh: "refresh-acme", idToken: idToken(sub: acmeSub, email: "you@acme.com")))
                    case ("authorization_code", "code-partial"):
                        return ok(token(access: "access-partial", refresh: "refresh-partial", scope: "openid https://www.googleapis.com/auth/userinfo.email", idToken: idToken(sub: "100000000000000000003", email: "you@studio.example")))
                    default:
                        return (400, Data(#"{"error": "invalid_grant", "error_description": "Token has been expired or revoked.", "error_subtype": "invalid_rapt"}"#.utf8), [:])
                    }
                }
                guard url.host() == "www.googleapis.com", path.hasPrefix("/calendar/v3/") else { return (404, Data(), [:]) }
                let parts = path.dropFirst("/calendar/v3/".count).split(separator: "/").map(String.init)
                let account = auth == "Bearer access-gmail" ? gmailSub : auth == "Bearer access-acme" ? acmeSub : nil
                guard let account else { return (401, Data(Recorded.error(401, reason: "authError", domain: "global").utf8), [:]) }
                if parts == ["users", "me", "calendarList"] {
                    return ok(account == gmailSub ? gmailCalendarList : acmeCalendarList)
                }
                if parts.count == 2, parts[0] == "calendars" {
                    return ok(parts[1] == "you@acme.com" ? acmeCalendar : #"{"id": "\#(parts[1])", "summary": "x"}"#)
                }
                if parts.count == 3, parts[0] == "calendars", parts[2] == "events" {
                    let pages = events[CalendarID(account: AccountID(account), googleID: parts[1])]
                        ?? events.first { $0.key.googleID == parts[1] }?.value ?? [#"{"items": []}"#]
                    let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first { $0.name == "pageToken" }?.value == "page-2" ? 1 : 0
                    return ok(pages[min(page, pages.count - 1)])
                }
                return (404, Data(), [:])
            }
        }

        static let gmailSub = "100000000000000000001"
        static let acmeSub = "100000000000000000002"

        static let gmailCalendarList = #"""
            {"kind": "calendar#calendarList", "etag": "\"p32g\"", "nextSyncToken": "invented", "items": [
              {"kind": "calendar#calendarListEntry", "id": "en.dutch#holiday@group.v.calendar.google.com", "summary": "Holidays in the Netherlands", "timeZone": "Europe/Amsterdam", "colorId": "8", "backgroundColor": "#0b8043", "foregroundColor": "#ffffff", "selected": true, "accessRole": "reader"},
              {"kind": "calendar#calendarListEntry", "id": "you@gmail.com", "summary": "you@gmail.com", "summaryOverride": "Personal", "timeZone": "Europe/Amsterdam", "colorId": "14", "backgroundColor": "#039be5", "foregroundColor": "#000000", "selected": true, "accessRole": "owner", "primary": true},
              {"kind": "calendar#calendarListEntry", "id": "addressbook#contacts@group.v.calendar.google.com", "summary": "Birthdays", "timeZone": "Europe/Amsterdam", "colorId": "13", "backgroundColor": "#7cb342", "foregroundColor": "#000000", "selected": true, "accessRole": "reader"}
            ]}
            """#

        /// The work account also sees the personal calendar, shared with it read-only; it must
        /// fold into the personal account's copy.
        static let acmeCalendarList = #"""
            {"kind": "calendar#calendarList", "items": [
              {"id": "c_7f3e9a1offsites@group.calendar.google.com", "summary": "Team offsites", "timeZone": "Europe/Amsterdam", "backgroundColor": "#8e24aa", "accessRole": "writer"},
              {"id": "you@acme.com", "summary": "you@acme.com", "timeZone": "Europe/Amsterdam", "backgroundColor": "#4285f4", "selected": true, "accessRole": "owner", "primary": true},
              {"id": "you@gmail.com", "summary": "you@gmail.com", "timeZone": "Europe/Amsterdam", "backgroundColor": "#039be5", "selected": true, "accessRole": "reader"}
            ]}
            """#

        static let acmeCalendar = #"""
            {"kind": "calendar#calendar", "id": "you@acme.com", "summary": "you@acme.com", "timeZone": "Europe/Amsterdam",
             "labelProperties": {"eventLabels": [{"id": "customer", "name": "Customer", "backgroundColor": "#f4511e"}]}}
            """#

        static let quarterClose = #"""
            {"items": [{"id": "q1close2027", "iCalUID": "q1close2027@google.com", "summary": "Quarter close",
              "organizer": {"email": "you@gmail.com", "self": true},
              "start": {"dateTime": "2027-03-15T10:00:00+01:00"}, "end": {"dateTime": "2027-03-15T11:00:00+01:00"}}]}
            """#

        /// Events per calendar, as `events.list` pages. The personal calendar comes in two pages.
        static let events: [CalendarID: [String]] = [
            CalendarID(account: AccountID(gmailSub), googleID: "you@gmail.com"): [
                #"""
                {"kind": "calendar#events", "summary": "you@gmail.com", "timeZone": "Europe/Amsterdam", "nextPageToken": "page-2", "items": [
                  {"kind": "calendar#event", "id": "1e813e74970635342528", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=MWU4MTNlNzQ5NzA2MzUzNDI1MjggeW91QGdtYWlsLmNvbQ",
                   "summary": "Lunch with Maya", "location": "Café Nord\nRua Inventada 4, 1100-053 Lisboa",
                   "creator": {"email": "you@gmail.com", "self": true}, "organizer": {"email": "you@gmail.com", "self": true},
                   "start": {"dateTime": "2026-11-04T12:30:00+01:00"}, "end": {"dateTime": "2026-11-04T13:30:00+01:00"},
                   "iCalUID": "1e813e74970635342528@google.com", "eventType": "default"},
                  {"kind": "calendar#event", "id": "7hq2k4investor04", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=N2hxMms0aW52ZXN0b3IwNCB5b3VAZ21haWwuY29t",
                   "summary": "Investor call",
                   "description": "Q4 numbers and the seed extension.<br>Deck: <a href=\"https://harbor.example/deck/q4\">https://harbor.example/deck/q4</a>",
                   "colorId": "3", "organizer": {"email": "ines@harbor.example"},
                   "start": {"dateTime": "2026-11-04T08:00:00-05:00", "timeZone": "America/New_York"},
                   "end": {"dateTime": "2026-11-04T09:00:00-05:00", "timeZone": "America/New_York"},
                   "iCalUID": "7hq2k4investor04@google.com",
                   "attendees": [
                     {"email": "ines@harbor.example", "organizer": true, "responseStatus": "accepted"},
                     {"email": "tom@harbor.example", "responseStatus": "accepted"},
                     {"email": "you@gmail.com", "self": true, "responseStatus": "needsAction"},
                     {"email": "priya@acme.com", "responseStatus": "accepted"},
                     {"email": "you@acme.com", "responseStatus": "needsAction"},
                     {"email": "c_1888boardroom@resource.calendar.google.com", "displayName": "Boardroom", "resource": true, "responseStatus": "accepted"}
                   ],
                   "hangoutLink": "https://meet.google.com/ick-auwh-blm",
                   "conferenceData": {"entryPoints": [
                     {"entryPointType": "video", "uri": "https://meet.google.com/ick-auwh-blm", "label": "meet.google.com/ick-auwh-blm"},
                     {"entryPointType": "phone", "uri": "tel:+31-20-000-0000", "pin": "000000000"}]},
                   "eventType": "default"}
                ]}
                """#,
                #"""
                {"kind": "calendar#events", "items": [
                  {"kind": "calendar#event", "id": "abeaab179545e127c03f", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=YWJlYWFiMTc5NTQ1ZTEyN2MwM2YgeW91QGdtYWlsLmNvbQ",
                   "summary": "Lisbon", "organizer": {"email": "you@gmail.com", "self": true},
                   "start": {"date": "2026-11-03"}, "end": {"date": "2026-11-06"}, "transparency": "transparent",
                   "iCalUID": "abeaab179545e127c03f@google.com", "eventType": "default"},
                  {"kind": "calendar#event", "id": "fd852fec28c581e323c9", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=ZmQ4NTJmZWMyOGM1ODFlMzIzYzkgeW91QGdtYWlsLmNvbQ",
                   "summary": "Flight to Amsterdam (TP 674)", "location": "Lisbon Humberto Delgado (LIS)",
                   "organizer": {"email": "you@gmail.com", "self": true},
                   "start": {"dateTime": "2026-11-05T19:30:00.000Z", "timeZone": "Europe/Lisbon"},
                   "end": {"dateTime": "2026-11-05T23:15:00Z", "timeZone": "Europe/Amsterdam"},
                   "iCalUID": "fd852fec28c581e323c9@google.com", "eventType": "fromGmail"}
                ]}
                """#,
            ],
            CalendarID(account: AccountID(gmailSub), googleID: "en.dutch#holiday@group.v.calendar.google.com"): [
                #"""
                {"kind": "calendar#events", "items": [
                  {"kind": "calendar#event", "id": "61ff0b21cb887bef0096", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=NjFmZjBiMjFjYjg4N2JlZjAwOTYgZW4uZHV0Y2gjaG9saWRheUBncm91cC52LmNhbGVuZGFyLmdvb2dsZS5jb20",
                   "summary": "Sint Maarten",
                   "organizer": {"email": "en.dutch#holiday@group.v.calendar.google.com", "displayName": "Holidays in the Netherlands"},
                   "start": {"date": "2026-11-11"}, "end": {"date": "2026-11-12"}, "transparency": "transparent",
                   "visibility": "public", "iCalUID": "61ff0b21cb887bef0096@google.com", "eventType": "default"}
                ]}
                """#
            ],
            CalendarID(account: AccountID(gmailSub), googleID: "addressbook#contacts@group.v.calendar.google.com"): [
                #"""
                {"kind": "calendar#events", "items": [
                  {"kind": "calendar#event", "id": "ed793112e10e_20261108", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=ZWQ3OTMxMTJlMTBlXzIwMjYxMTA4IGFkZHJlc3Nib29rI2NvbnRhY3RzQGdyb3VwLnYuY2FsZW5kYXIuZ29vZ2xlLmNvbQ",
                   "summary": "Noor's birthday", "start": {"date": "2026-11-08"}, "end": {"date": "2026-11-09"},
                   "recurringEventId": "ed793112e10e", "originalStartTime": {"date": "2026-11-08"},
                   "transparency": "transparent", "visibility": "private", "iCalUID": "ed793112e10e@google.com",
                   "eventType": "birthday", "birthdayProperties": {"type": "birthday", "contact": "people/c0000000000000000001"}}
                ]}
                """#
            ],
            CalendarID(account: AccountID(acmeSub), googleID: "you@acme.com"): [
                #"""
                {"kind": "calendar#events", "summary": "you@acme.com", "timeZone": "Europe/Amsterdam", "items": [
                  {"id": "officehrs8c_20261103T150000Z", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=b2ZmaWNlaHJzOGNfMjAyNjExMDNUMTUwMDAwWiB5b3VAYWNtZS5jb20",
                   "summary": "Customer office hours", "colorId": "7", "eventLabelId": "customer",
                   "organizer": {"email": "priya@acme.com"},
                   "start": {"dateTime": "2026-11-03T16:00:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "end": {"dateTime": "2026-11-03T17:00:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "recurringEventId": "officehrs8c",
                   "originalStartTime": {"dateTime": "2026-11-03T16:00:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "iCalUID": "officehrs8c@google.com",
                   "attendees": [
                     {"email": "priya@acme.com", "organizer": true, "responseStatus": "accepted"},
                     {"email": "you@acme.com", "self": true, "responseStatus": "tentative"},
                     {"email": "ana@northwind.example", "responseStatus": "needsAction"}
                   ],
                   "conferenceData": {"entryPoints": [{"entryPointType": "video", "uri": "https://meet.google.com/wyo-ecdo-juv"}]},
                   "eventType": "default"},
                  {"id": "standup4k2q_20261104T083000Z", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=c3RhbmR1cDRrMnFfMjAyNjExMDRUMDgzMDAwWiB5b3VAYWNtZS5jb20",
                   "summary": "Standup", "organizer": {"email": "priya@acme.com"},
                   "start": {"dateTime": "2026-11-04T09:30:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "end": {"dateTime": "2026-11-04T09:45:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "recurringEventId": "standup4k2q",
                   "originalStartTime": {"dateTime": "2026-11-04T09:30:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "iCalUID": "standup4k2q@google.com",
                   "attendees": [
                     {"email": "priya@acme.com", "organizer": true, "responseStatus": "accepted"},
                     {"email": "you@acme.com", "self": true, "responseStatus": "accepted"},
                     {"email": "sam@acme.com", "responseStatus": "accepted"},
                     {"email": "lena@acme.com", "responseStatus": "accepted"},
                     {"email": "mo@acme.com", "responseStatus": "needsAction"},
                     {"email": "ruth@acme.com", "responseStatus": "accepted"},
                     {"email": "joe@acme.com", "responseStatus": "tentative"}
                   ],
                   "hangoutLink": "https://meet.google.com/hvv-lzlt-aej",
                   "conferenceData": {"entryPoints": [{"entryPointType": "video", "uri": "https://meet.google.com/hvv-lzlt-aej"}]},
                   "eventType": "default"},
                  {"id": "0f7af481aa10fff86479", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=MGY3YWY0ODFhYTEwZmZmODY0NzkgeW91QGFjbWUuY29t",
                   "summary": "Lisbon", "organizer": {"email": "you@acme.com", "self": true},
                   "start": {"date": "2026-11-04"}, "end": {"date": "2026-11-05"}, "transparency": "transparent",
                   "visibility": "public", "iCalUID": "0f7af481aa10fff86479@google.com", "eventType": "workingLocation",
                   "workingLocationProperties": {"type": "customLocation", "customLocation": {"label": "Lisbon"}}},
                  {"id": "60645a7570c87af11cbe", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=NjA2NDVhNzU3MGM4N2FmMTFjYmUgeW91QGFjbWUuY29t",
                   "summary": "Vendor demo", "organizer": {"email": "lena@vendorly.example"},
                   "start": {"dateTime": "2026-11-04T10:00:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "end": {"dateTime": "2026-11-04T10:30:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "iCalUID": "60645a7570c87af11cbe@google.com",
                   "attendees": [
                     {"email": "lena@vendorly.example", "organizer": true, "responseStatus": "accepted"},
                     {"email": "you@acme.com", "self": true, "responseStatus": "declined"},
                     {"email": "priya@acme.com", "responseStatus": "needsAction"},
                     {"email": "mo@vendorly.example", "responseStatus": "accepted"}
                   ],
                   "hangoutLink": "https://meet.google.com/oud-mfwx-vpw", "eventType": "default"},
                  {"id": "7hq2k4investor04", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=N2hxMms0aW52ZXN0b3IwNCB5b3VAYWNtZS5jb20",
                   "summary": "Investor call",
                   "description": "Q4 numbers and the seed extension.<br>Deck: <a href=\"https://harbor.example/deck/q4\">https://harbor.example/deck/q4</a>",
                   "colorId": "3", "organizer": {"email": "ines@harbor.example"},
                   "start": {"dateTime": "2026-11-04T14:00:00+01:00", "timeZone": "America/New_York"},
                   "end": {"dateTime": "2026-11-04T15:00:00+01:00", "timeZone": "America/New_York"},
                   "iCalUID": "7hq2k4investor04@google.com",
                   "attendees": [
                     {"email": "ines@harbor.example", "organizer": true, "responseStatus": "accepted"},
                     {"email": "tom@harbor.example", "responseStatus": "accepted"},
                     {"email": "priya@acme.com", "responseStatus": "accepted"},
                     {"email": "sam@acme.com", "responseStatus": "accepted"},
                     {"email": "you@acme.com", "self": true, "responseStatus": "needsAction"}
                   ],
                   "conferenceData": {"entryPoints": [{"entryPointType": "video", "uri": "https://meet.google.com/ick-auwh-blm"}]},
                   "eventType": "default"},
                  {"id": "ooofriday0k_20261106T153000Z", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=b29vZnJpZGF5MGtfMjAyNjExMDZUMTUzMDAwWiB5b3VAYWNtZS5jb20",
                   "summary": "Out of office", "organizer": {"email": "you@acme.com", "self": true},
                   "start": {"dateTime": "2026-11-06T16:30:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "end": {"dateTime": "2026-11-06T23:00:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "recurringEventId": "ooofriday0k",
                   "originalStartTime": {"dateTime": "2026-11-06T16:30:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "iCalUID": "ooofriday0k@google.com", "eventType": "outOfOffice"},
                  {"id": "11bb22a75266e394a01d", "status": "confirmed",
                   "htmlLink": "https://www.google.com/calendar/event?eid=MTFiYjIyYTc1MjY2ZTM5NGEwMWQgeW91QGFjbWUuY29t",
                   "summary": "Out of office", "organizer": {"email": "you@acme.com", "self": true},
                   "start": {"dateTime": "2026-11-09T00:00:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "end": {"dateTime": "2026-11-13T00:00:00+01:00", "timeZone": "Europe/Amsterdam"},
                   "iCalUID": "11bb22a75266e394a01d@google.com", "eventType": "outOfOffice",
                   "outOfOfficeProperties": {"autoDeclineMode": "declineOnlyNewConflictingInvitations"}},
                  {"id": "broken-no-start", "status": "confirmed", "summary": "Skipped: no start"}
                ]}
                """#
            ],
        ]
    }
}
