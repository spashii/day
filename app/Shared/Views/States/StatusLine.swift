import AuthenticationServices
import DayCore
import SwiftUI

/// The lines directly under the summary that say what is wrong with the data on screen:
/// offline, Google unreachable, an account signed out. Each is a line of text where the
/// content is, never a banner, and it goes away with the next good fetch. While everything
/// is fine it draws nothing.
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

/// Runs a Google sign-in and turns its failure into the line the screen shows. Closing
/// Google's sheet is a choice, not a failure, so it shows nothing.
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
            return "Couldn't sign in to Google: \(error.localizedDescription)"
        }
    }
}
