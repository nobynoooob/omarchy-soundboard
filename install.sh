#!/usr/bin/env bash
# Optional post-install setup for the Omarchy Soundboard plugin.
#
# `omarchy plugin add <url> --enable` is the normal install path. Run this
# script after a manual clone (or after adding the plugin) to verify
# dependencies, fix executable bits, create the clips directory, and rescan
# the shell.
#
#   ./install.sh                 check dependencies and prepare the plugin
#   ./install.sh --install-deps  install missing packages with pacman
#   ./install.sh --skip-deps     configure files only
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="nobynoooob.soundboard"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
PLUGINS_DIR="$CONFIG_HOME/omarchy/plugins"
DATA_DIR="$PLUGINS_DIR/soundboard"
SOUNDS_DIR="$DATA_DIR/sounds"

INSTALL_DEPS=0
SKIP_DEPS=0

for arg in "$@"; do
  case "$arg" in
    --install-deps) INSTALL_DEPS=1 ;;
    --skip-deps) SKIP_DEPS=1 ;;
    -h | --help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "install.sh: unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# Package -> probe. Probes are used before pacman so the script also works on
# non-Arch systems and inside containers.
missing=()
recommended=()

check_required() {
  local pkg="$1" probe="$2" label="$3"
  if eval "$probe" >/dev/null 2>&1; then
    return 0
  fi
  missing+=("$pkg")
  printf '  missing  %-18s %s\n' "$pkg" "$label"
}

check_optional() {
  local pkg="$1" probe="$2" label="$3"
  if eval "$probe" >/dev/null 2>&1; then
    return 0
  fi
  recommended+=("$pkg")
  printf '  optional %-18s %s\n' "$pkg" "$label"
}

if (( ! SKIP_DEPS )); then
  say "Checking dependencies:"
  check_required pipewire-pulse "pactl info | grep -qi 'PipeWire'" "PipeWire PulseAudio bridge"
  check_required python-gobject "python3 -c 'import gi'" "GTK window (PyGObject)"
  check_required gtk3 "python3 -c 'import gi; gi.require_version(\"Gtk\", \"3.0\")'" "GTK3 runtime"
  check_required yt-dlp "command -v yt-dlp" "URL imports"
  check_optional mpv "command -v mpv" "best playback quality"
  check_optional ffmpeg "command -v ffmpeg" "loudness normalization"
  check_optional curl "command -v curl" "direct audio downloads"

  if (( ${#missing[@]} )); then
    pkgs="${missing[*]}"
    if (( INSTALL_DEPS )); then
      command -v pacman >/dev/null 2>&1 || {
        echo "install.sh: pacman not found; install manually: $pkgs" >&2
        exit 1
      }
      say "Installing: $pkgs"
      sudo pacman -S --needed --noconfirm $pkgs
    else
      printf '\nMissing required packages:\n  sudo pacman -S --needed %s\n' "$pkgs" >&2
      printf 'Re-run with --install-deps to do this automatically, or --skip-deps to configure anyway.\n' >&2
      exit 1
    fi
  fi

  if (( ${#recommended[@]} )); then
    printf '\nRecommended packages:\n  sudo pacman -S --needed %s\n' "${recommended[*]}"
  fi

  if ! pactl info 2>/dev/null | grep -qi 'PipeWire'; then
    warn "PipeWire does not look reachable; the virtual mic will not work."
  fi
fi

say "Preparing files:"
chmod +x "$ROOT"/bin/*.sh "$ROOT"/bin/*.py "$ROOT"/soundboard.py
mkdir -p "$SOUNDS_DIR"
say "  executable bits set"
say "  clips directory: $SOUNDS_DIR"

# No compiled assets in this plugin; QML and Python are loaded from source.
say "  assets: none to build"

if [[ "$ROOT" == "$PLUGINS_DIR/"* ]]; then
  if command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    say "  omarchy-shell rescanned"
  else
    warn "omarchy-shell not found; rescan the plugin after starting Omarchy."
  fi
else
  warn "this copy is not under ~/.config/omarchy/plugins; install it with:"
  warn "  omarchy plugin add https://github.com/nobynoooob/omarchy-soundboard.git --enable"
fi

say ""
say "Done. Enable it with: omarchy plugin enable $PLUGIN_ID"
say "Add the Hyprland window rule from README.md so the panel opens pinned."
