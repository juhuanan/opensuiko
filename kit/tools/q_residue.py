#!/usr/bin/env python3
"""q_residue.py -- three residual questions in MAIN.EXE / SLUS_002.92, settled.

Each question was an ``evidence: "open"`` row in the fact registry.  This module
answers it in code, so the answer is machine-checkable and cannot rot into a
sentence in a document:

1. **What is ``record+0x4C == 0x16``?**  The byte is not a character class.  It
   is the character's **rune number**: every reader indexes the rune pointer
   array at ``0x8016A0E0`` with it (``lbu 0x4c`` -> ``sll 2`` ->
   ``la 0x8016A0E0`` -> ``lw``), and 0 means "no rune".  ``0x16`` is rune 22,
   the **Fortune Rune**, which is why the experience award doubles for it.
   Every other constant the battle code compares against ``+0x4C`` is likewise a
   rune, and each one's in-code behaviour is that rune's effect.

2. **What is a unite attack's ``+0x18`` byte?**  It is the **member count**, not
   an element.  The membership matcher ``0x800F91C0`` reads ``lbu 0x18`` as the
   loop bound and ``lbu 0x1A+m`` as the member's **character id** for
   ``m = 0 .. count-1``.  ``+0x19`` is the unite-attack id (an index into the
   pointer table at ``0x8016D2D0``) and ``+0x16`` is a ``u16`` flag field, which
   is what the "element count" reading mistook for the length.

3. **What are resource-table ``+4`` and ``+11``?**  ``+11`` is nothing: no
   instruction in ``MAIN.EXE`` forms an address for it; it is the unused high
   byte of the ``u16`` at ``+0x0A``.  ``+4`` (``u16``) and ``+6`` (``u16``) are
   two separate fields, not one ``u32``.  ``+4`` is divided by ``0xAC44``
   (= 44100) by the loader and the quotient is handed to the per-voice
   descriptor; ``+6`` is a file-relative sector the loader rewinds the read
   cursor to.

Provenance: ``MAIN.EXE``, the headerless image at base ``0x800C0800``
(``disc.extract(...)[2048:]``), and ``SLUS_002.92``, headerless at
``0x80010000``.  Static analysis only.

Usage::

    .venv/bin/python kit/tools/q_residue.py --json
    .venv/bin/python kit/tools/q_residue.py --verify
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)

import disc      # noqa: E402
import maindec   # noqa: E402

MAIN_BASE = maindec.MBASE

#: the 78 x 0x50 character template in SLUS_002.92.  The boot seeder copies
#: 0x1D60 bytes from SLUS image 0x80042FE0 into gs, so the template's +0x294 is
#: the runtime record -- image offset 0x33274 == VA 0x80043274.
SLUS_NAME = "SLUS_002.92"
CHAR_IMAGE_OFF = 0x33274
CHAR_STRIDE = 0x50
CHAR_COUNT = 78
CHAR_RUNE_OFF = 0x4C
CHAR_WEAPON_OFF = 0x44

#: word[0] is the count (31), words[1..31] the 31 rune records, word[32] a
#: placeholder, word[33] the True Holy Rune.  A character record's +0x4C indexes
#: it 1-based, which is why every reader tests the byte for zero first.
RUNE_ARRAY = 0x8016A0E0
RUNE_RECORD_BYTES = 0x14

#: the constants the battle code compares a record's +0x4C against.  Each is a
#: rune number; the value is the word at 0x800C1414[class-1] for the dispatcher.
RUNE_CONSTANTS = (
    (0x800D4EFC, 0x13, "0x800d4f00"),   # 0x800d4f00 ori $v0,$zero,0x13
    (0x800E6BC8, 0x19, "0x800e6bcc"),   # 0x800e6bcc ori $v0,$zero,0x19
    (0x800E98EC, 0x16, "0x800e98f0"),   # 0x800e98f0 ori $v0,$zero,0x16
    (0x800E9BD0, 0x17, "0x800e9bac"),   # 0x800e9bac ori $a2,$zero,0x17
    (0x800F4A7C, 0x0E, "0x800f4a80"),   # 0x800f4a80 ori $v0,$zero,0x0e
    (0x800F4AB0, 0x11, "0x800f4ab4"),   # 0x800f4ab4 ori $v0,$zero,0x11
    (0x800F79A4, 0x10, "0x800f79a8"),   # 0x800f79a8 ori $v0,$zero,0x10
    (0x800F7B58, 0x1A, "0x800f7b5c"),   # 0x800f7b5c ori $v0,$zero,0x1a
    (0x800F7E08, 0x12, "0x800f7e0c"),   # 0x800f7e0c ori $v0,$zero,0x12
    (0x800F83FC, 0x0F, "0x800f8400"),   # 0x800f8400 ori $v0,$zero,0x0f
)

#: the rune-array index each of the above resolves to, as a rune name.
RUNE_CONSTANT_NAMES = {
    0x0E: "Double-beat Rune",
    0x0F: "Killer Rune",
    0x10: "Counter Rune",
    0x11: "Spark Rune",
    0x12: "Hazy Rune",
    0x13: "Gale Rune",
    0x16: "Fortune Rune",
    0x17: "Prosperity Rune",
    0x19: "Turtle Rune",
    0x1A: "Phero Rune",
}

UNITE_TABLE = 0x8016CD0C
UNITE_STRIDE = 0x24
UNITE_COUNT = 32
UNITE_PTR = 0x8016D18C
UNITE_NAME_BYTES = 0x14
UNITE_FLAGS_OFF = 0x16     # u16, read with lhu at 0x800F588C
UNITE_COUNT_OFF = 0x18     # u8 member count, read with lbu at 0x800F9210
UNITE_ID_OFF = 0x19        # u8 unite id, read with lbu at 0x800F5914
UNITE_MEMBERS_OFF = 0x1A   # u8 per member, read with lbu at 0x800F9238
UNITE_ACTION_PTR = 0x8016D2D0
UNITE_MEMBERS_MAX = 8      # the widest record has four, so 8 is slack

#: the membership matcher and its instruction words (cited as evidence).
UNITE_MATCHER = 0x800F91C0
UNITE_MATCHER_WORDS = {
    0x800F9204: 0x8C830000,   # lw   $v1,0x0($a0)      ; unite rec[t4]
    0x800F9210: 0x906B0018,   # lbu  $t3,0x18($v1)     ; member count
    0x800F9238: 0x9047001A,   # lbu  $a3,0x1a($v0)     ; member id
    0x800F928C: 0x010B102A,   # slt  $v0,$t0,$t3       ; bound is +0x18
    0x800F588C: 0x94420016,   # lhu  $v0,0x16($v0)     ; flags, not a count
    0x800F5914: 0x90420019,   # lbu  $v0,0x19($v0)     ; unite id
}
UNITE_ACTION_LA = 0x800F5920
UNITE_ACTION_LA_WORD = 0x3C018017
UNITE_ACTION_ADD = 0x800F5924
UNITE_ACTION_ADD_WORD = 0x2421D2D0

RES_TABLE = 0x80164E68
RES_STRIDE = 12
RES_LAST_ROW = 70          # rows 0..70; row 0 and row 67 are zero
RES_EMPTY_ROWS = (0, 67)
RES_A_OFF = 4              # u16
RES_B_OFF = 6              # u16
RES_SECTORS_OFF = 8        # u16
RES_FLAG_OFF = 0x0A        # u8
RES_PAD_OFF = 0x0B         # never addressed
RES_CD_RATE = 44100        # 0xAC44

#: every `lui 0x8016 / addiu` pair in MAIN.EXE that forms an address inside
#: [0x80164E60, 0x80164E80].  These are the only ways the table is addressed;
#: none of them builds +0x0B.
RES_ACCESSORS = {
    0x800C7978: 0x80164E72,
    0x800C7A54: 0x80164E72,
    0x800C7AD4: 0x80164E6C,
    0x800C7C34: 0x80164E72,
    0x800C7C60: 0x80164E68,
    0x800C864C: 0x80164E70,
    0x800C865C: 0x80164E68,
    0x800C8684: 0x80164E6E,
    0x800C89B0: 0x80164E6C,
}
RES_RATE_WORDS = {
    0x800C7AE0: 0x94230000,   # lhu  $v1,0x0($at)      ; +4
    0x800C7AE4: 0x3402AC44,   # ori  $v0,$zero,0xac44  ; 44100
    0x800C7AEC: 0x0062001A,   # div  $v1,$v0
    0x800C8684: 0x3C018016,   # lui  $at,0x8016
    0x800C8688: 0x24214E6E,   # addiu $at,$at,0x4e6e   ; +6
    0x800C8690: 0x94220000,   # lhu  $v0,0x0($at)      ; +6
    0x800C86A4: 0xAC229CE8,   # sw   $v0,-0x6318($at)  ; cursor = LBA + +6
}


# --------------------------------------------------------------------------- #
# game text
# --------------------------------------------------------------------------- #

_TEXT_LOWER = {0x11 + i: chr(ord("a") + i) for i in range(0x1A)}
_TEXT_UPPER = {0x2B + i: chr(ord("A") + i) for i in range(0x1A)}
_TEXT_DIGIT = {0x45 + i: chr(ord("0") + i) for i in range(10)}
_TEXT_EXTRA = {0x10: " ", 0x53: "'", 0x5C: "-", 0x58: "?"}


def game_text(bs: bytes) -> str:
    """Decode the engine's own single-byte text table, tolerantly."""
    out = []
    for c in bs:
        if c == 0:
            break
        ch = (_TEXT_LOWER.get(c) or _TEXT_UPPER.get(c) or _TEXT_DIGIT.get(c)
              or _TEXT_EXTRA.get(c))
        out.append(ch if ch is not None else "?")
    return "".join(out).rstrip()


