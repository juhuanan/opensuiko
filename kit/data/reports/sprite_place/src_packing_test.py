#!/usr/bin/env python3
"""Structural test of the e-record `src` byte-11 packing claim (scratch, 2026-10-03).

For every 04_PLAY file and every section, for every e-record, evaluate the
claimed packing  x=(b11&0xF)*8, y=((b11>>4)&0x07)*8, blob=bit7  and report:
  - how many rects fit 128x128
  - overlap statistics
  - the raw distribution of byte 11 and the other src bytes
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "kit", "tools"))
from parse_04play import parse_04play  # noqa: E402

PLAY = os.path.join(ROOT, "kit", "extracted", "bin_overlays", "DATA", "04_PLAY")


def main():
    files = sorted(f for f in os.listdir(PLAY) if f.endswith(".BIN"))
    tot = 0
    oob = 0
    overlaps = 0
    b11_vals = {}
    b8_vals = {}
    worst = []
    for fn in files:
        data = open(os.path.join(PLAY, fn), "rb").read()
        try:
            res = parse_04play(os.path.join(PLAY, fn), base=0x80010000)
        except Exception as e:
            print(fn, "parse error", e)
            continue
        for name, sec in res["sections"].items():
            if "e" not in sec:
                continue
            recs = [e for e in sec["e"]["entries"]]
            rects = []
            for e in recs:
                rec = e["record"]
                src = int(rec["src"], 16)
                b11 = (src >> 24) & 0xFF
                b8 = src & 0xFF
                b11_vals[b11] = b11_vals.get(b11, 0) + 1
                b8_vals[b8] = b8_vals.get(b8, 0) + 1
                x = (b11 & 0x0F) * 8
                y = ((b11 >> 4) & 0x07) * 8
                blob = 1 if (b11 & 0x80) else 0
                w = rec["w"]
                h = rec["h"]
                tot += 1
                if x + w > 128 or y + h > 128:
                    oob += 1
                    worst.append((fn, name, e["index"], b11, x, y, w, h))
                rects.append((x, y, w, h, blob))
            # overlap pairs
            for i in range(len(rects)):
                for j in range(i + 1, len(rects)):
                    a, b = rects[i], rects[j]
                    if a[4] != b[4]:
                        continue
                    ox = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
                    oy = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
                    if ox > 0 and oy > 0:
                        overlaps += 1
    print("total e-records:", tot)
    print("rects OOB (x*8+w>128 or y*8+h>128):", oob)
    print("overlapping pairs (same blob):", overlaps)
    print("byte11 histogram:", dict(sorted(b11_vals.items())))
    print("src byte8 histogram:", dict(sorted(b8_vals.items())))
    print("first OOB samples:", worst[:15])


if __name__ == "__main__":
    main()
