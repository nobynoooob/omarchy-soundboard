#!/usr/bin/env bash
# audio_router.sh — PipeWire virtual-microphone engine for the soundboard.
#
# On-demand topology (pulse-protocol loopbacks; native clients can't resolve
# .monitor facade names):
#   clips -> [soundboard_board null-sink]
#              |-.monitor -> module-loopback -> [soundboard_virtual_mic null-sink]
#              |-.monitor -> module-loopback -> default speakers (optional "monitor")
#   real mic -> module-loopback -> [soundboard_virtual_mic]
#
# The system default source is NEVER changed. A watcher daemon observes the
# board sink: while a clip plays it re-binds apps that record from the hardware
# mic onto the virtual mic, and releases them the moment playback stops. When
# idle the virtual mic is invisible to apps — pickers always see real hardware.
#
# Module lookups match type + exact args: the pulse server reuses numeric
# module ids, so stored ids alone are not proof of what a module is.

set -u

BOARD_SINK="${SBOARD_BOARD_SINK:-soundboard_board}"
VMIC_SINK="${SBOARD_VMIC_SINK:-soundboard_virtual_mic}"
STATE_DIR="${SBOARD_STATE_DIR:-$HOME/.local/state/omarchy-soundboard}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

mkdir -p "$STATE_DIR"

log() { printf '%s\n' "$*" >&2; }
die() { log "soundboard: $*"; exit 1; }
# Waybar caches custom-module output; nudge it so icon/state changes show now.
refresh_waybar() { pkill -RTMIN+7 -x waybar 2>/dev/null || true; }

# Serialize mutating commands: the shell can fire several setup calls at once
# (service reloads) and concurrent module loads race into duplicates.
acquire_lock() {
  exec 9>"$STATE_DIR/router.lock"
  timeout 20 flock -w 20 9 || die "router busy (another command holds the lock)"
}

require_pulse() {
  command -v pactl >/dev/null 2>&1 || die "pactl not found (install pipewire-pulse)"
  timeout 3 pactl info >/dev/null 2>&1 || die "PipeWire PulseAudio server not reachable"
}

# --- lookups ----------------------------------------------------------------

sink_index() {
  timeout 3 pactl list short sinks 2>/dev/null | awk -v n="$1" '$2 == n { print $1; exit }'
}

source_index() {
  timeout 3 pactl list short sources 2>/dev/null | awk -v n="$1" '$2 == n { print $1; exit }'
}

sink_module_id() {
  timeout 3 pactl list modules short 2>/dev/null | awk -F'\t' -v s="sink_name=$1" \
    '$2 == "module-null-sink" && index($3, s) { print $1; exit }'
}

loopback_module_id() {  # <source> <sink> — exact args + type match
  timeout 3 pactl list modules short 2>/dev/null | awk -F'\t' -v s="source=$1 sink=$2" \
    '$2 == "module-loopback" && $3 == s { print $1; exit }'
}

our_loopbacks() {
  timeout 3 pactl list modules short 2>/dev/null | awk -F'\t' -v b="$BOARD_SINK" -v v="$VMIC_SINK" \
    '$2 == "module-loopback" && ($3 ~ "sink=" v || $3 ~ "source=" b ".monitor" || $3 ~ "sink=" b) { print $1 }'
}

board_monitor_loopbacks() {  # loopbacks reading the board monitor (excl. vmic feed)
  timeout 3 pactl list modules short 2>/dev/null | awk -F'\t' -v s="source=$BOARD_SINK.monitor" -v v="$VMIC_SINK" \
    '$2 == "module-loopback" && index($3, s) == 1 && $3 !~ "sink=" v { print $1 }'
}

start_loopback() {
  local name="$1" capture="$2" playback="$3" id
  id=$(loopback_module_id "$capture" "$playback")
  if [ -n "$id" ]; then
    log "soundboard: loopback '$name' already active"
    return 0
  fi
  timeout 5 pactl load-module module-loopback source="$capture" sink="$playback" >/dev/null \
    || die "could not create loopback '$name'"
}

stop_loopback() {
  local capture="$1" playback="$2" id
  id=$(loopback_module_id "$capture" "$playback")
  [ -n "$id" ] && timeout 4 pactl unload-module "$id" 2>/dev/null
}

