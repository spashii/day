import AuthenticationServices
import DayCore
import SwiftUI

/// Accounts and calendar visibility: one list for first run, the iPhone Calendars sheet and
/// the Mac Accounts tab. Accounts by address in the order added, calendars named exactly as
/// in Google with a toggle, the add button, and the two lines that say what Day keeps.
struct AccountsView: View {
    @EnvironmentStore private var store
    @Environment(\.webAuthenticationSession) private var session

    /// `Add Google Account…`, or `Add Another Account…` in the first-run flow.
    var addTitle: LocalizedStringKey = "Add Google Account…"

    @State private var removing: Account?
    @State private var failure: String?
    @State private var busy = false

    var body: some View {
        Form {
            ForEach(store.accounts) { account in
                Section {
                    accountRow(account)
                    if account.signedOut {
                        Button("Sign In Again…") {
                            signIn { try await store.signInAgain(account.id, using: session) }
                        }
                        .disabled(busy)
                    } else {
                        ForEach(store.calendars(of: account.id)) { info in
                            calendarRow(info)
                        }
                    }
                }
            }
            Section {
                Button(addTitle) {
                    signIn { try await store.addAccount(using: session) }
                }
                .disabled(busy)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.cell) {
                    if let failure {
                        Text(verbatim: failure)
                    }
                    if !store.accounts.isEmpty {
                        Text("Hidden calendars stay in Google.")
                    }
                    Text(privacy)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            removing?.email ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { account in
            Button("Remove", role: .destructive) {
                withAnimation { store.removeAccount(account.id) }
            }
        } message: { _ in
            Text("Its calendars disappear from Day. Nothing changes in Google.")
        }
    }

    /// The account's address; `Signed out` beside it when Google refused it. Removing is a
    /// swipe on the iPhone and `Remove…` on the Mac.
    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: Spacing.cell) {
            Text(verbatim: account.email)
                .fontWeight(.semibold)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if account.signedOut {
                Text("Signed out")
                    .foregroundStyle(.secondary)
            }
            #if os(macOS)
                Button("Remove…") { removing = account }
            #endif
        }
        #if os(iOS)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Remove", role: .destructive) { removing = account }
            }
        #endif
    }

    /// `● Personal` with its toggle. The mark is the calendar's color as Google resolves it;
    /// there is no color picker, because the color is changed in Google.
    private func calendarRow(_ info: CalendarInfo) -> some View {
        Toggle(
            isOn: Binding(
                get: { store.isVisible(info.id) },
                set: { store.setVisible($0, calendar: info.id) })
        ) {
            HStack(spacing: Spacing.cell) {
                Circle()
                    .fill(info.markColor)
                    .frame(width: 10, height: 10)
                Text(verbatim: info.name)
                    .lineLimit(1)
            }
        }
    }

    private var privacy: LocalizedStringKey {
        #if os(macOS)
            "Day reads your calendars from Google and keeps them on this device. It collects nothing. It also checks for updates."
        #else
            "Day reads your calendars from Google and keeps them on this device. It collects nothing."
        #endif
    }

    private func signIn(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            failure = await SignIn.run(work)
            busy = false
        }
    }
}

/// The iPhone Calendars sheet, from the Month's bottom toolbar or `Choose Calendars…`.
struct CalendarsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccountsView()
                .navigationTitle("Calendars")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

#Preview("Calendars") {
    let store = PreviewStore.make()
    CalendarsSheet()
        .calendarStore(store)
}

#Preview("Calendars, signed out") {
    let store = PreviewStore.make(state: .signedOut)
    CalendarsSheet()
        .calendarStore(store)
}
