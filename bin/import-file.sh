#!/usr/bin/env bash
# import-file.sh SRC... — copy dropped files into the sounds dir.
# stdout: one line per file: "ok <name>" / "error <msg>"
set -u
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SOUNDS_DIR="${SBOARD_SOUNDS_DIR:-$CONFIG_HOME/omarchy/plugins/soundboard/sounds}"
GAIN_SCRIPT="$(cd "$(dirname "$0")" && pwd)/clip-gain.py"
mkdir -p "$SOUNDS_DIR"

for src in "$@"; do
  src="${src#file://}"
  src="${src//%20/ }"
  src="${src//%25/%}"
  if [ ! -f "$src" ]; then
    printf 'error not a file: %s\n' "$src"
    continue
  fi
  name=$(basename "$src")
  ext="${name##*.}"
  stem="${name%.*}"
  # keep Unicode (Arabic, emoji, …); Linux only forbids "/" and control chars
  clean="${stem//\//_}"
  clean="${clean//$'\n'/ }"
  clean="${clean//$'\t'/ }"
  clean="${clean//$'\r'/ }"
  clean="${clean#"${clean%%[![:space:]]*}"}"
  clean="${clean%"${clean##*[![:space:]]}"}"
  [ -n "$clean" ] || clean="clip"
  ext_lc=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
  if [[ "$ext_lc" =~ ^(mp3|wav|ogg|oga|flac|opus|m4a)$ ]]; then ext="$ext_lc"; else ext="mp3"; fi
  dest="$SOUNDS_DIR/$clean.$ext"
  i=2
  while [ -e "$dest" ]; do dest="$SOUNDS_DIR/$clean-$i.$ext"; i=$((i+1)); done
  if cp -f -- "$src" "$dest"; then
    printf 'ok %s\n' "$(basename "$dest")"
    [ -x "$GAIN_SCRIPT" ] && setsid "$GAIN_SCRIPT" "$dest" >/dev/null 2>&1 &
  else
    printf 'error copy failed: %s\n' "$src"
  fi
done