real_mic() {
  local mic default_src
  default_src=$(timeout 3 pactl get-default-source 2>/dev/null || true)
  if [ "$default_src" = "$VMIC_SINK.monitor" ]; then
    mic=$(cat "$STATE_DIR/real_mic" 2>/dev/null || true)
  else
    mic="$default_src"
  fi
  if [ -z "$mic" ] || [ "$mic" = "$VMIC_SINK.monitor" ]; then
    mic=$(timeout 3 pactl -f json list sources 2>/dev/null | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    name = s["name"]
    if "monitor" in name or name.startswith("soundboard_"):
        continue
    print(name); break
')
  fi
  [ -n "$mic" ] || die "no usable microphone found"
  printf '%s' "$mic"
}

# Restore the hardware mic if an older version left the virtual mic as default.
legacy_restore_default() {
  [ "$(timeout 3 pactl get-default-source 2>/dev/null)" = "$VMIC_SINK.monitor" ] || return 0
  local mic
  mic=$(cat "$STATE_DIR/real_mic" 2>/dev/null || true)
  if [ -n "$mic" ] && timeout 3 pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$mic"; then
    timeout 3 pactl set-default-source "$mic" && log "soundboard: default mic restored to $mic"
  fi
}

# --- on-demand stream bridging ---------------------------------------------

BRIDGE="$(cd "$(dirname "$0")" && pwd)/sb-bridge.py"

# The virtual mic's monitor is the actual recording tap. Keep it at unity so a
# stray per-app volume change cannot undo the per-clip loudness normalization.
normalize_vmic_tap() {
  timeout 3 pactl set-source-volume "$VMIC_SINK.monitor" 100% 2>/dev/null || true
  timeout 3 pactl set-source-mute "$VMIC_SINK.monitor" 0 2>/dev/null || true
}

engage_streams() {
  normalize_vmic_tap
  [ -n "$(source_index "$VMIC_SINK.monitor")" ] || return 0
  timeout 20 python3 "$BRIDGE" engage
}

release_streams() {
  timeout 20 python3 "$BRIDGE" release
}

# --- watcher daemon ---------------------------------------------------------

start_watcher() {
  local pidfile="$STATE_DIR/watcher.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    return 0
  fi
  rm -f "$pidfile" "$STATE_DIR/engaged" "$STATE_DIR/moved.tsv"
  # 9>&- : do not leak the router lock fd into the long-lived watcher
  setsid nohup "$SELF" watch >>"$STATE_DIR/watch.log" 2>&1 </dev/null 9>&- &
}

stop_watcher() {
  local pidfile="$STATE_DIR/watcher.pid" pid
  [ -f "$pidfile" ] || return 0
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$pidfile"
}

cmd_watch() {
  local pidfile="$STATE_DIR/watcher.pid"
  local fifo="$STATE_DIR/watch.fifo"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    exit 0
  fi
  echo $$ >"$pidfile"
  : >"$STATE_DIR/watch.log"
  local board_idx sub_pid
  board_idx=$(sink_index "$BOARD_SINK")
  [ -n "$board_idx" ] || { log "watcher: board sink missing"; rm -f "$pidfile"; exit 1; }

  rm -f "$fifo"
  mkfifo -m 600 "$fifo" || { rm -f "$pidfile"; exit 1; }
  pactl subscribe >"$fifo" 2>/dev/null &
  sub_pid=$!

  cleanup() {
    [ -n "${sub_pid:-}" ] && kill "$sub_pid" 2>/dev/null
    release_streams
    rm -f "$fifo" "$pidfile" "$STATE_DIR/engaged"
  }
  trap cleanup EXIT
  trap 'exit 0' INT TERM HUP

  local engaged=0 n
  board_stream_count() {
    timeout 2 pactl list short sink-inputs 2>/dev/null | awk -v s="$board_idx" '$2 == s' | wc -l
  }

  # a clip may already be playing when the watcher starts
  if [ "$(board_stream_count)" -gt 0 ]; then
    engaged=1
    : >"$STATE_DIR/engaged"
    log "$(date +%T) engaged"
    engage_streams
    refresh_waybar
  fi

  while IFS= read -r event; do
    case "$event" in
      *"sink-input"*|*"source-output"*) ;;
      *) continue ;;
    esac
    n=$(board_stream_count)
    if [ "$n" -gt 0 ]; then
      if [ "$engaged" = 0 ]; then
        engaged=1
        : >"$STATE_DIR/engaged"
        log "$(date +%T) engaged"
        refresh_waybar
      fi
      engage_streams
    elif [ "$engaged" = 1 ]; then
      sleep 0.5
      if [ "$(board_stream_count)" -eq 0 ]; then
        engaged=0
        rm -f "$STATE_DIR/engaged"
        release_streams
        log "$(date +%T) released"
        refresh_waybar
      fi
    fi
  done <"$fifo"
}

