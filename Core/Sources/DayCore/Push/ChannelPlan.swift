import Foundation

/// What one reconcile does with Google's channels: which targets to watch, which channels a
/// new one replaces, and which to stop. Pure, so the renewal timing is tested on its own.
///
/// A channel is renewed a day before Google's expiry, or halfway through its life when Google
/// grants less than two days, so a short grant is never renewed on every check. A renewal
/// opens the new channel first and stops the old one only once the new one is open; until
/// then both deliver, and the relay folds the two notifications into one push.
public struct ChannelPlan: Hashable, Sendable {
    /// Targets to open a channel on: never watched, or their channel is due.
    public var watch: [WatchTarget]
    /// Channels that go once their target's new channel is open.
    public var replacing: [WatchTarget: WatchedChannel]
    /// Channels nothing needs any more (a calendar hidden, an account signed out or removed,
    /// a second channel on one target), stopped with Google and dropped.
    public var stop: [WatchedChannel]
    /// Channels past their expiry: Google has closed them already, so they are only dropped.
    public var expired: [WatchedChannel]

    public static let renewBefore: TimeInterval = 24 * 3600

    public var isEmpty: Bool {
        watch.isEmpty && stop.isEmpty && expired.isEmpty
    }

    /// When `channel` should be replaced.
    public static func renewal(of channel: WatchedChannel) -> Date {
        let life = channel.expiration.timeIntervalSince(channel.created)
        let lead = min(renewBefore, max(0, life) / 2)
        return channel.expiration.addingTimeInterval(-lead)
    }

    /// The plan for `wanted` given the channels open now. `token` is the relay's current
    /// channel token; a channel opened with another is due at once. Targets in `waiting` had
    /// a recent failure and are left for later.
    public static func make(
        wanted: WatchSet, channels: [WatchedChannel], token: String, now: Date,
        waiting: Set<WatchTarget> = []
    ) -> ChannelPlan {
        var plan = ChannelPlan(watch: [], replacing: [:], stop: [], expired: [])
        var byTarget: [WatchTarget: [WatchedChannel]] = [:]
        for channel in channels {
            if channel.expiration <= now {
                plan.expired.append(channel)
            } else {
                byTarget[channel.target, default: []].append(channel)
            }
        }
        for (target, open) in byTarget {
            let newest = open.max { $0.expiration < $1.expiration }!
            plan.stop += open.filter { $0 != newest }
            guard wanted.targets.contains(target) || wanted.keepsBlind(target) else {
                plan.stop.append(newest)
                continue
            }
            if newest.token != token || renewal(of: newest) <= now {
                plan.replacing[target] = newest
            }
        }
        let open = Set(byTarget.keys)
        let missing = wanted.targets.filter { !open.contains($0) }
        let renewing = plan.replacing.keys
        plan.watch = (Array(missing) + Array(renewing))
            .filter { !waiting.contains($0) }
            .sorted(by: Self.order)
        plan.stop.sort { $0.id < $1.id }
        plan.expired.sort { $0.id < $1.id }
        return plan
    }

    /// The next time a check has something to do for `channels`: the earliest renewal.
    public static func nextRenewal(of channels: [WatchedChannel]) -> Date? {
        channels.map(renewal(of:)).min()
    }

    /// A stable order, so requests and tests do not depend on hashing.
    static func order(_ a: WatchTarget, _ b: WatchTarget) -> Bool {
        key(a) < key(b)
    }

    private static func key(_ target: WatchTarget) -> String {
        switch target {
        case .calendarList(let account): "0 \(account.sub)"
        case .events(let calendar): "1 \(calendar.account.sub) \(calendar.googleID)"
        }
    }
}
