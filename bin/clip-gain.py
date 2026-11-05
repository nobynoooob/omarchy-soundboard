#!/usr/bin/env python3
"""clip-gain.py FILE | --scan DIR — per-clip playback gain in dB.

Measures EBU R128 integrated loudness (and true peak) with ffmpeg and returns
the gain that lands the clip on the configured target, clamped so the measured
true peak never exceeds the ceiling. Results are cached by inode+size+mtime, so
renames do not invalidate them and repeat plays are instant.

Env:
    SBOARD_TARGET_LUFS   override target (default: config clipTargetLufs, -16)
    SBOARD_PEAK_CEIL     true-peak ceiling in dBFS (default -1.0)
    SBOARD_CONFIG        plugin config path
    SBOARD_STATE_DIR     cache root (default ~/.local/state/omarchy-soundboard)
"""

import fcntl
import json
import os
import re
import subprocess
import sys

AUDIO_EXTS = {".mp3", ".wav", ".ogg", ".oga", ".flac", ".opus", ".m4a"}
CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
CONFIG_PATH = os.environ.get(
    "SBOARD_CONFIG",
    os.path.join(CONFIG_HOME, "omarchy/plugins/soundboard/config.json"),
)
STATE_DIR = os.environ.get(
    "SBOARD_STATE_DIR", os.path.expanduser("~/.local/state/omarchy-soundboard")
)
CACHE_DIR = os.path.join(STATE_DIR, "gains")
PEAK_CEIL = float(os.environ.get("SBOARD_PEAK_CEIL", "-1.0"))
MAX_BOOST = 24.0
MAX_CUT = -30.0
SILENCE_LUFS = -60.0

_I_RE = re.compile(r"\bI:\s*(-?\d+(?:\.\d+)?)\s+LUFS")
_PEAK_RE = re.compile(r"\bPeak:\s*([+-]?\d+(?:\.\d+)?)\s+dBFS")


def target_lufs():
    if "SBOARD_TARGET_LUFS" in os.environ:
        try:
            return float(os.environ["SBOARD_TARGET_LUFS"])
        except ValueError:
            pass
    try:
        with open(CONFIG_PATH) as handle:
            return float(json.load(handle).get("clipTargetLufs", -16.0))
    except (OSError, ValueError, TypeError):
        return -16.0


def cache_key(path):
    st = os.stat(path)
    return f"{st.st_dev:x}-{st.st_ino:x}-{st.st_size:x}-{st.st_mtime_ns:x}"


def measure(path):
    """Return (integrated LUFS, true peak dBFS); either may be None."""
    try:
        done = subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-nostats", "-nostdin",
                "-i", path, "-map", "0:a:0",
                "-af", "ebur128=peak=true", "-f", "null", "-",
            ],
            capture_output=True, text=True, timeout=180,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, None
    log = done.stderr
    loud = _I_RE.findall(log)
    peak = _PEAK_RE.findall(log)
    return (
        float(loud[-1]) if loud else None,
        float(peak[-1]) if peak else None,
    )


def compute_gain(path, target):
    lufs, peak = measure(path)
    if lufs is None or lufs <= SILENCE_LUFS:
        # Too short/silent for an integrated measurement: don't guess, and
        # never blow up a silent sample.
        gain = 0.0
    else:
        gain = target - lufs
    if peak is not None:
        gain = min(gain, PEAK_CEIL - peak)
    return max(MAX_CUT, min(MAX_BOOST, gain)), lufs, peak


def gain_for(path, target):
    key = cache_key(path)
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache = os.path.join(CACHE_DIR, key)
    lock_path = cache + ".lock"
    with open(lock_path, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(cache) as handle:
                parts = handle.read().split()
            if len(parts) >= 4 and abs(float(parts[3]) - target) < 1e-6:
                return float(parts[0])
        except (OSError, ValueError):
            pass
        gain, lufs, peak = compute_gain(path, target)
        tmp = f"{cache}.{os.getpid()}.tmp"
        with open(tmp, "w") as handle:
            handle.write(f"{gain:.2f}\t{lufs}\t{peak}\t{target}\n")
        os.replace(tmp, cache)
        return gain


def main():
    if len(sys.argv) < 2:
        print("usage: clip-gain.py FILE | --scan DIR", file=sys.stderr)
        return 2
    target = target_lufs()

    if sys.argv[1] == "--scan":
        root = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser(
            "~/.config/omarchy/plugins/soundboard/sounds"
        )
        try:
            names = sorted(os.listdir(root))
        except OSError:
            return 1
        for name in names:
            if os.path.splitext(name)[1].lower() not in AUDIO_EXTS:
                continue
            path = os.path.join(root, name)
            if not os.path.isfile(path):
                continue
            try:
                gain = gain_for(path, target)
            except OSError:
                continue
            print(f"{gain:+6.2f} dB  {name}", file=sys.stderr)
        return 0

    path = sys.argv[1]
    if not os.path.isfile(path):
        print("0.00")
        return 1
    try:
        gain = gain_for(path, target)
    except (OSError, ValueError):
        gain = 0.0
    print(f"{gain:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