# --- commands ---------------------------------------------------------------

cmd_setup() {
  require_pulse
  acquire_lock
  local monitor="on"
  [ $# -gt 0 ] && monitor="$1"

  legacy_restore_default

  if [ -z "$(sink_module_id "$BOARD_SINK")" ]; then
    timeout 5 pactl load-module module-null-sink sink_name="$BOARD_SINK" \
      sink_properties='device.description="Soundboard Playback"' >/dev/null \
      || die "could not create soundboard playback sink"
  fi
  if [ -z "$(sink_module_id "$VMIC_SINK")" ]; then
    timeout 5 pactl load-module module-null-sink sink_name="$VMIC_SINK" \
      sink_properties='device.description="Soundboard Virtual Microphone"' >/dev/null \
      || die "could not create virtual microphone sink"
  fi

  local mic default_sink
  mic=$(real_mic)
  echo "$mic" >"$STATE_DIR/real_mic"
  default_sink=$(timeout 3 pactl get-default-sink 2>/dev/null || true)
  normalize_vmic_tap

  start_loopback voice "$mic" "$VMIC_SINK"
  start_loopback board "$BOARD_SINK.monitor" "$VMIC_SINK"
  if [ "$monitor" = "on" ] && [ -n "$default_sink" ]; then
    case "$default_sink" in
      "$BOARD_SINK"|"$VMIC_SINK") ;; # never loop into ourselves
      *) start_loopback monitor "$BOARD_SINK.monitor" "$default_sink" ;;
    esac
  else
    stop_loopback "$BOARD_SINK.monitor" "$default_sink"
  fi

  # drop loopbacks from older runs that do not match the canonical trio and
  # any duplicate copies of a canonical one (keep the first id per arg set)
  local seen="" args
  while IFS=$'\t' read -r id args; do
    [ -n "$id" ] || continue
    case "$args" in
      "source=$mic sink=$VMIC_SINK"|\
      "source=$BOARD_SINK.monitor sink=$VMIC_SINK"|\
      "source=$BOARD_SINK.monitor sink=$default_sink") ;;
      *) timeout 3 pactl unload-module "$id" 2>/dev/null; continue ;;
    esac
    case "|$seen|" in
      *"|$args|"*) timeout 3 pactl unload-module "$id" 2>/dev/null ;;
      *) seen="$seen|$args" ;;
    esac
  done < <(timeout 3 pactl list modules short 2>/dev/null | awk -F'\t' \
    -v b="$BOARD_SINK" -v v="$VMIC_SINK" \
    '$2 == "module-loopback" && ($3 ~ "sink=" v || $3 ~ "source=" b ".monitor" || $3 ~ "sink=" b) { print $1 "\t" $3 }')

  start_watcher
  log "soundboard: armed — mic stays '$mic'; clips bridge on demand"
  refresh_waybar
}

cmd_teardown() {
  require_pulse
  acquire_lock
  stop_watcher
  release_streams
  legacy_restore_default
  rm -f "$STATE_DIR/engaged" "$STATE_DIR/moved.tsv"
  # cascade: sink unload takes every dependent loopback with it
  for id in "$(sink_module_id "$VMIC_SINK")" "$(sink_module_id "$BOARD_SINK")"; do
    [ -n "$id" ] && timeout 4 pactl unload-module "$id" 2>/dev/null
  done
  for id in $(our_loopbacks); do
    timeout 3 pactl unload-module "$id" 2>/dev/null
  done
  log "soundboard: torn down — hardware mic untouched"
  refresh_waybar
}

