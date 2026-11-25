#!/usr/bin/env python3
"""BATTLE.BIN section inventory and diagnostic byte-grid renders.

DATA/00_INIT/BATTLE.BIN has eight 04_PLAY-family sections and thirteen distinct
[u32 compressed_length][LZSS] blobs, each strictly decoding to 16,384 bytes.
Section 0 has three separate 32-entry RGB555 d-palettes. Sections 1..7 share
ten blobs and have no d-table palettes; their packed spell CLUT bank is embedded
in the right half of the last shared blob (file 0x1429C).

Spell setup 0x801205FC queues the ten blobs at texture counters 30..39.
The last upload is RECT(896,384,64,128) in VRAM words, covering the packed bank
at (928,384,32,128). Selected spell consumers use indexed4 sampling; transfer
size alone does not determine texture depth. See battle_effect_palette_source.md
and spell_effect_sources.py for source/consumer evidence and palette metadata.

This tool's 128x128 byte-grid pictures remain diagnostics, not composed native
spell pixels. Optional --oracle-clut colour comes from an existing field-state
VRAM capture, never accepted spell art. No output here promotes staging.

Usage: battle_bin.py --out DIR [--oracle-clut], or --sections.
Exit: 0 clean, 1 on structural/decode failure.
"""

# Diagnostic byte-grid renders are not native spell pixels; selected spell readers
# use indexed4/packed16 CLUTs (spell_effect_sources_port.md).
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

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.exit("PIL required: pip install pillow")

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ISO_JSON = os.path.join(_KIT, "extracted", "iso_files.json")
_ORACLE_VRAM = os.path.join(_KIT, "work", "vram_raw.bin")

DISC_PATH = "DATA/00_INIT/BATTLE.BIN"
LOAD_BASE = 0x800AA000
ATLAS_BYTES = 16384
ATLAS_W = ATLAS_H = 128
PALETTE_WORDS = 32
DECODER_ID = "kit/tools/lzss.py v2.0.0"

# Recorded 2026-10-05 and asserted by tests/test_battle_bin.py, so a framing or
# decoder regression cannot pass silently.
EXPECTED_SECTIONS = 8
EXPECTED_ATLASES = 13
EXPECTED_SECTION0 = {"c_count": 3, "d_flags": 0x83}


def battle_bin_lba():
    with open(_ISO_JSON) as f:
        for r in json.load(f):
            if r.get("path") == DISC_PATH:
                return r["lba"], r["size"]
    raise SystemExit("BATTLE.BIN not in kit/extracted/iso_files.json")


def _u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def _u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def to_file(ptr, size):
    """Absolute runtime pointer -> file offset, or None if it lands outside."""
    off = ptr - LOAD_BASE
    return off if 0 <= off < size else None


