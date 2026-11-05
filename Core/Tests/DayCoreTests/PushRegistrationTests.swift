import Foundation
import Testing

@testable import DayCore

/// What goes over the wire, checked against `push/README.md` and the relay's own validation
/// in `push/src/index.js`: the registration body, the watch and stop requests, and that
/// nothing naming a calendar or an account reaches the relay.
struct PushRegistrationTests {
    static let install = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"

    static func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theReadmeExampleEncodesAsWritten() throws {
        let channel = WatchedChannel(
            id: "chan-1", resourceID: "resource-1", target: .calendarList(AccountID("1001")),
            token: "t", created: .distantPast, expirationMillis: 1_731_405_600_000)
        let body = try Self.json(
            PushRegistration(
                install: Self.install, platform: .ios, environment: .production,
                app: .set("ab12"), widget: .set("cd34"), channels: [channel]))
        #expect(Set(body.keys) == ["install", "platform", "environment", "tokens", "channels"])
        #expect(body["install"] as? String == Self.install)
        #expect(body["platform"] as? String == "ios")
        #expect(body["environment"] as? String == "production")
        let tokens = try #require(body["tokens"] as? [String: Any])
        #expect(tokens["app"] as? String == "ab12")
        #expect(tokens["widget"] as? String == "cd34")
        let channels = try #require(body["channels"] as? [[String: Any]])
        #expect(channels.count == 1)
        #expect(Set(channels[0].keys) == ["id", "expiration"])
        #expect(channels[0]["id"] as? String == "chan-1")
        // Google's milliseconds, as a string, exactly as the watch answer gave them.
        #expect(channels[0]["expiration"] as? String == "1731405600000")
    }

    @Test func aTokenIsSetClearedOrLeftOut() throws {
        let body = try Self.json(
            PushRegistration(
                install: Self.install, platform: .ios, environment: .sandbox, app: .keep,
                widget: .clear))
        let tokens = try #require(body["tokens"] as? [String: Any])
        // Left out: the relay keeps its copy. Null: the relay clears it.
        #expect(tokens["app"] == nil)
        #expect(tokens["widget"] is NSNull)
        // No channels key leaves the relay's set alone; an empty list empties it.
        #expect(body["channels"] == nil)
        let emptied = try Self.json(
            PushRegistration(install: Self.install, platform: .macos, environment: .production, channels: []))
        #expect((emptied["channels"] as? [Any])?.isEmpty == true)
        #expect(emptied["platform"] as? String == "macos")
    }

    @Test func neverMoreChannelsThanTheRelayTakes() throws {
        let many = (0..<350).map {
            WatchedChannel(
                id: "chan-\($0)", resourceID: "r", target: .calendarList(AccountID("1")), token: "t",
                created: .distantPast, expirationMillis: 1)
        }
        let body = try Self.json(
            PushRegistration(install: Self.install, platform: .ios, environment: .production, channels: many))
        #expect((body["channels"] as? [Any])?.count == PushRegistration.maxChannels)
    }

    @Test func theRelayAnswersAreRead() async throws {
        let net = PushNet(now: { Date() })
        let server = PushServer(transport: net, retry: PushFixture.noWait)
        let token = try await server.register(
            PushRegistration(install: Self.install, platform: .ios, environment: .sandbox))
        #expect(token == "\(Self.install).c2lnbmVk")
        try await server.delete(install: Self.install)
        let sent = net.sent
        #expect(sent.map(\.method) == ["POST", "DELETE"])
        #expect(sent[0].url.absoluteString == "https://apps.idea2prod.in/day/devices")
        #expect(sent[1].url.absoluteString == "https://apps.idea2prod.in/day/devices/\(Self.install)")
        #expect(server.webhook.absoluteString == "https://apps.idea2prod.in/day/push")

        net.answer("POST", "/day/devices") { _, _ in (400, #"{"error":"install must be a UUID"}"#) }
        await #expect(throws: PushServerError.rejected(status: 400, reason: "install must be a UUID")) {
            _ = try await server.register(
                PushRegistration(install: "x", platform: .ios, environment: .sandbox))
        }
        net.answer("POST", "/day/devices") { _, _ in (503, #"{"error":"storage unavailable"}"#) }
        await #expect(throws: PushServerError.unavailable(status: 503)) {
            _ = try await server.register(
                PushRegistration(install: Self.install, platform: .ios, environment: .sandbox))
        }
    }

    @Test func watchAndStopRequestsAreGooglesShape() throws {
        let watcher = WatchClient(api: CalendarAPI(transport: PushNet(now: { Date() })))
        let holidays = CalendarID(
            account: AccountID("1001"), googleID: "en.dutch#holiday@group.v.calendar.google.com")
        let address = URL(string: "https://apps.idea2prod.in/day/push")!
        let events = watcher.watchRequest(
            .events(holidays), channelID: "c-1", token: "\(Self.install).c2lnbmVk",
            address: address, accessToken: "access")
        #expect(events.httpMethod == "POST")
        #expect(
            events.url?.absoluteString
                == "https://www.googleapis.com/calendar/v3/calendars/en.dutch%23holiday%40group.v.calendar.google.com/events/watch")
        #expect(events.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        let body = try #require(
            JSONSerialization.jsonObject(with: events.httpBody ?? Data()) as? [String: String])
        #expect(
            body == [
                "id": "c-1", "type": "web_hook", "address": "https://apps.idea2prod.in/day/push",
                "token": "\(Self.install).c2lnbmVk",
            ])

