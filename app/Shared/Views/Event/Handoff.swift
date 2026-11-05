import DayCore
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Opens a Google Calendar page or a meeting link, the two ways out of Day. The views call
/// it for `Join` and `Open in Google Calendar`; a root may replace it, for instance to route
/// through the app's own URL handling.
///
/// - iPhone: as a universal link first, so Google Calendar, Meet, Zoom and Teams open their
///   apps, and in Safari when no app claims it.
/// - Mac: in the default browser with `authuser=<email>` on google.com hosts, so the
///   account the event came from opens rather than whichever is signed in first. Browser
///   Picker, as the default browser, keeps routing profiles.
struct HandoffAction {
    let handler: @MainActor (URL, Account?) -> Void

    @MainActor
    func callAsFunction(_ url: URL, account: Account?) {
        handler(url, account)
    }

    static var system: HandoffAction {
        HandoffAction { url, account in
            #if os(iOS)
                UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
                    if !opened {
                        UIApplication.shared.open(url)
                    }
                }
            #else
                NSWorkspace.shared.open(HandoffAction.withAuthUser(url, account: account))
            #endif
        }
    }

    /// Adds `authuser=<email>` to Google URLs. Google documents no such parameter; it is the
    /// community-reported way to pick the account, so it goes only on google.com hosts.
    static func withAuthUser(_ url: URL, account: Account?) -> URL {
        guard let account, let host = url.host()?.lowercased(),
            host == "google.com" || host.hasSuffix(".google.com"),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "authuser" }
        items.append(URLQueryItem(name: "authuser", value: account.email))
        components.queryItems = items
        return components.url ?? url
    }
}

private struct HandoffKey: EnvironmentKey {
    static var defaultValue: HandoffAction { .system }
}

extension EnvironmentValues {
    var handoff: HandoffAction {
        get { self[HandoffKey.self] }
        set { self[HandoffKey.self] = newValue }
    }
}
