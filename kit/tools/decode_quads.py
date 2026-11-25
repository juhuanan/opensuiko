#!/usr/bin/env python3
"""
decode_quads.py — Suikoden PS1 .8 area-file textured-quad decoder + box-map renderer.

Parses the .8 container (16-byte records: u16 tag + 14 payload bytes),
extracts the 28 high-first signed nibbles from drawable records, applies the
hypothesized turtle-model delta decode, and renders an SVG box map.

UNCERTAINTY LEDGER (see docs/quad_record_layout.md for full analysis):
  VERIFIED:
    - Container: 16-byte records, u16 LE tag + 14 payload bytes.
    - Tag low byte = PS1 GPU primitive command (0x24-0x27 POLY_FT3, etc.).
    - 0x20C/zero = padding; 0x3xx = terminator; 0x6xx = section marker.
    - Payload nibbles are extracted HIGH nibble first (bounded-accumulation
      test: high-first stays within +-155 over 1140 records; low-first
      drifts to +-9000).
  HYPOTHESIZED (not code-verified):
    - Nibbles are signed 4-bit deltas applied to a running (cx,cy) cursor
      (turtle model). Nibbles 0-5 -> the 3 triangle vertices.
    - Coordinate scale: raw 4-bit deltas give tiny triangles; --scale 16
      is a guess.
    - Nibble->field assignment for UV/color/CLUT is unknown; only positions
      are decoded.

Usage:
    python3 decode_quads.py <file.8> [--tag 0x225] [--scale 16] [-o out.svg]
    python3 decode_quads.py <file.8> --stats      # tag histogram only
"""

import argparse
import struct
import sys
from collections import Counter

# tag low-byte -> primitive name
PRIM_NAMES = {
    0x20: "POLY_F3",  0x21: "POLY_F3",  0x22: "POLY_F3",  0x23: "POLY_F3",
    0x24: "POLY_FT3", 0x25: "POLY_FT3", 0x26: "POLY_FT3", 0x27: "POLY_FT3",
    0x28: "POLY_F4",  0x29: "POLY_F4",  0x2A: "POLY_F4",  0x2B: "POLY_F4",
    0x2C: "POLY_FT4", 0x2D: "POLY_FT4", 0x2E: "POLY_FT4", 0x2F: "POLY_FT4",
    0x30: "POLY_G3",  0x31: "POLY_G3",  0x32: "POLY_G3",  0x33: "POLY_G3",
    0x34: "POLY_GT3", 0x35: "POLY_GT3", 0x36: "POLY_GT3", 0x37: "POLY_GT3",
    0x38: "POLY_G4",  0x39: "POLY_G4",  0x3A: "POLY_G4",  0x3B: "POLY_G4",
    0x3C: "POLY_GT4", 0x3D: "POLY_GT4", 0x3E: "POLY_GT4", 0x3F: "POLY_GT4",
    0x40: "LINE_F1",  0x41: "LINE_F1",  0x42: "LINE_F1",  0x43: "LINE_F1",
    0x44: "LINE_F2",  0x45: "LINE_F2",  0x46: "LINE_F2",  0x47: "LINE_F2",
    0x48: "LINE_F3",  0x49: "LINE_F3",  0x4A: "LINE_F3",  0x4B: "LINE_F3",
    0x4C: "LINE_G2",  0x4D: "LINE_G2",  0x4E: "LINE_G2",  0x4F: "LINE_G2",
    0x50: "LINE_G3",  0x51: "LINE_G3",  0x52: "LINE_G3",  0x53: "LINE_G3",
    0x60: "TILE",     0x61: "TILE",     0x62: "TILE",     0x63: "TILE",
    0x64: "SPRITE",   0x65: "SPRITE",   0x66: "SPRITE",   0x67: "SPRITE",
    0x68: "TILE_1",   0x69: "TILE_8",   0x6A: "TILE_16",
}

TRI_TAGS = [t for t in range(0x200, 0x300)
            if (t & 0xFF) in (0x20, 0x21, 0x22, 0x23,
                              0x24, 0x25, 0x26, 0x27,
                              0x34, 0x35, 0x36, 0x37)]