# --------------------------------------------------------------------------- #
# image helpers
# --------------------------------------------------------------------------- #

_MBODY = None
_SLUS = None


def body() -> bytes:
    global _MBODY
    if _MBODY is None:
        _MBODY = maindec.body()
    return _MBODY


def word(va: int):
    return maindec.mword(va)


def byte(va: int) -> int:
    return body()[va - MAIN_BASE]


def half(va: int) -> int:
    o = va - MAIN_BASE
    return struct.unpack_from("<H", body(), o)[0]


def slus_image() -> bytes:
    """The headerless SLUS_002.92 image (the new-game gs seed lives in it)."""
    global _SLUS
    if _SLUS is None:
        rec = None
        for cand in (os.path.join(_KIT, "extracted", "iso_files.json"),
                     os.path.join(_KIT, "work", "iso_files.json")):
            if os.path.exists(cand):
                with open(cand, encoding="utf-8") as fh:
                    rows = json.load(fh)
                rec = next((r for r in rows if r.get("path") == SLUS_NAME), None)
                if rec:
                    break
        if rec is None:
            raise SystemExit("q_residue: SLUS_002.92 is not in iso_files.json")
        _SLUS = disc.extract(rec["lba"], rec["size"])[2048:]
    return _SLUS


# --------------------------------------------------------------------------- #
# Q1 -- record+0x4C is a rune number
# --------------------------------------------------------------------------- #

