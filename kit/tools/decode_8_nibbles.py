#!/usr/bin/env python3
"""
decode_8_nibbles.py — Suikoden PS1 .8 nibble-record decoder.

Implements everything VERIFIED about the .8 nibble records, and isolates the
UNVERIFIED hypothesized parts behind explicit flags.

VERIFIED (from disassembly / container analysis):
  - Container: 16-byte records = u16 LE tag + 14 payload bytes.
  - Tag low byte = PS1 GPU primitive command (0x24-0x27 POLY_FT3, etc.).
  - Nibbles extracted HIGH nibble first (bounded-accumulation test).
  - DECODED 16-byte record layout, from drawlist_record_walker @0x801373DC:
      +0x0 u8  X coarse            (0xFF = culled/marked)
      +0x1 u8  Y coarse
      +0x2 u8  X fine: X += byte>>4
      +0x3 u8  Y fine: Y += byte>>3
      +0xC u32 object pointer       (0 = inactive record)
    Position: X = b0 + (b2>>4), Y = b1 + (b3>>3).
    See kit/docs/walker_801373DC.md for the full analysis.

HYPOTHESIZED (not code-verified, from docs/quad_record_layout.md):
  - Nibbles are signed 4-bit deltas applied to a running (cx,cy) cursor
    (turtle model). Nibbles 0-5 -> the 3 triangle vertices.
  - The nibble->field assignment for UV/color/CLUT is UNKNOWN.

Usage:
  python3 decode_8_nibbles.py <file.8> --nibbles --tag 0x225 [--limit 5]
  python3 decode_8_nibbles.py <file.8> --turtle --tag 0x225 [--scale 16]
  python3 decode_8_nibbles.py --decoded <16-byte-record-hex>
"""

import argparse
import struct
import sys


def sign4(n):
    """4-bit sign extension: stored 0..15 -> -8..+7."""
    return n - 16 if n >= 8 else n


def decode_nibbles(payload14):
    """
    Extract the 28 signed nibbles from a 14-byte .8 payload, HIGH first.

    VERIFIED extraction order (docs/quad_record_layout.md section 3.1).
    Returns list of 28 ints in -8..+7.

    NOTE: this does NOT map nibbles to fields. The nibble->(x,y,u,v,w,h)
    assignment is UNKNOWN — the true .8 unpacker was never located in
    MAIN.EXE (see docs/record_walker_location.md). Use decode_turtle()
    for the hypothesized position model.
    """
    if len(payload14) != 14:
        raise ValueError(f"payload must be 14 bytes, got {len(payload14)}")
    out = []
    for b in payload14:
        out.append(sign4((b >> 4) & 0xF))  # high first (verified)
        out.append(sign4(b & 0xF))          # low second
    return out


def decode_turtle(nibbles, scale=1):
    """
    HYPOTHESIZED turtle-model position decode (UNVERIFIED).

    Applies nibbles 0-5 as signed deltas to a running cursor:
        cx += n0; cy += n1 -> v0
        cx += n2; cy += n3 -> v1
        cx += n4; cy += n5 -> v2
    Returns (v0, v1, v2) as (x, y) tuples, or None if fewer than 6 nibbles.

    WARNING: the delta model is hypothesized, not code-verified. It gives
    bounded accumulation on CDSE18.8 but drifts on DJ2.8's full stream.
    Do not treat output as ground truth.
    """
    if len(nibbles) < 6:
        return None
    cx = nibbles[0] * scale
    cy = nibbles[1] * scale
    v0 = (cx, cy)
    cx += nibbles[2] * scale
    cy += nibbles[3] * scale
    v1 = (cx, cy)
    cx += nibbles[4] * scale
    cy += nibbles[5] * scale
    v2 = (cx, cy)
    return (v0, v1, v2)


