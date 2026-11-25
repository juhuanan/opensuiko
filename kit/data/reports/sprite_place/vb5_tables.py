#!/usr/bin/env python3
"""Scratch analysis of VB5.BIN tables for sprite/entity placement (2026-10-03).

Reads the extracted overlay to keep provenance honest; the extraction is
re-verified against the disc when --verify is passed.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..", "..", "tools")))

ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
VB5 = os.path.join(ROOT, "kit", "extracted", "bin_overlays", "DATA", "02_AREA.B", "VB5.BIN")
BASE = 0x80010000


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def main():
    d = open(VB5, "rb").read()
    print("VB5.BIN size", len(d), hex(len(d)))
    import hashlib
    print("md5", hashlib.md5(d).hexdigest())

    # 98-entry table at 0x1ca98
    T = 0x1CA98
    print("\n=== 98-entry u32 table @0x1ca98 ===")
    for i in range(98):
        v = u32(d, T + 4 * i)
        off = v - BASE
        ok = 0 <= off < len(d) - 8
        extra = ""
        if ok:
            w0 = u32(d, off)
            extra = "words=%08x %08x" % (w0, u32(d, off + 4))
        print("%3d ptr=%08x -> off=%#08x %s %s" % (i, v, off, "IN" if ok else "OUT", extra))

    # 15-entry table at 0x31190
    print("\n=== 15-entry u32 table @0x31190 ===")
    for i in range(16):
        v = u32(d, 0x31190 + 4 * i)
        print("%2d ptr=%08x -> off=%#08x" % (i, v, v - BASE))

    # struct at 0x311cc
    print("\n=== struct/tilemap header @0x311cc ===")
    for i in range(0, 0x60, 4):
        v = u32(d, 0x311CC + i)
        print("+%02x %08x  (%d)" % (i, v, v))

    # who references the tables?
    print("\n=== references to 0x1ca98 and 0x31190 (as absolute ptr) ===")
    for name, addr in (("98tab", BASE + T), ("15tab", BASE + 0x31190),
                       ("hdr311cc", BASE + 0x311CC)):
        pat = struct.pack("<I", addr)
        hits = []
        start = 0
        while True:
            k = d.find(pat, start)
            if k < 0:
                break
            hits.append(k)
            start = k + 1
        print(name, hex(addr), "hits:", [hex(h) for h in hits])


if __name__ == "__main__":
    main()
