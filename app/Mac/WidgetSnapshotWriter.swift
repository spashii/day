import DayCore
import Foundation
import Security
import WidgetKit

/// The App Group the Mac app shares with its desktop widget, and where the widget's snapshot
/// sits inside it. Compiled into the app and into the widget extension, so the two name the
/// group and the folder in one place.
///
/// Only the snapshot crosses into the group. The app keeps its cache, tokens and settings in
/// `~/Library/Application Support/Day` and the login keychain, as before; the widget is
/// sandboxed and reads this one file.
enum MacWidgetGroup {
    /// Prefixed with the Team ID: macOS authorises such a group by the Team ID in the code
    /// signature, so a Developer ID build needs no provisioning profile. `app/project.yml`
    /// repeats it in both entitlements; change the three together.
    static let identifier = "JMCP69LCSU.io.github.spashii.day"
    static let teamID = "JMCP69LCSU"

    /// Whether this process is signed by the team that owns the group. Only then does macOS
    /// open the container without asking. A build signed ad hoc or with "Blend Dev" has no
    /// Team ID, so touching the container would put a consent prompt up on every launch while
    /// its widget could not read the file anyway; such a build leaves the group alone.
    static let isAvailable: Bool = signingTeam() == teamID

    /// The group's copy of the cache folder, laid out as on iPhone. Nil when this build may
    /// not use the group.
    static func cache() -> CacheDirectory? {
        guard isAvailable,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: identifier)
        else { return nil }
        return CacheDirectory(
            url: container.appending(
                path: "Library/Application Support/Day", directoryHint: .isDirectory))
    }

    /// The Team ID in this process's own signature; nil when it is signed without a team.
    private static func signingTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return nil }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let information = information as? [String: Any]
        else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Copies the app's widget snapshot into the App Group after a refresh, then asks WidgetKit
/// to rebuild the desktop widget's timelines only when the copy changed what it shows.
///
/// The engine already writes `widget-snapshot.json` beside the app's cache after every
/// refresh, toggle and removal, with the newer-wins rule; this mirrors that file. The group
/// has no other writer (the Mac widget never reads Google), so the copy follows the app's
/// exactly, a calendar hidden a moment ago included.
@MainActor
enum WidgetSnapshotWriter {
    /// Publishes `snapshot`, the one the engine left on disk. Nil, or a build that may not use
    /// the group, does nothing.
    static func publish(_ snapshot: WidgetSnapshot?) {
        guard let snapshot, let group = MacWidgetGroup.cache() else { return }
        publish(snapshot, to: group) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Writes `snapshot` into `group` unless the same one is there, and calls `reload` when
    /// the widget should draw it: what it shows changed, or the age its `As of` line is timed
    /// from moved by an hour (`WidgetSnapshot.needsReload`). A refresh that found nothing new
    /// still updates the file, so the widget's next scheduled reload starts from it, and costs
    /// none of the daily reload budget. Returns whether it asked for a reload.
    @discardableResult
    static func publish(
        _ snapshot: WidgetSnapshot, to group: CacheDirectory, reload: () -> Void
    ) -> Bool {
        let current = WidgetSnapshot.read(from: group)
        guard current != snapshot,
            (try? snapshot.write(to: group, force: true)) == true,
            snapshot.needsReload(after: current)
        else { return false }
        reload()
        return true
    }
}
