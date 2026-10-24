#!/usr/bin/env python3
"""Summarize an xctrace 'time-profile' export for one process: busiest threads and leaf/total functions.

usage: time_profile.py tp.xml <process name substring>
"""
import collections
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
want = sys.argv[2].lower()
# Every element with an id, so later ref= attributes resolve.
by_id = {el.get("id"): el for el in root.iter() if el.get("id") is not None}


def resolve(el):
    ref = el.get("ref")
    return by_id[ref] if ref is not None else el


threads = collections.Counter()
leaf = collections.Counter()
total = collections.Counter()
samples = 0
for row in root.iter("row"):
    proc = row.find("process")
    thread = row.find("thread")
    bt = row.find("backtrace")
    if bt is None:
        bt = row.find("tagged-backtrace")
    if proc is None or thread is None:
        continue
    proc = resolve(proc)
    if want not in (proc.get("fmt") or "").lower():
        continue
    thread = resolve(thread)
    samples += 1
    threads[thread.get("fmt")] += 1
    if bt is None:
        continue
    bt = resolve(bt)
    names = []
    for fr in bt.iter("frame"):
        fr = resolve(fr)
        names.append(fr.get("name") or fr.get("addr") or "?")
    if names:
        leaf[names[0]] += 1
        for n in set(names):
            total[n] += 1

print(f"{samples} samples")
print("threads:")
for t, n in threads.most_common(12):
    print(f"  {100 * n / samples:5.1f}%  {t}")
print("leaf functions:")
for f, n in leaf.most_common(25):
    print(f"  {100 * n / samples:5.1f}%  {f[:110]}")
print("inclusive:")
for f, n in total.most_common(30):
    print(f"  {100 * n / samples:5.1f}%  {f[:110]}")