def rune_records() -> list[dict]:
    """34 words at 0x8016A0E0: [0] the count, [1..33] the rune records."""
    out = []
    for n in range(0, 34):
        p = word(RUNE_ARRAY + 4 * n)
        rec = None
        if p and MAIN_BASE <= p < MAIN_BASE + len(body()):
            o = p - MAIN_BASE
            rec = {
                "addr": f"{p:#010x}",
                "raw": body()[o:o + RUNE_RECORD_BYTES].hex(),
                "name": game_text(body()[o:o + RUNE_RECORD_BYTES]),
            }
        out.append({"index": n, "pointer": f"{p:#010x}" if p else None,
                    "record": rec})
    return out


def rune_names() -> dict:
    return {r["index"]: (r["record"] or {}).get("name") for r in rune_records()}


def character_runes() -> list[dict]:
    """The 78 character records' +0x4C byte, with the rune name it selects."""
    img = slus_image()
    names = rune_names()
    out = []
    for i in range(CHAR_COUNT):
        o = CHAR_IMAGE_OFF + i * CHAR_STRIDE
        cid = struct.unpack_from("<I", img, o)[0]
        r = img[o + CHAR_RUNE_OFF]
        out.append({"record": i, "id": cid,
                    "weapon": img[o + CHAR_WEAPON_OFF],
                    "rune": r,
                    "rune_name": names.get(r) if r else None})
    return out


