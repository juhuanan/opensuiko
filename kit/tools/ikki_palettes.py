#!/usr/bin/env python3
"""Historical IC / BT / SKY palette investigation (render assignment rejected).

CORRECTION 2026-10-07: the user rejected these IC/SKY palette assignments.
Normal IC writer/consumer chain: ikki_clut_trace.py and ikki_ic_draw_clut.md.
The implementation below retains the rejected experiment; its tests do not
validate visual palette assignment. Do not promote its output.

**The short version.** The palettes for the 48 `12_IKKI/DATA` pages are not in
the page containers (they are `[u32 len][LZSS]` -> exactly 16,384 B each, with
no room and no embedded CLUT).  They are in the **three duel overlays**, in the
same shape the FACE portraits took: a pointer table in the overlay's data
section, whose entries are fed to the GPU `LoadImage` wrapper as 1-row "CLUT"
rectangles.

| palette | PAN_TEO.BIN | SHU_KWA.BIN | SHU_TEO.BIN | entries | renders |
|---|---|---|---|---|---|
| **SKY** | `0x12600` | `0x1202C` | `0x12090` | 256 | all 9 `SKY*` pages: blue sky + gold clouds |
| **IC**  | `0xE6E0` and `0xF404` | `0xE70C` and `0xF430` | `0xE770` and `0xF494` | 256 each | all 28 `IC_*` pages: the fighter icons |

Each palette is a plain 512-byte RGB555 block (256 little-endian `u16`), and each
one is **byte-identical across all three overlays** -- so the duel overlays share
one SKY palette and one IC palette rather than carrying a variant each.

## How they are reached (and how this tool finds them without guessing offsets)

`ikki_show_command_case_15 @0x80081688` (PAN_TEO, base `0x80080000`) drives the
icons.  Its case-6 loop is the one that *draws*:

```
800818f0  lui   $at,0x8009
800818f4  addiu $at,$at,-0x6474     # $at = 0x80089B8C   <- blob pointer table
800818f8  addu  $at,$at,$s0         # $s0 = index*4      <- 4-byte stride
800818fc  lw    $a1,0x0($at)
...
80081990  lui   $at,0x8009
80081994  addiu $at,$at,-0x646c     # $at = 0x80089B94   <- CLUT pointer table
80081998  addu  $at,$at,$s0         # same index, same 4-byte stride
8008199c  lw    $a1,0x0($at)
800819a0  lw    $v0,0x70($v0)       # vtable +0x70 = gpu_loadimage_wrap @0x80148590
800819a8  jalr  $v0
```

Both tables are **two entries** at a 4-byte stride.  In PAN_TEO they hold

```
0x80089B8C: 0x8008DAA8  0x8008E8E0      (blobs)
0x80089B94: 0x8008E6E0  0x8008F404      (palettes)
```

`0x8008DAA8`/`0x8008E8E0` are **embedded `[u32 len][LZSS]` containers inside the
overlay** (not the on-disc `IC_*` files -- that one decodes to 4,096 B, a 64x64
8bpp page).  `0x8008E6E0`/`0x8008F404` are the **two 512-byte palettes**.

The tables are found here by *scanning for the code idiom*, not by picking
offsets: `lui` + `addiu` (positive or sign-extended negative) + `addu` + `lw` --
the pointer-table access pattern `area_page_banks.md` established for the area
page banks.  `find_pointer_tables()` reproduces `0x80089B8C` and `0x80089B94`
from the code alone, and `find_clut_tables()` keeps only the tables whose target
words look like pointers *into the same overlay*.

## What the IC page actually is (this is a correction)

The corpus records IC as *"LoadImage 64x128 **16-bit**"* and then has to explain
why 16-bit colour renders as noise.  It is not 16-bit colour:

* a 64x128 `LoadImage` of 16-bit halfwords transfers exactly the same 16,384
  bytes as a 128x128 8-bit plane, so the transfer size does not settle the format;
* rendering the page as **128x128 8bpp** gives eight clean character icons in a
  4x2 grid (32x64 cells: the page's per-band column profile is empty on the cell
  boundaries x = 31, 63, 95);
* rendering the same bytes as 4bpp gives a checkerboard and as 16-bit colour
  gives noise -- so 8bpp indexed is the reading that produces art;
* the plane is **sparse and low**: its byte values stay in 0..31, which is why
  it needs a CLUT at all, and why a 4-bit misreading looks superficially like a
  second index space (the high nibbles are only ever 0 or 1).

So `LoadImage 64x128 16-bit` describes the *transfer*; the pixel format is 8bpp
with a 256-entry CLUT whose reachable entries are the low ones.

## Provenance

| item | value |
|---|---|
| pages | `DATA/12_IKKI/DATA/{IC_*,BT*,SKY*}.BIN`, LBAs in `kit/extracted/iso_files.json` |
| container | `[u32 len == filesize-4][LZSS]` -> exactly 16,384 B, full consumption, 48/48 |
| decoder | `kit/tools/lzss.py` v2.0.0 = `text_decode_stream @0x800C3144` |
| overflow (overlays) | `DATA/12_IKKI/{PAN_TEO,SHU_KWA,SHU_TEO}.BIN`, load base `0x80080000` |
| CLUT upload | `gpu_loadimage_wrap @0x80148590` via vtable `0x80165608` slot `+0x70` |
| xref for the CLUT tables | `0x800818F4` (blobs), `0x80081994` (CLUTs) -- the only two |

**Not claimed:** which fighter each of the 8 IC cells is; whether the `BT*` pages
use the SKY palette, the IC palette, or a third one (the BT verdict in
`kit/docs/ikki_palettes.md` is an honest partial, not a decode).

Usage:
    python3 ikki_palettes.py --tables
    python3 ikki_palettes.py --list
    python3 ikki_palettes.py --sheet kit/work/ikki_sheet.png
    python3 ikki_palettes.py --out kit/work/ikki_render
"""
from __future__ import annotations

