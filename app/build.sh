#!/bin/bash
# Builds "Claude Chimes.app" (default: ~/Applications; override with CLAUDE_CHIMES_APP).
# The app is self-contained: the chimes and icon are bundled, and it sets up its own hooks.
# Usage: app/build.sh [--no-open] [--native]
#   --native   build only for this Mac's CPU (faster); the default is a universal Apple silicon + Intel binary
# Set CLAUDE_CHIMES_NO_KILL=1 to leave a running copy of the app alone (used by the tests).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${CLAUDE_CHIMES_APP:-$HOME/Applications/Claude Chimes.app}"
case "$APP" in *.app) ;; *) echo "CLAUDE_CHIMES_APP must end in .app" >&2; exit 1 ;; esac

OPEN=1; ARCHS="arm64 x86_64"
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN=0 ;;
    --native) ARCHS="$(uname -m)" ;;
  esac
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" "$ROOT"/app/Sources/*.swift -o "$WORK/ClaudeChimes-$arch"
done
python3 "$ROOT/sounds/generate.py" "$WORK/sounds" >/dev/null

[ "${CLAUDE_CHIMES_NO_KILL:-}" = 1 ] || pkill -x ClaudeChimes 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$WORK"/ClaudeChimes-* -output "$APP/Contents/MacOS/ClaudeChimes"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/assets/menubar.svg" "$ROOT/assets/menubar-muted.svg" "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$WORK/sounds" "$APP/Contents/Resources/sounds"
codesign --force --sign - "$APP" 2>/dev/null

[ "$OPEN" = 1 ] && open "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ClaudeChimes"))"
