#!/usr/bin/env python3
"""
tim_scan.py — scan a file for PS1 TIM image headers.

TIM layout (little-endian):
  +0: magic 0x00000010
  +4: flags: bits0-2 = PMODE (0=4bpp,1=8bpp,2=16bpp,3=24bpp), bit3 = CF (CLUT present)
  +8: [if CF] clut_len (4), dx (2), dy (2), w (2), h (2), then clut_len-12 bytes of CLUT
  +8 or +clut_len: img_len (4), dx (2), dy (2), w (2), h (2), then img_len-12 bytes of pixels

Validation: block lengths must be sane and fit within the file.

Usage:
  python3 tim_scan.py <file> [--align N] [--verbose]
"""

import argparse
import struct
import sys

BPP_MODES = {0: "4bpp", 1: "8bpp", 2: "16bpp", 3: "24bpp", 4: "mixed"}


def scan(data: bytes, label: str = "", verbose: bool = False, align: int = 1):
    hits = []
    n = len(data)
    off = 0
    while off <= n - 12:
        if data[off:off + 4] == b"\x10\x00\x00\x00":
            flags = struct.unpack("<I", data[off + 4:off + 8])[0]
            pmode = flags & 0x7
            cf = bool(flags & 0x8)
            reserved = flags & ~0xF
            if pmode in BPP_MODES and reserved == 0:
                # validate structure
                p = off + 8
                ok = True
                info = {"offset": off, "pmode": BPP_MODES[pmode], "cf": cf}
                if cf:
                    if p + 12 > n:
                        ok = False
                    else:
                        clut_len = struct.unpack("<I", data[p:p + 4])[0]
                        cdx, cdy, cw, ch = struct.unpack("<HHHH", data[p + 4:p + 12])
                        if not (12 <= clut_len <= 0x100000 and p + clut_len <= n):
                            ok = False
                        else:
                            info.update({"clut": (cdx, cdy, cw, ch), "clut_len": clut_len})
                            p += clut_len
                if ok:
                    if p + 12 > n:
                        ok = False
                    else:
                        img_len = struct.unpack("<I", data[p:p + 4])[0]
                        idx, idy, iw, ih = struct.unpack("<HHHH", data[p + 4:p + 12])
                        # sanity: image dims and length must agree roughly
                        bpp_bits = {0: 4, 1: 8, 2: 16, 3: 24}.get(pmode, 0)
                        expect = (iw * ih * bpp_bits) // 8 if bpp_bits else 0
                        if not (12 <= img_len <= 0x1000000 and p + img_len <= n):
                            ok = False
                        elif bpp_bits and expect and abs(img_len - 12 - expect) > 16:
                            ok = False
                        else:
                            info.update({"img": (idx, idy, iw, ih), "img_len": img_len})
                if ok:
                    hits.append(info)
                    if verbose or True:
                        clut_s = f" clut@{info['clut']} len={info['clut_len']}" if cf else ""
                        img = info["img"]
                        print(f"{label}TIM @ 0x{off:08X} ({off}): {info['pmode']} "
                              f"CF={int(cf)}{clut_s} img@({img[0]},{img[1]}) {img[2]}x{img[3]} len={info['img_len']}")
        off += align
    return hits


def main():
    ap = argparse.ArgumentParser(description="Scan file for PS1 TIM headers")
    ap.add_argument("file", help="File to scan")
    ap.add_argument("--align", type=int, default=1, help="byte alignment step (default 1)")
    args = ap.parse_args()

    with open(args.file, "rb") as f:
        data = f.read()
    print(f"Scanning {args.file} ({len(data)} bytes)...")
    hits = scan(data, label=args.file + ": ", align=args.align)
    print(f"Done: {len(hits)} TIM candidate(s)")


if __name__ == "__main__":
    main()
