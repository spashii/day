import AuthenticationServices
import DayCore
import SwiftUI

/// What a day says before its events, when it has something to say: `Loading…` the first
/// time, `No calendars shown.` when every calendar is hidden, `Nothing scheduled.` for a day
/// with no events at all (an all-day line is an event), then the status lines. Each is a line of text where the content would be,
/// never a banner. While everything is fine it draws nothing, so the day starts with its
/// events.
struct DayStateLines: View {
    @EnvironmentStore private var store
    @Environment(\.chooseCalendars) private var chooseCalendars

    /// The day has no rows at all: no all-day line, no event.
    let isEmpty: Bool

    /// Whether `body` draws anything. The list adds a row for it only then, because a row
    /// with nothing in it would still take its height and its separator.
    static func isShown(in store: any CalendarStore, isEmpty: Bool) -> Bool {
        store.allCalendarsHidden || store.status != .current || isEmpty
            || !store.signedOutAccounts.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cell) {
            if store.allCalendarsHidden {
                Text("No calendars shown.")
                    .foregroundStyle(.secondary)
                if let chooseCalendars {
                    Button("Choose Calendars…") { chooseCalendars() }
                        .buttonStyle(.borderless)
                }
            } else if store.status == .loading {
                Text("Loading…")
                    .foregroundStyle(.secondary)
            } else if isEmpty {
                Text("Nothing scheduled.")
                    .foregroundStyle(.secondary)
            }
            StatusLines()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `Nothing else today.` under the rows of a day whose last event has ended, with or without
/// an all-day line above the Earlier row. The list shows it only for `DayEnding.nothingElse`.
struct DayEndingLine: View {
    var body: some View {
        Text("Nothing else today.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The lines that say what is wrong with the data on screen: offline, Google unreachable, an
/// account signed out. Each is a line of text where the content is, never a banner, and it
/// goes away with the next good fetch. While everything is fine it draws nothing.
struct StatusLines: View {
    @EnvironmentStore private var store
    @Environment(\.webAuthenticationSession) private var session
    @State private var failure: String?

    var body: some View {
        let signedOut = store.signedOutAccounts
        if fetchLine != nil || !signedOut.isEmpty || failure != nil {
            VStack(alignment: .leading, spacing: Spacing.row) {
                if let fetchLine {
                    Text(verbatim: fetchLine)
                        .foregroundStyle(.secondary)
                }
                ForEach(signedOut) { account in
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.cell) {
                            signedOutText(account)
                            signInButton(account)
                        }
                        VStack(alignment: .leading, spacing: Spacing.row) {
                            signedOutText(account)
                            signInButton(account)
                        }
                    }
                }
                if let failure {
                    Text(verbatim: failure)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `Offline. Showing events as of 9:40.` or
    /// `Couldn't reach Google. Showing events as of 9:40.`
    private var fetchLine: String? {
        let asOf = store.lastFetchedAt.map {
            " Showing events as of \(Formatting.time($0, calendar: store.calendar))."
        } ?? ""
        switch store.status {
        case .offline: return "Offline." + asOf
        case .unreachable: return "Couldn't reach Google." + asOf
        case .current, .loading: return nil
        }
    }

    private func signedOutText(_ account: Account) -> some View {
        Text("Google signed out \(account.email).")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func signInButton(_ account: Account) -> some View {
        Button("Sign In Again…") {
            Task {
                failure = await SignIn.run {
                    try await store.signInAgain(account.id, using: session)
                }
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

/// Runs a Google sign-in and turns its failure into the line the screen shows, which is the
/// failure's own description: the stores word it in plain words (`SignInFailure`, the keychain
/// failure) and keep every status and code in the log. Closing Google's sheet is a choice,
/// not a failure, so it shows nothing.
@MainActor
enum SignIn {
    static func run(_ work: @MainActor () async throws -> Void) async -> String? {
        do {
            try await work()
            return nil
        } catch is CancellationError {
            return nil
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        } catch {
            // Only a store's own words reach the screen. Anything else is not worded for a
            // person and may carry a code.
            return (error as? any LocalizedError)?.errorDescription ?? SignInFailure.unfinished
        }
    }
}
