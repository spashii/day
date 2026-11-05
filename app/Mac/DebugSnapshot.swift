#if DEBUG
    import AppKit
    import DayCore
    import SwiftUI

    /// Draws the app's own windows to PNG files, for checking the Mac app without a display
    /// session. A Mac that is locked or asleep cannot be captured from outside
    /// (`screencapture` fails and System Events sees no windows), and a build check over SSH
    /// is exactly that. Debug builds only: a release has no reason to look at itself.
    ///
    /// - `-SnapshotTo <folder>` writes every window twice a second, named after its title.
    /// - `-SnapshotScript "step; step"` runs steps once the window is up, one per second:
    ///   `today`, `date:2026-11-12`, `day:+1`, `week:+1`, `month:+1`, `pane:hide`, `pane:show`,
    ///   `event:next`, `event:prev`, `event:show`, `gotodate`,
    ///   `settings`, `settings:general`, `panel`, `addaccount` (the fixture's next account,
    ///   as if Google's sheet had finished), `close` (closes the main window),
    ///   `open:day://day/2026-11-12` (the URL through Launch Services, as a widget click),
    ///   `dump:<name>` (windows and menus to
    ///   `dump-<name>.txt`), `snap:<name>` (copies the windows to `<name>-<title>.png`) and
    ///   `quit`.
    /// - `-SnapshotHidden YES` keeps the app out of sight while it draws: no Dock icon and
    ///   windows with no opacity, so a run beside the Day in use shows nothing on its screen.
    @MainActor
    enum DebugSnapshot {
        private static var timer: Timer?
        private static var activity: (any NSObjectProtocol)?

        static func startIfRequested() {
            guard let folder = UserDefaults.standard.string(forKey: "SnapshotTo") else { return }
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // A window nobody can see lets the app nap, which would stop the timer.
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "Writing window snapshots")
            if UserDefaults.standard.bool(forKey: "SnapshotHidden") {
                NSApp.setActivationPolicy(.accessory)
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didUpdateNotification, object: nil, queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        for window in NSApp.windows { window.alphaValue = 0 }
                    }
                }
            }
            let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { write(to: url, prefix: nil) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer

            if let script = UserDefaults.standard.string(forKey: "SnapshotScript") {
                let steps = script.split(separator: ";").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    for step in steps {
                        run(step, folder: url)
                        try? await Task.sleep(for: .milliseconds(1200))
                    }
                }
            }
        }

        private static func run(_ step: String, folder: URL) {
            let state = MacLaunch.shared.state
            let (name, argument) = step.split(separator: ":", maxSplits: 1).map(String.init)
                .pair
            switch name {
            case "today": state.goToToday()
            case "date":
                if let day = argument.flatMap({ CivilDate($0) }) { state.goTo(day) }
            case "day": state.move(days: Int(argument ?? "1") ?? 1)
            case "week": state.move(days: 7 * (Int(argument ?? "1") ?? 1))
            case "month": state.moveMonth(by: Int(argument ?? "1") ?? 1)
            case "pane": state.showsDayPane = argument != "hide"
            case "event":
                switch argument {
                case "next": state.moveEvent(by: 1)
                case "prev": state.moveEvent(by: -1)
                default: state.showEvent()
                }
            case "gotodate": state.showsGoToDate = true
            case "addaccount": (MacLaunch.shared.store as? FixtureStore)?.addNextAccount()
            case "settings":
                state.settingsTab = argument == "general" ? .general : .accounts
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            case "tab": state.settingsTab = argument == "general" ? .general : .accounts
            case "panel": clickStatusItem()
            case "snap": write(to: folder, prefix: argument ?? "snap")
            case "dump":
                let scroll = state.scroll
                var text = "pane=\(state.showsDayPane) day=\(state.day.isoString)\n"
                text += "page=\(scroll.shown(today: state.store.today).isoString)\n"
                NSApp.mainMenu?.update()
                for item in NSApp.mainMenu?.items ?? [] {
                    let entries = (item.submenu?.items ?? []).map {
                        ($0.isSeparatorItem ? "-" : "\($0.title)[\($0.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) })\($0.keyEquivalentModifierMask.rawValue)\($0.isEnabled ? "" : " off")]") + ($0.isHidden ? "(hid)" : "")
                    }
                    text += "menu \(item.title) hidden=\(item.isHidden): \(entries.joined(separator: " | "))\n"
                }
                for window in NSApp.windows {
                    text += "\(type(of: window)) \"\(window.title)\" visible=\(window.isVisible) frame=\(window.frame) min=\(window.minSize) max=\(window.maxSize) resizable=\(window.styleMask.contains(.resizable)) zoomable=\(window.standardWindowButton(.zoomButton)?.isEnabled ?? false) screen=\(window.screen?.visibleFrame ?? .zero)\n"
                }
                try? text.write(to: folder.appending(path: "dump-\(argument ?? "x").txt"), atomically: true, encoding: .utf8)
            case "close":
                for window in NSApp.windows where window.title.contains("2026") { window.close() }
            case "open":
                // Through Launch Services to this copy of the app, the way a click on the
                // desktop widget arrives, so the URL handling runs as it does for real.
                if let url = argument.flatMap({ URL(string: $0) }) {
                    NSWorkspace.shared.open(
                        [url], withApplicationAt: Bundle.main.bundleURL,
                        configuration: NSWorkspace.OpenConfiguration())
                }
            case "quit": NSApp.terminate(nil)
            default: break
            }
        }

        /// Opens the menu bar panel the way a click on the item does.
        private static func clickStatusItem() {
            for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
                if let button = window.contentView.flatMap({ find(NSStatusBarButton.self, in: $0) }) {
                    button.performClick(nil)
                    return
                }
            }
        }

        private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for child in view.subviews {
                if let match = find(type, in: child) { return match }
            }
            return nil
        }

        private static func write(to folder: URL, prefix: String?) {
            for window in NSApp.windows {
                guard let frame = window.contentView?.superview ?? window.contentView,
                    frame.bounds.width > 100,
                    let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
                else { continue }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                var name = (window.title.isEmpty ? String(describing: type(of: window)) : window.title)
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: " ", with: "_")
                if let prefix { name = "\(prefix)-\(name)" }
                try? png.write(to: folder.appending(path: "\(name).png"), options: .atomic)
            }
        }
    }

    extension Array where Element == String {
        fileprivate var pair: (String, String?) {
            (first ?? "", count > 1 ? self[1] : nil)
        }
    }
#endif
