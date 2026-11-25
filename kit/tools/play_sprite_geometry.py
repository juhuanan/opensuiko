#!/usr/bin/env python3
"""`DATA/04_PLAY` sprite geometry: the e-record draw-piece rectangles.

This tool separates two stages, and the separation is the point:

**PROBE (disc-derived, no interpretation).** The container is walked exactly as
`kit/tools/parse_04play.py` documents it: a 5-slot u32 header at `0x20`
(`[offset_table_ptr, S1, S2, S3, S4]`), a section header per section
(`[i16 a][i16 b][u8 c_count][u8 d_flags][u8 ret][u8 unk][u32 c][u32 d][u32 e][u32 f]`),
u32 pointer tables, `[u32 len][LZSS]` graphic blobs, and raw RGB555 palettes.
Every blob is decoded with `lzss.py` v2.0.0 and **the measured consumption must
equal the container length** or the record is rejected.

**INFERENCE (derived, and falsifiable).** Each section's `e` table is an array of
16-byte records. The record layout and the piece rectangle below are *derived*
from the disc by `derive_rect()`; they are not fitted to a picture. See
`kit/docs/play_sprite_geometry.md` for the derivation and the
constraints that discriminate it, and `kit/tests/test_play_sprite_geometry.py`
for the independent re-derivation.

Record layout (16 bytes, little-endian):

```
+0x00 u8   u           1, and 2 on 8 records corpus-wide
+0x01 u8   v           always 0
+0x02 u8   w           piece width  in pixels, 8..64
+0x03 u8   h           piece height in pixels, 8..64
+0x04 u16  tpage       GPU texture-page word
+0x06 u16  clut        GPU CLUT word
+0x08 u8   -           }
+0x09 u8   -           }  low 3 bytes of the u32 the parser calls `src`;
+0x0A u8   atlas_sel_a }  `+0x0A` and `+0x0F` split pieces that share one
+0x0B u8   tile        }  tpage; `+0x0B` is the SOURCE TILE byte:
+0x0C u8   w-1            x = (tile & 0x0F) * 8
+0x0D u8   h-1            y = (tile >> 4) * 8   (full 4-bit row, no mask)
+0x0E u8   0
+0x0F u8   atlas_sel_b   0 or 2; never 2 together with atlas_sel_a == 1
```

The atlas is **128x128 8bpp = 16,384 bytes** (one LZSS blob) with a **32-colour**
palette from the section's `d` blob; index 0 is transparent. `0x04`'s low bits
are *not* the texture depth -- reading the blob as 4bpp yields noise while 8bpp
yields the character, so the tile-descriptor report's "4-bit, palette-animated"
reading of this table is refuted (`kit/docs/decode_04play_tile_descriptors.md`
now carries a correction banner).

**What carries the derivation, and what does not.** The rectangle rests on two
constraints that need no grouping at all, each measured against a null that
shuffles the tile byte and keeps the sizes (`--stats` recomputes both):

| reading | out of bounds (observed 0; null 128-179) | edge landings (observed 500; null 240-304) |
|---|---|---|
| **derived** | **0** | **500** |
| `masked` (y & 7) | 0 | 170 |
| `pitch12` (y*12) | 422 | 175 |
| `lowbyte` (tile at +0x08) | 3 | 9 |

Only the derived reading satisfies both. A third observation -- that pieces
sharing a `(tpage, +0x0A, +0x0F)` grouping are pixel-disjoint (719/724 groups,
99.3 %) -- **supports** the formula but is weaker evidence, because the
`(+0x0A, +0x0F)` half of that grouping is chosen to maximise disjointness rather
than derived: `tpage` alone leaves 75.4 % of groups disjoint, because a section's
12 palette/variant pieces share one page.

Usage:
    play_sprite_geometry.py --list                 # the 78 files and their sections
    play_sprite_geometry.py --file AIL.BIN         # probe + derived rects for one file
    play_sprite_geometry.py --stats                # the corpus-wide derivation evidence
    play_sprite_geometry.py --all --json out.json  # every piece, machine-readable
    play_sprite_geometry.py --sheet OUTDIR         # contact sheets, one per file
"""
from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import disc  # noqa: E402
import disc_iso  # noqa: E402
import lzss  # noqa: E402
from psx_vram import rgb555  # noqa: E402

