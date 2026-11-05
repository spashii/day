import Foundation

/// The Lock Screen widget's WidgetKit push token, from the extension's push handler.
public enum WidgetPushToken {
    /// Keeps `token` in the App Group for the app to send with its own, and tells the relay
    /// at once when the app has registered this install, so a widget added while the app
    /// stays closed still gets its pushes. Nil means the widget is on no Lock Screen any
    /// more, which clears the relay's copy. Best effort: the app sends the saved token again
    /// on its next registration.
    public static func publish(
        _ token: Data?, store: PushStore, environment: PushEnvironment,
        server: PushServer = PushServer()
    ) async {
        let hex = token?.hexString
        store.saveWidgetToken(hex)
        guard store.state().registered != nil, let install = store.existingInstall() else {
            return
        }
        let registration = PushRegistration(
            install: install, platform: .ios, environment: environment, app: .keep,
            widget: hex.map(PushRegistration.Token.set) ?? .clear)
        _ = try? await server.register(registration)
    }
}
