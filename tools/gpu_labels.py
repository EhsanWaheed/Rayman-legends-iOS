#!/usr/bin/env python3
"""GPU time per encoder label from an xctrace 'metal-gpu-intervals' export (see gpu_frames.py)."""
import collections, re, sys
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
    for sub in el:
        value(sub)
    return v
tot = collections.defaultdict(float); cnt = collections.Counter()
for row in root.iter("row"):
    vals = {}
    for i, el in enumerate(row):
        if i >= len(cols): break
        vals[cols[i]] = value(el) if el.tag != "sentinel" else None
    if vals.get("event-depth") not in ("0", 0, None):
        continue
    label = re.sub(r"\s+\(.*", "", vals.get("event-label") or "")
    label = re.sub(r"Command \d+", "Command", label)
    key = (vals.get("channel-name"), label)
    tot[key] += int(vals.get("duration") or 0) / 1e6
    cnt[key] += 1
for k, v in sorted(tot.items(), key=lambda x: -x[1])[:25]:
    print(f"{v:9.1f} ms {cnt[k]:6d}x  {k[0]} / {k[1]}")
