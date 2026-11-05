#!/bin/bash
# Claude Chimes installer: sounds, the menu bar app, and the Claude Code hooks.
# Safe to run again; it replaces its own hooks and keeps your settings.
# Usage: ./install.sh [--no-open]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CHIMES="$HOME/.claude/chimes"
SETTINGS="$HOME/.claude/settings.json"
APP="${CLAUDE_CHIMES_APP:-$HOME/Applications/Claude Chimes.app}"
export CLAUDE_CHIMES_APP="$APP"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Claude Chimes is macOS only."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || die "macOS 14 (Sonoma) or later is required."
command -v swiftc >/dev/null || die "Swift compiler not found. Install the Xcode Command Line Tools: xcode-select --install"
command -v python3 >/dev/null || die "python3 not found. Install the Xcode Command Line Tools: xcode-select --install"

say "Generating chimes in ~/.claude/chimes/sounds"
python3 "$ROOT/sounds/generate.py" "$CHIMES/sounds" >/dev/null

if [ ! -f "$CHIMES/config" ]; then
  cat > "$CHIMES/config" <<CONF
# Claude Chimes config: written by the menu bar app, read by the chime hook
input=$CHIMES/sounds/input-nudge.wav
done=$CHIMES/sounds/done-spark.wav
volume=0.40
muted=0
showCount=1
showFinished=1
CONF
fi

say "Building the menu bar app"
"$ROOT/app/build.sh" --no-open

say "Linking the hook to ~/.claude/chimes/chime-hook"
ln -sf "$APP/Contents/MacOS/ClaudeChimes" "$CHIMES/chime-hook"
rm -f "$CHIMES/chime.sh"   # replaced by chime-hook in 1.1

say "Adding hooks to ~/.claude/settings.json"
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

OURS = "/.claude/chimes/chime"
# (event, hook argument, runs in the background?)
WANTED = [
    ("Notification", "notification", False),  # chime + mark "needs your input"
    ("Stop", "stop", False),                  # chime + mark "ready for your reply"
    ("UserPromptSubmit", "prompt", True),     # you replied: clear the session
    ("PostToolUse", "tool", True),            # a tool ran: permission was answered
    ("SessionEnd", "end", True),              # session closed: clear it
]

hooks = settings.setdefault("hooks", {})
for event in list(hooks):  # drop any earlier Claude Chimes hooks, keep everything else
    groups = []
    for g in hooks[event]:
        kept = [h for h in g.get("hooks", []) if OURS not in h.get("command", "")]
        if kept:
            groups.append({**g, "hooks": kept})
    if groups:
        hooks[event] = groups
    else:
        del hooks[event]

for event, arg, background in WANTED:
    hook = {"type": "command", "command": f"~/.claude/chimes/chime-hook {arg}", "timeout": 5}
    if background:
        hook["async"] = True
    hooks.setdefault(event, []).append({"hooks": [hook]})

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + ".tmp", "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(path + ".tmp", path)
PY

[ "${1:-}" = "--no-open" ] || open "$APP"

cat <<DONE

Claude Chimes is installed. Look for its icon in the menu bar.
  - Chimes play when Claude needs your input and when it finishes a reply.
  - The menu lists sessions waiting on you; Settings… holds the sound setup.
  - Works in the Claude desktop app's Code tab and the claude CLI.
  - Already-open sessions may need a restart to pick up the new hooks.
DONE
