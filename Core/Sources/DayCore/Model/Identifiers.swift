import Foundation

/// Names shared by the apps, the widget and Core. `app/project.yml` repeats the bundle
/// identifiers, App Group, URL scheme and task identifier; change both together.
public enum DayIdentifiers {
    public static let bundleID = "io.github.spashii.day"
    public static let widgetBundleID = "io.github.spashii.day.widget"
    public static let appGroup = "group.io.github.spashii.day"
    public static let urlScheme = "day"
    /// The Lock Screen widget's kind, shown in the gallery as "Next".
    public static let widgetKind = "Next"
    /// Keychain service for the per-account token items.
    public static let keychainService = "io.github.spashii.day.google"
    /// The `BGAppRefreshTask` identifier.
    public static let refreshTask = "io.github.spashii.day.refresh"
    /// Info.plist key holding the Google OAuth client ID.
    public static let googleClientIDKey = "GoogleClientID"
    /// The value project.yml ships until a Google OAuth client exists. While it is set the
    /// apps run on the fixture, because signing in cannot work.
    public static let googleClientPlaceholder =
        "000000000000-placeholder.apps.googleusercontent.com"
}
