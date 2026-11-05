import Foundation
import Observation
import ServiceManagement

/// `Open at login`, through `SMAppService`. Day never registers itself: the toggle is shown on
/// the first-run screen and in Settings, starts off, and only a click changes it. The
/// system owns the truth (the person can also switch it in System Settings), so the state is
/// read from `SMAppService` each time the window or Settings comes to the front.
@MainActor
@Observable
final class OpenAtLogin {
    private(set) var status: SMAppService.Status
    /// What went wrong the last time the toggle was changed, in words a person can act on.
    private(set) var failure: String?

    init() {
        status = SMAppService.mainApp.status
    }

    /// On only once macOS lets Day start at login. Registered but waiting for the person's
    /// approval in System Settings reads as off, so the switch never claims more than is true.
    var isOn: Bool {
        status == .enabled
    }

    /// A click on the toggle. When macOS holds the registration until the person allows Day
    /// under Login Items, that pane opens right away, because it is the only place the next
    /// step can happen and it needs no words of Day's own.
    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failure = nil
        } catch {
            failure = "Couldn't change Open at login: \(error.localizedDescription)"
        }
        refresh()
        if on, status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }
}