def q1() -> dict:
    chars = character_runes()
    nonzero = [c for c in chars if c["rune"]]
    consts = []
    for lbu_va, imm, ori_va in RUNE_CONSTANTS:
        consts.append({
            "read_at": f"{lbu_va:#010x}",
            "compare_at": ori_va,
            "immediate": imm,
            "rune_name": rune_names().get(imm),
            "instruction": f"{word(int(ori_va, 16)):#010x}",
        })
    return {
        "field": "character record +0x4C (0x50-byte records at gs+0x294)",
        "template": f"{SLUS_NAME} image 0x{CHAR_IMAGE_OFF:x} (VA 0x80043274)",
        "rune_array": f"{RUNE_ARRAY:#010x}",
        "meaning": "the character's rune number, 1-based into the rune array; "
                   "0 means no rune",
        "id_16": "rune 22 = " + str(rune_names().get(0x16)),
        "nonzero_count": len(nonzero),
        "nonzero_values": sorted({c["rune"] for c in nonzero}),
        "id_16_present_in_template": any(c["rune"] == 0x16 for c in chars),
        "rune_constants": consts,
        "characters": [c for c in chars if c["rune"]],
    }


# --------------------------------------------------------------------------- #
# Q2 -- the unite record layout
# --------------------------------------------------------------------------- #

def unites() -> list[dict]:
    out = []
    for i in range(UNITE_COUNT):
        a = UNITE_TABLE + UNITE_STRIDE * i
        n = byte(a + UNITE_COUNT_OFF)
        members = [byte(a + UNITE_MEMBERS_OFF + k) for k in range(n)]
        out.append({
            "index": i,
            "addr": f"{a:#010x}",
            "name": game_text(body()[a - MAIN_BASE:a - MAIN_BASE + UNITE_NAME_BYTES]),
            "flags": half(a + UNITE_FLAGS_OFF),
            "target_selection": "individual" if half(a + UNITE_FLAGS_OFF) & 2 else "no_individual_picker",
            "member_count": n,
            "unite_id": byte(a + UNITE_ID_OFF),
            "members": members,
        })
    return out


def q2() -> dict:
    return {
        "table": f"{UNITE_TABLE:#010x}",
        "stride": UNITE_STRIDE,
        "count": UNITE_COUNT,
        "names": f"{UNITE_PTR:#010x}",
        "layout": {
            "+0x00": "name, 0x14-byte fixed-width game-text literal",
            "+0x16": "u16 flag field (read with lhu at 0x800F588C)",
            "+0x18": "u8 member count (read with lbu at 0x800F9210)",
            "+0x19": "u8 unite-attack id, index into the table at "
                     f"{UNITE_ACTION_PTR:#010x} (lbu at 0x800F5914)",
            "+0x1A": "u8 per member: the member's character id, count of them "
                     "(lbu at 0x800F9238)",
        },
        "answer": "the byte at +0x18 is the member count; the member character "
                  "ids start at +0x1A.  There is no element byte.",
        "records": unites(),
    }


# --------------------------------------------------------------------------- #
# Q3 -- the resource table
# --------------------------------------------------------------------------- #

def resource_rows() -> list[dict]:
    out = []
    for i in range(RES_LAST_ROW + 1):
        a = RES_TABLE + RES_STRIDE * i
        out.append({
            "index": i,
            "addr": f"{a:#010x}",
            "lba": struct.unpack_from("<I", body(), a - MAIN_BASE)[0],
            "a": half(a + RES_A_OFF),
            "b": half(a + RES_B_OFF),
            "sectors": half(a + RES_SECTORS_OFF),
            "flag": byte(a + RES_FLAG_OFF),
            "pad_11": byte(a + RES_PAD_OFF),
        })
    return out


