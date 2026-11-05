#!/bin/bash
# Claude Chimes: plays a notification sound from a Claude Code hook.
#
# Usage: chime.sh input|done      (sound chosen in ~/.claude/chimes/config)
#        chime.sh /path/to/file   (play that file directly)
#
# Config keys: input, done (file paths), volume (0.0-1.0), muted (0/1).
# CLAUDE_CHIMES_VOLUME overrides the volume for a single run.

CONF="$HOME/.claude/chimes/config"
SOUNDS="$HOME/.claude/chimes/sounds"
get() { [ -f "$CONF" ] && grep -m1 "^$1=" "$CONF" | cut -d= -f2-; }

# Drain stdin (the hook's JSON payload) so Claude Code isn't left waiting on the pipe.
cat >/dev/null 2>&1

[ "$(get muted)" = "1" ] && exit 0

case "$1" in
  input) SOUND="$(get input)"; SOUND="${SOUND:-$SOUNDS/input-nudge.wav}" ;;
  done)  SOUND="$(get done)";  SOUND="${SOUND:-$SOUNDS/done-spark.wav}" ;;
  *)     SOUND="$1" ;;
esac
SOUND="${SOUND/#\~/$HOME}"

VOLUME="${CLAUDE_CHIMES_VOLUME:-$(get volume)}"
VOLUME="${VOLUME:-0.4}"

[ -f "$SOUND" ] || exit 0
nohup afplay -v "$VOLUME" "$SOUND" >/dev/null 2>&1 &
exit 0
