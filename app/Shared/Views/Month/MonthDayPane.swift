import DayCore
import SwiftUI

/// The selected day under the iPhone's month grid: a date line that opens the full Day, then
/// the same `DayList` the Day draws, with its all-day lines, Earlier row, now line, rows and
/// Join. So the month answers "what does this day look like" without a navigation,
/// and the Day is one tap further.
struct MonthDayPane: View {
    @EnvironmentStore private var store

    let day: CivilDate
    /// A tap on the date line: the full Day.
    let onOpen: () -> Void

    var body: some View {
        DayList(day: day)
            // The date line stays put while the rows scroll under it. The hard edge, not a
            // background of its own, keeps the two apart: it is the system's treatment for a
            // pinned header over a list.
            .safeAreaBar(edge: .top, spacing: 0) {
                dateLine
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .refreshable { await store.refresh() }
    }

    /// `Wednesday 4 November` with a chevron, the row's whole width a button.
    private var dateLine: some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.row) {
                Text(verbatim: Formatting.dayHeader(day, calendar: store.calendar))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.forward")
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .padding(.top, Spacing.block)
            .padding(.bottom, Spacing.row)
            .scenePadding(.horizontal)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(Text("Opens the day"))
    }
}

#Preview("Selected day, 12:10") {
    let store = PreviewStore.make(at: "12:10")
    MonthDayPane(day: store.today) {}
        .calendarStore(store)
}
