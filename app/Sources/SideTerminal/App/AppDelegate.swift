import AppKit
import Combine
import SwiftUI
import OSLog
import GhosttyKit
import SideTerminalCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.sideterminal.app",
        category: "app"
    )

    /// The Ghostty global runtime state. The terminal engine is pure Ghostty;
    /// SideTerminal only reshapes the windowing experience around it.
    /// nonisolated(unsafe): the vendored layer reads this from callbacks that
    /// always run on the main thread but aren't statically main-actor.
    nonisolated(unsafe) private(set) var ghostty: Ghostty.App!

    /// Global undo manager, referenced by the vendored Ghostty layer.
    let undoManager = ExpiringUndoManager()

    private(set) var sidebar: SidebarController!
    private var menuBar: MenuBarController!
    private var settingsWindow: SettingsWindowController?
    private var hotKey: GlobalHotKey?
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObserver: NSKeyValueObservation?

    let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock presence is the user's choice; the app works either way.
        applyActivationPolicy()

        // Feed Ghostty a config generated from our settings.
        let configPath = settings.writeTerminalConfig()
        ghostty = Ghostty.App(configPath: configPath)
        ghostty.delegate = self

        sidebar = SidebarController(ghostty: ghostty, settings: settings)
        menuBar = MenuBarController(delegate: self)

        applyTheme()
        registerHotKey()
        observeSettings()
        settings.reconcileLaunchAtLogin()

        // Report the effective appearance to libghostty so conditional
        // themes (theme = light:…,dark:…) resolve — and re-resolve live
        // when the appearance changes.
        appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new, .initial]
        ) { [weak self] _, change in
            guard let appearance = change.newValue,
                  let app = self?.ghostty.app else { return }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ghostty_app_set_color_scheme(
                app,
                isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            )
            // Surfaces track their own conditional state; without this the
            // terminal keeps its old light/dark resolution forever.
            DispatchQueue.main.async { self?.sidebar?.syncColorScheme() }
        }

        installControlChannel()

        // Reveal on first launch so the user discovers the interaction, and
        // on later launches restore how they left it.
        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: "internal.hasLaunchedBefore")
        defaults.set(true, forKey: "internal.hasLaunchedBefore")
        let shouldReveal = firstLaunch ||
            (settings.restoreSession && defaults.bool(forKey: "internal.wasVisible"))
        if shouldReveal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.sidebar.reveal(reason: .manual)
            }
        }
    }

    /// Scriptable control: `sideterminalctl show|hide|toggle|settings|restart`.
    /// Posts arrive over DistributedNotificationCenter so power users can
    /// drive the sidebar from scripts and hotkey daemons.
    private func installControlChannel() {
        let center = DistributedNotificationCenter.default()
        let commands: [(String, Selector)] = [
            ("com.sideterminal.control.show", #selector(showSidebar)),
            ("com.sideterminal.control.hide", #selector(hideSidebar)),
            ("com.sideterminal.control.toggle", #selector(toggleSidebar)),
            ("com.sideterminal.control.settings", #selector(openSettings)),
            ("com.sideterminal.control.restart", #selector(restartSession)),
            ("com.sideterminal.control.status", #selector(dumpStatus)),
            ("com.sideterminal.control.dumptext", #selector(dumpScreenText)),
            ("com.sideterminal.control.newsession", #selector(newSessionFromControl)),
        ]
        for (name, selector) in commands {
            center.addObserver(self, selector: selector, name: .init(name), object: nil)
        }

        // Generic setter for scripted testing: object string is "key=value",
        // e.g. "theme=dark". Runs through the same published-property path
        // the Settings UI uses.
        center.addObserver(
            forName: .init("com.sideterminal.control.set"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.object as? String,
                  let eq = raw.firstIndex(of: "=") else { return }
            let key = String(raw[..<eq])
            let value = String(raw[raw.index(after: eq)...])
            MainActor.assumeIsolated {
                self?.applyScriptedSetting(key: key, value: value)
            }
        }

        installTestChannel(center)
    }

    private func applyScriptedSetting(key: String, value: String) {
        switch key {
        case "theme":
            if let theme = AppTheme(rawValue: value) { settings.theme = theme }
        case "edge":
            if let edge = SidebarEdge(rawValue: value) { settings.edge = edge }
        case "opacity":
            if let v = Double(value) { settings.backgroundOpacity = v }
        case "fontSize":
            if let v = Double(value) { settings.fontSize = v }
        case "width":
            if let v = Double(value) { settings.sidebarWidth = v }
        case "menubar":
            settings.showMenuBarIcon = (value == "true" || value == "on")
        case "dock":
            settings.showInDock = (value == "true" || value == "on")
        default:
            Self.logger.warning("unknown scripted setting \(key, privacy: .public)")
        }
    }

    /// Scripted-test hooks: type text / press keys / read the screen.
    private func installTestChannel(_ center: DistributedNotificationCenter) {
        center.addObserver(forName: .init("com.sideterminal.control.type"), object: nil, queue: .main) { [weak self] note in
            guard let text = note.object as? String else { return }
            MainActor.assumeIsolated { self?.sidebar.typeText(text) }
        }
        center.addObserver(forName: .init("com.sideterminal.control.key"), object: nil, queue: .main) { [weak self] note in
            guard let name = note.object as? String else { return }
            MainActor.assumeIsolated { self?.sidebar.sendKey(name) }
        }
    }

    @objc func dumpScreenText() {
        try? sidebar.screenText().write(
            toFile: NSTemporaryDirectory() + "/sideterminal-screen.txt",
            atomically: true,
            encoding: .utf8
        )
    }

    @objc func newSessionFromControl() {
        sidebar.newSession()
    }

    /// Diagnostic snapshot used by scripted verification.
    @objc func dumpStatus() {
        let s = sidebar.diagnosticDescription()
        Self.logger.notice("status: \(s, privacy: .public)")
        try? s.write(
            toFile: NSTemporaryDirectory() + "/sideterminal-status.txt",
            atomically: true,
            encoding: .utf8
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        sidebar?.persistState()
    }

    /// Launching the app while it's already running (Dock click, Spotlight,
    /// Launchpad) brings up the sidebar — and Settings too when the menu
    /// bar icon is hidden, so there is always a way back in.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        sidebar.reveal(reason: .manual)
        if !settings.showMenuBarIcon {
            openSettings()
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    // MARK: Settings observation

    private func observeSettings() {
        // Discrete choices must land the instant they're picked — a theme
        // switch that lags behind the settings panel reads as broken.
        let immediate: [AnyPublisher<Void, Never>] = [
            settings.$theme.dropFirst().map { _ in }.eraseToAnyPublisher(),
            settings.$edge.dropFirst().map { _ in }.eraseToAnyPublisher(),
            settings.$cursorStyle.dropFirst().map { _ in }.eraseToAnyPublisher(),
            settings.$autoHide.dropFirst().map { _ in }.eraseToAnyPublisher(),
            settings.$alwaysOnTop.dropFirst().map { _ in }.eraseToAnyPublisher(),
            settings.$showMenuBarIcon.dropFirst().map { _ in }.eraseToAnyPublisher(),
            settings.$showInDock.dropFirst().map { _ in }.eraseToAnyPublisher(),
            settings.$globalShortcut.dropFirst().map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(immediate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.applySettings()
            }
            .store(in: &cancellables)

        // Continuous controls (sliders, text fields) batch briefly so a drag
        // doesn't thrash config reloads.
        settings.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.applySettings()
            }
            .store(in: &cancellables)
    }

    /// Push current settings into the live app: regenerate the Ghostty
    /// config, reload it, and let the sidebar restyle itself.
    private func applySettings() {
        // Lockout guard: hiding the menu bar icon needs another way back in
        // — a working shortcut or the Dock icon. With neither, keep the
        // icon. (Re-entry is safe: the second pass sees a visible icon.)
        if !settings.showMenuBarIcon,
           !settings.showInDock,
           HotKeySpec(string: settings.globalShortcut) == nil {
            settings.showMenuBarIcon = true
        }

        settings.writeTerminalConfig()
        reloadTerminalConfig()
        applyTheme()
        applyActivationPolicy()
        registerHotKey()
        menuBar.updateVisibility()
        sidebar.settingsDidChange()
    }

    /// Show or remove the Dock icon live.
    private func applyActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy =
            settings.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
        }
    }

    private func applyTheme() {
        NSApp.appearance = settings.theme.appearance
    }

    func reloadTerminalConfig() {
        // Hard reload: re-reads the generated config file from disk.
        ghostty.reloadConfig()
    }

    private func registerHotKey() {
        hotKey = nil
        guard let spec = HotKeySpec(string: settings.globalShortcut) else { return }
        hotKey = GlobalHotKey(spec: spec) { [weak self] in
            self?.toggleSidebar()
        }
    }

    /// Can this combo be claimed system-wide right now? Our own current
    /// registration is released around the probe so re-recording the same
    /// shortcut doesn't read as "taken by another app".
    func testShortcutAvailability(_ spec: HotKeySpec) -> Bool {
        hotKey = nil
        let available = GlobalHotKey.isAvailable(spec)
        registerHotKey()
        return available
    }

    // MARK: Actions

    @objc func toggleSidebar() {
        sidebar.toggle(reason: .manual)
    }

    @objc func showSidebar() {
        sidebar.reveal(reason: .manual)
    }

    @objc func hideSidebar() {
        sidebar.hide(reason: .manual)
    }

    @objc func restartSession() {
        sidebar.restartSession()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings)
        }
        settingsWindow?.show()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Hooks called by the vendored Ghostty layer
    //
    // These are invoked from contexts the compiler can't prove are
    // main-actor, but libghostty delivers its app callbacks on the main
    // thread, so we assume isolation and hop on.

    /// The vendored Ghostty layer calls this for the quick-terminal action;
    /// in SideTerminal the sidebar *is* the quick terminal.
    nonisolated func toggleQuickTerminal(_ sender: Any) {
        DispatchQueue.main.async { [weak self] in self?.toggleSidebar() }
    }

    private lazy var menuShortcutManager = Ghostty.MenuShortcutManager()

    nonisolated func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool {
        MainActor.assumeIsolated {
            menuShortcutManager.performGhosttyBindingMenuKeyEquivalent(with: event)
        }
    }

    nonisolated func setSecureInput(_ mode: Ghostty.SetSecureInput) {
        MainActor.assumeIsolated {
            let input = SecureInput.shared
            switch mode {
            case .on: input.global = true
            case .off: input.global = false
            case .toggle: input.global.toggle()
            }
        }
    }

    /// "Close all windows" in a single-panel app means hide the sidebar.
    nonisolated func closeAllWindows(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in self?.hideSidebar() }
    }

    nonisolated func toggleVisibility(_ sender: Any) {
        DispatchQueue.main.async { [weak self] in self?.toggleSidebar() }
    }

    /// No update framework is bundled; updates arrive with the app.
    nonisolated func checkForUpdates(_ sender: Any?) {}

    /// SideTerminal has no float-on-top menu to synchronize.
    nonisolated func syncFloatOnTopMenu(_ window: NSWindow?) {}
}

// MARK: GhosttyAppDelegate

extension AppDelegate: GhosttyAppDelegate {
    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        sidebar?.surfaceView(id: uuid)
    }
}
