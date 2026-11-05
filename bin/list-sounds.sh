#!/usr/bin/env bash
# list-sounds.sh — emit the sounds directory as a JSON array.
set -u
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SOUNDS_DIR="${SBOARD_SOUNDS_DIR:-$CONFIG_HOME/omarchy/plugins/soundboard/sounds}"
mkdir -p "$SOUNDS_DIR"

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

first=1
printf '['
while IFS= read -r -d '' file; do
  base=$(basename "$file")
  name="${base%.*}"
  [ "$first" = 1 ] || printf ','
  first=0
  printf '{"name":"%s","file":"%s"}' "$(json_escape "$name")" "$(json_escape "$base")"
done < <(
  find "$SOUNDS_DIR" -maxdepth 1 -type f \( \
    -iname '*.mp3' -o -iname '*.wav' -o -iname '*.ogg' -o -iname '*.flac' \
    -o -iname '*.opus' -o -iname '*.m4a' \) -print0 2>/dev/null | sort -z
)
printf ']\n'
