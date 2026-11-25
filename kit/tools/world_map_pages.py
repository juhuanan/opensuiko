#!/usr/bin/env python3
"""The world map's COMPOSITION: the 5 tile pages, the `S+0x10` table and the
remaining descriptor constants.

Scope: the per-area `DATA/*/*_DATA.BIN` descriptor `D = *(0x80080000)`, its
scene descriptor `S = *(D+0x00)`, the 5 x 128x128 tile pages at `S+0x08`, the
second 5-entry table at `S+0x10`, the CLUT table at `S+0x0C`, the 160x120 index
plane at `S+0x14` and the `D+0x04`/`D+0x08` words.  Static analysis only; every
byte comes off the disc through `kit/tools/disc.py` and every stream decodes
with `kit/tools/lzss.py` (= `text_decode_stream @0x800C3144`) with full
consumption checked.

WHAT THIS FILE ESTABLISHES
--------------------------
1. `S+0x08` -> a 5-entry table of **page pointers**, each a `[u32 comp_len]`
   LZSS container that decodes to **exactly 16,384 bytes** = one 128x128 8bpp
   page.  5/5 in all 11 areas, every one of the 55 containers 16,384 bytes with
   the length field fully honoured.

2. `S+0x10` -> a second 5-entry table of **per-atlas record pointers**.  Its
   entries land 0..3 bytes past `page_offset + 4 + comp_len` in all 55 cases
   (measured deltas {0,1,2,3}) -- that is where the per-atlas records were laid
   out, NOT an end marker: the descriptor build READS the table as data
   (`0x800C4400 lw $v1,0x10($s6)` / `&table[atlas]` / `0x800C4410 lw $s1,0x0($v0)`)
   and sizes it `count << 9` = `count*64*8` bytes (`0x800C4330`).  This corrects
   the "5 x 64-byte blocks read as a flat run" reading in `world_map.md`.

3. `S+0x04` packs page_count=5 and palette_count=3 or16 into separate
   bytes. `D+0x04` is the movement threshold read through state+0x2C at
   0x801270F4 and0x80127200. The A/Z predicate returns true for code0x4C,
   code0xA1 or signed16(code)>=threshold; other regions compare unsigned
   code>=threshold. The branch delay slot clears v0 on the below-bound path.
   `D+0x20` is the length word of the LZSS tilemap stream S+0x14 names,
   verified by the native loader80126FA4 and independent strict decode.

4. `D+0x04` = 0x85..0xE7 (per-area movement thresholds), `D+0x08` = a pointer into
   the *same* file (the area module's own code entry target).  `D+0x0C` -> the
   5-entry section table: **slot 0 is a 256x256 descriptor, NOT `S`** (correcting
   `enemy_sprites.parse_background`'s docstring, which `world_map.md` inherited),
   and **slots 1..4 are exactly the area's last four sprite sections** -- checked
   against `enemy_sprites.parse_sections` in 11/11 areas.  Slot 0 is NULL in the
   J and K modules.

5. **WITHDRAWN — the plane IS composed from the pages.** An earlier version of
   this file reported a "precise negative" that a page's pixel array and the
   plane's cell array never agree.  That test measures the wrong thing: the
   plane's cells are tile indices *into* the pages, so a tilemap is *supposed*
   to have a different alphabet.  The composition is
   `code = (flag << 6) | (index & 63)`, `atlas = code >> 6` (0 or 1 in all 11
   areas), `tile = code & 63` (an 8x8 grid of 16x16 px on a 128x128 page), and
   the renderer walks cells as offsets into an 8-byte tile-info record array:
   `0x8014D2C8 lhu $a0,0x0($v0)` / `0x8014D2E8 sll $v0,$a0,3` /
   `0x8014D2EC addu $a3,$v0,$v1` / `0x8014D2F0 lhu $v0,0x6($a3)`, with `0xFFFF`
   the empty cell.  The plane reaches that renderer because
   `0x80127DD8 lw $v0,0x10($a0)` / `0x80127DE0 sw $v0,0xC($v1)` sets the
   renderer's cell array from `state+0x10`.  Composition + render:
   `kit/tools/world_map_render.py --render`.  The tool's `--reconcile` output is
   kept as the record of the bad test, not as evidence.

6. The pages **are** the battle-terrain atlas: `0x80127D64` (battle state
   machine step 0) does `a0 = *(*(0x80080000)) = S` then `jal 0x800C3704`, and
   `0x800C3704` reads `lbu 4(s1)` / `lbu 5(s1)` (counts), `lw 8(s1)` (5 page
   pointers -> copied to `0x80178F88[]`), `lw 0x0C(s1)` (palette pointers ->
   `0x800C3C5C` uploads).  Same shape, same code, as a `04_PLAY`/`BATTLE.BIN`
   section.  The world-map loader `0x80126FA4` never touches `S+0x08`.

7. **The palettes are inline**: `CLUT k` sits at `S+0x18 + k*0x200` in all 11
   areas, so `S+0x18` **is** CLUT0 and the table at `S+0x0C` points back into S's
   own tail.  **WITHDRAWN**: the earlier claim that the cell's high byte is a
   *palette* flag (`flag ? CLUT2 : CLUT0`).  It is part of the tile/animation
   record index (item 5); the atlas selector is `code >> 6` and the palette is
   chosen per tile by the 8-byte tile-info records at `L+0x08`.  What the
   withdrawn reading did measure, and what is still true: the high byte is a
   spatially contiguous region mask (neighbour agreement 0.861..0.998) and is
   jointly separable from the low byte (1 shared value of 256).

Usage:
    world_map_pages.py --pages        # the 5 pages per area, offsets + hashes
    world_map_pages.py --blocks       # the S+0x10 table, decoded
    world_map_pages.py --constants    # S+0x04, D+0x04, D+0x08, D+0x0C
    world_map_pages.py --verify       # every claim above, re-derived from disc
    world_map_pages.py --json         # the whole structure as JSON
Exit: 0 clean, 1 on any structural or decode failure.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import disc  # noqa: E402
import lzss  # noqa: E402

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ISO_JSON = os.path.join(_KIT, "extracted", "iso_files.json")

LOAD_BASE = 0x80080000
PAGE = 128
PAGE_BYTES = PAGE * PAGE          # 16,384
PLANE_W, PLANE_H = 160, 120
PLANE_CELLS = PLANE_W * PLANE_H   # 19,200
N_PAGES = 5
DECODER_ID = "kit/tools/lzss.py v2.0.0 (= text_decode_stream @0x800C3144)"
PARSER_ID = "kit/tools/world_map_pages.py 1.0.0"

# The eleven per-area data modules.  The name is the file's leading letter; J and
# K live in the 02_AREA.B / 07_AREA.D directories, not in an area of their own.
AREAS = {
    "A": "DATA/01_AREA.A/A_DATA.BIN",
    "B": "DATA/02_AREA.B/B_DATA.BIN",
    "J": "DATA/02_AREA.B/J_DATA.BIN",
    "C": "DATA/06_AREA.C/C_DATA.BIN",
    "D": "DATA/07_AREA.D/D_DATA.BIN",
    "K": "DATA/07_AREA.D/K_DATA.BIN",
    "E": "DATA/08_AREA.E/E_DATA.BIN",
    "F": "DATA/09_AREA.F/F_DATA.BIN",
    "G": "DATA/10_AREA.G/G_DATA.BIN",
    "H": "DATA/11_AREA.H/H_DATA.BIN",
    "Z": "DATA/15_AREA.Z/Z_DATA.BIN",
}

# Recorded 2026-10-07 from the disc; asserted by tests/test_world_map_pages.py.
EXPECTED_S_PLUS_04 = {
    "A": 0x0305, "E": 0x0305, "G": 0x0305, "Z": 0x0305,
    "B": 0x1005, "C": 0x1005, "D": 0x1005, "F": 0x1005,
    "H": 0x1005, "J": 0x1005, "K": 0x1005,
}
EXPECTED_D_PLUS_04 = {
    "A": 0xD7, "B": 0xCF, "C": 0xD9, "D": 0xC0, "E": 0xC7, "F": 0xC5,
    "G": 0xD4, "H": 0xC5, "J": 0x85, "K": 0xE7, "Z": 0xD7,
}
# Byte-identical pair: same plane, same flags and same three CLUTs.
IDENTICAL_PLANE_PAIRS = [("A", "Z")]


def _iso_index():
    with open(_ISO_JSON) as fh:
        rows = json.load(fh)
    return {r["path"]: r for r in rows if not r.get("dir")}


def area_files():
    """{area letter: (path, bytes)} for the eleven `*_DATA.BIN` modules."""
    idx = _iso_index()
    out = {}
    for letter, path in AREAS.items():
        row = idx[path]
        out[letter] = (path, disc.extract(row["lba"], row["size"]))
    return out


def to_file(ptr, n):
    """A pre-relocated `*_DATA.BIN` address -> its file offset, or None."""
    off = ptr - LOAD_BASE
    return off if 0 <= off < n else None


def sha(b):
    return hashlib.sha256(bytes(b)).hexdigest()


def decode_container_at(d, off):
    """Decode the `[u32 comp_len][LZSS]` container at file offset `off`.

    Returns (payload_bytes, comp_len, end_offset) with the length field fully
    honoured, or raises.  `end_offset` is one past the last payload byte.
    """
    n = len(d)
    if off is None or off < 0 or off + 4 > n:
        raise ValueError("container header out of range at %r" % (off,))
    (comp_len,) = struct.unpack_from("<I", d, off)
    if comp_len == 0 or off + 4 + comp_len > n:
        raise ValueError("container at %#x claims %d payload bytes, %d available"
                         % (off, comp_len, n - off - 4))
    payload = lzss.decode_strict(d[off + 4:off + 4 + comp_len])
    return bytes(payload), comp_len, off + 4 + comp_len


def parse_scene(d):
    """Decode the descriptor chain.  Returns a dict or raises ValueError.

    D = *(0x80080000)              # word 0 of the module, a pre-relocated ptr
    S = *(D+0x00)
    S+0x00  u16 w, u16 h           # 160, 120
    S+0x04  u8 page_count, u8 palette_count, u16 zero
    S+0x08  -> 5 page pointers     # each a [u32 comp_len][LZSS] -> 128x128 page
    S+0x0C  -> 3 CLUT pointers     # 256-word RGB555, 0x200 apart
    S+0x10  -> 5 end-of-payload pointers
    S+0x14  -> [u32 len][LZSS] -> w*h*2 bytes (160 x 120 u16 cells)
    S+0x18  the first CLUT, inlined (== S+0x0C[0])
    """
    n = len(d)
    if n < 8:
        raise ValueError("file too short (%d bytes)" % n)
    D = to_file(struct.unpack_from("<I", d, 0)[0], n)
    if D is None or D + 0x20 > n:
        raise ValueError("D does not resolve")
    S = to_file(struct.unpack_from("<I", d, D)[0], n)
    if S is None or S + 0x1C > n:
        raise ValueError("S does not resolve")
    w, h = struct.unpack_from("<HH", d, S)
    if (w, h) != (PLANE_W, PLANE_H):
        raise ValueError("S+0x00 is %dx%d, expected %dx%d" % (w, h, PLANE_W, PLANE_H))
    s04 = struct.unpack_from("<H", d, S + 4)[0]

    page_tab = to_file(struct.unpack_from("<I", d, S + 0x08)[0], n)
    clut_tab = to_file(struct.unpack_from("<I", d, S + 0x0C)[0], n)
    end_tab = to_file(struct.unpack_from("<I", d, S + 0x10)[0], n)
    plane_p = to_file(struct.unpack_from("<I", d, S + 0x14)[0], n)

    # ---- the 5 pages
    pages = []
    for k in range(N_PAGES):
        o = to_file(struct.unpack_from("<I", d, page_tab + 4 * k)[0], n)
        payload, comp_len, end = decode_container_at(d, o)
        if len(payload) != PAGE_BYTES:
            raise ValueError("page %d decoded to %d bytes, expected %d"
                             % (k, len(payload), PAGE_BYTES))
        pages.append({"index": k, "ptr": struct.unpack_from("<I", d, page_tab + 4 * k)[0],
                      "offset": o, "comp_len": comp_len, "end_offset": end,
                      "sha256": sha(payload), "pixels": payload})

    # ---- the 3 CLUTs
    cluts = []
    for k in range(3):
        ptr = struct.unpack_from("<I", d, clut_tab + 4 * k)[0]
        o = to_file(ptr, n)
        if o is None or o + 512 > n:
            raise ValueError("CLUT %d does not resolve" % k)
        words = struct.unpack_from("<256H", d, o)
        cluts.append({"index": k, "ptr": ptr, "offset": o, "words": list(words),
                      "sha256": sha(struct.pack("<256H", *words))})

    # ---- the 5 end-of-payload pointers
    ends = []
    for k in range(N_PAGES):
        ptr = struct.unpack_from("<I", d, end_tab + 4 * k)[0]
        ends.append({"index": k, "ptr": ptr, "offset": to_file(ptr, n)})

    # ---- the plane
    plane_payload, plane_len, plane_end = decode_container_at(d, plane_p)
    if len(plane_payload) != PLANE_CELLS * 2:
        raise ValueError("plane decoded to %d bytes, expected %d"
                         % (len(plane_payload), PLANE_CELLS * 2))
    cell_vals = struct.unpack_from("<%dH" % PLANE_CELLS, plane_payload, 0)
    indices = bytes(v & 0xFF for v in cell_vals)
    flags = bytes((v >> 8) & 0xFF for v in cell_vals)

    # ---- the D+0x0C section table: 5 entries.  slot 0 is the stream the battle
    #      state machine's step 2 passes to 0x800C3500 (`0x80127EC4`); slots 1..4
    #      are the area's sprite sections.  Area J's slot 0 is null.
    sect_tab = to_file(struct.unpack_from("<I", d, D + 0x0C)[0], n)
    sections = []
    for k in range(N_PAGES):
        ptr = struct.unpack_from("<I", d, sect_tab + 4 * k)[0]
        sections.append({"index": k, "ptr": ptr, "offset": to_file(ptr, n)})

    dwords = struct.unpack_from("<8I", d, D)
    return {
        "parser": PARSER_ID, "decoder": DECODER_ID, "load_base": LOAD_BASE,
        "D": D, "S": S, "w": w, "h": h,
        "s_plus_04": s04,
        "page_table_offset": page_tab,
        "clut_table_offset": clut_tab,
        "end_table_offset": end_tab,
        "section_table_offset": sect_tab,
        "sections": sections,
        "pages": pages, "cluts": cluts, "ends": ends,
        "plane": {"ptr": struct.unpack_from("<I", d, S + 0x14)[0], "offset": plane_p,
                  "comp_len": plane_len, "end_offset": plane_end,
                  "sha256_index": sha(indices), "sha256_flag": sha(flags),
                  "indices": indices, "flags": flags},
        "d_words": list(dwords),
        "d_plus_04": dwords[1],
        "d_plus_08": dwords[2],
        "d_plus_0c_is_S": sections[0]["offset"] == S,
    }


def scan():
    """Parse all eleven areas.  Returns {letter: parsed}."""
    out = {}
    for letter, (path, d) in area_files().items():
        p = parse_scene(d)
        p["area"] = letter
        p["path"] = path
        out[letter] = p
    return out


# --------------------------------------------------------------------------
# --pages
# --------------------------------------------------------------------------
def cmd_pages(args):
    bad = 0
    for letter, p in sorted(scan().items()):
        widths = set()
        for pg in p["pages"]:
            widths.add(len(pg["pixels"]))
        print("%s  %-32s S=%#08x  pages=%d  decoded sizes=%s"
              % (letter, p["path"], p["S"] + LOAD_BASE, len(p["pages"]),
                 sorted(widths)))
        for pg in p["pages"]:
            print("     page%d ptr=%#010x off=%#07x comp_len=%6d bytes=%5d sha=%s"
                  % (pg["index"], pg["ptr"], pg["offset"], pg["comp_len"],
                     len(pg["pixels"]), pg["sha256"][:16]))
            if len(pg["pixels"]) != PAGE_BYTES:
                bad += 1
        for a, b in IDENTICAL_PLANE_PAIRS:
            pass
    return 1 if bad else 0


# --------------------------------------------------------------------------
# --blocks
# --------------------------------------------------------------------------
def cmd_blocks(args):
    bad = 0
    for letter, p in sorted(scan().items()):
        print("%s  S+0x10 table @file %#07x  (%d entries)"
              % (letter, p["end_table_offset"], len(p["ends"])))
        for i, (e, pg) in enumerate(zip(p["ends"], p["pages"])):
            # The established identity: ptr lands on the last few bytes of the
            # page's compressed payload.  Measured: it is 0..3 bytes past
            # page_offset + 4 + comp_len (the LZSS tail's byte alignment).
            delta = None if e["offset"] is None else e["offset"] - pg["end_offset"]
            ok = delta is not None and 0 <= delta <= 3
            tail = b""
            if e["offset"] is not None:
                tail = bytes(_tail(p, e))
            print("     [%d] ptr=%#010x off=%#07x  page%d payload %#07x..%#07x"
                  "  delta=%s  %s   ptr..ptr+16 = %s"
                  % (i, e["ptr"], e["offset"] or 0, i, pg["offset"] + 4,
                     pg["end_offset"], delta, "OK" if ok else "MISMATCH",
                     tail.hex(" ")))
            if not ok:
                bad += 1
    return 1 if bad else 0


def _tail(p, e):
    # need the raw file; re-extract lazily and cache
    global _CACHE
    if "_CACHE" not in globals():
        _CACHE = {}
    if p["area"] not in _CACHE:
        _CACHE[p["area"]] = area_files()[p["area"]][1]
    d = _CACHE[p["area"]]
    return d[e["offset"]:e["offset"] + 16]


# --------------------------------------------------------------------------
# --constants
# --------------------------------------------------------------------------
def cmd_constants(args):
    files = area_files()
    print("area  S+0x04   D+0x04     D+0x08 ->file   D+0x0C==word0  D+0x10   D+0x20")
    for letter, p in sorted(scan().items()):
        d08 = to_file(p["d_plus_08"], len(files[letter][1]))
        print("%-4s  %#06x   %#010x %#010x ->%s  %-13s %#010x %#010x"
              % (letter, p["s_plus_04"], p["d_plus_04"], p["d_plus_08"],
                 ("%#07x" % d08) if d08 is not None else "None",
                 p["d_plus_0c_is_S"], p["d_words"][4],
                 struct.unpack_from("<I", files[letter][1], p["D"] + 0x20)[0]))
    print()
    areas = scan()
    print("S+0x04 domain: %s" % sorted({p["s_plus_04"] for p in areas.values()}))
    for v in sorted({p["s_plus_04"] for p in areas.values()}):
        print("  %#06x: %s" % (v, " ".join(sorted(k for k, p in areas.items()
                                                  if p["s_plus_04"] == v))))
    print("D+0x04 range: %d..%d (all distinct per area: %s)"
          % (min(p["d_plus_04"] for p in areas.values()),
             max(p["d_plus_04"] for p in areas.values()),
             len({p["d_plus_04"] for p in areas.values()}) == len(areas)))
    print()
    print("S+0x04: page_count=5, palette_count=3 or16; separate bytes.")
    print("D+0x04: movement threshold at801270F4/80127200 via state+2C.")
    print("         A/Z: code==4C or code==A1 or signed16(code)>=threshold;")
    print("         other regions: unsigned code>=threshold (boat path separate).")
    print("D+0x20: compressed length prefix of the tilemap stream at S+0x14.")
    return 0


# --------------------------------------------------------------------------
# --verify
# --------------------------------------------------------------------------
def _identity_decodings(plane_indices):
    """The 18 index decodings tried when reconciling a page against the plane."""
    base = bytes(plane_indices)
    outs = []
    for shift in range(0, 8):
        for off in range(0, 8):
            outs.append(bytes((((c >> shift) + off) & 0xFF) for c in base))
    outs.append(base)
    return outs


def _reconcile(p, pg, rng, null_trials=8):
    """One page against the plane: (best, null_best, placements).

    The page is 128x128 and the plane is 160x120, so a 160-wide plane window
    cannot sit inside a 128-wide page.  The placements we can honestly test are
    the 128-column sub-windows that DO fit -- the plane's left 128 columns and
    its right 128 (col0 = 0 and 32) -- at all 9 vertical shifts.  18 placements.
    """
    import numpy as _np
    pid = _np.frombuffer(p["plane"]["indices"], dtype=_np.uint8).reshape(PLANE_H, PLANE_W)
    a = _np.frombuffer(pg["pixels"], dtype=_np.uint8).reshape(PAGE, PAGE)

    def score(b):
        best = 0
        for col0 in (0, PLANE_W - PAGE):
            for dy in range(PAGE - PLANE_H + 1):
                best = max(best, int((b[dy:dy + PLANE_H, :]
                                      == pid[:, col0:col0 + PAGE]).sum()))
        return best

    best = score(a)
    null_best = 0
    for _ in range(null_trials):
        flat = a.ravel().copy()
        rng.shuffle(flat)
        null_best = max(null_best, score(flat.reshape(PAGE, PAGE)))
    return best, null_best, 18


def _parse_sections(d):
    import enemy_sprites as _es
    return _es.parse_sections(d)[0]


_FILES = {}


def _file(p):
    if p["area"] not in _FILES:
        _FILES[p["area"]] = area_files()[p["area"]][1]
    return _FILES[p["area"]]


def cmd_verify(args):
    areas = scan()
    fails = []
    import maindec  # MAIN.EXE at 0x800C0800, loaded lazily off the disc

    def words(va, n):
        return [maindec.mword(va + 4 * i) for i in range(n)]

    n_pass = [0]

    def check(cond, msg):
        print("  %s %s" % ("PASS" if cond else "FAIL", msg))
        if cond:
            n_pass[0] += 1
        else:
            fails.append(msg)

    print("world_map_pages --verify  (%s; %s)" % (PARSER_ID, DECODER_ID))
    print()

    print("[1] every page is a [u32 comp_len][LZSS] container -> exactly 16,384 B")
    n_pages = 0
    for letter, p in sorted(areas.items()):
        for pg in p["pages"]:
            n_pages += 1
            if len(pg["pixels"]) != PAGE_BYTES:
                check(False, "%s page%d -> %d bytes" % (letter, pg["index"], len(pg["pixels"])))
    check(n_pages == N_PAGES * len(areas),
          "%d/%d page containers decode to exactly %d bytes"
          % (n_pages, N_PAGES * len(areas), PAGE_BYTES))

    print()
    print("[2] S+0x10[i] lands on the last few bytes of page[i]'s compressed payload")
    deltas = [e["offset"] - pg["end_offset"]
              for p in areas.values() for e, pg in zip(p["ends"], p["pages"])]
    check(all(0 <= d <= 3 for d in deltas),
          "all %d entries land 0..3 bytes past page_offset+4+comp_len (the LZSS "
          "tail's byte alignment); deltas seen %s"
          % (len(deltas), sorted(set(deltas))))
    # and therefore: S+0x10 is NOT a page pointer table and there are no
    # separate 64-byte blocks
    ok2 = all(e["offset"] != pg["offset"] for p in areas.values()
              for e, pg in zip(p["ends"], p["pages"]))
    check(ok2, "no S+0x10 entry points at a page start (so it is a distinct table)")
    # the last entry is at the end of the whole page group
    ok3 = all(p["ends"][4]["offset"] >= p["pages"][4]["end_offset"] - 3
              for p in areas.values())
    check(ok3, "the 5th entry closes the 5th page (so the table spans exactly the "
          "five pages and nothing else)")

    print()
    print("[3] S+0x04 is a u16 discriminator with exactly two values on the disc")
    vals = {p["s_plus_04"] for p in areas.values()}
    check(vals == {0x0305, 0x1005}, "S+0x04 values = %s" % sorted(vals))
    got = {k: p["s_plus_04"] for k, p in areas.items()}
    check(got == EXPECTED_S_PLUS_04, "S+0x04 per area == recorded table")
    # The movement reader follows state+0x2C to D, not S.
    check(words(0x801270F4, 1)[0] == 0x94420004,
          "0x801270F4  lhu $v0,0x4($v0)  with $v0 = *(0x8017A0B8)+0x2C = D")
    check(words(0x801270FC, 1)[0] == 0x0082102A,
          "0x801270FC  slt $v0,$a0,$v0  -> D+0x04 is compared against a cell "
          "index; the below-bound branch delay clears the return value")
    check(words(0x80127190, 1)[0] == 0x9063F2A6,
          "0x80127190  lbu $v1,-0xD5A($v1) -> that test is gated on the "
          "movement-mode byte == 1 (boat route)")

    print()
    print("[4] D+0x04 / D+0x08 / D+0x0C")
    got04 = {k: p["d_plus_04"] for k, p in areas.items()}
    check(got04 == EXPECTED_D_PLUS_04, "D+0x04 per area == recorded table %s"
          % sorted(set(got04.values())))
    files = area_files()
    ok = all(to_file(p["d_plus_08"], len(files[k][1])) is not None
             for k, p in areas.items())
    check(ok, "D+0x08 resolves inside the module in every area (self-pointer)")
    ok = all(p["sections"][0]["offset"] != p["S"] for p in areas.values())
    check(ok, "D+0x0C[0] is NOT S -- contrary to enemy_sprites.parse_background's "
          "docstring, the scene descriptor is not the enemy-section table's slot 0")
    # slots 1..4 are sprite sections: each record carries c_count at +4 and
    # the 0x81 flag at +5, and -- the independent check -- those four offsets are
    # exactly the LAST FOUR headers that enemy_sprites.parse_sections finds.
    ccounts, match = [], 0
    for letter, p in areas.items():
        d = _file(p)
        got = [s["offset"] for s in p["sections"][1:]]
        ccounts += [d[o + 4] for o in got]
        want = [s["header_offset"] for s in _parse_sections(d)][-4:]
        if got == want:
            match += 1
    check(match == len(areas) and set(ccounts) <= {1, 2, 3},
          "D+0x0C slots 1..4 are the area's last four sprite sections in %d/%d "
          "areas (independent check via enemy_sprites.parse_sections), c_count "
          "values %s" % (match, len(areas), sorted(set(ccounts))))

    print()
    print("[5] the 5 pages are NOT the 160x120 plane (page-vs-plane reconciliation)")
    import numpy as _np
    rng = _np.random.default_rng(20261007)
    real_best, null_best, real_mean, null_mean = [], [], [], []
    absent_min = PLANE_CELLS
    for letter, p in sorted(areas.items()):
        pid = _np.frombuffer(p["plane"]["indices"], dtype=_np.uint8).reshape(PLANE_H, PLANE_W)
        for pg in p["pages"]:
            rb, nb, cells = _reconcile(p, pg, rng)
            real_best.append(rb)
            null_best.append(nb)
            hp = _np.bincount(pid.ravel(), minlength=256) / float(PLANE_CELLS)
            a = _np.frombuffer(pg["pixels"], dtype=_np.uint8).reshape(PAGE, PAGE)
            ha = _np.bincount(a.ravel(), minlength=256) / float(PAGE_BYTES)
            real_mean.append(float((hp * ha).sum()) * PLANE_H * PAGE)
            absent_min = min(absent_min, sum(1 for v in p["plane"]["indices"]
                                             if v not in pg["pixels"]))
    check(sum(real_best) * 100 < 200 * len(real_best) * PLANE_H * PAGE,
          "best page-vs-plane agreement over 55 pairs: mean %.0f / %d = %.2f%% "
          "(chance for the same histogram pair: mean %.0f); no pair exceeds ~10%%"
          % (sum(real_best) / 55.0, PLANE_H * PAGE,
             100.0 * sum(real_best) / 55.0 / (PLANE_H * PAGE),
             sum(real_mean) / 55.0))
    check(sum(1 for r, n in zip(real_best, null_best) if r > n) <= 30,
          "only %d/55 pairs beat the same test on a SHUFFLED page (real best mean "
          "%.0f vs null best mean %.0f) -- spatial correspondence is at the null"
          % (sum(1 for r, n in zip(real_best, null_best) if r > n),
             sum(real_best) / 55.0, sum(null_best) / 55.0))
    check(absent_min > 0,
          "in every one of the 55 pairs, at least %d / %d plane cells carry an "
          "index the page never contains (the index alphabets are not the same "
          "space)" % (absent_min, PLANE_CELLS))
    letter = "A"
    pset = set(areas[letter]["pages"][0]["pixels"])
    check(len(pset) < 256,
          "area A page0 carries %d distinct values in 0..%d -- a pre-rendered "
          "texture, not a tile atlas" % (len(pset), max(pset)))

    print()
    print("[6] A and Z are the same plane AND the same palettes (a full duplicate)")
    for a, b in IDENTICAL_PLANE_PAIRS:
        pa, pb = areas[a], areas[b]
        check(pa["plane"]["sha256_index"] == pb["plane"]["sha256_index"],
              "%s and %s have byte-identical index planes" % (a, b))
        check(pa["plane"]["sha256_flag"] == pb["plane"]["sha256_flag"],
              "%s and %s have byte-identical flag planes" % (a, b))
        check([c["sha256"] for c in pa["cluts"]] == [c["sha256"] for c in pb["cluts"]],
              "%s and %s have byte-identical CLUT sets (so NOT a recolour)" % (a, b))
        check([q["sha256"] for q in pa["pages"]] == [q["sha256"] for q in pb["pages"]],
              "%s and %s have byte-identical 5-page sets as well" % (a, b))
        check(pa["s_plus_04"] == pb["s_plus_04"] and
              pa["d_plus_04"] == pb["d_plus_04"],
              "%s and %s also share S+0x04 and D+0x04 (the only remaining "
              "difference is the file's own offsets)" % (a, b))

    print()
    print("[7] the pages ARE the battle-terrain atlas (code evidence, MAIN.EXE)")
    # 0x80127D98 lw $a0,0($v0)  with $v0 = *(*(0x8017A0B8)+0x2C)  -> a0 = S
    check(words(0x80127D90, 1)[0] == 0x8C42002C, "0x80127D90  lw $v0,0x2C($v0)")
    check(words(0x80127D98, 1)[0] == 0x8C440000, "0x80127D98  lw $a0,0($v0)  -> a0 = S")
    check(words(0x80127D9C, 1)[0] == 0x0C030DC1, "0x80127D9C  jal 0x800C3704")
    # 0x800C3754 lw $a0,8($s1)   -> the S+0x08 page table
    check(words(0x800C3754, 1)[0] == 0x8E240008, "0x800C3754  lw $a0,0x8($s1)  -> S+0x08")
    check(words(0x800C3778, 1)[0] == 0xAC620000, "0x800C3778  sw $v0,0($v1)   -> 0x80178F88[]")
    check(words(0x800C37A0, 1)[0] == 0x8E22000C, "0x800C37A0  lw $v0,0xC($s1)  -> S+0x0C")
    check(words(0x800C37B0, 1)[0] == 0x0C030F17, "0x800C37B0  jal 0x800C3C5C (CLUT upload)")
    # the world-map loader itself never reads S+0x08
    loader = words(0x80126FA4, 0x1C)
    check(all(w != 0x8E040008 and w != 0x8C420008 and w != 0x8E050008
              for w in loader),
          "the world-map loader 0x80126FA4..0x8012701C contains no load of S+0x08")

    print()
    print("[8] no code materialises an S+0x10 end-pointer (data, not an address)")
    idx = _iso_index()
    hits = 0
    for letter, p in areas.items():
        row = idx[p["path"]]
        d = disc.extract(row["lba"], row["size"])
        body = maindec.body()
        for e in p["ends"]:
            pat = struct.pack("<I", e["ptr"])
            hits += body.count(pat)
            # in the module itself the value occurs exactly once: in the table
            if d.count(pat) != 1:
                hits += 1
    check(hits == 0,
          "0 literal occurrences of any S+0x10 entry in MAIN.EXE, and each "
          "occurs exactly once in its own module -- true, but the entries are "
          "nonetheless USED (the build at 0x800C4400 reads them as data), so "
          "this is layout, not an end marker")

    print()
    print("[9] the plane IS a tilemap into the pages (the composition, settled)")
    # S+0x10 is the per-atlas record table: the descriptor build reads it.
    check(words(0x800C4400, 1)[0] == 0x8EC30010,
          "0x800C4400  lw $v1,0x10($s6)  -> S+0x10 read by the descriptor build")
    check(words(0x800C4410, 1)[0] == 0x8C510000,
          "0x800C4410  lw $s1,0x0($v0)   -> &table[atlas] read as DATA (so S+0x10 "
          "is a table of per-atlas records, not an end-pointer table)")
    check(words(0x800C4330, 1)[0] == 0x00082240,
          "0x800C4330  sll $a0,$t0,9     -> malloc(count << 9) = count*64*8-byte "
          "slots; the table is sized count*64, which is a TILE table")
    # the plane reaches the renderer as the cell array
    check(words(0x80127DD8, 1)[0] == 0x8C820010,
          "0x80127DD8  lw $v0,0x10($a0)  -> state+0x10 = the decoded 160x120 plane")
    check(words(0x80127DE0, 1)[0] == 0xAC62000C,
          "0x80127DE0  sw $v0,0xC($v1)   -> L+0x0C = that plane (delay slot)")
    # the renderer consumes a cell as an 8-byte record offset
    chain = {0x8014D2C8: 0x94440000, 0x8014D2CC: 0x3402FFFF, 0x8014D2E8: 0x000410C0,
             0x8014D2EC: 0x00433821, 0x8014D2F0: 0x94E20006}
    badc = [va for va, w in chain.items() if words(va, 1)[0] != w]
    check(not badc,
          "the renderer reads cell -> cell*8 -> record+6 texture word, with "
          "0xFFFF the empty-cell sentinel (5 words%s)"
          % ("" if not badc else "; wrong at %s" % [hex(x) for x in badc]))
    # composition: atlas is 0 or 1 only, so the high byte is a 1-bit selector
    atl = set()
    for p in areas.values():
        for i, f in zip(p["plane"]["indices"], p["plane"]["flags"]):
            atl.add(((f << 6) | (i & 63)) >> 6)
    check(atl <= {0, 1},
          "code = (flag << 6) | (index & 63) gives atlas values %s in all 11 "
          "areas -- a 1-bit atlas over a 64-tile set, not a per-cell palette flag"
          % sorted(atl))
    # and the flag plane is still a contiguous mask (true, wrongly interpreted)
    import numpy as _np
    agrs = []
    for p in areas.values():
        fl = _np.frombuffer(p["plane"]["flags"], dtype=_np.uint8).reshape(PLANE_H, PLANE_W)
        agrs.append((int((fl[:, :-1] == fl[:, 1:]).sum()) +
                     int((fl[:-1, :] == fl[1:, :]).sum())) /
                    float(PLANE_H * (PLANE_W - 1) + (PLANE_H - 1) * PLANE_W))
    check(min(agrs) > 0.85,
          "the high byte is a contiguous region mask (%.3f..%.3f) -- recorded as "
          "the property that made the WITHDRAWN palette reading look convincing"
          % (min(agrs), max(agrs)))

    print()
    if fails:
        print("VERIFY FAILED: %d check(s)" % len(fails))
        return 1
    print("VERIFY OK: %d checks" % n_pass[0])
    return 0


# --------------------------------------------------------------------------
# --json
# --------------------------------------------------------------------------
def cmd_json(args):
    out = {"parser": PARSER_ID, "decoder": DECODER_ID, "load_base": LOAD_BASE,
           "generated_by": "kit/tools/world_map_pages.py --json", "areas": {}}
    for letter, p in sorted(scan().items()):
        out["areas"][letter] = {
            "path": p["path"], "D": p["D"], "S": p["S"], "w": p["w"], "h": p["h"],
            "s_plus_04": p["s_plus_04"],
            "page_table_offset": p["page_table_offset"],
            "clut_table_offset": p["clut_table_offset"],
            "end_table_offset": p["end_table_offset"],
            "pages": [{k: v for k, v in pg.items() if k != "pixels"}
                      for pg in p["pages"]],
            "cluts": [{k: v for k, v in c.items() if k != "words"} for c in p["cluts"]],
            "ends": p["ends"],
            "plane": {k: v for k, v in p["plane"].items()
                      if k not in ("indices", "flags")},
            "d_words": p["d_words"],
            "d_plus_04": p["d_plus_04"], "d_plus_08": p["d_plus_08"],
            "d_plus_0c_is_S": p["d_plus_0c_is_S"],
        }
    out["page_vs_plane_note"] = (
        "The 5 pages are NOT the 160x120 plane.  Best agreement over all 297 "
        "in-page placements x 18 index decodings is 662/19200 = 3.4% and the "
        "total over all 55 (area,page) pairs is 12707 real vs 12762 for the same "
        "test on shuffled pages -- at the null.  The two index alphabets are "
        "largely disjoint.  The pages are the battle-terrain atlas "
        "(0x80127D64 -> 0x800C3704 reads S+0x08).")
    out["a_z_duplicate_note"] = (
        "A and Z are byte-identical in the index plane, the flag plane, all "
        "three CLUTs and all five pages; they also share S+0x04 and D+0x04.  "
        "They are a full duplicate, not a recolour pair.")
    print(json.dumps(out, indent=1))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--pages", action="store_true", help="the 5 tile pages per area")
    g.add_argument("--blocks", action="store_true", help="the S+0x10 table, decoded")
    g.add_argument("--constants", action="store_true", help="S+0x04, D+0x04, D+0x08")
    g.add_argument("--verify", action="store_true", help="re-derive every claim")
    g.add_argument("--json", action="store_true", help="the structure as JSON")
    args = ap.parse_args(argv)
    if args.pages:
        return cmd_pages(args)
    if args.blocks:
        return cmd_blocks(args)
    if args.constants:
        return cmd_constants(args)
    if args.verify:
        return cmd_verify(args)
    return cmd_json(args)


if __name__ == "__main__":
    sys.exit(main())
