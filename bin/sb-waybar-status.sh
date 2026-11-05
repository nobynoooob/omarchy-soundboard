#!/usr/bin/env bash
# sb-waybar-status.sh — JSON for Waybar's custom/soundboard module.
#
# The icon glyph lives here (single source of truth for Waybar); override it
# with SBOARD_ICON if you prefer another Nerd Font glyph. Classes map to
# style.css: inactive (off) / armed (mic untouched) / engaged (clips bridged).
set -u

ICON="${SBOARD_ICON:-󰝚}"
ROUTER="${SBOARD_ROUTER:-$(cd "$(dirname "$0")" && pwd)/audio_router.sh}"

json() {
  printf '{"text":"%s","class":"%s","tooltip":"%s"}' "$ICON" "$1" "$2"
}

status=$("$ROUTER" status 2>/dev/null) || { json inactive "Soundboard offline"; exit 0; }

if [[ "$status" == *'"active":true'* ]]; then
  if [[ "$status" == *'"engaged":true'* ]]; then
    json engaged "Soundboard · clips live — mic bridged"
  else
    tip="Soundboard armed — mic untouched, bridges on play"
    [[ "$status" == *'"monitor":true'* ]] && tip+=" · local monitor on"
    json armed "$tip"
  fi
else
  json inactive "Soundboard off — right-click to arm"
fi
