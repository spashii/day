import DayCore
import SwiftUI

/// The system date picker for jumping the month to any day: the iPhone opens it from the
/// month title, the Mac from `Go to Date…`. The jump waits for Done, because the graphical
/// picker also changes its date while the month and year wheels turn.
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
            .scenePadding(.horizontal)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .navigationTitle("Go to date")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
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
            .frame(minWidth: 320)
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