def palette_rgb888(words):
    return [(((w & 31) * 255 // 31), (((w >> 5) & 31) * 255 // 31),
             (((w >> 10) & 31) * 255 // 31)) for w in words]


def parse(*, need_atlases=True):
    """Parse BATTLE.BIN. Returns (sections, atlases, errors, source_bytes).

    `sections` mirrors the on-disc header contract exactly; `atlases` is the
    deduplicated pixel-blob pool in file order, each tagged with the palette
    the engine would use for it.
    """
    lba, size = battle_bin_lba()
    d = disc.extract(lba, size)
    errors = []

    masters = []
    for i in range(EXPECTED_SECTIONS):
        p = to_file(_u32(d, 4 * i), size)
        if p is None:
            errors.append("master[%d] pointer outside the file" % i)
        masters.append(p)

    sections, seen, atlases = [], {}, []
    for i, h in enumerate(masters):
        if h is None or h + 0x18 > size:
            sections.append({"index": i, "header_offset": h, "error": "out of file"})
            continue
        a, b = _u16(d, h), _u16(d, h + 2)
        c_count, d_flags = d[h + 4], d[h + 5]
        d_count = d_flags & 0x3F
        ptrs = {}
        for name, k in (("c", 0), ("d", 1), ("e", 2), ("f", 3)):
            ptrs[name] = to_file(_u32(d, h + 8 + 4 * k), size)
        sec = {"index": i, "header_offset": h, "a_e_count": a, "b_f_count": b,
               "c_count": c_count, "d_flags": "0x%02x" % d_flags,
               "d_count": d_count,
               "palette_path": "32-color CLUT" if (d_flags & 0xC0) else "256-color",
               "tables": ptrs, "atlas_offsets": [], "palette_offsets": []}

        palettes = []
        if d_flags & 0xC0:
            dp = ptrs["d"]
            if dp is None:
                errors.append("section %d: 32-colour path but no d-table" % i)
            else:
                for j in range(d_count):
                    po = to_file(_u32(d, dp + 4 * j), size)
                    if po is None or po + 2 * PALETTE_WORDS > size:
                        errors.append("section %d: d[%d] palette outside file" % (i, j))
                        palettes.append(None)
                        continue
                    words = struct.unpack_from("<%dH" % PALETTE_WORDS, d, po)
                    palettes.append(palette_rgb888(words))
                    sec["palette_offsets"].append(po)

        cp = ptrs["c"]
        if cp is None:
            errors.append("section %d: no c-table" % i)
            sections.append(sec)
            continue
        for j in range(c_count):
            eo = to_file(_u32(d, cp + 4 * j), size)
            if eo is None:
                errors.append("section %d: c[%d] pointer outside file" % (i, j))
                continue
            ln = _u32(d, eo)
            if ln == 0 or eo + 4 + ln > size:
                errors.append("section %d: c[%d] length %d out of range" % (i, j, ln))
                continue
            sec["atlas_offsets"].append(eo)
            if eo in seen:
                seen[eo]["sections"].append(i)
                continue
            if not need_atlases:
                seen[eo] = {"offset": eo, "sections": [i]}
                continue
            try:
                raw = lzss.decode_strict(d[eo + 4:eo + 4 + ln])
            except lzss.LZSSError as exc:
                errors.append("section %d: c[%d] decode failed: %s" % (i, j, exc))
                continue
            if len(raw) != ATLAS_BYTES:
                errors.append("section %d: c[%d] decoded to %d bytes, expected %d"
                              % (i, j, len(raw), ATLAS_BYTES))
                continue
            rec = {"offset": eo, "compressed_len": ln, "atlas": raw,
                   "sections": [i], "palette": None, "palette_offset": None}
            # Pair c-blob j with d-palette j on the 32-colour path; the
            # 04_PLAY processor walks the two tables in lockstep.
            if palettes and j < len(palettes):
                rec["palette"] = palettes[j]
                rec["palette_offset"] = (sec["palette_offsets"][j]
                                         if j < len(sec["palette_offsets"]) else None)
            seen[eo] = rec
            atlases.append(rec)
        sections.append(sec)
    return sections, atlases, errors, d


def classify(atlas):
    hi = max(atlas)
    return ("32-colour" if hi < 64 else "256-colour"), hi, len(set(atlas))


def render(atlas, palette=None, transparent_zero=True):
    img = Image.new("RGBA", (ATLAS_W, ATLAS_H))
    px = img.load()
    for k, idx in enumerate(atlas):
        x, y = k % ATLAS_W, k // ATLAS_W
        if palette is None:
            px[x, y] = (idx, idx, idx, 255)
        elif idx == 0 and transparent_zero:
            continue
        else:
            px[x, y] = palette[idx] + (255,)
    return img


def oracle_clut(row=0x1E4):
    """The existing VRAM capture's CLUT row — ORACLE COLOUR, not disc bytes."""
    import numpy as np
    v = np.fromfile(_ORACLE_VRAM, dtype="<u2").reshape(512, 1024)
    return palette_rgb888([int(x) for x in v[row, 256:256 + 256]])


def sheet(atlases, palette_for, scale, label):
    cols = 4
    cw = ATLAS_W * scale
    rows = (len(atlases) + cols - 1) // cols
    out = Image.new("RGB", (cols * cw, rows * (cw + 14)), (22, 22, 26))
    dr = ImageDraw.Draw(out)
    for i, s in enumerate(atlases):
        pal = palette_for(s)
        img = render(s["atlas"], pal).convert("RGB")
        if scale != 1:
            img = img.resize((cw, cw), Image.NEAREST)
        x, y = (i % cols) * cw, (i // cols) * (cw + 14)
        out.paste(img, (x, y))
        dr.text((x + 3, y + cw + 1),
                "+%#06x  %s  %s  max=%d n=%d"
                % (s["offset"], s["palette_path"], "%#x" % s["palette_offset"]
                   if s.get("palette_offset") is not None else "no palette",
                   s["max_index"], s["distinct"]),
                fill=(200, 200, 210))
    dr.text((4, 2), label, fill=(255, 220, 120))
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(_KIT, "work", "battle_bin"))
    ap.add_argument("--oracle-clut", action="store_true",
                    help="also render effect sheets with the VRAM oracle CLUT")
    ap.add_argument("--sections", action="store_true",
                    help="print the section/table structure and exit")
    ap.add_argument("--scale", type=int, default=2)
    args = ap.parse_args(argv)

    sections, atlases, errors, d = parse(need_atlases=not args.sections)
    for sec in sections:
        print("section %d @%#06x  a=%3d b=%3d c=%2d d_flags=%s d_count=%d  %s"
              % (sec["index"], sec.get("header_offset") or 0, sec.get("a_e_count", -1),
                 sec.get("b_f_count", -1), sec.get("c_count", -1),
                 sec.get("d_flags", "-"), sec.get("d_count", -1),
                 sec.get("palette_path", "-")))
        print("    tables %s" % {k: (v if v is None else hex(v))
                                 for k, v in sec.get("tables", {}).items()})
        print("    atlases %s" % [hex(o) for o in sec.get("atlas_offsets", [])])
        print("    palettes %s" % [hex(o) for o in sec.get("palette_offsets", [])])
    print("distinct atlas blobs: %d, sections: %d"
          % (len(atlases) or len({o for s in sections
                                  for o in s.get("atlas_offsets", [])}),
             len(sections)))
    if errors:
        for e in errors:
            print("ERROR %s" % e)

    ok = (len(sections) == EXPECTED_SECTIONS
          and not errors
          and (args.sections or len(atlases) == EXPECTED_ATLASES))
    if args.sections:
        return 0 if not errors else 1

    for s in atlases:
        path, hi, distinct = classify(s["atlas"])
        s["palette_path"] = path
        s["max_index"] = hi
        s["distinct"] = distinct

    os.makedirs(os.path.join(args.out, "index"), exist_ok=True)
    os.makedirs(os.path.join(args.out, "sheets"), exist_ok=True)
    manifest = {
        "provenance": "disc-derived",
        "source": {"path": DISC_PATH, "lba": battle_bin_lba()[0],
                   "size": battle_bin_lba()[1]},
        "decoder": DECODER_ID,
        "atlas_bytes": ATLAS_BYTES,
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "sections": sections,
        "atlases": [],
    }
    for s in atlases:
        i = render(s["atlas"]).convert("RGB")
        i.save(os.path.join(args.out, "index", "atlas_%06x_index.png" % s["offset"]))
        if s.get("palette") is not None:
            render(s["atlas"], s["palette"]).convert("RGB").save(
                os.path.join(args.out, "sheets",
                             "atlas_%06x_discpal.png" % s["offset"]))
        manifest["atlases"].append({
            "offset": s["offset"], "compressed_len": s["compressed_len"],
            "sections": s["sections"], "palette_path": s["palette_path"],
            "palette_offset": s["palette_offset"],
            "max_index": s["max_index"], "distinct_indices": s["distinct"],
        })

    disc_pal = [s for s in atlases if s.get("palette") is not None]
    nopal = [s for s in atlases if s.get("palette") is None]
    if disc_pal:
        sheet(disc_pal, lambda s: s["palette"], args.scale,
              "BATTLE.BIN sections 0 — DISC-DERIVED palettes").save(
            os.path.join(args.out, "sheets", "disc_palette_colour.png"))
        print("sheet: sheets/disc_palette_colour.png (%d planes)" % len(disc_pal))
    sheet(nopal, lambda s: None, args.scale,
          "BATTLE.BIN 256-colour planes — INDEX PLANES, no on-disc palette"
          ).save(os.path.join(args.out, "sheets", "index_planes.png"))
    print("sheet: sheets/index_planes.png (%d planes)" % len(nopal))

    if args.oracle_clut and nopal:
        clut = oracle_clut()
        sheet(nopal, lambda s: clut, args.scale,
              "ORACLE COLOUR (kit/work/vram_raw.bin CLUT row 0x1e4) — NOT "
              "disc-derived; identification only").save(
            os.path.join(args.out, "sheets", "ORACLE_PALETTE_colour.png"))
        manifest["oracle_colour"] = ("kit/work/vram_raw.bin CLUT row 0x1e4 at "
                                     "VRAM x=256; identification only")
        print("sheet: sheets/ORACLE_PALETTE_colour.png")

    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    print("manifest: %s" % os.path.join(args.out, "manifest.json"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
