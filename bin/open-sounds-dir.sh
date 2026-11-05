#!/usr/bin/env bash
# open-sounds-dir.sh — open the clips folder in the default file manager.
set -u

SOUNDS_DIR="${SBOARD_SOUNDS_DIR:-$HOME/.config/omarchy/plugins/soundboard/sounds}"
mkdir -p "$SOUNDS_DIR"
exec xdg-open "$SOUNDS_DIR"
