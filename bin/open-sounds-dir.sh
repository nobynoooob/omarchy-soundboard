#!/usr/bin/env bash
# open-sounds-dir.sh — open the clips folder in the default file manager.
set -u

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SOUNDS_DIR="${SBOARD_SOUNDS_DIR:-$CONFIG_HOME/omarchy/plugins/soundboard/sounds}"
mkdir -p "$SOUNDS_DIR"
exec xdg-open "$SOUNDS_DIR"