PLAY_PREFIX = "DATA/04_PLAY/"
ATLAS_W = 128
ATLAS_H = 128
ATLAS_BYTES = ATLAS_W * ATLAS_H          # 16384, the measured LZSS output size
E_RECORD = 16
HEADER_OFF = 0x20
#: the two bytes that together select which blob an e-record samples
SEL_A_OFF = 0x0A
SEL_B_OFF = 0x0F
#: the source-tile byte
TILE_OFF = 0x0B
TILE_PITCH = 8                            # pixels per tile step, both axes
DECODER_ID = "kit/tools/lzss.py v2.0.0"


# --------------------------------------------------------------------------
# PROBE -- container walk.  No interpretation lives in this section.
# --------------------------------------------------------------------------

def play_files() -> list[dict]:
    iso = os.path.join(_KIT, "extracted", "iso_files.json")
    out = [r for r in disc_iso.iso_records(iso) if r.get("path", "").startswith(PLAY_PREFIX)]
    return sorted(out, key=lambda r: r["path"])


def load(path_or_name: str) -> tuple[str, bytes]:
    """Load a 04_PLAY file by basename or by full disc path."""
    recs = play_files()
    for r in recs:
        if r["path"] == path_or_name or os.path.basename(r["path"]) == path_or_name:
            return os.path.basename(r["path"]), disc.extract(r["lba"], r["size"])
    raise SystemExit("no such DATA/04_PLAY file: %s" % path_or_name)


def probe(name: str, d: bytes) -> dict:
    """Walk the container.  Raises on any inconsistency; never guesses."""
    slots = [struct.unpack_from("<I", d, HEADER_OFF + 4 * i)[0] for i in range(5)]
    out = {"file": name, "size": len(d), "slots": slots, "sections": []}
    for si in (1, 2):
        so = slots[si]
        if not so or so + 0x18 > len(d):
            continue
        a, b = struct.unpack_from("<hh", d, so)
        c_count, d_flags = d[so + 4], d[so + 5]
        ctab, dtab, etab, ftab = struct.unpack_from("<IIII", d, so + 8)
        sec = {"name": "S%d" % si, "sec_off": so, "a": a, "b": b,
               "c_count": c_count, "d_flags": d_flags,
               "c_tab": ctab, "d_tab": dtab, "e_tab": etab, "f_tab": ftab}
        # palette: the d table's first entry, raw RGB555, no length prefix
        if dtab and dtab + 4 <= len(d):
            dptr = struct.unpack_from("<I", d, dtab)[0]
            pal_words = struct.unpack_from("<32H", d, dptr) if dptr + 64 <= len(d) else None
            sec["palette_off"] = dptr
            sec["palette"] = list(pal_words) if pal_words else None
        # blobs: [u32 len][LZSS], measured consumption must equal len
        blobs = []
        for k in range(c_count):
            t = struct.unpack_from("<I", d, ctab + 4 * k)[0]
            ln = struct.unpack_from("<I", d, t)[0]
            payload = d[t + 4 : t + 4 + ln]
            if len(payload) != ln:
                raise ValueError("%s %s: c-blob %d short read" % (name, sec["name"], k))
            atlas, used = lzss.decode(payload)
            if used != ln:
                raise ValueError("%s %s: c-blob %d consumed %d of %d"
                                 % (name, sec["name"], k, used, ln))
            if len(atlas) != ATLAS_BYTES:
                raise ValueError("%s %s: c-blob %d -> %d bytes, expected %d"
                                 % (name, sec["name"], k, len(atlas), ATLAS_BYTES))
            blobs.append(atlas)
        sec["blobs"] = blobs
        # e records
        recs = []
        for k in range(a):
            t = struct.unpack_from("<I", d, etab + 4 * k)[0]
            recs.append(d[t : t + E_RECORD])
        sec["e_raw"] = recs
        out["sections"].append(sec)
    return out


# --------------------------------------------------------------------------
# INFERENCE -- the derived rectangle.  This is the claim under test.
# --------------------------------------------------------------------------

