#!/bin/bash
# Builds SideTerminal and assembles SideTerminal.app.
# Usage: bundle-app.sh [debug|release]  (default: release)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/SideTerminal.app"

cd "$ROOT/app"
swift build -c "$CONFIG"

BIN="$ROOT/app/.build/$CONFIG/SideTerminal"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/SideTerminal"

# Ghostty runtime resources (terminfo, shell integration, themes).
cp -R "$ROOT/ghostty/zig-out/share/ghostty" "$APP/Contents/Resources/ghostty"
cp -R "$ROOT/ghostty/zig-out/share/terminfo" "$APP/Contents/Resources/terminfo"

# App icon: the curated artwork in assets/ wins; fall back to the
# generated one (scripts/make-icon.swift) only if it's absent.
if [ -f "$ROOT/assets/AppIcon.icns" ]; then
    cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
        (cd "$ROOT/build" && swift "$ROOT/scripts/make-icon.swift" . \
            && iconutil -c icns AppIcon.iconset -o AppIcon.icns)
    fi
    cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Monochrome template icon for the menu bar (scripts/make-menubar-icon.swift).
if [ -f "$ROOT/assets/MenuBarIcon.png" ]; then
    cp "$ROOT/assets/MenuBarIcon.png" "$ROOT/assets/MenuBarIcon@2x.png" \
        "$APP/Contents/Resources/"
fi

# GitHub mark for the About pane.
if [ -f "$ROOT/assets/GitHubMark.png" ]; then
    cp "$ROOT/assets/GitHubMark.png" "$APP/Contents/Resources/"
fi

# Version is stamped from the environment during a release; defaults keep
# local dev builds working (scripts/release.sh sets these from the tag).
APP_VERSION="${SIDETERMINAL_VERSION:-1.0.0}"
APP_BUILD="${SIDETERMINAL_BUILD:-1}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>SideTerminal</string>
    <key>CFBundleIdentifier</key><string>com.sideterminal.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>SideTerminal</string>
    <key>CFBundleDisplayName</key><string>SideTerminal</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
    <key>CFBundleVersion</key><string>${APP_BUILD}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo "Built: $APP"
