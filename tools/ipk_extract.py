#!/usr/bin/env python3
"""Extracts files from UbiArt bundles: ipk_extract.py <regex> <out dir> <ipk...> (first match of each path)."""
import os, re, struct, sys, zlib
def entries(path):
    with open(path, 'rb') as f:
        head = f.read(0x30)
        if struct.unpack('>I', head[:4])[0] != 0x50EC12BA: return
        base, count = struct.unpack('>II', head[0x0C:0x14])
        f.seek(0); t = f.read(min(base, 64 << 20))
    o = 0x30
    for _ in range(count):
        size, csize, ts, off = struct.unpack('>IIQQ', t[o+4:o+28]); o += 28
        parts = []
        for _ in range(2):
            l = struct.unpack('>I', t[o:o+4])[0]; o += 4
            parts.append(t[o:o+l].decode('latin1')); o += l
        o += 8
        yield parts[0] + parts[1], size, csize, base + off
rx = re.compile(sys.argv[1], re.I); out = sys.argv[2]; seen = set()
for p in sys.argv[3:]:
    for name, size, csize, off in entries(p):
        if not rx.search(name) or name in seen: continue
        seen.add(name)
        with open(p, 'rb') as f:
            f.seek(off); d = f.read(csize or size)
        if csize: d = zlib.decompress(d)
        dst = os.path.join(out, name.split('/')[-1]); open(dst, 'wb').write(d)
        print(len(d), dst)
