#!/usr/bin/env python3
"""Per-thread busy time and hottest functions from an xctrace time-profile export.

usage: thread_hot.py tp.xml <process substring> [top N functions per thread]
"""
import collections
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
want = sys.argv[2].lower()
top = int(sys.argv[3]) if len(sys.argv) > 3 else 12
by_id = {el.get("id"): el for el in root.iter() if el.get("id") is not None}
r = lambda e: by_id[e.get("ref")] if e is not None and e.get("ref") else e
times = []
thread_ms = collections.Counter()
leaf = collections.defaultdict(collections.Counter)
incl = collections.defaultdict(collections.Counter)
for row in root.iter("row"):
    t = r(row.find("sample-time"))
    if t is not None:
        times.append(int(t.text))
    p = r(row.find("process"))
    if p is None or want not in (p.get("fmt") or "").lower():
        continue
    th = r(row.find("thread")).get("fmt").split(" (")[0]
    w = r(row.find("weight"))
    ms = int(w.text) / 1e6 if w is not None else 1.0
    thread_ms[th] += ms
    bt = row.find("backtrace")
    if bt is None:
        bt = row.find("tagged-backtrace")
    if bt is None:
        continue
    names = [(r(f).get("name") or "?") for f in r(bt).iter("frame")]
    if names:
        leaf[th][names[0]] += ms
        for n in set(names):
            incl[th][n] += ms
span = (max(times) - min(times)) / 1e9
print(f"span {span:.2f} s")
for th, ms in thread_ms.most_common(6):
    print(f"\n== {th}: {ms / 10 / span:.0f}% of a core")
    for f, v in leaf[th].most_common(top):
        print(f"   leaf {100 * v / ms:5.1f}%  {f[:100]}")