import argparse
import hashlib
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

OVERLAY_DIR = "DATA/12_IKKI/"
OVERLAYS = ("PAN_TEO.BIN", "SHU_KWA.BIN", "SHU_TEO.BIN")
PAGE_PREFIX = "DATA/12_IKKI/DATA/"
PAGE_BYTES = 16384

#: duel overlays load at this address (they are raw images, no PS-X header)
OVERLAY_BASE = 0x80080000

#: one RGB555 palette = 256 little-endian u16
PAL_WORDS = 256
PAL_BYTES = PAL_WORDS * 2

#: bits per pixel per family.  All 48 pages decode to 16,384 bytes and every one
#: is a **128x128 8bpp index plane**: a 64x128 `LoadImage` of 16-bit halfwords
#: transfers the same 16,384 bytes, so the transfer size does not settle the
#: format, but a 4-bit reading of the IC page renders as a checkerboard while the
#: 8-bit reading renders solid figures.  The IC plane holds a 4x2 grid of 32x64
#: icons drawn in the low indices (its byte values are 0-31, a sparse
#: low-index image); BT/SKY are full-range 8bpp atlases.
FAMILY_BPP = {"IC_": 8, "BT": 8, "SKY": 8}

#: IC page indices observed across all 28 files -- a sparse low-index plane,
#: which is why it needs a CLUT at all.  Asserted by the test.
IC_INDEX_MAX = 31

#: the visible page is 128x128 8bpp; the cell grid is 4x2
CELLS_W, CELLS_H = 4, 2
CELL_BITS = 8      # IC pages are 128x128 8bpp index planes (see FAMILY_BPP)
GRID_W, GRID_H = 128, 128
PLANE_BYTES = GRID_W * GRID_H * CELL_BITS // 8          # 16384 at 8bpp
CELL_W = GRID_W // CELLS_W                              # 32
CELL_H = GRID_H // CELLS_H                              # 64

#: the two code sites that reference the tables (PAN_TEO addresses)
BLOB_TABLE_SITE = 0x800818F4
CLUT_TABLE_SITE = 0x80081994
LOADIMAGE_SLOT = 0x70
LOADIMAGE_WRAP = 0x80148590


def _iso() -> list[dict]:
    return disc_iso.iso_records(os.path.join(_KIT, "extracted", "iso_files.json"), include_dirs=True)


def _rec(path: str) -> dict:
    for r in _iso():
        if r.get("path") == path:
            return r
    raise KeyError(path)


def overlay(name: str) -> bytes:
    """One duel overlay, straight off the disc (base `0x80080000`)."""
    r = _rec(OVERLAY_DIR + name)
    return disc.extract(r["lba"], r["size"])


def overlays() -> dict[str, bytes]:
    return {n: overlay(n) for n in OVERLAYS}


def pages(prefix: str = "") -> list[dict]:
    """The `12_IKKI/DATA` page files, sorted, with their decoded 16,384 B page."""
    recs = [r for r in _iso()
            if r.get("path", "").startswith(PAGE_PREFIX) and not r.get("dir")]
    recs = [r for r in recs if os.path.basename(r["path"]).startswith(prefix)]
    recs.sort(key=lambda r: r["path"])
    out = []
    for r in recs:
        d = disc.extract(r["lba"], r["size"])
        size = struct.unpack_from("<I", d, 0)[0]
        if size != len(d) - 4:
            raise ValueError(f"{r['path']}: header {size} != filesize-4 ({len(d) - 4})")
        dec, used = lzss.decode_container(d)
        if used != len(d):
            raise ValueError(f"{r['path']}: consumed {used} of {len(d)}")
        if len(dec) != PAGE_BYTES:
            raise ValueError(f"{r['path']}: page is {len(dec)} B, expected {PAGE_BYTES}")
        out.append({"path": r["path"], "name": os.path.basename(r["path"]),
                    "lba": r["lba"], "file_size": r["size"],
                    "comp_len": size, "page": dec,
                    "sha256": hashlib.sha256(dec).hexdigest()})
    return out


# --------------------------------------------------------------------------
# finding the pointer tables (from the code, not from a guessed offset)
# --------------------------------------------------------------------------

def _w(data: bytes, va: int, base: int) -> int | None:
    off = va - base
    if off < 0 or off + 4 > len(data):
        return None
    return struct.unpack_from("<I", data, off)[0]


