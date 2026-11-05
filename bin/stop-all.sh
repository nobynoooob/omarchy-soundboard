#!/usr/bin/env bash
# stop-all.sh — kill every running soundboard clip.
set -u
STATE_DIR="${SBOARD_STATE_DIR:-$HOME/.local/state/omarchy-soundboard}"
PLAYING_DIR="$STATE_DIR/playing"
BOARD_SINK="${SBOARD_BOARD_SINK:-soundboard_board}"

count=0
if [ -d "$PLAYING_DIR" ]; then
  for f in "$PLAYING_DIR"/*; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    rm -f "$f"
    # kill the player child first: SIGTERM to the shell does not propagate
    [ -n "$pid" ] && pkill -P "$pid" 2>/dev/null
    [ -n "$pid" ] && kill "$pid" 2>/dev/null && count=$((count + 1))
  done
fi

# catch strays launched outside the pidfile (mpv/ffplay command lines carry the sink)
pkill -f "pulse/$BOARD_SINK" 2>/dev/null
pkill -f "pw-cat --playback --target $BOARD_SINK" 2>/dev/null

[ "$count" -gt 0 ] && echo "stopped $count clip(s)"