def derive_rect(raw: bytes, mode: str = "derived") -> dict:
    """The piece rectangle for one 16-byte e-record.

    `mode` exists only so the test can show the *alternatives* fail:
      derived   x=(+0x0B & 0x0F)*8, y=(+0x0B >> 4)*8   <- shipped
      masked    y uses (+0x0B >> 4) & 0x07             <- refuted
      pitch12   y = (+0x0B >> 4) * 12                  <- refuted
      lowbyte   tile byte read from +0x08              <- refuted
    """
    u, v, w, h = raw[0], raw[1], raw[2], raw[3]
    tpage, clut = struct.unpack_from("<HH", raw, 4)
    if mode == "derived":
        tile = raw[TILE_OFF]
        x, y = (tile & 0x0F) * TILE_PITCH, (tile >> 4) * TILE_PITCH
    elif mode == "masked":
        tile = raw[TILE_OFF]
        x, y = (tile & 0x0F) * TILE_PITCH, ((tile >> 4) & 0x07) * TILE_PITCH
    elif mode == "pitch12":
        tile = raw[TILE_OFF]
        x, y = (tile & 0x0F) * TILE_PITCH, (tile >> 4) * 12
    elif mode == "lowbyte":
        tile = raw[0x08]
        x, y = (tile & 0x0F) * TILE_PITCH, ((tile >> 4) & 0x07) * TILE_PITCH
    else:
        raise ValueError("unknown mode %r" % mode)
    return {
        "u": u, "v": v, "w": w, "h": h,
        "tpage": tpage, "clut": clut,
        "tile": raw[TILE_OFF],
        "x": x, "y": y,
        "atlas": (raw[SEL_A_OFF], raw[SEL_B_OFF]),
        "w_minus_1": raw[0x0C], "h_minus_1": raw[0x0D],
        "oob": (x + w > ATLAS_W) or (y + h > ATLAS_H),
    }


def cut(atlas: bytes, rect: dict, palette) -> "list[list]":
    """The piece's pixels: (r,g,b,a) rows, index 0 transparent."""
    x, y, w, h = rect["x"], rect["y"], rect["w"], rect["h"]
    if rect["oob"]:
        raise ValueError("rect out of atlas: %r" % rect)
    rows = []
    for yy in range(h):
        row = []
        base = (y + yy) * ATLAS_W + x
        for xx in range(w):
            i = atlas[base + xx]
            if i == 0:
                row.append((0, 0, 0, 0))
            else:
                r, g, b = palette[i % len(palette)]
                row.append((r, g, b, 255))
        rows.append(row)
    return rows


def pieces(name: str, d: bytes) -> list[dict]:
    """Every e-record of a file as a derived piece."""
    pr = probe(name, d)
    out = []
    for sec in pr["sections"]:
        pal = [rgb555(w) for w in (sec.get("palette") or [])]
        for k, raw in enumerate(sec["e_raw"]):
            r = derive_rect(raw)
            r["section"] = sec["name"]
            r["index"] = k
            r["palette_ok"] = bool(pal)
            out.append(r)
    return out


# --------------------------------------------------------------------------
# the corpus-wide derivation evidence
# --------------------------------------------------------------------------

def _all_records() -> list:
    out = []
    for rec in play_files():
        nm, d = load(rec["path"])
        for sec in probe(nm, d)["sections"]:
            out += list(sec["e_raw"])
    return out