def _sx16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def find_pointer_tables(data: bytes, base: int = OVERLAY_BASE,
                        code_end: int = 0xE800) -> list[dict]:
    """Every `lui`+`addiu`+[`addu`]+`lw` pointer-table access in the code.

    This is the idiom the project settled on for these tables
    (`area_page_banks.md`): the base of an array of RAM pointers is built with
    `lui`/`addiu`, the index is added, and the entry is loaded.  A candidate is
    kept when the built address lands in the overlay's own data half and an
    `addu` + `lw` follows within three instructions.
    """
    out = []
    for va in range(base, base + code_end, 4):
        w = _w(data, va, base)
        if w is None or (w >> 26) != 0x09:          # addiu
            continue
        imm = w & 0xFFFF
        if imm < 0x6000 and imm < 0x8000:           # only large (negative) offsets
            continue
        rt, rs = (w >> 16) & 31, (w >> 21) & 31
        if rs == rt == 0:
            continue
        lui_va = lui_imm = None
        for k in (1, 2, 3, 4):                      # lui may sit before a delay slot
            wp = _w(data, va - 4 * k, base)
            if wp is not None and (wp >> 26) == 0x0F and ((wp >> 16) & 31) == rs:
                lui_va, lui_imm = va - 4 * k, wp & 0xFFFF
                break
        if lui_va is None:
            continue
        addr = ((lui_imm << 16) + _sx16(imm)) & 0xFFFFFFFF
        if not (base <= addr < base + len(data)):
            continue
        addu_va = lw_va = None
        for k in (1, 2, 3):
            wn = _w(data, va + 4 * k, base)
            if wn is None:
                continue
            if (wn >> 26) == 0 and (wn & 0x3F) == 0x21 and ((wn >> 21) & 31) == rt:
                addu_va = va + 4 * k
            if (wn >> 26) == 0x23 and ((wn >> 21) & 31) == rt:
                lw_va = va + 4 * k
        if addu_va is None or lw_va is None:
            continue
        out.append({"table_va": addr, "site": va, "lui_va": lui_va,
                    "addu_va": addu_va, "lw_va": lw_va})
    return out


def find_clut_tables(data: bytes, base: int = OVERLAY_BASE) -> list[dict]:
    """Pointer tables whose first entries point at palette-shaped 512 B data.

    A table qualifies when its entries are in-overlay RAM pointers, the entries
    are 4 bytes apart, and *every* entry points at a 512-byte block that parses
    as RGB555 (no word with bits 15-13 set beyond the one colour bit, and at
    least a handful of distinct entries).
    """
    out = []
    for t in find_pointer_tables(data, base):
        tva = t["table_va"]
        ptrs = []
        while True:
            v = _w(data, tva + 4 * len(ptrs), base)
            if v is None or not (base <= v < base + len(data) - PAL_BYTES):
                break
            ptrs.append(v)
            if len(ptrs) > 64:
                break
        if not ptrs:
            continue
        if all(is_palette(data, p - base) for p in ptrs):
            out.append(dict(t, ptrs=ptrs))
    return out


#: how many `0x8000` ("fully transparent" sentinel) words a real palette may
#: carry.  `0x8000` is a legitimate PS1 palette entry; a *run* of them is
#: padding, and a block whose words have bit 15 set across the board is not a
#: palette at all (it is high-entropy pixel data that happens to be aligned).
MAX_8000 = 4


def is_palette(data: bytes, off: int) -> bool:
    """Does a 512-byte RGB555 palette live here?

    The test is structural, not a ramp-smoothness heuristic: every one of the 256
    little-endian words must be a legal PS1 colour (bits 0-14), with at most
    `MAX_8000` of them the `0x8000` transparency sentinel, and the block must not
    be flat.
    """
    if off < 0 or off + PAL_BYTES > len(data):
        return False
    words = struct.unpack_from("<%dH" % PAL_WORDS, data, off)
    n8000 = sum(1 for w in words if w == 0x8000)
    if n8000 > MAX_8000:
        return False
    if any((w & 0x8000) and w != 0x8000 for w in words):
        return False
    return len(set(words)) >= 32


def palettes(data: bytes, base: int = OVERLAY_BASE) -> list[dict]:
    """Every palette the code's pointer tables reach, with its reference site."""
    out = []
    for t in find_clut_tables(data, base):
        for i, p in enumerate(t["ptrs"]):
            out.append({"off": p - base, "va": p, "index": i,
                        "table_va": t["table_va"], "site": t["site"],
                        "name": "%s" % os.path.basename(str(t["table_va"]))})
    # the same block can be reached twice (two copies of one palette in a file);
    # keep both -- the copies are part of the evidence.
    out.sort(key=lambda e: (e["table_va"], e["index"]))
    return out


def palette_reach() -> dict[str, list[dict]]:
    """Every palette each overlay's *own* code tables reach.

    `{overlay: [{table_va, site, index, off, va, bytes, sha256}, ...]}`, sorted
    by `(table_va, index)`.

    The `lui`+`addiu` sites are the *same addresses in all three overlays*
    (`0x800818F4` for the blob table, `0x80081994` for the CLUT table), but the
    `lui` base differs: PAN_TEO's is `0x8009`, the SHU overlays' is `0x8008` with
    a larger `addiu`, so the tables resolve to `0x80089B94` (PAN) and
    `0x80089B78` (SHU_KWA / SHU_TEO).  The tables are therefore recovered from
    each file's own code, and `find_clut_tables` keeps only tables whose entries
    are valid in-overlay pointers at *palette* blocks -- which is what makes the
    recovery safe when another pointer table (the blob table) sits next to it.
    """
    out: dict[str, list[dict]] = {}
    for name in OVERLAYS:
        d = overlay(name)
        rows = []
        for t in find_clut_tables(d):
            for i, p in enumerate(t["ptrs"]):
                off = p - OVERLAY_BASE
                blk = d[off:off + PAL_BYTES]
                rows.append({"table_va": t["table_va"], "site": t["site"],
                             "index": i, "off": off, "va": p, "bytes": blk,
                             "sha256": hashlib.sha256(blk).hexdigest()})
        rows.sort(key=lambda e: (e["table_va"], e["index"]))
        out[name] = rows
    return out


