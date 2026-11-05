#!/bin/bash
# Removes Claude Chimes: its hooks, the menu bar app, and ~/.claude/chimes.
# Usage: ./uninstall.sh [--keep-sounds]   (--keep-sounds keeps your sounds and config)
# You can also uninstall from the app: Settings → General → Uninstall…
set -euo pipefail

APP="${CLAUDE_CHIMES_APP:-$HOME/Applications/Claude Chimes.app}"
BIN="$APP/Contents/MacOS/ClaudeChimes"
FLAGS=(--uninstall); [ "${1:-}" = "--keep-sounds" ] || FLAGS+=(--delete-data)

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

pkill -x ClaudeChimes 2>/dev/null || true
if [ -x "$BIN" ]; then
  say "Removing hooks${FLAGS[1]:+, sounds and settings}"
  "$BIN" "${FLAGS[@]}" </dev/null
else
  # The app is already gone: remove the hooks directly.
  say "Removing Claude Chimes hooks from ~/.claude/settings.json"
  python3 - "$HOME/.claude/settings.json" <<'PY'
import json, os, shutil, sys, time
path = sys.argv[1]
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)
    shutil.copy2(path, f"{path}.bak-chimes-{time.strftime('%Y%m%d%H%M%S')}")
    hooks = settings.get("hooks", {})
    for event in list(hooks):
        groups = []
        for g in hooks[event]:
            kept = [h for h in g.get("hooks", []) if "/.claude/chimes/chime" not in h.get("command", "")]
            if kept:
                groups.append({**g, "hooks": kept})
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]
    if not hooks:
        settings.pop("hooks", None)
    with open(path + ".tmp", "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(path + ".tmp", path)
PY
  rm -f "$HOME/.claude/chimes/chime-hook"
  [ "${1:-}" = "--keep-sounds" ] || rm -rf "$HOME/.claude/chimes"
fi

case "$APP" in *.app) [ -d "$APP" ] && { say "Removing $APP"; rm -rf "$APP"; } ;; esac
echo "Claude Chimes is uninstalled."
