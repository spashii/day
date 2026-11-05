import AppKit
import DayCore
import SwiftUI

/// The Mac's first-run window: small, fixed in size, one centered column. Day's icon, its name,
/// what it does, the one button that starts it, the note about Google's warning, and `Open at
/// login` under it, so the choice is offered once and never made silently. System fonts and
/// native spacing, and nothing drawn behind them.
///
/// It stands in for the whole window until an account exists, and the window moves to the
/// Month the moment the first one is added (`MainWindow`). When every account is signed out
/// the same window lists them with `Sign In Again…`.
struct FirstRunWindow: View {
    @EnvironmentStore private var store

    let login: OpenAtLogin

    /// The window's size in points. It cannot be resized.
    static let size = CGSize(width: 420, height: 360)

    var body: some View {
        Group {
            if store.accounts.isEmpty {
                welcome
            } else {
                // The same add button as Settings: `Add Another Account…` belongs to the
                // iPhone's first run, which has a Done step the Mac does not.
                AccountsView()
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var welcome: some View {
        VStack(spacing: Spacing.block) {
            VStack(spacing: Spacing.cell) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Day")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }
            FirstRunLine()
                .font(.title3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            FirstRunSignIn(centered: true)
            Toggle(
                "Open at login",
                isOn: Binding(get: { login.isOn }, set: { login.set($0) })
            )
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.block)
    }
}

#Preview("First run") {
    let store = PreviewStore.make(state: .noAccount)
    FirstRunWindow(login: OpenAtLogin())
        .calendarStore(store)
}

#Preview("Every account signed out") {
    let store = PreviewStore.make(state: .allSignedOut)
    FirstRunWindow(login: OpenAtLogin())
        .calendarStore(store)
}
