#!/bin/bash
# Builds Claude Chimes from source, then lets the app set itself up (sounds, hook link, hooks).
# Safe to run again; it replaces only its own hooks and keeps your settings.
# Usage: ./install.sh [--no-open] [--native]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${CLAUDE_CHIMES_APP:-$HOME/Applications/Claude Chimes.app}"
export CLAUDE_CHIMES_APP="$APP"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Claude Chimes is macOS only."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || die "macOS 14 (Sonoma) or later is required."
command -v swiftc >/dev/null || die "Swift compiler not found. Install the Xcode Command Line Tools: xcode-select --install"
command -v python3 >/dev/null || die "python3 not found. Install the Xcode Command Line Tools: xcode-select --install"

OPEN=1; BUILD_ARGS=(--no-open)
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN=0 ;;
    --native) BUILD_ARGS+=(--native) ;;
  esac
done

say "Building Claude Chimes.app"
"$ROOT/app/build.sh" "${BUILD_ARGS[@]}"

say "Setting up sounds and Claude Code hooks"
"$APP/Contents/MacOS/ClaudeChimes" --setup </dev/null
rm -f "$HOME/.claude/chimes/chime.sh"   # replaced by chime-hook in 1.1

[ "$OPEN" = 1 ] && open "$APP"

cat <<DONE

Claude Chimes is installed. Look for the wave in the menu bar.
  - Restart Claude sessions that were already open so they load the hooks.
  - Settings… holds the sound setup and a health check.
DONE