def parse_decoded_record(rec16):
    """
    Parse a 16-byte DECODED record (walker @0x801373DC input format).

    VERIFIED from disassembly. Layout:
      +0x0 u8 X coarse, +0x1 u8 Y coarse,
      +0x2 u8 X fine (>>4), +0x3 u8 Y fine (>>3),
      +0xC u32 object pointer.
    Returns dict with x, y, active, obj_ptr, raw bytes.
    """
    if len(rec16) != 16:
        raise ValueError(f"decoded record must be 16 bytes, got {len(rec16)}")
    b0, b1, b2, b3 = rec16[0], rec16[1], rec16[2], rec16[3]
    obj_ptr = struct.unpack_from("<I", rec16, 0xC)[0]
    x = b0 + (b2 >> 4)
    y = b1 + (b3 >> 3)
    return {
        "x": x,
        "y": y,
        "x_coarse": b0,
        "y_coarse": b1,
        "x_fine": b2 >> 4,
        "y_fine": b3 >> 3,
        "culled": b0 == 0xFF,
        "active": obj_ptr != 0,
        "obj_ptr": obj_ptr,
    }


def parse_8(path):
    """Parse .8 container into list of (tag, payload14)."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) % 16:
        print(f"warning: size {len(data)} not a multiple of 16", file=sys.stderr)
    recs = []
    for i in range(len(data) // 16):
        tag = struct.unpack_from("<H", data, i * 16)[0]
        recs.append((tag, data[i * 16 + 2:i * 16 + 16]))
    return recs


# tag low byte -> PS1 GPU primitive (verified mapping)
PRIM = {
    0x24: "POLY_FT3", 0x25: "POLY_FT3", 0x26: "POLY_FT3", 0x27: "POLY_FT3",
    0x28: "POLY_F4", 0x29: "POLY_F4", 0x2A: "POLY_F4", 0x2B: "POLY_F4",
    0x2C: "POLY_FT4", 0x2D: "POLY_FT4", 0x2E: "POLY_FT4", 0x2F: "POLY_FT4",
    0x30: "POLY_G3", 0x31: "POLY_G3", 0x32: "POLY_G3", 0x33: "POLY_G3",
    0x34: "POLY_GT3", 0x35: "POLY_GT3", 0x36: "POLY_GT3", 0x37: "POLY_GT3",
    0x44: "LINE_F2", 0x45: "LINE_F2", 0x46: "LINE_F2", 0x47: "LINE_F2",
}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("file", nargs="?", help=".8 file to parse")
    ap.add_argument("--tag", type=lambda s: int(s, 0), default=None,
                    help="only show records with this tag (e.g. 0x225)")
    ap.add_argument("--limit", type=int, default=5, help="max records to show")
    ap.add_argument("--nibbles", action="store_true",
                    help="print 28 high-first nibbles per record (verified)")
    ap.add_argument("--turtle", action="store_true",
                    help="apply HYPOTHESIZED turtle decode to nibbles 0-5")
    ap.add_argument("--scale", type=int, default=1, help="turtle scale factor")
    ap.add_argument("--decoded", metavar="HEX",
                    help="parse a 16-byte DECODED record (32 hex chars)")
    args = ap.parse_args()

    if args.decoded:
        rec = bytes.fromhex(args.decoded)
        r = parse_decoded_record(rec)
        print(f"decoded record: X={r['x']} (coarse {r['x_coarse']}+fine {r['x_fine']}), "
              f"Y={r['y']} (coarse {r['y_coarse']}+fine {r['y_fine']}), "
              f"active={r['active']}, culled={r['culled']}, obj=0x{r['obj_ptr']:08X}")
        return

    if not args.file:
        ap.error("need a .8 file (or --decoded)")
    recs = parse_8(args.file)
    shown = 0
    for idx, (tag, payload) in enumerate(recs):
        if args.tag is not None and tag != args.tag:
            continue
        if shown >= args.limit:
            break
        shown += 1
        prim = PRIM.get(tag & 0xFF, "?")
        flag20 = "0x20" if tag & 0x20 else "----"
        print(f"rec {idx}: tag=0x{tag:04X} ({prim}, flag {flag20}) payload={payload.hex()}")
        if args.nibbles or args.turtle:
            nb = decode_nibbles(payload)
            if args.nibbles:
                print(f"  nibbles(high-first): {nb}")
            if args.turtle:
                t = decode_turtle(nb, args.scale)
                print(f"  turtle(HYPOTHESIZED, scale={args.scale}): {t}")
    print(f"({shown} shown of {len(recs)} records)")


if __name__ == "__main__":
    main()
