<h1 align="center">
  <img src="assets/sideterminal.png" width="30" align="center" alt="">
  SideTerminal
</h1>

<p align="center"><b>Your terminal, one edge away.</b></p>

<p align="center">
  A premium edge-reveal sidebar terminal for macOS. Nudge your mouse to the
  screen edge and it glides in; move away and it glides out.<br>Your session
  never dies.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-lightgrey" alt="Apple Silicon">
  <a href="https://github.com/bunnysayzz/sideterminal/actions/workflows/build.yml"><img src="https://github.com/bunnysayzz/sideterminal/actions/workflows/build.yml/badge.svg" alt="Build"></a>
</p>

---

## Features

- **Edge reveal** — a hot zone on your chosen edge (left/right) with a
  configurable dwell delay and a spring-animated, blurred card.
- **Sessions stay alive** — hiding never touches the pty. Claude CLI, SSH,
  tmux, builds — everything keeps running for hours.
- **Session switcher** — keep up to 10 live sessions on a shelf and switch
  instantly, each with its full scrollback and running programs.
- **Intelligent auto-hide** — never hides while you type, select, drag, or
  scroll.
- **Menu bar app** — no clutter. Optional Dock icon, single Show/Hide toggle,
  Settings, session switcher, Restart Session, Quit.
- **Live settings** — General / Sidebar / Appearance / Behavior / Advanced,
  applied instantly.
- **Record any shortcut** — a macOS-style recorder with live availability
  feedback; taken combos are refused.
- **Workspace restore** — remembers the working directory across restarts and
  reboots.
- **Never locked out** — hide the menu bar icon and an on-card gear appears;
  the Dock icon, global shortcut, and re-launching all reach Settings too.

## Install

1. Download `SideTerminal.dmg` from the
   [Releases](https://github.com/bunnysayzz/sideterminal/releases) page, open it,
   and drag **SideTerminal** into **Applications**.
2. SideTerminal is open source and unsigned (no paid Apple Developer account),
   so macOS Gatekeeper blocks it on first launch. Allow it once with:

   ```bash
   xattr -dr com.apple.quarantine /Applications/SideTerminal.app
   ```

   Then open it normally. (Alternatively: **System Settings → Privacy &
   Security → Open Anyway**.)

Requires macOS 14+ on Apple Silicon. Or build from source below.

## Build from source

```bash
git clone https://github.com/bunnysayzz/sideterminal
cd sideterminal
scripts/bootstrap.sh           # once: fetch the engine + Zig, build the SDK shim
scripts/build-libghostty.sh    # build the engine (slow the first time)
scripts/bundle-app.sh release  # -> build/SideTerminal.app
```

- **Runs on** macOS 14+ (Apple Silicon).
- **Builds on** macOS 26 SDK (Xcode 26 / Tahoe) — the UI uses the latest
  AppKit/SwiftUI. Only the Xcode Command Line Tools are required, not full Xcode.

## Usage

- Move the pointer to your chosen screen edge to reveal; move away to hide.
- Toggle any time with the global shortcut (default `⌘⇧\``) or the menu bar icon.
- Drive it from scripts via a `DistributedNotificationCenter` channel:
  ```
  com.sideterminal.control.{show,hide,toggle,settings,restart,status}
  com.sideterminal.control.set   object "theme=dark" | "edge=left" | "width=600"
  ```

## Releasing

The app must be built on macOS 26 (its UI uses the latest SDK), so releases are
cut from a maintainer's Mac, not CI. One command tests, builds, packages, and
publishes:

```bash
scripts/release.sh v1.2.0
```

It refuses to run unless the unit tests are green in CI for the current commit,
then builds the app + DMG and creates a GitHub Release whose notes are generated
automatically from the commits and merged PRs since the last release (grouped by
label per [`.github/release.yml`](.github/release.yml)).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). In short:
the terminal engine is off-limits (that's the whole point of wrapping a great
one); SideTerminal owns the sidebar experience around it. Pure logic lives in
[`app/Core`](app/Core) and is unit-tested. Pull requests are automatically
checked (build, tests, security, lint, hygiene) and reviewed by CodeRabbit.

## License

[MIT](LICENSE). Includes third-party open-source components — see
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
