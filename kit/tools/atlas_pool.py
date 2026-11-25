#!/usr/bin/env python3
"""Every 128x128 8-bit sprite/tile atlas on the disc — the unread pool.

WHY
---
`overlay_sprites.py` reads the *04_PLAY-format containers* (113 of them, 339
atlases). That is not where most of the disc's 128x128 atlases live. A raw scan
for `[u32 len][LZSS]` streams that decode to exactly 16,384 bytes finds:

    **3,582 atlases across 339 files**, of which only 339 are inside a
    04_PLAY-format container. The other ~3,240 sit directly in the area
    overlays (`DATA/*_AREA.*/V*.BIN`), the `*_DATA.BIN` tables, `BATTLE.BIN`,
    `SLUS_002.92` and the `16_WAR` maps.

`area_scene.py` reads only the handful of contexts a *room* references, so the
great majority of this art has never been rendered. This tool renders it.

CLASSIFICATION
--------------
A 16x16-tile page fills its 128x128 plane; an isolated sprite sheet does not.
Measured index-0 fraction separates them cleanly:

    sprite-like   index-0 fraction > 0.40   2,038 atlases
    mid           0.05 .. 0.40                714
    tile-like     < 0.05                      830

The threshold is a heuristic and is reported per atlas, not asserted.

PROVENANCE
----------
DISC-DERIVED index planes: `lzss.decode_strict` output only. The **palette is
not** resolved for pool atlases (it lives in the overlay's per-context CLUT
table, which this tool does not yet pair up), so sheets are palette-free
greyscale index renders — enough to identify shapes, not to publish art.
`--oracle-clut` adds an identification-only colour view from the existing VRAM
capture, banner-flagged and never promotable.

COLOUR MODE (2026-10-05)
------------------------
`--colour` resolves a palette per atlas **only where a table in the atlas's own
source file references it**, and reports every atlas it cannot resolve as
unresolved. Two independent table routes are used (see
`kit/docs/atlas_pool_colour.md`):

* **area_scene route** — for a file whose header parses as an area overlay
  (`area_scene.root`/`section_table`), a section is `[+4] atlas count,
  [+5] palette count, [+8] atlas table, [+0xc] CLUT table, [+0x10] per-atlas
  64-byte palette selector, [+0x14] tilemap`. Atlas slot `i` is paired with
  palette `selector[code % 64]` for every tile code in the section's maps whose
  `code // 64 == i`. Candidate contexts (`[+4] atlas count`, `[+8]`/`[+0xc]`
  tables) are resolved the same way when `[+5] < 0x40`. The pairing is then
  re-derived as **VRAM evidence** with `area_scene`'s own upload geometry
  (`atlas_slot_geometry`, `PALETTE_Y0`): the 16,384 atlas bytes are looked up in
  a `psx_vram.PsxVram` built from the section, and the 512 palette bytes must be
  at the row those rules give.
* **play-family route** — a 24-byte sprite section header (`+4` c count,
  `+5` flags `& 0xc0 == 0x80`, `+6` in {0, 0x1e}, `+8`/`+0xc`/`+0x10`/`+0x14`
  absolute pointers to c/d/e/f tables) as found in `BATTLE.BIN`,
  `DATA/*/*_DATA.BIN` and the character archives. Atlas entry `k` is paired with
  d-entry `k` (`enemy_sprites.py` §2: "the palette pairs index-for-index with the
  atlas"); when the d-table has a single entry, every atlas of the section takes
  it.

A wrong colour is worse than a stated unknown, so an atlas with no referencing
table stays greyscale, `palette: null`, and is counted in
`resolution.unresolved_atlases`. When two routes disagree, or one route yields
several distinct palettes, **all** candidates are recorded and the sheet is
flagged (yellow border / `*` in the caption); the atlas is only counted resolved
once, in `resolution.ambiguous_atlases`.

Usage:
    atlas_pool.py --out DIR [--files GLOB] [--class sprite|mid|tile|all]
    atlas_pool.py --render --colour --class all --out DIR
Exit: 0 clean, 1 on a structural problem.
"""

from __future__ import annotations

import argparse
import datetime
import glob as globmod
import hashlib
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import disc  # noqa: E402
import lzss  # noqa: E402

try:
    import numpy as np
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.exit("numpy + PIL required")

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ISO_JSON = os.path.join(_KIT, "extracted", "iso_files.json")
_ORACLE_VRAM = os.path.join(_KIT, "work", "vram_raw.bin")

ATLAS = 16384
W = H = 128
MAX_LEN = 20000          # every observed atlas stream is far below this
SPRITE_ZERO_FRAC = 0.40
TILE_ZERO_FRAC = 0.05
DECODER_ID = "kit/tools/lzss.py v2.0.0"

# --- colour resolution (2026-10-05) ---------------------------------------
RAM_BASE = 0x80010000        # area overlays: absolute file pointers
PLAY_BASE = 0x80080000       # X_DATA.BIN / per-area sprite sections
PLAY_BASE_B = 0x800A0000     # BATTLE.BIN
MAX_ATLAS_PER_TABLE = 64     # same bound area_scene uses
MAX_PLAY_C = 8               # 04_PLAY-family c-table entries (enemy_sprites MAX_C)
PLAY_D_FLAGS = 0x80          # d_flags bit 7: 32-colour CLUT branch
AREA_CTX_32 = 0x40           # area ctx+5 >= this: the 32-colour NPC descriptor,
                             # not a palette count (area_scene.load_scene_materials)
