import Foundation

/// Google's JSON into the model. Pure functions with no I/O, so every rule here is tested
/// against recorded, invented responses.
///
/// - All-day events become civil dates with an exclusive end, never a `Date` at UTC
///   midnight.
/// - A timed event keeps the zone it was written in (`start.timeZone`, else the calendar's),
///   which the event sheet names when it differs from the device's.
/// - The join link is chosen in source order: the conference's video entry point,
///   `hangoutLink`, a URL in the location, a known meeting URL in the description.
/// - The color is the event label's, then the event's `colorId` in the modern palette, then
///   the calendar's, mapped onto the thirteen system colors.
/// - An event with no title is `Busy` on every calendar, free/busy-only or not, so no
///   surface ever draws an empty title.
public enum GoogleDecoding {
    // MARK: Calendars

    /// One calendar list entry, or nil for a deleted or hidden one. `labels` comes from
    /// `calendars.get`, read separately and cached with the list.
    public static func calendarInfo(
        _ entry: GoogleCalendarListEntry, account: AccountID, labels: [String: LabelInfo] = [:]
    ) -> CalendarInfo? {
        guard entry.deleted != true, entry.hidden != true else { return nil }
        let name =
            [entry.summaryOverride, entry.summary].compactMap { $0 }.first { !$0.isEmpty }
            ?? entry.id
        return CalendarInfo(
            id: CalendarID(account: account, googleID: entry.id),
            name: name,
            colorHex: entry.backgroundColor.flatMap(hex) ?? "#616161",
            // Google omits `selected` when it is false.
            selected: entry.selected ?? false,
            isPrimary: entry.primary ?? false,
            accessRole: accessRole(entry.accessRole),
            timeZone: entry.timeZone.flatMap { TimeZone(identifier: $0) != nil ? $0 : nil }
                ?? "UTC",
            labels: labels,
            defaultReminders: defaultReminders(entry.defaultReminders))
    }

    /// An account's calendar list in Google's order, with the primary calendar first.
    public static func calendars(
        _ entries: [GoogleCalendarListEntry], account: AccountID,
        labels: [String: [String: LabelInfo]] = [:]
    ) -> [CalendarInfo] {
        let infos = entries.compactMap {
            calendarInfo($0, account: account, labels: labels[$0.id] ?? [:])
        }
        return infos.filter(\.isPrimary) + infos.filter { !$0.isPrimary }
    }

    /// Whether `calendars.get` is worth calling for labels. Google's generated calendars
    /// (holidays, birthdays, week numbers) live under `group.v.calendar.google.com` and
    /// carry none; a free/busy reader cannot see them.
    public static func mayHaveLabels(_ entry: GoogleCalendarListEntry) -> Bool {
        entry.accessRole != "freeBusyReader"
            && !entry.id.hasSuffix("@group.v.calendar.google.com")
    }

    /// The same test on a calendar already decoded.
    public static func mayHaveLabels(_ info: CalendarInfo) -> Bool {
        info.accessRole != .freeBusyReader
            && !info.id.googleID.hasSuffix("@group.v.calendar.google.com")
    }

    /// Whether events decoded on `old` would come out differently on `new`: their color
    /// (the calendar's and its labels), the zone a timed event falls back to, and the
    /// `Busy` title of a free/busy calendar. An incremental read only returns events that
    /// changed, so a calendar whose own entry changed this way is read in full instead.
    public static func decodesDifferently(_ old: CalendarInfo, _ new: CalendarInfo) -> Bool {
        old.colorHex != new.colorHex || old.labels != new.labels
            || old.timeZone != new.timeZone || old.accessRole != new.accessRole
    }

    /// The labels a calendar defines, keyed by label ID. A label with no readable color is
    /// left out, so its events fall back to their own color.
    public static func labels(_ resource: GoogleCalendarResource) -> [String: LabelInfo] {
        var labels: [String: LabelInfo] = [:]
        for label in resource.labelProperties?.eventLabels ?? [] {
            guard
                let color = label.backgroundColor.flatMap(hex)
                    ?? label.colorId.flatMap(ModernPalette.eventHex)
            else { continue }
            labels[label.id] = LabelInfo(name: label.name ?? "", colorHex: color)
        }
        return labels
    }

