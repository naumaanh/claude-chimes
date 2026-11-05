#!/bin/bash
# Removes Claude Chimes: its hooks, the menu bar app, and ~/.claude/chimes.
# Usage: ./uninstall.sh [--keep-sounds]   (--keep-sounds leaves ~/.claude/chimes in place)
set -euo pipefail

CHIMES="$HOME/.claude/chimes"
SETTINGS="$HOME/.claude/settings.json"
APP="${CLAUDE_CHIMES_APP:-$HOME/Applications/Claude Chimes.app}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

if [ -x "$APP/Contents/MacOS/ClaudeChimes" ]; then
  say "Quitting the menu bar app and removing its login item"
  pkill -x ClaudeChimes 2>/dev/null || true
  "$APP/Contents/MacOS/ClaudeChimes" --disable-login-item || true
fi

if [ -f "$SETTINGS" ]; then
  say "Removing Claude Chimes hooks from ~/.claude/settings.json"
  python3 - "$SETTINGS" <<'PY'
import json, os, shutil, sys, time
path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)
shutil.copy2(path, f"{path}.bak-chimes-{time.strftime('%Y%m%d%H%M%S')}")
hooks = settings.get("hooks", {})
for event in list(hooks):
    groups = []
    for g in hooks[event]:
        kept = [h for h in g.get("hooks", []) if "chimes/chime.sh" not in h.get("command", "")]
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
fi

case "$APP" in *.app) [ -d "$APP" ] && { say "Removing $APP"; rm -rf "$APP"; } ;; esac

if [ "${1:-}" != "--keep-sounds" ] && [ -d "$CHIMES" ]; then
  say "Removing ~/.claude/chimes"
  rm -rf "$CHIMES"
fi

echo "Claude Chimes is uninstalled."