PALETTE_WORDS_32 = 32
PALETTE_BYTES_256 = 512
ATLAS_BYTES_PER_ROW = 2048   # one 128x128 8-bit atlas = 2048 VRAM bytes/row
RESOLUTION_RULE = ("tables referencing the atlas in its own source file: "
                   "area section/context selector tables (VRAM-verified) or "
                   "play-family c/d index pairing")


def disc_files(paths=None):
    with open(_ISO_JSON) as f:
        files = [r for r in json.load(f) if not r.get("dir")]
    out = []
    for r in files:
        p = r["path"]
        if p.endswith(".8") or p.endswith(".STR") or p.endswith(".str"):
            continue
        if r["size"] < 128:
            continue
        if paths and not any(globmod.fnmatch.fnmatch(p, g) for g in paths):
            continue
        out.append(r)
    return out


def find_atlases(data):
    """Every `[u32 len][LZSS]` in `data` decoding to exactly 16,384 bytes."""
    n = len(data)
    m = (n // 4) * 4
    if m < 128:
        return []
    u = np.frombuffer(data[:m], dtype="<u4")
    cand = np.nonzero((u >= 64) & (u <= MAX_LEN))[0]
    found = []
    for i in cand:
        off = int(i) * 4
        ln = int(u[i])
        if off + 4 + ln > n:
            continue
        try:
            raw = lzss.decode_strict(data[off + 4:off + 4 + ln])
        except lzss.LZSSError:
            continue
        if len(raw) != ATLAS:
            continue
        found.append((off, ln, raw))
    return found


def classify(raw):
    a = np.frombuffer(raw, dtype=np.uint8)
    zero = float((a == 0).mean())
    cls = ("sprite-like" if zero > SPRITE_ZERO_FRAC
           else "tile-like" if zero < TILE_ZERO_FRAC else "mid")
    return cls, zero, int(len(np.unique(a)))


def scan(paths=None, verbose=True):
    """Walk the disc once. Returns (records, sources) keyed by atlas sha1."""
    records, sources = {}, {}
    for r in disc_files(paths):
        data = disc.extract(r["lba"], r["size"])
        for off, ln, raw in find_atlases(data):
            h = hashlib.sha1(raw).hexdigest()
            sources.setdefault(h, []).append({"file": r["path"], "offset": off})
            if h not in records:
                cls, zero, distinct = classify(raw)
                records[h] = {"sha1": h, "bytes": raw, "compressed_len": ln,
                              "class": cls, "zero_fraction": round(zero, 4),
                              "distinct_indices": distinct,
                              "first_file": r["path"], "first_offset": off}
        if verbose:
            print("  scanned %-46s %8d B" % (r["path"], r["size"]), flush=True)
    return records, sources


def index_image(raw):
    a = np.frombuffer(raw, dtype=np.uint8).reshape(H, W)
    return Image.fromarray(a, mode="L").convert("RGB")


# ---------------------------------------------------------------------------
# Colour resolution (2026-10-05): pair pool atlases with their CLUTs
#
# The pairing rule, in one sentence: *an atlas is paired with a palette only
# when a table in the atlas's own source file names both, and the palette's
# bytes are found where the modelled upload geometry puts them.* Everything
# else stays unresolved and is counted as such.
# ---------------------------------------------------------------------------

def _rel(ptr, n, bases=(RAM_BASE, PLAY_BASE, PLAY_BASE_B)):
    """Absolute on-disc pointer -> file offset, or None.

    The three load bases are the ones the corpus has established: area
    overlays load at 0x80010000, per-area asset overlays at 0x80080000
    (`enemy_sprites.py`), BATTLE.BIN at 0x800AA000 (`battle_bin_decode`).

    The FULL `lui`+imm value is what matters and no truncation is applied
    (`0x8016F2A7` from `lui 0x8018` + `-0xD59` is 0x15F2A7 as an area address,
    never 0x17F2A7). The bases overlap once a value is formed, so they are tried
    in order and the first whose offset lands inside the file is taken; a value
    that fits no base -- including one that would land past the end -- is None.
    Returning None rather than a guess is what keeps a bad pointer from being
    paired with a palette.
    """
    for b in bases:
        off = ptr - b
        if 0 <= off < n:
            return off
    return None


# 04_PLAY-family table-pointer origins, tried in order. `None` = absolute (the
# `X_DATA.BIN`/`BATTLE.BIN` form); 0 = relative to the container start (the
# 04_PLAY and embedded-container form: "every pointer inside a container is
# relative to the container start", `overlay_sprite_containers.md` §1).
POINTER_ORIGINS = (None, 0)


def _at(ptr, n, origin):
    """A 04_PLAY-family table pointer under an explicit origin -> file offset.

    `origin is None` means the stored value is already a RAM address and defers
    to `_rel`. `origin == 0` means it is relative to the container start, i.e.
    already a file offset, and is bounds-checked against `n` but deliberately
    NOT fed through the absolute bases -- a small relative offset such as 0x81c
    must not be read as 0x8000081c. A wrong origin cannot pair anything, because
    every declared c/d entry must still decode under the caller's gates.
    """
    if origin is None:
        return _rel(ptr, n)
    return ptr if 0 <= ptr < n else None


def _decode_blob(d, off, n):
    """`[u32 len][LZSS]` at file offset `off` -> 16,384 bytes, else None."""
    if off is None or off < 0 or off + 4 > n:
        return None
    ln = struct.unpack_from("<I", d, off)[0]
    if not (0 < ln <= MAX_LEN) or off + 4 + ln > n:
        return None
    try:
        raw = lzss.decode_strict(d[off + 4:off + 4 + ln])
    except lzss.LZSSError:
        return None
    return raw if len(raw) == ATLAS else None


def _pal256(d, off, n):
    """512-byte 256-colour CLUT at `off` -> 256 RGB555 words, else None."""
    if off is None or off < 0 or off + PALETTE_BYTES_256 > n:
        return None
    return list(struct.unpack_from("<256H", d, off))


def _pal32(d, off, n):
    """64-byte 32-colour CLUT at `off` -> 32 RGB555 words, else None."""
    if off is None or off < 0 or off + 2 * PALETTE_WORDS_32 > n:
        return None
    return list(struct.unpack_from("<%dH" % PALETTE_WORDS_32, d, off))


def _selector_usage(d, sec, n, dtab):
    """bim -> [(palette_index, palette_offset)] actually selected for atlas slot i.

    Two independent structural gates, both cheap and both strong:

      * a tile code only counts when `code // 64` is inside the section's
        declared atlas count (the same bound `area_tile_materials` enforces);
      * the palette index is only accepted when it is inside the declared
        palette count AND its d-entry is a readable 512-byte palette.

    A slot whose codes survive both gates is *used*, and the selector byte for
    that code names the palette. An unused slot gets no palette, which is the
    honest answer: the file never says which one it would be.
    """
    cnt, palc = d[sec + 4], d[sec + 5]
    etab = _rel(_u32(d, sec + 0x10), n)
    if cnt < 1 or cnt > MAX_ATLAS_PER_TABLE or palc < 1 or etab is None:
        return {}
    w, h = _u16(d, sec), _u16(d, sec + 2)
    codes = set()
    pm = _rel(_u32(d, sec + 0x14), n)
    if pm is not None and 0 < w <= 256 and 0 < h <= 256 and pm + 2 * w * h <= n:
        codes |= set(struct.unpack_from("<%dH" % (w * h), d, pm))
    sm = _rel(_u32(d, sec + 0x18), n)
    if sm is not None and 0 < w <= 256 and 0 < h <= 256 and sm + 2 * w * h <= n:
        codes |= set(struct.unpack_from("<%dH" % (w * h), d, sm))
    usage = {}
    for code in sorted(codes):
        bi, si = divmod(code, 64)
        if bi >= cnt:
            continue
        eo = _rel(_u32(d, etab + 4 * bi), n)
        if eo is None or eo + 64 > n:
            continue
        pi = d[eo + si]
        if pi >= palc:
            continue
        po = _rel(_u32(d, dtab + 4 * pi), n)
        if _pal256(d, po, n) is None:
            continue
        usage.setdefault(bi, []).append((pi, po))
    return usage


def area_scene_candidates(d, n, atlas_offsets):
    """{stream offset: [candidate]} from an area overlay's section/context tables.

    `atlas_offsets` is the set of `[u32 len]` offsets the pool found in this
    file, so only atlases the pool actually recorded are resolved. Candidates
    are collected (not chosen) because one atlas can legitimately appear in
    several sections with different palettes.
    """
    import area_scene as scene
    if scene.root(d) is None or scene.section_table(d) is None:
        return {}
    out = {}

    def add(bo, pal_words, pal_off, source, section, slot, label,
            pal_base=None):
        if bo not in atlas_offsets or pal_off is None:
            return
        out.setdefault(bo, []).append({
            "source": source,
            "section_offset": section if source == "area_section" else None,
            "context_offset": section if source == "area_context" else None,
            "atlas_slot": slot,
            "palette_index": label,
            "palette_base": pal_base,
            "palette_offset": pal_off,
            "palette_words": pal_words,
        })

    for i in range(64):
        so = scene.section_off(d, i)
        # 0x18 is read as the secondary-map pointer, so the section
        # header must actually hold 0x1c bytes; a header flush with the
        # end of the file is skipped rather than read past (struct.error).
        if so is None or not scene.in_file(d, so, 0x1C):
            continue
        cnt, palc = d[so + 4], d[so + 5]
        if not (1 <= cnt <= MAX_ATLAS_PER_TABLE) or palc < 1:
            continue
        ctab = _rel(_u32(d, so + 8), n)
        dtab = _rel(_u32(d, so + 0xC), n)
        if ctab is None or dtab is None:
            continue
        usage = _selector_usage(d, so, n, dtab)
        for bi, uses in usage.items():
            bo = _rel(_u32(d, ctab + 4 * bi), n)
            if bo is None:
                continue
            for pi, po in uses:
                add(bo, _pal256(d, po, n), po, "area_section", so, bi, pi,
                    pal_base=palc)
        # Contexts: the same shape one level down. `[+5] >= 0x40` is the
        # 32-colour NPC branch, where `[+5]` is a descriptor rather than a
        # count (area_scene.load_scene_materials documents this); it is not
        # iterated here, so no palette is guessed for that branch.
        for c in scene.contexts(d, so):
            coff = c.get("offset")
            if coff is None or not scene.in_file(d, coff, 0x10):
                continue
            nctx, pc = d[coff + 4], d[coff + 5]
            if not (1 <= nctx <= MAX_ATLAS_PER_TABLE) or not (1 <= pc < AREA_CTX_32):
                continue
            atab = _rel(_u32(d, coff + 8), n)
            ptab = _rel(_u32(d, coff + 0xC), n)
            if atab is None or ptab is None:
                continue
            for k in range(nctx):
                bo = _rel(_u32(d, atab + 4 * k), n)
                po = _rel(_u32(d, ptab + 4 * k), n)
                words = _pal256(d, po, n)
                if bo is not None and words is not None:
                    add(bo, words, po, "area_context", coff, k, k, pal_base=pc)

    return out


def play_family_candidates(d, n, atlas_offsets):
    """{stream offset: [candidate]} from 04_PLAY-family 24-byte section headers.

    Header shape (established for 04_PLAY, re-proven for BATTLE.BIN and the
    `X_DATA.BIN` sprite sections; `enemy_sprites.py` §2):

        +0x04 u8  c_count     1..8
        +0x05 u8  d_flags     bit 7 set -> the 32-colour CLUT branch
        +0x06 u16             0 or 0x001e
        +0x08 u32 c_table     -> c_count pointers to [u32 len][LZSS] atlases
        +0x0C u32 d_table     -> (d_flags & 0x3f) pointers to 32-word palettes
        +0x10 u32 e_table     -- accepted as a span only (never parsed here)
        +0x14 u32 f_table     -- accepted as a span only

    A header is accepted only when every c-entry and every d-entry it declares
    is readable; that is what keeps the sweep from pairing a palette with a
    coincidence. The atlas -> palette rule is index-for-index (`c[k]` with
    `d[k]`), with a single-entry d-table shared by the whole section.

    Table pointers are stored **relative to the container start** in 04_PLAY and
    in the copies embedded in overlays ("every pointer inside a container is
    relative to the container start", `overlay_sprite_containers.md`
    §1), and **absolute** in the `X_DATA.BIN` / `BATTLE.BIN` sections. Both
    forms are tried; the absolute form first, and each must satisfy every gate
    above, so a wrong base cannot pair anything.
    """
    out = {}
    for origin in POINTER_ORIGINS:
        for h in range(0, n - 0x18, 4):
            cc, fl = d[h + 4], d[h + 5]
            if not (1 <= cc <= MAX_PLAY_C) or (fl & 0xC0) != PLAY_D_FLAGS:
                continue
            if struct.unpack_from("<H", d, h + 6)[0] not in (0, 0x1E):
                continue
            dc = fl & 0x3F
            if dc < 1:
                continue
            ctab = _at(_u32(d, h + 8), n, origin)
            dtab = _at(_u32(d, h + 0xC), n, origin)
            if ctab is None or dtab is None or ctab + 4 * cc > n or dtab + 4 * dc > n:
                continue
            blobs, ok = [], True
            for k in range(cc):
                bo = _at(_u32(d, ctab + 4 * k), n, origin)
                raw = _decode_blob(d, bo, n)
                if raw is None:
                    ok = False
                    break
                blobs.append((bo, raw))
            if not ok:
                continue
            pals, ok = [], True
            for k in range(dc):
                po = _at(_u32(d, dtab + 4 * k), n, origin)
                words = _pal32(d, po, n)
                if words is None:
                    ok = False
                    break
                pals.append((po, words))
            if not ok:
                continue
            for k, (bo, raw) in enumerate(blobs):
                if bo not in atlas_offsets:
                    continue
                po, words = pals[k if k < len(pals) else 0]
                out.setdefault(bo, []).append({
                    "source": "play_family",
                    "header_offset": h,
                    "atlas_index": k,
                    "d_count": dc,
                    "d_flags": fl,
                    "pointer_origin": origin,
                    "palette_index": k,
                    "palette_offset": po,
                    "palette_words": words,
                    "shared_d_table": len(pals) == 1,
                })
        if out:
            break      # the first origin that yields anything is this file's form
    return out


def merge_candidates(cand_lists):
    """Deduplicate candidates by (palette bytes) and rank them.

    Ordering is explicit rather than incidental: an area-section palette that
    the engine's selector uses outranks a play-family pairing, which outranks
    an area-context palette. Within a rank, the lowest palette offset wins.
    Every distinct palette is kept so the manifest can state the ambiguity.
    """
    rank = {"area_section": 0, "play_family": 1, "area_context": 2}
    by_words, out = {}, []
    for c in cand_lists:
        key = tuple(c["palette_words"])
        if key in by_words:
            continue
        by_words[key] = True
        out.append(c)
    out.sort(key=lambda c: (rank.get(c["source"], 9), c.get("palette_offset") or 0))
    return out


def vram_evidence(d, n, sec, bo, words, atlas_base=None, palette_base=None,
                  palette_index=None):
    """Re-derive the pairing from VRAM with `area_scene`'s own upload rules.

    A `PsxVram` is built from this section exactly as
    `area_scene.load_scene_materials` builds it (atlas slots from
    `atlas_slot_geometry(atlas_base + i)`, palettes at `PALETTE_Y0 + base + i`),
    then two byte-exact comparisons are made:

      * `atlas_in_slot` — the 16,384 atlas bytes are resident in VRAM;
      * `palette_row` — the 512 palette bytes of the *actual* uploaded palette
        row are byte-identical to the candidate, i.e. the candidate is a real
        palette of this section (not merely a plausible one), and
        `palette_row_is_derived_row` states whether it also sits on the row the
        header's own base value derives.

    Returns None when the evidence cannot be built (a table fails to decode, or
    `find_atlas` floods); a returned False means the candidate is wrong and the
    caller must not claim it.
    """
    try:
        import area_scene as scene
        from psx_vram import PsxVram, find_atlas
    except ImportError:                               # pragma: no cover
        return None
    if sec is None or not scene.in_file(d, sec, 0x1C):
        return None
    cnt, palc = d[sec + 4], d[sec + 5]
    if not (1 <= cnt <= MAX_ATLAS_PER_TABLE) or palc < 1:
        return None
    ctab = _rel(_u32(d, sec + 8), n)
    dtab = _rel(_u32(d, sec + 0xC), n)
    if ctab is None or dtab is None:
        return None
    s_atlas_base, s_pal_base = scene.context_upload_bases(d, sec)
    atlas_base = s_atlas_base if atlas_base is None else atlas_base
    palette_base = s_pal_base if palette_base is None else palette_base
    vram = PsxVram()
    slot, raw = None, None
    for k in range(cnt):
        o = _rel(_u32(d, ctab + 4 * k), n)
        r = _decode_blob(d, o, n)
        if r is None:
            return None
        gx, gy, _fold = scene.atlas_slot_geometry(atlas_base + k)
        vram.upload_rect(gx, gy, scene.ATLAS_SLOT_W, scene.ATLAS_SLOT_H, r)
        if o == bo:
            slot, raw = atlas_base + k, r
    if raw is None:
        return None
    # Upload the section's own palette bank the way the loader does, so the
    # rows compared below hold what the engine would have put there.
    declared_rows = {}
    for i in range(palc):
        po = _rel(_u32(d, dtab + 4 * i), n)
        pal = _pal256(d, po, n)
        if pal is None:
            continue
        row = scene.PALETTE_Y0 + ((palette_base + i) & 0xFF)
        if row >= 512:
            continue
        vram.upload_rect(0, row, 256, 1, struct.pack("<256H", *pal))
        declared_rows[row] = i
    try:
        hits = find_atlas(vram, raw)
    except Exception:                                 # pragma: no cover
        return None
    gx, gy, _fold = scene.atlas_slot_geometry(slot)
    want = struct.pack("<256H", *words)
    rows = []
    for row in sorted(declared_rows):
        got = b"".join(struct.pack("<H", vram.get_word(x, row))
                       for x in range(256))
        if got == want:
            rows.append({"palette_index": declared_rows[row], "row": row})
    derived = (None if palette_index is None else
               scene.PALETTE_Y0 + ((palette_base + palette_index) & 0xFF))
    return {"atlas_in_slot": (gx, gy) in hits,
            "slot_geometry": [gx, gy],
            "slot": slot,
            "rows_matching_candidate": rows,
            "derived_row": derived,
            "derived_row_matches": any(r["row"] == derived for r in rows),
            "palette_row_matches": bool(rows)}


def resolve_file_atlases(path, lba, size, atlas_offsets, verify_vram=True,
                         data=None):
    """Resolve every pool atlas in one source file. Returns {offset: record}.

    `atlas_offsets` maps `[u32 len]` offset -> sha1 for the atlases the pool
    recorded in this file, so a table can only ever resolve an atlas that is
    really there. All candidates for an offset are merged; the record names one
    `primary` palette and lists every distinct alternative, and the atlas is
    only marked `ambiguous` when those alternatives disagree.

    `data` may be supplied by a caller that has already extracted the file
    (the render path does), which avoids a second disc read.
    """
    if data is None:
        data = disc.extract(lba, size)
    n = len(data)
    want = set(atlas_offsets)
    cands = {}
    for src in (area_scene_candidates(data, n, want),
                play_family_candidates(data, n, want)):
        for bo, lst in src.items():
            cands.setdefault(bo, []).extend(lst)
    out = {}
    for bo, lst in cands.items():
        merged = merge_candidates(lst)
        if not merged:
            continue
        primary = merged[0]
        rec = {
            "palette_offset": primary["palette_offset"],
            "palette_words": primary["palette_words"],
            "source": primary["source"],
            "palette_index": primary["palette_index"],
            "section_offset": primary.get("section_offset"),
            "context_offset": primary.get("context_offset"),
            "header_offset": primary.get("header_offset"),
            "atlas_slot": primary.get("atlas_slot"),
            "alternatives": [
                {k: v for k, v in c.items() if k != "palette_words"}
                for c in merged[1:]],
            "ambiguity": sum(1 for c in merged[1:] if c["palette_words"] !=
                             primary["palette_words"]),
        }
        if verify_vram:
            # Every alternative gets the same VRAM treatment as the primary:
            # an alternative the modelled upload rules contradict is reported
            # as unverified rather than left looking equally good.
            for c in [primary] + merged[1:]:
                if c["source"] not in ("area_section", "area_context"):
                    continue
                sec = (c.get("section_offset")
                       if c["source"] == "area_section" else None)
                ev = vram_evidence(data, n, sec, bo, c["palette_words"],
                                   palette_base=c.get("palette_base"),
                                   palette_index=c.get("palette_index"))
                if ev is not None:
                    c["vram"] = ev
            if "vram" in primary:
                rec["vram"] = primary["vram"]
        out[bo] = rec
    return out


def _u16(d, off):
    return struct.unpack_from("<H", d, off)[0]


def _u32(d, off):
    return struct.unpack_from("<I", d, off)[0]


def palette_words(rec):
    """The resolved RGB555 words for a manifest atlas record, or None."""
    p = rec.get("palette")
    return p.get("words") if p else None


def vram_palette_image(raw, words):
    """Render a pool atlas in colour through a resolved CLUT.

    The palette is used at its NATIVE length: the 256-colour area tables carry
    256 words, the 32-colour play-family tables carry 32 (`d_flags & 0x3f`).
    An index at or past the end of the palette cannot be looked up, so it is
    painted WHITE rather than black -- a black pixel is a legitimate colour
    (index 0 is the transparent/black entry) and silently folding an
    out-of-range index into it would hide a wrong pairing. `palette_coverage`
    reports whether this happened.
    """
    a = np.frombuffer(raw, dtype=np.uint8).reshape(H, W)
    w = np.asarray(words, dtype=np.uint16)
    n = len(w)
    r = (w & 31).astype(np.uint16) * 255 // 31
    g = ((w >> 5) & 31).astype(np.uint16) * 255 // 31
    b = ((w >> 10) & 31).astype(np.uint16) * 255 // 31
    pal = np.dstack([r, g, b])[0].astype(np.uint8)
    clipped = a >= n
    idx = np.where(clipped, 0, a)
    rgba = np.dstack([pal[idx], (a != 0).astype(np.uint8) * 255])
    img = Image.fromarray(rgba, mode="RGBA")
    if clipped.any():
        arr = np.array(img)
        arr[clipped] = (255, 255, 255, 255)
        img = Image.fromarray(arr, mode="RGBA")
    bg = Image.new("RGB", (W, H), (18, 18, 22))
    bg.paste(img, (0, 0), img)
    return bg


def palette_coverage(raw, words):
    """(used index count, count of indices the palette cannot address)."""
    a = np.frombuffer(raw, dtype=np.uint8)
    used = int(len(np.unique(a)))
    return used, int(np.count_nonzero(a >= len(words)))


def colour_image(raw, clut):
    a = np.frombuffer(raw, dtype=np.uint8).reshape(H, W)
    pal = np.zeros((256, 3), np.uint8)
    for i, w in enumerate(clut):
        pal[i] = ((w & 31) * 255 // 31, ((w >> 5) & 31) * 255 // 31,
                  ((w >> 10) & 31) * 255 // 31)
    rgba = np.dstack([pal[a], (a != 0).astype(np.uint8) * 255])
    img = Image.fromarray(rgba, mode="RGBA")
    bg = Image.new("RGB", (W, H), (18, 18, 22))
    bg.paste(img, (0, 0), img)
    return bg


def oracle_clut(row=0x1E4):
    v = np.fromfile(_ORACLE_VRAM, dtype="<u2").reshape(512, 1024)
    return [int(x) for x in v[row, 256:256 + 256]]


def sheets(records, outdir, tag, scale, colour=None, cols=16):
    """Contact sheets; `colour(rec)` may return (image, caption) for colour mode.

    The caption carries the atlas's first location always, plus a colour status
    marker when a `colour` callback is in use: `*` = palette resolved from a
    table, `!` = unresolved (greyscale), which is what makes an honest unknown
    visible on the sheet rather than silently blended in.
    """
    os.makedirs(outdir, exist_ok=True)
    cw = W * scale
    per = cols * 10                       # 10 rows per sheet
    made = []
    for page in range(0, len(records), per):
        chunk = records[page:page + per]
        rows = (len(chunk) + cols - 1) // cols
        img = Image.new("RGB", (cols * cw, rows * (cw + 10)), (24, 24, 28))
        dr = ImageDraw.Draw(img)
        for i, rec in enumerate(chunk):
            cap = "%s+%#x" % (os.path.basename(rec["first_file"]),
                              rec["first_offset"])
            edge = None
            if colour:
                got = colour(rec)
                if isinstance(got, tuple):
                    p, status = got
                    cap = "%s %s" % (status, cap)
                    if status.startswith("!"):
                        edge = (210, 90, 60)
                    elif status.startswith("*"):
                        edge = (70, 170, 90)
                    else:
                        edge = (200, 180, 60)
                else:
                    p = got
            else:
                p = index_image(rec["bytes"])
            if scale != 1:
                p = p.resize((cw, cw), Image.NEAREST)
            x, y = (i % cols) * cw, (i // cols) * (cw + 10)
            img.paste(p, (x, y))
            if edge:
                dr.rectangle([x, y, x + cw - 1, y + cw - 1], outline=edge)
            dr.text((x + 2, y + cw), cap, fill=(190, 190, 200))
        path = os.path.join(outdir, "%s_%02d.png" % (tag, page // per))
        img.save(path)
        made.append(path)
    return made


def _colour_callback(oracle_clut_words):
    """Build the colour callback used by `sheets` for one render pass.

    The palette comes from the record's own manifest entry, which the scan
    resolved by sha1 across ALL occurrences of the atlas. Re-resolving only the
    occurrence in `first_file` would miss the atlases whose first occurrence is
    not the one a table names (34 of 2,006 when this was written).
    """
    def cb(rec):
        r = rec.get("resolved")
        words = r.get("words") if r else None
        if words is None and oracle_clut_words is not None:
            return colour_image(rec["bytes"], oracle_clut_words), "?oracle"
        if words is None:
            return index_image(rec["bytes"]), "!unresolved"
        img = vram_palette_image(rec["bytes"], words)
        if r.get("alternatives"):
            return img, "*%s alt=%d" % (r["source"], len(r["alternatives"]))
        return img, "*%s" % r["source"]
    return cb


def render_from_manifest(man_path, outdir, klass, scale, oracle, cols=16,
                         colour=False):
    """Decode only the manifest's recorded (file, offset) atlases and sheet them.

    Re-extracting each source file once and decoding the listed offset is far
    cheaper than the full scan, so sheets can be regenerated freely. In colour
    mode the palette is taken from the MANIFEST -- the scan's own answer, which
    was resolved by sha1 across every occurrence of the atlas. Re-resolving only
    the `first_file` occurrence here would under-report: 34 of 2,006 atlases are
    resolved through an occurrence that is not the first one.
    """
    with open(man_path) as f:
        man = json.load(f)
    keep = {"sprite": ["sprite-like"], "mid": ["mid"], "tile": ["tile-like"],
            "all": ["sprite-like", "mid", "tile-like"]}[klass]
    want = {}
    for a in man["atlases"]:
        if a["class"] in keep:
            want.setdefault(a["first_file"], []).append(a)
    recs = []
    n_res = n_unres = n_amb = 0
    for path, items in sorted(want.items()):
        r = None
        for cand in disc_files():
            if cand["path"] == path:
                r = cand
                break
        if r is None:
            print("  MISSING on disc: %s" % path)
            continue
        data = disc.extract(r["lba"], r["size"])
        for a in items:
            off = a["first_offset"]
            ln = struct.unpack_from("<I", data, off)[0]
            raw = lzss.decode_strict(data[off + 4:off + 4 + ln])
            if len(raw) != ATLAS:
                print("  re-decode mismatch %s+%#x" % (path, off))
                continue
            pal = a.get("palette")
            if colour:
                if pal:
                    n_res += 1
                    n_amb += 1 if pal.get("alternatives") else 0
                else:
                    n_unres += 1
            recs.append(dict(a, bytes=raw, resolved=pal))
        print("  rendered %-46s %3d atlases" % (path, len(items)), flush=True)
    recs.sort(key=lambda r: (r["class"], r["first_file"], r["first_offset"]))
    if colour:
        cb = _colour_callback(oracle_clut() if oracle else None)
        print("colour: %d resolved, %d unresolved, %d with alternative palettes"
              % (n_res, n_unres, n_amb))
    else:
        clut = oracle_clut() if oracle else None
        cb = ((lambda rec: colour_image(rec["bytes"], clut)) if clut else None)
    tag = {"sprite": "sprite_index", "mid": "mid_index",
           "tile": "tile_index", "all": "all_index"}[klass]
    if colour:
        tag = "colour_" + tag
    elif oracle:
        tag = "ORACLE_PALETTE_" + tag
    made = sheets(recs, os.path.join(outdir, "sheets"), tag, scale,
                  colour=cb, cols=cols)
    for p in made:
        print("sheet: %s" % p)
    return 0


def resolve_scan(records, sources, verify_vram=True, verbose=True):
    """Attach palette evidence to the scan's records, in place of guessing.

    For every file that holds atlases, the file's section/context tables are
    walked once and every atlas the pool recorded there is paired with the
    palette that table names and uses. The result is keyed by **sha1**, not by
    offset: the same atlas can occur in several files, and only a sha-keyed
    answer stays correct across those occurrences.

    Returns the summary dict that goes into the manifest. The scan result is
    not modified when `records` is passed as a plain dict of raw bytes; the
    caller passes manifest-style records (no `bytes` key).
    """
    by_file = {}
    for h, occ in sources.items():
        for s in occ:
            by_file.setdefault(s["file"], {})[s["offset"]] = h
    # An atlas can occur in many files. Resolve per OCCURRENCE, then fold to
    # the sha: any occurrence that resolves proves the pairing, and a sha whose
    # every occurrence fails is unresolved. Counting per occurrence would
    # double-count the heavy reuse (34 occurrences of one atlas) and inflate
    # the coverage number.
    per_sha = {}
    for h, occ in sources.items():
        for s in occ:
            per_sha.setdefault(h, []).append((s["file"], s["offset"]))
    lba_of = {r["path"]: r for r in disc_files()}
    stats = {"resolved": 0, "unresolved": 0, "ambiguous": 0,
             "vram_checked": 0, "vram_verified": 0, "by_source": {},
             "unresolved_reasons": {}}

    def note_reason(text):
        reasons = stats["unresolved_reasons"]
        reasons[text] = reasons.get(text, 0) + 1

    # Group the work by file so each file is extracted once.
    wants = {}
    for h, places in per_sha.items():
        for path, off in places:
            wants.setdefault(path, {}).setdefault(off, h)
    truth = {}
    for path, off2sha in sorted(wants.items()):
        r = lba_of.get(path)
        if r is None:
            for sha in off2sha.values():
                truth.setdefault(sha, {})[path] = None
            continue
        per_off = resolve_file_atlases(path, r["lba"], r["size"], off2sha,
                                       verify_vram=verify_vram)
        for off, sha in off2sha.items():
            truth.setdefault(sha, {})[path] = per_off.get(off)
        if verbose:
            print("  paired  %-46s %3d atlases" % (path, len(per_off)), flush=True)

    for h, places in sorted(per_sha.items()):
        rec = records.get(h)
        if rec is None:
            continue
        hit = None
        for path, off in places:
            cand = truth.get(h, {}).get(path)
            if cand is not None:
                hit = (path, cand)
                break
        if hit is None:
            stats["unresolved"] += 1
            rec["palette"] = None
            files = sorted({p for p, _ in places})
            rec["resolution"] = ("unresolved: no table in %s names this atlas"
                                 % (files[0] if len(files) == 1
                                    else "%d source files" % len(files)))
            note_reason("no referencing table in any source file")
            continue
        path, cand = hit
        words = cand.pop("palette_words")
        src = cand["source"]
        stats["resolved"] += 1
        stats["by_source"][src] = stats["by_source"].get(src, 0) + 1
        if cand.get("alternatives"):
            stats["ambiguous"] += 1
            note_reason("table yields several distinct palettes (all recorded)")
        ev = cand.get("vram")
        if ev is not None:
            stats["vram_checked"] += 1
            if ev.get("atlas_in_slot") and ev.get("palette_row_matches"):
                stats["vram_verified"] += 1
            else:
                note_reason("VRAM re-derivation did not confirm the pairing")
        rec["palette"] = {
            "source": src,
            "offset": cand["palette_offset"],
            "index": cand.get("palette_index"),
            "words": words,
            "section_offset": cand.get("section_offset"),
            "context_offset": cand.get("context_offset"),
            "header_offset": cand.get("header_offset"),
            "atlas_slot": cand.get("atlas_slot"),
            "alternatives": cand.get("alternatives") or [],
            "vram": ev,
        }
        rec["resolution"] = ("resolved from %s in %s" % (src, path)
                             if not cand.get("alternatives")
                             else "resolved from %s in %s, %d alternative "
                                  "palette(s)" % (src, path,
                                                  len(cand["alternatives"])))
    return stats


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(_KIT, "work", "atlas_pool"))
    ap.add_argument("--files", action="append", default=None,
                    help="fnmatch glob on the disc path (repeatable)")
    ap.add_argument("--class", dest="klass", default="sprite",
                    choices=["sprite", "mid", "tile", "all"])
    ap.add_argument("--scale", type=int, default=1)
    ap.add_argument("--oracle-clut", action="store_true")
    ap.add_argument("--colour", "--color", dest="colour", action="store_true",
                    help="resolve each atlas's palette from its source file's "
                         "own tables; unresolved atlases stay greyscale and are "
                         "counted, never guessed")
    ap.add_argument("--no-vram-check", action="store_true",
                    help="scan mode only: skip the VRAM re-derivation of "
                         "area-section pairings (faster, weaker evidence)")
    ap.add_argument("--no-scan", action="store_true",
                    help="reuse the manifest in --out instead of re-scanning")
    ap.add_argument("--render", action="store_true",
                    help="render sheets from the existing manifest (no scan)")
    args = ap.parse_args(argv)

    os.makedirs(args.out, exist_ok=True)
    man_path = os.path.join(args.out, "manifest.json")

    if args.render or args.no_scan:
        if not os.path.exists(man_path):
            raise SystemExit("no manifest at %s -- run a scan first" % man_path)
        with open(man_path) as f:
            man = json.load(f)
        keep = {"sprite": ["sprite-like"], "mid": ["mid"],
                "tile": ["tile-like"],
                "all": ["sprite-like", "mid", "tile-like"]}[args.klass]
        n = sum(1 for r in man["atlases"] if r["class"] in keep)
        print("manifest has %d atlases, %d selected (%s)"
              % (len(man["atlases"]), n, args.klass))
        if args.render:
            return render_from_manifest(man_path, args.out, args.klass,
                                        args.scale, args.oracle_clut,
                                        colour=args.colour)
        return 0

    records, sources = scan(args.files)
    atlases = []
    for h, rec in records.items():
        rec = dict(rec)
        del rec["bytes"]
        rec["occurrences"] = len(sources[h])
        rec["files"] = sorted({s["file"] for s in sources[h]})
        atlases.append(rec)
    atlases.sort(key=lambda r: (r["class"], r["first_file"], r["first_offset"]))
    by_sha = {r["sha1"]: r for r in atlases}
    resolution = None
    if args.colour:
        print("\nresolving palettes from source-file tables...")
        resolution = resolve_scan(by_sha, sources,
                                  verify_vram=not args.no_vram_check)
        resolution["rule"] = RESOLUTION_RULE
    man = {
        "provenance": ("disc-derived index planes; palettes disc-derived from "
                       "the referencing table" if args.colour
                       else "disc-derived index planes (palette not resolved)"),
        "palette_resolution": ("table-paired" if args.colour
                               else "not attempted (run with --colour)"),
        "tool": "kit/tools/atlas_pool.py",
        "decoder": DECODER_ID,
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "atlas_bytes": ATLAS, "atlas_px": [W, H],
        "sprite_zero_fraction": SPRITE_ZERO_FRAC,
        "tile_zero_fraction": TILE_ZERO_FRAC,
        "distinct_atlases": len(atlases),
        "by_class": {c: sum(1 for a in atlases if a["class"] == c)
                     for c in ("sprite-like", "mid", "tile-like")},
        "total_streams": sum(len(v) for v in sources.values()),
        "files_with_atlases": len({f for v in sources.values() for f in
                                   [s["file"] for s in v]}),
        "resolution": resolution,
        "atlases": atlases,
    }
    with open(man_path, "w") as f:
        json.dump(man, f, indent=1)
    print("\ndistinct atlases %d  streams %d  files %d"
          % (man["distinct_atlases"], man["total_streams"],
             man["files_with_atlases"]))
    print("by class: %s" % man["by_class"])
    if resolution:
        print("palettes: %d resolved, %d unresolved, %d ambiguous, "
              "vram-checked %d (verified %d)"
              % (resolution["resolved"], resolution["unresolved"],
                 resolution["ambiguous"], resolution["vram_checked"],
                 resolution["vram_verified"]))
        print("by source: %s" % resolution["by_source"])
    print("manifest: %s" % man_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