def null_test(trials: int = 400, seed: int = 20261006) -> dict:
    """Shuffle the tile byte across pieces, keep (w,h); measure the two
    constraints that the derivation must beat.  No PIL, no rendering."""
    import random
    recs = _all_records()
    tiles = [r[TILE_OFF] for r in recs]
    wh = [(r[2], r[3]) for r in recs]
    rng = random.Random(seed)
    oob, land = [], []
    for _ in range(trials):
        rng.shuffle(tiles)
        o = l = 0
        for t, (w, h) in zip(tiles, wh):
            x, y = (t & 0x0F) * TILE_PITCH, (t >> 4) * TILE_PITCH
            if x + w > ATLAS_W or y + h > ATLAS_H:
                o += 1
            if x + w == ATLAS_W or y + h == ATLAS_H:
                l += 1
        oob.append(o)
        land.append(l)
    obs_oob = sum(1 for r in recs if derive_rect(r)["oob"])
    obs_land = sum(1 for r in recs
                   if derive_rect(r)["x"] + r[2] == ATLAS_W
                   or derive_rect(r)["y"] + r[3] == ATLAS_H)
    return {
        "trials": trials, "records": len(recs),
        "observed_out_of_bounds": obs_oob,
        "null_out_of_bounds": [min(oob), max(oob), round(sum(oob) / len(oob), 1)],
        "observed_edge_landings": obs_land,
        "null_edge_landings": [min(land), max(land), round(sum(land) / len(land), 1)],
        "alternatives": {
            m: {
                "out_of_bounds": sum(1 for r in recs if derive_rect(r, m)["oob"]),
                "edge_landings": sum(
                    1 for r in recs
                    if derive_rect(r, m)["x"] + r[2] == ATLAS_W
                    or derive_rect(r, m)["y"] + r[3] == ATLAS_H),
            } for m in ("masked", "pitch12", "lowbyte")
        },
    }


def stats() -> dict:
    """The three structural constraints that discriminate the derivation.

    1. bounds      -- every piece must lie inside 128x128
    2. packing     -- pieces sharing an atlas must not overlap
    3. grid        -- a well-packed sheet lands pieces exactly on the edges
    """
    per_mode = {}
    for mode in ("derived", "masked", "pitch12", "lowbyte"):
        oob = n = 0
        for rec in play_files():
            nm, d = load(rec["path"])
            pr = probe(nm, d)
            for sec in pr["sections"]:
                for raw in sec["e_raw"]:
                    r = derive_rect(raw, mode)
                    n += 1
                    if r["oob"]:
                        oob += 1
        per_mode[mode] = {"records": n, "out_of_bounds": oob}

    groups = clean = 0
    overlap_px = 0
    dup_groups = []
    sel_pairs = collections.Counter()
    dup_pairs = 0
    w_bad = 0
    for rec in play_files():
        nm, d = load(rec["path"])
        pr = probe(nm, d)
        for sec in pr["sections"]:
            g = collections.defaultdict(list)
            for raw in sec["e_raw"]:
                r = derive_rect(raw)
                g[(r["tpage"],) + r["atlas"]].append(r)
                sel_pairs[r["atlas"]] += 1
                if raw[0x0C] != (r["w"] - 1) & 0xFF or raw[0x0D] != (r["h"] - 1) & 0xFF:
                    w_bad += 1
            for key, items in g.items():
                groups += 1
                cells = {}
                bad = 0
                for r in items:
                    for yy in range(r["y"], r["y"] + r["h"]):
                        for xx in range(r["x"], r["x"] + r["w"]):
                            if (xx, yy) in cells:
                                bad += 1
                            else:
                                cells[(xx, yy)] = 1
                overlap_px += bad
                if bad:
                    rects = collections.Counter(
                        (r["x"], r["y"], r["w"], r["h"]) for r in items)
                    exact = [v for v in rects.values() if v > 1]
                    dup_pairs += len(exact)
                    dup_groups.append({"file": nm, "section": sec["name"],
                                       "group": list(key), "overlap_px": bad,
                                       "duplicate_rects": len(exact),
                                       "n": len(items)})
                else:
                    clean += 1
    null = null_test()
    return {
        "null": null,
        "files": len(play_files()),
        "modes": per_mode,
        "grouping": "(tpage, +0x0A, +0x0F)",
        "atlas_groups": groups,
        "atlas_groups_clean": clean,
        "overlap_px": overlap_px,
        "unclean_groups": dup_groups,
        "groups_with_exact_duplicate_rects": sum(
            1 for g in dup_groups if g["duplicate_rects"]),
        "groups_with_harmless_1px_overlap": sum(
            1 for g in dup_groups if not g["duplicate_rects"]),
        "wh_duplicate_mismatches": w_bad,
        "selector_pairs": {"%s" % (k,): v for k, v in sel_pairs.items()},
        "decoder": DECODER_ID,
    }


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

