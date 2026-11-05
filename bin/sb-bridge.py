#!/usr/bin/env python3
"""Runtime capture-source bridge for the soundboard.

While a clip plays, live recorder streams are relinked into the virtual
microphone and restored afterwards. This talks to PipeWire directly with
pw-link: on a WirePlumber + easyeffects stack `pactl move-source-output`
returns success but the stream never leaves its original source, and default
source changes do not relink running streams.

Bridge records are tab-separated lines in <state>/moved.tsv:
    target_node  target_port  vmic_port  source_node  source_port
"""

import json
import os
import subprocess
import sys

VMIC = os.environ.get("SBOARD_VMIC_SINK", "soundboard_virtual_mic")
STATE = os.environ.get("SBOARD_STATE_DIR", os.path.expanduser("~/.local/state/omarchy-soundboard"))
RECORD = os.path.join(STATE, "moved.tsv")


def dump():
    out = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=15).stdout
    return json.loads(out)


def pwlink(*args):
    done = subprocess.run(["pw-link", *args], capture_output=True, text=True, timeout=8)
    return done.returncode == 0


def analyze(data):
    nodes = {}
    ports = {}
    link_into = {}
    for obj in data:
        kind = obj.get("type")
        info = obj.get("info") or {}
        props = info.get("props") or {}
        if kind == "PipeWire:Interface:Node":
            nodes[obj["id"]] = props
        elif kind == "PipeWire:Interface:Port":
            try:
                node_id = int(props.get("node.id"))
            except (TypeError, ValueError):
                continue
            ports[obj["id"]] = (str(props.get("port.name", "")), node_id, props.get("port.direction"))
        elif kind == "PipeWire:Interface:Link":
            try:
                link_into[int(props["link.input.port"])] = int(props["link.output.port"])
            except (KeyError, TypeError, ValueError):
                pass
    return nodes, ports, link_into


def node_name(node_id, nodes):
    props = nodes.get(node_id) or {}
    return str(props.get("node.name") or props.get("application.name") or "")


def vmic_monitor_ports(nodes, ports):
    vm_id = next((i for i, p in nodes.items() if p.get("node.name") == VMIC), None)
    if vm_id is None:
        return []
    names = [
        pname
        for pname, nid, direction in ports.values()
        if nid == vm_id and direction == "out" and pname.startswith("monitor_")
    ]
    return sorted(names)


def eligible(props):
    if props.get("media.class") != "Stream/Input/Audio":
        return False
    app = props.get("application.name")
    if not app:
        return False
    app = str(app).lower()
    name = str(props.get("node.name") or "")
    if "easyeffects" in app or name.startswith("ee_") or "loopback" in name:
        return False
    return True


def read_records():
    records = []
    if os.path.exists(RECORD):
        with open(RECORD) as handle:
            for line in handle:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 5 and parts[0]:
                    records.append(parts)
    return records


def engage():
    nodes, ports, link_into = analyze(dump())
    monitors = vmic_monitor_ports(nodes, ports)
    if not monitors:
        print("soundboard: virtual mic node not found", file=sys.stderr)
        return 1
    seen = {rec[0] for rec in read_records()}
    new_records = []
    for nid, props in nodes.items():
        if not eligible(props):
            continue
        name = str(props.get("node.name") or nid)
        if name in seen:
            continue
        inputs = sorted(
            (pid, pname)
            for pid, (pname, node_id, direction) in ports.items()
            if node_id == nid and direction == "in"
        )
        if not inputs:
            continue
        bridged = 0
        for index, (pid, pname) in enumerate(inputs[: len(monitors)]):
            feeder = link_into.get(pid)
            src_node = src_port = ""
            if feeder is not None:
                src_port = ports.get(feeder, ("",))[0]
                src_node = node_name(ports.get(feeder, ("", 0))[1], nodes)
                if src_node:
                    pwlink("-d", f"{src_node}:{src_port}", f"{name}:{pname}")
            if pwlink(f"{VMIC}:{monitors[index]}", f"{name}:{pname}"):
                new_records.append((name, pname, monitors[index], src_node, src_port))
                bridged += 1
        if bridged:
            print(f"soundboard: bridged {bridged} port(s) of {name}", file=sys.stderr)
    if new_records:
        os.makedirs(STATE, exist_ok=True)
        with open(RECORD, "a") as handle:
            for record in new_records:
                handle.write("\t".join(record) + "\n")
    return 0


def release():
    records = read_records()
    if not records:
        if os.path.exists(RECORD):
            os.remove(RECORD)
        return 0
    for name, pname, vport, src_node, src_port in records:
        pwlink("-d", f"{VMIC}:{vport}", f"{name}:{pname}")
        if src_node and src_port:
            pwlink(f"{src_node}:{src_port}", f"{name}:{pname}")
            print(f"soundboard: released {name}:{pname} -> {src_node}:{src_port}", file=sys.stderr)
        else:
            print(f"soundboard: released {name}:{pname} (no original source)", file=sys.stderr)
    os.remove(RECORD)
    return 0


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "help"
    if command == "engage":
        return engage()
    if command == "release":
        return release()
    print("usage: sb-bridge.py engage|release", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
