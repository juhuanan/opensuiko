#!/usr/bin/env python3
"""

> **CORRECTION 2026-10-05 — `.8` FILES ARE XA AUDIO.**
> They are MODE2 **Form 2** sectors (2324-byte user field); `disc.extract()`
> returns the Form 1 (2048-byte) field, so every "record" this file reads is a
> 276-bytes-per-sector alignment artifact, and the payload/nibble layout asserted
> below describes that misread stream. Every sampled sector of all 67 `.8` files
> carries XA submode `0x08` = audio. Kept as the error record; its renders are not
> art. See `kit/docs/dot8_is_xa_audio.md`.
eight_gpu_parse.py — Parse Suikoden PS1 .8 area display-list records.

STATUS 2026-10-01: SUBSTANTIALLY DECODED (static analysis + geometric validation).
The "literal GPU packet" hypothesis is REFUTED (see notes). The records are a
compact engine-specific encoding; the tag's low byte is the PS1 GPU primitive
command and the payload is a compressed form the engine expands.

Record layout (16 bytes, validated across 18M records / 67 files):
    [u16 tag LE][14 bytes payload]

Tag structure:
    bits 8-11 : category  (0x2 = data, 0x3 = terminator, 0x6 = section marker)
    bit  5     : 0x20 — GPU primitive flag (walker: bit set -> GPU-packet path
                via 0x800C3D8C/0x800C3D38; clear -> dropped/marked 0xFF)
    bits 5-6   : 0x60 — zero -> record skipped entirely (walker @0x80137578)
    bits 0-7   : GPU primitive command (Sony documented values):
        0x22-0x23 POLY_F3   0x24-0x27 POLY_FT3  0x28-0x2B POLY_F4
        0x2C-0x2F POLY_FT4  0x32-0x33 POLY_G3   0x34-0x37 POLY_GT3
        0x38-0x3B POLY_G4   0x3C-0x3F POLY_GT4  0x42-0x4B lines
        (0x44-0x47/0x4C-0x4F are not Sony GPU commands; engine maps the
        0x40-0x4F family to line packets itself)

Why NOT literal GPU packets (refutation):
    A POLY_FT3 packet is 7 words (28 B); POLY_F4 5 words (20 B); POLY_GT4
    13 words (52 B). Records carry 14 payload bytes. Only LINE_F2 (3 words =
    12 B) could fit, with 2 spare bytes. The engine's drawlist walker
    (0x801373DC) + GPU-packet builder (0x800C3D8C) expand the compact form.

VALIDATED payload encodings (geometric coherence confirmed by wireframe
renders: DJ2.8 FT3 mesh forms coherent regions; F4 quads are convex and
sane-sized):

  POLY_FT3 (0x224-0x227):
      [X0,Y0,U0,V0, X1,Y1,U1,V1, X2,Y2,U2,V2, E0,E1]
      X,Y = signed s8 screen coords; U,V = u8 texture coords (0-255).
      E0,E1 = 2-byte per-primitive field, spatially smooth, approximately
      tracks the triangle's UV location (mean(E0-U0)~0, std~27). Exact
      semantics OPEN (candidates: texture block/layer id, OT sort key,
      packed texpage/CLUT). It is NOT depth-sorted in file order
      (mean|dE| between consecutive records ~24826, i.e. random).

  POLY_F4 (0x228-0x2B):
      [X0,Y0,X1,Y1,X2,Y2,X3,Y3, R,G,B, S, E0,E1]
      X,Y = signed s8; R,G,B = u8 flat color; S = 1 spare byte (open);
      E0,E1 = same per-primitive field as FT3 (corr(E,Y) weaker: -0.53).

OPEN: gouraud families (0x232-0x23C), line families (0x242-0x24C),
control records (0x202-0x21C), exact E0E1 semantics, texture page/CLUT
source, draw offset, coordinate-system origin.

Usage:
    python3 eight_gpu_parse.py <file.8> [--png out.png] [--limit N]
"""

import struct, sys, math
from collections import Counter

# ---------------------------------------------------------------- tag map

GPU_PRIMS = {
    0x22: "POLY_F3", 0x23: "POLY_F3",
    0x24: "POLY_FT3", 0x25: "POLY_FT3", 0x26: "POLY_FT3", 0x27: "POLY_FT3",
    0x28: "POLY_F4", 0x29: "POLY_F4", 0x2A: "POLY_F4", 0x2B: "POLY_F4",
    0x2C: "POLY_FT4", 0x2D: "POLY_FT4", 0x2E: "POLY_FT4", 0x2F: "POLY_FT4",
    0x32: "POLY_G3", 0x33: "POLY_G3",
    0x34: "POLY_GT3", 0x35: "POLY_GT3", 0x36: "POLY_GT3", 0x37: "POLY_GT3",
    0x38: "POLY_G4", 0x39: "POLY_G4", 0x3A: "POLY_G4", 0x3B: "POLY_G4",
    0x3C: "POLY_GT4", 0x3D: "POLY_GT4", 0x3E: "POLY_GT4", 0x3F: "POLY_GT4",
    0x42: "LINE_F2", 0x43: "LINE_F2",
    0x44: "LINE?", 0x45: "LINE?", 0x46: "LINE?", 0x47: "LINE?",
    0x48: "POLYLINE?", 0x49: "POLYLINE?", 0x4A: "POLYLINE?", 0x4B: "POLYLINE?",
}

# Sony GPU packet sizes in 32-bit words (command word included)
GPU_PACKET_WORDS = {
    "POLY_F3": 4, "POLY_FT3": 7, "POLY_F4": 5, "POLY_FT4": 9,
    "POLY_G3": 6, "POLY_GT3": 9, "POLY_G4": 9, "POLY_GT4": 13,
    "LINE_F2": 3,
}

