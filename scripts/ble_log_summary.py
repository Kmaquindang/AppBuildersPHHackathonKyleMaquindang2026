#!/usr/bin/env python3
"""Summarize Libre Bluetooth logs from device tests (issue #1) as a Markdown table.

Usage:
  python3 scripts/ble_log_summary.py [--since 2026-10-13T01:00] <log> [<log> ...]

--since keeps only lines stamped at or after that UTC time (iPhone and Mac logs).

Each <log> is an iPhone or Mac ble-log.txt (Connection sheet > Show debug info > Share
Bluetooth log) or an Android logcat dump (adb logcat -d -s LibreBLE LibreMesh > android.txt).
Only device names and numbers are read; the logs never hold message text.

Our own script (Oct 2026). Standard library only.
"""

import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

PROBE = re.compile(r"(?:BLE )?probe (?P<peer>.+?) role=(?P<role>\w+) mtu=(?P<mtu>\d+) bytes=(?P<bytes>\d+) rtt_ms=(?P<rtt>\d+) Bps=(?P<bps>\d+)")
VERIFIED = re.compile(r"(?:BLE )?verified (?P<peer>.+?) key=\S+ role=(?P<role>\w+) mtu=(?P<mtu>\d+)(?: after_s=(?P<after>[\d.]+))?")
FOUND = re.compile(r"(?:BLE )?found a Libre device rssi=(?P<rssi>-?\d+)")
BAT = re.compile(r"BAT pct=(?P<pct>-?\d+) charging=(?P<chg>[01]) links=(?P<links>\d+) bright=(?P<bright>-?[\d.]+) state=(?P<state>fg|bg) os=(?P<os>.+?) model=(?P<model>.+)$")
ISO_TIME = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})")
LOGCAT_TIME = re.compile(r"^(\d{2}-\d{2} \d{2}:\d{2}:\d{2})")
MSG = re.compile(r"MSG (?P<kind>\w+) link=(?P<link>\w+) hops=(?P<hops>\d+)(?: rtt_ms=(?P<rtt>\d+))?(?: ai_ms=(?P<ai>\d+))?")


def spread(values):
    """'n=3, median 12, range 10 to 15' for a list of numbers (empty string when none)."""
    if not values:
        return ""
    med = statistics.median(values)
    fmt = (lambda v: f"{v:.1f}") if any(isinstance(v, float) for v in values) else (lambda v: f"{v:g}")
    if len(values) == 1:
        return f"n=1, {fmt(values[0])}"
    return f"n={len(values)}, median {fmt(med)}, range {fmt(min(values))} to {fmt(max(values))}"


def parse(text):
    """Collects the numbers from one log's text."""
    out = {
        "probe_kbps": defaultdict(list),   # peer -> KB/s
        "mtu": defaultdict(set),           # peer -> MTUs seen
        "verify_s": [],                    # seconds from link open to verified
        "found_rssi": [],
        "rtt": defaultdict(list),          # (link, hops) -> answer round trips in ms
        "ai": defaultdict(list),           # (link, hops) -> AI time in ms
        "chats": defaultdict(int),         # (link, hops) -> received chat count
        "battery": [],                     # (seconds since epoch or None, pct, charging, links, state, os, model)
    }
    for line in text.splitlines():
        if m := PROBE.search(line):
            out["probe_kbps"][m["peer"]].append(int(m["bps"]) / 1000)
            out["mtu"][m["peer"]].add(int(m["mtu"]))
        elif m := VERIFIED.search(line):
            if m["after"]:
                out["verify_s"].append(float(m["after"]))
        elif m := FOUND.search(line):
            out["found_rssi"].append(int(m["rssi"]))
        elif m := BAT.search(line):
            out["battery"].append((stamp(line), int(m["pct"]), m["chg"] == "1", int(m["links"]), m["state"], m["os"], m["model"].strip()))
        elif m := MSG.search(line):
            key = (m["link"], int(m["hops"]))
            if m["kind"] == "answer" and m["rtt"]:
                out["rtt"][key].append(int(m["rtt"]))
                if m["ai"]:
                    out["ai"][key].append(int(m["ai"]))
            elif m["kind"] == "chat":
                out["chats"][key] += 1
    return out


