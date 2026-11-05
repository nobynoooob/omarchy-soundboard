#!/usr/bin/env bash
# download.sh URL [NAME] — pull audio into the sounds dir via yt-dlp or curl.
# stdout: final line "ok <filename>" on success, "error <message>" on failure.
set -u
SOUNDS_DIR="${SBOARD_SOUNDS_DIR:-$HOME/.config/omarchy/plugins/soundboard/sounds}"
GAIN_SCRIPT="$(cd "$(dirname "$0")" && pwd)/clip-gain.py"
URL="$1"
NAME="${2:-}"
mkdir -p "$SOUNDS_DIR"

say() { printf '%s\n' "$*"; }
fail() { say "error $*"; exit 1; }
scan() { [ -x "$GAIN_SCRIPT" ] && [ -f "$1" ] && setsid "$GAIN_SCRIPT" "$1" >/dev/null 2>&1 & }

case "$URL" in
  http://*|https://*) ;;
  file://*)
    src="${URL#file://}"
    src="${src//%20/ }"
    [ -f "$src" ] || fail "file not found: $src"
    fname="${NAME:-$(basename "$src")}"
    cp -f "$src" "$SOUNDS_DIR/$fname" || fail "copy failed"
    scan "$SOUNDS_DIR/$fname"
    say "ok $fname"
    exit 0
    ;;
  *) fail "not a http(s) URL: $URL" ;;
esac

audio_ext='*\.(mp3|wav|ogg|oga|flac|opus|m4a)'

if [[ "$URL" =~ \.mp3(\?|$) || "$URL" =~ \.wav(\?|$) || "$URL" =~ \.ogg(\?|$) || "$URL" =~ \.flac(\?|$) ]]; then
  fname="${NAME:-$(basename "${URL%%\?*}")}"
  [[ "$fname" =~ $audio_ext ]] || fname="$fname.mp3"
  curl -fsSL --max-time 120 -o "$SOUNDS_DIR/$fname" "$URL" \
    || fail "curl download failed"
  scan "$SOUNDS_DIR/$fname"
  say "ok $fname"
  exit 0
fi

command -v yt-dlp >/dev/null 2>&1 || fail "yt-dlp not installed (sudo pacman -S yt-dlp)"

tmpout="$SOUNDS_DIR/.yt-dlp.out"
if [ -n "$NAME" ]; then
  yt-dlp -x --audio-format mp3 --audio-quality 4 \
    -o "$SOUNDS_DIR/$NAME.%(ext)s" -- "$URL" >"$tmpout" 2>&1 \
    || { tail -3 "$tmpout" >&2; fail "yt-dlp failed (see stderr)"; }
  scan "$SOUNDS_DIR/$NAME.mp3"
  say "ok $NAME.mp3"
else
  yt-dlp -x --audio-format mp3 --audio-quality 4 \
    -o "$SOUNDS_DIR/%(title)s.%(ext)s" -- "$URL" >"$tmpout" 2>&1 \
    || { tail -3 "$tmpout" >&2; fail "yt-dlp failed (see stderr)"; }
  newest=$(ls -t "$SOUNDS_DIR"/*.mp3 2>/dev/null | head -1)
  [ -n "$newest" ] && scan "$newest"
  [ -n "$newest" ] && say "ok $(basename "$newest")" || say "ok"
fi
