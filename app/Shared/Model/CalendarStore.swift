import AuthenticationServices
import DayCore
import Foundation
import Observation
// WebAuthenticationSession comes from the AuthenticationServices and SwiftUI overlay.
import SwiftUI

/// Everything a view reads and every action it can take. `AppModel` is the real store over
/// Google; `FixtureStore` serves invented data to previews, screenshots and the simulator.
/// Views take `any CalendarStore` from the environment and never know which one they have.
@MainActor
protocol CalendarStore: AnyObject, Observable {
    /// In the order added.
    var accounts: [Account] { get }
    /// Every account's calendars, accounts in order and each account's calendars in
    /// Google's order. A calendar shared into two accounts appears once.
    var calendars: [CalendarInfo] { get }
    /// What the screen says about fetching (section 11 of the brief).
    var status: StoreStatus { get }
    /// When Google last answered. `Offline. Showing events as of 9:40.` reads it.
    var lastFetchedAt: Date? { get }
    /// The clock every rule runs on. `AppModel` advances it each minute; `FixtureStore`
    /// holds it where `-Now` put it, so screenshots repeat exactly.
    var now: Date { get }
    /// The calendar, zone and locale every rule and formatter uses. Views pass it to the
    /// rules and set it as the `calendar` and `timeZone` environment.
    var calendar: Calendar { get }

    /// Merged events from visible calendars whose time overlaps any of `days` in
    /// `calendar`'s zone, sorted by start. A superset: an event ending at 00:15 is returned
    /// for both days, and the rules decide where it draws. Reads the cache; never waits on
    /// the network.
    func events(in days: ClosedRange<CivilDate>) -> [Event]
    /// Shown in Day. Starts from Google's `selected` flag; the person's toggle wins after.
    func isVisible(_ calendar: CalendarID) -> Bool
    func setVisible(_ visible: Bool, calendar: CalendarID)

    /// Fetches every visible calendar again. Pull to refresh and Command-R await it.
    func refresh() async
    /// Runs Google's sign-in in `session` (the view's `webAuthenticationSession`) and adds
    /// the account. Throws `CancellationError` when the person closes the sheet.
    func addAccount(using session: WebAuthenticationSession) async throws
    /// Signs a signed-out account in again, with its email as the login hint.
    func signInAgain(_ account: AccountID, using session: WebAuthenticationSession) async throws
    /// Forgets the account here. Nothing changes in Google.
    func removeAccount(_ account: AccountID)
}

/// The fetching state the screen reports, one line above the day's events. Signed-out accounts,
/// no accounts and all calendars hidden are read from `accounts` and visibility instead,
/// because they can hold at the same time as any of these.
enum StoreStatus: Hashable, Sendable {
    /// Nothing to say: cached or fresh data on screen.
    case current
    /// First fetch with nothing cached: the day reads `Loading…`. Once per install.
    case loading
    /// `Offline. Showing events as of 9:40.`
    case offline
    /// `Couldn't reach Google. Showing events as of 9:40.`
    case unreachable
}

extension CalendarStore {
    var today: CivilDate {
        CivilDate(now, in: calendar)
    }

    func account(_ id: AccountID) -> Account? {
        accounts.first { $0.id == id }
    }

    func calendarInfo(_ id: CalendarID) -> CalendarInfo? {
        calendars.first { $0.id == id }
    }

    func calendars(of account: AccountID) -> [CalendarInfo] {
        calendars.filter { $0.id.account == account }
    }

    var signedOutAccounts: [Account] {
        accounts.filter(\.signedOut)
    }

    /// No account, or every account signed out: the first-run screen.
    var needsFirstRun: Bool {
        accounts.allSatisfy(\.signedOut)
    }

    /// `No calendars shown.` with `Choose Calendars…`.
    var allCalendarsHidden: Bool {
        !accounts.isEmpty && !calendars.contains { isVisible($0.id) }
    }

    /// The merged events the Day's rows for one day are built from: that day and the next.
    func dayEvents(_ day: CivilDate) -> [Event] {
        events(in: day...day.adding(days: 1))
    }

    /// The month mark for an event, with its own account and calendar looked up.
    func monthMark(_ event: Event) -> MonthMark {
        guard let account = account(event.account), let info = calendarInfo(event.id.calendar)
        else { return .hidden }
        return DayCore.monthMark(event, account: account, calendar: info, in: calendar)
    }
}
