#!/bin/bash
# Builds "Claude Chimes.app" (default: ~/Applications) and launches it.
# Usage: app/build.sh [--no-open]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${CLAUDE_CHIMES_APP:-$HOME/Applications/Claude Chimes.app}"
case "$APP" in *.app) ;; *) echo "CLAUDE_CHIMES_APP must end in .app" >&2; exit 1 ;; esac

pkill -x ClaudeChimes 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$ROOT/app/ClaudeChimes.swift" -o "$APP/Contents/MacOS/ClaudeChimes"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/assets/menubar.svg" "$ROOT/assets/menubar-muted.svg" "$APP/Contents/Resources/"
codesign --force --sign - "$APP" 2>/dev/null

[ "${1:-}" = "--no-open" ] || open "$APP"
echo "Built $APP"