    /// Google's roles onto Day's four. `writerWithoutPrivateAccess` writes, so it ranks as a
    /// writer when picking which account keeps a shared calendar.
    public static func accessRole(_ role: String?) -> AccessRole {
        switch role {
        case "owner": .owner
        case "writer", "writerWithoutPrivateAccess": .writer
        case "freeBusyReader": .freeBusyReader
        default: .reader
        }
    }

    // MARK: Events

    /// One event on `calendar`, or nil when it has no usable start.
    public static func event(_ google: GoogleEvent, on calendar: CalendarInfo) -> Event? {
        guard let time = eventTime(google, calendarZone: calendar.timeZone) else { return nil }
        let people = (google.attendees ?? []).filter { !isRoom($0) }
        let me = google.attendees?.first { $0.isSelf == true }
        let others = people.filter { $0.isSelf != true }
        var event = Event(
            id: EventID(calendar: calendar.id, googleID: google.id),
            iCalUID: nonEmpty(google.iCalUID) ?? google.id,
            originalStart: google.originalStartTime.flatMap(originalStart),
            title: title(google.summary),
            time: time,
            kind: google.eventType.flatMap(EventKind.init(rawValue:)) ?? .default,
            status: google.status.flatMap(EventStatus.init(rawValue:)) ?? .confirmed,
            isRecurring: nonEmpty(google.recurringEventId) != nil,
            response: me.map { response($0.responseStatus) } ?? .none,
            isOrganizer: google.organizer?.isSelf == true,
            attendeeCount: people.count,
            attendeeDomains: Set(others.compactMap { domain($0.email) }).sorted(),
            attendees: (google.attendees ?? []).compactMap(attendee),
            isFree: google.transparency == "transparent",
            location: nonEmpty(google.location?.trimmingCharacters(in: .whitespacesAndNewlines)),
            joinURL: joinURL(google),
            htmlLink: google.htmlLink.flatMap(webURL),
            description: nonEmpty(google.description.map(plainText(fromHTML:))),
            colorKey: colorKey(
                labelID: google.eventLabelId, colorID: google.colorId, calendar: calendar))
        event.reminders = reminders(google.reminders)
        return event
    }

    /// Every event of one calendar's page, skipping any without a usable start.
    public static func events(_ google: [GoogleEvent], on calendar: CalendarInfo) -> [Event] {
        google.compactMap { event($0, on: calendar) }
    }

    /// One item of an incremental answer, as what it does to the cache. `cancelled` always
    /// removes: a deleted event, a cancelled instance of a series, an event moved to another
    /// calendar (it leaves a cancelled item behind), and the organizer's own deleted copy,
    /// which still carries its details. An item that no longer decodes removes the copy too,
    /// because a full read would leave it out and the two kinds of read must agree.
    public static func change(_ google: GoogleEvent, on calendar: CalendarInfo) -> EventChange {
        guard google.status != "cancelled", let event = event(google, on: calendar) else {
            return .remove(googleID: google.id)
        }
        return .upsert(event)
    }

    /// The title exactly as written in Google. Google sends no `summary` for an untitled
    /// event, and none for events on a calendar shared as free/busy only; a blank title would
    /// draw an empty row and an empty widget line, so both are `Event.untitled`. Titles stay
    /// data, which is why this is decided here and not in the views.
    static func title(_ summary: String?) -> String {
        if let summary, !summary.allSatisfy(\.isWhitespace) { return summary }
        return Event.untitled
    }

    static func eventTime(_ google: GoogleEvent, calendarZone: String) -> EventTime? {
        guard let start = google.start else { return nil }
        if let first = start.date.flatMap({ CivilDate($0) }) {
            var end = google.end?.date.flatMap { CivilDate($0) } ?? first.adding(days: 1)
            if end <= first { end = first.adding(days: 1) }
            return .allDay(start: first, endExclusive: end)
        }
        guard let begins = start.dateTime.flatMap(instant) else { return nil }
        let ends = max(begins, google.end?.dateTime.flatMap(instant) ?? begins)
        let zone = [start.timeZone, calendarZone].compactMap { $0 }
            .first { !$0.isEmpty && TimeZone(identifier: $0) != nil }
        return .timed(start: begins, end: ends, authoredZone: zone)
    }