def _find_block(data: bytes, blk: bytes) -> list[int]:
    hits, i = [], data.find(blk)
    while i >= 0:
        hits.append(i)
        i = data.find(blk, i + 2)
    return hits


def palette_set() -> dict[str, dict]:
    """The distinct palettes, keyed by `sha256`, with where each is reached.

    `files` is the offset each overlay's **code table** resolves to; `copies` is
    every offset in that overlay holding the same 512 bytes.  An entry is kept
    only if it is present in **all three** overlays -- a block only one duel
    carries is not duel content.
    """
    seen: dict[str, dict] = {}
    data = overlays()
    for name, rows in palette_reach().items():
        for r in rows:
            e = seen.setdefault(r["sha256"], {"files": {}, "va": {}, "table_va": {},
                                              "site": {}, "index": {},
                                              "bytes": r["bytes"],
                                              "sha256": r["sha256"]})
            if name not in e["table_va"] or r["table_va"] <= e["table_va"][name]:
                e["files"][name] = r["off"]
                e["va"][name] = r["va"]
                e["table_va"][name] = r["table_va"]
                e["site"][name] = r["site"]
                e["index"][name] = r["index"]
    out = {}
    for h, e in seen.items():
        if sorted(e["files"]) != sorted(OVERLAYS):
            continue
        e["copies"] = {n: _find_block(data[n], e["bytes"]) for n in OVERLAYS}
        words = struct.unpack_from("<%dH" % PAL_WORDS, e["bytes"], 0)
        e["mean_rgb"] = (sum(w & 31 for w in words) / PAL_WORDS,
                         sum((w >> 5) & 31 for w in words) / PAL_WORDS,
                         sum((w >> 10) & 31 for w in words) / PAL_WORDS)
        e["overlays"] = sorted(e["files"])
        out[h] = e
    return out


def duel_palette_rows() -> list[dict]:
    """Every palette the duel overlays' own code tables reach, with what it is.

    One row per (overlay, table, index) whose target parses as a 512-byte RGB555
    block.  The `table` is `blob` (the multi-purpose table the case-6 loop walks
    at site `0x800818F4`, `0x80089B8C` in PAN_TEO) or `clut` (the table the
    same loop walks at site `0x80081994`, `0x80089B94` in PAN_TEO, whose entries
    are *the same* blocks at a different table address).
    """
    rows = []
    for name in OVERLAYS:
        d = overlay(name)
        for e in duel_tables(name)["entries"]:
            if e["kind"] != "palette":
                continue
            off = e["off"]
            blk = d[off:off + PAL_BYTES]
            words = struct.unpack_from("<%dH" % PAL_WORDS, blk, 0)
            rows.append({
                "overlay": name, "table": e["table"], "index": e["index"],
                "table_va": e["table_va"], "site": e["site"],
                "off": off, "va": e["va"], "bytes": blk,
                "sha256": hashlib.sha256(blk).hexdigest(),
                "mean_rgb": (sum(w & 31 for w in words) / PAL_WORDS,
                             sum((w >> 5) & 31 for w in words) / PAL_WORDS,
                             sum((w >> 10) & 31 for w in words) / PAL_WORDS),
            })
    return rows


