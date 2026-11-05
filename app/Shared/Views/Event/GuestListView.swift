import DayCore
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The guests line of the event sheet and the people under it: `5 guests: 3 yes, 1 no, 1
/// awaiting`, then the organizer, you and the rest, each with their answer as a small symbol.
/// More than eight show the first eight and `Show All`, which opens the rest in place.
/// Clicking or tapping a guest copies their address to the pasteboard, and the row reads
/// `Copied` in place of the name for a moment, so the copy is seen on the Mac too; the iPhone
/// also gives a haptic. Nothing here writes mail, answers for anyone or reaches Google.
struct GuestListView: View {
    let list: GuestList
    @State private var showingAll = false
    @State private var copies = 0
    /// The row that reads `Copied`, and the copy that put it there, so a later copy is not
    /// cut short by the timer of an earlier one.
    @State private var copied: (row: GuestList.Row.ID, copy: Int)?

    /// Long enough to read one word, short enough that the name is back before the next look.
    static let copiedFor: Duration = .seconds(1.5)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            Text(verbatim: list.summary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list.shown(all: showingAll)) { row in
                    GuestRowView(row: row, copied: copied?.row == row.id) {
                        copy(row)
                    }
                }
            }
            if list.isLong && !showingAll {
                Button("Show All") {
                    withAnimation { showingAll = true }
                }
                .buttonStyle(.borderless)
            }
        }
        .sensoryFeedback(.success, trigger: copies)
    }

    private func copy(_ row: GuestList.Row) {
        GuestPasteboard.copy(row.email)
        copies += 1
        let copy = copies
        copied = (row.id, copy)
        AccessibilityNotification.Announcement(GuestRowView.copiedWord).post()
        Task {
            try? await Task.sleep(for: Self.copiedFor)
            if copied?.copy == copy { copied = nil }
        }
    }
}

/// One guest: the answer's symbol, the name, and Organizer or Optional after it in the
/// secondary color. VoiceOver reads it as one element, name then answer then the marks, and
/// the symbol is decoration. A guest with no address has nothing to copy and is plain text.
struct GuestRowView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: GuestList.Row
    /// Reads `Copied` in place of the name, just after the address was copied.
    var copied = false
    let copy: () -> Void

    static let copiedWord = "Copied"

    var body: some View {
        if row.email.isEmpty {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.spoken)
        } else {
            Button(action: copy) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.spoken)
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.cell) {
            Image(systemName: row.answer.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            if copied {
                Text(verbatim: Self.copiedWord)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: row.name)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            if !copied, !row.marks.isEmpty {
                Text(verbatim: row.marks.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        // A finger needs 44 points; a pointer does not.
        .frame(minHeight: Platform.isMac ? 24 : 44, alignment: .leading)
        .contentShape(.rect)
    }
}

extension GuestAnswer {
    /// Outline symbols that differ in shape, not only in color, drawn monochrome like the
    /// calendar symbols on the rows.
    var symbolName: String {
        switch self {
        case .yes: "checkmark.circle"
        case .no: "xmark.circle"
        case .maybe: "questionmark.circle"
        case .awaiting: "circle.dotted"
        }
    }
}

/// The system pasteboard, a guest's address only.
enum GuestPasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }
}

#Preview("Guests, six") {
    let list = GuestList([
        Attendee(email: "ines@harbor.example", displayName: "Ines Vos", isOrganizer: true, response: .accepted),
        Attendee(email: "you@acme.com", displayName: "Sam", isSelf: true, response: .needsAction),
        Attendee(email: "tom@acme.com", displayName: "Tom Berg", response: .accepted),
        Attendee(email: "priya@acme.com", displayName: "Priya Rao", response: .declined),
        Attendee(email: "maya@harbor.example", isOptional: true, response: .tentative),
        Attendee(email: "lobby@resource.calendar.google.com", displayName: "Lobby", isResource: true, response: .accepted),
    ])!
    GuestListView(list: list)
        .frame(width: 320, alignment: .leading)
        .padding()
}

#Preview("Guests, eleven") {
    let list = GuestList(
        (1...11).map {
            Attendee(
                email: "guest\($0)@harbor.example", displayName: "Guest \($0)",
                isOrganizer: $0 == 1, response: $0 % 3 == 0 ? .needsAction : .accepted)
        })!
    GuestListView(list: list)
        .frame(width: 320, alignment: .leading)
        .padding()
}
