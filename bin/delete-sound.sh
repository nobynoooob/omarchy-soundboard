#!/usr/bin/env bash
# delete-sound.sh NAME — remove a clip from the sounds dir (basename-guarded).
set -u
SOUNDS_DIR="${SBOARD_SOUNDS_DIR:-$HOME/.config/omarchy/plugins/soundboard/sounds}"
name="${1:-}"
[ -n "$name" ] || { echo "error no name" >&2; exit 1; }
name=$(basename "$name") # no traversal
shopt -s nullglob
if [ -f "$SOUNDS_DIR/$name" ]; then
  matches=("$SOUNDS_DIR/$name")
else
  matches=("$SOUNDS_DIR/${name%.*}".*)
fi
if [ "${#matches[@]}" -eq 0 ]; then
  echo "error not found: $name"
  exit 1
fi
rm -f -- "${matches[@]}"
echo "ok $name"