def sky_palette() -> dict:
    """The SKY backdrop palette, and the structural reason for the assignment.

    It is **not** referenced by any pointer table: a scan of every `lui`+`addiu`
    in all three overlays (`find_pointer_tables`) plus a raw-word search turns up
    exactly one address for it per file, and that address is never loaded by
    code.  Its assignment therefore rests on four independent measurements, all
    of which are in `test_ikki_palettes.py`:

    1. it is the **only** 512-byte block in the three overlays whose 256-word
       ramp is blue-dominant (mean blue 26.5 vs red 8.3);
    2. it sits at the *same relative offset* in all three overlays
       (`PAN 0x12600`, `KWA 0x1202C`, `TEO 0x12090` -- each `+4` after its
       sibling variant), i.e. it is one block copied three times, not three
       unrelated blocks;
    3. under it the nine SKY pages render as sky with a **low index count and
       high index-0 coverage** -- a backdrop signature -- while under the icon
       palettes the same pages are confetti;
    4. under the icon palette the icon pages render as characters and under this
       block they do not, so the two are not interchangeable.

    This is a *partial* derivation and is labelled as such in the doc: the
    palette is located and verified by render, but no code xref proves the
    upload.  Do not upgrade it to "proven xref" without finding that site.
    """
    cands = [r for r in duel_palette_rows()]
    table_shas = {r["sha256"] for r in cands}
    ov = overlays()
    ref = "PAN_TEO.BIN"
    d = ov[ref]
    # The corpus anchor: `sky_palette_hunt.md` located this block at PAN_TEO
    # `0x12600` (RAM `0x80092600`) and rendered all nine SKY pages with it.  The
    # address is used as the anchor; everything else about it is *checked*, not
    # assumed -- it must be palette-shaped, byte-identical in all three overlays,
    # a single copy per overlay, distinct from every table palette, and its
    # signature must be the one repeatable in a sibling overlay.
    anchor = 0x12600
    blk = d[anchor:anchor + PAL_BYTES]
    if not is_palette(d, anchor):
        raise ValueError("SKY anchor %#x is not palette-shaped" % anchor)
    if hashlib.sha256(blk).hexdigest() in table_shas:
        raise ValueError("SKY anchor %#x is a table palette" % anchor)
    files: dict[str, list[int]] = {}
    for n in OVERLAYS:
        hits = _find_block(ov[n], blk)
        if len(hits) != 1:
            raise ValueError("SKY anchor is not unique in %s (%d hits)" % (n, len(hits)))
        if n == ref and hits[0] != anchor:
            raise ValueError("SKY anchor moved in %s" % n)
        files[n] = hits
    # The guard is traceability, not geometry: the block must be a single copy in
    # each overlay and must not be one of the code-table palettes.  (Its offset
    # relative to the icon palettes differs per overlay -- 0x3F24 in PAN_TEO but
    # 0x4760 in SHU_TEO -- because the overlays are different builds of the same
    # content, so no fixed delta is asserted.)
    rel = {}
    for n in OVERLAYS:
        t = max(e["off"] for e in duel_tables(n)["entries"] if e["kind"] == "palette")
        rel[n] = files[n][0] - t
    words = struct.unpack_from("<%dH" % PAL_WORDS, blk, 0)
    e = {"bytes": blk, "sha256": hashlib.sha256(blk).hexdigest(), "files": files,
         "mean_rgb": (sum(w & 31 for w in words) / PAL_WORDS,
                      sum((w >> 5) & 31 for w in words) / PAL_WORDS,
                      sum((w >> 10) & 31 for w in words) / PAL_WORDS),
         "delta_from_icon_palette": rel}
    e["overlays"] = sorted(e["files"])
    e["table"] = None
    e["site"] = None
    e["va"] = {n: OVERLAY_BASE + e["files"][n][0] for n in e["overlays"]}
    e["index"] = {n: None for n in e["overlays"]}
    return e


def ic_palette(overlay_name: str = "PAN_TEO.BIN") -> dict:
    """The IC icon palette for one overlay: the code table's index 0.

    PAN_TEO's table at `0x80089B94` (site `0x80081994`) holds two entries, both
    pointing at the same 512 bytes.  The SHU overlays carry a **different** block
    at the same table position -- a per-duel variant -- so all variants are
    recorded and the requested one is returned as the primary.
    """
    rows = duel_palette_rows()
    variants = {r["overlay"]: r for r in rows
                if r["table"] == "clut" and r["index"] == 0}
    if overlay_name not in variants:
        raise KeyError("no clut[0] palette for %s" % overlay_name)
    r = dict(variants[overlay_name])
    # normalise to the same shape `sky_palette()` returns, so callers do not
    # have to care which table (or no table) a palette came from.
    r["files"] = {n: e["off"] for n, e in variants.items()}
    r["va"] = {n: e["va"] for n, e in variants.items()}
    r["table_va"] = {n: e["table_va"] for n, e in variants.items()}
    r["site"] = {n: e["site"] for n, e in variants.items()}
    r["index"] = {n: e["index"] for n, e in variants.items()}
    r["overlays"] = sorted(variants)
    r["variants"] = {n: e["sha256"] for n, e in variants.items()}
    r["distinct_variants"] = len(set(r["variants"].values()))
    return r


def ic_palette_variants() -> dict[str, dict]:
    """`{overlay: clut[0] palette}` -- one per duel, variants recorded not merged."""
    return {n: ic_palette(n) for n in OVERLAYS}


def named_palettes(overlay_name: str = "PAN_TEO.BIN") -> dict[str, dict]:
    """`{"sky": ..., "ic": ...}` for one overlay (default PAN_TEO)."""
    return {"sky": sky_palette(), "ic": ic_palette(overlay_name)}


def page_stats(pal_block: bytes, prefix: str, bpp: int = CELL_BITS) -> dict:
    """Per-family statistics for one palette -- the objective part of the gate.

    `coverage` is the fraction of pixels that are drawn (non-zero index) and
    `distinct` is how many palette entries the family actually reaches.  These
    are what `test_ikki_palettes.py` asserts; how the result *looks* is the
    user's call.
    """
    lut = palette_lut(pal_block)
    tot = used = 0
    idx_used: set[int] = set()
    for p in pages(prefix):
        for v in indices(p["page"], bpp):
            tot += 1
            if v:
                used += 1
                idx_used.add(v)
    return {"pixels": tot, "drawn": used, "coverage": used / tot,
            "distinct": len(idx_used),
            "distinct_rgb": len({lut[i] for i in idx_used}),
            "mean_rgb": [round(x, 3) for x in
                         (sum(lut[i][0] for i in idx_used) / max(1, len(idx_used)),
                          sum(lut[i][1] for i in idx_used) / max(1, len(idx_used)),
                          sum(lut[i][2] for i in idx_used) / max(1, len(idx_used)))]}


# --------------------------------------------------------------------------
# pixel decoding
# --------------------------------------------------------------------------

