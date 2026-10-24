#!/usr/bin/env python3
"""Summarize an xctrace 'metal-gpu-intervals' export: GPU busy time per frame and the busiest channels.

usage: xcrun xctrace export --input X.trace --xpath '...table[@schema="metal-gpu-intervals"]' > gpu.xml
       gpu_frames.py gpu.xml
"""
import collections
import statistics
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
cols = [c.findtext("mnemonic") for c in root.iter("col")]
by_id = {}


def value(el):
    if el is None:
        return None
    ref = el.get("ref")
    if ref is not None:
        return by_id.get(ref)
    v = (el.text or "").strip() or el.get("fmt")
    if el.get("id") is not None:
        by_id[el.get("id")] = v
    for sub in el:  # register nested ids too
        value(sub)
    return v


rows = []
for row in root.iter("row"):
    vals = {}
    i = 0
    for el in row:
        if i >= len(cols):
            break
        vals[cols[i]] = value(el) if el.tag != "sentinel" else None
        i += 1
    rows.append(vals)

frames = collections.defaultdict(float)
channels = collections.defaultdict(float)
starts = []
for r in rows:
    if r.get("event-depth") not in ("0", 0):
        continue
    d = int(r.get("duration") or 0) / 1e6
    f = r.get("frame-number")
    frames[f] += d
    channels[r.get("channel-name")] += d
    starts.append(int(r.get("start") or 0))
span_s = (max(starts) - min(starts)) / 1e9 if starts else 0
busy = [v for k, v in frames.items() if k is not None]
print(f"{len(rows)} intervals over {span_s:.1f} s, {len(busy)} frames ({len(busy) / span_s:.1f} per second)")
if busy:
    print(f"GPU busy per frame: median {statistics.median(busy):.1f} ms, p90 {sorted(busy)[int(len(busy) * 0.9)]:.1f} ms")
total = sum(channels.values())
for name, ms in sorted(channels.items(), key=lambda kv: -kv[1]):
    print(f"  {name}: {ms:.0f} ms ({100 * ms / total:.0f}%)")
