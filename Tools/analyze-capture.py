#!/usr/bin/env python3
"""Summarize Probe --capture logs; discard startup and report-mode transitions."""
import argparse
from collections import defaultdict
import json
import re

REPORT = re.compile(r"REPORT t=([\d.]+) slot=(\d+) seq=(\d+) us=(\w+) data=([\da-f]+)")


def intervals(values):
    values = sorted(values)
    if not values:
        return {}
    return {
        "p95": round(values[min(len(values) - 1, int(len(values) * 0.95))], 2),
        "maximum": round(values[-1], 2),
    }


def has_optical_point(data):
    if len(data) != 22 or data[0] != 0x37:
        return False
    for offset in (6, 11):
        p = data[offset:offset + 5]
        points = (
            (p[0] | ((p[2] >> 4) & 3) << 8, p[1] | ((p[2] >> 6) & 3) << 8),
            (p[3] | (p[2] & 3) << 8, p[4] | ((p[2] >> 2) & 3) << 8),
        )
        if any(x < 1023 and y < 1023 for x, y in points):
            return True
    return False


def summarize(path, start=None, end=None):
    rows = defaultdict(list)
    with open(path, errors="replace") as source:
        for line in source:
            match = REPORT.match(line)
            if not match:
                continue
            arrival, slot, _, timestamp, hexdata = match.groups()
            data = bytes.fromhex(hexdata)
            if len(data) >= 3 and data[0] >= 0x30:
                rows[int(slot)].append((float(arrival), None if timestamp == "none" else int(timestamp), data))
    capture_end = max((samples[-1][0] for samples in rows.values()), default=0)
    print(path)
    for slot, all_rows in sorted(rows.items()):
        first_combined = next((row[0] for row in all_rows if row[2][0] == 0x37), all_rows[0][0])
        trim = start if start is not None else max(all_rows[0][0], first_combined) + 10
        samples = [row for row in all_rows if row[0] >= trim and (end is None or row[0] <= end)]
        if len(samples) < 2:
            print(json.dumps({"slot": slot, "error": "fewer than two samples in measurement window"}))
            continue
        arrivals = [(b[0] - a[0]) * 1000 for a, b in zip(samples, samples[1:])]
        source = [((b[1] - a[1]) & 0xffffffff) / 1000 for a, b in zip(samples, samples[1:])
                  if a[1] is not None and b[1] is not None]
        presses = releases = last = 0
        for _, _, data in all_rows:
            buttons = (data[1] | data[2] << 8) & ~0x60e0
            presses += bool(buttons & 0x800 and not last & 0x800)
            releases += bool(last & 0x800 and not buttons & 0x800)
            last = buttons
        span = samples[-1][0] - samples[0][0]
        print(json.dumps({
            "slot": slot, "start": round(trim, 2), "seconds": round(span, 2),
            "reports": len(samples), "rate": round((len(samples) - 1) / span, 2) if span else 0,
            "arrival_ms": intervals(arrivals), "source_ms": intervals(source),
            "tail_silence_s": round(max(0, min(end or capture_end, capture_end) - samples[-1][0]), 2),
            "A_presses": presses, "A_releases": releases, "final_buttons": last,
            "optical_reports": sum(has_optical_point(row[2]) for row in all_rows),
            "gyro_reports": sum(len(row[2]) == 22 and row[2][0] == 0x37 and bool(row[2][21] & 2) for row in samples),
        }))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+")
    parser.add_argument("--start", type=float, help="Explicit arrival-time window start (seconds)")
    parser.add_argument("--end", type=float, help="Explicit arrival-time window end (seconds)")
    options = parser.parse_args()
    for path in options.logs:
        summarize(path, options.start, options.end)
