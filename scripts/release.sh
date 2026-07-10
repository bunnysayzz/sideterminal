#!/bin/bash
# Cut a SideTerminal release: verify tests, build the app on this macOS 26
# machine, package a DMG, tag, and publish a GitHub Release with notes
# generated from the commits/PRs since the last release.
#
#   scripts/release.sh v1.2.0
#
# The app can only be built on macOS 26 (the UI uses the latest SDK), so
# releases are cut here, not in CI. "Proper testing" is enforced by checking
# that the Build workflow (which runs the unit tests) is green for this commit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: scripts/release.sh vX.Y.Z" >&2
    exit 1
fi
[[ "$VERSION" == v* ]] || VERSION="v$VERSION"
NUMBER="${VERSION#v}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }

# --- Preconditions ----------------------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree not clean — commit or stash first." >&2
    exit 1
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
    echo "error: release from main (currently on $BRANCH)." >&2
    exit 1
fi
if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "error: tag $VERSION already exists." >&2
    exit 1
fi
git fetch -q origin

# --- Proper testing: require green CI (unit tests) for this commit ----------
log "Verifying CI tests passed for $(git rev-parse --short HEAD)"
SHA="$(git rev-parse HEAD)"
CONCLUSION="$(gh run list --commit "$SHA" --workflow build.yml \
    --json status,conclusion --jq '[.[] | select(.status=="completed")][0].conclusion' 2>/dev/null || echo "")"
if [ "$CONCLUSION" != "success" ]; then
    echo "error: Build workflow is not green for this commit (state: ${CONCLUSION:-pending})." >&2
    echo "Push your commits and wait for the tests to pass, then retry." >&2
    exit 1
fi

# --- Build the app (this machine has the macOS 26 SDK) ----------------------
if [ ! -f ghostty/zig-out/lib/libghostty.a ]; then
    log "Building engine library"
    scripts/build-libghostty.sh
fi
log "Building SideTerminal $VERSION"
SIDETERMINAL_VERSION="$NUMBER" SIDETERMINAL_BUILD="$(date +%Y%m%d%H%M)" \
    scripts/bundle-app.sh release

log "Packaging DMG"
scripts/make-dmg.sh

# --- Tag and publish --------------------------------------------------------
log "Tagging $VERSION"
git tag -a "$VERSION" -m "SideTerminal $VERSION"
git push origin "$VERSION"

log "Publishing GitHub release with generated notes"
gh release create "$VERSION" \
    --title "SideTerminal $VERSION" \
    --generate-notes \
    build/SideTerminal.dmg

log "Released $VERSION 🎉  →  https://github.com/bunnysayzz/sideterminal/releases/tag/$VERSION"