def table_field_targets() -> list[dict]:
    """Every `lui/addiu` pair in MAIN.EXE landing in the resource table's frame.

    This is the cross-reference proof for the ``+11`` negative: the only ways
    the code reaches into the table are enumerated here, and ``+0x0B`` is not
    among them.
    """
    b = body()
    out = []
    for i in range(0, len(b) - 8, 4):
        w1, w2 = struct.unpack_from("<II", b, i)
        if (w1 >> 26) != 0x0F or (w2 >> 26) != 0x09:
            continue
        if ((w1 >> 16) & 0x1F) != ((w2 >> 21) & 0x1F):
            continue
        addr = ((((w1 & 0xFFFF) << 16) + (w2 & 0xFFFF)) & 0xFFFFFFFF)
        if 0x80164E60 <= addr <= 0x80164E80:
            out.append({"at": f"{MAIN_BASE + i:#010x}", "target": f"{addr:#010x}"})
    return out


def q3() -> dict:
    rows = resource_rows()
    populated = [r for r in rows if r["lba"] or r["sectors"]]
    return {
        "table": f"{RES_TABLE:#010x}",
        "stride": RES_STRIDE,
        "rows": len(rows),
        "populated": len(populated),
        "empty_rows": list(RES_EMPTY_ROWS),
        "layout": {
            "+0x00": "u32 LBA",
            "+0x04": "u16, divided by 0xAC44 (44100) by the loader",
            "+0x06": "u16, sectors added to the LBA when the read cursor wraps",
            "+0x08": "u16 sector count (x2048 == the file size)",
            "+0x0A": "u8 load flag; zero aborts the load",
            "+0x0B": "never addressed by any instruction",
        },
        "answer_11": "not a field: no instruction forms an address for +0x0B, "
                     "and it is 0 in every populated row",
        "answer_04": "a rate value: the loader computes (+4 << 12) / 44100 "
                     "(0x800C7AE0-0x800C7B14) and stores the quotient in the "
                     "per-voice descriptor; +4 <= 44100 in every populated row",
        "answer_06": "a file-relative sector: when the read cursor passes "
                     "LBA+sectors the loader rewinds it to LBA + (+6) "
                     "(0x800C8688-0x800C86A4); +6 <= sectors and +6 % 32 == 0 "
                     "in every populated row",
        "field_accessors": table_field_targets(),
        "rows_detail": rows,
    }


# --------------------------------------------------------------------------- #
# verify
# --------------------------------------------------------------------------- #

def _asrt(cond, msg):
    if not cond:
        raise AssertionError(msg)


