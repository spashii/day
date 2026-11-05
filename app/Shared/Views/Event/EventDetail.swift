import DayCore
import SwiftUI

/// The event, in nine lines, each only when it has content: title; when, with the authored
/// zone when its offset differs; `Repeats`; Join; the place; the guests with their answers
/// (`GuestListView`); the calendars it sits on; the description; `Open in Google Calendar`.
/// The iPhone shows it in a sheet, the Mac in a popover. Nothing here edits or answers:
/// that is Google Calendar's, one tap away.
struct EventDetail: View {
    @EnvironmentStore private var store
    @EnvironmentSymbols private var symbols
    @Environment(\.handoff) private var handoff
    @Environment(\.openURL) private var openURL

    let event: Event

    var body: some View {
        let calendar = store.calendar
        let account = store.account(event.account)
        VStack(alignment: .leading, spacing: Spacing.block) {
            VStack(alignment: .leading, spacing: Spacing.row) {
                Text(event.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: Formatting.eventWhen(event, calendar: calendar))
                    .monospacedDigit()
                if let authored = Formatting.authoredTime(event, calendar: calendar) {
                    Text(verbatim: authored)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if event.isRecurring {
                    Text("Repeats")
                        .foregroundStyle(.secondary)
                }
            }

            if let join = event.joinURL {
                Button("Join") {
                    handoff(join, account: account)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .fontWeight(.semibold)
            }

            let place = Formatting.place(event)
            let guests = event.guests
            // Events saved before guests were kept have a count and no list until the next
            // refresh reads them again; they keep the line they had.
            let countOnly = event.attendees.isEmpty ? Formatting.guests(event) : nil
            VStack(alignment: .leading, spacing: Spacing.cell) {
                if let place, let maps = mapsURL {
                    Button {
                        openURL(maps)
                    } label: {
                        Text(verbatim: place)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                }
                if let guests {
                    GuestListView(list: guests)
                } else if let countOnly {
                    Text(verbatim: countOnly)
                }
                ForEach(event.calendars, id: \.self) { id in
                    calendarLine(id)
                }
            }

            if let description = event.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                !description.isEmpty
            {
                DescriptionText(text: description)
            }

            if let link = event.htmlLink {
                Button("Open in Google Calendar") {
                    handoff(link, account: account)
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `Work · you@acme.com`, with the calendar's mark: its symbol in the calendar's color
    /// when it has one, else the color's dot. A primary calendar is named by its address in
    /// Google, so it shows the address once.
    @ViewBuilder
    private func calendarLine(_ id: CalendarID) -> some View {
        let info = store.calendarInfo(id)
        let email = store.account(id.account)?.email
        let name = info?.name ?? id.googleID
        HStack(spacing: Spacing.cell) {
            CalendarMark(
                symbol: symbols.symbol(for: id), color: info?.markColor ?? event.markColor, dot: 8)
            Text(verbatim: email.map { $0 == name ? name : "\(name) · \($0)" } ?? name)
                .lineLimit(1)
        }
    }

    /// Apple Maps searching the whole location as Google has it, so an address on its second
    /// line still finds the place.
    private var mapsURL: URL? {
        guard let location = event.location else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: location)]
        return components?.url
    }
}

/// The iPhone event sheet: medium and large detents, scrolling when the description is long.
struct EventSheet: View {
    let event: Event

    var body: some View {
        ScrollView {
            EventDetail(event: event)
                .scenePadding()
                .padding(.top, Spacing.cell)
        }
        .presentationDetents([.medium, .large])
    }
}

/// The Mac popover, opened by a click, Return or Command-I on a row or a titled item.
struct EventPopover: View {
    let event: Event

    var body: some View {
        ScrollView {
            EventDetail(event: event)
                .padding(Spacing.block)
        }
        .frame(width: 320)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// `Join` and `Open in Google Calendar` for context menus: a secondary click on the Mac, a
/// touch and hold on a touchscreen Mac.
struct EventMenuItems: View {
    @EnvironmentStore private var store
    @Environment(\.handoff) private var handoff
    let event: Event

    var body: some View {
        if let join = event.joinURL {
            Button("Join") {
                handoff(join, account: store.account(event.account))
            }
        }
        if let link = event.htmlLink {
            Button("Open in Google Calendar") {
                handoff(link, account: store.account(event.account))
            }
        }
    }
}

#Preview("Event sheet") {
    let store = PreviewStore.make()
    let event = store.dayEvents(store.today).first { $0.title == "Investor call" }!
    Text(verbatim: "Day")
        .sheet(isPresented: .constant(true)) {
            EventSheet(event: event)
                .calendarStore(store)
        }
        .calendarStore(store)
}

#Preview("Event sheet, with symbols") {
    let store = PreviewStore.make()
    let event = store.dayEvents(store.today).first { $0.title == "Investor call" }!
    // The Investor call sits on both accounts, so the sheet shows one symbol and one dot.
    let symbols = CalendarSymbols([event.id.calendar: CalendarSymbol.named("briefcase")!])
    Text(verbatim: "Day")
        .sheet(isPresented: .constant(true)) {
            EventSheet(event: event)
                .calendarStore(store)
                .calendarSymbols(symbols)
        }
        .calendarStore(store)
}
