#!/bin/bash
# Package build/SideTerminal.app into a distributable, drag-to-install DMG.
# Run after scripts/bundle-app.sh release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SideTerminal.app"
DMG="$ROOT/build/SideTerminal.dmg"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run scripts/bundle-app.sh release first." >&2
    exit 1
fi

rm -f "$DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# A window the user drags SideTerminal.app into /Applications from.
cp -R "$APP" "$STAGING/SideTerminal.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "SideTerminal" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

echo "Built: $DMG ($(du -h "$DMG" | cut -f1))"
