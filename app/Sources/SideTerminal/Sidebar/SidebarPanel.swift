import AppKit

/// The borderless, non-activating panel that hosts the terminal card.
///
/// The window itself never animates: it is placed at its final frame and the
/// card (`cardView`) animates within it using Core Animation, which keeps
/// every frame on the GPU and lets the soft shadow ride along smoothly.
final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// AppKit turns an unhandled Esc into `cancelOperation:`, which on a panel
    /// tries to "cancel" (close) it — swallowing Esc before TUIs like vim or
    /// Claude Code can see it. Route it back into the terminal as a real Esc.
    override func cancelOperation(_ sender: Any?) {
        guard let responder = firstResponder,
              responder.responds(to: #selector(NSResponder.keyDown(with:))) else { return }
        if let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ) {
            responder.keyDown(with: esc)
        }
    }

    init() {
        // .nonactivatingPanel is required for the sidebar to appear over a
        // fullscreen app: calling NSApp.activate() while another app owns a
        // fullscreen Space forces macOS to switch back to the desktop Space
        // instead of overlaying our panel on it. A non-activating panel can
        // still become the real key window and receive every keystroke
        // (Esc included) without that app-wide activation step — that's
        // its whole purpose, and combined with .canJoinAllSpaces +
        // .fullScreenAuxiliary below it lets the panel join the fullscreen
        // Space directly. `focusTerminal()` already compensates for the one
        // side effect (no window-key notification) by calling
        // ghostty_surface_set_focus explicitly.
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        identifier = .init(rawValue: "com.sideterminal.sidebar")
        setAccessibilitySubrole(.floatingWindow)

        isOpaque = false
        backgroundColor = .clear
        // The card draws its own shadow: a window shadow would flicker as
        // the card's layer animates.
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        // .canJoinAllSpaces + .fullScreenAuxiliary is the documented recipe
        // for a panel that overlays a fullscreen app's Space instead of
        // being confined to the desktop Space.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
    }
}

/// The visual card: soft shadow wrapper + rounded, blurred content stack.
final class SidebarCardView: NSView {
    /// Rounded clipping container that holds the blur + terminal.
    let contentContainer = NSView()
    let effectView = NSVisualEffectView()

    /// A drop resolved into intent. Directories become a `cd`, files/text
    /// become an inserted path, so the terminal behaves like Terminal.app's
    /// "open at folder".
    enum Drop {
        case changeDirectory(String)  // escaped directory path
        case insert(String)           // escaped text/path
    }
    var onDrop: ((Drop) -> Void)?

    private let cornerRadius: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        registerForDraggedTypes([.string, .fileURL])

        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        // Soft, Apple-like ambient shadow. Lives on this (unclipped) layer.
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.30
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -6)

        contentContainer.wantsLayer = true
        contentContainer.layer?.cornerRadius = cornerRadius
        contentContainer.layer?.cornerCurve = .continuous
        contentContainer.layer?.masksToBounds = true
        // A hairline border reads as machined edge in both themes.
        contentContainer.layer?.borderWidth = 1
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(effectView)

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            effectView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])

        updateBorderColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        // A single folder → cd into it (Terminal.app "open at folder").
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.count == 1, let url = urls.first, url.isFileURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                let escaped = Ghostty.Shell.escape(url.path)
                onDrop?(isDir.boolValue ? .changeDirectory(escaped) : .insert(escaped))
                return true
            }
        }

        // Anything else (multiple items, plain text) → insert as-is.
        guard let content = pb.getOpinionatedStringContents() else { return false }
        onDrop?(.insert(content))
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        contentContainer.layer?.borderColor = isDark
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.black.withAlphaComponent(0.08).cgColor
    }

    /// Install the terminal view inside the rounded container.
    func embedTerminal(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }
}

/// A quiet overlay button that brightens under the pointer. Gives the
/// sidebar built-in Settings access so the app stays reachable even with
/// the menu bar icon hidden.
final class HoverButton: NSButton {
    private var hoverArea: NSTrackingArea?

    var restingAlpha: CGFloat = 0.35 {
        didSet { alphaValue = restingAlpha }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        animator().alphaValue = 0.95
    }

    override func mouseExited(with event: NSEvent) {
        animator().alphaValue = restingAlpha
    }
}
