#!/usr/bin/env python3
"""Lists the files in UbiArt bundles (.ipk), optionally filtered: ipk_list.py <regex> <ipk...>"""
import re, struct, sys
def entries(path):
    with open(path, 'rb') as f:
        head = f.read(0x30)
        if struct.unpack('>I', head[:4])[0] != 0x50EC12BA: return
        base, count = struct.unpack('>II', head[0x0C:0x14])
        f.seek(0); t = f.read(min(base, 64 << 20))
    o = 0x30
    for _ in range(count):
        n = struct.unpack('>I', t[o:o+4])[0]
        size, csize = struct.unpack('>II', t[o+4:o+12]); o += 4 + 24
        parts = []
        for _ in range(2):
            l = struct.unpack('>I', t[o:o+4])[0]; o += 4
            parts.append(t[o:o+l].decode('latin1')); o += l
        o += 8
        yield parts[0] + parts[1], size, csize
rx = re.compile(sys.argv[1], re.I)
for p in sys.argv[2:]:
    for name, size, csize in entries(p):
        if rx.search(name): print(f"{p.split('/')[-1]}\t{size}\t{name}")
