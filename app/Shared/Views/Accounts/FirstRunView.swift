import AuthenticationServices
import DayCore
import SwiftUI

/// The first-run screen, on both platforms: what Day does and the one button that starts
/// it. After the first account it becomes the accounts list with `Add Another Account…` and
/// `Done`, and Done lands on today. When every account is signed out it lists them with
/// `Sign In Again…` beside each.
struct FirstRunView: View {
    @EnvironmentStore private var store
    @Environment(\.webAuthenticationSession) private var session

    /// Leaves first run for today.
    let onDone: () -> Void

    @State private var failure: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Group {
                if store.accounts.isEmpty {
                    intro
                } else {
                    AccountsView(addTitle: "Add Another Account…")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", action: onDone)
                                    .disabled(store.needsFirstRun)
                            }
                        }
                }
            }
            .navigationTitle("Day")
        }
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Shows your Google calendars.")
                    Text("Edits open in Google Calendar.")
                }
                .font(.title3)
                VStack(alignment: .leading, spacing: Spacing.cell) {
                    Button("Add Google Account…") {
                        busy = true
                        Task {
                            failure = await SignIn.run {
                                try await store.addAccount(using: session)
                            }
                            busy = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(busy)
                    Text("Google will flag it as unverified.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let failure {
                        Text(verbatim: failure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scenePadding()
        }
    }
}

#Preview("First run") {
    let store = PreviewStore.make(state: .noAccount)
    FirstRunView {}
        .calendarStore(store)
}

#Preview("Every account signed out") {
    let store = PreviewStore.make(state: .allSignedOut)
    FirstRunView {}
        .calendarStore(store)
}