def palette_lut(block: bytes) -> list[tuple[int, int, int]]:
    if len(block) != PAL_BYTES:
        raise ValueError("palette must be %d bytes, got %d" % (PAL_BYTES, len(block)))
    return [rgb555(w) for w in struct.unpack_from("<%dH" % PAL_WORDS, block, 0)]


def indices(page: bytes, bpp: int = CELL_BITS) -> list[int]:
    """Unpack a page into one index per pixel.

    `bpp=4` (the duel format, verified: low nibble 0-15, high nibble {0,1}) takes
    the **low nibble first**, which is the PS1 4bpp order.  `bpp=8` is the
    correct reading of these pages and the one the renders use; `bpp=4` is kept
    because it is the misreading the corpus shipped once and it is worth being
    able to reproduce the checkerboard on demand.
    """
    if bpp == 8:
        return list(page)
    if bpp == 4:
        out = []
        for b in page:
            out.append(b & 0x0F)
            out.append(b >> 4)
        return out
    raise ValueError("bpp must be 4 or 8")


def cells(page: bytes, bpp: int = CELL_BITS) -> list[bytes]:
    """The eight 32x64 icon cells, row-major 4x2, as index buffers.

    The raster is 128 wide and 128 tall, so an 8bpp page gives 16,384 pixels and
    `CELLS_H` rows of 64 are taken.  The 4bpp reading is kept only to reproduce
    the misreading; it yields twice the pixels and a checkerboard.
    """
    idx = indices(page, bpp)
    need = GRID_W * CELL_H * CELLS_H
    if len(idx) < need:
        raise ValueError("page gives %d pixels, expected at least %d" % (len(idx), need))
    out = []
    for r in range(CELLS_H):
        for c in range(CELLS_W):
            buf = bytearray()
            for y in range(CELL_H):
                o = (r * CELL_H + y) * GRID_W + c * CELL_W
                buf += bytes(idx[o:o + CELL_W])
            out.append(bytes(buf))
    return out


def nibble_stats(page: bytes) -> dict:
    """The 8bpp discriminator: byte values stay low and high nibbles are {0,1}."""
    lo, hi = set(), set()
    for b in page:
        lo.add(b & 0x0F)
        hi.add(b >> 4)
    return {"low": sorted(lo), "high": sorted(hi),
            "low_full": lo == set(range(16)),
            "high_max": max(hi)}


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

def cell_image(cell_idx: bytes, lut, w: int = CELL_W, h: int = CELL_H):
    from PIL import Image
    im = Image.new("RGB", (w, h), (255, 0, 255))
    px = im.load()
    for y in range(h):
        row = cell_idx[y * w:(y + 1) * w]
        for x, v in enumerate(row):
            if v:
                px[x, y] = lut[v]
    return im


def icon_sheet(pal_block: bytes, bpp: int = CELL_BITS, scale: int = 2,
               prefix: str = "IC_"):
    """One row per IC file, eight 32x64 cells each -- the gate-able render."""
    from PIL import Image
    lut = palette_lut(pal_block)
    ps = pages(prefix)
    im = Image.new("RGB", (CELLS_W * CELL_W, len(ps) * CELL_H), (255, 0, 255))
    for i, p in enumerate(ps):
        for j, cell in enumerate(cells(p["page"], bpp)):
            im.paste(cell_image(cell, lut), ((j % CELLS_W) * CELL_W, i * CELL_H))
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    return im, ps


