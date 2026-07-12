import AppKit
import Combine
import GhosttyKit

/// Owns the sidebar panel, the persistent terminal surface, and the
/// reveal/hide behavior. The terminal session lives here for the entire app
/// lifetime — hiding the sidebar never touches the pty.
@MainActor
final class SidebarController: NSObject {
    enum State {
        case hidden
        case revealing
        case shown
        case hiding
    }

    enum Reason {
        case edge      // pointer touched the screen edge
        case manual    // menu item, hotkey, or first-launch hello
    }

    private(set) var state: State = .hidden

    private let ghostty: Ghostty.App
    private let settings: AppSettings

    private let panel = SidebarPanel()
    private let card = SidebarCardView()
    private var animator: SidebarAnimator!
    private let edgeMonitor = EdgeMonitor()
    private let resizeHandle = SidebarResizeHandle()

    /// The handle's active constraints; the edge pins are installed on the
    /// container, so they must be deactivated explicitly on relayout.
    private var resizeHandleConstraints: [NSLayoutConstraint] = []

    /// Always-available Settings access on the card itself, so hiding the
    /// menu bar icon can never lock the user out.
    private let settingsButton = HoverButton()
    private var settingsButtonConstraints: [NSLayoutConstraint] = []

    /// The persistent terminal surface. Recreated only on explicit restart
    /// or when the child process exits.
    private var surface: Ghostty.SurfaceView?

    /// Screen the sidebar currently lives on.
    private var activeScreen: NSScreen?

    /// Tracks the shell's pwd for workspace restoration.
    private var pwdObserver: AnyCancellable?

    // MARK: Hide heuristics

    private var hideTimer: Timer?
    private var pointerTracker: Timer?
    private var localEventMonitor: Any?
    private var lastKeyEventAt: TimeInterval = 0
    private var lastScrollEventAt: TimeInterval = 0
    private var mouseIsDownInPanel = false
    private var pointerEnteredSinceReveal = false
    private var lastRevealReason: Reason = .manual

    /// Hysteresis margin around the panel before the hide timer arms.
    /// Small enough that leaving feels acknowledged, big enough to forgive
    /// clipping the edge while scrolling.
    private let hideHysteresis: CGFloat = 16

    /// Inset of the floating card from screen edges.
    private let margin: CGFloat = 10

