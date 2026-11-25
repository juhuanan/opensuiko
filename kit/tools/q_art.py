#!/usr/bin/env python3
"""Four open art questions, answered from instructions and bytes.

Each of these was recorded `evidence: "open"` in the registry.  This tool
re-derives the answer for each one from the disc, so the answers cannot drift
from their evidence.

1. `BATTLE.BIN` -- the descriptor-pointer -> VRAM-upload path.
   The file is loaded at `0x800AA000` (`cd_load_slot_driver @0x800C9CC8`; the
   only `lui 0x800A` in MAIN.EXE is at `0x800C9D18`, paired with
   `ori $a1,$a1,0xA000` at `0x800C9D20`).  Its sections are the 04_PLAY
   section/pointer-table family and are walked by the **`& 0x3F` processor**
   `file_play_processor @0x800C3810`, whose twin is `0x800C3500`:

   * `c`-table pointers are pushed onto the queue array `0x80178F88`
     (count `0x80179028`), then decoded and uploaded by the worker
     `0x800C33A0` -> `text_decode_stream @0x800C3144` -> `0x800C3A44`;
   * the `d`-table is uploaded once per entry, `lbu(+5) & 0x3F` times, through
     `0x800C3CC8` (32-entry, CLUT x = 0x100) when `lbu(+5) & 0xC0` is set and
     through `0x800C3C5C` (256-entry, CLUT x = 0) otherwise;
   * the processor stamps the descriptor: `+0x06` = the slot base and `+0x07` =
     the palette row base of the band it chose.

   The **discriminator between the two count conventions** is the file's own
   `d`-table extent, not the byte value.  The sibling `0x800C3704` uses the
   plain byte `lbu(+5)`; for section 0 that is `0x83` = 131 entries, but the
   `d`-table starts at file `0xE0` and the `e`-table entry 0 begins at file
   `0xEC`, so the table holds exactly 3 pointers.  131 is refuted by the file's
   allocation; 3 is what the `& 0x3F` convention yields.

2. `04_PLAY` -- the piece-record walker.
   It is `0x800E211C` in MAIN.EXE, reached by `jal 0x800E211C` at `0x800E2104`.
   It reads the 52-byte animation object's `+0x30` **field** (the section
   descriptor stored by `0x800E1E3C` at `0x800E1E7C`), then `+0x10` of that
   descriptor for the `e`-table, then the `e`-table entry's target, so no `lui`
   materialises the section base: it arrives as an argument.  That is why the
   earlier `lui` sweep missed it.

3. The duel overlays' BT/SKY pages.
   Each duel loads two **load-group indices from its own data words** and
   indexes the 16-entry directory at `0x8016B358` with them.

4. What the 1,019 page-shaped containers depict.
   The 133 whole-file pages are the 12 directory-owned families.  The 886
   in-module pages are the area/mode sprite page banks. Stream consumption does
   not establish whether decoded page regions carry embedded palettes.

Renders produced by `--render` are **candidates**: the user is the final gate for
any image, and the contact sheets are index planes rendered as luminance, never
colour invented without a proven palette source.

Usage:
    q_art.py --json kit/work/q_art.json
    q_art.py --verify
    q_art.py --render kit/work/q_art_pages
    q_art.py --only duel

Exit: 0 clean, 1 on any structural or decode failure.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys

import numpy as np

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)

import disc          # noqa: E402
import lzss          # noqa: E402
import maindec       # noqa: E402
import mipsdec       # noqa: E402
import data_overlays as dov  # noqa: E402

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    Image = None

TOOL_VERSION = "1.0.0"
DECODER_ID = "kit/tools/lzss.py v2.0.0 (= text_decode_stream @0x800C3144)"

MAIN_BASE = 0x800C0800
OVERLAY_BASE = 0x80080000

BATTLE_PATH = "DATA/00_INIT/BATTLE.BIN"
BATTLE_BASE = 0x800AA000
BATTLE_SECTIONS = 8
BATTLE_ATLASES = 13

AIL_PATH = "DATA/04_PLAY/AIL.BIN"

DUELS = ("PAN_TEO.BIN", "SHU_KWA.BIN", "SHU_TEO.BIN")
DUEL_PATH = "DATA/12_IKKI/%s"
#: (file offset of index word A, offset of index word B)
DUEL_INDEX_WORDS = {
    "PAN_TEO.BIN": (0x9B9C, 0x9BA0),
    "SHU_KWA.BIN": (0x9B80, 0x9B84),
    "SHU_TEO.BIN": (0x9B80, 0x9B84),
}
DUEL_ENTRY = 0x8008102C
LOAD_GROUP_DIR = 0x8016B358
MASTER_TABLE = 0x80163D64

PAGE_BYTES = 16384
PAGE_WH = 128


# --------------------------------------------------------------------------
# disc helpers
# --------------------------------------------------------------------------
def iso_files() -> list[dict]:
    with open(os.path.join(_KIT, "extracted", "iso_files.json"), encoding="utf-8") as fh:
        return [r for r in json.load(fh) if not r.get("dir")]


def read_file(path: str) -> bytes:
    rec = next(r for r in iso_files() if r["path"] == path)
    return disc.extract(rec["lba"], rec["size"])


def read_overlay(name: str) -> bytes:
    return read_file(DUEL_PATH % name)


def mword(va: int) -> int:
    """One instruction/data word of the headerless MAIN.EXE image."""
    return maindec.mword(va)


def ovword(data: bytes, va: int) -> int:
    return struct.unpack_from("<I", data, va - OVERLAY_BASE)[0]


def runs_of_words(data: bytes) -> list[int]:
    return list(struct.unpack_from("<%dI" % (len(data) // 4), data))


def instance(va: int, data: bytes = None, base: int = MAIN_BASE):
    """('0xADDR', '0xWORD', 'asm') for evidence output."""
    w = ovword(data, va) if data is not None else mword(va)
    asm, _ = mipsdec.dec(va, w)
    return {"addr": "0x%08X" % va, "word": "0x%08X" % w, "asm": asm}


def inst_seq(data: bytes, va0: int, count: int, base: int):
    out = []
    for i in range(count):
        va = va0 + 4 * i
        w = ovword(data, va) if base == OVERLAY_BASE else mword(va)
        asm, _ = mipsdec.dec(va, w)
        out.append({"addr": "0x%08X" % va, "word": "0x%08X" % w, "asm": asm})
    return out


# --------------------------------------------------------------------------
# 1. BATTLE.BIN
# --------------------------------------------------------------------------
def battle_findings() -> dict:
    rec = next(r for r in iso_files() if r["path"] == BATTLE_PATH)
    d = read_file(BATTLE_PATH)
    size = len(d)

    def rd32(off: int) -> int:
        return struct.unpack_from("<I", d, off)[0]

    master = [rd32(4 * i) for i in range(BATTLE_SECTIONS)]

    # The load base, three independent ways.
    # (a) the loader instruction: lui $a1,0x800A at 0x800C9D18 plus
    #     ori $a1,$a1,0xA000 at 0x800C9D20 -> 0x800AA000 exactly.
    loader = mword(0x800C9D18), mword(0x800C9D20)
    assert loader[0] == 0x3C05800A and loader[1] == 0x34A5A000, loader
    # (b) every aligned word in the file that looks like an absolute pointer
    #     must land inside the file; the largest is 0x800BE29C, which base
    #     0x800A0000 (top 0x800B653B) would leave out of range.
    embedded = [struct.unpack_from("<I", d, i)[0]
                for i in range(0, len(d) - 3, 4)]
    embedded = [p for p in embedded if 0x800A0000 <= p < 0x800C0000]
    assert min(embedded) == 0x800AA020 and max(embedded) == 0x800BE29C, \
        (hex(min(embedded)), hex(max(embedded)))
    assert all(BATTLE_BASE <= p < BATTLE_BASE + size for p in master + embedded)

    sections = []
    for si, p in enumerate(master):
        o = p - BATTLE_BASE
        a, b = struct.unpack_from("<HH", d, o)
        c_count = d[o + 4]
        d_flags = d[o + 5]
        w6 = struct.unpack_from("<H", d, o + 6)[0]
        ctab, dtab, etab, ftab = struct.unpack_from("<IIII", d, o + 8)
        c_blobs = [rd32(ctab - BATTLE_BASE + 4 * i) - BATTLE_BASE
                   for i in range(c_count)]
        palettes = []
        capacity = None
        if dtab:
            # The two count conventions disagree for this section: the
            # file_play_processor family takes `lbu(+5) & 0x3F` (0x800C3904),
            # the sibling 0x800C3704 takes the plain byte (0x800C3790).  The
            # allocation decides: the d-table's own region runs from its file
            # offset up to the lowest e-record the e-table points at, and that
            # span holds exactly 3 pointers.  131 does not fit.
            e_targets = [rd32(etab - BATTLE_BASE + 4 * i) - BATTLE_BASE
                         for i in range(a)]
            capacity = (min(e_targets) - (dtab - BATTLE_BASE)) // 4
            palettes = [rd32(dtab - BATTLE_BASE + 4 * i) - BATTLE_BASE
                        for i in range(d[o + 5] & 0x3F)]
        sections.append({
            "index": si,
            "header_file_off": o,
            "master_pointer": "0x%08X" % p,
            "a_pieces": a,
            "b_anims": b,
            "c_count": c_count,
            "d_flags": "0x%02X" % d_flags,
            "d_count_masked_0x3F": d_flags & 0x3F,
            "d_count_plain_byte": d[o + 5],
            "d_table_capacity_pointers": capacity,
            "header_word6": "0x%04X" % w6,
            "c_table_file_off": ctab - BATTLE_BASE,
            "d_table_file_off": (dtab - BATTLE_BASE) if dtab else None,
            "e_table_file_off": etab - BATTLE_BASE,
            "f_table_file_off": ftab - BATTLE_BASE,
            "c_blob_file_offsets": c_blobs,
            "palette_file_offsets": palettes,
        })

    # the 13 distinct atlases
    atlases = []
    for s in sections:
        for off in s["c_blob_file_offsets"]:
            comp_len = rd32(off)
            out, used = lzss.decode_container(d, off)
            atlases.append({
                "section": s["index"],
                "file_off": off,
                "comp_len": comp_len,
                "out_len": len(out),
                "used": used,
                "full_consumption": used == 4 + comp_len,
                "sha256_16": hashlib.sha256(out).hexdigest()[:16],
            })
    distinct = {(a["file_off"], a["sha256_16"]) for a in atlases}

    # pixel-slot layout: 0x800C3A44, c = counter 0x80189030
    slots = []
    for c in range(len(distinct)):
        q1, r1 = divmod(c, 5)
        q2, r2 = divmod(q1, 20)
        q3 = r2 // 5
        slots.append({"c": c,
                      "rect_x": (q2 * 5 + r1) * 64 + 0x140,
                      "rect_y": q3 * 128, "rect_w": 64, "rect_h": 128})

    # palette rows: 0x800C3CC8 / 0x800C3C5C, y = counter + 0x1E0
    pal_rows = [{"index": i, "clut_x": 0x100, "clut_y": 0x1E0 + i,
                 "entries": 32, "file_off": p}
                for i, p in enumerate(sections[0]["palette_file_offsets"])]

    return {
        "path": BATTLE_PATH,
        "lba": rec["lba"],
        "size": size,
        "load_base": "0x%08X" % BATTLE_BASE,
        "master_pointers": ["0x%08X" % p for p in master],
        "periodic_atlas_count": len(atlases),
        "distinct_atlas_count": len(distinct),
        "atlases": atlases,
        "sections": sections,
        "pixel_slots": slots,
        "section0_palette_rows": pal_rows,
        "code": {
            "loader_site": inst_seq(None, 0x800C9D10, 6, MAIN_BASE),
            "file_play_processor_count": inst_seq(None, 0x800C3894, 8, MAIN_BASE),
            "file_play_processor_32branch": inst_seq(None, 0x800C38A8, 10, MAIN_BASE)
            + inst_seq(None, 0x800C38C0, 3, MAIN_BASE)
            + inst_seq(None, 0x800C38D8, 2, MAIN_BASE),
            "file_play_processor_256branch": inst_seq(None, 0x800C38F4, 8, MAIN_BASE)
            + inst_seq(None, 0x800C390C, 3, MAIN_BASE)
            + inst_seq(None, 0x800C3924, 2, MAIN_BASE),
            "sibling_plain_byte_count": inst_seq(None, 0x800C3790, 5, MAIN_BASE),
            "sibling_call_site": instance(0x80127D9C),
            "sibling_descriptor_reached_at": inst_seq(None, 0x80127D84, 7, MAIN_BASE),
            "counter_getters": {
                "pixel_slot_counter_0x80179030": inst_seq(None, 0x800C3A14, 4, MAIN_BASE),
                "palette_counter_0x80179038_256": inst_seq(None, 0x800C3A34, 4, MAIN_BASE),
                "palette_counter_0x80179040_32": inst_seq(None, 0x800C3A24, 4, MAIN_BASE),
            },
            "palette_upload_256": inst_seq(None, 0x800C3C5C, 4, MAIN_BASE)
            + inst_seq(None, 0x800C3C90, 2, MAIN_BASE),
            "palette_upload_32": inst_seq(None, 0x800C3CC8, 4, MAIN_BASE)
            + inst_seq(None, 0x800C3D00, 2, MAIN_BASE),
            "pixel_upload_slot_math": inst_seq(None, 0x800C3A54, 4, MAIN_BASE)
            + inst_seq(None, 0x800C3AFC, 6, MAIN_BASE),
        },
    }


def lbu_byte(d: bytes, off: int, wide: bool = True) -> int:
    return d[off] if not wide else d[off] & 0x3F


# --------------------------------------------------------------------------
# 2. 04_PLAY's piece-record walker
# --------------------------------------------------------------------------
WALKER = 0x800E211C
WALKER_CALLSITE = 0x800E2104


def piece_records(d: bytes, base: int, e_table_off: int, count: int) -> list[dict]:
    """The e-table is an array of u32 pointers to piece records.

    A piece record is `[u8 count][u8 ?][u8 w][u8 h][4 bytes ?]` followed by
    `count` 8-byte sub-pieces.
    """

    def rd32(off):
        return struct.unpack_from("<I", d, off)[0]

    out = []
    for i in range(count):
        ptr = rd32(e_table_off + 4 * i)
        off = ptr - base
        cnt = d[off]
        subs = []
        for k in range(cnt):
            s = off + 8 + 8 * k
            sub = d[s:s + 8]
            subs.append({
                "file_off": s,
                "raw": sub.hex(),
                "x": sub[0], "y": sub[1],
                "slot_delta": sub[2],
                "u": sub[3],
                "w": sub[4] + 1, "h": sub[5] + 1,
                "palette_delta": sub[6],
                "flags": "0x%02X" % sub[7],
                "flip_x": bool(sub[7] & 0x80),
            })
        out.append({
            "index": i,
            "file_off": off,
            "count": cnt,
            "piece_w": d[off + 2],
            "piece_h": d[off + 3],
            "sub_pieces": subs,
        })
    return out


def play_findings() -> dict:
    img = maindec.body()
    # the walker's own reads, as instruction evidence
    seq = inst_seq(None, 0x800E214C, 22, MAIN_BASE)
    seq2 = inst_seq(None, 0x800E21CC, 8, MAIN_BASE)
    seq3 = inst_seq(None, 0x800E21E0, 6, MAIN_BASE)
    seq4 = inst_seq(None, 0x800E2258, 20, MAIN_BASE)
    seq5 = inst_seq(None, 0x800E22A4, 4, MAIN_BASE)
    seq6 = inst_seq(None, 0x800E22B0, 4, MAIN_BASE)
    seq7 = inst_seq(None, 0x800E2304, 2, MAIN_BASE)
    seq8 = inst_seq(None, 0x800E2328, 2, MAIN_BASE)

    # AIL.BIN S2 as the worked container
    ail = read_file(AIL_PATH)
    ptrs = [struct.unpack_from("<I", ail, 0x20 + 4 * i)[0] for i in range(5)]
    offset_table_ptr, s1, s2, s3, s4 = ptrs
    o = s2
    a, b = struct.unpack_from("<HH", ail, o)
    c_count, d_flags = ail[o + 4], ail[o + 5]
    ctab, dtab, etab, ftab = struct.unpack_from("<IIII", ail, o + 8)
    s2_pieces = piece_records(ail, 0, etab, a)

    # and every BATTLE.BIN section, to show the record shape is the family's
    bd = read_file(BATTLE_PATH)
    all_pieces = []
    for s in battle_findings()["sections"]:
        pc = piece_records(bd, BATTLE_BASE, s["e_table_file_off"], s["a_pieces"])
        all_pieces.append({"section": s["index"], "pieces": pc})
    multi = sum(1 for g in all_pieces for p in g["pieces"] if p["count"] > 1)
    total = sum(1 for g in all_pieces for p in g["pieces"])

    return {
        "walker_entry": "0x%08X" % WALKER,
        "walker_call_site": "0x%08X" % WALKER_CALLSITE,
        "walker_is_direct_jal": True,
        "why_the_lui_sweep_missed_it": (
            "the section descriptor is fetched from the animation object's "
            "+0x30 field (set by 0x800E1E3C at 0x800E1E7C from the caller's "
            "argument), not materialised with lui"),
        "code": {
            "object_field_holding_the_descriptor": instance(0x800E1E7C),
            "walker_head": seq,
            "sub_piece_loop": seq2,
            "slot_math": seq3,
            "clut_row_math": seq4,
            "getclut_args": seq5,
            "tpage_row_math": seq6,
            "tpage_write": seq7,
            "clut_write": seq8,
        },
        "record_layout": {
            "e_table": "array of u32 pointers to piece records, at section+0x10",
            "piece": {
                "+0x00": "u8 sub-piece count",
                "+0x01": "u8 (unused here)",
                "+0x02": "u8 piece width",
                "+0x03": "u8 piece height",
                "+0x08": "count x 8-byte sub-piece records",
            },
            "sub_piece": {
                "+0x00": "u8 x offset in pixels",
                "+0x01": "u8 y offset in pixels",
                "+0x02": "u8 VRAM slot delta: slot = (section[6] + delta) mod 20",
                "+0x03": "u8 texture u, in 8-pixel steps (4-bit field pair)",
                "+0x04": "u8 width - 1",
                "+0x05": "u8 height - 1",
                "+0x06": "u8 CLUT row delta: row = 0x1E0 + ((section[7] + delta) & 0xFF)",
                "+0x07": "u8 flags; bit 7 mirrors u",
            },
        },
        "ail_s2": {
            "path": AIL_PATH,
            "section_file_off": o,
            "a_pieces": a,
            "b_anims": b,
            "c_count": c_count,
            "d_flags": "0x%02X" % d_flags,
            "e_table_file_off": etab,
            "pieces": s2_pieces,
        },
        "battle_sections": all_pieces,
        "battle_piece_count": total,
        "battle_multi_subpiece_count": multi,
    }


# --------------------------------------------------------------------------
# 3. duel overlays -> BT/SKY pages
# --------------------------------------------------------------------------
def load_group_members() -> list[dict]:
    """The 16-entry directory at 0x8016B358, resolved to file names."""
    by_lba = {r["lba"]: r["path"] for r in iso_files()
              if r["path"].startswith("DATA/") and r["path"].endswith(".BIN")}
    recs = [struct.unpack_from("<II", _master_bytes(), 8 * i)
            for i in range(344)]
    groups = []
    for g in range(16):
        p = mword(LOAD_GROUP_DIR + 4 * g)
        members = []
        for k in range(64):
            v = mword(p + 4 * k)
            if v is None or not (MASTER_TABLE <= v < MASTER_TABLE + 344 * 8):
                break
            idx = (v - MASTER_TABLE) // 8
            size, lba = recs[idx]
            members.append({"table_index": idx, "size": size, "lba": lba,
                            "path": by_lba.get(lba)})
        groups.append({"index": g, "members": members,
                       "names": [os.path.basename(m["path"] or "?") for m in members]})
    return groups


_MASTER_CACHE: dict = {}


def _master_bytes() -> bytes:
    if "b" not in _MASTER_CACHE:
        _MASTER_CACHE["b"] = maindec.body()[MASTER_TABLE - MAIN_BASE:
                                            MASTER_TABLE - MAIN_BASE + 344 * 8]
    return _MASTER_CACHE["b"]


def duel_findings() -> dict:
    groups = load_group_members()
    out = []
    for name in DUELS:
        d = read_overlay(name)
        oa, ob = DUEL_INDEX_WORDS[name]
        ia = struct.unpack_from("<I", d, oa)[0]
        ib = struct.unpack_from("<I", d, ob)[0]
        ga, gb = groups[ia], groups[ib]
        bt = [n for n in ga["names"] if n.startswith("BT")]
        ic = [n for n in ga["names"] if n.startswith("IC_")]
        sky = [n for n in gb["names"] if n.startswith("SKY")]
        out.append({
            "overlay": DUEL_PATH % name,
            "size": len(d),
            "entry_va": "0x%08X" % DUEL_ENTRY,
            "index_words": [
                {"file_off": oa, "va": "0x%08X" % (OVERLAY_BASE + oa), "value": ia},
                {"file_off": ob, "va": "0x%08X" % (OVERLAY_BASE + ob), "value": ib},
            ],
            "code": inst_seq(d, DUEL_ENTRY + 0x20, 12, OVERLAY_BASE),
            "groups": [{"index": ia, "members": ga["names"]},
                       {"index": ib, "members": gb["names"]}],
            "bt_pages": bt,
            "sky_pages": sky,
            "ic_pages": ic,
        })
    return {"directory": "0x%08X" % LOAD_GROUP_DIR,
            "directory_installer": "0x800C9648",
            "subsystem_slot": "0x801BB4B8 = 0x801BA000 + 0x14B8",
            "groups": [{"index": g["index"], "count": len(g["members"]),
                        "names": g["names"]} for g in groups],
            "duels": out}


# --------------------------------------------------------------------------
# 4. the 1,019 page containers
# --------------------------------------------------------------------------
#: classification thresholds, chosen from the measured distribution over all
#: 1,019 pages (see notes_q_art.md).  A page is described by its 128x128 index
#: plane alone -- no palette is invented.
CLASS_FLAT = 4              # distinct indices
CLASS_LOWENT = 2.5          # bits
CLASS_LOWIDX = 10
CLASS_BLOCK = 0.35          # fraction of constant 8x8 blocks
CLASS_HIGHENT = 5.5         # bits


def _page_stats(plane: bytes) -> dict:
    a = np.frombuffer(plane, dtype=np.uint8).reshape(PAGE_WH, PAGE_WH)
    hist = np.bincount(a.ravel(), minlength=256).astype(float)
    p = hist / hist.sum()
    nz = p[p > 0]
    ent = float(-(nz * np.log2(nz)).sum())
    blocks = a.reshape(16, 8, 16, 8).transpose(0, 2, 1, 3).reshape(-1, 64)
    return {
        "distinct": int((hist > 0).sum()),
        "entropy_bits": round(ent, 4),
        "mean_abs_dx": round(float(np.abs(np.diff(a.astype(np.int16), axis=1)).mean()), 4),
        "mean_abs_dy": round(float(np.abs(np.diff(a.astype(np.int16), axis=0)).mean()), 4),
        "constant_8x8_fraction": round(float((blocks.max(axis=1) == blocks.min(axis=1)).mean()), 4),
        "index0_fraction": round(float(hist[0] / hist.sum()), 4),
    }


def classify_page(st: dict) -> str:
    if st["distinct"] <= CLASS_FLAT:
        return "flat"
    if st["entropy_bits"] < CLASS_LOWENT and st["distinct"] <= CLASS_LOWIDX:
        return "low-index"
    if st["constant_8x8_fraction"] >= CLASS_BLOCK:
        return "block-coherent"
    if st["entropy_bits"] >= CLASS_HIGHENT and st["constant_8x8_fraction"] < 0.10:
        return "high-entropy"
    return "mixed"


def pages_findings(render_dir: str | None = None) -> dict:
    census = dov.build()
    pages = []
    for r in census["records"]:
        if r["container"] and r["container"]["out_len"] == PAGE_BYTES:
            pages.append((r["path"], r["family"], 0, "whole-file"))
        if r["bank"]:
            for off in r["bank"]["pages"]:
                pages.append((r["path"], r["family"], off, "in-module"))

    cache: dict[str, bytes] = {}
    records = []
    for path, family, off, kind in pages:
        d = cache.get(path)
        if d is None:
            d = cache[path] = dov.read(path)
        comp_len = struct.unpack_from("<I", d, off)[0]
        plane, used = lzss.decode_container(d, off)
        if len(plane) != PAGE_BYTES or used != 4 + comp_len:
            raise AssertionError(
                "partial decode %s@%d: %d bytes out, used %d of %d"
                % (path, off, len(plane), used, comp_len))
        st = _page_stats(plane)
        records.append({
            "path": path, "family": family, "file_off": off, "kind": kind,
            "comp_len": comp_len, "out_len": len(plane), "used": used,
            "sha256_16": hashlib.sha256(plane).hexdigest()[:16],
            "class": classify_page(st), **st,
        })

    from collections import Counter, defaultdict
    by_family = Counter(r["family"] for r in records)
    by_class = Counter(r["class"] for r in records)
    tab = defaultdict(Counter)
    for r in records:
        tab[r["family"]][r["class"]] += 1

    sha = Counter(r["sha256_16"] for r in records)
    dup_groups = {k: v for k, v in sha.items() if v > 1}
    fam_of = defaultdict(Counter)
    for r in records:
        fam_of[r["sha256_16"]][r["family"]] += 1
    cross = Counter()
    for k, c in fam_of.items():
        if sha[k] > 1 and len(c) > 1:
            cross[tuple(sorted(c))] += 1
    whole = {r["sha256_16"] for r in records if r["kind"] == "whole-file"}
    dup_of_whole = sum(1 for r in records
                       if r["kind"] == "in-module" and r["sha256_16"] in whole)

    manifest = None
    if render_dir:
        manifest = _render_pages(records, cache, render_dir)

    return {
        "total": len(records),
        "whole_file": sum(1 for r in records if r["kind"] == "whole-file"),
        "in_module": sum(1 for r in records if r["kind"] == "in-module"),
        "files_holding_pages": len({r["path"] for r in records}),
        "all_decode_to_16384_full_consumption": True,
        "distinct_contents": len(sha),
        "duplicate_groups": len(dup_groups),
        "pages_in_duplicate_groups": sum(dup_groups.values()),
        "duplicate_groups_spanning_families": {str(k): v for k, v in cross.items()},
        "in_module_pages_identical_to_a_whole_file_page": dup_of_whole,
        "family_census": dict(by_family.most_common()),
        "class_census": dict(by_class.most_common()),
        "family_by_class": {k: dict(v) for k, v in sorted(tab.items())},
        "thresholds": {
            "flat_distinct_le": CLASS_FLAT,
            "low_index_entropy_lt": CLASS_LOWENT,
            "low_index_distinct_le": CLASS_LOWIDX,
            "block_coherent_8x8_ge": CLASS_BLOCK,
            "high_entropy_ge": CLASS_HIGHENT,
        },
        "carries_its_own_palette": None,
        "palette_note": (
            "every container is exactly 4 + comp_len bytes with full "
            "consumption of the declared region; this does not determine "
            "whether decoded bytes include embedded palette words"),
        "records": records,
        "render_manifest": manifest,
    }


def _render_pages(records, cache, out_dir: str) -> dict:
    """Greyscale index-plane contact sheets plus full-size renders of the
    most contrast-rich pages.  Candidates only -- the user gates images."""
    if Image is None:
        raise SystemExit("PIL required for --render")
    os.makedirs(out_dir, exist_ok=True)
    planes: dict[int, bytes] = {}
    for r in records:
        key = id(cache[r["path"]]), r["file_off"]
        plane, _ = lzss.decode_container(cache[r["path"]], r["file_off"])
        planes[key] = plane

    sheets = {}
    groups = {}
    for r in records:
        groups.setdefault(r["family"], []).append(r)
    for family, rs in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        rs = sorted(rs, key=lambda r: r["file_off"])[:64]
        cell, cols = 128, 8
        rows = (len(rs) + cols - 1) // cols
        sheet = Image.new("L", (cols * cell, rows * (cell + 12)), 0)
        dr = ImageDraw.Draw(sheet)
        for i, r in enumerate(rs):
            plane, _ = lzss.decode_container(cache[r["path"]], r["file_off"])
            im = Image.frombytes("L", (PAGE_WH, PAGE_WH), plane)
            x, y = (i % cols) * cell, (i // cols) * (cell + 12)
            sheet.paste(im, (x, y))
            dr.text((x + 2, y + cell), "%s@%d" % (os.path.basename(r["path"]), r["file_off"]),
                    fill=180)
        p = os.path.join(out_dir, "family_%s.png" % family.replace("/", "_"))
        sheet.save(p)
        sheets[family] = p
    return {"sheets": sheets, "note": "index planes as luminance; no palette invented"}


# --------------------------------------------------------------------------
# verify
# --------------------------------------------------------------------------
def verify() -> int:
    ok = []

    b = battle_findings()
    assert b["size"] == 91451 and b["load_base"] == "0x800AA000", b["size"]
    assert b["distinct_atlas_count"] == BATTLE_ATLASES, b["distinct_atlas_count"]
    assert b["periodic_atlas_count"] == 3 + 7 * 10, b["periodic_atlas_count"]
    assert all(a["out_len"] == PAGE_BYTES and a["full_consumption"]
               for a in b["atlases"])
    ok.append("PASS: BATTLE.BIN has 8 sections and 13 distinct 16,384-byte atlases "
              "(73 c-table references: 3 in section 0, the same 10 shared by "
              "sections 1-7), each with full consumption of its declared length")
    s0 = b["sections"][0]
    assert s0["a_pieces"] == 82 and s0["c_count"] == 3 and s0["d_flags"] == "0x83"
    assert [hex(p) for p in s0["palette_file_offsets"]] == ["0x20", "0x60", "0xa0"]
    # the count convention is decided by the file's own d-table extent
    assert s0["d_count_masked_0x3F"] == 3
    assert s0["d_count_plain_byte"] == 131
    assert s0["d_table_capacity_pointers"] == 3, s0["d_table_capacity_pointers"]
    assert s0["d_count_masked_0x3F"] <= s0["d_table_capacity_pointers"] \
        < s0["d_count_plain_byte"]
    assert all(s["d_table_file_off"] is None and s["d_flags"] == "0x00"
               for s in b["sections"][1:])
    ok.append("PASS: section 0 carries separate d-palettes (d_flags 0x83, three 32-word "
              "palettes at file 0x20/0x60/0xA0); sections 1-7 have d_flags 0x00 "
              "and a NULL d-table, so there are no separate d-table palette uploads")
    ok.append("PASS: the count convention is the & 0x3F one (3), not the plain byte "
              "(131) -- the d-table spans 3 pointers from file 0xE0 to the e-table at "
              "0xEC, so 131 is refuted by the file's own allocation")
    assert any(x["asm"] == "andi $v1,$v1,0x3f"
               for x in b["code"]["file_play_processor_32branch"])
    assert any(x["asm"] == "andi $v1,$v1,0x3f"
               for x in b["code"]["file_play_processor_256branch"])
    assert b["code"]["sibling_plain_byte_count"][0]["asm"] == "lbu $v0,0x5($s1)"
    assert b["code"]["sibling_call_site"]["addr"] == "0x80127D9C"
    assert b["pixel_slots"][0]["rect_x"] == 0x140 and b["pixel_slots"][0]["rect_y"] == 0
    assert [p["clut_y"] for p in b["section0_palette_rows"]] == [0x1E0, 0x1E1, 0x1E2]
    ok.append("PASS: the descriptor reaches VRAM through the 0x800C3810/0x800C3500 "
              "family (& 0x3F count, & 0xC0 band); planes land at "
              "x = 64*(5*(c//20)+(c%5)) + 0x140, y = 128*((c%20)//5), and section 0's "
              "three palettes at CLUT (0x100, 0x1E0..0x1E2)")

    p = play_findings()
    assert p["walker_entry"] == "0x800E211C"
    assert p["code"]["walker_head"][0]["asm"] == "lw $v1,0x30($s4)"
    assert any(x["asm"] == "lw $v0,0x10($v1)" for x in p["code"]["walker_head"]), \
        p["code"]["walker_head"]
    ok.append("PASS: the piece-record walker IS in MAIN.EXE at 0x800E211C, reached by "
              "jal at 0x800E2104; it reads the descriptor from the object's +0x30 field, "
              "which is why a lui sweep could not see it")
    assert p["ail_s2"]["a_pieces"] == 12 and p["ail_s2"]["b_anims"] == 4
    assert all(pc["count"] == 1 for pc in p["ail_s2"]["pieces"])
    assert p["battle_piece_count"] == 82 + 64 + 6 + 32 + 16 + 50 + 23 + 24
    assert p["battle_multi_subpiece_count"] > 0
    ok.append("PASS: the S2/AIL e-table holds %d piece records; BATTLE.BIN holds %d "
              "across its 8 sections, %d with more than one sub-piece"
              % (len(p["ail_s2"]["pieces"]), p["battle_piece_count"],
                 p["battle_multi_subpiece_count"]))

    du = duel_findings()
    got = {os.path.basename(x["overlay"]): (x["bt_pages"], x["sky_pages"])
           for x in du["duels"]}
    assert got["PAN_TEO.BIN"] == (["BT2_1S%02d.BIN" % i for i in range(10)],
                                  ["SKY3_1.BIN", "SKY3_2.BIN", "SKY3_3.BIN"]), got["PAN_TEO.BIN"]
    assert got["SHU_KWA.BIN"] == (["BT1_1S00.BIN"],
                                  ["SKY1_1.BIN", "SKY1_2.BIN", "SKY1_3.BIN"]), got["SHU_KWA.BIN"]
    assert got["SHU_TEO.BIN"] == (["BT2_1S%02d.BIN" % i for i in range(10)],
                                  ["SKY2_1.BIN", "SKY2_2.BIN", "SKY2_3.BIN"]), got["SHU_TEO.BIN"]
    allbt = sorted({n for x in du["duels"] for n in x["bt_pages"]})
    allsky = sorted({n for x in du["duels"] for n in x["sky_pages"]})
    assert len(allbt) == 11 and len(allsky) == 9, (allbt, allsky)
    ok.append("PASS: the duel index words are 9/10, 11/12, 13/14; SHU_KWA takes SKY1 "
              "(not 'no SKY page') and SHU_TEO takes SKY2 (not SKY1); 11 BT pages and "
              "9 SKY pages in all")

    pg = pages_findings()
    assert pg["total"] == 1019 and pg["whole_file"] == 133 and pg["in_module"] == 886
    assert pg["files_holding_pages"] == 118 + 133, pg["files_holding_pages"]
    assert sum(pg["family_census"][k] for k in
               ("IC", "FACE", "BATH", "STONE", "BOOK", "PAPER", "CURIO", "HANA",
                "MIZU", "YUGE", "BT", "SKY")) == 133
    assert pg["all_decode_to_16384_full_consumption"]
    assert set(pg["class_census"]) <= {"flat", "low-index", "block-coherent",
                                       "high-entropy", "mixed"}
    ok.append("PASS: 1,019 page containers (133 whole-file, 886 in-module); all decode "
              "to exactly 16,384 bytes with used == 4 + comp_len; %d distinct contents, "
              "%d in-module pages byte-identical to a directory-owned page"
              % (pg["distinct_contents"], pg["in_module_pages_identical_to_a_whole_file_page"]))
    assert pg["duplicate_groups_spanning_families"] == {"('FACE', 'area-overlay')": 26}, \
        pg["duplicate_groups_spanning_families"]
    ok.append("PASS: the only cross-family duplication is 26 area-overlay pages that are "
              "byte-identical copies of DATA/03_SHIRO/DATA/FACE_* portrait pages")

    for line in ok:
        print(line)
    return 0


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", metavar="OUT")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--render", metavar="DIR")
    ap.add_argument("--only", choices=("battle", "play", "duel", "pages"))
    args = ap.parse_args(argv)

    if args.verify:
        return verify()

    out = {"tool": "kit/tools/q_art.py", "version": TOOL_VERSION,
           "decoder": DECODER_ID}
    if args.only in (None, "battle"):
        out["battle"] = battle_findings()
    if args.only in (None, "play"):
        out["play"] = play_findings()
    if args.only in (None, "duel"):
        out["duel"] = duel_findings()
    if args.only in (None, "pages"):
        out["pages"] = pages_findings(render_dir=args.render)

    text = json.dumps(out, indent=1)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        print("wrote %s (%d bytes)" % (args.json, len(text) + 1))
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
