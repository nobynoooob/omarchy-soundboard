#!/usr/bin/env bash
# toggle-soundboard.sh — show/hide the persistent soundboard window.
#
# Geometry, pinning and placement come from the Hyprland rule in
# ~/.config/hypr/hyprland.lua. This script only owns process lifecycle:
# one instance, instant hide/open, no compositor dispatch strings.
set -u

PLUGIN_DIR="${SBOARD_PLUGIN_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${SBOARD_STATE_DIR:-$HOME/.local/state/omarchy-soundboard}"
PIDFILE="$STATE_DIR/ui.pid"

mkdir -p "$STATE_DIR"

pid=""
if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
fi

if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.04
  done
  kill -9 "$pid" 2>/dev/null
  rm -f "$PIDFILE"
  exit 0
fi

rm -f "$PIDFILE"
setsid nohup python3 "$PLUGIN_DIR/soundboard.py" </dev/null >/dev/null 2>&1 &
