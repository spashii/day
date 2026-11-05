import Foundation
import Testing

@testable import DayCore

/// The whole round with the relay and Google scripted (`PushNet`): register, watch, register
/// the channels, renew, stop, forget. Every account and calendar is invented.
struct PushCoordinatorTests {
    static let day: TimeInterval = 24 * 3600

    static func google(_ sent: [PushNet.Sent]) -> [PushNet.Sent] {
        sent.filter { $0.host == "www.googleapis.com" }
    }

    static func relay(_ sent: [PushNet.Sent]) -> [PushNet.Sent] {
        sent.filter { $0.host == "apps.idea2prod.in" }
    }

    @Test func theFirstRoundRegistersWatchesAndRegistersTheChannels() async throws {
        let fixture = try PushFixture()
        let next = await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        let sent = fixture.net.sent

        // POST /day/devices first, for the channel token, with no channels.
        #expect(sent.first?.host == "apps.idea2prod.in")
        #expect(sent.first?.body?["channels"] == nil)
        let install = try #require(sent.first?.body?["install"] as? String)
        #expect(install == fixture.store.existingInstall())
        let tokens = try #require(sent.first?.body?["tokens"] as? [String: Any])
        #expect(tokens["app"] as? String == PushFixture.appToken)

        // Then a watch per shown calendar and one calendar list per account, each with the
        // relay's address, the channel token and that account's own access token.
        let watches = Self.google(sent)
        #expect(watches.count == 5)
        #expect(watches.filter { $0.path.hasSuffix("/calendarList/watch") }.count == 2)
        for watch in watches {
            #expect(watch.body?["address"] as? String == "https://apps.idea2prod.in/day/push")
            #expect(watch.body?["token"] as? String == "\(install).c2lnbmVk")
            #expect(watch.body?["type"] as? String == "web_hook")
        }

        // Last, the channels with their expiries.
        let last = try #require(sent.last)
        #expect(last.host == "apps.idea2prod.in")
        let channels = try #require(last.body?["channels"] as? [[String: Any]])
        let open = await fixture.coordinator.openChannels
        #expect(Set(channels.compactMap { $0["id"] as? String }) == Set(open.map(\.id)))
        #expect(open.count == 5)

        // Renewal is due a day before the week Google granted; the relay hears from the
        // install again before that, once a day.
        let renewal = try #require(ChannelPlan.nextRenewal(of: open))
        #expect(renewal == fixture.clock.now.addingTimeInterval(PushNet.lifetime - Self.day))
        #expect(next == fixture.clock.now.addingTimeInterval(Self.day))
    }

    @Test func aSecondRoundWithNothingDueSendsNothing() async throws {
        let fixture = try PushFixture()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        fixture.net.clear()
        fixture.clock.advance(3600)
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        #expect(fixture.net.sent.isEmpty)
    }

    @Test func channelsAreRenewedADayBeforeExpiryNewFirstThenOldStopped() async throws {
        let fixture = try PushFixture()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        let before = await fixture.coordinator.openChannels
        fixture.net.clear()

        fixture.clock.advance(PushNet.lifetime - Self.day - 60)
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        // Still a minute short of the renewal; only the daily registration goes out.
        #expect(Self.google(fixture.net.sent).isEmpty)
        fixture.net.clear()

        fixture.clock.advance(60)
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        let sent = Self.google(fixture.net.sent)
        let watches = sent.filter { $0.path.hasSuffix("/watch") }
        let stops = sent.filter { $0.path.hasSuffix("/channels/stop") }
        #expect(watches.count == 5)
        #expect(Set(stops.compactMap { $0.body?["id"] as? String }) == Set(before.map(\.id)))
        // Every new channel is open before any old one is stopped.
        let lastWatch = try #require(sent.lastIndex { $0.path.hasSuffix("/watch") })
        let firstStop = try #require(sent.firstIndex { $0.path.hasSuffix("/channels/stop") })
        #expect(lastWatch < firstStop)
        let after = await fixture.coordinator.openChannels
        #expect(Set(after.map(\.id)).isDisjoint(with: before.map(\.id)))
        let registered = try #require(Self.relay(fixture.net.sent).last?.body?["channels"] as? [[String: Any]])
        #expect(Set(registered.compactMap { $0["id"] as? String }) == Set(after.map(\.id)))
    }

