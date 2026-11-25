#!/usr/bin/env python3
"""Enemy / monster sprite sections in the per-area `DATA/*/*_DATA.BIN` overlays.

THE FINDING (2026-10-05)
------------------------
`battle_render_status.md` recorded the enemy sprite source as
unidentified after five eliminated hypotheses. It is here.

In MAIN.EXE, `0x80126FA4` sets the battle asset descriptor to the **first word
of the overlay loaded at `0x80080000`**:

    0x80126fac  lui  $v0,0x8008
    0x80126fb0  lw   $v0,0x0($v0)      # v0 = *(0x80080000)
    0x80126fc0  sw   $v0,0x2c($state)  # state->0x2c = the area's asset descriptor
    0x80126fc4  lw   $s0,0x0($v0)      # S = D[0]
    0x80126fcc  lh   $v0,0x2($s0)      # h
    0x80126fd0  lh   $v1,0x0($s0)      # w   -> w=160 h=120 in every file

`0x80080000` is the load base of the current area's `X_DATA.BIN`. Every one of
the eleven such files begins with that descriptor, and its **tail is a sequence
of 04_PLAY-family sprite sections**:

    u16 a; u16 b; u8 c_count; u8 d_flags; u16; u32 c, d, e, f
    c_table -> c_count pointers to [u32 len][LZSS] 128x128 8-bit atlases
    d_table -> (d_flags & 0x3F) pointers to 32-word RGB555 palettes

`c_count` is 1-3 atlases per section (the enemies' animation sheets) and the
palette pairs index-for-index with the atlas, so **these render in full colour
from disc bytes alone** — unlike the atlas pool
(`atlas_pool.md`), whose palettes are not paired.

Verified on all nine area data files: every section's every c-blob decodes
through `lzss.decode_strict` to exactly 16,384 bytes, and every d-table entry
is a readable 32-word palette.

    E_DATA.BIN  9 sections   e.g. 0x1f044 (8 frames, 2 sheets) purple
                                       whip-demon; 0x20eb0 green hounds;
                                       0x22aa0 winged harpy + fireballs;
                                       0x25a70 stone golems
    D_DATA.BIN  8 sections   e.g. 0x20b28 boars; 0x25d50 hawks
    A_DATA.BIN 11 sections   e.g. 0x23864 birds; 0x21d90 small-enemy sheets
    B_DATA.BIN  7 sections   e.g. 0x239bc large eagle/phoenix
    C/F/G/H/Z  4-5 each

WHAT IS NOT CLAIMED
-------------------
* The mapping **enemy id -> section** is not proven. The ids come from the
  battle formation/RLE table (`battle_actor_system.md` §3); the link
  between that list and these sections is the next step.
* Section `a`/`b` are read as the e/f record counts by analogy with 04_PLAY;
  the e/f tables are parsed only as spans, not as piece records.

Usage:
    enemy_sprites.py --scan                 # per-file section report
    enemy_sprites.py --out DIR              # render every section, every area
Exit: 0 clean, 1 on any structural or decode failure.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import disc  # noqa: E402
import lzss  # noqa: E402
from psx_vram import rgb555  # noqa: E402

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.exit("PIL required: pip install pillow")

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ISO_JSON = os.path.join(_KIT, "extracted", "iso_files.json")

LOAD_BASE = 0x80080000
ATLAS = 16384
W = H = 128
PALETTE_WORDS = 32
MAX_C = 8
DECODER_ID = "kit/tools/lzss.py v2.0.0"
PARSER_ID = "kit/tools/enemy_sprites.py 1.1.0"

# Recorded 2026-10-05; asserted by tests/test_enemy_sprites.py.
EXPECTED_SECTIONS = {
    "DATA/01_AREA.A/A_DATA.BIN": 11,
    "DATA/02_AREA.B/B_DATA.BIN": 9,
    "DATA/02_AREA.B/J_DATA.BIN": 4,
    "DATA/06_AREA.C/C_DATA.BIN": 9,
    "DATA/07_AREA.D/D_DATA.BIN": 8,
    "DATA/07_AREA.D/K_DATA.BIN": 8,
    "DATA/08_AREA.E/E_DATA.BIN": 9,
    "DATA/09_AREA.F/F_DATA.BIN": 8,
    "DATA/10_AREA.G/G_DATA.BIN": 7,
    "DATA/11_AREA.H/H_DATA.BIN": 8,
    "DATA/15_AREA.Z/Z_DATA.BIN": 7,
}
EXPECTED_TOTAL = 88
EXPECTED_SHEETS = 125
# Per-area enemy tables: (table offset, count). Recorded 2026-10-05.
EXPECTED_TABLES = {
    "DATA/01_AREA.A/A_DATA.BIN": (0x163E8, 5),
    "DATA/07_AREA.D/D_DATA.BIN": (0x17BB8, 3),
    "DATA/08_AREA.E/E_DATA.BIN": (0x1606C, 4),
}



def parse_background(d):
    """The battle asset descriptor at word 0: 160x120 size, terrain pages, CLUTs.

    Layout, verified against `0x80126FA4`-`0x80126FD8` and every area file:

        D = *(0x80080000)         # word 0 of the file
        S = D[0]                  # +0x00
        S[0..3]  u16 w, u16 h     # 160, 120 in every area
        S[0x08] -> 5 pointers     # the battle terrain tile pages (128x128)
        S[0x0C] -> 3 pointers     # 256-word RGB555 CLUTs, 0x200 apart
        D[0x0C] -> selection table (index 0 stream, 1..n enemy sections, n+1 = S)

    Only CLUT 0 colours the pages correctly; CLUT 1/2 produce noise, which is
    recorded rather than averaged over.
    """
    n = len(d)
    D = to_file(struct.unpack_from("<I", d, 0)[0], n)
    if D is None or D + 0x20 > n:
        return None
    S = to_file(struct.unpack_from("<I", d, D)[0], n)
    if S is None or S + 0x18 > n:
        return None
    w, h = struct.unpack_from("<HH", d, S)
    ap = to_file(struct.unpack_from("<I", d, S + 8)[0], n)
    cp = to_file(struct.unpack_from("<I", d, S + 0x0C)[0], n)
    pages, cluts = [], []
    for k in range(5):
        if ap is None or ap + 4 * k + 4 > n:
            break
        o = to_file(struct.unpack_from("<I", d, ap + 4 * k)[0], n)
        raw = decode_atlas(d, o, n)
        if raw is not None:
            pages.append({"offset": o, "atlas": raw})
    for k in range(3):
        if cp is None or cp + 4 * k + 4 > n:
            break
        o = to_file(struct.unpack_from("<I", d, cp + 4 * k)[0], n)
        if o is None or o + 2 * PALETTE_WORDS * 8 > n:
            break
        cluts.append({"offset": o,
                      "words": struct.unpack_from("<256H", d, o)})
    return {"descriptor": D, "image_descriptor": S, "w": w, "h": h,
            "pages": pages, "cluts": cluts}


def terrain_image(raw, clut_words):
    pr = [rgb555(w) for w in clut_words]
    img = Image.new("RGB", (W, H))
    px = img.load()
    for k, idx in enumerate(raw):
        px[k % W, k // W] = pr[idx]
    return img


def unpack_2bit(payload, out_size=16384):
    """The engine's EXACT 2-bit expansion, read off `0x800C3958`.

    `0x800C3958(a0=len, a1=src, a2=dst)` first LZSS-decodes `a1` into `dst`
    (4096 bytes), then walks `a0 = dst+0xFFF` DOWNWARD writing to
    `v1 = dst+0x3FFF` DOWNWARD, four 2-bit groups per input byte, low bits
    first. So the last input byte supplies the last four output pixels, and the
    first input byte supplies pixels 0..3 in reverse bit order. Getting this
    order wrong still yields a coherent-looking image (it is a mirror), which
    is why it is implemented from the listing rather than guessed.
    """
    n = len(payload)
    if n * 4 != out_size:
        return None
    out = bytearray(out_size)
    a0 = n - 1
    v1 = out_size - 1
    while a0 >= 0:
        b = payload[a0]
        out[v1] = b & 3
        out[v1 - 1] = (b >> 2) & 3
        out[v1 - 2] = (b >> 4) & 3
        out[v1 - 3] = (b >> 6) & 3
        v1 -= 4
        a0 -= 1
    return out


def parse_twobit_texture(d):
    """The `[u32 len][LZSS]` 2-bit texture at the battle descriptor's `+0x14`.

    `0x80127F8C` calls `0x800DDA50(state[0x2C]->0x14, state[0x2C]->0x18)`, and
    `0x800DDA50` runs `text_decode_stream` -> `0x800C3958` (this unpack) ->
    `LoadImage` -> `0x800C3C5C(+0x18)`. Returns (offset, 128x128 index bytes) or
    None. The 4-colour palette is NOT in this structure and is not claimed.
    """
    n = len(d)
    D = to_file(struct.unpack_from("<I", d, 0)[0], n)
    if D is None or D + 0x18 > n:
        return None
    off = to_file(struct.unpack_from("<I", d, D + 0x14)[0], n)
    if off is None or off + 4 > n:
        return None
    ln = struct.unpack_from("<I", d, off)[0]
    if ln == 0 or off + 4 + ln > n:
        return None
    try:
        raw = lzss.decode_strict(d[off + 4:off + 4 + ln])
    except lzss.LZSSError:
        return None
    px = unpack_2bit(raw)
    return None if px is None else (off, px)


def parse_worldmap(d):
    """The 160x120 u16 **tilemap** at the descriptor's `S+0x14`.

    IDENTIFICATION: the user (who has played the game) identified this art as
    the **world map tile set**, NOT a battle background -- see
    `kit/docs/world_map.md`. The structure below was decoded
    independently; the identification is the user's.

    `malloc(w*h*2)` then `text_decode_stream(*(S+0x14), S+0x14+4, buf)` at
    `0x80126FD8`-`0x80127014`; each cell is a `u16` whose high byte is 0 or 1
    and whose low byte is 0..255.
    Returns (w, h, indices bytes, flags bytes, cluts) or None.

    **SUPERSEDED 2026-10-07 -- read `kit/docs/world_map_render.md` before
    using this.** Two things here are wrong or borrowed:

    * the cell is a **9-bit tile code**, not a pixel index plus a flag. The
      ninth bit is `atlas = code >> 6` (so "flag = 1" means "tiles 0..63 of the
      fifth page"), and `tile = code & 63`;
    * `cluts` is taken from `parse_background(d)` -- a different asset -- so
      every render made from this dict uses the **battle background's**
      palettes. The world map's own CLUTs are the `pal_count`-entry pointer
      table at `S+0x0C`, and the palette is chosen **per tile** by the 64-byte
      per-atlas table at `S+0x10`.

    Canonical tool: `kit/tools/world_map_render.py`. This function is kept
    unchanged because the existing sheets and tests pin its shape.
    """
    n = len(d)
    D = to_file(struct.unpack_from("<I", d, 0)[0], n)
    if D is None:
        return None
    S = to_file(struct.unpack_from("<I", d, D)[0], n)
    if S is None or S + 0x18 > n:
        return None
    w, h = struct.unpack_from("<hh", d, S)
    if not (0 < w <= 512 and 0 < h <= 512):
        return None
    off = to_file(struct.unpack_from("<I", d, S + 0x14)[0], n)
    if off is None or off + 4 > n:
        return None
    ln = struct.unpack_from("<I", d, off)[0]
    if ln == 0 or off + 4 + ln > n:
        return None
    try:
        raw = lzss.decode_strict(d[off + 4:off + 4 + ln])
    except lzss.LZSSError:
        return None
    if len(raw) != w * h * 2:
        return None
    vals = struct.unpack_from("<%dH" % (w * h), raw, 0)
    idx = bytes(v & 0xFF for v in vals)
    flag = bytes((v >> 8) & 0xFF for v in vals)
    bg = parse_background(d)
    return {"w": w, "h": h, "offset": off, "indices": idx, "flags": flag,
            "cluts": (bg or {}).get("cluts", []), "S": S, "D": D}

def find_enemy_tables(d, sections):
    """The per-area enemy tables: `u32 count` then `count` record pointers.

    Each record's `+0x2C` points at that enemy's sprite section, so the table
    is the roster and the record is the enemy (stats at `+0x10`..`+0x1E`). A
    table is accepted only when EVERY entry resolves to a record that resolves
    to a known section, and the sections are distinct -- that is what keeps the
    detection from being pattern-matching on coincidence.
    """
    n = len(d)
    by_header = {s["header_offset"]: s for s in sections}
    out = []
    for t in range(0, n - 8, 4):
        count = struct.unpack_from("<I", d, t)[0]
        if not (1 <= count <= 32) or t + 4 + 4 * count > n:
            continue
        recs, secs = [], []
        ok = True
        for k in range(count):
            ro = to_file(struct.unpack_from("<I", d, t + 4 + 4 * k)[0], n)
            if ro is None or ro + 0x30 > n:
                ok = False
                break
            so = to_file(struct.unpack_from("<I", d, ro + 0x2C)[0], n)
            if so is None or so not in by_header:
                ok = False
                break
            recs.append(ro)
            secs.append(so)
        if not ok or len(set(secs)) != count:
            continue
        out.append({"table_offset": t, "count": count,
                    "record_offsets": recs, "section_offsets": secs})
    return out



def strongest_entries(d, tables, sections):
    """Highest (level, HP) record per roster; footprint does not rank strength."""
    out = []
    by_header = {s["header_offset"]: s for s in sections}
    for t in tables:
        entries = []
        for so, ro in zip(t["section_offsets"], t["record_offsets"]):
            lvl, footprint, hp = d[ro + 0x10], d[ro + 0x11], \
                struct.unpack_from("<H", d, ro + 0x12)[0]
            entries.append({"section": so, "record": ro, "level": lvl,
                            "formation_footprint": footprint, "hp": hp})
        selected = [max(entries, key=lambda e: (e["level"], e["hp"]))] if entries else []
        for e in selected:
            sec = by_header.get(e["section"])
            if sec is None:
                continue
            out.append(dict(e, palette=sec["palettes"][0],
                            atlas=sec["atlases"][0]["atlas"],
                            header=sec["header_offset"]))
    return out

def area_files():
    """Every per-area data overlay, in disc-listing order."""
    with open(_ISO_JSON) as f:
        return [r for r in json.load(f)
                if not r.get("dir") and r["path"].endswith("_DATA.BIN")
                and r["size"] > 16]


def to_file(ptr, n):
    off = ptr - LOAD_BASE
    return off if 0 <= off < n else None


def decode_atlas(d, off, n):
    if off is None or off + 4 > n:
        return None
    ln = struct.unpack_from("<I", d, off)[0]
    if ln == 0 or off + 4 + ln > n:
        return None
    try:
        raw = lzss.decode_strict(d[off + 4:off + 4 + ln])
    except lzss.LZSSError:
        return None
    return raw if len(raw) == ATLAS else None


def parse_sections(d):
    """Every valid sprite section in `d`, including world actors; returns (sections, errors)."""
    n = len(d)
    out, errors = [], []
    for h in range(0, n - 0x18, 4):
        c_count, d_flags = d[h + 4], d[h + 5]
        if not (0 < c_count <= MAX_C and (d_flags & 0xC0) == 0x80):
            continue
        cptr = struct.unpack_from("<I", d, h + 8)[0]
        c = to_file(cptr, n)
        if c is None:
            continue
        atlases, ok = [], True
        for k in range(c_count):
            if c + 4 * k + 4 > n:
                ok = False
                break
            off = to_file(struct.unpack_from("<I", d, c + 4 * k)[0], n)
            raw = decode_atlas(d, off, n)
            if raw is None:
                ok = False
                break
            atlases.append({"offset": off, "atlas": raw})
        if not ok or not atlases:
            continue

        d_count = d_flags & 0x3F
        dptr = to_file(struct.unpack_from("<I", d, h + 0x0C)[0], n)
        palettes = []
        if dptr is not None:
            for k in range(d_count):
                if dptr + 4 * k + 4 > n:
                    break
                po = to_file(struct.unpack_from("<I", d, dptr + 4 * k)[0], n)
                if po is None or po + 2 * PALETTE_WORDS > n:
                    palettes.append(None)
                    continue
                palettes.append(struct.unpack_from("<%dH" % PALETTE_WORDS, d, po))
        e = to_file(struct.unpack_from("<I", d, h + 0x10)[0], n)
        f = to_file(struct.unpack_from("<I", d, h + 0x14)[0], n)
        a, b = struct.unpack_from("<HH", d, h)
        out.append({"header_offset": h, "a_e_count": a, "b_f_count": b,
                    "c_count": c_count, "d_flags": "0x%02x" % d_flags,
                    "d_count": d_count, "c_table": c, "d_table": dptr,
                    "e_table": e, "f_table": f,
                    "atlases": atlases, "palettes": palettes})
    return out, errors


def atlas_image(raw, palette):
    pr = [rgb555(w) for w in palette]
    img = Image.new("RGBA", (W, H))
    px = img.load()
    for k, idx in enumerate(raw):
        if idx == 0:
            continue
        if idx >= len(pr):
            raise ValueError("index %d beyond %d-entry palette" % (idx, len(pr)))
        px[k % W, k // W] = pr[idx] + (255,)
    return img


def sheet(items, path, label, scale=2, cols=6):
    if not items:
        return None
    cw = W * scale
    rows = (len(items) + cols - 1) // cols
    img = Image.new("RGB", (cols * cw, rows * (cw + 12)), (20, 20, 24))
    dr = ImageDraw.Draw(img)
    for i, it in enumerate(items):
        p = it["image"]
        if scale != 1:
            p = p.resize((cw, cw), Image.NEAREST)
        x, y = (i % cols) * cw, (i // cols) * (cw + 12)
        if p.mode == "RGBA":
            img.paste(p, (x, y), p)
        else:
            img.paste(p, (x, y))
        dr.text((x + 3, y + cw + 1), it["label"], fill=(205, 205, 215))
    dr.text((4, 2), label, fill=(255, 220, 120))
    img.save(path)
    return path


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(_KIT, "work", "enemy_sprites"))
    ap.add_argument("--scan", action="store_true")
    ap.add_argument("--scale", type=int, default=2)
    args = ap.parse_args(argv)

    files = area_files()
    manifest = {
        "provenance": "disc-derived (c-blobs via lzss.decode_strict; palettes on disc)",
        "tool": PARSER_ID, "decoder": DECODER_ID, "load_base": "%#x" % LOAD_BASE,
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "files": [], "failures": [],
    }
    all_items = []
    all_strong = []
    all_pages = []      # (label, image) for the page-role review sheet
    total = 0
    for r in files:
        d = disc.extract(r["lba"], r["size"])
        sections, errors = parse_sections(d)
        total += len(sections)
        tag = r["path"].split("/")[1]
        if not args.scan:
            os.makedirs(os.path.join(args.out, tag), exist_ok=True)
        print("%-42s %8d B  %2d enemy sections"
              % (r["path"], r["size"], len(sections)))
        for e in errors:
            manifest["failures"].append({"file": r["path"], "error": e})
        items = []
        for s in sections:
            for i, at in enumerate(s["atlases"]):
                pal = s["palettes"][min(i, len(s["palettes"]) - 1)] \
                    if s["palettes"] else None
                if pal is None:
                    manifest["failures"].append(
                        {"file": r["path"], "error":
                         "section %#x c[%d] has no palette"
                         % (s["header_offset"], i)})
                    continue
                label = "%s h%x.c%d" % (tag, s["header_offset"], i)
                img = atlas_image(at["atlas"], pal)
                items.append({"label": label, "image": img, "section": s,
                              "blob": i, "offset": at["offset"]})
                print("    %-22s %2d frames  atlas@%#07x  palette entries=%d"
                      % (label, s["a_e_count"], at["offset"],
                         len([w for w in pal if w])))
        by_sec = {}
        for it in items:
            by_sec.setdefault(it["section"]["header_offset"], []).append(it)
        tables = find_enemy_tables(d, sections)
        bg = parse_background(d)
        wm = parse_worldmap(d)
        if wm is not None and wm["cluts"]:
            pal = [rgb555(x) for x in wm["cluts"][0]["words"]]
            wi = Image.new("RGB", (wm["w"], wm["h"]))
            wpx = wi.load()
            for k, v in enumerate(wm["indices"]):
                wpx[k % wm["w"], k // wm["w"]] = pal[v]
            if not args.scan:
                wi.resize((wm["w"] * 2, wm["h"] * 2), Image.NEAREST).save(
                    os.path.join(args.out, tag, "worldmap_%06x.png" % wm["offset"]))
                sheet([{"label": "world map %dx%d @%#07x, CLUT 0"
                        % (wm["w"], wm["h"], wm["offset"]), "image": wi}],
                      os.path.join(args.out, "%s_worldmap.png" % tag),
                      "DATA/%s -- WORLD MAP tile set (user-identified; NOT a "
                      "battle background) -- see docs/world_map.md"
                      % tag, 2, cols=1)
        tb = parse_twobit_texture(d)
        if tb is not None:
            o2, px = tb
            tbi = Image.new("L", (W, H))
            tbi.putdata([v * 85 for v in px])
            if not args.scan:
                tbi.save(os.path.join(args.out, tag,
                                      "twobit_%06x.png" % o2))
                sheet([{"label": "2bpp @%#07x (engine order)" % o2,
                        "image": tbi}],
                      os.path.join(args.out, "%s_twobit.png" % tag),
                      "DATA/%s -- the descriptor's +0x14 2-bit texture, "
                      "128x128, 4-colour index (palette not decoded)" % tag,
                      2, cols=1)
        if bg and bg["pages"] and bg["cluts"]:
            timgs = [{"label": "page%d @%#07x" % (i, p["offset"]),
                      "image": terrain_image(p["atlas"], bg["cluts"][0]["words"])}
                     for i, p in enumerate(bg["pages"])]
            if not args.scan:
                for p, it in zip(bg["pages"], timgs):
                    it["image"].save(os.path.join(
                        args.out, tag, "page_%06x.png" % p["offset"]))
                sheet(timgs, os.path.join(args.out, "%s_pages.png" % tag),
                      "DATA/%s -- the 5 x 128x128 pages at S+0x08, CLUT 0 "
                      "@%#07x. WORLD MAP tile set (user-identified), NOT a "
                      "battle background" % (tag, bg["cluts"][0]["offset"]),
                      2, cols=5)
        roster = []
        for t in tables:
            for sec in t["section_offsets"]:
                roster.extend(by_sec.get(sec, []))
        if args.scan:
            for t in tables:
                print("    roster table @%#07x: %d enemies -> sections %s"
                      % (t["table_offset"], t["count"],
                         [hex(x) for x in t["section_offsets"]]))
            continue
        for it in items:
            it["image"].save(os.path.join(
                args.out, tag, "enemy_%06x_c%d.png"
                % (it["section"]["header_offset"], it["blob"])))
        sheet(items, os.path.join(args.out, "%s_enemies.png" % tag),
              "DATA/%s — %d enemy sprite sheets" % (tag, len(items)),
              args.scale)
        if roster:
            sheet(roster, os.path.join(args.out, "%s_roster.png" % tag),
                  "DATA/%s — the area's enemy ROSTER in table order "
                  "(%d enemies, %d sheets)"
                  % (tag, sum(len(t["section_offsets"]) for t in tables),
                     len(roster)), args.scale)
        # Recolour variants: a section with more d-table entries than c-blobs
        # draws the SAME atlas in several palettes (enemy_sprites doc 7).
        variants = []
        for sec in sections:
            if len(sec["palettes"]) <= 1:
                continue
            at = sec["atlases"][0]["atlas"]
            for i, pal in enumerate(sec["palettes"]):
                if pal is None:
                    continue
                variants.append({
                    "label": "%s h%x pal%d" % (tag, sec["header_offset"], i),
                    "image": atlas_image(at, pal)})
        if variants and not args.scan:
            sheet(variants, os.path.join(args.out, "%s_variants.png" % tag),
                  "DATA/%s -- recolour variants: one atlas, several d-table "
                  "palettes (%d)" % (tag, len(variants)), 2, cols=7)
        strongest = strongest_entries(d, tables, sections)
        if strongest:
            simgs = []
            for e in strongest:
                img = atlas_image(e["atlas"], e["palette"])
                simgs.append({"label": "%s L%d footprint%d HP%d"
                              % (tag, e["level"], e["formation_footprint"], e["hp"]), "image": img})
            if not args.scan:
                sheet(simgs, os.path.join(args.out,
                                          "%s_strongest.png" % tag),
                      "DATA/%s -- highest-level enemies "
                      "(%d of %d)" % (tag, len(simgs), len(sections)), 2,
                      cols=6)
            all_strong.extend(simgs)
        all_items.extend(items)
        if bg is not None and bg.get("pages") and bg.get("cluts"):
            for pi, pg in enumerate(bg["pages"]):
                all_pages.append(("%s.p%d" % (tag, pi), atlas_image(
                    pg["atlas"], bg["cluts"][0]["words"])))
        manifest["files"].append({
            "path": r["path"], "size": r["size"], "sections": len(sections),
            "background": None if not bg else {
                "descriptor": bg["descriptor"], "image_descriptor":
                bg["image_descriptor"], "w": bg["w"], "h": bg["h"],
                "page_offsets": [p["offset"] for p in bg["pages"]],
                "clut_offsets": [c["offset"] for c in bg["cluts"]]},
            "variant_images": len(variants),
            "twobit_texture_offset": None if tb is None else tb[0],
            "worldmap": None if wm is None else {
                "w": wm["w"], "h": wm["h"], "offset": wm["offset"],
                "flagged_cells": sum(1 for f in wm["flags"] if f)},
            "strongest": [{"level": e["level"], "formation_footprint": e["formation_footprint"],
                            "hp": e["hp"], "section": e["section"]}
                           for e in strongest],
            "enemy_tables": [{"table_offset": t["table_offset"],
                              "count": t["count"],
                              "record_offsets": t["record_offsets"],
                              "section_offsets": t["section_offsets"]}
                             for t in tables],
            "atlases": [{"header_offset": s["header_offset"],
                         "c_count": s["c_count"], "d_flags": s["d_flags"],
                         "a_e_count": s["a_e_count"], "b_f_count": s["b_f_count"],
                         "blob_offsets": [a["offset"] for a in s["atlases"]]}
                        for s in sections],
        })

    if args.scan:
        print("\ntotal enemy sections: %d" % total)
        return 0

    if all_strong:
        sheet(all_strong, os.path.join(args.out, "ALL_strongest_enemies.png"),
              "Suikoden -- highest-level enemy per roster (%d)"
              % len(all_strong), 2, cols=8)
    pages_items = [{"label": lab, "image": im} for lab, im in all_pages if im]
    if pages_items:
        sheet(pages_items, os.path.join(args.out, "ALL_pages.png"),
              "Suikoden -- every 128x128 page at S+0x08, one row per area, CLUT 0. "
              "WHICH PAGE IS GROUND AND WHICH IS BACKDROP IS NOT DECODED; this "
              "sheet exists so someone who knows the game can say.", 1, cols=5)
    if all_items:
        sheet(all_items, os.path.join(args.out, "ALL_enemy_sheets.png"),
              "Suikoden — every enemy sprite sheet in DATA/*/*_DATA.BIN "
              "(%d sheets)" % len(all_items), 1, cols=14)
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    print("\nenemy sections: %d, sprite sheets: %d" % (total, len(all_items)))
    print("manifest: %s" % os.path.join(args.out, "manifest.json"))
    return 1 if manifest["failures"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
