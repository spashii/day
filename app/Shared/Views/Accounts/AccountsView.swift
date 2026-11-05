import AuthenticationServices
import DayCore
import SwiftUI

/// Accounts and calendar visibility: one list for first run, the iPhone Calendars sheet and
/// the Mac Accounts tab. Accounts by address in the order added, calendars named exactly as
/// in Google with a toggle and an optional symbol, the add button, and the two lines that say
/// what Day keeps.
struct AccountsView: View {
    @EnvironmentStore private var store
    @EnvironmentSymbols private var symbols
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
                            CalendarRow(info: info)
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
                withAnimation {
                    store.removeAccount(account.id)
                    symbols.forget(account: account.id)
                }
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

/// `● Personal` with its toggle. The mark is the calendar's symbol when it has one, else its
/// color as Google resolves it, always in that color; the color itself has no picker, because
/// it is changed in Google. Tapping the name opens the symbol grid, tapping the switch
/// shows or hides the calendar.
private struct CalendarRow: View {
    @EnvironmentStore private var store
    @EnvironmentSymbols private var symbols

    let info: CalendarInfo

    @State private var choosing = false

    var body: some View {
        let symbol = symbols.symbol(for: info.id)
        HStack(spacing: Spacing.cell) {
            Button {
                choosing = true
            } label: {
                HStack(spacing: Spacing.cell) {
                    CalendarMark(symbol: symbol, color: info.markColor, dot: 10)
                        .frame(width: 20)
                    Text(verbatim: info.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: symbol?.label ?? "No symbol"))
            .accessibilityHint("Choose a symbol")
            .popover(isPresented: $choosing) {
                CalendarSymbolGrid(selection: symbol, tint: info.markColor) { chosen in
                    symbols.set(chosen, for: info.id)
                    choosing = false
                }
                // A compact popover on the iPhone, where a popover would otherwise become a
                // sheet.
                .presentationCompactAdaptation(.popover)
            }

            Toggle(
                isOn: Binding(
                    get: { store.isVisible(info.id) },
                    set: { store.setVisible($0, calendar: info.id) })
            ) {
                Text(verbatim: info.name)
            }
            .labelsHidden()
        }
    }
}

/// The mark beside a calendar's name: its symbol in the calendar's color, or the color's dot
/// when it has no symbol or this system cannot draw it. Monochrome, at the size of the text
/// beside it, and in the content layer only. Decoration: the name beside it is what VoiceOver
/// reads, and the list row also reads the symbol's name as its value.
struct CalendarMark: View {
    let symbol: CalendarSymbol?
    let color: Color
    /// The dot's diameter, which differs between the list and the event sheet.
    let dot: CGFloat

    var body: some View {
        if let symbol, symbol.isDrawable {
            Image(systemName: symbol.name)
                .symbolRenderingMode(.monochrome)
                .imageScale(.small)
                .foregroundStyle(color)
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(color)
                .frame(width: dot, height: dot)
                .accessibilityHidden(true)
        }
    }
}

/// The symbols a calendar can wear, in the calendar's color, as one compact grid in a
/// popover, and `None` to go back to the color dot. Choosing one closes the popover.
struct CalendarSymbolGrid: View {
    let selection: CalendarSymbol?
    let tint: Color
    let choose: (CalendarSymbol?) -> Void

    #if os(iOS)
        private let cell: CGFloat = 44
    #else
        private let cell: CGFloat = 32
    #endif

    /// Six to a row, so the thirty symbols are five full rows.
    private static let columns = 6

    var body: some View {
        VStack(spacing: Spacing.cell) {
            Grid(horizontalSpacing: Spacing.row, verticalSpacing: Spacing.row) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row]) { symbol in
                            symbolButton(symbol)
                        }
                    }
                }
            }
            Button {
                choose(nil)
            } label: {
                HStack(spacing: Spacing.row) {
                    Text("None")
                    if selection == nil {
                        Image(systemName: "checkmark")
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.borderless)
            .accessibilityAddTraits(selection == nil ? .isSelected : [])
        }
        .padding(Spacing.block)
    }

    /// Only what this system draws, so the grid never offers an empty cell.
    private var rows: [[CalendarSymbol]] {
        let symbols = CalendarSymbol.all.filter(\.isDrawable)
        return stride(from: 0, to: symbols.count, by: Self.columns).map {
            Array(symbols[$0..<min($0 + Self.columns, symbols.count)])
        }
    }

    private func symbolButton(_ symbol: CalendarSymbol) -> some View {
        let selected = symbol == selection
        return Button {
            choose(symbol)
        } label: {
            Image(systemName: symbol.name)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: cell, height: cell)
                .background {
                    if selected {
                        Circle().fill(Color.accentColor.opacity(0.2))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: symbol.label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The iPhone Calendars sheet, from the Month's bottom toolbar or `Choose Calendars…`. Every
/// switch and symbol applies as it is changed, so there is nothing to confirm: the sheet has
/// the system's close button, not Done.
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
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
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

#Preview("Calendars, with symbols") {
    let store = PreviewStore.make()
    let symbols = CalendarSymbols(
        Dictionary(
            uniqueKeysWithValues: store.calendars.prefix(3).enumerated().map { index, info in
                (info.id, CalendarSymbol.all[[0, 5, 28][index]])
            }))
    CalendarsSheet()
        .calendarStore(store)
        .calendarSymbols(symbols)
}

#Preview("Symbol grid") {
    CalendarSymbolGrid(selection: CalendarSymbol.named("briefcase"), tint: .blue) { _ in }
}

#Preview("Calendars, signed out") {
    let store = PreviewStore.make(state: .signedOut)
    CalendarsSheet()
        .calendarStore(store)
}