def _pil():
    try:
        from PIL import Image
    except ImportError:  # pragma: no cover
        raise SystemExit("PIL required: pip install pillow")
    return Image


def sheet(name: str, d: bytes, outdir: str, scale: int = 3) -> str:
    """A contact sheet of one file's derived pieces.  Returns the PNG path."""
    Image = _pil()
    from PIL import ImageDraw
    pr = probe(name, d)
    cols = 6
    cell = 72
    groups = []
    for sec in pr["sections"]:
        groups += [(sec, k, raw) for k, raw in enumerate(sec["e_raw"])]
    rows = (len(groups) + cols - 1) // cols
    img = Image.new("RGB", (cols * cell, rows * (cell + 14)), (18, 18, 26))
    dr = ImageDraw.Draw(img)
    for k, (sec, ei, raw) in enumerate(groups):
        r = derive_rect(raw)
        pal = [rgb555(w) for w in (sec.get("palette") or [])]
        blob = r["atlas"]
        bi = blob[0] + (1 if blob[1] == 2 else 0)
        if bi >= len(sec["blobs"]):
            continue
        rows_px = cut(sec["blobs"][bi], r, pal)
        tile = Image.new("RGBA", (r["w"], r["h"]))
        px = tile.load()
        for yy, row in enumerate(rows_px):
            for xx, c in enumerate(row):
                px[xx, yy] = c
        gx, gy = (k % cols) * cell, (k // cols) * (cell + 14)
        img.paste(tile, (gx, gy), tile)
        dr.text((gx + 1, gy + cell - 2),
                "%s e%d %dx%d" % (sec["name"], ei, r["w"], r["h"]),
                fill=(230, 230, 90))
    os.makedirs(outdir, exist_ok=True)
    out = os.path.join(outdir, name.replace(".BIN", "") + "_pieces.png")
    img.resize((img.width * scale, img.height * scale), 0).save(out)
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--file", help="one 04_PLAY basename, e.g. AIL.BIN")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--sheet", metavar="OUTDIR")
    args = ap.parse_args(argv)

    if args.list:
        for r in play_files():
            nm, d = load(r["path"])
            pr = probe(nm, d)
            desc = ", ".join("%s a=%d c=%d blobs=%d" % (s["name"], s["a"], s["c_count"],
                                                        len(s["blobs"]))
                             for s in pr["sections"])
            print("%-12s %7d  %s" % (nm, len(d), desc))
        return 0

    if args.stats:
        print(json.dumps(stats(), indent=1))
        return 0

    if args.sheet:
        for r in play_files():
            nm, d = load(r["path"])
            print(sheet(nm, d, args.sheet))
        return 0

    if args.all or args.json:
        data = {}
        for r in play_files():
            nm, d = load(r["path"])
            data[nm] = pieces(nm, d)
        if args.json:
            with open(args.json, "w") as f:
                json.dump(data, f, indent=1)
            print("wrote %s (%d files, %d pieces)"
                  % (args.json, len(data), sum(len(v) for v in data.values())))
        return 0

    if args.file:
        nm, d = load(args.file)
        pr = probe(nm, d)
        print("%s  %d bytes  slots=%s" % (nm, len(d), [hex(s) for s in pr["slots"]]))
        for sec in pr["sections"]:
            print("  %s @0x%X a=%d c_count=%d d_flags=0x%02X  blobs=%d palette@0x%X"
                  % (sec["name"], sec["sec_off"], sec["a"], sec["c_count"],
                     sec["d_flags"], len(sec["blobs"]), sec.get("palette_off", 0)))
            print("     idx atlas (x,  y)  w  h  tpage  clut   tile")
            for k, raw in enumerate(sec["e_raw"]):
                r = derive_rect(raw)
                print("     %3d %-6s (%3d,%3d) %2d %2d  0x%04X 0x%04X 0x%02X"
                      % (k, "%d,%d" % r["atlas"], r["x"], r["y"], r["w"], r["h"],
                         r["tpage"], r["clut"], r["tile"]))
        return 0

    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
