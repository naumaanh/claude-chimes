#!/bin/bash
# Claude Chimes test suite. Builds the app into a throwaway HOME and exercises setup, the hooks,
# session tracking, the health check and uninstall. Never touches your real ~/.claude or running app.
#
# Usage: tests/run.sh [--universal]   (default builds only for this Mac's CPU, which is faster)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export CLAUDE_CHIMES_APP="$WORK/home/Applications/Claude Chimes.app"
export CLAUDE_CHIMES_NO_KILL=1
export CLAUDE_CHIMES_VOLUME=0          # silent: the hooks still run, afplay is skipped
# Hooks read these from Claude Code; make sure the ones from the shell running the tests don't leak in.
unset CLAUDE_PID CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_HOST_SESSION_ID __CFBundleIdentifier
mkdir -p "$HOME/.claude"

BIN="$CLAUDE_CHIMES_APP/Contents/MacOS/ClaudeChimes"
HOOK="$HOME/.claude/chimes/chime-hook"
SETTINGS="$HOME/.claude/settings.json"
SESSIONS="$HOME/.claude/chimes/sessions"
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
# Run with a time limit (a hook that hangs is a failure, not a stuck test run) and no terminal stdin.
lim() { perl -e 'alarm 15; exec @ARGV' "$@"; }
hook() { local id="$1" ev="$2"; shift 2; echo "{\"session_id\":\"$id\",\"cwd\":\"/tmp/$id\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission\"}" | env "$@" perl -e 'alarm 15; exec @ARGV' "$HOOK" "$ev"; }
has() { [ -f "$SESSIONS/$1.json" ]; }
status_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$SESSIONS/$1.json" 2>/dev/null; }

section "Build"
BUILD_ARGS=(--no-open --native); [ "${1:-}" = "--universal" ] && BUILD_ARGS=(--no-open)
if "$ROOT/app/build.sh" "${BUILD_ARGS[@]}" >"$WORK/build.log" 2>&1; then ok "app builds ($(lipo -archs "$BIN"))"; else bad "app builds" "$(tail -20 "$WORK/build.log")"; exit 1; fi
check "bundles six chimes" '[ "$(ls "$CLAUDE_CHIMES_APP/Contents/Resources/sounds" | wc -l | tr -d " ")" = 6 ]'
check "bundles the app icon" '[ -f "$CLAUDE_CHIMES_APP/Contents/Resources/AppIcon.icns" ]'

section "Setup keeps settings.json intact"
cp "$ROOT/tests/fixtures/settings.json" "$SETTINGS"
check "--setup succeeds" 'lim "$BIN" --setup </dev/null >/dev/null'
check "top-level key order kept" '[ "$(python3 -c "import json,sys; print(list(json.load(open(sys.argv[1]))))" "$SETTINGS")" = "['"'"'model'"'"', '"'"'cleanupPeriodDays'"'"', '"'"'ratio'"'"', '"'"'statusLine'"'"', '"'"'hooks'"'"', '"'"'env'"'"', '"'"'permissions'"'"']" ]'
check "number spelling kept (1.0e3)" 'grep -q "\"ratio\": 1.0e3" "$SETTINGS"'
check "unrelated hooks kept" 'grep -q "my-guard" "$SETTINGS" && grep -q "echo other-stop" "$SETTINGS"'
check "1.0 chime.sh hook replaced" '! grep -q "chimes/chime.sh" "$SETTINGS"'
for ev in notification stop prompt tool end; do
  check "hook installed: $ev" 'grep -q "chimes/chime-hook '"$ev"'\"" "$SETTINGS"'
done
check "background hooks are async" '[ "$(grep -c "\"async\": true" "$SETTINGS")" = 3 ]'
check "chimes copied to ~/.claude/chimes/sounds" '[ "$(ls "$HOME/.claude/chimes/sounds" | wc -l | tr -d " ")" = 6 ]'
cp "$SETTINGS" "$WORK/after-setup.json"
lim "$BIN" --setup </dev/null >/dev/null
check "running setup again changes nothing" 'cmp -s "$SETTINGS" "$WORK/after-setup.json"'
check "doctor passes" 'lim "$HOOK" --doctor </dev/null >/dev/null'

