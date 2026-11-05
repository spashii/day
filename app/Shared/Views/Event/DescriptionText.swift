import SwiftUI

/// The event description as plain text with its links tappable in the tint color, six lines
/// and then `More` when there is more.
struct DescriptionText: View {
    let text: String

    @State private var expanded = false
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        let linked = DescriptionText.linked(text)
        VStack(alignment: .leading, spacing: Spacing.row) {
            Text(linked)
                .lineLimit(expanded ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                .background(alignment: .topLeading) {
                    // The whole text, unlimited and invisible, to learn whether six lines cut it.
                    Text(linked)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
            if !expanded, fullHeight > shownHeight + 1 {
                Button("More") {
                    withAnimation { expanded = true }
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Links found with the system's data detector, so a pasted agenda URL opens.
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return result }
        let whole = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: whole) {
            guard let url = match.url, let range = Range(match.range, in: text),
                let target = Range(range, in: result)
            else { continue }
            result[target].link = url
        }
        return result
    }
}
