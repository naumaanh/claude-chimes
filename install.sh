#!/bin/bash
# Claude Chimes installer: sounds, hook script, Claude Code hooks, and the menu bar app.
# Safe to run again; it replaces its own hooks and keeps your sound choices.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CHIMES="$HOME/.claude/chimes"
SETTINGS="$HOME/.claude/settings.json"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Claude Chimes is macOS only."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || die "macOS 14 (Sonoma) or later is required."
command -v swiftc >/dev/null || die "Swift compiler not found. Install the Xcode Command Line Tools: xcode-select --install"
command -v python3 >/dev/null || die "python3 not found. Install the Xcode Command Line Tools: xcode-select --install"

say "Generating chimes in ~/.claude/chimes/sounds"
python3 "$ROOT/sounds/generate.py" "$CHIMES/sounds" >/dev/null

say "Installing hook script to ~/.claude/chimes/chime.sh"
install -m 755 "$ROOT/hooks/chime.sh" "$CHIMES/chime.sh"

if [ ! -f "$CHIMES/config" ]; then
  cat > "$CHIMES/config" <<CONF
# Claude Chimes config: read by ~/.claude/chimes/chime.sh, written by the menu bar app
input=$CHIMES/sounds/input-nudge.wav
done=$CHIMES/sounds/done-spark.wav
volume=0.40
muted=0
CONF
fi

say "Adding Notification and Stop hooks to ~/.claude/settings.json"
python3 - "$SETTINGS" <<'PY'
import json, os, shutil, sys, time

path = sys.argv[1]
settings = {}
if os.path.exists(path):
    with open(path) as f:
        text = f.read()
    try:
        settings = json.loads(text) if text.strip() else {}
    except json.JSONDecodeError as e:
        sys.exit(f"{path} is not valid JSON ({e}); fix it and run install.sh again.")
    shutil.copy2(path, f"{path}.bak-chimes-{time.strftime('%Y%m%d%H%M%S')}")

hooks = settings.setdefault("hooks", {})
for event, arg in (("Notification", "input"), ("Stop", "done")):
    groups = []
    for g in hooks.get(event, []):  # drop any earlier Claude Chimes hook, keep everything else
        kept = [h for h in g.get("hooks", []) if "chimes/chime.sh" not in h.get("command", "")]
        if kept:
            groups.append({**g, "hooks": kept})
    groups.append({"hooks": [{"type": "command", "command": f"~/.claude/chimes/chime.sh {arg}", "timeout": 5}]})
    hooks[event] = groups

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + ".tmp", "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(path + ".tmp", path)
PY

say "Building the menu bar app"
"$ROOT/app/build.sh" "$@"

cat <<DONE

Claude Chimes is installed. Look for its icon in the menu bar.
  - Sounds play when Claude needs your input and when it finishes a reply.
  - Works in the Claude desktop app's Code tab and the claude CLI.
  - Already-open sessions may need a restart to pick up the new hooks.
DONE
