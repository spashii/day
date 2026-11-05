import DayCore
import SwiftUI

/// The system date picker for jumping the month to any day, from `Go to Date…` in the
/// iPhone's bottom bar and the Mac's menu. The jump waits for the confirm button, because the
/// graphical picker also changes its date while the month and year wheels turn.
struct GoToDateSheet: View {
    @EnvironmentStore private var store
    @Environment(\.dismiss) private var dismiss

    /// The day the picker opens on.
    let initial: CivilDate
    let onPick: (CivilDate) -> Void

    @State private var date: Date?
    @State private var height: CGFloat = 0

    var body: some View {
        let calendar = store.calendar
        NavigationStack {
            DatePicker(
                "Go to date",
                selection: Binding(
                    get: { date ?? initial.date(in: calendar) },
                    set: { date = $0 }),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            #if os(macOS)
                // The Mac's graphical picker is small and fixed; the sheet hugs it.
                .fixedSize()
                .padding(Spacing.block)
            #else
                .scenePadding(.horizontal)
            #endif
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .navigationTitle("Go to date")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // The system's roles: a close mark and a tinted checkmark on the iPhone, Cancel
                // and a default Done that Return presses on the Mac.
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        onPick(date.map { CivilDate($0, in: calendar) } ?? initial)
                        dismiss()
                    }
                }
            }
        }
        #if os(iOS)
            // As tall as the picker and its title bar, so no half-empty sheet.
            .presentationDetents(height > 0 ? [.height(height + 72)] : [.medium])
        #else
            // The Mac's sheet otherwise takes the navigation stack's default width, about
            // three times the picker's; this is the picker with room for Cancel and Done.
            .frame(width: 260)
        #endif
    }
}

#Preview {
    let store = PreviewStore.make()
    Text(verbatim: "Month")
        .sheet(isPresented: .constant(true)) {
            GoToDateSheet(initial: store.today) { _ in }
                .calendarStore(store)
        }
        .calendarStore(store)
}
