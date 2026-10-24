#!/usr/bin/env python3
"""List code addresses that data points at but codegen did not register as functions.

Dump the image first:  REXGLUE_DUMP_SECTIONS=analysis/sections rexglue codegen <manifest>
usage: find_missed_functions.py <sections dir> <generated *_register.cpp>

Prints the pointers that look like function starts (the word before is a blr, bctr, padding or a branch):
vtable entries and this-adjustor thunks, static initializers, exception-handler funclets. Check each
against codegen's warnings after adding it: a jump-table target inside a function splits that function.
"""
import glob
import os
import re
import struct
import sys

BLR = 0x4E800020
BCTR = 0x4E800420


def main():
    sections, register = sys.argv[1], sys.argv[2]
    text_path = glob.glob(os.path.join(sections, "_text_*.bin"))[0]
    text = open(text_path, "rb").read()
    text_base = int(text_path.rsplit("_", 1)[1][:8], 16)
    text_end = text_base + len(text)
    registered = {int(a, 16) for a in re.findall(r"SetFunction\(0x([0-9A-F]+)", open(register).read())}

    def word(addr):
        return struct.unpack_from(">I", text, addr - text_base)[0]

    found = {}
    for path in glob.glob(os.path.join(sections, "_*data_*.bin")):
        if "_pdata_" in path:
            continue
        data = open(path, "rb").read()
        for i in range(0, len(data) - 3, 4):
            value = struct.unpack_from(">I", data, i)[0]
            if text_base <= value < text_end and value % 4 == 0 and value not in registered:
                found.setdefault(value, 0)
                found[value] += 1

    for addr in sorted(found):
        prev = word(addr - 4)
        if prev in (BLR, BCTR, 0) or prev >> 26 == 18:
            print(f"0x{addr:08X}")


if __name__ == "__main__":
    main()