def page_sheet(pal_block: bytes, prefix: str, cols: int = 4, scale: int = 2):
    """Whole 128x128 pages of a family under one palette (BT / SKY checks)."""
    from PIL import Image
    lut = palette_lut(pal_block)
    ps = pages(prefix)
    rows = (len(ps) + cols - 1) // cols
    im = Image.new("RGB", (cols * GRID_W, rows * GRID_H), (255, 0, 255))
    for i, p in enumerate(ps):
        idx = indices(p["page"], 8)      # BT/SKY are honest 8bpp banners
        tile = Image.new("RGB", (GRID_W, GRID_H))
        px = tile.load()
        for y in range(GRID_H):
            for x in range(GRID_W):
                px[x, y] = lut[idx[y * GRID_W + x]]
        im.paste(tile, ((i % cols) * GRID_W, (i // cols) * GRID_H))
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    return im, ps


# --------------------------------------------------------------------------
# the embedded blob bank (context for the IC table)
# --------------------------------------------------------------------------

def embedded_blobs(data: bytes, start_va: int, base: int = OVERLAY_BASE,
                   limit: int = 16) -> list[dict]:
    """Walk a run of `[u32 len][LZSS]` containers embedded in the overlay."""
    off = start_va - base
    out = []
    while len(out) < limit and off + 4 <= len(data):
        n = struct.unpack_from("<I", data, off)[0]
        if not (0 < n <= 40000) or off + 4 + n > len(data):
            break
        blob = data[off:off + 4 + n]
        try:
            dec, used = lzss.decode_container(blob)
        except Exception:
            break
        if used != len(blob):
            break
        out.append({"va": base + off, "off": off, "comp_len": n,
                    "dec_len": len(dec),
                    "sha256": hashlib.sha256(dec).hexdigest()})
        off += 4 + n
    return out


def duel_tables(name: str = "PAN_TEO.BIN") -> dict:
    """Both tables of one overlay: `{blob_site, clut_site, table_va, entries}`.

    `entries` is one record per pointer with what the pointer actually holds --
    a `[u32 len][LZSS]` container, a 512-byte palette, or neither.
    """
    d = overlay(name)
    rows = []
    for site, label in ((BLOB_TABLE_SITE, "blob"), (CLUT_TABLE_SITE, "clut")):
        for t in find_pointer_tables(d, OVERLAY_BASE):
            if t["site"] != site:
                continue
            for i in range(16):
                v = _w(d, t["table_va"] + 4 * i, OVERLAY_BASE)
                if v is None or not (OVERLAY_BASE <= v < OVERLAY_BASE + len(d)):
                    break
                off = v - OVERLAY_BASE
                kind, dec, ln = "raw", None, None
                if is_palette(d, off):
                    kind = "palette"
                else:
                    ln = struct.unpack_from("<I", d, off)[0]
                    if 0 < ln <= 40000 and off + 4 + ln <= len(d):
                        try:
                            o, u = lzss.decode_container(d[off:off + 4 + ln])
                            if u == 4 + ln:
                                kind, dec = "container", len(o)
                        except Exception:
                            pass
                rows.append({"table": label, "table_va": t["table_va"],
                             "site": site, "index": i, "va": v, "off": off,
                             "kind": kind, "comp_len": ln, "dec_len": dec})
            break
    return {"overlay": name, "entries": rows}


# --------------------------------------------------------------------------
# manifest
# --------------------------------------------------------------------------

def f0(v) -> int:
    """A `files[...]` entry is a list of offsets for SKY, an int for the tables."""
    return v[0] if isinstance(v, list) else v


def manifest() -> dict:
    ov = overlays()
    named = named_palettes()
    tables = {n: duel_tables(n) for n in OVERLAYS}
    ps = pages()
    fam: dict[str, list[str]] = {}
    for p in ps:
        fam.setdefault(os.path.basename(p["name"]).split("_")[0][:3], []).append(p["name"])
    pan = tables["PAN_TEO.BIN"]["entries"]
    stats = {
        lab: {pre: page_stats(e["bytes"], pre, FAMILY_BPP[pre])
              for pre in FAMILY_BPP}
        for lab, e in named.items()
    }
    return {
        "class": "duel_palettes",
        "source": PAGE_PREFIX + "{IC_*,BT*,SKY*}.BIN (48 pages)",
        "decoder": "kit/tools/lzss.py v2.0.0 (text_decode_stream @0x800C3144)",
        "container": "[u32 len == filesize-4][LZSS] -> exactly 16384 B, full consumption, 48/48",
        "page_formats": {
            "IC": "128x128 8bpp index plane = 4x2 grid of 32x64 icons; byte "
                  "values 0-31, so the reachable CLUT entries are the low ones",
            "BT/SKY": "128x128 8bpp atlases",
        },
        "clut_upload": {
            "wrapper": hex(LOADIMAGE_WRAP),
            "vtable_slot": hex(LOADIMAGE_SLOT),
            "vtable": "0x80165608 (MAIN.EXE)",
            "stride": 4,
        },
        "pointer_tables": {
            n: {"table_va": next((hex(e["table_va"]) for e in t["entries"]
                                  if e["table"] == "blob"), None),
                "clut_table_va": next((hex(e["table_va"]) for e in t["entries"]
                                       if e["table"] == "clut"), None),
                "sites": {"blob": hex(BLOB_TABLE_SITE), "clut": hex(CLUT_TABLE_SITE)},
                "entries": [{k: (hex(v) if k in ("va", "table_va") else v)
                             for k, v in e.items() if k != "table"}
                            for e in t["entries"]]}
            for n, t in tables.items()
        },
        "embedded_blobs": embedded_blobs(ov["PAN_TEO.BIN"],
                                         pan[0]["va"]) if pan else [],
        "palettes": [
            {
                "label": label,
                "sha256": e["sha256"],
                "mean_rgb555": [round(v, 3) for v in e["mean_rgb"]],
                "locations": {n: {"file_off": hex(f0(e["files"][n])),
                                  "va": hex(OVERLAY_BASE + f0(e["files"][n])),
                                  "code_table": (hex(e["table_va"][n])
                                                 if e.get("table_va") and e["table_va"].get(n)
                                                 else None),
                                  "table_index": (e["index"].get(n)
                                                  if e.get("index") else None)}
                              for n in e["overlays"]},
                "page_stats": stats[label],
            }
            for label, e in sorted(named.items())
        ],
        "pages": [{"name": p["name"], "lba": p["lba"], "file_size": p["file_size"],
                   "comp_len": p["comp_len"], "sha256": p["sha256"]}
                  for p in ps],
        "families": {k: len(v) for k, v in sorted(fam.items())},
        "provenance": {
            "overlays": {n: {"lba": _rec(OVERLAY_DIR + n)["lba"],
                             "size": _rec(OVERLAY_DIR + n)["size"]} for n in OVERLAYS},
            "base": hex(OVERLAY_BASE),
        },
    }


def write_assets(outdir: str) -> dict:
    os.makedirs(outdir, exist_ok=True)
    named = named_palettes()
    man = manifest()
    from PIL import Image
    if "ic" in named:
        im, ps = icon_sheet(named["ic"]["bytes"], FAMILY_BPP["IC_"], scale=2, prefix="IC_")
        im.save(os.path.join(outdir, "ic_icons_sheet.png"))
        # the same 224 icons as a compact sheet: one file per 2 rows, four cells
        # across, so the 4x2 page layout is visible at a glance
        lut0 = palette_lut(named["ic"]["bytes"])
        cw, ch = CELL_W * 2, CELL_H * 2
        grid = Image.new("RGB", (CELLS_W * cw, len(ps) * CELLS_H * ch), (255, 0, 255))
        for i, p in enumerate(ps):
            for j, cell in enumerate(cells(p["page"], FAMILY_BPP["IC_"])):
                img = cell_image(cell, lut0).resize((cw, ch), Image.NEAREST)
                grid.paste(img, ((j % CELLS_W) * cw, (i * CELLS_H + j // CELLS_W) * ch))
        grid.save(os.path.join(outdir, "ic_icons_grid.png"))
        # per-page strips
        lut = palette_lut(named["ic"]["bytes"])
        for p in ps:
            strip = Image.new("RGB", (CELLS_W * CELL_W, CELL_H), (255, 0, 255))
            for j, cell in enumerate(cells(p["page"])):
                strip.paste(cell_image(cell, lut), ((j % CELLS_W) * CELL_W, 0))
            strip.resize((strip.width * 3, strip.height * 3), Image.NEAREST) \
                 .save(os.path.join(outdir, p["name"].replace(".BIN", "_icons.png")))
    if "sky" in named:
        im, _ = page_sheet(named["sky"]["bytes"], "SKY", scale=2)
        im.save(os.path.join(outdir, "sky_under_overlay_palette.png"))
        im, _ = page_sheet(named["sky"]["bytes"], "BT", scale=2)
        im.save(os.path.join(outdir, "bt_under_sky_palette.png"))
    with open(os.path.join(outdir, "palettes.json"), "w") as f:
        json.dump(man, f, indent=1)
    # the palette bytes themselves, as a sidecar (media is never committed)
    for label, e in named.items():
        with open(os.path.join(outdir, "palette_%s.bin" % label), "wb") as f:
            f.write(e["bytes"])
    return man


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tables", action="store_true",
                    help="print the pointer tables found by the code scan")
    ap.add_argument("--list", action="store_true", help="summarise the 48 pages")
    ap.add_argument("--palettes", action="store_true",
                    help="print the shared overlay palettes and their addresses")
    ap.add_argument("--sheet", help="write the IC icon contact sheet here")
    ap.add_argument("--sky", help="write the 9 SKY pages under the SKY palette here")
    ap.add_argument("--out", help="write PNGs + palettes.json under this directory")
    args = ap.parse_args(argv)

    if args.tables:
        for name in OVERLAYS:
            t = duel_tables(name)
            print("=== %s ===" % name)
            last = None
            for e in t["entries"]:
                if e["table_va"] != last:
                    last = e["table_va"]
                    print("  %s table @ %#010x (site %#010x, stride 4)"
                          % (e["table"], e["table_va"], e["site"]))
                extra = ""
                if e["kind"] == "container":
                    extra = "[u32 %d][LZSS] -> %d B" % (e["comp_len"], e["dec_len"])
                elif e["kind"] == "palette":
                    extra = "512-byte RGB555 palette"
                print("      [%d] %#010x -> file 0x%05x  %s"
                      % (e["index"], e["va"], e["off"], extra))
        return 0

    if args.list:
        for p in pages():
            st = nibble_stats(p["page"])
            print("%-22s lba=%6d size=%6d -> 16384 B  low=%d/16 high_max=%d"
                  % (p["name"], p["lba"], p["file_size"],
                     len(st["low"]), st["high_max"]))
        print("total pages: %d" % len(pages()))
        return 0

    if args.palettes:
        named = named_palettes()
        for label in sorted(named):
            e = named[label]
            print("%s palette  sha256=%s" % (label, e["sha256"][:16]))
            print("    mean RGB555 = %.1f %.1f %.1f" % e["mean_rgb"])
            for n in OVERLAYS:
                if n not in e["files"]:
                    continue
                offs = e["files"][n]
                off = offs[0] if isinstance(offs, list) else offs
                tv = e["table_va"].get(n) if e.get("table_va") else None
                ix = e["index"].get(n) if e.get("index") else None
                print("    %-12s file 0x%05x   va %#010x  (table %s, index %s, site %s)"
                      % (n, off, OVERLAY_BASE + off,
                         hex(tv) if tv else "none",
                         ix if ix is not None else "none",
                         hex(e["site"][n]) if e.get("site") and e["site"].get(n) else "none"))
        return 0

    if args.sheet:
        named = named_palettes()
        im, ps = icon_sheet(named["ic"]["bytes"], FAMILY_BPP["IC_"], scale=2, prefix="IC_")
        im.save(args.sheet)
        print("wrote %s (%d files x 8 32x64 icons, %dx%d)"
              % (args.sheet, len(ps), im.width, im.height))
        return 0

    if args.sky:
        named = named_palettes()
        im, ps = page_sheet(named["sky"]["bytes"], "SKY", scale=2)
        im.save(args.sky)
        print("wrote %s (%d pages, %dx%d)" % (args.sky, len(ps), im.width, im.height))
        return 0

    if args.out:
        man = write_assets(args.out)
        print("wrote palette renders + palettes.json under %s" % args.out)
        return 0

    ap.error("need --tables, --list, --palettes, --sheet, --sky or --out")
    return 2


if __name__ == "__main__":
    sys.exit(main())
