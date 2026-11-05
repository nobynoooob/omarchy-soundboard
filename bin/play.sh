#!/usr/bin/env bash
# play.sh FILE [VOLUME_PCT] — play a clip into the soundboard playback sink.
# Clips are loudness-normalized (bin/clip-gain.py) before the master volume is
# applied, so quiet voice memos and loud music land at the same level.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOARD_SINK="${SBOARD_BOARD_SINK:-soundboard_board}"
STATE_DIR="${SBOARD_STATE_DIR:-$HOME/.local/state/omarchy-soundboard}"
PLAYING_DIR="$STATE_DIR/playing"
VOL="${2:-100}"
FILE="$1"

[ -f "$FILE" ] || { echo "play: no such file: $FILE" >&2; exit 1; }
[[ "$VOL" =~ ^[0-9]+$ ]] || VOL=100
mkdir -p "$PLAYING_DIR"
# opportunistic sweep of stale pidfiles from dead players
for f in "$PLAYING_DIR"/*; do
  [ -f "$f" ] || continue
  p=$(cat "$f" 2>/dev/null)
  [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && rm -f "$f"
done

GAIN=$("$SCRIPT_DIR/clip-gain.py" "$FILE" 2>/dev/null) || GAIN=0
[[ "$GAIN" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || GAIN=0

run() {
  local pid=$$
  echo "$pid" >"$PLAYING_DIR/$pid"
  # expand pid now; local goes out of scope before EXIT fires
  trap "rm -f '$PLAYING_DIR/$pid'" EXIT
  "$@"
}

if command -v mpv >/dev/null 2>&1; then
  run mpv --no-video --ao=pulse --audio-device="pulse/$BOARD_SINK" \
    --volume="$VOL" --volume-max=200 --af="volume=${GAIN}dB" \
    --really-quiet --no-terminal -- "$FILE"
elif command -v ffplay >/dev/null 2>&1; then
  PULSE_SINK="$BOARD_SINK" run ffplay -nodisp -autoexit -loglevel error \
    -af "volume=${GAIN}dB" -i "$FILE"
elif command -v pw-cat >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1; then
  # pw-cat cannot apply gain; decode+normalize through ffmpeg, then pipe PCM.
  run bash -c 'ffmpeg -hide_banner -loglevel error -nostdin -i "$1" -map 0:a:0 \
    -af "volume=$2dB" -f f32le -ac 2 -ar 48000 - | \
    pw-cat --playback --raw --format f32 --rate 48000 --channels 2 \
      --target "$3" --volume "$4" -' \
    _ "$FILE" "$GAIN" "$BOARD_SINK" "$(awk "BEGIN{print $VOL/100}")"
elif command -v pw-cat >/dev/null 2>&1; then
  run pw-cat --playback --target "$BOARD_SINK" \
    --volume "$(awk "BEGIN{print $VOL/100}")" -- "$FILE"
else
  echo "play: no player found (install mpv or ffmpeg)" >&2
  exit 1
fi
