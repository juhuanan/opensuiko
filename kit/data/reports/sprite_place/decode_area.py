#!/usr/bin/env python3
"""Decode area BIN room/section/entry chain (scratch, 2026-10-03).

Chain (all addresses verified in MAIN.EXE disassembly):
  S       = u32@0                      (loaded at 0x80010000)
  table2  = u32@(S+4)                  indexed by room record byte +5
  roomtab = u32@(S+8)                  16-byte records, indexed by game_state[1]
  entrytab= u32@(room+0)               24-byte records
  section = u32@(table2 + 4*room[5])
  entry[0]  = X          (u8, world units)
  entry[2]  = Y          (u8, world units)
  entry[4]  = flags      (bit 0x20/0x40 -> walker-placed entity)
  entry[6]  = u16 id     (arg to 0x801346a8)
  entry[12] = u32 -> 0x06-delimited stream pointer
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DIR = os.path.join(ROOT, "kit", "extracted", "bin_overlays", "DATA", "02_AREA.B")
BASE = 0x80010000


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def off_of(d, v):
    o = v - BASE
    return o if 0 <= o < len(d) else None


def main(fn):
    d = open(os.path.join(DIR, fn), "rb").read()
    s = off_of(d, u32(d, 0))
    t2 = off_of(d, u32(d, s + 4))
    rt = off_of(d, u32(d, s + 8))
    print("%s size=%d S=%#x table2=%#x roomtab=%#x" % (fn, len(d), s, t2, rt))
    print("S fields:", [(hex(k), hex(u32(d, s + k))) for k in range(0, 0x20, 4)])
    print("\n-- room records --")
    for i in range(40):
        o = rt + 16 * i
        if o + 16 > len(d):
            break
        et = off_of(d, u32(d, o))
        if et is None:
            break
        cnt = d[o + 4]
        sidx = d[o + 5]
        sec = off_of(d, u32(d, t2 + 4 * sidx)) if t2 + 4 * sidx + 4 <= len(d) else None
        print("room %2d @%#07x entries@%#07x count=%3d secidx=%3d sec=%s w1=%08x w2=%08x w3=%08x"
              % (i, o, et, cnt, sidx, hex(sec) if sec is not None else "NULL",
                 u32(d, o + 4), u32(d, o + 8), u32(d, o + 12)))
        if et is None or cnt == 0:
            continue
        nmatch = 0
        xs, ys = [], []
        for k in range(cnt):
            eo = et + 24 * k
            if eo + 24 > len(d):
                break
            x = d[eo + 0]
            y = d[eo + 2]
            fl = u16(d, eo + 4)
            if fl & 0x60:
                nmatch += 1
                xs.append(x)
                ys.append(y)
        print("        entities(flags&0x60)=%d  X=%s Y=%s" % (
            nmatch, (min(xs), max(xs)) if xs else "-", (min(ys), max(ys)) if ys else "-"))


if __name__ == "__main__":
    for a in sys.argv[1:]:
        main(a)
        print()