    /// The instance's slot in its series. An all-day series has a date there, which becomes
    /// UTC midnight: the value is only ever a merge key, and UTC makes it the same instant
    /// from every account whatever their calendars' zones.
    static func originalStart(_ time: GoogleEvent.Time) -> Date? {
        if let dateTime = time.dateTime { return instant(dateTime) }
        return time.date.flatMap { CivilDate($0) }?.date(in: TimeZone.gmt)
    }

    static func response(_ status: String?) -> Response {
        switch status {
        case "accepted": .accepted
        case "declined": .declined
        case "tentative": .tentative
        default: .needsAction
        }
    }

    /// One guest-list entry as the model keeps it, or nil for an entry with neither an
    /// address nor a name, which the sheet could not draw.
    static func attendee(_ person: GoogleEvent.Person) -> Attendee? {
        let email = person.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = nonEmpty(person.displayName?.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !email.isEmpty || name != nil else { return nil }
        return Attendee(
            email: email, displayName: name, isOrganizer: person.isOrganizer == true,
            isSelf: person.isSelf == true, isResource: isRoom(person),
            isOptional: person.isOptional == true, response: response(person.responseStatus))
    }

    static func isRoom(_ person: GoogleEvent.Person) -> Bool {
        person.resource == true
            || person.email?.lowercased().hasSuffix("@resource.calendar.google.com") == true
    }

    /// `harbor.example` from `ines@harbor.example`; nil for Google's own calendar addresses
    /// (groups, rooms), which are not people with a domain of their own.
    static func domain(_ email: String?) -> String? {
        guard let email, let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].lowercased()
        guard !domain.isEmpty, !domain.hasSuffix("calendar.google.com") else { return nil }
        return domain
    }

    /// The label's color, then the event's `colorId` in the modern palette, then the
    /// calendar's, as Google Calendar itself orders them.
    public static func colorKey(labelID: String?, colorID: String?, calendar: CalendarInfo)
        -> ColorKey
    {
        if let labelID, let label = calendar.labels[labelID],
            let key = ColorKey(hex: label.colorHex)
        {
            return key
        }
        if let colorID, let hex = ModernPalette.eventHex(colorID), let key = ColorKey(hex: hex) {
            return key
        }
        return calendar.colorKey
    }

    // MARK: Join links

    /// The link Join opens, first match: the conference's `video` entry point (which also
    /// covers add-ons such as Zoom), `hangoutLink`, a URL in the location, then a known
    /// meeting URL in the description.
    public static func joinURL(_ google: GoogleEvent) -> URL? {
        if let video = google.conferenceData?.entryPoints?
            .first(where: { $0.entryPointType == "video" })?.uri,
            let url = webURL(video)
        {
            return url
        }
        if let url = google.hangoutLink.flatMap(webURL) {
            return url
        }
        // A maps link in the location points at a place, not a call.
        if let location = google.location,
            let url = links(in: location).first(where: { !isMapLink($0) })
        {
            return url
        }
        if let description = google.description,
            let url = links(in: decodeEntities(description)).first(where: isMeetingLink)
        {
            return url
        }
        return nil
    }

    /// The meeting services Day recognizes: Meet, Zoom, Teams, Webex and Whereby.
    static func isMeetingLink(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let hosts: Set = [
            "meet.google.com", "zoom.us", "zoomgov.com", "teams.microsoft.com", "teams.live.com",
            "whereby.com",
        ]
        let suffixes = [".zoom.us", ".zoomgov.com", ".webex.com", ".whereby.com"]
        return hosts.contains(host) || suffixes.contains { host.hasSuffix($0) }
    }

    static func isMapLink(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let path = url.path()
        return host.hasPrefix("maps.") || host == "maps.app.goo.gl"
            || (host == "goo.gl" && path.hasPrefix("/maps"))
            || (host.hasSuffix("google.com") && path.hasPrefix("/maps"))
    }

