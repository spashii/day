import Foundation
import Testing

@testable import DayCore

/// Section 9, "Menu bar": the label follows the same `nextEvents` as the Lock Screen and is
/// as short as it can be, so macOS does not hide it beside the notch.
struct MenuBarLabelTests {
    let calendar = TestData.amsterdam

    func label(_ events: [Event], _ now: String) -> MenuBarLabel {
        let at = TestData.date(now)
        return menuBarLabel(
            next: nextEvents(events: events, now: at, calendar: calendar), now: at, calendar: calendar)
    }

    /// A title longer than 8 characters, so the label is the time alone.
    let investor = [TestData.event("Investor call", "2026-11-04 14:00", "2026-11-04 15:00")]

    @Test func quietIsTheStartTimeAlone() {
        #expect(label(investor, "2026-11-04 09:00") == MenuBarLabel(showsSymbol: false, text: "14:00"))
        // Just over 15 minutes away is still quiet.
        #expect(label(investor, "2026-11-04 13:44:59") == MenuBarLabel(showsSymbol: false, text: "14:00"))
        // No leading zero, as on the Lock Screen.
        let early = [TestData.event("Investor call", "2026-11-04 09:30", "2026-11-04 10:00")]
        #expect(label(early, "2026-11-04 07:00").text == "9:30")
    }

    @Test func withinFifteenMinutesIsTheWaitAlone() {
        #expect(label(investor, "2026-11-04 13:48") == MenuBarLabel(showsSymbol: false, text: "in 12 min"))
        #expect(label(investor, "2026-11-04 13:45") == MenuBarLabel(showsSymbol: false, text: "in 15 min"))
        // Seconds round up so it never reads 0 min.
        #expect(label(investor, "2026-11-04 13:59:30") == MenuBarLabel(showsSymbol: false, text: "in 1 min"))
    }

    @Test func inProgressSaysHowLongIsLeftAlone() {
        #expect(label(investor, "2026-11-04 14:42") == MenuBarLabel(showsSymbol: false, text: "18 min left"))
        #expect(label(investor, "2026-11-04 14:00") == MenuBarLabel(showsSymbol: false, text: "1 h left"))
        #expect(label(investor, "2026-11-04 14:10") == MenuBarLabel(showsSymbol: false, text: "50 min left"))
        #expect(label(investor, "2026-11-04 14:42:30") == MenuBarLabel(showsSymbol: false, text: "18 min left"))
    }

    @Test func inProgressBeatsTheNextOneStartingSoon() {
        let events = investor + [TestData.event("Acme sync", "2026-11-04 14:30", "2026-11-04 15:00")]
        #expect(label(events, "2026-11-04 14:20").text == "40 min left")
        // Acme sync started last, so it is the one in progress. Nine characters, so no title.
        #expect("Acme sync".count == 9)
        #expect(label(events, "2026-11-04 14:40").text == "20 min left")
    }

    @Test func afterTheLastEventOrWithNothingTodayIsTheSymbolAlone() {
        #expect(label(investor, "2026-11-04 15:00") == .symbolOnly)
        #expect(label([], "2026-11-04 09:00") == .symbolOnly)
        // Tomorrow's event, far away: the symbol alone, not tomorrow's time.
        let tomorrow = [TestData.event("Standup", "2026-11-05 09:30", "2026-11-05 09:45")]
        #expect(label(tomorrow, "2026-11-04 12:00") == .symbolOnly)
        #expect(MenuBarLabel.symbolOnly == MenuBarLabel(showsSymbol: true, text: nil))
    }

    @Test func aCountdownCrossesMidnight() {
        let early = [TestData.event("Early call", "2026-11-05 00:05", "2026-11-05 00:30")]
        #expect(label(early, "2026-11-04 23:50").text == "in 15 min")
        #expect(label(early, "2026-11-04 23:40") == .symbolOnly)
    }

    @Test func aTitleOfEightCharactersOrFewerJoinsTheTime() {
        let short = [TestData.event("Standup", "2026-11-04 09:30", "2026-11-04 09:45")]
        #expect(label(short, "2026-11-04 07:00").text == "9:30 Standup")
        #expect(label(short, "2026-11-04 09:20").text == "Standup in 10 min")
        #expect(label(short, "2026-11-04 09:40").text == "Standup, 5 min left")
        // No symbol beside a label with an event: the notch has no room for it.
        #expect(label(short, "2026-11-04 07:00").showsSymbol == false)
    }

    @Test func aTitleIsNeverCut() {
        // Exactly eight characters is whole and joins; nine is left out entirely.
        let eight = [TestData.event("Dentists", "2026-11-04 14:00", "2026-11-04 15:00")]
        #expect("Dentists".count == 8)
        #expect(label(eight, "2026-11-04 09:00").text == "14:00 Dentists")
        let nine = [TestData.event("Dentists!", "2026-11-04 14:00", "2026-11-04 15:00")]
        #expect("Dentists!".count == 9)
        #expect(label(nine, "2026-11-04 09:00").text == "14:00")
        #expect(label(nine, "2026-11-04 13:50").text == "in 10 min")
        #expect(label(nine, "2026-11-04 14:10").text == "50 min left")
        // Never an ellipsis, in any state.
        let long = [TestData.event("Quarterly planning meeting", "2026-11-04 14:00", "2026-11-04 15:00")]
        for now in ["2026-11-04 09:00", "2026-11-04 13:50", "2026-11-04 14:10"] {
            #expect(label(long, now).text?.contains("…") == false)
            #expect(label(long, now).text?.contains("Quarterly") == false)
        }
    }

    @Test func titlesCountCharactersNotBytes() {
        // Four characters in the title, eleven bytes.
        let emoji = [TestData.event("📅📅📅📅", "2026-11-04 14:00", "2026-11-04 15:00")]
        #expect(label(emoji, "2026-11-04 09:00").text == "14:00 📅📅📅📅")
        // Spaces around a title do not count against it.
        let padded = [TestData.event("  Standup  ", "2026-11-04 14:00", "2026-11-04 15:00")]
        #expect(label(padded, "2026-11-04 09:00").text == "14:00 Standup")
    }

    @Test func anUntitledEventReadsBusy() {
        let busy = [TestData.event("Busy", "2026-11-04 14:00", "2026-11-04 15:00")]
        #expect(label(busy, "2026-11-04 09:00").text == "14:00 Busy")
    }

    @Test func theInventedWednesday() throws {
        let events = try TestData.inventedEvents()
        func at(_ time: String) -> MenuBarLabel {
            let now = TestData.wednesday(time)
            return menuBarLabel(next: nextEvents(events: events, now: now, calendar: calendar), now: now, calendar: calendar)
        }
        #expect(at("07:50") == MenuBarLabel(showsSymbol: false, text: "9:30 Standup"))
        #expect(at("09:20") == MenuBarLabel(showsSymbol: false, text: "Standup in 10 min"))
        // Design review is 13 characters, so only the wait is left.
        #expect(at("11:40") == MenuBarLabel(showsSymbol: false, text: "20 min left"))
        #expect(at("12:10") == MenuBarLabel(showsSymbol: false, text: "12:30"))
        #expect(at("17:30") == .symbolOnly)
    }
}