def s8(b):
    return b - 256 if b >= 128 else b

def decode_tag(tag):
    """Return dict with category, gpu_cmd, prim name, flag bits."""
    return {
        "tag": tag,
        "category": (tag >> 8) & 0xF,
        "gpu_cmd": tag & 0xFF,
        "prim": GPU_PRIMS.get(tag & 0xFF, "CONTROL/UNKNOWN"),
        "bit_0x20": bool(tag & 0x20),
        "bits_0x60": bool(tag & 0x60),
    }

# ---------------------------------------------------------------- payload parsers (validated)

def parse_ft3(p):
    """14 payload bytes -> textured triangle. VALIDATED geometrically."""
    v = [((s8(p[0]), s8(p[1])), (p[2], p[3])),
         ((s8(p[4]), s8(p[5])), (p[6], p[7])),
         ((s8(p[8]), s8(p[9])), (p[10], p[11]))]
    return {"verts": v, "e": (p[12], p[13]), "e_u16": p[12] | (p[13] << 8)}

def parse_f4(p):
    """14 payload bytes -> flat quad. VALIDATED geometrically."""
    v = [(s8(p[0]), s8(p[1])), (s8(p[2]), s8(p[3])),
         (s8(p[4]), s8(p[5])), (s8(p[6]), s8(p[7]))]
    return {"verts": v, "rgb": (p[8], p[9], p[10]), "spare": p[11],
            "e": (p[12], p[13]), "e_u16": p[12] | (p[13] << 8)}

def tri_area(v):
    (x0, y0), (x1, y1), (x2, y2) = v
    return abs((x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)) / 2

def quad_area(v):
    return abs(sum(v[i][0] * v[(i + 1) % 4][1] - v[(i + 1) % 4][0] * v[i][1]
                   for i in range(4))) / 2

# ---------------------------------------------------------------- file parse

def parse_file(path, limit=None):
    with open(path, "rb") as fh:
        data = fh.read()
    n = len(data) // 16
    recs = []
    for i in range(n):
        if limit and len(recs) >= limit:
            break
        tag = struct.unpack_from("<H", data, i * 16)[0]
        recs.append((i, tag, data[i * 16 + 2:i * 16 + 16]))
    return recs

def validation_report(path, limit=None):
    recs = parse_file(path, limit)
    fam = Counter()
    ft3_areas, f4_areas = [], []
    ft3_ys, ft3_es = [], []
    for i, tag, p in recs:
        t = decode_tag(tag)
        fam[t["prim"]] += 1
        if t["prim"] == "POLY_FT3":
            r = parse_ft3(p)
            xy = [v[0] for v in r["verts"]]
            ft3_areas.append(tri_area(xy))
            ft3_ys.append(sum(y for x, y in xy) / 3)
            ft3_es.append(r["e_u16"])
        elif t["prim"] == "POLY_F4":
            r = parse_f4(p)
            f4_areas.append(quad_area(r["verts"]))
    print(f"== {path} ({len(recs)} records) ==")
    print("primitive families:", dict(fam))
    if ft3_areas:
        a = ft3_areas
        print(f"FT3 n={len(a)} area mean={sum(a)/len(a):.0f} "
              f"frac<200={sum(1 for x in a if x<200)/len(a):.1%} "
              f"frac>20000={sum(1 for x in a if x>20000)/len(a):.1%}")
        if ft3_es:
            mx = sum(ft3_es) / len(ft3_es); my = sum(ft3_ys) / len(ft3_ys)
            cov = sum((x - mx) * (y - my) for x, y in zip(ft3_es, ft3_ys)) / len(ft3_es)
            vx = sum((x - mx) ** 2 for x in ft3_es) / len(ft3_es)
            vy = sum((y - my) ** 2 for y in ft3_ys) / len(ft3_ys)
            print(f"FT3 corr(E_u16, Ycentroid)={cov / math.sqrt(vx * vy):.3f}")
    if f4_areas:
        a = f4_areas
        print(f"F4  n={len(a)} area mean={sum(a)/len(a):.0f} "
              f"frac<50={sum(1 for x in a if x<50)/len(a):.1%} "
              f"frac>10000={sum(1 for x in a if x>10000)/len(a):.1%}")

def render_wireframe(path, out, limit=20000):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    recs = parse_file(path)
    polys, colors, is_ft3 = [], [], []
    for i, tag, p in recs:
        t = decode_tag(tag)
        if t["prim"] == "POLY_FT3":
            r = parse_ft3(p)
            polys.append([(x, -y) for (x, y), uv in r["verts"]])
            colors.append(r["e_u16"]); is_ft3.append(True)
        elif t["prim"] == "POLY_F4":
            r = parse_f4(p)
            polys.append([(x, -y) for x, y in r["verts"]])
            colors.append(r["e_u16"]); is_ft3.append(False)
        if len(polys) >= limit:
            break
    fig, ax = plt.subplots(figsize=(12, 12))
    coll = PolyCollection(polys, array=colors, cmap="viridis", edgecolors="none")
    ax.add_collection(coll)
    ax.autoscale_view(); ax.set_aspect("equal")
    plt.colorbar(coll, ax=ax, label="E0E1 u16")
    ax.set_title(f"{path}: FT3+F4 wireframe colored by E (n={len(polys)})")
    plt.savefig(out, dpi=80, bbox_inches="tight")
    print(f"wrote {out}")

if __name__ == "__main__":
    path = sys.argv[1]
    out = None; limit = None
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--png": out = args[i + 1]; i += 2
        elif args[i] == "--limit": limit = int(args[i + 1]); i += 2
        else: i += 1
    validation_report(path, limit)
    if out:
        render_wireframe(path, out, limit or 20000)
