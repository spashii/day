import AuthenticationServices
import DayCore
import SwiftUI

/// What Day says on first run, in one place so the iPhone screen and the Mac window say the
/// same words. The caller sets the font and the alignment.
struct FirstRunLine: View {
    var body: some View {
        Text("All your Google calendars as one. Edits open in Google Calendar.")
    }
}

/// The one button that starts first run, the note under it and the line a failed sign-in
/// leaves there. The same words on the iPhone and the Mac.
struct FirstRunSignIn: View {
    @EnvironmentStore private var store
    @Environment(\.webAuthenticationSession) private var session

    /// Centered for the Mac window's single column, leading for the iPhone screen.
    var centered = false

    @State private var failure: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: Spacing.cell) {
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
            Text("Google will warn that Day isn't verified yet. Continue past it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let failure {
                Text(verbatim: failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
    }
}

#if os(iOS)
    /// The iPhone's first-run screen: what Day does and the one button that starts it. After
    /// the first account it becomes the accounts list with `Add Another Account…` and
    /// `Done`, and Done lands on today. When every account is signed out it lists them with
    /// `Sign In Again…` beside each. The Mac has its own small window (`FirstRunWindow`).
    struct FirstRunView: View {
        @EnvironmentStore private var store

        /// Leaves first run for today.
        let onDone: () -> Void

        var body: some View {
            NavigationStack {
                Group {
                    if store.accounts.isEmpty {
                        intro
                    } else {
                        AccountsView(addTitle: "Add Another Account…")
                            .toolbar {
                                // Done finishes first run and lands on today, so it is the
                                // sheet's confirm action, tinted.
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done", role: .confirm, action: onDone)
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
                    FirstRunLine()
                        .font(.title3)
                    FirstRunSignIn()
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
#endif