cmd_monitor() {
  require_pulse
  case "${1:-}" in
    on)
      [ -n "$(sink_module_id "$BOARD_SINK")" ] || die "soundboard not armed (run: audio_router.sh setup)"
      local default_sink
      default_sink=$(timeout 3 pactl get-default-sink 2>/dev/null)
      start_loopback monitor "$BOARD_SINK.monitor" "$default_sink"
      log "soundboard: local monitor on"
      refresh_waybar
      ;;
    off)
      stop_loopback "$BOARD_SINK.monitor" "$(timeout 3 pactl get-default-sink 2>/dev/null)"
      log "soundboard: local monitor off"
      refresh_waybar
      ;;
    *) die "usage: audio_router.sh monitor on|off" ;;
  esac
}

cmd_volume() {
  require_pulse
  local arg="${1:-80}"
  local pct
  if [[ "$arg" =~ ^[+-][0-9]+$ ]]; then
    local cur
    cur=$(timeout 3 pactl get-sink-volume "$BOARD_SINK" 2>/dev/null | grep -om1 '[0-9]\+%' | tr -d '%' | head -n1)
    pct=$(( ${cur:-80} + arg ))
  else
    pct="$arg"
  fi
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=80
  pct=$(( pct < 0 ? 0 : pct > 100 ? 100 : pct ))
  timeout 3 pactl set-sink-volume "$BOARD_SINK" "${pct}%" || die "playback sink not present"
  log "soundboard: master volume ${pct}%"
  refresh_waybar
}

cmd_is_active() {
  [ -n "$(sink_module_id "$BOARD_SINK")" ] || exit 1
  [ -f "$STATE_DIR/watcher.pid" ] || exit 1
  kill -0 "$(cat "$STATE_DIR/watcher.pid" 2>/dev/null)" 2>/dev/null || exit 1
  exit 0
}

cmd_status() {
  local active=false watcher=false engaged=false monitor=false
  local real="" default_src="" vol=""
  timeout 3 pactl info >/dev/null 2>&1 || { echo '{"active":false,"server":false}'; exit 0; }
  [ -n "$(sink_module_id "$BOARD_SINK")" ] && active=true
  local wpid
  wpid=$(cat "$STATE_DIR/watcher.pid" 2>/dev/null || true)
  [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null && watcher=true
  [ -f "$STATE_DIR/engaged" ] && engaged=true
  [ -n "$(board_monitor_loopbacks)" ] && monitor=true
  real=$(cat "$STATE_DIR/real_mic" 2>/dev/null || true)
  default_src=$(timeout 3 pactl get-default-source 2>/dev/null || true)
  vol=$(timeout 3 pactl get-sink-volume "$BOARD_SINK" 2>/dev/null | grep -om1 '[0-9]\+%' | tr -d '%' | head -n1)
  printf '{"active":%s,"watcher":%s,"engaged":%s,"monitor":%s,"real_mic":"%s","default_source":"%s","volume":"%s","board_sink":"%s","vmic_sink":"%s"}\n' \
    "$active" "$watcher" "$engaged" "$monitor" "$real" "$default_src" "${vol:-80}" "$BOARD_SINK" "$VMIC_SINK"
}

cmd_toggle() {
  if cmd_is_active 2>/dev/null; then
    cmd_teardown
  else
    cmd_setup on
  fi
}

case "${1:-help}" in
  setup)     shift; cmd_setup "$@" ;;
  teardown)  cmd_teardown ;;
  toggle)    cmd_toggle ;;
  monitor)   shift; cmd_monitor "$@" ;;
  volume)    shift; cmd_volume "$@" ;;
  status)    cmd_status ;;
  is-active) cmd_is_active ;;
  watch)     cmd_watch ;;
  help|*)
    cat >&2 <<EOF
usage: audio_router.sh <command> [args]
  setup [on|off]   arm the virtual mic chain + on-demand watcher
  teardown         remove sinks + loopbacks, stop watcher (default mic untouched)
  toggle           setup if off, teardown if on
  monitor on|off   toggle local clip monitoring
  volume <n|+n|-n> set/relative-adjust board master volume (0-100)
  status           one-line JSON state
  is-active        exit 0 when armed and the watcher is running
EOF
    ;;
esac