section "Hooks track sessions"
hook s1 notification CLAUDE_CODE_ENTRYPOINT=cli
check "permission prompt marks needs-input" '[ "$(status_of s1)" = needs-input ]'
hook s1 tool
check "a tool run clears the prompt" '! has s1'
hook s1 stop CLAUDE_CODE_ENTRYPOINT=cli
check "stop marks finished" '[ "$(status_of s1)" = finished ]'
echo '{"session_id":"s1","notification_type":"idle_prompt"}' | lim "$HOOK" notification
check "idle reminder is ignored" '[ "$(status_of s1)" = finished ]'
hook s1 prompt
check "replying clears the session" '! has s1'
hook s2 stop; hook s2 end
check "session end clears it" '! has s2'
hook d1 stop CLAUDE_CODE_ENTRYPOINT=claude-desktop CLAUDE_CODE_HOST_SESSION_ID=local_abc-123
hook c1 stop CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_HOST_SESSION_ID=local_inherited
hook x1 stop CLAUDE_CODE_ENTRYPOINT=claude-desktop 'CLAUDE_CODE_HOST_SESSION_ID=local_x&evil=1'
LIST="$(lim "$HOOK" --list-sessions </dev/null)"
check "desktop chat gets its link" 'echo "$LIST" | grep "^finished	d1" | grep -q "claude://code/continue?session=local_abc-123"'
check "CLI session doesn't use an inherited desktop ID" 'echo "$LIST" | grep "^finished	c1" | grep -q "	-$"'
check "malformed desktop ID is rejected" 'echo "$LIST" | grep "^finished	x1" | grep -q "	-$"'
rm -f "$SESSIONS"/*.json

section "Stale sessions are pruned"
sleep 30 & LIVE=$!; sleep 0.05 & DEAD=$!; wait $DEAD 2>/dev/null
hook needs-dead notification CLAUDE_PID=$DEAD CLAUDE_CODE_ENTRYPOINT=cli
hook needs-live notification CLAUDE_PID=$LIVE CLAUDE_CODE_ENTRYPOINT=cli
hook cli-dead stop CLAUDE_PID=$DEAD CLAUDE_CODE_ENTRYPOINT=cli
hook desk-dead stop CLAUDE_PID=$DEAD CLAUDE_CODE_ENTRYPOINT=claude-desktop
hook no-pid stop CLAUDE_CODE_ENTRYPOINT=cli
hook reused stop CLAUDE_PID=$LIVE CLAUDE_CODE_ENTRYPOINT=cli
python3 - "$SESSIONS/reused.json" <<'PY'
import json, sys; p = sys.argv[1]; s = json.load(open(p)); s["pidStart"] -= 1000; json.dump(s, open(p, "w"))
PY
KEPT="$(lim "$HOOK" --list-sessions </dev/null | cut -f2 | sort | tr '\n' ' ')"
check "keeps live, desktop and no-PID sessions; drops dead and reused" '[ "$KEPT" = "desk-dea needs-li no-pid " ]'
{ kill $LIVE; wait $LIVE; } 2>/dev/null; rm -f "$SESSIONS"/*.json

section "Health check and repair"
python3 - "$SETTINGS" <<'PY'
import json, sys; p = sys.argv[1]; s = json.load(open(p)); del s["hooks"]["SessionEnd"]; json.dump(s, open(p, "w"), indent=2)
PY
rm -f "$HOOK"
lim "$BIN" --doctor </dev/null >"$WORK/doctor.txt"; RC=$?
check "doctor exits 1 when broken" '[ $RC = 1 ]'
check "doctor names the missing hook" 'grep -q "Missing: SessionEnd" "$WORK/doctor.txt"'
check "doctor notices the missing link" 'grep -q "chime-hook is missing or broken" "$WORK/doctor.txt"'
check "--repair fixes both" 'lim "$BIN" --repair </dev/null >/dev/null && lim "$HOOK" --doctor </dev/null >/dev/null'

section "Event log"
python3 -c "import sys; open(sys.argv[1],'a').write(('x'*200+'\n')*1400)" "$HOME/.claude/chimes/events.log"
hook rot prompt
SIZE=$(stat -f %z "$HOME/.claude/chimes/events.log")
check "log rotates under 256 KB ($SIZE bytes)" '[ $SIZE -lt 262144 ]'
check "newest event survives rotation" 'tail -1 "$HOME/.claude/chimes/events.log" | grep -q "prompt session=rot"'

section "Uninstall"
cp "$ROOT/tests/fixtures/settings.json" "$SETTINGS"
lim "$BIN" --setup </dev/null >/dev/null
check "--uninstall succeeds" 'lim "$BIN" --uninstall </dev/null >/dev/null'
check "settings.json matches the original minus the old hook, byte for byte" 'cmp -s "$SETTINGS" "$ROOT/tests/fixtures/settings-after-uninstall.json"'
check "keeps sounds without --delete-data" '[ -d "$HOME/.claude/chimes/sounds" ]'
lim "$BIN" --setup </dev/null >/dev/null; lim "$BIN" --uninstall --delete-data </dev/null >/dev/null
check "--delete-data removes ~/.claude/chimes" '[ ! -e "$HOME/.claude/chimes" ]'
check "backups were written" 'ls "$HOME/.claude" | grep -q "settings.json.bak-chimes-"'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
