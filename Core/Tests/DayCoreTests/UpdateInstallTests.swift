import Foundation
import Testing

@testable import DayCore

/// When the Mac app installs a downloaded update by relaunching: only while nobody is looking
/// at it and no meeting is about to start or has just started.
struct UpdateInstallTests {
    let calendar = TestData.amsterdam
    let now = "2026-11-04 12:00"

    func idle(
        _ events: [Event] = [], active: Bool = false, windows: [AppWindow] = []
    ) -> Bool {
        let at = TestData.date(now)
        return isIdleForUpdate(
            appIsActive: active, windows: windows,
            next: nextEvents(events: events, now: at, calendar: calendar), now: at)
    }

    func event(_ start: String, _ end: String) -> Event {
        TestData.event("Review", "2026-11-04 \(start)", "2026-11-04 \(end)")
    }

    let closed = AppWindow(isKey: false, isVisible: false)

    @Test func noEventsAndNothingOnScreenIsIdle() {
        #expect(idle())
        #expect(idle(windows: [closed, closed]))
    }

    @Test func aKeyWindowIsInUse() {
        #expect(!idle(windows: [closed, AppWindow(isKey: true, isVisible: true)]))
    }

    @Test func aVisiblePanelIsInUse() {
        #expect(!idle(windows: [closed, AppWindow(isKey: false, isVisible: true)]))
    }

    @Test func theActiveAppIsInUseEvenWithNoWindow() {
        #expect(!idle(active: true))
    }

    @Test func anEventOneMinuteAheadHoldsItBack() {
        #expect(!idle([event("12:01", "12:30")]))
    }

    @Test func anEventThreeMinutesAheadDoesNot() {
        #expect(idle([event("12:03", "12:30")]))
    }

    @Test func anEventThatStartedOneMinuteAgoHoldsItBack() {
        #expect(!idle([event("11:59", "12:30")]))
    }

    @Test func aMeetingUnderWayForLongerDoesNot() {
        #expect(idle([event("11:30", "12:30")]))
    }

    @Test func twoMinutesExactlyStillHoldsItBack() {
        #expect(!idle([event("12:02", "12:30")]))
        #expect(!idle([event("11:58", "12:30")]))
    }

    /// The same candidates as the menu bar: a declined meeting is not one.
    @Test func aDeclinedEventDoesNotHoldItBack() {
        var declined = event("12:01", "12:30")
        declined.response = .declined
        #expect(idle([declined]))
    }
}