def verify() -> list[str]:
    lines = []

    # ---------------- Q1
    names = rune_names()
    _asrt(names.get(0x16) == "Fortune Rune",
          f"rune 0x16 must be the Fortune Rune, got {names.get(0x16)!r}")
    _asrt(word(0x8016A0E0) == 31, "rune array word 0 must be the count 31")
    chars = character_runes()
    _asrt(len(chars) == 78, "the template must hold 78 records")
    _asrt(len({c["id"] for c in chars}) == 78, "the 78 ids must be distinct")
    nz = [c for c in chars if c["rune"]]
    _asrt(len(nz) == 22, f"22 records carry a rune, got {len(nz)}")
    _asrt(sorted({c["rune"] for c in nz}) ==
          [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 18, 27, 29, 30, 31, 32, 33],
          "the nonzero rune set changed")
    _asrt(not any(c["rune"] == 0x16 for c in chars),
          "no template record carries the Fortune Rune")
    for lbu_va, imm, ori_va in RUNE_CONSTANTS:
        w = word(int(ori_va, 16))
        _asrt((w >> 26) == 0x0D and ((w >> 21) & 0x1F) == 0 and
              (w & 0xFFFF) == imm,
              f"{ori_va} is {w:#010x}, not `ori ...,$zero,{imm:#x}`")
        _asrt(names.get(imm) == RUNE_CONSTANT_NAMES[imm],
              f"rune {imm:#x} is not {RUNE_CONSTANT_NAMES[imm]!r}")
    # the readers really do index the array with the byte
    _asrt(word(0x800CF0D0) == 0x1040001A, "0x800CF0D0 is not `beq $v0,$zero`")
    _asrt(word(0x800CF0DC) == 0x2421A0E0,
          "0x800CF0DC is not `addiu $at,$at,0xa0e0`")
    _asrt(word(0x800E98EC) == 0x9043004C, "0x800E98EC is not `lbu $v1,0x4c($v0)`")
    _asrt(word(0x800E9904) == 0x00021040, "0x800E9904 is not `sll $v0,$v0,1`")
    # the dispatcher table maps runes onto seven element values
    for cls, arm in ((2, 0x800F82D8), (27, 0x800F82D8), (3, 0x800F82E0),
                     (4, 0x800F82F8), (6, 0x800F82E8), (5, 0x800F82F0),
                     (7, 0x800F8300), (1, 0x800F8308)):
        _asrt(word(0x800C1414 + 4 * (cls - 1)) == arm,
              f"dispatch entry for rune {cls} moved")
    _asrt(word(0x800F81E8) == 0x9072004C, "0x800F81E8 is not `lbu $s2,0x4c($v1)`")
    lines.append("PASS: character record +0x4C is the character's rune number "
                 "(0x8016A0E0[+0x4C], 0 = none); the template's 78 records carry "
                 "22 runes, value set "
                 "3,4,5,6,7,8,9,10,11,12,14,16,18,27,29,30,31,32,33; "
                 "0x16 is rune 22 = Fortune Rune, so the doubled experience "
                 "award is the Fortune Rune's effect, and the ten constants the "
                 "battle code compares against +0x4C are ten runes")

    # ---------------- Q2
    for va, w in UNITE_MATCHER_WORDS.items():
        _asrt(word(va) == w, f"{va:#010x} is {word(va):#010x}, expected {w:#010x}")
    _asrt(word(UNITE_ACTION_LA) == UNITE_ACTION_LA_WORD, "unite-id table base")
    _asrt(word(UNITE_ACTION_ADD) == UNITE_ACTION_ADD_WORD, "unite-id table base")
    us = unites()
    _asrt(len(us) == 32, "32 unite records")
    _asrt(us[0]["name"] == "Talisman attack", us[0]["name"])
    _asrt(us[31]["name"] == "Master pupil attack", us[31]["name"])
    _asrt(all(u["flags"] & 1 for u in us), "bit 0 of +0x16 is set in all 32")
    _asrt({u["flags"] for u in us} == {1, 3}, "the +0x16 flag set changed")
    _asrt(all(1 <= u["member_count"] <= 4 for u in us), "member counts")
    _asrt(all(m < 110 for u in us for m in u["members"]), "member ids in range")
    expect = {
        1: [32, 38],    # Fisherman: Tai Ho + Yam Koo
        3: [4, 75, 9],  # Elf: Kirkis + Stallion + Sylvina
        4: [11, 43, 41],
        5: [70, 72, 69, 71],
        7: [17, 48, 49],
        11: [14, 80],   # Kobold: Kuromimi + Gon
        12: [19, 29],   # Dragon Knight: Futch + Milia
        15: [33, 63],   # Warriors: Tengaar + Hix
        16: [0, 30],    # Couple: Eileen + Lepant
        26: [14, 65, 80],
        28: [23, 55, 22],
        30: [30, 0, 62],
        31: [8, 91],    # Master pupil: Hero + Kai
    }
    for i, mem in expect.items():
        _asrt(us[i]["members"] == mem,
              f"unite {i} members {us[i]['members']} != {mem}")
    for i in (21, 22, 23, 24):
        _asrt(us[i]["unite_id"] == 6 and us[i]["member_count"] == 4,
              f"blacksmith variant {i}")
        _asrt(us[i]["name"] == "Blacksmith attack", us[i]["name"])
    lines.append("PASS: a unite record's +0x18 is the member count and +0x1A.. "
                 "are the member character ids (0x800F9210 / 0x800F9238, bound "
                 "at 0x800F928C); +0x19 is the unite-attack id into "
                 "0x8016D2D0 (0x800F5914) and +0x16 is a u16 flag field "
                 "(0x800F588C); the named records resolve to the right teams "
                 "(Couple = Eileen+Lepant, Master pupil = Hero+Kai, Fisherman "
                 "= Tai Ho+Yam Koo, Kobold = Kuromimi+Gon)")

    # ---------------- Q3
    rows = resource_rows()
    _asrt(len(rows) == 71, f"the table has 71 rows, got {len(rows)}")
    for i in RES_EMPTY_ROWS:
        r = rows[i]
        _asrt(r["lba"] == 0 and r["sectors"] == 0 and r["a"] == 0 and
              r["b"] == 0 and r["flag"] == 0, f"row {i} is not empty")
    pop = [r for r in rows if r["lba"] or r["sectors"]]
    _asrt(len(pop) == 69, f"69 populated rows, got {len(pop)}")
    _asrt(all(r["pad_11"] == 0 for r in pop), "+0x0B is not zero everywhere")
    _asrt(all(r["a"] <= RES_CD_RATE for r in pop), "+4 must never exceed 44100")
    _asrt(all(r["b"] <= r["sectors"] for r in pop), "+6 must not exceed +8")
    _asrt(all(r["b"] % 32 == 0 for r in pop), "+6 must be a multiple of 32")
    for va, w in RES_RATE_WORDS.items():
        _asrt(word(va) == w, f"{va:#010x} is {word(va):#010x}, expected {w:#010x}")
    got = {int(e["at"], 16): int(e["target"], 16) for e in table_field_targets()}
    _asrt(got == RES_ACCESSORS,
          f"resource-table address formation changed: {got}")
    _asrt(0x80164E73 not in got.values(), "+0x0B must never be addressed")
    # the +4 field is not the size and not derived from the file
    _asrt(all(r["a"] != r["sectors"] * 2048 for r in pop), "+4 is not the size")
    lines.append("PASS: the resource table is 71 rows at 0x80164E68 (rows 0 and "
                 "67 empty, 69 populated); +0x04 and +0x06 are two u16 fields, "
                 "not one u32 -- +0x04 is a rate the loader divides by 0xAC44 "
                 "(44100) and is <= 44100 in all 69 rows, +0x06 is a wrap sector "
                 "the loader rewinds to (LBA + +6) and is <= the sector count "
                 "and a multiple of 32 in all 69; +0x0B is addressed by no "
                 "instruction (the nine lui/addiu pairs that reach the table "
                 "build only +0x00, +0x04, +0x06, +0x08 and +0x0A) and is zero "
                 "in every populated row")
    return lines


