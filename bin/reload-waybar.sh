#!/usr/bin/env bash
# reload-waybar.sh — make Waybar pick up soundboard module/icon changes now.
#
# Waybar caches custom-module output ("interval": 0), so script or glyph edits
# stay invisible until the module is signalled. This sends:
#   SIGRTMIN+7  re-run the exec (module "signal": 7) → new glyph/text instantly
#   SIGUSR2     re-read config.jsonc and style.css from disk
#
# Usage:
#   reload-waybar.sh            refresh module output + reload config/CSS
#   reload-waybar.sh --restart  fully restart the Waybar daemon
#   reload-waybar.sh --start    start Waybar if it is not running
set -u

MODE="${1:-refresh}"
PID=$(pgrep -x waybar | head -n1 || true)

if [ -z "$PID" ]; then
  case "$MODE" in
    --start|start)
      if systemctl --user start waybar 2>/dev/null; then
        echo "waybar: started via systemd user unit" >&2
      else
        setsid waybar </dev/null >/dev/null 2>&1 &
        echo "waybar: started (direct)" >&2
      fi
      ;;
    *)
      echo "waybar: not running — the soundboard module renders the current glyph on next start" >&2
      echo "waybar: run '$0 --start' or 'systemctl --user start waybar' to launch it" >&2
      ;;
  esac
  exit 0
fi

case "$MODE" in
  --restart|restart)
    if systemctl --user restart waybar 2>/dev/null; then
      echo "waybar: restarted via systemd user unit" >&2
    else
      kill "$PID" 2>/dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.05
      done
      setsid waybar </dev/null >/dev/null 2>&1 &
      echo "waybar: restarted (direct)" >&2
    fi
    ;;
  *)
    kill -RTMIN+7 "$PID" 2>/dev/null
    kill -USR2 "$PID" 2>/dev/null
    echo "waybar: module output and config/style reloaded" >&2
    ;;
esac
