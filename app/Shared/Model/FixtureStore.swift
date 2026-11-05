import AuthenticationServices
import DayCore
import Foundation
import Observation
// WebAuthenticationSession comes from the AuthenticationServices and SwiftUI overlay.
import SwiftUI

/// A `CalendarStore` over an invented fixture, for previews, screenshots and the simulator.
/// No real calendar data may appear in either, and no Google client exists until the OAuth
/// client is made, so this is also what the apps run on while `GoogleClientID` holds the
/// placeholder.
///
/// Launch arguments, read through `UserDefaults`:
/// - `-UseFixtures invented-week` runs on `invented-week.json` from the app bundle.
/// - `-Now 2026-11-04T12:10` fixes the clock, in the fixture's zone (a full ISO 8601 date
///   with offset also works). Without it the clock is the fixture's own `now`.
/// - `-FixtureState offline` shows one of the states in `FixtureStore.State`.
@MainActor
@Observable
final class FixtureStore: CalendarStore {
    /// The states a screenshot can ask for.
    enum State: String, CaseIterable, Sendable {
        /// Everything fetched, nothing to say.
        case normal
        /// First fetch with nothing cached: no events, `Loading…`.
        case loading
        /// `Offline. Showing events as of 9:40.`
        case offline
        /// `Couldn't reach Google. Showing events as of 9:40.`
        case unreachable
        /// The work account needs signing in again; its events stay on screen.
        case signedOut
        /// Every account signed out: the first-run screen with `Sign In Again…`.
        case allSignedOut
        /// No account added: the first-run screen.
        case noAccount
        /// Every calendar hidden: `No calendars shown.`
        case noCalendars
    }

    private(set) var accounts: [Account]
    private(set) var calendars: [CalendarInfo]
    private(set) var status: StoreStatus
    private(set) var lastFetchedAt: Date?
    var now: Date
    let calendar: Calendar

    private let fixture: Fixture
    private var visibility: [CalendarID: Bool] = [:]

    init(fixture: Fixture, now: Date? = nil, state: State = .normal) {
        self.fixture = fixture
        self.now = now ?? fixture.now
        calendar = fixture.calendar
        accounts = fixture.accounts
        calendars = fixture.calendars
        status = .current
        lastFetchedAt = fixture.fetchedAt

        switch state {
        case .normal:
            break
        case .loading:
            status = .loading
            lastFetchedAt = nil
        case .offline, .unreachable:
            status = state == .offline ? .offline : .unreachable
            // Two and a half hours stale, which reads `as of 9:40` at the fixture's 12:10.
            lastFetchedAt = self.now.addingTimeInterval(-150 * 60)
        case .signedOut:
            if let last = accounts.indices.last { accounts[last].signedOut = true }
        case .allSignedOut:
            for i in accounts.indices { accounts[i].signedOut = true }
        case .noAccount:
            accounts = []
            calendars = []
            lastFetchedAt = nil
        case .noCalendars:
            for info in calendars { visibility[info.id] = false }
        }
    }

    /// Loads `<name>.json` from `bundle`. app/project.yml copies `invented-week.json` into
    /// both apps and the widget.
    convenience init(
        named name: String = "invented-week", bundle: Bundle = .main, now: Date? = nil,
        state: State = .normal
    ) {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            preconditionFailure("\(name).json is not in the bundle; app/project.yml copies it in")
        }
        do {
            self.init(fixture: try Fixture.load(from: url), now: now, state: state)
        } catch {
            preconditionFailure("\(name).json does not decode: \(error)")
        }
    }

    /// The store the launch arguments ask for: a fixture when `-UseFixtures` is given or no
    /// Google client is configured, otherwise nil and the app builds its real store.
    static func fromLaunchArguments(
        _ defaults: UserDefaults = .standard, bundle: Bundle = .main
    ) -> FixtureStore? {
        let clientID =
            bundle.object(forInfoDictionaryKey: DayIdentifiers.googleClientIDKey) as? String
        let noClient = clientID == nil || clientID == DayIdentifiers.googleClientPlaceholder
        let name = defaults.string(forKey: "UseFixtures")
        guard name != nil || noClient else { return nil }

        let store = FixtureStore(
            named: name ?? "invented-week", bundle: bundle,
            state: defaults.string(forKey: "FixtureState").flatMap(State.init) ?? .normal)
        if let text = defaults.string(forKey: "Now"),
            let now = parseNow(text, calendar: store.calendar)
        {
            store.now = now
        }
        return store
    }

    /// `2026-11-04T12:10` in the fixture's zone, or ISO 8601 with an offset.
    static func parseNow(_ text: String, calendar: Calendar) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) {
            return date
        }
        let parts = text.split(separator: "T")
        guard parts.count == 2, let day = CivilDate(String(parts[0])) else { return nil }
        let clock = parts[1].split(separator: ":").compactMap { Int($0) }
        guard clock.count >= 2 else { return nil }
        return calendar.date(
            from: DateComponents(
                year: day.year, month: day.month, day: day.day, hour: clock[0],
                minute: clock[1], second: clock.count > 2 ? clock[2] : 0))
    }

    func events(in days: ClosedRange<CivilDate>) -> [Event] {
        guard status != .loading else { return [] }
        let from = days.lowerBound.date(in: calendar)
        let to = days.upperBound.adding(days: 1).date(in: calendar)
        let order = Dictionary(
            uniqueKeysWithValues: accounts.enumerated().map { ($0.element.id, $0.offset) })
        let visible = fixture.events
            .filter { order[$0.account] != nil && isVisible($0.id.calendar) }
            .enumerated()
            .sorted { (order[$0.element.account]!, $0.offset) < (order[$1.element.account]!, $1.offset) }
            .map(\.element)
        return merged(visible)
            .filter { event in
                let interval = event.time.interval(in: calendar)
                return interval.start < to && (interval.end > from || interval.start >= from)
            }
            .sorted { $0.time.start(in: calendar) < $1.time.start(in: calendar) }
    }

    func isVisible(_ id: CalendarID) -> Bool {
        visibility[id] ?? calendarInfo(id)?.selected ?? false
    }

    func setVisible(_ visible: Bool, calendar id: CalendarID) {
        visibility[id] = visible
    }

    func refresh() async {
        // Invented data never changes; the brief pause lets pull to refresh show its spinner.
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Adds back the first fixture account not on the list, so the first-run flow can be
    /// walked through in the simulator.
    func addAccount(using session: WebAuthenticationSession) async throws {
        guard let next = fixture.accounts.first(where: { account($0.id) == nil }) else { return }
        accounts.append(next)
        accounts.sort { $0.addedAt < $1.addedAt }
        calendars = fixture.calendars.filter { info in accounts.contains { $0.id == info.id.account } }
        if status == .loading || lastFetchedAt == nil {
            status = .current
            lastFetchedAt = now
        }
    }

    func signInAgain(_ id: AccountID, using session: WebAuthenticationSession) async throws {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].signedOut = false
    }

    func removeAccount(_ id: AccountID) {
        accounts.removeAll { $0.id == id }
        calendars.removeAll { $0.id.account == id }
    }
}
