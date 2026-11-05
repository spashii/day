import Foundation
import Observation
import Sparkle

/// Updates come through Sparkle: it reads the appcast on Day's website, checks each update
/// against the signing key in Info.plist, and asks before installing. Sparkle itself asks on
/// the second launch whether to check automatically; nothing else in Day goes online for
/// updates.
///
/// A run that was started with `-UseFixtures` (screenshots, tests) never starts Sparkle, so
/// its second-launch question and its network check cannot land in a capture.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// False while a check is already under way, and always false when Sparkle was not
    /// started.
    private(set) var canCheck = false

    /// `Check for updates automatically`. Sparkle's own first question changes it behind the
    /// toggle's back, so it is read through the observation below too.
    var automatic: Bool {
        didSet {
            if controller.updater.automaticallyChecksForUpdates != automatic {
                controller.updater.automaticallyChecksForUpdates = automatic
            }
        }
    }

    init(start: Bool) {
        let controller = SPUStandardUpdaterController(
            startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        automatic = updater.automaticallyChecksForUpdates
        canCheck = updater.canCheckForUpdates
        // Sparkle changes both on the main thread.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.canCheck = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated {
                    if self?.automatic != value { self?.automatic = value }
                }
            },
        ]
    }

    /// `Check for Updates…`.
    func check() {
        controller.checkForUpdates(nil)
    }
}
