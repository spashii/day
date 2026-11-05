import Foundation
import Testing

@testable import DayCore

/// The contracts every package builds on: the fixture decodes into the model with the
/// shape the golden tests rely on, civil dates never drift with the zone, colors map onto
/// the system set, and the app's URLs survive Google's calendar IDs.
struct ModelTests {
    static func fixture() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "invented-week", withExtension: "json", subdirectory: "Fixtures"))
        return try Fixture.load(from: url)
    }

    @Test func fixtureHasTwoAccountsInOrderAdded() throws {
        let fixture = try Self.fixture()
        #expect(fixture.accounts.map(\.email) == ["you@gmail.com", "you@acme.com"])
        #expect(fixture.accounts[0].addedAt < fixture.accounts[1].addedAt)
        #expect(fixture.accounts[0].isConsumer)
        #expect(fixture.accounts[1].domain == "acme.com")
        #expect(!fixture.accounts[1].isConsumer)
    }

    @Test func fixtureCalendars() throws {
        let fixture = try Self.fixture()
        let byName = Dictionary(uniqueKeysWithValues: fixture.calendars.map { ($0.name, $0) })
        #expect(byName["Holidays in the Netherlands"]?.isHoliday == true)
        #expect(byName["Personal"]?.isHoliday == false)
        #expect(byName["Team offsites"]?.selected == false)
        #expect(byName["you@acme.com"]?.labels["customer"]?.name == "Customer")
        #expect(byName["Personal"]?.colorKey == .cyan)
        #expect(byName["you@acme.com"]?.colorKey == .blue)
    }

    /// The invented Wednesday of the design: six counted events, plus the all-day line,
    /// a working location, a declined call and the investor call on both accounts.
    @Test func inventedWednesday() throws {
        let fixture = try Self.fixture()
        let calendar = fixture.calendar
        let wednesday = CivilDate(year: 2026, month: 11, day: 4)
        let timed = fixture.events.filter { event in
            guard case .timed(let start, _, _) = event.time else { return false }
            return CivilDate(start, in: calendar) == wednesday
        }
        let counted = timed.filter {
            $0.response != .declined && ($0.kind == .default || $0.kind == .fromGmail)
        }
        let times = Set(counted.map { event in
            "\(Formatting.time(event.time.start(in: calendar), calendar: calendar)) \(event.title)"
        })
        #expect(
            times == [
                "9:30 Standup", "11:00 Design review", "12:30 Lunch with Maya", "14:00 Investor call",
                "14:30 Acme sync", "16:00 Weekly planning",
            ])
        #expect(timed.contains { $0.title == "Vendor demo" && $0.response == .declined })

        let lunch = try #require(counted.first { $0.title == "Lunch with Maya" })
        #expect(!lunch.hasOtherAttendees)
        #expect(!lunch.isRecurring)
        #expect(Formatting.place(lunch) == "Café Nord")

        let allDay = fixture.events.filter {
            $0.isAllDay && coveredDays($0, calendar: calendar).contains(wednesday)
        }
        #expect(allDay.contains { $0.title == "Lisbon" && $0.kind == .default })
        #expect(allDay.contains { $0.kind == .workingLocation })
    }

    @Test func crossAccountDuplicateMergesToOne() throws {
        let fixture = try Self.fixture()
        let copies = fixture.events.filter { $0.title == "Investor call" && $0.iCalUID.hasPrefix("7hq2") }
        #expect(copies.count == 2)
        #expect(Set(copies.map(\.account)).count == 2)

        let investor = merged(fixture.events).filter { $0.iCalUID == copies[0].iCalUID }
        #expect(investor.count == 1)
        #expect(investor.first?.calendars.count == 2)
        // Neither copy is organized or answered, so the first-added account's copy is kept.
        #expect(investor.first?.account == fixture.accounts[0].id)
    }

    @Test func thursdayStartsWithStandup() throws {
        let fixture = try Self.fixture()
        let calendar = fixture.calendar
        let thursday = CivilDate(year: 2026, month: 11, day: 5)
        let first = fixture.events
            .filter { !$0.isAllDay && $0.response != .declined && $0.kind == .default }
            .filter { CivilDate($0.time.start(in: calendar), in: calendar) == thursday }
            .min { $0.time.start(in: calendar) < $1.time.start(in: calendar) }
        #expect(first?.title == "Standup")
        #expect(first.map { Formatting.time($0.time.start(in: calendar), calendar: calendar) } == "9:30")
    }

    @Test func fixtureCoversTheOtherCases() throws {
        let fixture = try Self.fixture()
        #expect(fixture.events.contains { $0.kind == .outOfOffice && !$0.isRecurring })
        #expect(fixture.events.contains { $0.kind == .outOfOffice && $0.isRecurring })
        #expect(fixture.events.contains { $0.kind == .birthday })
        #expect(fixture.events.contains { $0.kind == .focusTime })
        #expect(fixture.events.contains { $0.kind == .fromGmail })
        #expect(fixture.events.contains { $0.status == .cancelled })
        #expect(fixture.events.contains { $0.id.calendar.isHoliday })
        #expect(fixture.events.contains { $0.response == .tentative })
        let flight = try #require(fixture.events.first { $0.title == "Flight to Amsterdam (TP 674)" })
        #expect(coveredDays(flight, calendar: fixture.calendar) == CivilDate(year: 2026, month: 11, day: 5)...CivilDate(year: 2026, month: 11, day: 5))
        #expect(Formatting.authoredTime(flight, calendar: fixture.calendar) == "19:30 to 23:15 in Lisbon")
    }

    @Test func fixtureRoundTripsThroughTheSharedCoder() throws {
        let fixture = try Self.fixture()
        let data = try DayJSON.encoder().encode(fixture)
        let again = try DayJSON.decoder().decode(Fixture.self, from: data)
        #expect(again == fixture)
    }

    @Test func civilDateArithmetic() {
        let day = CivilDate(year: 2026, month: 11, day: 4)
        #expect(day.adding(days: 27) == CivilDate(year: 2026, month: 12, day: 1))
        #expect(day.adding(days: -35) == CivilDate(year: 2026, month: 9, day: 30))
        #expect(CivilDate(year: 2028, month: 2, day: 28).adding(days: 1) == CivilDate(year: 2028, month: 2, day: 29))
        #expect(CivilDate(year: 2026, month: 12, day: 31).adding(days: 1) == CivilDate(year: 2027, month: 1, day: 1))
        #expect(day.weekday == 4)
        #expect((day...day.adding(days: 6)).count == 7)
        #expect(CivilDate("2026-11-04") == day)
        #expect(CivilDate("2026-02-30") == nil)
        #expect(day.isoString == "2026-11-04")
    }

    /// A day is the same day in every zone; only the instant it starts at moves.
    @Test(arguments: ["Asia/Kolkata", "America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Pago_Pago"])
    func civilDateRoundTripsInEveryZone(_ zone: String) throws {
        let tz = try #require(TimeZone(identifier: zone))
        let day = CivilDate(year: 2026, month: 3, day: 29)
        let start = day.date(in: tz)
        #expect(CivilDate(start, in: tz) == day)
        #expect(CivilDate(start.addingTimeInterval(-1), in: tz) == day.adding(days: -1))
    }

    @Test func civilDateEncodesAsAString() throws {
        let data = try DayJSON.encoder().encode([CivilDate(year: 2026, month: 11, day: 4)])
        #expect(String(decoding: data, as: UTF8.self) == #"["2026-11-04"]"#)
    }

    @Test(arguments: [
        ("#D50000", ColorKey.red), ("#E67C73", .red), ("#F4511E", .orange), ("#F6BF26", .yellow),
        ("#33B679", .green), ("#0B8043", .green), ("#039BE5", .cyan), ("#3F51B5", .indigo),
        ("#7986CB", .indigo), ("#8E24AA", .purple), ("#616161", .gray), ("#4285F4", .blue),
        ("#795548", .brown), ("#AC725E", .brown), ("#A79B8E", .gray), ("#009688", .mint),
        ("#D81B60", .pink), ("#9E69AF", .purple),
    ])
    func googleColorsMapToSystemColors(_ hex: String, _ key: ColorKey) {
        #expect(ColorKey(hex: hex) == key)
    }

    @Test func colorKeyRejectsNonHex() {
        #expect(ColorKey(hex: "blue") == nil)
        #expect(ColorKey(hex: "#12345") == nil)
    }

    @Test func dayLinksRoundTripGoogleIDs() throws {
        let calendar = CalendarID(
            account: AccountID("100000000000000000002"),
            googleID: "en.dutch#holiday@group.v.calendar.google.com")
        let event = EventID(calendar: calendar, googleID: "a+b/c_20261104T083000Z")
        let link = DayLink.event(event)
        #expect(!link.url.absoluteString.contains("#"))
        #expect(DayLink(url: link.url) == link)

        let day = DayLink.day(CivilDate(year: 2026, month: 11, day: 4))
        #expect(day.url.absoluteString == "day://day/2026-11-04")
        #expect(DayLink(url: day.url) == day)
        #expect(DayLink(url: URL(string: "https://example.com/day/2026-11-04")!) == nil)
    }

    @Test func eventDefaultsWhenKeysAreMissing() throws {
        let json = #"""
            {"id": {"calendar": {"account": "1", "googleID": "c"}, "googleID": "e"},
             "time": {"allDay": {"start": "2026-11-04", "endExclusive": "2026-11-05"}}}
            """#
        let event = try DayJSON.decoder().decode(Event.self, from: Data(json.utf8))
        #expect(event.iCalUID == "e")
        #expect(event.kind == .default)
        #expect(event.response == .none)
        #expect(event.calendars == [event.id.calendar])
        #expect(event.isAllDay)
    }
}