def sign4(n):
    return n - 16 if n >= 8 else n


def nibbles_high_first(payload14):
    """Extract 28 signed nibbles, HIGH nibble first (verified order)."""
    out = []
    for b in payload14:
        out.append(sign4((b >> 4) & 0xF))
        out.append(sign4(b & 0xF))
    return out


def parse_8(path):
    """Return list of (tag, payload14) tuples."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) % 16:
        print(f"warning: file size {len(data)} not a multiple of 16",
              file=sys.stderr)
    recs = []
    for i in range(len(data) // 16):
        tag = struct.unpack_from("<H", data, i * 16)[0]
        recs.append((tag, data[i * 16 + 2:i * 16 + 16]))
    return recs


def decode_triangles(recs, tags=None, scale=1):
    """
    Hypothesized turtle-model decode.
    Returns list of ((x0,x1,x2),(y0,y1,y2)) triangles.
    """
    if tags is None:
        tags = TRI_TAGS
    tagset = set(tags)
    cx = cy = 0
    tris = []
    for tag, payload in recs:
        if tag not in tagset:
            continue
        nb = nibbles_high_first(payload)
        # HYPOTHESIS: nibbles 0-5 are (dx0,dy0,dx1,dy1,dx2,dy2)
        cx += nb[0] * scale; cy += nb[1] * scale; v0 = (cx, cy)
        cx += nb[2] * scale; cy += nb[3] * scale; v1 = (cx, cy)
        cx += nb[4] * scale; cy += nb[5] * scale; v2 = (cx, cy)
        tris.append(((v0[0], v1[0], v2[0]), (v0[1], v1[1], v2[1])))
    return tris


def render_svg(tris, out_path, width=800, height=800):
    xs = [v for t in tris for v in t[0]]
    ys = [v for t in tris for v in t[1]]
    if not xs:
        print("no triangles to render", file=sys.stderr)
        return
    mnx, mxx = min(xs), max(xs)
    mny, mxy = min(ys), max(ys)
    sx = width / (mxx - mnx) if mxx > mnx else 1
    sy = height / (mxy - mny) if mxy > mny else 1
    s = min(sx, sy)
    with open(out_path, "w") as f:
        f.write(f'<svg width="{width}" height="{height}" '
                f'xmlns="http://www.w3.org/2000/svg">\n')
        f.write('<rect width="100%" height="100%" fill="black"/>\n')
        for (x0, x1, x2), (y0, y1, y2) in tris:
            pts = " ".join(
                f"{(x - mnx) * s:.1f},{(y - mny) * s:.1f}"
                for x, y in ((x0, y0), (x1, y1), (x2, y2)))
            f.write(f'<polygon points="{pts}" fill="none" '
                    f'stroke="lime" stroke-width="0.5"/>\n')
        f.write("</svg>\n")
    print(f"wrote {out_path} ({len(tris)} tris, "
          f"x [{mnx},{mxx}] y [{mny},{mxy}])")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("file", help=".8 area file")
    ap.add_argument("--tag", default=None,
                    help="only decode this tag (hex, e.g. 0x225); "
                         "default: all triangle tags")
    ap.add_argument("--scale", type=int, default=16,
                    help="nibble-delta scale factor (hypothesized, default 16)")
    ap.add_argument("-o", "--out", default="boxmap.svg",
                    help="output SVG path")
    ap.add_argument("--stats", action="store_true",
                    help="print tag histogram and exit")
    args = ap.parse_args()

    recs = parse_8(args.file)
    print(f"{len(recs)} records")

    if args.stats:
        c = Counter(tag for tag, _ in recs)
        print(f"{len(c)} distinct tags")
        for tag, n in c.most_common(20):
            prim = PRIM_NAMES.get(tag & 0xFF, "?")
            print(f"  {tag:#07x} {n:6d}  {prim}")
        return

    tags = [int(args.tag, 16)] if args.tag else None
    tris = decode_triangles(recs, tags=tags, scale=args.scale)
    render_svg(tris, args.out)


if __name__ == "__main__":
    main()