def stamp(line):
    """Seconds for an iPhone or Mac ISO stamp, or a logcat MM-DD HH:MM:SS stamp (year 2000), else None."""
    from datetime import datetime, timezone
    if m := ISO_TIME.match(line):
        return datetime.strptime(m[1], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    if m := LOGCAT_TIME.match(line):
        return datetime.strptime("2000-" + m[1], "%Y-%m-%d %H:%M:%S").timestamp()
    return None


def battery_rows(points):
    """Start and end battery, drain per hour, links held, for one log's BAT lines."""
    known = [p for p in points if p[1] >= 0]
    if not known:
        return []
    first, last = known[0], known[-1]
    rows = [f"| Device | {last[6]}, {last[5]} |",
            f"| Battery start to end (%) | {first[1]} to {last[1]}{' (charging seen)' if any(p[2] for p in known) else ''} |",
            f"| Links held during the run | {spread([p[3] for p in known])} |",
            f"| Time on screen / in background (lines) | {sum(p[4] == 'fg' for p in known)} / {sum(p[4] == 'bg' for p in known)} |"]
    if first[0] is not None and last[0] is not None and last[0] > first[0]:
        hours = (last[0] - first[0]) / 3600
        rows.append(f"| Run length (min) | {hours * 60:.0f} |")
        rows.append(f"| Drain (% per hour) | {(first[1] - last[1]) / hours:.1f} |")
    return rows


def report(name, data):
    lines = [f"### {name}", "", "| Measure | Result |", "|---|---|"]
    for peer in sorted(data["probe_kbps"]):
        mtus = ", ".join(str(x) for x in sorted(data["mtu"][peer]))
        lines.append(f"| 4 KB probe to {peer} (KB/s, MTU {mtus}) | {spread(data['probe_kbps'][peer])} |")
    if data["verify_s"]:
        lines.append(f"| Link open to verified (s) | {spread(data['verify_s'])} |")
    if data["found_rssi"]:
        lines.append(f"| Signal when first found (RSSI dBm) | {spread(data['found_rssi'])} |")
    for key in sorted(data["rtt"]):
        link, hops = key
        lines.append(f"| @libre round trip, answer over {link}, {hops} hop(s) (ms) | {spread(data['rtt'][key])} |")
        if data["ai"][key]:
            lines.append(f"| of which AI time on the Mac (ms) | {spread(data['ai'][key])} |")
    for key in sorted(data["chats"]):
        link, hops = key
        lines.append(f"| Chats received over {link}, {hops} hop(s) | {data['chats'][key]} |")
    lines += battery_rows(data["battery"])
    if len(lines) == 4:
        lines.append("| (no Libre Bluetooth lines found) | |")
    return "\n".join(lines)


def since(text, start):
    """Keeps lines stamped at or after `start` (ISO 8601 UTC, for example 2026-10-13T01:00).
    Lines without a leading ISO stamp (Android logcat) are kept; clear logcat with adb logcat -c."""
    kept = []
    for line in text.splitlines():
        stamp = line.split(" ", 1)[0]
        if not ISO_STAMP.match(stamp) or stamp >= start:
            kept.append(line)
    return "\n".join(kept)


ISO_STAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T")


def main(args):
    start = None
    if len(args) >= 2 and args[0] == "--since":
        start, args = args[1], args[2:]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    print("Probe speed is 4096 bytes divided by the probe round trip, so it slightly understates one-way speed.\n")
    for p in args:
        text = Path(p).read_text(errors="replace")
        print(report(Path(p).name, parse(since(text, start) if start else text)))
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