    init(ghostty: Ghostty.App, settings: AppSettings) {
        self.ghostty = ghostty
        self.settings = settings
        super.init()

        animator = SidebarAnimator(card: card)

        let content = NSView()
        content.wantsLayer = true
        panel.contentView = content

        card.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            card.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])

        resizeHandle.onDrag = { [weak self] deltaFromStart, startWidth in
            self?.applyLiveResize(startWidth: startWidth, delta: deltaFromStart)
        }
        resizeHandle.onDragEnded = { [weak self] in
            guard let self else { return }
            self.settings.sidebarWidth = Double(self.panel.frame.width - 2 * self.margin)
        }
        resizeHandle.currentWidth = { [weak self] in
            guard let self else { return 0 }
            return self.panel.frame.width - 2 * self.margin
        }

        // Folder/file drops: a folder cd's the terminal into it; a file (or
        // anything else) inserts its escaped path at the prompt.
        card.onDrop = { [weak self] drop in
            guard let self, let surface = self.surface else { return }
            switch drop {
            case .changeDirectory(let path):
                surface.insertText("cd \(path)\n", replacementRange: NSRange(location: 0, length: 0))
            case .insert(let text):
                surface.insertText(text, replacementRange: NSRange(location: 0, length: 0))
            }
        }

        settingsButton.image = NSImage(
            systemSymbolName: "gearshape.fill",
            accessibilityDescription: "SideTerminal Settings"
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        settingsButton.title = ""
        settingsButton.imagePosition = .imageOnly
        settingsButton.isBordered = false
        settingsButton.bezelStyle = .regularSquare
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.restingAlpha = 0.55
        // The terminal is a layer-hosting Metal view; siblings need an
        // explicit zPosition to composite above it.
        settingsButton.wantsLayer = true
        settingsButton.layer?.zPosition = 100
        settingsButton.target = self
        settingsButton.action = #selector(openSettingsFromCard)
        settingsButton.toolTip = "SideTerminal Settings"
        // The gear is a fallback entrance: it only appears while the menu
        // bar icon is hidden (kept in sync by settingsDidChange).
        settingsButton.isHidden = settings.showMenuBarIcon

        createSurface()
        applyPanelLevel()

        edgeMonitor.onEdgeDwell = { [weak self] screen in
            self?.edgeDwell(on: screen)
        }
        edgeMonitor.edge = settings.edge
        edgeMonitor.revealDelay = settings.revealDelay
        edgeMonitor.start()

        installEventMonitors()
    }

    // MARK: Surface lifecycle

    /// A live terminal session. Shelved sessions keep their surface — and
    /// therefore their pty, running programs, and full scrollback — alive;
    /// switching back is instant and lossless.
    struct TerminalSession {
        let id: UUID
        let view: Ghostty.SurfaceView
        let createdAt: Date
    }

    /// All live sessions in most-recently-used order; the active one is
    /// always last.
    private(set) var sessions: [TerminalSession] = []

    /// Cap on live sessions. Past it the oldest shelved session is torn
    /// down (its deinit closes the pty and frees the terminal state), so
    /// memory stays bounded no matter how many sessions the user spawns.
    private let maxSessions = 10

    private func makeSurfaceView() -> Ghostty.SurfaceView? {
        guard let app = ghostty.app else { return nil }

        var config = Ghostty.SurfaceConfiguration()
        if !settings.workingDirectory.isEmpty {
            config.workingDirectory = settings.workingDirectory
        } else if settings.restoreWorkspace,
                  let saved = UserDefaults.standard.string(forKey: "internal.lastPwd"),
                  FileManager.default.fileExists(atPath: saved) {
            // Come back exactly where the user left off, even across
            // app restarts and reboots.
            config.workingDirectory = saved
        }
        if !settings.startupCommand.isEmpty {
            config.command = settings.startupCommand
        }

        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    /// Put a session's surface on screen and route everything at it.
    private func activate(_ view: Ghostty.SurfaceView) {
        surface?.removeFromSuperview()
        surface = view
        card.embedTerminal(view)

        // The surface would otherwise claim drops itself (inserting the path);
        // let them fall through to the card so a folder drop cd's into it.
        view.unregisterDraggedTypes()

        // Remember the shell's working directory as it changes (shell
        // integration reports it) so the next session can restore it.
        pwdObserver = view.$pwd
            .compactMap { $0 }
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { pwd in
                UserDefaults.standard.set(pwd, forKey: "internal.lastPwd")
            }

        // Keep the resize handle and settings gear above the terminal.
        resizeHandle.removeFromSuperview()
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        card.contentContainer.addSubview(resizeHandle)
        settingsButton.removeFromSuperview()
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(settingsButton, positioned: .above, relativeTo: card.contentContainer)
        layoutResizeHandle()

        // A fresh surface starts with no color scheme; report the current
        // one so conditional themes (light:…,dark:…) resolve immediately.
        syncColorScheme()

        if state == .shown || state == .revealing {
            focusTerminal()
        }
    }

    private func createSurface() {
        guard let view = makeSurfaceView() else { return }
        sessions.append(TerminalSession(id: view.id, view: view, createdAt: Date()))
        activate(view)
        enforceSessionCap()
    }

    /// Shelve the current session (it keeps running) and start a fresh one.
    func newSession() {
        pruneDeadSessions()
        createSurface()
    }

    /// Bring a shelved session back exactly as it was.
    func switchToSession(id: UUID) {
        pruneDeadSessions()
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        sessions.append(session)
        guard session.view !== surface else { return }
        activate(session.view)
    }

    /// A session whose process has exited has nothing to switch back to.
    private func pruneDeadSessions() {
        sessions.removeAll { $0.view !== surface && $0.view.processExited }
    }

    private func enforceSessionCap() {
        while sessions.count > maxSessions {
            // The list is MRU-ordered, so the first entry is the least
            // recently used — and never the active one.
            _ = sessions.removeFirst()
        }
    }

    /// Snapshot for the menu bar's session switcher, newest first.
    struct SessionInfo {
        let id: UUID
        let title: String
        let isActive: Bool
        let createdAt: Date
    }

    func sessionInfos() -> [SessionInfo] {
        pruneDeadSessions()
        return sessions.reversed().map { session in
            var title = session.view.title
            if title.isEmpty {
                title = (session.view.pwd as NSString?)?.abbreviatingWithTildeInPath
                    ?? "Terminal"
            }
            if title.count > 44 {
                title = String(title.prefix(43)) + "…"
            }
            return SessionInfo(
                id: session.id,
                title: title,
                isActive: session.view === surface,
                createdAt: session.createdAt
            )
        }
    }

    /// Report the effective appearance to the live surface. Surfaces keep
    /// their own conditional-config state, so the app-level color scheme
    /// alone never re-themes an existing terminal.
    func syncColorScheme() {
        guard let surfaceHandle = surface?.surface else { return }
        let isDark = NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_surface_set_color_scheme(
            surfaceHandle,
            isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        )
    }

    private func layoutResizeHandle() {
        guard resizeHandle.superview === card.contentContainer else { return }
        // Deactivate the previous set explicitly: the edge pins live on the
        // container, so removeConstraints(resizeHandle.constraints) misses
        // them and an edge flip would pin both sides at width 8 — collapsing
        // the whole panel to a sliver.
        NSLayoutConstraint.deactivate(resizeHandleConstraints)
        let container = card.contentContainer
        var constraints: [NSLayoutConstraint] = [
            resizeHandle.topAnchor.constraint(equalTo: container.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),
        ]
        // The grabbable edge faces the screen center.
        switch settings.edge {
        case .left:
            constraints.append(resizeHandle.trailingAnchor.constraint(equalTo: container.trailingAnchor))
        case .right:
            constraints.append(resizeHandle.leadingAnchor.constraint(equalTo: container.leadingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        resizeHandleConstraints = constraints

        // The gear sits in the top corner facing the screen center, clear
        // of the terminal's first row and the resize strip. It lives on the
        // card, above the clipped content stack, so the Metal-backed
        // terminal can never composite over it.
        if settingsButton.superview === card {
            NSLayoutConstraint.deactivate(settingsButtonConstraints)
            var gear: [NSLayoutConstraint] = [
                settingsButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            ]
            switch settings.edge {
            case .left:
                gear.append(settingsButton.trailingAnchor.constraint(
                    equalTo: card.trailingAnchor, constant: -14))
            case .right:
                gear.append(settingsButton.leadingAnchor.constraint(
                    equalTo: card.leadingAnchor, constant: 14))
            }
            NSLayoutConstraint.activate(gear)
            settingsButtonConstraints = gear
        }
    }

    @objc private func openSettingsFromCard() {
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }

    func surfaceView(id: UUID) -> Ghostty.SurfaceView? {
        sessions.first { $0.view.id == id }?.view
    }

    func restartSession() {
        // Dropping every reference tears the surface (and its pty) down via
        // the vendored SurfaceView's deinit. Only the active session
        // restarts; shelved ones are untouched.
        if let index = sessions.firstIndex(where: { $0.view === surface }) {
            sessions.remove(at: index)
        }
        surface?.removeFromSuperview()
        surface = nil
        createSurface()
    }

    // MARK: Placement

    private var direction: SidebarAnimator.Direction {
        settings.edge == .left ? .fromLeft : .fromRight
    }

    private func targetFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = min(
            max(320, CGFloat(settings.sidebarWidth)),
            visible.width * 0.8
        ) + 2 * margin
        let x: CGFloat
        switch settings.edge {
        case .left: x = visible.minX
        case .right: x = visible.maxX - width
        }
        return NSRect(x: x, y: visible.minY, width: width, height: visible.height)
    }

    private func applyPanelLevel() {
        // "Always on top" means above fullscreen apps and floating windows.
        // .popUpMenu (101) achieves that while staying BELOW the system's
        // drag layer (~500) — .screenSaver (1000) sat above it, which broke
        // drag-and-drop onto the terminal entirely.
        panel.level = settings.alwaysOnTop ? .popUpMenu : .floating
    }

    /// Glass pipeline, mirroring Ghostty's own quick terminal: when the
    /// terminal is translucent the desktop shows through and the Blur
    /// slider drives a real window blur radius (Ghostty reads
    /// background-blur from its live config). The fixed-material effect
    /// view would mask both sliders, so it only stays for the opaque look.
    private func applyGlass() {
        card.effectView.isHidden = settings.backgroundOpacity < 0.999
        guard panel.isVisible, let app = ghostty.app else { return }
        ghostty_set_window_background_blur(app, Unmanaged.passUnretained(panel).toOpaque())
    }

    private func applyLiveResize(startWidth: CGFloat, delta: CGFloat) {
        guard let screen = activeScreen ?? panel.screen else { return }
        let visible = screen.visibleFrame
        let contentDelta = settings.edge == .left ? delta : -delta
        let newWidth = min(max(320, startWidth + contentDelta), visible.width * 0.8)
        var frame = panel.frame
        frame.size.width = newWidth + 2 * margin
        if settings.edge == .right {
            frame.origin.x = visible.maxX - frame.size.width
        }
        panel.setFrame(frame, display: true)
    }

    // MARK: Reveal / hide

    private func edgeDwell(on screen: NSScreen) {
        switch state {
        case .hidden, .hiding:
            reveal(on: screen, reason: .edge)
        case .shown, .revealing:
            break
        }
    }

    func toggle(reason: Reason) {
        switch state {
        case .hidden, .hiding:
            reveal(reason: reason)
        case .shown, .revealing:
            hide(reason: reason)
        }
    }

    func reveal(reason: Reason) {
        let screen = screenForReveal()
        reveal(on: screen, reason: reason)
    }

    private func screenForReveal() -> NSScreen {
        // Prefer the screen the pointer is on; it's where attention is.
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func reveal(on screen: NSScreen, reason: Reason) {
        guard state == .hidden || state == .hiding else { return }

        lastRevealReason = reason
        pointerEnteredSinceReveal = false
        activeScreen = screen

        let frame = targetFrame(on: screen)
        let firstOrder = !panel.isVisible
        panel.setFrame(frame, display: true)

        if firstOrder || state == .hidden {
            animator.prepareHidden(direction: direction)
        }

        state = .revealing
        UserDefaults.standard.set(true, forKey: "internal.wasVisible")
        // Deliberately no NSApp.activate(ignoringOtherApps:) here: while a
        // *different* app owns a fullscreen Space, activating our app would
        // force macOS to switch away from that Space back to the desktop —
        // exactly the "sidebar only shows up on the desktop" bug. The panel
        // is a .nonactivatingPanel, so makeKeyAndOrderFront alone is enough
        // to make it the real key window and receive every keystroke,
        // without moving the user out of whatever Space (fullscreen or not)
        // they're currently on.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        applyGlass()
        focusTerminal()

        animator.reveal(direction: direction, speed: settings.animationSpeed.multiplier) { [weak self] in
            guard let self, self.state == .revealing else { return }
            self.state = .shown
        }

        startPointerTracking()
    }

    func hide(reason: Reason) {
        guard state == .shown || state == .revealing else { return }

        state = .hiding
        UserDefaults.standard.set(false, forKey: "internal.wasVisible")
        cancelHideTimer()
        stopPointerTracking()

        animator.hide(direction: direction, speed: settings.animationSpeed.multiplier) { [weak self] in
            guard let self, self.state == .hiding else { return }
            self.state = .hidden
            self.panel.orderOut(nil)
        }
    }

    // MARK: Intelligent hiding

    private func installEventMonitors() {
        // Local monitor: we only see events routed to our app, i.e. when the
        // panel is key. That is exactly the activity that should keep the
        // sidebar open.
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp,
            .scrollWheel,
        ]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let now = ProcessInfo.processInfo.systemUptime
            switch event.type {
            case .keyDown, .flagsChanged:
                self.lastKeyEventAt = now
            case .scrollWheel:
                self.lastScrollEventAt = now
            case .leftMouseDown, .rightMouseDown:
                self.mouseIsDownInPanel = true
            case .leftMouseUp, .rightMouseUp:
                self.mouseIsDownInPanel = false
            case .leftMouseDragged:
                self.mouseIsDownInPanel = true
            default:
                break
            }
            return event
        }
    }

    private func startPointerTracking() {
        stopPointerTracking()
        // 30 Hz while visible: leaving the panel is acknowledged within a
        // frame or two, so the hide delay is the only intentional wait.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluatePointer() }
        }
        RunLoop.main.add(t, forMode: .common)
        pointerTracker = t
    }

    private func stopPointerTracking() {
        pointerTracker?.invalidate()
        pointerTracker = nil
    }

    private func evaluatePointer() {
        guard state == .shown || state == .revealing else { return }

        let mouse = NSEvent.mouseLocation
        let inside = panel.frame.insetBy(dx: -hideHysteresis, dy: -hideHysteresis)
            .contains(mouse)

        if panel.frame.contains(mouse) {
            pointerEnteredSinceReveal = true
        }

        guard settings.autoHide else { return }

        if inside, settings.keepOpenWhileMouseInside {
            cancelHideTimer()
            return
        }

        // Outside the panel: decide whether hiding is allowed at all.
        if shouldHoldOpen() {
            cancelHideTimer()
            return
        }

        armHideTimer()
    }

    private func shouldHoldOpen() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime

        // Never vanish mid-drag or mid-selection.
        if mouseIsDownInPanel { return true }

        // Recent typing keeps it open — but once the pointer has left the
        // panel, deliberately mousing away should win quickly, so the
        // typing grace shrinks outside.
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        let typingGrace: TimeInterval = inside ? 2.5 : 0.8
        if settings.keepOpenWhileTyping, now - lastKeyEventAt < typingGrace { return true }

        // Recent scrolling counts as engagement.
        if now - lastScrollEventAt < 0.8 { return true }

        // Respect "prevent accidental hiding": a reveal the user never
        // engaged with only dismisses after the pointer has actually
        // visited the panel — except edge reveals, which self-dismiss.
        if settings.preventAccidentalHiding,
           lastRevealReason == .manual,
           !pointerEnteredSinceReveal {
            return true
        }

        return false
    }

    private func armHideTimer() {
        guard hideTimer == nil else { return }
        let t = Timer(timeInterval: settings.hideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hideTimer = nil
                // Re-check conditions at fire time; the world has moved on.
                if !self.panel.frame.insetBy(dx: -self.hideHysteresis, dy: -self.hideHysteresis)
                    .contains(NSEvent.mouseLocation),
                   !self.shouldHoldOpen() {
                    self.hide(reason: .edge)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func focusTerminal() {
        guard let surface else { return }
        panel.makeFirstResponder(surface)
        // Tell the engine the surface is focused so the cursor is solid and
        // input is live immediately — makeFirstResponder alone doesn't fire
        // the window-key notification the surface listens for when the panel
        // is non-activating.
        if let handle = surface.surface {
            ghostty_surface_set_focus(handle, true)
        }
    }

    // MARK: Settings

    func settingsDidChange() {
        edgeMonitor.edge = settings.edge
        edgeMonitor.revealDelay = settings.revealDelay
        applyPanelLevel()
        applyGlass()
        // The on-card gear only exists while the menu bar icon is hidden.
        settingsButton.isHidden = settings.showMenuBarIcon
        layoutResizeHandle()

        // Re-place live with a gentle transition if visible. Clear any
        // stale card animation state first so an edge flip never leaves
        // the card translated or faded.
        if state == .shown || state == .revealing, let screen = activeScreen {
            if let layer = card.layer {
                layer.removeAllAnimations()
                layer.transform = CATransform3DIdentity
                layer.opacity = 1
            }
            state = .shown
            let frame = targetFrame(on: screen)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.setFrame(frame, display: true)
            }
            panel.orderFrontRegardless()
        }
    }

    func persistState() {
        UserDefaults.standard.set(state == .shown, forKey: "internal.wasVisible")
    }

    // MARK: Scripted-test hooks (control channel)

    /// Insert text into the live surface exactly as a paste would.
    func typeText(_ text: String) {
        surface?.insertText(text, replacementRange: NSRange(location: 0, length: 0))
    }

    /// Synthesize a real key press through the panel's responder chain, so
    /// scripted tests exercise the same path physical keys take.
    func sendKey(_ name: String) {
        let map: [String: (code: UInt16, chars: String, raw: String, flags: NSEvent.ModifierFlags)] = [
            "escape": (53, "\u{1b}", "\u{1b}", []),
            "return": (36, "\r", "\r", []),
            "tab":    (48, "\t", "\t", []),
            "ctrl-c": (8,  "\u{03}", "c", [.control]),
        ]
        guard let k = map[name] else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let ev = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: k.flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil,
                characters: k.chars, charactersIgnoringModifiers: k.raw,
                isARepeat: false, keyCode: k.code
            ) {
                panel.sendEvent(ev)
            }
        }
    }

    /// The visible terminal contents (via the surface's accessibility value).
    func screenText() -> String {
        (surface?.accessibilityValue() as? String) ?? "<no surface>"
    }

    /// One-line state summary for scripted verification and bug reports.
    func diagnosticDescription() -> String {
        let responder = panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "state=\(state) visible=\(panel.isVisible) key=\(panel.isKeyWindow) " +
            "responder=\(responder) frame=\(panel.frame) " +
            "surfaceAlive=\(surface != nil) " +
            "processExited=\(surface?.processExited ?? true) " +
            "gearHidden=\(settingsButton.isHidden) " +
            "gearSuperview=\(settingsButton.superview != nil) " +
            "gearFrame=\(settingsButton.frame) " +
            "sessions=\(sessions.count)"
    }
}

/// Invisible strip along the card's inner edge that resizes the sidebar.
final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var currentWidth: (() -> CGFloat)?

    private var dragStartX: CGFloat = 0
    private var startWidth: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = NSEvent.mouseLocation.x
        startWidth = currentWidth?() ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = NSEvent.mouseLocation.x - dragStartX
        onDrag?(delta, startWidth)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