    /// Web links in `text`, in order of appearance.
    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased())
            else { return nil }
            return url
        }
    }

    static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil
        else { return nil }
        return url
    }

    // MARK: Text

    /// Plain text from a description. The web app writes HTML (`<br>`, `<a>`, lists); other
    /// clients write plain text, which passes through. A link whose text differs from its
    /// target keeps the target in brackets, so link detection in the sheet still finds it.
    public static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: "\r\n", with: "\n")
        let looksLikeHTML = text.contains(#/<[a-zA-Z\/][^>]*>/#) || text.contains(#/&[#a-zA-Z0-9]+;/#)
        guard looksLikeHTML else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.replacing(
            #/<a\b[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>/#.ignoresCase()
                .dotMatchesNewlines()
        ) { match in
            let target = decodeEntities(String(match.output.1))
            let label = decodeEntities(stripTags(String(match.output.2)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = webURL(target) else { return label }
            if label.isEmpty || label == target || label.contains(url.absoluteString) {
                return target
            }
            return "\(label) (\(target))"
        }
        text = text.replacing(#/<br\s*/?>/#.ignoresCase(), with: "\n")
        text = text.replacing(#/</(p|div|li|tr|h[1-6]|ul|ol)\s*>/#.ignoresCase(), with: "\n")
        text = text.replacing(#/<li\b[^>]*>/#.ignoresCase(), with: "• ")
        text = decodeEntities(stripTags(text))
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(#/[ \t]+$/#, with: "") }
        text = lines.joined(separator: "\n")
        text = text.replacing(#/\n{3,}/#, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripTags(_ html: String) -> String {
        html.replacing(#/<[^>]*>/#, with: "")
    }

    /// `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, `&#39;`, `&nbsp;` and numeric references.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        ]
        return text.replacing(#/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/#) { match in
            let body = String(match.output.1)
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                return UInt32(body.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }
                    .map { String(Character($0)) } ?? String(match.output.0)
            }
            if body.hasPrefix("#") {
                return UInt32(body.dropFirst()).flatMap { Unicode.Scalar($0) }
                    .map { String(Character($0)) } ?? String(match.output.0)
            }
            return named[body.lowercased()] ?? String(match.output.0)
        }
    }

    // MARK: Values

    /// RFC 3339 as Google writes it: `2026-11-04T14:00:00+01:00`, `…Z`, with optional
    /// fractional seconds. Parsed by hand, because it is the hot path of every fetch and the
    /// format is fixed.
    public static func instant(_ text: String) -> Date? {
        let c = Array(text.utf8)
        func number(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= c.count else { return nil }
            var value = 0
            for i in from..<(from + count) {
                guard (48...57).contains(c[i]) else { return nil }
                value = value * 10 + Int(c[i] - 48)
            }
            return value
        }
        guard c.count >= 20,
            let year = number(0, 4), c[4] == UInt8(ascii: "-"),
            let month = number(5, 2), c[7] == UInt8(ascii: "-"),
            let day = number(8, 2), [UInt8(ascii: "T"), UInt8(ascii: "t")].contains(c[10]),
            let hour = number(11, 2), c[13] == UInt8(ascii: ":"),
            let minute = number(14, 2), c[16] == UInt8(ascii: ":"),
            let second = number(17, 2),
            (1...12).contains(month), (1...CivilDate.daysIn(month: month, year: year)).contains(day),
            hour < 24, minute < 60, second < 61
        else { return nil }
        var i = 19
        var fraction = 0.0
        if i < c.count, c[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < c.count, (48...57).contains(c[i]) {
                fraction += Double(c[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        guard i < c.count else { return nil }
        var offset = 0
        switch c[i] {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            i += 1
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            guard let hours = number(i + 1, 2), i + 3 < c.count, c[i + 3] == UInt8(ascii: ":"),
                let minutes = number(i + 4, 2)
            else { return nil }
            offset = (hours * 3600 + minutes * 60) * (c[i] == UInt8(ascii: "-") ? -1 : 1)
            i += 6
        default:
            return nil
        }
        guard i == c.count else { return nil }
        let days = CivilDate(year: year, month: month, day: day).dayNumber
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds) + fraction)
    }

    /// `#rrggbb` uppercased, or nil for anything that is not a hex color.
    static func hex(_ value: String) -> String? {
        guard ColorKey(hex: value) != nil else { return nil }
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        return "#" + digits.uppercased()
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
