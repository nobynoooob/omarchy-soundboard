# Omarchy Soundboard

A soundboard for Omarchy that plays clips **into your microphone stream**, so
Discord, OBS, WhatsApp, and browser calls hear your voice plus the board. Clips
can also be monitored locally. The engine stays armed in the background and
only bridges your real microphone while a clip is playing, so apps that hold or
re-detect the default mic never lose it.

## Install

One command, straight from git:

```bash
omarchy plugin add https://github.com/nobynoooob/omarchy-soundboard.git --enable
```

`--enable` places the 󰝚 widget in the bar. In scripts or non-interactive shells,
add `--yes` to skip the trust prompt.

Optional post-install setup (dependency check, executable bits, clips folder,
shell rescan):

```bash
~/.config/omarchy/plugins/nobynoooob.soundboard/install.sh
```

Then add the window rule from [Hyprland rule](#hyprland-rule) so the panel opens
pinned in the corner.

## Requirements

| Package | Why |
|---|---|
| `pipewire-pulse` | PulseAudio bridge used by the virtual-mic graph |
| `python-gobject` + `gtk3` | the persistent soundboard window |
| `yt-dlp` | YouTube and other URL imports |
| `mpv` *(recommended)* | best playback path; `ffplay`/`pw-cat` also work |
| `ffmpeg` *(recommended)* | EBU R128 loudness normalization |
| `curl` *(recommended)* | direct HTTP audio downloads |

```bash
sudo pacman -S pipewire-pulse python-gobject gtk3 yt-dlp mpv ffmpeg curl
```

Omarchy already ships PipeWire, Hyprland, and `omarchy-shell`. The plugin is a
native bar widget; Waybar support is optional.

## Usage

- **Left-click the 󰝚 bar icon** — open or close the pinned soundboard window.
- **Right-click the bar icon** — arm or disarm the virtual microphone.
- **Scroll over the icon** — master volume (0–100%).
- **Click a cell** — play a clip. Multiple clips overlap; *Stop All* clears
  everything.
- **Drag MP3/WAV/OGG/FLAC/OPUS/M4A files** from any file manager onto the
  window. Drop several at once; Unicode and Arabic filenames are preserved.
- **Paste a URL** — YouTube links go through `yt-dlp`, direct audio links
  through `curl`.
- **Right-click a cell** — rename or delete it. Renaming keeps the original
  extension; Enter saves, Esc cancels.
- **Click the 󰉋 folder button** — open the clips directory in your file manager.
- **In call apps** keep selecting your normal microphone. During playback the
  stream is bridged so everyone hears the clip; afterwards your mic is restored.

Clips are **level-matched**: `bin/clip-gain.py` measures EBU R128 integrated
loudness once per file and caches the gain. `bin/play.sh` applies it before
playback, targeting `clipTargetLufs` (default **-16 LUFS**) with true peak
capped at **-1 dBFS**. A quiet voice memo and a loud song arrive at the same
perceived level instead of one sounding distant and the next clipping.

### Configuration

`~/.config/omarchy/plugins/soundboard/config.json`:

```json
{
  "autoSetup": true,
  "monitorLocal": true,
  "masterVolume": 100,
  "clipTargetLufs": -16.0
}
```

- `clipTargetLufs`: `-14.0` is louder, `-18.0` is quieter.
- `monitorLocal`: also route clips to your speakers.
- `autoSetup`: arm the router when the shell starts.

After changing `clipTargetLufs`, delete
`~/.local/state/omarchy-soundboard/gains/` to force re-measurement.

## How it works

```
                     ┌──────────────────────────── PipeWire ────────────────────────────┐
 soundboard clips ──▶│ soundboard_board (null sink)                                     │
                     │    ├─.monitor ─ loopback ─▶ soundboard_virtual_mic (null sink)   │
                     │    │                          └─.monitor  ◀── bridged recorders │
                     │    └─.monitor ─ loopback ─▶ default speakers (local monitor)     │
 your real mic ─────▶│ loopback ─────────────────▶ soundboard_virtual_mic               │
                     └──────────────────────────────────────────────────────────────────┘
```

- `bin/audio_router.sh setup` creates two null sinks and three PulseAudio
  loopbacks, then starts a watcher daemon. **The system default source is never
  changed.**
- While a clip plays, `bin/sb-bridge.py` relinks live recorder streams into the
  virtual mic with `pw-link`; when playback stops they return to their original
  source.
- The bridge talks to PipeWire directly: on a WirePlumber + EasyEffects stack,
  `pactl move-source-output` reports success but the stream never leaves its
  source, and default-source changes do not relink running streams.
- `bin/play.sh` auto-picks a player (`mpv` → `ffplay` → `pw-cat`) and targets
  the board sink. `bin/stop-all.sh` reaps every running clip.

## Hyprland rule

The window is undecorated, pinned, and placed under the bar on the right edge.
Add this to `~/.config/hypr/hyprland.lua` and reload Hyprland
(`hyprctl reload`):

```lua
o.window("nobynoooob.soundboard", {
  float = true,
  pin = true,
  size = { 380, 560 },
  move = { "(monitor_w-window_w-12)", "56" },
})
```

## Waybar (optional)

Stock Omarchy runs `omarchy-shell` with the native QML widget. If you use
Waybar instead, merge [`waybar_config.json`](waybar_config.json) into your
config and append the CSS snippet to `style.css`.

- The module emits JSON classes: `inactive` (off), `armed` (mic untouched),
  `engaged` (clips bridged).
- Left-click opens the window, right-click arms/disarms the router, middle-click
  stops all clips, and scrolling changes the master volume.
- Waybar caches `"interval": 0` output. Refresh it after edits:

  ```bash
  ~/.config/omarchy/plugins/nobynoooob.soundboard/bin/reload-waybar.sh
  ```

  The router already signals Waybar on arm, play, release, and volume changes.

## Troubleshooting

- **Nothing plays** — `bin/audio_router.sh status`. If `"active":false` or
  `"watcher":false`, run `bin/audio_router.sh setup on`.
- **Callers never hear clips** — during playback `status` must show
  `"engaged":true`. Check `~/.local/state/omarchy-soundboard/watch.log` for
  `bridged` / `released` lines and confirm the app is recording.
- **Mic missing in an app** — the plugin never changes the default source. If an
  older install left the virtual mic as default, the next `setup` restores the
  hardware mic.
- **Clips feel quieter or louder than your voice** — adjust `clipTargetLufs`
  (see [Configuration](#configuration)).
- **MP3 silent** — install `mpv` or `ffmpeg`.
- **yt-dlp fails** — `sudo pacman -Syu yt-dlp`.
- **Reset audio** — `bin/audio_router.sh teardown` removes sinks and loopbacks
  and releases every bridged stream. Default devices are untouched.

## Files

```
omarchy-soundboard/
├── manifest.json            # schema 1, bar-widget only
├── BarWidget.qml            # bar icon; embeds the engine via Loader
├── Service.qml              # engine/state: scripts, config, status polling
├── soundboard.py            # persistent GTK3 window (drag-drop, URL, grid)
├── install.sh               # optional dependency check + setup
├── waybar_config.json       # optional Waybar custom-module snippet
├── .gitignore
├── LICENSE
├── bin/
│   ├── audio_router.sh      # sinks, loopbacks, watcher, status
│   ├── sb-bridge.py         # on-demand pw-link stream bridging
│   ├── play.sh              # normalized playback into the board
│   ├── clip-gain.py         # EBU R128 gain cache
│   ├── stop-all.sh          # kill running clips
│   ├── list-sounds.sh       # sounds dir → JSON
│   ├── download.sh          # yt-dlp / curl import
│   ├── import-file.sh       # drag-and-drop import (Unicode-safe)
│   ├── rename-sound.sh      # rename a clip, keep its extension
│   ├── delete-sound.sh      # remove a clip
│   ├── open-sounds-dir.sh   # open the clips folder
│   ├── toggle-soundboard.sh # open/close the window
│   ├── reload-waybar.sh     # refresh/restart Waybar
│   └── sb-waybar-status.sh  # Waybar JSON status
└── README.md
```

Storage:

| Path | Purpose |
|---|---|
| `~/.config/omarchy/plugins/soundboard/sounds/` | clips |
| `~/.config/omarchy/plugins/soundboard/config.json` | volume, monitor, `clipTargetLufs` |
| `~/.local/state/omarchy-soundboard/` | pids, `watch.log`, `moved.tsv`, `gains/` |

Environment overrides: `SBOARD_SOUNDS_DIR`, `SBOARD_CONFIG`,
`SBOARD_STATE_DIR`, `SBOARD_BOARD_SINK`, `SBOARD_VMIC_SINK`,
`SBOARD_TARGET_LUFS`, `SBOARD_PEAK_CEIL`.

## Remove

```bash
omarchy plugin remove nobynoooob.soundboard
```

The command removes the plugin checkout. Clips, config, and router state are
kept; delete them explicitly if you want a clean slate:

```bash
rm -rf ~/.config/omarchy/plugins/soundboard ~/.local/state/omarchy-soundboard
```

## License

MIT — see [LICENSE](LICENSE).
