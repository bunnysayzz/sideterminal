import SwiftUI
import SideTerminalCore

// MARK: Row icon

/// Small tinted rounded-square icon, System Settings style.
struct SettingIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.gradient)
            )
    }
}

/// A labeled row with a leading icon.
private struct IconLabel: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            SettingIcon(symbol: symbol, color: color)
            Text(title)
        }
    }
}

private struct SliderRow: View {
    let title: String
    let symbol: String
    let color: Color
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var defaultValue: Double?
    let format: (Double) -> String

    @State private var hoveringValue = false

    var body: some View {
        LabeledContent {
            HStack {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                // Hovering the value reveals the reset affordance; clicking
                // snaps the setting back to its default. Both faces stay
                // mounted and only opacity flips, so the swap is instant —
                // a structural if/else here reads as lag.
                ZStack(alignment: .trailing) {
                    let showReset = hoveringValue && defaultValue != nil
                    Text(format(value))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .opacity(showReset ? 0 : 1)
                    if let defaultValue {
                        Button {
                            value = defaultValue
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Reset to default (\(format(defaultValue)))")
                        .opacity(showReset ? 1 : 0)
                        .allowsHitTesting(showReset)
                    }
                }
                .frame(width: 56, alignment: .trailing)
                .contentShape(Rectangle())
                .onHover { hoveringValue = $0 }
            }
        } label: {
            IconLabel(title: title, symbol: symbol, color: color)
        }
    }
}

// MARK: General

struct GeneralPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.launchAtLogin) {
                    IconLabel(title: "Launch at Login", symbol: "power", color: .green)
                }
                Toggle(isOn: $settings.showMenuBarIcon) {
                    IconLabel(title: "Show Menu Bar Icon", symbol: "menubar.rectangle", color: .gray)
                }
                Toggle(isOn: $settings.showInDock) {
                    IconLabel(title: "Show in Dock", symbol: "dock.rectangle", color: .blue)
                }
            } footer: {
                if settings.showMenuBarIcon {
                    if HotKeySpec(string: settings.globalShortcut) == nil {
                        Text("Set a global shortcut below before hiding the icon — without one, the icon stays visible so you can always reach SideTerminal.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Icon hidden. Reach Settings anytime via the ⚙︎ on the sidebar, the global shortcut, or by opening SideTerminal again from Spotlight.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent {
                    ShortcutRecorder()
                } label: {
                    IconLabel(title: "Global Shortcut", symbol: "command", color: .indigo)
                }
            } footer: {
                Text("Click, press the keys you want, done. Taken shortcuts are refused so the toggle always works.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.restoreSession) {
                    IconLabel(title: "Restore Previous Session", symbol: "arrow.counterclockwise", color: .blue)
                }
            } footer: {
                Text("Reopens the sidebar exactly as you left it after relaunching the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Sidebar

struct SidebarPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Position") {
                LabeledContent {
                    Picker("", selection: $settings.edge) {
                        ForEach(SidebarEdge.allCases) { edge in
                            Text(edge.label).tag(edge)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                } label: {
                    IconLabel(title: "Screen Edge", symbol: "rectangle.righthalf.inset.filled", color: .blue)
                }

                SliderRow(
                    title: "Width", symbol: "arrow.left.and.right", color: .purple,
                    value: $settings.sidebarWidth, range: 320...900, step: nil,
                    defaultValue: 520
                ) { "\(Int($0)) pt" }
            }

            Section("Timing") {
                SliderRow(
                    title: "Reveal Delay", symbol: "cursorarrow.rays", color: .orange,
                    value: $settings.revealDelay, range: 0...0.75, step: nil,
                    defaultValue: 0.12
                ) { String(format: "%.2f s", $0) }

                SliderRow(
                    title: "Hide Delay", symbol: "timer", color: .pink,
                    value: $settings.hideDelay, range: 0.2...6, step: nil,
                    defaultValue: 0.5
                ) { String(format: "%.1f s", $0) }

                LabeledContent {
                    Picker("", selection: $settings.animationSpeed) {
                        ForEach(AnimationSpeed.allCases) { speed in
                            Text(speed.label).tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                } label: {
                    IconLabel(title: "Animation", symbol: "wand.and.sparkles", color: .teal)
                }
            }

            Section {
                Toggle(isOn: $settings.autoHide) {
                    IconLabel(title: "Auto Hide", symbol: "eye.slash", color: .gray)
                }
                Toggle(isOn: $settings.alwaysOnTop) {
                    IconLabel(title: "Always On Top", symbol: "square.stack.3d.up", color: .indigo)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Appearance

struct AppearancePane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Theme") {
                LabeledContent {
                    Picker("", selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                } label: {
                    IconLabel(title: "Appearance", symbol: "circle.lefthalf.filled", color: .blue)
                }
            }

            Section("Glass") {
                SliderRow(
                    title: "Opacity", symbol: "square.on.square.intersection.dashed", color: .purple,
                    value: $settings.backgroundOpacity, range: 0.5...1.0, step: nil,
                    defaultValue: 0.82
                ) { "\(Int($0 * 100))%" }

                SliderRow(
                    title: "Blur", symbol: "drop.halffull", color: .teal,
                    value: $settings.blurAmount, range: 0...40, step: nil,
                    defaultValue: 24
                ) { "\(Int($0))" }
            }

            Section("Type") {
                LabeledContent {
                    FontPickerButton()
                } label: {
                    IconLabel(title: "Font", symbol: "textformat", color: .orange)
                }

                SliderRow(
                    title: "Font Size", symbol: "textformat.size", color: .pink,
                    value: $settings.fontSize, range: 9...24, step: 0.5,
                    defaultValue: 13
                ) { String(format: "%.1f pt", $0) }

                LabeledContent {
                    Picker("", selection: $settings.cursorStyle) {
                        ForEach(TerminalCursorStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                } label: {
                    IconLabel(title: "Cursor Style", symbol: "cursor.rays", color: .green)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Behavior

struct BehaviorPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Keep Open") {
                Toggle(isOn: $settings.keepOpenWhileTyping) {
                    IconLabel(title: "While Typing", symbol: "keyboard.badge.ellipsis", color: .blue)
                }
                Toggle(isOn: $settings.keepOpenWhileMouseInside) {
                    IconLabel(title: "While Mouse Is Inside", symbol: "cursorarrow.motionlines", color: .purple)
                }
                Toggle(isOn: $settings.preventAccidentalHiding) {
                    IconLabel(title: "Prevent Accidental Hiding", symbol: "hand.raised", color: .orange)
                }
            }

            Section {
                Toggle(isOn: $settings.restoreWorkspace) {
                    IconLabel(title: "Restore Workspace", symbol: "folder.badge.gearshape", color: .teal)
                }
                LabeledContent {
                    ValidatedPathField(
                        text: $settings.workingDirectory,
                        placeholder: NSHomeDirectory(),
                        requirement: .directory,
                        invalidHint: "No folder at this path"
                    )
                    .frame(maxWidth: 280)
                } label: {
                    IconLabel(title: "Default Working Directory", symbol: "folder", color: .gray)
                }
            } header: {
                Text("Workspace")
            } footer: {
                Text("New sessions start here. Empty uses your home folder, shown above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Advanced

struct AdvancedPane: View {
    @EnvironmentObject var settings: AppSettings
    @State private var confirmReset = false

    /// The user's actual login shell, shown as the effective default.
    static let loginShell: String = {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    TextField("", text: $settings.startupCommand, prompt: Text("None — runs your shell"))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 240)
                } label: {
                    IconLabel(title: "Startup Command", symbol: "play.rectangle", color: .green)
                }
                .help("Runs instead of your shell when a session starts, e.g. “claude”.")

                LabeledContent {
                    ValidatedPathField(
                        text: $settings.shellPath,
                        placeholder: Self.loginShell,
                        requirement: .executable,
                        invalidHint: "Not an executable — check the path"
                    )
                    .frame(maxWidth: 260)
                } label: {
                    IconLabel(title: "Shell", symbol: "terminal", color: .gray)
                }
            } footer: {
                Text("Empty fields use your login shell, shown above. Changes apply when the terminal session restarts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Session") {
                LabeledContent {
                    Button("Restart Terminal Session") {
                        (NSApp.delegate as? AppDelegate)?.restartSession()
                    }
                } label: {
                    IconLabel(title: "Session", symbol: "arrow.triangle.2.circlepath", color: .red)
                }
            }

            Section {
                LabeledContent {
                    Button("Reset All Settings…", role: .destructive) {
                        confirmReset = true
                    }
                    .confirmationDialog(
                        "Reset every setting to its default?",
                        isPresented: $confirmReset
                    ) {
                        Button("Reset Everything", role: .destructive) {
                            settings.resetToDefaults()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Your terminal session keeps running; only settings change.")
                    }
                } label: {
                    IconLabel(title: "Defaults", symbol: "arrow.uturn.backward", color: .gray)
                }
            } footer: {
                Text("Returns every option in all tabs to how SideTerminal shipped.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: About

struct AboutPane: View {
    private static let repo = "https://github.com/bunnysayzz/sideterminal"
    private static let repoURL = URL(string: repo)!
    private static let releasesURL = URL(string: repo + "/releases")!
    private static let issuesURL = URL(string: repo + "/issues")!
    private static let licenseURL = URL(string: repo + "/blob/main/LICENSE")!

    @State private var hoveringGitHub = false

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var gitHubMark: NSImage? {
        guard let url = Bundle.main.url(forResource: "GitHubMark", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        Form {
            // Centered hero: icon, name + version, tagline, primary action.
            Section {
                VStack(spacing: 0) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)

                    Text("SideTerminal")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .padding(.top, 12)

                    Text("Version \(versionString)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)

                    Text("Your terminal, one edge away.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)

                    gitHubButton
                        .padding(.top, 18)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .listRowBackground(Color.clear)
            }

            // Standard info + links, in the same grouped style as other panes.
            Section {
                LabeledContent {
                    Text(versionString).foregroundStyle(.secondary).monospacedDigit()
                } label: {
                    IconLabel(title: "Version", symbol: "number", color: .gray)
                }
                Button { NSWorkspace.shared.open(Self.licenseURL) } label: {
                    LabeledContent {
                        HStack(spacing: 5) {
                            Text("MIT").foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.forward.square").font(.caption).foregroundStyle(.tertiary)
                        }
                    } label: {
                        IconLabel(title: "License", symbol: "checkmark.seal", color: .green)
                    }
                }
                .buttonStyle(.plain)
            }

            Section {
                linkRow("Source Code", detail: "bunnysayzz/sideterminal", symbol: "chevron.left.forwardslash.chevron.right", color: .indigo, url: Self.repoURL)
                linkRow("Releases", detail: "Download builds", symbol: "shippingbox", color: .orange, url: Self.releasesURL)
                linkRow("Report an Issue", detail: "GitHub Issues", symbol: "exclamationmark.bubble", color: .pink, url: Self.issuesURL)
            } footer: {
                HStack(spacing: 4.5) {
                    Text("© 2026 bunnysayzz · Open source, made with")
                    Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(.red)
                    Text("for the Mac")
                }
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
        }
        .formStyle(.grouped)
    }

    private func linkRow(_ title: String, detail: String, symbol: String, color: Color, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            LabeledContent {
                HStack(spacing: 5) {
                    Text(detail).foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.forward.square").font(.caption).foregroundStyle(.tertiary)
                }
            } label: {
                IconLabel(title: title, symbol: symbol, color: color)
            }
        }
        .buttonStyle(.plain)
    }

    private var gitHubButton: some View {
        Button {
            NSWorkspace.shared.open(Self.repoURL)
        } label: {
            HStack(spacing: 8) {
                if let gitHubMark {
                    Image(nsImage: gitHubMark)
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 15, height: 15)
                }
                Text("View on GitHub")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 18)
            .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
            .shadow(color: Color(nsColor: .controlAccentColor).opacity(hoveringGitHub ? 0.4 : 0.22),
                    radius: hoveringGitHub ? 10 : 6, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(hoveringGitHub ? 1.03 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hoveringGitHub)
        .onHover { hoveringGitHub = $0 }
        .help("bunnysayzz/sideterminal")
    }
}
