import Foundation
import Testing

@testable import DayCore

/// Section 9, "Menu bar": the label follows the same `nextEvents` as the Lock Screen.
struct MenuBarLabelTests {
    let calendar = TestData.amsterdam

    func label(_ events: [Event], _ now: String) -> MenuBarLabel {
        let at = TestData.date(now)
        return menuBarLabel(
            next: nextEvents(events: events, now: at, calendar: calendar), now: at, calendar: calendar)
    }

    let investor = [TestData.event("Investor call", "2026-11-04 14:00", "2026-11-04 15:00")]

    @Test func quietIsTheSymbolAndTheStartTime() {
        #expect(label(investor, "2026-11-04 09:00") == MenuBarLabel(showsSymbol: true, text: "14:00"))
        // Just over 15 minutes away is still quiet.
        #expect(label(investor, "2026-11-04 13:44:59") == MenuBarLabel(showsSymbol: true, text: "14:00"))
    }

    @Test func withinFifteenMinutesNamesTheEventAndTheWait() {
        #expect(label(investor, "2026-11-04 13:48") == MenuBarLabel(showsSymbol: false, text: "Investor call in 12 min"))
        #expect(label(investor, "2026-11-04 13:45") == MenuBarLabel(showsSymbol: false, text: "Investor call in 15 min"))
        // Seconds round up so it never reads 0 min.
        #expect(label(investor, "2026-11-04 13:59:30") == MenuBarLabel(showsSymbol: false, text: "Investor call in 1 min"))
    }

    @Test func inProgressSaysHowLongIsLeft() {
        #expect(label(investor, "2026-11-04 14:42") == MenuBarLabel(showsSymbol: false, text: "Investor call, 18 min left"))
        #expect(label(investor, "2026-11-04 14:00") == MenuBarLabel(showsSymbol: false, text: "Investor call, 1 h left"))
        #expect(label(investor, "2026-11-04 14:10") == MenuBarLabel(showsSymbol: false, text: "Investor call, 50 min left"))
        #expect(label(investor, "2026-11-04 14:42:30") == MenuBarLabel(showsSymbol: false, text: "Investor call, 18 min left"))
    }

    @Test func inProgressBeatsTheNextOneStartingSoon() {
        let events = investor + [TestData.event("Acme sync", "2026-11-04 14:30", "2026-11-04 15:00")]
        #expect(label(events, "2026-11-04 14:20") == MenuBarLabel(showsSymbol: false, text: "Investor call, 40 min left"))
        // Acme sync started last, so it is the one in progress.
        #expect(label(events, "2026-11-04 14:40") == MenuBarLabel(showsSymbol: false, text: "Acme sync, 20 min left"))
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
        #expect(label(early, "2026-11-04 23:50") == MenuBarLabel(showsSymbol: false, text: "Early call in 15 min"))
        #expect(label(early, "2026-11-04 23:40") == .symbolOnly)
    }

    @Test func titlesAreCutAtSixteenCharactersAndThenGetAnEllipsis() {
        let long = [TestData.event("Quarterly planning meeting", "2026-11-04 14:00", "2026-11-04 15:00")]
        #expect(label(long, "2026-11-04 13:50").text == "Quarterly planni… in 10 min")
        #expect(label(long, "2026-11-04 14:10").text == "Quarterly planni…, 50 min left")
        // A cut title is sixteen characters and the ellipsis: the brief's rule, decided in
        // section 9, so the cut reads as one.
        #expect(label(long, "2026-11-04 13:50").text?.hasPrefix("Quarterly planni…") == true)
        #expect("Quarterly planni".count == 16)

        // Exactly sixteen is not cut.
        let exact = [TestData.event("Sixteen chars ok", "2026-11-04 14:00", "2026-11-04 15:00")]
        #expect("Sixteen chars ok".count == 16)
        #expect(label(exact, "2026-11-04 13:50").text == "Sixteen chars ok in 10 min")
        // Seventeen is the shortest title that is cut.
        let over = [TestData.event("Sixteen chars ok!", "2026-11-04 14:00", "2026-11-04 15:00")]
        #expect("Sixteen chars ok!".count == 17)
        #expect(label(over, "2026-11-04 13:50").text == "Sixteen chars ok… in 10 min")
        // A trailing space before the cut does not leave a gap before the ellipsis.
        let spaced = [TestData.event("Weekly planning x", "2026-11-04 14:00", "2026-11-04 15:00")]
        #expect(label(spaced, "2026-11-04 13:50").text == "Weekly planning… in 10 min")
    }

    @Test func theInventedWednesday() throws {
        let events = try TestData.inventedEvents()
        func at(_ time: String) -> MenuBarLabel {
            let now = TestData.wednesday(time)
            return menuBarLabel(next: nextEvents(events: events, now: now, calendar: calendar), now: now, calendar: calendar)
        }
        #expect(at("07:50") == MenuBarLabel(showsSymbol: true, text: "9:30"))
        #expect(at("09:20") == MenuBarLabel(showsSymbol: false, text: "Standup in 10 min"))
        #expect(at("11:40") == MenuBarLabel(showsSymbol: false, text: "Design review, 20 min left"))
        #expect(at("12:10") == MenuBarLabel(showsSymbol: true, text: "12:30"))
        #expect(at("17:30") == .symbolOnly)
    }
}
