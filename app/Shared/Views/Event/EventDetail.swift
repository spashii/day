import DayCore
import SwiftUI

/// The event, in nine lines, each only when it has content: title; when, with the authored
/// zone when its offset differs; `Repeats`; Join; the place; guests and his answer; the
/// calendars it sits on; the description; `Open in Google Calendar`. The iPhone shows it in a
/// sheet, the Mac in a popover. Nothing here edits, answers or lists guests: that is Google
/// Calendar's, one tap away.
struct EventDetail: View {
    @EnvironmentStore private var store
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
            let guests = Formatting.guests(event)
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
                    Text(verbatim: guests)
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

    /// `Work · you@acme.com`, with the calendar's color mark. A primary calendar is named by
    /// its address in Google, so it shows the address once.
    @ViewBuilder
    private func calendarLine(_ id: CalendarID) -> some View {
        let info = store.calendarInfo(id)
        let email = store.account(id.account)?.email
        let name = info?.name ?? id.googleID
        HStack(spacing: Spacing.cell) {
            Circle()
                .fill(info?.markColor ?? event.markColor)
                .frame(width: 8, height: 8)
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
