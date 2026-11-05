#!/usr/bin/env python3
"""Omarchy Soundboard — persistent GTK3 panel front-end.

Plays clips through the soundboard playback sink (bin/audio_router.sh topology),
so they land in the virtual microphone AND the local speakers. Drag-and-drop
files or paste a URL to import. The window is pinned/floated by a Hyprland
rule; bin/toggle-soundboard.sh owns its lifecycle.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import threading
import urllib.parse

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

APP_ID = "nobynoooob.soundboard"
PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(PLUGIN_DIR, "bin")
SOUNDS_DIR = os.environ.get(
    "SBOARD_SOUNDS_DIR",
    os.path.expanduser("~/.config/omarchy/plugins/soundboard/sounds"),
)
CONFIG_PATH = os.environ.get(
    "SBOARD_CONFIG",
    os.path.expanduser("~/.config/omarchy/plugins/soundboard/config.json"),
)
STATE_DIR = os.environ.get(
    "SBOARD_STATE_DIR",
    os.path.expanduser("~/.local/state/omarchy-soundboard"),
)
UI_PID = os.path.join(STATE_DIR, "ui.pid")
AUDIO_EXTS = {".mp3", ".wav", ".ogg", ".oga", ".flac", ".opus", ".m4a"}


def run_script(name, *args):
    """Run a plugin script, returning (rc, stdout, stderr)."""
    try:
        p = subprocess.run(
            [os.path.join(BIN, name), *args],
            capture_output=True, text=True, timeout=180,
        )
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (subprocess.TimeoutExpired, OSError) as e:
        return 1, "", str(e)


def spawn_script(name, *args):
    subprocess.Popen(
        [os.path.join(BIN, name), *args],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def clip_path(name):
    """Resolve a clip stem (or filename) to an existing audio file."""
    direct = os.path.join(SOUNDS_DIR, name)
    if os.path.isfile(direct) and os.path.splitext(direct)[1].lower() in AUDIO_EXTS:
        return direct
    stem = os.path.splitext(os.path.basename(name))[0]
    try:
        entries = sorted(os.listdir(SOUNDS_DIR))
    except OSError:
        return None
    for entry in entries:
        base, ext = os.path.splitext(entry)
        if base == stem and ext.lower() in AUDIO_EXTS:
            full = os.path.join(SOUNDS_DIR, entry)
            if os.path.isfile(full):
                return full
    return None


def load_theme():
    """Pull accent/bg/fg from the active Omarchy theme; fall back to dark grays."""
    colors = {
        "background": "#0a0a0a", "lighter_background": "#14201e",
        "foreground": "#c8dcdc", "muted": "#647f7f", "accent": "#ADF0E9",
    }
    try:
        name = open(os.path.expanduser(
            "~/.local/state/omarchy/current/theme.name")).read().strip()
        toml = open(os.path.expanduser(
            f"~/.config/omarchy/themes/{name}/colors.toml")).read()
        for key in colors:
            m = re.search(rf'^\s*{key}\s*=\s*"(#[0-9A-Fa-f]{{6}})"', toml, re.M)
            if m:
                colors[key] = m.group(1)
    except (OSError, re.error):
        pass
    return colors


def load_config():
    cfg = {
        "autoSetup": True,
        "monitorLocal": True,
        "masterVolume": 80,
        "clipTargetLufs": -16.0,
    }
    try:
        with open(CONFIG_PATH) as f:
            cfg.update({k: v for k, v in json.load(f).items() if k in cfg})
    except (OSError, ValueError):
        pass
    try:
        cfg["masterVolume"] = max(0, min(100, int(cfg.get("masterVolume", 80))))
    except (TypeError, ValueError):
        cfg["masterVolume"] = 80
    try:
        cfg["clipTargetLufs"] = max(-24.0, min(-10.0, float(cfg["clipTargetLufs"])))
    except (TypeError, ValueError):
        cfg["clipTargetLufs"] = -16.0
    return cfg


def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)


class SoundCell(Gtk.Button):
    def __init__(self, name, parent):
        super().__init__()
        self.parent_panel = parent
        self.sound_name = name
        box = Gtk.Box(spacing=6)
        icon = Gtk.Label(label="󰝚")
        icon.get_style_context().add_class("cell-icon")
        text = Gtk.Label(label=name, halign=Gtk.Align.START, ellipsize=3, width_chars=12)
        text.set_max_width_chars(13)
        text.get_style_context().add_class("clip-name")
        box.pack_start(icon, False, False, 0)
        box.pack_start(text, True, True, 0)
        self.add(box)
        self.get_style_context().add_class("sound-cell")
        self.connect("clicked", self.on_clicked)
        self.connect("button-press-event", self.on_button)

    def on_clicked(self, _btn):
        self.parent_panel.play_clip(self.sound_name)

    def on_button(self, _btn, event):
        if event.button.button != 3:  # left click plays, right click edits
            return False
        menu = Gtk.Popover(relative_to=self)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, margin=6)
        rename = Gtk.Button(label="󰏫  Rename")
        rename.get_style_context().add_class("ghost")
        delete = Gtk.Button(label="󰩹  Delete")
        delete.get_style_context().add_class("ghost")
        delete.get_style_context().add_class("destructive")
        rename.connect("clicked", lambda _b: (
            menu.popdown(), GLib.idle_add(self.parent_panel.rename_clip, self)))
        delete.connect("clicked", lambda _b: (
            menu.popdown(), GLib.idle_add(self.parent_panel.delete_clip, self)))
        box.pack_start(rename, False, False, 0)
        box.pack_start(delete, False, False, 0)
        menu.add(box)
        self.parent_panel.keep_popover(menu)
        menu.show_all()
        return True


class SoundboardWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="Soundboard")
        self.theme = load_theme()
        self.config = load_config()
        self._vol_timer = None

        self.set_default_size(380, 560)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_type_hint(Gdk.WindowTypeHint.DIALOG)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        self.connect("key-press-event", self.on_key)

        self.apply_css()
        self.build_ui()
        self.setup_dnd()

        GLib.timeout_add(150, self.bootstrap_audio)
        GLib.timeout_add(2000, self._poll_status)
        self.refresh_sounds()
        self.refresh_router_status()
        spawn_script("clip-gain.py", "--scan", SOUNDS_DIR)

    # ------------------------------------------------------------------ theme

    def apply_css(self):
        t = self.theme
        rgba = lambda hex, a: (f"rgba({int(hex[1:3],16)}, {int(hex[3:5],16)}, "
                               f"{int(hex[5:7],16)}, {a})")
        css = f"""
            window {{ background: {rgba(t['background'], 0.97)}; border-radius: 14px;
                      border: 1px solid {rgba(t['accent'], 0.45)}; }}
            .panel-title {{ color: {t['foreground']}; font-weight: 700; font-size: 14px; }}
            .panel-sub {{ color: {t['muted']}; font-size: 11px; }}
            .header {{ padding: 12px 14px 8px 14px; }}
            .drop-zone {{ background: {rgba(t['lighter_background'], 0.6)};
                          border: 1px dashed {rgba(t['accent'], 0.5)};
                          border-radius: 10px; padding: 10px; }}
            .drop-zone.hot {{ background: {rgba(t['accent'], 0.14)};
                              border-style: solid; }}
            .drop-zone label {{ color: {t['muted']}; font-size: 11px; }}
            entry {{ background: {t['lighter_background']}; color: {t['foreground']};
                     border: 1px solid {rgba(t['foreground'], 0.15)};
                     border-radius: 8px; padding: 7px 10px; font-size: 12px;
                     font-family: "JetBrainsMono Nerd Font", "Noto Naskh Arabic",
                                  "Noto Kufi Arabic", sans-serif; }}
            entry:focus {{ border-color: {rgba(t['accent'], 0.8)}; }}
            .sound-cell {{ background: {t['lighter_background']}; color: {t['foreground']};
                           border: 1px solid {rgba(t['foreground'], 0.10)};
                           border-radius: 8px; padding: 8px 10px;
                           transition: border-color 120ms ease; }}
            .sound-cell:hover {{ border-color: {rgba(t['accent'], 0.85)}; }}
            .sound-cell:active {{ background: {rgba(t['accent'], 0.22)}; }}
            .sound-cell .cell-icon {{ color: {t['accent']}; font-size: 12px; }}
            .sound-cell label {{ color: {t['foreground']}; font-size: 12px;
                                 font-family: "JetBrainsMono Nerd Font",
                                              "Noto Naskh Arabic", sans-serif; }}
            .destructive {{ color: #ff6b6b; }}
            scale trough {{ background: {t['lighter_background']}; border-radius: 3px;
                            min-height: 5px; }}
            scale highlight {{ background: {t['accent']}; border-radius: 3px; }}
            scale slider {{ background: {t['foreground']}; border-radius: 7px;
                            min-height: 13px; min-width: 13px; margin: -4px; }}
            .ghost {{ background: transparent; color: {t['foreground']};
                      border: 1px solid {rgba(t['foreground'], 0.18)};
                      border-radius: 8px; padding: 7px 10px; font-size: 12px; }}
            .ghost:hover {{ border-color: {rgba(t['accent'], 0.85)}; }}
            .ghost.active {{ border-color: {t['accent']}; color: {t['accent']}; }}
            .status {{ color: {t['muted']}; font-size: 11px; padding: 4px 14px 10px 14px; }}
        """
        prov = Gtk.CssProvider()
        prov.load_from_data(css.encode())
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    # ------------------------------------------------------------------ ui

    def build_ui(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(outer)

        header = Gtk.Box(spacing=8)
        header.get_style_context().add_class("header")
        icon = Gtk.Label(label="󰝚")
        icon.get_style_context().add_class("cell-icon")
        title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        self.title = Gtk.Label(label="Soundboard", halign=Gtk.Align.START)
        self.title.get_style_context().add_class("panel-title")
        self.subtitle = Gtk.Label(label="…", halign=Gtk.Align.START)
        self.subtitle.get_style_context().add_class("panel-sub")
        self.subtitle.set_ellipsize(3)
        self.subtitle.set_max_width_chars(26)
        title_box.pack_start(self.title, False, False, 0)
        title_box.pack_start(self.subtitle, False, False, 0)
        close = Gtk.Button(label="󰅖")
        close.get_style_context().add_class("ghost")
        close.set_tooltip_text("Close (Esc)")
        close.connect("clicked", lambda _b: self.destroy())
        folder = Gtk.Button(label="󰉋")
        folder.get_style_context().add_class("ghost")
        folder.set_tooltip_text("Open sounds folder")
        folder.connect("clicked", lambda _b: spawn_script("open-sounds-dir.sh"))
        header.pack_start(icon, False, False, 0)
        header.pack_start(title_box, True, True, 0)
        header.pack_start(folder, False, False, 0)
        header.pack_start(close, False, False, 0)
        outer.pack_start(header, False, False, 0)

        self.drop_zone = Gtk.Label(label="󰁇  Drop MP3 / WAV files here")
        self.drop_zone.get_style_context().add_class("drop-zone")
        ev = Gtk.EventBox()
        ev.add(self.drop_zone)
        outer.pack_start(ev, False, False, 4)

        url_row = Gtk.Box(spacing=6, margin_start=12, margin_end=12)
        self.url_entry = Gtk.Entry()
        self.url_entry.set_placeholder_text("Paste a YouTube / sound URL…")
        self.url_entry.connect("activate", self.on_url_activate)
        dl = Gtk.Button(label="󰇚")
        dl.get_style_context().add_class("ghost")
        dl.set_tooltip_text("Download")
        dl.connect("clicked", lambda _b: self.on_url_activate(self.url_entry))
        url_row.pack_start(self.url_entry, True, True, 0)
        url_row.pack_start(dl, False, False, 0)
        outer.pack_start(url_row, False, False, 6)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_vexpand(True)
        scroll.set_margin_start(10)
        scroll.set_margin_end(10)
        scroll.set_margin_top(6)
        self.flow = Gtk.FlowBox(
            valign=Gtk.Align.START,
            max_children_per_line=6,
            min_children_per_line=2,
            selection_mode=Gtk.SelectionMode.NONE,
            column_spacing=6, row_spacing=6,
        )
        scroll.add(self.flow)
        outer.pack_start(scroll, True, True, 0)

        vol_row = Gtk.Box(spacing=8, margin_start=12, margin_end=12)
        vol_label = Gtk.Label(label="Volume")
        vol_label.get_style_context().add_class("panel-sub")
        self.volume = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 5)
        self.volume.set_draw_value(False)
        self.volume.set_value(self.config["masterVolume"])
        self.volume.connect("value-changed", self.on_volume_changed)
        self.vol_pct = Gtk.Label(label=f"{self.config['masterVolume']}%", width_chars=4)
        vol_row.pack_start(vol_label, False, False, 0)
        vol_row.pack_start(self.volume, True, True, 0)
        vol_row.pack_start(self.vol_pct, False, False, 0)
        outer.pack_start(vol_row, False, False, 4)

        foot = Gtk.Box(spacing=6, margin_start=12, margin_end=12)
        self.router_btn = Gtk.ToggleButton(label="Virtual mic: off")
        self.router_btn.get_style_context().add_class("ghost")
        self.router_btn.connect("toggled", self.on_router_toggled)
        stop = Gtk.Button(label="󰝜 Stop All")
        stop.get_style_context().add_class("ghost")
        stop.connect("clicked", lambda _b: spawn_script("stop-all.sh"))
        mon_box = Gtk.Box(spacing=4)
        mon_label = Gtk.Label(label="Hear locally")
        mon_label.get_style_context().add_class("panel-sub")
        self.mon_switch = Gtk.Switch(active=self.config["monitorLocal"])
        self.mon_switch.connect("notify::active", self.on_monitor_changed)
        mon_box.pack_start(mon_label, False, False, 2)
        mon_box.pack_start(self.mon_switch, False, False, 0)
        foot.pack_start(self.router_btn, True, True, 0)
        foot.pack_start(stop, False, False, 0)
        foot.pack_start(mon_box, False, False, 0)
        outer.pack_start(foot, False, False, 6)

        self.status = Gtk.Label(label="", halign=Gtk.Align.START, wrap=True)
        self.status.get_style_context().add_class("status")
        outer.pack_start(self.status, False, False, 0)

    def setup_dnd(self):
        targets = [
            Gtk.TargetEntry.new("text/uri-list", 0, 0),
            Gtk.TargetEntry.new("text/plain", 0, 1),
        ]
        self.drag_dest_set(Gtk.DestDefaults.ALL, targets, Gdk.DragAction.COPY)
        self.connect("drag-data-received", self.on_drag_data)
        self.connect("drag-motion", self.on_drag_motion)
        self.connect("drag-leave", self.on_drag_leave)

    def on_drag_motion(self, *_a):
        self.drop_zone.get_style_context().add_class("hot")
        return True

    def on_drag_leave(self, *_a):
        self.drop_zone.get_style_context().remove_class("hot")

    def on_drag_data(self, _w, ctx, _x, _y, data, info, time):
        uris = data.get_uris() or []
        files, links = [], []
        for uri in uris:
            uri = uri.strip()
            if uri.startswith("file://"):
                files.append(os.path.normpath(urllib.parse.unquote(
                    uri.replace("file://", "", 1))))
            elif uri.startswith("http"):
                links.append(uri)
        if info == 1 or not uris:
            # text/plain drags (link from a browser address bar / page)
            for line in (data.get_text() or "").splitlines():
                line = line.strip()
                if line.startswith("http"):
                    links.append(line)
        ok = bool(files or links)
        if files:
            run_script("import-file.sh", *files)
            self.set_status(f"Imported {len(files)} file(s)")
        for link in links:
            self.start_download(link)
        self.refresh_sounds()
        Gtk.drag_finish(ctx, ok, False, time)

    # ------------------------------------------------------------------ logic

    def keep_popover(self, pop):
        self._popover = pop  # popovers are not parented; keep them alive

    def rename_clip(self, cell):
        path = clip_path(cell.sound_name)
        if not path:
            self.set_status(f"missing clip: {cell.sound_name}")
            return
        stem = os.path.splitext(os.path.basename(path))[0]
        pop = Gtk.Popover(relative_to=cell)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin=8)
        label = Gtk.Label(label="Rename clip", halign=Gtk.Align.START)
        label.get_style_context().add_class("panel-sub")
        entry = Gtk.Entry(text=stem)
        row = Gtk.Box(spacing=6)
        cancel = Gtk.Button(label="Cancel")
        cancel.get_style_context().add_class("ghost")
        save = Gtk.Button(label="Rename")
        save.get_style_context().add_class("ghost")

        def apply(_w=None):
            self._rename_to(cell.sound_name, entry.get_text().strip())
            pop.popdown()

        save.connect("clicked", apply)
        entry.connect("activate", apply)
        cancel.connect("clicked", lambda _b: pop.popdown())
        row.pack_start(cancel, True, True, 0)
        row.pack_start(save, False, False, 0)
        box.pack_start(label, False, False, 0)
        box.pack_start(entry, False, False, 0)
        box.pack_start(row, False, False, 0)
        pop.add(box)
        self.keep_popover(pop)
        pop.show_all()
        entry.grab_focus()
        entry.select_region(0, -1)

    def _rename_to(self, old_name, new_name):
        if not new_name or new_name == old_name:
            return
        rc, out, err = run_script("rename-sound.sh", old_name, new_name)
        if rc == 0:
            self.set_status(f"Renamed: {out[3:] if out.startswith('ok ') else new_name}")
        else:
            self.set_status((err.splitlines() or ["rename failed"])[-1])
        self.refresh_sounds()

    def delete_clip(self, cell):
        pop = Gtk.Popover(relative_to=cell)
        box = Gtk.Box(spacing=6, orientation=Gtk.Orientation.HORIZONTAL, margin=8)
        msg = Gtk.Label(label=f"Delete “{cell.sound_name}”?")
        yes = Gtk.Button(label="Delete")
        yes.get_style_context().add_class("destructive")
        no = Gtk.Button(label="Keep")
        yes.connect("clicked", lambda _b: (
            run_script("delete-sound.sh", cell.sound_name),
            pop.popdown(), self.refresh_sounds()))
        no.connect("clicked", lambda _b: pop.popdown())
        box.pack_start(msg, False, False, 4)
        box.pack_start(yes, False, False, 0)
        box.pack_start(no, False, False, 0)
        pop.add(box)
        self.keep_popover(pop)
        pop.show_all()

    def play_clip(self, name):
        path = clip_path(name)
        if not path:
            self.set_status(f"missing clip: {name}")
            return
        spawn_script("play.sh", path, str(self.config["masterVolume"]))
        if self.config["monitorLocal"]:
            self.set_status(f"▶ {name}")
        else:
            self.set_status(f"▶ {name} · hear locally is off (mic only)")

    def bootstrap_audio(self):
        rc, out, _ = run_script("audio_router.sh", "status")
        if rc != 0:
            self.set_status("PipeWire not reachable")
            return False
        if '"active":false' in out and self.config["autoSetup"]:
            threading.Thread(target=self._setup_router, daemon=True).start()
        return False  # one-shot

    def _setup_router(self):
        rc, out, err = run_script("audio_router.sh", "setup",
                                  "on" if self.config["monitorLocal"] else "off")
        if rc == 0:
            run_script("audio_router.sh", "volume", str(self.config["masterVolume"]))
            GLib.idle_add(self.set_status, out or "Virtual mic armed")
        else:
            GLib.idle_add(self.set_status, err or "Router setup failed")
        GLib.idle_add(self.refresh_router_status)

    def _poll_status(self):
        self.refresh_router_status()
        return True

    def refresh_router_status(self):
        rc, out, _ = run_script("audio_router.sh", "status")
        active = rc == 0 and '"active":true' in out
        engaged = active and '"engaged":true' in out
        self.router_btn.handler_block_by_func(self.on_router_toggled)
        self.router_btn.set_active(active)
        self.router_btn.handler_unblock_by_func(self.on_router_toggled)
        self.router_btn.set_label("Virtual mic: armed" if active else "Virtual mic: off")
        if engaged:
            self.subtitle.set_text("Clips live — mic bridged")
        elif active:
            monitor = " · local monitor on" if '"monitor":true' in out else ""
            self.subtitle.set_text(f"Armed · mic untouched{monitor}")
        else:
            self.subtitle.set_text("Virtual mic off")
        return False

    def on_router_toggled(self, btn):
        if btn.get_active():
            threading.Thread(target=self._setup_router, daemon=True).start()
        else:
            threading.Thread(target=self._teardown_router, daemon=True).start()

    def _teardown_router(self):
        rc, out, err = run_script("audio_router.sh", "teardown")
        GLib.idle_add(self.set_status, out if rc == 0 else (err or "Teardown failed"))
        GLib.idle_add(self.refresh_router_status)

    def on_volume_changed(self, scale):
        val = int(scale.get_value())
        self.vol_pct.set_text(f"{val}%")
        if self._vol_timer:
            GLib.source_remove(self._vol_timer)
        self._vol_timer = GLib.timeout_add(250, self._commit_volume, val)

    def _commit_volume(self, val):
        self.config["masterVolume"] = val
        save_config(self.config)
        spawn_script("audio_router.sh", "volume", str(val))
        self._vol_timer = None
        return False

    def on_monitor_changed(self, switch, _pspec):
        val = switch.get_active()
        self.config["monitorLocal"] = val
        save_config(self.config)
        spawn_script("audio_router.sh", "monitor", "on" if val else "off")
        GLib.timeout_add(400, self.refresh_router_status)

    def on_url_activate(self, entry):
        url = entry.get_text().strip()
        if url:
            self.start_download(url)
            entry.set_text("")

    def start_download(self, url):
        self.set_status(f"Downloading {url.split('/')[-1][:40] or url}…")
        threading.Thread(target=self._download_worker, args=(url,), daemon=True).start()

    def _download_worker(self, url):
        rc, out, err = run_script("download.sh", url)
        ok_line = next((l[3:] for l in out.splitlines() if l.startswith("ok ")), None)
        GLib.idle_add(self._download_done, rc, ok_line, err)

    def _download_done(self, rc, ok_line, err):
        if rc == 0 and ok_line:
            self.set_status(f"Added: {ok_line}")
        else:
            self.set_status((err.splitlines() or ["Download failed"])[-1])
        self.refresh_sounds()
        return False

    def refresh_sounds(self):
        for child in self.flow.get_children():
            self.flow.remove(child)
        try:
            names = sorted(
                os.path.splitext(f)[0]
                for f in os.listdir(SOUNDS_DIR)
                if os.path.splitext(f)[1].lower() in AUDIO_EXTS
                and os.path.isfile(os.path.join(SOUNDS_DIR, f))
            )
        except OSError:
            names = []
        if not names:
            hint = Gtk.Label(label="No clips yet — drop files above or download a URL.")
            hint.get_style_context().add_class("panel-sub")
            hint.set_margin_top(8)
            self.flow.add(hint)
        else:
            for name in names:
                self.flow.add(SoundCell(name, self))
        self.flow.show_all()
        return False

    def on_key(self, _w, event):
        if event.keyval == Gdk.KEY_Escape:
            self.destroy()
            return True
        return False

    def set_status(self, text):
        self.status.set_text(text or "")


def running_pid():
    try:
        with open(UI_PID) as handle:
            pid = int(handle.read().strip() or 0)
    except (OSError, ValueError):
        return 0
    if pid and pid != os.getpid():
        try:
            os.kill(pid, 0)
            return pid
        except OSError:
            return 0
    return 0


def main():
    os.makedirs(SOUNDS_DIR, exist_ok=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    if running_pid():
        return 0
    with open(UI_PID, "w") as handle:
        handle.write(str(os.getpid()))
    # Must happen before the GDK surface exists: Hyprland matches this class.
    GLib.set_prgname(APP_ID)
    try:
        Gdk.set_program_class(APP_ID)
    except AttributeError:
        pass
    win = SoundboardWindow()
    win.set_wmclass(APP_ID, APP_ID)
    win.show_all()

    def on_destroy(*_args):
        try:
            os.remove(UI_PID)
        except OSError:
            pass
        Gtk.main_quit()

    win.connect("destroy", on_destroy)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: GLib.idle_add(win.destroy))
    Gtk.main()


if __name__ == "__main__":
    main()
