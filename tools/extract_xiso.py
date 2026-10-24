#!/usr/bin/env python3
"""Extract an Xbox 360 disc image (XDVDFS, XGD1/2/3 layouts) to a folder.

usage: extract_xiso.py <image.iso> <out_dir> [--list] [--only default.xex]
"""
import os
import struct
import sys

SECTOR = 2048
MAGIC = b"MICROSOFT*XBOX*MEDIA"
# Game partition offsets: plain XDVDFS, XGD3, XGD2, XGD1.
PARTITIONS = (0x0, 0x2080000, 0xFD90000, 0x18300000)


def find_partition(f):
    for base in PARTITIONS:
        f.seek(base + 32 * SECTOR)
        if f.read(len(MAGIC)) == MAGIC:
            return base
    raise SystemExit("no XDVDFS volume descriptor found")


def walk(f, base, sector, size, prefix, out):
    """Walk a directory table (a binary tree of entries) and yield (path, sector, size, is_dir)."""
    if size == 0:
        return
    f.seek(base + sector * SECTOR)
    table = f.read(size)
    stack = [0]
    seen = set()
    while stack:
        off = stack.pop()
        if off in seen or off + 14 > len(table):
            continue
        seen.add(off)
        left, right, start, length, attrs, nlen = struct.unpack_from("<HHIIBB", table, off)
        if left == 0xFFFF:
            continue
        name = table[off + 14 : off + 14 + nlen].decode("latin-1")
        path = f"{prefix}/{name}" if prefix else name
        is_dir = bool(attrs & 0x10)
        out.append((path, start, length, is_dir))
        if is_dir:
            walk(f, base, start, length, path, out)
        if left:
            stack.append(left * 4)
        if right:
            stack.append(right * 4)


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        raise SystemExit(__doc__)
    iso, dest = args[0], args[1]
    only = args[args.index("--only") + 1] if "--only" in args else None
    with open(iso, "rb") as f:
        base = find_partition(f)
        f.seek(base + 32 * SECTOR + len(MAGIC))
        root_sector, root_size = struct.unpack("<II", f.read(8))
        entries = []
        walk(f, base, root_sector, root_size, "", entries)
        if "--list" in args:
            for path, _, size, is_dir in sorted(entries):
                print(f"{'<dir>' if is_dir else size:>12}  {path}")
            return
        total = 0
        for path, start, size, is_dir in sorted(entries):
            if only and path.lower() != only.lower():
                continue
            target = os.path.join(dest, path)
            if is_dir:
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            f.seek(base + start * SECTOR)
            remaining = size
            with open(target, "wb") as o:
                while remaining:
                    chunk = f.read(min(remaining, 8 << 20))
                    o.write(chunk)
                    remaining -= len(chunk)
            total += size
        print(f"partition 0x{base:X}: {len(entries)} entries, {total / 1e9:.2f} GB written to {dest}")


if __name__ == "__main__":
    main()
