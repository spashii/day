import DayCore
import Foundation

/// Day's folder for this build of the app.
///
/// A Debug build of the Mac app has the installed app's bundle identifier and runs as the
/// same user, so with one folder it would read the installed app's `accounts.json`, find no
/// token for those accounts under its own keychain service (`SecItemKeychain.local`), and
/// write them back as signed out, which the installed app then reads. A Debug build on the
/// Mac therefore keeps everything in `~/Library/Application Support/Day Debug` and never
/// opens the installed app's folder. On the iPhone a Debug build replaces the installed app,
/// so there is nothing to keep apart.
enum BuildFolder {
    static var macFolder: String {
        #if os(macOS) && DEBUG
            DayIdentifiers.macFolder + " Debug"
        #else
            DayIdentifiers.macFolder
        #endif
    }

    static func cache() throws -> CacheDirectory {
        try CacheDirectory.shared(macFolder: macFolder)
    }
}
