import AppKit
import DayCore
import SwiftUI

/// Draws the Mac app's own views to PNG files for tools/screenshots.sh, on the invented
/// fixture with a fixed clock, in light and dark. Launched with `-ShotsTo <folder>`; it writes
/// `done.txt` (file, tab, caption per line) last and quits.
///
/// It runs as an accessory app and places every window off every screen, so nothing shows on
/// the desktop and it works while the Mac is locked, when nothing on screen can be captured.
/// Each window draws itself into a bitmap; a sheet or popover is drawn into the same picture
/// at its place beside its window. What the window server composites on its own, glass and
/// window shadows, is not in these pictures.
@main
struct MacShots {
    @MainActor private static var delegate: ShotsDelegate?

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ShotsDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class ShotsDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await Shots().run()
            NSApp.terminate(nil)
        }
    }
}

@MainActor
final class Shots {
    enum Look: String, CaseIterable {
        case light, dark

        var appearance: NSAppearance? {
            NSAppearance(named: self == .dark ? .darkAqua : .aqua)
        }
    }

    private var folder = URL(fileURLWithPath: NSTemporaryDirectory())
    private var done: [String] = []
    /// Kept until the run ends: a window released while SwiftUI still updates it crashes.
    private var windows: [NSWindow] = []

    func run() async {
        guard let path = UserDefaults.standard.string(forKey: "ShotsTo") else { return }
        folder = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Accent colors (switches, the tint on text buttons) draw only in the active app. No
        // window is on a screen, so activating shows nothing; the app that was in front gets
        // its place back when this one quits.
        NSApp.activate(ignoringOtherApps: true)
        for look in Look.allCases {
            NSApp.appearance = look.appearance
            await window(look)
            await narrowWindow(look)
            await firstRun(look)
            await menuBar(look)
            await settings(look)
        }
        try? done.joined(separator: "\n").appending("\n")
            .write(to: folder.appending(path: "done.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Main window

    private func window(_ look: Look) async {
        let store = Self.store(at: "12:10")
        let state = MacState(store: store)
        let window = host(
            MainWindow(state: state, login: OpenAtLogin()).calendarStore(store),
            size: CGSize(width: 1080, height: 720), look: look, chrome: true)
        window.title = state.title
        await settle(2.5)
        if UserDefaults.standard.bool(forKey: "ShotsDump") { dump(window) }
        let pane = { () -> AnyView in
            AnyView(
                DayView(
                    day: state.day, selection: .constant(state.selectedEvent),
                    presented: .constant(nil)
                )
                .calendarStore(store))
        }
        await save(
            window, as: "window-\(look)",
            "Window at 12:10: Month with today selected and the day pane (\(look))", pane: pane)

        // A real popover would be placed on a screen, which is the desktop; its content is
        // drawn here instead, beside the selected row, on the side the app opens it.
        if let call = store.dayEvents(store.today).first(where: { $0.title == "Investor call" }) {
            state.selectedEvent = call.id
            await settle(1.2)
            let symbols = Self.symbols(for: store)
            let popover = host(
                EventPopover(event: call).calendarStore(store).calendarSymbols(symbols)
                    .background(Color(nsColor: .windowBackgroundColor)),
                size: NSHostingView(
                    rootView: EventPopover(event: call).calendarStore(store).calendarSymbols(symbols)
                ).fittingSize,
                look: look, chrome: false)
            await settle(1)
            await save(
                window, as: "popover-\(look)",
                "Event popover for Investor call, beside its row in the day pane, each calendar with its symbol (\(look))",
                pane: pane, beside: popover)
            close(popover)
            state.selectedEvent = nil
        }

        state.showsGoToDate = true
        await settle(1.5)
        await save(window, as: "go-to-date-\(look)", "Go to Date… sheet (\(look))", pane: pane)
        state.showsGoToDate = false
        await settle(1)

        state.goTo(CivilDate(year: 2026, month: 11, day: 23))
        window.title = state.title
        await settle(1.5)
        await save(
            window, as: "window-berlin-\(look)",
            "Window with 23 November selected: Berlin, day 1 of 3 (\(look))", pane: pane)

        state.goTo(CivilDate(year: 2026, month: 12, day: 1))
        window.title = state.title
        await settle(1.5)
        await save(
            window, as: "window-december-\(look)",
            "December with 1 December selected: Copenhagen continues from November, day 4 of 5 (\(look))",
            pane: pane)
        close(window)
    }

    /// The window near its smallest, where the Month keeps about 60 pt a day beside the pane.
    private func narrowWindow(_ look: Look) async {
        let store = Self.store(at: "12:10")
        let state = MacState(store: store)
        let window = host(
            MainWindow(state: state, login: OpenAtLogin()).calendarStore(store)
                .calendarSymbols(Self.symbols(for: store)),
            size: CGSize(width: 760, height: 520), look: look, chrome: true)
        window.title = state.title
        await settle(2.5)
        let pane = { () -> AnyView in
            AnyView(
                DayView(day: state.day, selection: .constant(nil), presented: .constant(nil))
                    .calendarStore(store))
        }
        await save(
            window, as: "window-narrow-\(look)",
            "Window at 760 by 520, near the 720 by 480 minimum (\(look))", pane: pane)
        close(window)
    }

    /// Symbols on both accounts' main calendars, as the person would choose them: Home on
    /// Personal, Work on you@acme.com. In memory, so nothing is written to this Mac.
    private static func symbols(for store: FixtureStore) -> CalendarSymbols {
        var chosen: [CalendarID: CalendarSymbol] = [:]
        for info in store.calendars {
            if info.id.googleID == "you@gmail.com" { chosen[info.id] = CalendarSymbol.named("house") }
            if info.id.googleID == "you@acme.com" { chosen[info.id] = CalendarSymbol.named("briefcase") }
        }
        return CalendarSymbols(chosen)
    }

    /// The small fixed window the app opens before any account exists, and again when every
    /// account is signed out. The signed-out list is a grouped `Form`, which this renderer
    /// draws blank inside a titled window, so that one is drawn without the title bar.
    private func firstRun(_ look: Look) async {
        let shots: [(FixtureStore.State, String, String, Bool)] = [
            (.noAccount, "first-run", "First run: 420 by 360, fixed, with Open at login under the note", true),
            (.allSignedOut, "first-run-signed-out", "Every account signed out: the small window again, Sign In Again… beside each, drawn without its title bar", false),
        ]
        for (fixtureState, name, caption, chrome) in shots {
            let store = Self.store(at: "12:10", state: fixtureState)
            let state = MacState(store: store)
            let window = host(
                MainWindow(state: state, login: OpenAtLogin()).calendarStore(store),
                size: FirstRunWindow.size, look: look, chrome: chrome)
            window.title = "Day"
            await settle(1.5)
            await save(window, as: "\(name)-\(look)", "\(caption) (\(look))")
            close(window)
        }
    }

    // MARK: Menu bar

    private func menuBar(_ look: Look) async {
        let labels = [
            ("12:10", "Quiet: the next event today is more than 15 minutes away"),
            ("13:48", "Within 15 minutes"),
            ("14:12", "In progress"),
            ("14:42", "In progress, two at once: the one that started last"),
            ("17:30", "After the last event: the symbol alone"),
        ]
        for (clock, words) in labels {
            let store = Self.store(at: clock)
            let strip = HStack {
                Spacer()
                MenuBarLabelView()
                    .calendarStore(store)
                    .font(.system(size: NSFont.systemFontSize(for: .regular)))
                    .padding(.horizontal, 10)
            }
            .frame(width: 360, height: 24)
            .background(Color(nsColor: .windowBackgroundColor))
            let window = host(strip, size: CGSize(width: 360, height: 24), look: look, chrome: false)
            await settle(0.6)
            let name = "label-\(clock.replacingOccurrences(of: ":", with: ""))-\(look)"
            await save(window, as: name, "Menu bar label at \(clock). \(words) (\(look))")
            close(window)
        }

        for (clock, words) in [("12:10", "at 12:10"), ("13:55", "at 13:55, with Join in its 10-minute window")] {
            let store = Self.store(at: clock)
            let state = MacState(store: store)
            let panel = MenuBarPanel(state: state).calendarStore(store)
            let size = NSHostingView(rootView: panel).fittingSize
            let window = host(panel, size: size, look: look, chrome: false)
            await settle(1.2)
            await save(window, as: "panel-\(clock.replacingOccurrences(of: ":", with: ""))-\(look)", "Menu bar panel \(words) (\(look))")
            close(window)
        }
    }

    // MARK: Settings

    /// The Settings window as SwiftUI's `Settings` scene builds it: a tab view controller in
    /// toolbar style, one tab per `Tab`, the window titled after the selected one.
    private func settings(_ look: Look) async {
        let store = Self.store(at: "12:10")
        let login = OpenAtLogin()
        let updater = Updater(start: false)
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let accounts = NSTabViewItem(
            viewController: NSHostingController(
                rootView: AccountsView().frame(width: 520, height: 480).calendarStore(store)
                    .calendarSymbols(Self.symbols(for: store))))
        accounts.label = "Accounts"
        accounts.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
        let general = NSTabViewItem(
            viewController: NSHostingController(
                rootView: GeneralSettings(updater: updater, login: login).frame(width: 520, height: 190)))
        general.label = "General"
        general.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        tabs.addTabViewItem(accounts)
        tabs.addTabViewItem(general)

        let window = OffscreenWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.appearance = look.appearance
        place(window)
        window.title = "Accounts"
        await settle(1.2)
        window.toolbar?.selectedItemIdentifier = nil
        await settle(0.5)
        await save(
            window, as: "settings-accounts-\(look)",
            "Settings, Accounts: Personal wears Home, you@acme.com wears Work (\(look))")
        tabs.selectedTabViewItemIndex = 1
        window.title = "General"
        await settle(1.2)
        // The selected tab's glass bezel draws as an opaque white tile outside the window
        // server; without the mark, the window title still names the tab.
        window.toolbar?.selectedItemIdentifier = nil
        await settle(0.5)
        if UserDefaults.standard.bool(forKey: "ShotsDump") { dump(window) }
        await save(window, as: "settings-general-\(look)", "Settings, General (\(look))")
        close(window)
    }

    // MARK: Windows

    private static func store(at clock: String, state: FixtureStore.State = .normal) -> FixtureStore {
        let store = FixtureStore(state: state)
        if let now = FixtureStore.parseNow("2026-11-04T\(clock)", calendar: store.calendar) {
            store.now = now
        }
        return store
    }

    private func host(_ view: some View, size: CGSize, look: Look, chrome: Bool) -> NSWindow {
        // Drawn as the window in front: an accessory app that never activates would
        // otherwise draw every control in its inactive gray.
        let controller = NSHostingController(
            rootView: AnyView(view.environment(\.controlActiveState, .key)))
        if chrome {
            // The window's title and toolbar come from the view, as in a SwiftUI scene.
            controller.sceneBridgingOptions = [.title, .toolbars]
        }
        let window = OffscreenWindow(contentViewController: controller)
        window.styleMask =
            chrome
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.borderless]
        if chrome {
            window.toolbarStyle = .unified
        }
        window.appearance = look.appearance
        window.setContentSize(size)
        place(window)
        return window
    }

    private func place(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The window with its sheets, in one picture. `pane` is the view inside the window's
    /// large glass pane, drawn again on a flat ground because glass and the vibrant colors
    /// inside it only exist in the window server. `beside` is drawn to the leading side of
    /// the pane's selected row, where the app opens its popover.
    private func save(
        _ window: NSWindow, as name: String, _ caption: String,
        pane: (() -> AnyView)? = nil, beside: NSWindow? = nil
    ) async {
        let extras = NSApp.windows.filter { other in
            other !== window && other.isVisible && window.sheets.contains(other)
        }
        var panes: [(NSRect, NSWindow)] = []
        if let pane, let root = window.contentView?.superview {
            let top = window.frame.height - window.contentLayoutRect.height
            for glass in glassPanes(in: root) {
                var rect = glass.convert(glass.bounds, to: nil)
                rect.size.height -= top
                let hosted = host(
                    pane().background(Color(nsColor: .windowBackgroundColor)),
                    size: rect.size, look: window.appearance?.name == .darkAqua ? .dark : .light,
                    chrome: false)
                panes.append((rect, hosted))
            }
            await settle(1.2)
        }
        guard let png = composite(window, extras, panes: panes, beside: beside) else { return }
        let file = "\(name).png"
        try? png.write(to: folder.appending(path: file), options: .atomic)
        done.append("\(file)\t\(caption)")
    }

    private func composite(
        _ base: NSWindow, _ extras: [NSWindow], panes: [(NSRect, NSWindow)], beside: NSWindow?
    ) -> Data? {
        let all = [base] + extras
        let union = all.map(\.frame).reduce(base.frame) { $0.union($1) }
        let scale = max(base.backingScaleFactor, 2)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(union.width * scale),
                pixelsHigh: Int(union.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return nil }
        rep.size = union.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let baseOrigin = NSPoint(x: base.frame.minX - union.minX, y: base.frame.minY - union.minY)
        var row: NSRect?
        for window in all {
            guard let drawn = bitmap(window) else { continue }
            let origin = NSPoint(x: window.frame.minX - union.minX, y: window.frame.minY - union.minY)
            drawn.draw(in: NSRect(origin: origin, size: window.frame.size))
            guard window === base else { continue }
            for (rect, hosted) in panes {
                let target = rect.offsetBy(dx: origin.x, dy: origin.y)
                // The glass placeholder reaches a point past the pane on each side.
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                }
                NSRect(
                    x: target.minX - 2, y: target.minY, width: target.width + 4,
                    height: window.frame.height - rect.minY
                ).fill()
                bitmap(hosted)?.draw(in: target)
                if let selected = selectedRow(in: hosted) {
                    row = selected.offsetBy(dx: target.minX, dy: target.minY)
                }
            }
            // The title bar's scroll edge is drawn by the window server, so weeks scrolled
            // under the toolbar would show through its title. It gets a flat ground, as the
            // hard scroll edge the app asks for gives it.
            if !panes.isEmpty, let content = window.contentView, let root = content.superview,
                let bar = first(named: "NSTitlebarContainerView", in: root)
            {
                content.isHidden = true
                let chrome = snapshot(root)
                content.isHidden = false
                let rect = bar.convert(bar.bounds, to: nil).offsetBy(dx: origin.x, dy: origin.y)
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                }
                rect.fill()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: rect).addClip()
                chrome?.draw(in: NSRect(origin: origin, size: window.frame.size))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if let beside, let drawn = bitmap(beside), let row {
            let size = beside.frame.size
            var frame = NSRect(
                x: row.minX - size.width - 8, y: row.midY - size.height / 2,
                width: size.width, height: size.height)
            frame.origin.y = min(max(frame.minY, baseOrigin.y + 8), baseOrigin.y + base.frame.height - 60 - size.height)
            let shape = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            drawn.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
            base.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.separatorColor.setStroke()
            }
            shape.lineWidth = 1
            shape.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// `-ShotsDump YES` writes the window's view tree, which is where to look when AppKit
    /// changes how it builds glass and a picture shows a placeholder again.
    private func dump(_ window: NSWindow) {
        var text = ""
        func walk(_ view: NSView, _ depth: Int) {
            let sublayers = (view.layer?.sublayers ?? []).map { "\(type(of: $0))\($0.isHidden ? "(hidden)" : "")" }
            text += String(repeating: "  ", count: depth)
                + "\(type(of: view)) \(view.frame) hidden=\(view.isHidden) layer=\(view.layer.map { String(describing: type(of: $0)) } ?? "-") sub=\(sublayers)\n"
            for child in view.subviews { walk(child, depth + 1) }
        }
        if let root = window.contentView?.superview { walk(root, 0) }
        try? text.write(to: folder.appending(path: "dump.txt"), atomically: true, encoding: .utf8)
    }

    private func glassPanes(in view: NSView) -> [NSView] {
        if String(describing: type(of: view)).contains("GlassEffectView"),
            view.bounds.width > 120, view.bounds.height > 120
        {
            return [view]
        }
        return view.subviews.flatMap { glassPanes(in: $0) }
    }

    /// The selected row of the day pane's list, in window coordinates.
    private func selectedRow(in window: NSWindow) -> NSRect? {
        func find(_ view: NSView) -> NSView? {
            if let row = view as? NSTableRowView, row.isSelected { return row }
            for child in view.subviews {
                if let found = find(child) { return found }
            }
            return nil
        }
        guard let root = window.contentView?.superview, let row = find(root) else { return nil }
        return row.convert(row.bounds, to: nil)
    }

    /// The window as AppKit draws it. Glass and backdrop blurs are hidden while it draws:
    /// outside the window server they are opaque placeholders over what is under them.
    private func bitmap(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        return snapshot(view)
    }

    private func first(named name: String, in view: NSView) -> NSView? {
        if String(describing: type(of: view)) == name { return view }
        for child in view.subviews {
            if let found = first(named: name, in: child) { return found }
        }
        return nil
    }

    private func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        let glass = allGlass(in: view).filter { !$0.isHidden }
        glass.forEach { $0.isHidden = true }
        view.cacheDisplay(in: view.bounds, to: rep)
        glass.forEach { $0.isHidden = false }
        return rep
    }

    private func allGlass(in view: NSView) -> [NSView] {
        let name = String(describing: type(of: view))
        let backdrop = view.layer.map { String(describing: type(of: $0)).contains("Backdrop") } ?? false
        if name.contains("GlassEffectView") || name == "NSGlassView" || backdrop { return [view] }
        return view.subviews.flatMap { allGlass(in: $0) }
    }
}

/// A window that stays where it is put, off every screen. AppKit otherwise moves a titled
/// window back onto a screen when it is ordered in.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Drawn as the window in front: controls in an inactive window draw gray, and an
    /// accessory app that never activates would otherwise show every window that way.
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