        let list = watcher.watchRequest(
            .calendarList(AccountID("1001")), channelID: "c-2", token: "t", address: address,
            accessToken: "access")
        #expect(list.url?.absoluteString == "https://www.googleapis.com/calendar/v3/users/me/calendarList/watch")

        let channel = WatchedChannel(
            id: "c-1", resourceID: "resource-9", target: .events(holidays), token: "t",
            created: .distantPast, expirationMillis: 1)
        let stop = watcher.stopRequest(channel, accessToken: "access")
        #expect(stop.url?.absoluteString == "https://www.googleapis.com/calendar/v3/channels/stop")
        let stopBody = try #require(
            JSONSerialization.jsonObject(with: stop.httpBody ?? Data()) as? [String: String])
        #expect(stopBody == ["id": "c-1", "resourceId": "resource-9"])
    }

    /// The relay's own checks (`parseRegistration` in push/src/index.js), applied to what a
    /// real reconcile sends.
    @Test func whatReconcileSendsPassesTheRelaysChecks() async throws {
        let fixture = try PushFixture()
        await fixture.coordinator.reconcile(
            PushFixture.wanted(),
            tokens: .init(app: PushFixture.appToken, widget: PushFixture.widgetToken))
        let registrations = fixture.net.sent.filter { $0.host == "apps.idea2prod.in" }
        #expect(registrations.count == 2)
        let uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
        let hex = /^[0-9a-f]{32,512}$/
        let channelID = /^[A-Za-z0-9_+\/=-]{1,64}$/
        for registration in registrations {
            let body = try #require(registration.body)
            let install = try #require(body["install"] as? String)
            #expect(install.wholeMatch(of: uuid) != nil)
            #expect(["ios", "macos"].contains(body["platform"] as? String))
            #expect(["sandbox", "production"].contains(body["environment"] as? String))
            let tokens = try #require(body["tokens"] as? [String: Any])
            for value in tokens.values {
                #expect((value as? String)?.wholeMatch(of: hex) != nil)
            }
            for channel in body["channels"] as? [[String: Any]] ?? [] {
                #expect((channel["id"] as? String)?.wholeMatch(of: channelID) != nil)
                #expect(Int64(channel["expiration"] as? String ?? "") ?? 0 > 0)
            }
        }
    }

    /// The relay learns a random install, random channel IDs, expiries and Apple's tokens,
    /// and nothing that names a calendar, an account or a Google sign-in.
    @Test func nothingPrivateReachesTheRelay() async throws {
        let fixture = try PushFixture()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        fixture.clock.advance(6.5 * 24 * 3600)
        await fixture.coordinator.reconcile(PushFixture.wanted(holidays: false), tokens: PushFixture.tokens)
        await fixture.coordinator.accountRemoved(
            PushFixture.home.id, token: try fixture.tokens.token(for: PushFixture.home.id),
            lastAccount: false)
        await fixture.coordinator.accountRemoved(
            PushFixture.work.id, token: try fixture.tokens.token(for: PushFixture.work.id),
            lastAccount: true)

        let relay = fixture.net.sent.filter { $0.host == "apps.idea2prod.in" }
        #expect(relay.count >= 4)
        let secrets = [
            "you@acme.com", "you@gmail.com", "holiday", "117000000000000000001",
            "117000000000000000002", "refresh-", "access-",
            "resource-",
        ]
        for request in relay {
            for secret in secrets {
                #expect(!request.text.contains(secret), "\(secret) in \(request.method) \(request.path)")
                #expect(!request.url.absoluteString.contains(secret))
            }
        }
    }

    @Test func theEnvironmentFollowsTheProfile() {
        func profile(_ value: String) -> Data {
            Data("signed-bytes<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Entitlements</key><dict><key>aps-environment</key><string>\(value)</string></dict></dict></plist>more-signed-bytes".utf8)
        }
        #expect(PushEnvironment.apsEnvironment(inProfile: profile("development")) == "development")
        #expect(PushEnvironment.apsEnvironment(inProfile: profile("production")) == "production")
        #expect(PushEnvironment.apsEnvironment(inProfile: Data("no plist".utf8)) == nil)
    }

    @Test func theInstallIsMadeOnceAndStaysPrivate() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "day-install-\(UUID().uuidString)")
        let store = PushStore(directory: CacheDirectory(url: folder))
        #expect(store.existingInstall() == nil)
        let first = try store.install()
        #expect(first == first.lowercased())
        #expect(UUID(uuidString: first) != nil)
        #expect(try store.install() == first)
        // A second process asking at the same moment reads the same ID.
        #expect(try PushStore(directory: CacheDirectory(url: folder)).install() == first)
        let values = try store.directory.fileURL(PushStore.installFile)
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
