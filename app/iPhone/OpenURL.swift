import DayCore
import SwiftUI
import UIKit

/// How the iPhone opens a link that leaves Day: `Open in Google Calendar`, `Join`, and the
/// links detected in an event's description.
///
/// Each web link is offered to the apps first, as a universal link, so Google Calendar, Meet,
/// Zoom and Teams open in their own apps. `universalLinksOnly` makes the system say whether an
/// app took the link, which is what lets Safari be the fallback only when none did.
enum PhoneOpener {
    /// Opens `url` in the app that claims it, or in Safari.
    @MainActor
    static func open(_ url: URL) async {
        let application = UIApplication.shared
        if isWeb(url), await application.open(url, options: [.universalLinksOnly: true]) {
            return
        }
        await application.open(url)
    }

    /// Set at the root as `\.openURL`, so every link in the app, including those in a
    /// description, goes the same way. `day://` links and anything that is not a web page
    /// (`tel:`, `mailto:`) stay with the system.
    @MainActor
    static var action: OpenURLAction {
        OpenURLAction { url in
            guard isWeb(url) else { return .systemAction }
            Task { @MainActor in await open(url) }
            return .handled
        }
    }

    private static func isWeb(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }
}

extension HandoffAction {
    /// The handoff the views call for `Join` and `Open in Google Calendar`, through
    /// `PhoneOpener`. The iPhone sends no account hint: the universal link opens whichever
    /// account Google Calendar has signed in, which only a test on a device can confirm.
    static var phone: HandoffAction {
        HandoffAction { url, _ in
            Task { await PhoneOpener.open(url) }
        }
    }
}
