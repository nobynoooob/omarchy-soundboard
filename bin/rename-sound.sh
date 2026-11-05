#!/usr/bin/env bash
# rename-sound.sh OLD NEW — rename a clip, preserving its extension.
#
# OLD may be a filename or a bare stem. NEW is the display name; Unicode is
# kept as-is (Arabic, emoji, …). A supported audio extension typed into NEW is
# stripped and the clip's real extension is kept.
set -u

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SOUNDS_DIR="${SBOARD_SOUNDS_DIR:-$CONFIG_HOME/omarchy/plugins/soundboard/sounds}"
old="${1:-}"
new="${2:-}"

[ -n "$old" ] && [ -n "$new" ] || { echo "error usage: rename-sound.sh OLD NEW" >&2; exit 1; }

# trim surrounding whitespace
new="${new#"${new%%[![:space:]]*}"}"
new="${new%"${new##*[![:space:]]}"}"
[ -n "$new" ] || { echo "error empty name" >&2; exit 1; }

case "$new" in
  */*|.|..) echo "error invalid name" >&2; exit 1 ;;
  *$'\n'*|*$'\t'*|*$'\r'*) echo "error invalid name" >&2; exit 1 ;;
esac

# strip a supported extension from the new name; keep the original one
shopt -s nocasematch
for ext in mp3 wav ogg oga flac opus m4a; do
  if [[ "$new" == *."$ext" ]]; then new="${new%.*}"; break; fi
done
shopt -u nocasematch
[ -n "$new" ] || { echo "error empty name" >&2; exit 1; }

shopt -s nullglob
if [ -f "$SOUNDS_DIR/$old" ]; then
  src="$SOUNDS_DIR/$old"
else
  matches=("$SOUNDS_DIR/${old%.*}".*)
  [ "${#matches[@]}" -eq 1 ] && [ -f "${matches[0]}" ] \
    || { echo "error not found: $old" >&2; exit 1; }
  src="${matches[0]}"
fi

ext="${src##*.}"
target="$SOUNDS_DIR/$new.$ext"

if [ "$src" = "$target" ]; then
  echo "ok $new"
  exit 0
fi
[ -e "$target" ] && { echo "error name exists: $new" >&2; exit 1; }

mv -- "$src" "$target" || { echo "error rename failed" >&2; exit 1; }
echo "ok $new"