# --------------------------------------------------------------------------- #
# cli
# --------------------------------------------------------------------------- #

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true", help="emit the findings")
    ap.add_argument("--verify", action="store_true",
                    help="re-derive and assert every claim")
    ap.add_argument("--chars", action="store_true",
                    help="list the 78 records' rune numbers")
    ap.add_argument("--unites", action="store_true", help="list the 32 unites")
    ap.add_argument("--resources", action="store_true",
                    help="list the resource table")
    args = ap.parse_args(argv)

    if args.json:
        print(json.dumps({"q1_record_4c": q1(),
                          "q2_unite_element": q2(),
                          "q3_resource_table": q3()},
                         indent=2, sort_keys=False))
        return 0
    if args.verify:
        for line in verify():
            print(line)
        return 0
    if args.chars:
        for c in character_runes():
            print(f"{c['record']:3d} id={c['id']:4d} rune={c['rune']:3d} "
                  f"{c['rune_name'] or '-'}")
        return 0
    if args.unites:
        for u in unites():
            print(f"{u['index']:3d} {u['name']:<22} flags={u['flags']:#06x} "
                  f"members={u['members']} id={u['unite_id']} target={u['target_selection']}")
        return 0
    if args.resources:
        for r in resource_rows():
            print(f"{r['index']:3d} lba={r['lba']:7d} a={r['a']:6d} "
                  f"b={r['b']:6d} sectors={r['sectors']:6d} flag={r['flag']:#04x} "
                  f"pad11={r['pad11']:#04x}")
        return 0
    ap.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
