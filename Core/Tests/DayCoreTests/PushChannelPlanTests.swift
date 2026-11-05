import Foundation
import Testing

@testable import DayCore

/// When channels are renewed, replaced and stopped (`ChannelPlan`).
struct PushChannelPlanTests {
    static let start = Date(timeIntervalSince1970: 1_793_800_000)
    static let day: TimeInterval = 24 * 3600
    static let token = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b.c2lnbmVk"

    static func channel(
        _ target: WatchTarget, id: String = UUID().uuidString.lowercased(),
        created: Date = start, life: TimeInterval = 7 * day, token: String = token
    ) -> WatchedChannel {
        WatchedChannel(
            id: id, resourceID: "resource-\(id)", target: target, token: token, created: created,
            expirationMillis: Int64((created.timeIntervalSince1970 + life) * 1000))
    }

    static let work = PushFixture.work
    static let primary = WatchTarget.events(PushFixture.workPrimary.id)
    static let list = WatchTarget.calendarList(PushFixture.work.id)
    static let wanted = WatchSet(targets: [primary, list])

    @Test func aWeekLongChannelIsRenewedADayBeforeItExpires() {
        let open = Self.channel(Self.primary)
        #expect(ChannelPlan.renewal(of: open) == open.expiration.addingTimeInterval(-Self.day))

        let channels = [open, Self.channel(Self.list)]
        let early = ChannelPlan.make(
            wanted: Self.wanted, channels: channels, token: Self.token,
            now: open.expiration.addingTimeInterval(-Self.day - 1))
        #expect(early.isEmpty)

        let due = ChannelPlan.make(
            wanted: Self.wanted, channels: channels, token: Self.token,
            now: open.expiration.addingTimeInterval(-Self.day))
        #expect(due.watch == [Self.list, Self.primary].sorted(by: ChannelPlan.order))
        #expect(due.replacing[Self.primary] == open)
        // The old one is stopped only once its replacement is open, so it is not in `stop`.
        #expect(due.stop.isEmpty)
    }

    @Test func aShortGrantIsRenewedHalfwaySoItIsNotRenewedOnEveryCheck() {
        let short = Self.channel(Self.primary, life: 3600)
        #expect(ChannelPlan.renewal(of: short) == Self.start.addingTimeInterval(1800))
        let plan = ChannelPlan.make(
            wanted: WatchSet(targets: [Self.primary]), channels: [short], token: Self.token,
            now: Self.start.addingTimeInterval(60))
        #expect(plan.isEmpty)
    }

    @Test func aLapsedChannelIsDroppedAndWatchedAgain() {
        let lapsed = Self.channel(Self.primary, created: Self.start.addingTimeInterval(-8 * Self.day))
        let plan = ChannelPlan.make(
            wanted: WatchSet(targets: [Self.primary]), channels: [lapsed], token: Self.token,
            now: Self.start)
        #expect(plan.expired == [lapsed])
        #expect(plan.watch == [Self.primary])
        #expect(plan.stop.isEmpty)
    }

    @Test func aChannelFromAnOlderRelayKeyIsOpenedAgainAtOnce() {
        let old = Self.channel(Self.primary, token: "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b.b2xk")
        let plan = ChannelPlan.make(
            wanted: WatchSet(targets: [Self.primary]), channels: [old], token: Self.token,
            now: Self.start)
        #expect(plan.watch == [Self.primary])
        #expect(plan.replacing[Self.primary] == old)
    }

    @Test func channelsNobodyWantsAreStoppedAndADuplicateKeepsTheNewest() {
        let hidden = WatchTarget.events(PushFixture.holidays.id)
        let older = Self.channel(Self.primary, life: 5 * Self.day)
        let newer = Self.channel(Self.primary, life: 6 * Self.day)
        let gone = Self.channel(hidden)
        let plan = ChannelPlan.make(
            wanted: WatchSet(targets: [Self.primary]), channels: [older, newer, gone],
            token: Self.token, now: Self.start)
        #expect(Set(plan.stop) == [older, gone])
        #expect(plan.watch.isEmpty)
    }

    @Test func eventChannelsOfAnAccountWithUnreadableCalendarsAreKept() {
        // The calendar list could not be read on this run: the account is signed in but no
        // calendar of it is known, so its event channels stay, and only the list is wanted.
        let open = Self.channel(Self.primary)
        let blind = WatchSet(accounts: [PushFixture.work], calendars: []) { _ in true }
        #expect(blind.unknownCalendars == [PushFixture.work.id])
        let plan = ChannelPlan.make(
            wanted: blind, channels: [open, Self.channel(Self.list)], token: Self.token,
            now: Self.start)
        #expect(plan.isEmpty)
    }

    @Test func aSignedOutAccountWantsNoChannels() {
        var signedOut = PushFixture.work
        signedOut.signedOut = true
        let wanted = WatchSet(accounts: [signedOut], calendars: [PushFixture.workPrimary]) { _ in true }
        #expect(wanted.targets.isEmpty)
        #expect(wanted.unknownCalendars.isEmpty)
    }

    @Test func aTargetThatFailedWaitsItsTurn() {
        let plan = ChannelPlan.make(
            wanted: Self.wanted, channels: [], token: Self.token, now: Self.start,
            waiting: [Self.primary])
        #expect(plan.watch == [Self.list])
    }

    @Test func theNextCheckIsTheEarliestRenewal() {
        let soon = Self.channel(Self.primary, life: 2 * Self.day)
        let later = Self.channel(Self.list)
        #expect(ChannelPlan.nextRenewal(of: [later, soon]) == Self.start.addingTimeInterval(Self.day))
        #expect(ChannelPlan.nextRenewal(of: []) == nil)
    }

    @Test func theWatchSetFollowsWhatIsShown() {
        let wanted = PushFixture.wanted(holidays: false)
        #expect(
            wanted.targets == [
                .calendarList(PushFixture.work.id), .calendarList(PushFixture.home.id),
                .events(PushFixture.workPrimary.id), .events(PushFixture.homePrimary.id),
            ])
    }
}