    @Test func aFailedRenewalKeepsTheOldChannelUntilItWorks() async throws {
        let fixture = try PushFixture()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        let before = await fixture.coordinator.openChannels
        fixture.net.answer("POST", "/events/watch") { _, _ in (503, "") }
        fixture.clock.advance(PushNet.lifetime - Self.day)
        fixture.net.clear()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        let after = await fixture.coordinator.openChannels
        // The calendar lists renewed; the event channels still deliver until their expiry.
        let kept = Set(before.filter { $0.target != .calendarList($0.target.account) })
        #expect(kept.isSubset(of: Set(after)))
        #expect(after.count == 5)
        let stopped = Self.google(fixture.net.sent).filter { $0.path.hasSuffix("/channels/stop") }
        #expect(stopped.count == 2)
    }

    @Test func aHiddenCalendarsChannelIsStopped() async throws {
        let fixture = try PushFixture()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        let holidays = try #require(
            await fixture.coordinator.openChannels.first { $0.target == .events(PushFixture.holidays.id) })
        fixture.net.clear()
        await fixture.coordinator.reconcile(PushFixture.wanted(holidays: false), tokens: PushFixture.tokens)
        let sent = fixture.net.sent
        #expect(Self.google(sent).count == 1)
        #expect(Self.google(sent).first?.body?["id"] as? String == holidays.id)
        #expect(Self.google(sent).first?.body?["resourceId"] as? String == holidays.resourceID)
        let channels = try #require(Self.relay(sent).last?.body?["channels"] as? [[String: Any]])
        #expect(channels.count == 4)
    }

    @Test func aWatchGoogleRefusesWaitsBeforeItIsTriedAgain() async throws {
        let fixture = try PushFixture()
        let holidays = "en.dutch%23holiday%40group.v.calendar.google.com/events/watch"
        fixture.net.answer("POST", holidays) { _, _ in
            (400, #"{"error":{"errors":[{"reason":"pushNotSupportedForRequestedResource"}]}}"#)
        }
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        #expect(await fixture.coordinator.openChannels.count == 4)
        fixture.net.clear()
        fixture.clock.advance(1800)
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        #expect(Self.google(fixture.net.sent).isEmpty)
        fixture.clock.advance(1800)
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        #expect(Self.google(fixture.net.sent).map(\.path).contains { $0.hasSuffix(holidays) })
    }

    @Test func theRelayBeingDownLeavesGoogleAloneAndBacksOff() async throws {
        let fixture = try PushFixture()
        fixture.net.answer("POST", "/day/devices") { _, _ in (503, #"{"error":"storage unavailable"}"#) }
        let next = await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        #expect(Self.google(fixture.net.sent).isEmpty)
        #expect(next == fixture.clock.now.addingTimeInterval(60))
        fixture.net.clear()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        #expect(fixture.net.sent.isEmpty)
    }

    @Test func aNewRelayKeyReopensEveryChannel() async throws {
        let fixture = try PushFixture()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        fixture.net.answer("POST", "/day/devices") { _, body in
            (200, #"{"channelToken":"\#(body?["install"] as? String ?? "").bmV3"}"#)
        }
        // A new push token makes the next round register, which brings the new channel token.
        await fixture.coordinator.reconcile(
            PushFixture.wanted(), tokens: .init(app: String(repeating: "c3", count: 32)))
        let open = await fixture.coordinator.openChannels
        #expect(open.count == 5)
        #expect(open.allSatisfy { $0.token.hasSuffix(".bmV3") })
    }

    @Test func noPushTokenMeansNoChannels() async throws {
        let fixture = try PushFixture()
        let next = await fixture.coordinator.reconcile(
            PushFixture.wanted(), tokens: .init(app: nil, widget: PushFixture.widgetToken))
        #expect(next == nil)
        #expect(fixture.net.sent.isEmpty)
        #expect(fixture.store.existingInstall() == nil)
    }

    @Test func removingAnAccountStopsItsChannelsWithTheTokenGiven() async throws {
        let fixture = try PushFixture()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        fixture.net.clear()
        let token = try fixture.tokens.token(for: PushFixture.home.id)
        // The sign-in code deletes the item right after; the token passed in is what counts.
        try fixture.tokens.removeToken(for: PushFixture.home.id)
        await fixture.coordinator.accountRemoved(PushFixture.home.id, token: token, lastAccount: false)
        let stops = Self.google(fixture.net.sent)
        #expect(stops.count == 2)
        #expect(stops.allSatisfy { $0.path.hasSuffix("/channels/stop") })
        let channels = try #require(Self.relay(fixture.net.sent).last?.body?["channels"] as? [[String: Any]])
        #expect(channels.count == 3)
        #expect(await fixture.coordinator.openChannels.allSatisfy { $0.target.account == PushFixture.work.id })
    }

    @Test func anAccountRemovedElsewhereIsOnlyDropped() async throws {
        let fixture = try PushFixture()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        fixture.net.clear()
        await fixture.coordinator.accountRemoved(PushFixture.home.id, token: nil, lastAccount: false)
        #expect(Self.google(fixture.net.sent).isEmpty)
        #expect(Self.relay(fixture.net.sent).count == 1)
    }

    @Test func theLastAccountGoingStopsEverythingAndForgetsTheInstall() async throws {
        let fixture = try PushFixture()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        let install = try #require(fixture.store.existingInstall())
        await fixture.coordinator.accountRemoved(
            PushFixture.home.id, token: try fixture.tokens.token(for: PushFixture.home.id),
            lastAccount: false)
        fixture.net.clear()
        await fixture.coordinator.accountRemoved(
            PushFixture.work.id, token: try fixture.tokens.token(for: PushFixture.work.id),
            lastAccount: true)
        let sent = fixture.net.sent
        #expect(Self.google(sent).count == 3)
        let delete = try #require(sent.last)
        #expect(delete.method == "DELETE")
        #expect(delete.url.absoluteString == "https://apps.idea2prod.in/day/devices/\(install)")
        // Stopped with Google before the relay forgets the install, as the README asks.
        #expect(sent.dropLast().allSatisfy { $0.host == "www.googleapis.com" })
        #expect(await fixture.coordinator.openChannels.isEmpty)
        // The install keeps its ID; a later sign-in registers it again.
        #expect(fixture.store.existingInstall() == install)
        fixture.net.clear()
        await fixture.coordinator.forget()
        #expect(fixture.net.sent.isEmpty)
    }

    @Test func noAccountFileMeansNothingIsForgotten() async throws {
        let fixture = try PushFixture()
        await fixture.coordinator.reconcile(PushFixture.wanted(), tokens: PushFixture.tokens)
        fixture.net.clear()
        // No accounts file at all, as before the first unlock: nothing is stopped.
        await fixture.coordinator.forgetIfNoAccounts()
        #expect(fixture.net.sent.isEmpty)
        #expect(await fixture.coordinator.openChannels.count == 5)
        // A readable, empty list is every account gone.
        try CacheDirectory(url: fixture.folder).write([Account](), to: CacheFile.accounts)
        await fixture.coordinator.forgetIfNoAccounts()
        #expect(fixture.net.sent.last?.method == "DELETE")
    }

    @Test func theWidgetsTokenGoesWithTheAppsOrOnItsOwn() async throws {
        let fixture = try PushFixture()
        // Before the app registered, the extension only keeps the token for it.
        await WidgetPushToken.publish(
            Data([0xb2, 0xb2]), store: fixture.store, environment: .production,
            server: PushServer(transport: fixture.net, retry: PushFixture.noWait))
        #expect(fixture.net.sent.isEmpty)
        #expect(fixture.store.widgetToken() == "b2b2")

        await fixture.coordinator.reconcile(
            PushFixture.wanted(), tokens: .init(app: PushFixture.appToken, widget: "b2b2"))
        let first = try #require(Self.relay(fixture.net.sent).first?.body?["tokens"] as? [String: Any])
        #expect(first["widget"] as? String == "b2b2")
        fixture.net.clear()

        // Once registered, the extension tells the relay itself, its own token only.
        await WidgetPushToken.publish(
            nil, store: fixture.store, environment: .production,
            server: PushServer(transport: fixture.net, retry: PushFixture.noWait))
        let body = try #require(fixture.net.sent.first?.body)
        let tokens = try #require(body["tokens"] as? [String: Any])
        #expect(tokens["app"] == nil)
        #expect(tokens["widget"] is NSNull)
        #expect(body["channels"] == nil)
    }
}
