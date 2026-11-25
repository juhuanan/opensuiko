#!/usr/bin/env python3
"""Survey VB*.BIN room/section tables (scratch, 2026-10-03).

For each DATA/02_AREA.B/VB*.BIN:
  S = u32@0 ; table2 = u32@(S+4) ; roomtab = u32@(S+8)
  count room records (until the record's +0 is not a plausible ptr)
  count non-null table2 entries
  validate: does every room's +5 index land on a non-null table2 entry?
"""
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DIR = os.path.join(ROOT, "kit", "extracted", "bin_overlays", "DATA", "02_AREA.B")
BASE = 0x80010000


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def ptr_off(d, v):
    o = v - BASE
    return o if 0 <= o < len(d) else None


def main():
    files = sorted(f for f in os.listdir(DIR) if f.endswith(".BIN"))
    print("file        size    S       table2  n_t2  roomtab n_rooms  idx_range  ok_idx")
    for fn in files:
        d = open(os.path.join(DIR, fn), "rb").read()
        if len(d) < 0x40:
            continue
        s = ptr_off(d, u32(d, 0))
        if s is None or s + 0x18 > len(d):
            print("%-10s BAD first word %08x" % (fn, u32(d, 0)))
            continue
        t2 = ptr_off(d, u32(d, s + 4))
        rt = ptr_off(d, u32(d, s + 8))
        if t2 is None or rt is None:
            print("%-10s BAD S fields t2=%s rt=%s" % (fn, t2, rt))
            continue
        n_t2 = 0
        for i in range(64):
            if t2 + 4 * i + 4 > len(d):
                break
            if u32(d, t2 + 4 * i) != 0:
                n_t2 += 1
        n_rooms = 0
        idxs = []
        ok = 0
        for i in range(64):
            o = rt + 16 * i
            if o + 16 > len(d):
                break
            p = ptr_off(d, u32(d, o))
            if p is None:
                break
            idx = d[o + 5]
            idxs.append(idx)
            n_rooms += 1
            if t2 + 4 * idx + 4 <= len(d) and u32(d, t2 + 4 * idx) != 0:
                ok += 1
        print("%-10s %7d %#07x %#07x %4d %#07x %6d  %s  %d/%d" % (
            fn, len(d), s, t2, n_t2, rt, n_rooms, (min(idxs), max(idxs)) if idxs else "-", ok, n_rooms))


if __name__ == "__main__":
    main()
