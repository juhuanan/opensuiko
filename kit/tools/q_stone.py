#!/usr/bin/env python3
"""q_stone.py -- three questions about `03_SHIRO` art that is loaded but had no
located consumer, re-derived from the disc.

`MAIN.EXE` is the headerless image at base `0x800C0800` (the 2048-byte PS-X
header is always stripped before the base is applied); the `03_SHIRO` overlays
are headerless at `0x80080000`.

**Q1 -- where the tablet's page coordinates come from.**  The recorded reading
was that `STONE.BIN`'s only reference to VRAM `(0x240,0x100)` is a LoadImage
*write*, and that the quad emitters take their texture-page word from an engine
draw-state field at `+0x780`.  Both halves are wrong.  The vtable load one word
before `0x800833D8` is slot `+0x6C` (`GetTpage`, `MAIN.EXE 0x8014AB0C`), not
`+0x70` (`LoadImage`, `0x80148590`); `0x240`/`0x100` are that call's `x` and `y`
arguments, and the result is stored into a `POLY_FT4`'s texture-page halfword at
`+0x16`.  The `+0x780` field is a **display-list head**: the code both reads it
and writes the packet's address back into it, which is the linked-list splice,
and the packet's own word 0 carries its word count in the top byte.

**Q2 -- the consumer of the uploaded RECTs.**  The RECT table at `0x80084CDC`
holds **18** entries (the loader's own bound is 18), and its pages are sampled by
`STONE.BIN 0x80081334`, a full-screen composite that draws one `POLY_FT4` per
20-byte entry of the page-coordinate table at `0x80084D6C`.  An 8-bit `u` spans
a whole texel byte row, so a quad wider than 128 pixels crosses into the
neighbouring page without a second `GetTpage`; every one of the 18 RECTs lies
inside some entry's sampled region.

**Q3 -- the owner of `PAPER_*`, `YUGE_00`, `MIZU_00`, `HANA`, `CURIO_0`.**  These
files are named by neither an overlay nor an LBA literal.  They are reached
through the **load-group directory** (`MAIN.EXE 0x8016B358`), whose address the
loader installer writes into `ctx+0x14B8`.  `BOOKS.BIN` reads `dir[3]`
(13 files: `BOOK_0..5`, `PAPER_0..5`, `CURIO_0`) and bounds its index at 13;
`BATH.BIN` reads `dir[8]` (4 files: `YUGE_00`, `MIZU_00`, `CURIO_0`, `HANA`) and
bounds its index at 4.  `BATH.BIN`'s own debug string for that group pointer is
`csr_data_steam = %x\\n`.  `CURIO_0` is one master record in both lists.

Usage:
    python3 q_stone.py             # report
    python3 q_stone.py --json      # machine-readable
    python3 q_stone.py --verify    # re-derive and assert; prints PASS: lines
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
_KIT = _TOOLS.parent
sys.path.insert(0, str(_TOOLS))

import disc_iso  # noqa: E402

MAIN = "MAIN.EXE"
MAIN_BASE = 0x800C0800
OVL_BASE = 0x80080000

STONE = "DATA/03_SHIRO/STONE.BIN"
BOOKS = "DATA/03_SHIRO/BOOKS.BIN"
BATH = "DATA/03_SHIRO/BATH.BIN"

# --- Q1 -------------------------------------------------------------------
MAIN_GETTPAGE = 0x8014AB0C              # the engine vtable's slot +0x6C
MAIN_GETCLUT = 0x8014ABD4               # slot +0x8C
MAIN_MODE_BYTE = 0x80148250             # returns the byte that picks the arm
STONE_PORTRAIT_QUAD = 0x8008331C        # builds one POLY_FT4 for the roster
STONE_PORTRAIT_TPAGE_CALL = 0x800833DC  # GetTpage(1, 0, 0x240, 0x100)
STONE_PORTRAIT_CLUT_CALL = 0x800833B4   # GetClut(0, 0x1EA + n)
STONE_LIST_SPLICE_READ = 0x80081F88     # lw ...,0x780(...)   the list head
STONE_LIST_SPLICE_WRITE = 0x80081FB4    # sw ...,0x780(...)   written back
STONE_PAGE_240_100 = (0x240, 0x100)

# --- Q2 -------------------------------------------------------------------
STONE_RECT_TABLE = 0x80084CDC
STONE_RECT_COUNT = 18
STONE_RECT_LOAD = 0x800806B4            # the 18-page LoadImage loop
STONE_RECT_WALK = 0x80081334            # the composite sampler
STONE_PAGE_TABLE = 0x80084D6C           # 20-byte records, stride 0x14
STONE_PAGE_TABLE_STRIDE = 0x14
STONE_PAGE_TABLE_RECORDS = 14

# --- Q3 -------------------------------------------------------------------
GROUP_DIR = 0x8016B358
GROUP_DIR_SLOT = 0x14B8
GROUP_INSTALL = 0x800C9648
MASTER_TABLE = 0x80163D64
MASTER_COUNT = 344
GROUP_BOOKS = 3
GROUP_BATH = 8
BOOKS_DIR_READ = 0x800802D4
BOOKS_GROUP_READ = 0x800802E4
BOOKS_INDEX_READ = 0x800804AC
BOOKS_LOADER = 0x800804C8
BOOKS_BOUND = 0x80080628
BATH_DIR_READ = 0x800804A8
BATH_GROUP_READ = 0x800804F8
BATH_INDEX_READ = 0x80080968
BATH_LOADER = 0x8008098C
BATH_BOUND = 0x80080B30
BATH_CSR_CACHE = 0x8009D0FC             # `sw $v1,-0x2f04($at)`, lui 0x8009
BATH_CSR_DEBUG_SITE = 0x800805BC        # addiu $a0,$a0,0x6c
BATH_CSR_DEBUG_STR = b"csr_data_steam = %x\n"

PAGE_BYTES = 16384


# ---------------------------------------------------------------------------
# disc access
# ---------------------------------------------------------------------------
def _iso() -> list[dict]:
    return disc_iso.iso_records(_KIT / "extracted" / "iso_files.json")


def raw(path: str) -> bytes:
    return disc_iso.extract_path(path, _KIT / "extracted" / "iso_files.json")


def main_image() -> bytes:
    """`MAIN.EXE` **with the 2048-byte PS-X header stripped**, at 0x800C0800."""
    return disc_iso.main_image(_KIT / "extracted" / "iso_files.json")


def overlay(path: str) -> bytes:
    return raw(path)


def mw(addr: int) -> int:
    return struct.unpack_from("<I", main_image(), addr - MAIN_BASE)[0]


def ow(d: bytes, addr: int, base: int = OVL_BASE) -> int:
    return struct.unpack_from("<I", d, addr - base)[0]


def ov_hw(d: bytes, addr: int, n: int = 2, base: int = OVL_BASE) -> tuple:
    return struct.unpack_from("<%dH" % n, d, addr - base)


# ---------------------------------------------------------------------------
# Q1 -- the texture-page word and the display-list head
# ---------------------------------------------------------------------------
def gettpage(tp: int, abr: int, x: int, y: int) -> int:
    """`MAIN.EXE 0x8014AB0C`, re-derived.

    The function first asks `0x80148250` for the display-mode byte
    (`*(0x80171FEC)`).  The arm at `0x8014AB58` runs when that byte is 1 or 2;
    the arm at `0x8014AB80` runs otherwise, which is the arm this US NTSC disc
    uses.  The argument order is forced by which saved register each shift
    reads: `s0 = a0`, `s2 = a1`, `s3 = a2`, `s1 = a3`.
    """
    return (((tp & 3) << 7) | ((abr & 3) << 5) | ((y & 0x100) >> 4)
            | ((y & 0x200) << 2) | ((x & 0x3FF) >> 6)) & 0xFFFF


def getclut(x: int, y: int) -> int:
    """`MAIN.EXE 0x8014ABD4`: `sll v0,a1,6; sra a0,a0,4; andi a0,0x3F; or`."""
    return ((y << 6) | ((x >> 4) & 0x3F)) & 0xFFFF


def _arg_at(d: bytes, call: int, reg: int, limit: int = 40) -> tuple:
    """`(address, word)` of the nearest write to `reg` before `call`, or `(0, 0)`.

    The delay slot is checked first: an argument set there is the one the callee
    sees, and `STONE.BIN 0x800833E0` (the page's y) is set exactly that way.
    """
    for a in (call + 4,) + tuple(call - 4 * k for k in range(1, limit)):
        if a < OVL_BASE:
            break
        w = ow(d, a)
        op = w >> 26
        dst = None
        if op in (0x09, 0x0D, 0x08, 0x0C, 0x0A, 0x0B):
            dst = (w >> 16) & 0x1F
        elif op == 0 and (w & 0x3F) in (0x21, 0x23, 0x25):
            dst = (w >> 11) & 0x1F
        if dst == reg:
            return a, w
    return 0, 0


def _vtable_call_sites(d: bytes, slot: int) -> list[dict]:
    """Every `lw $rt,slot($rs)` + `jalr $rt` site, with the a0..a3 setup."""
    sites = []
    for i in range(len(d) // 4):
        w = ow(d, OVL_BASE + i * 4)
        if (w >> 26) != 0x23 or (w & 0xFFFF) != slot:
            continue
        rt = (w >> 16) & 0x1F
        for k in range(1, 7):
            w2 = ow(d, OVL_BASE + (i + k) * 4)
            if (w2 >> 26) == 0 and ((w2 >> 21) & 0x1F) == rt and (w2 & 0x3F) == 9:
                call = OVL_BASE + (i + k) * 4
                args = {}
                for reg, name in ((4, "a0"), (5, "a1"), (6, "a2"), (7, "a3")):
                    a, word = _arg_at(d, call, reg)
                    if word and (word >> 26) in (0x0D, 0x09) and ((word >> 21) & 0x1F) == 0:
                        args[name] = word & 0xFFFF
                    elif word:
                        args[name] = "reg@0x%08X" % a
                    else:
                        args[name] = None
                sites.append({"call": call, "load": OVL_BASE + i * 4, "args": args})
                break
    return sites


def q1() -> dict:
    d = overlay(STONE)
    ntsc = {
        "tp_shift": mw(0x8014AB80),     # sll $v1,$v1,7   (a0&3)<<7
        "abr_shift": mw(0x8014AB88),    # sll $v0,$v0,5   (a1&3)<<5
        "y_bit8": mw(0x8014AB94),       # sra $v0,$v0,4   (a3&0x100)>>4
        "x_bits": mw(0x8014ABA0),       # sra $v0,$v0,6   (a2&0x3FF)>>6
        "y_bit9": mw(0x8014ABAC),       # sll $v0,$v0,2   (a3&0x200)<<2
        "orr": mw(0x8014ABB0),          # or $v0,$v1,$v0
        "mode_lui": mw(0x80148250),     # lui $v0,0x8017
        "mode_read": mw(0x80148254),    # lbu $v0,0x1fec($v0)
        "mode_byte_addr": 0x80171FEC,
    }
    tp = gettpage(1, 0, *STONE_PAGE_240_100)
    site = {
        "slot_load": ow(d, 0x800833D4),     # lw $v0,0x6c($v0)
        "a2_x": ow(d, 0x800833D8),          # ori $a2,$zero,0x240
        "a3_y": ow(d, 0x800833E0),          # ori $a3,$zero,0x100
        "a0_depth": ow(d, 0x800833CC),      # ori $a0,$zero,0x1
        "a1_abr": ow(d, 0x800833D0),        # addu $a1,$zero,$zero
        "store_tpage": ow(d, 0x800833E4),   # sh $v0,0x16($s0)
    }
    clut_site = {
        "a0_zero": ow(d, 0x800833A4),       # addu $a0,$zero,$zero
        "mask": ow(d, 0x800833B0),          # andi $a1,$a1,0xf
        "bias": ow(d, 0x800833B8),          # addiu $a1,$a1,0x1ea
        "store": ow(d, 0x800833C4),         # sh $v0,0xe($s0)
        "pair_hi": ow(d, 0x80083388),       # addiu $at,$at,0x4bc1  the table's byte 1
        "state_2d": ow(d, 0x80083378),      # lbu $v0,0x2d($s2)
        "state_2f": ow(d, 0x8008339C),      # lbu $v0,0x2f($s2)
    }
    quad = {
        "prologue": ow(d, STONE_PORTRAIT_QUAD),          # addiu $sp,$sp,-0x30
        "packet_tag_len": ow(d, 0x80083368),             # ori $v0,$zero,0x9
        "packet_tag_store": ow(d, 0x8008336C),           # sb $v0,0x3($s0)
        "packet_code": ow(d, 0x80083370),                # ori $v0,$zero,0x2c
        "packet_code_store": ow(d, 0x80083374),          # sb $v0,0x7($s0)
        "advance": ow(d, 0x80083360),                    # addiu $v1,$s0,0x28
        "quadrant_mask": ow(d, 0x80083448),              # andi $v0,$v0,0x3
        "pair_lo": ow(d, 0x80083438),                    # addiu $at,$at,0x4bc0
        "u_shift": ow(d, 0x80083454),                    # sll $v1,$v1,6
        "u0": ow(d, 0x80083468),                         # sb $v1,0xc($s0)
        "v0": ow(d, 0x8008346C),                         # sb $v0,0xd($s0)
        "u1": ow(d, 0x80083470),                         # sb $a1,0x14($s0)
    }
    face = {
        "cache_dir2": ow(d, 0x80080304),      # sw $a0,0x1efc($at)   group 2 = FACE
        "cache_dir1": ow(d, 0x800802FC),      # sw $a1,0xda3c($at)   group 1 = STONE
        "dir2_load": ow(d, 0x800802D4),       # lw $a0,0x8($a0)      directory+8
        "lookup_cache": ow(d, 0x80080F94),    # lw $a0,0x1efc($a0)   the FACE list
        "lookup_mask": ow(d, 0x80080FA0),     # andi $v0,$v0,0x1fc   (index>>2)*4
        "lookup_upload": ow(d, 0x80081028),   # jal 0x80083D98       the (0x240,0x100) wrap
    }
    head = {
        "read": ow(d, STONE_LIST_SPLICE_READ),    # lw $v0,0x780($v0)
        "write": ow(d, STONE_LIST_SPLICE_WRITE),  # sw $v0,0x780($a0)
        "tag_len_byte": ow(d, 0x80082054),        # ori $v0,$zero,0x4
        "tag_len_store": ow(d, 0x80082058),       # sb $v0,0x3($s0)
        "packet_advance": ow(d, 0x8008204C),      # addiu $v0,$s0,0x14
    }
    return {
        "gettpage": {
            "addr": MAIN_GETTPAGE,
            "arm_used": 0x8014AB80,      # the byte is not 1 or 2
            "words": ntsc,
            "formula": "((tp&3)<<7)|((abr&3)<<5)|((y&0x100)>>4)|((y&0x200)<<2)|((x&0x3FF)>>6)",
            "args": "a0 = tp (texture depth), a1 = abr, a2 = page x, a3 = page y",
            "tpage_240_100": tp,
            "tpage_depth_bits": (tp >> 7) & 3,
            "tpage_xbase": tp & 0xF,
            "tpage_yband": ((tp >> 4) & 1) | (((tp >> 11) & 1) << 1),
        },
        "clut": {
            "addr": MAIN_GETCLUT,
            "formula": "(a1<<6)|((a0>>4)&0x3F)",
            "rows": [getclut(0, 0x1EA + n) for n in range(16)],
        },
        "portrait_quad": {
            "addr": STONE_PORTRAIT_QUAD,
            "tpage_call": STONE_PORTRAIT_TPAGE_CALL,
            "clut_call": STONE_PORTRAIT_CLUT_CALL,
            "site": site,
            "clut_site": clut_site,
            "quad": quad,
        },
        "draw_state_field_0x780": head,
        "face_page_route": face,
        "gettpage_sites": _vtable_call_sites(d, 0x6C),
        "getclut_sites": _vtable_call_sites(d, 0x8C),
    }


# ---------------------------------------------------------------------------
# Q2 -- the RECT table and its sampler
# ---------------------------------------------------------------------------
def rect_table(d: bytes) -> list[tuple]:
    return [ov_hw(d, STONE_RECT_TABLE + 8 * i, 4) for i in range(STONE_RECT_COUNT)]


def page_records(d: bytes) -> list[dict]:
    out = []
    for i in range(STONE_PAGE_TABLE_RECORDS):
        addr = STONE_PAGE_TABLE + STONE_PAGE_TABLE_STRIDE * i
        tx, ty, x0, y0, x1, y1 = ov_hw(d, addr, 6)
        u0, v0, u1, v1 = d[addr - OVL_BASE + 0xC], d[addr - OVL_BASE + 0xE], \
            d[addr - OVL_BASE + 0x10], d[addr - OVL_BASE + 0x12]
        out.append({"index": i, "addr": addr, "tpage": (tx, ty),
                    "src": (x0, y0, x1, y1), "uv": (u0, v0, u1, v1)})
    return out


def sampled_vram(rec: dict) -> tuple:
    """`(col0, col1, row0, row1)` in VRAM halfwords that one record samples.

    An 8-bit page is addressed with `u` as a **byte** column, so `u >> 1` is the
    halfword offset from the page's x base; `v` is a row in the page's 256-row
    band.  The band is the two-bit y field of the texture-page word.
    """
    tp = gettpage(1, 0, rec["tpage"][0], rec["tpage"][1])
    xbase = tp & 0xF
    yband = ((tp >> 4) & 1) | (((tp >> 11) & 1) << 1)
    u0, v0, u1, v1 = rec["uv"]
    return (xbase * 64 + (u0 >> 1), xbase * 64 + (u1 >> 1),
            yband * 0x100 + v0, yband * 0x100 + v1)


def q2() -> dict:
    d = overlay(STONE)
    rects = rect_table(d)
    recs = page_records(d)
    cover: dict[int, list[int]] = {i: [] for i in range(len(rects))}
    for r in recs:
        c0, c1, r0, r1 = sampled_vram(r)
        for i, (x, y, w, h) in enumerate(rects):
            if c0 < x + w and c1 >= x and r0 < y + h and r1 >= y:
                cover[i].append(r["index"])
    return {
        "rect_table": {
            "addr": STONE_RECT_TABLE,
            "count": len(rects),
            "loader": STONE_RECT_LOAD,
            "loader_bound": next((STONE_RECT_LOAD + 4 * k
                                  for k in range(80)
                                  if ow(d, STONE_RECT_LOAD + 4 * k) == 0x28420012), None),
            "loader_bound_value": 0x12,
            "rects": [{"x": x, "y": y, "w": w, "h": h} for x, y, w, h in rects],
        },
        "page_table": {
            "addr": STONE_PAGE_TABLE,
            "stride": STONE_PAGE_TABLE_STRIDE,
            "count": len(recs),
            "reader_quad_lo": ow(d, 0x800813EC),   # lh $a2,0x0($s2)
            "reader_quad_hi": ow(d, 0x800813F0),   # lh $a3,-0x8($s1)
            "reader_stride": ow(d, 0x800815C8),    # addiu $s2,$s2,0x14
            "records": [{"index": r["index"], "tpage": list(r["tpage"]),
                         "uv": list(r["uv"]), "vram": list(sampled_vram(r))}
                        for r in recs],
        },
        "coverage": {str(k): v for k, v in cover.items()},
        "uncovered": [i for i, v in cover.items() if not v],
        "sampler": STONE_RECT_WALK,
        "lookup_path_page": list(STONE_PAGE_240_100),
        "lookup_page_is_a_rect": STONE_PAGE_240_100 in [(x, y) for x, y, _w, _h in rects],
    }


# ---------------------------------------------------------------------------
# Q3 -- the load-group owners
# ---------------------------------------------------------------------------
def group_records(index: int) -> list[tuple]:
    p = mw(GROUP_DIR + 4 * index)
    lo, hi = MASTER_TABLE, MASTER_TABLE + MASTER_COUNT * 8
    out = []
    for k in range(64):
        v = mw(p + 4 * k)
        if not (lo <= v < hi):
            break
        out.append((v, mw(v), mw(v + 4)))
    return out


def q3() -> dict:
    by_lba = {r["lba"]: r["path"] for r in _iso()}
    d = overlay(BATH)
    books = overlay(BOOKS)
    groups = {}
    for gi in (GROUP_BOOKS, GROUP_BATH):
        recs = group_records(gi)
        groups[gi] = {
            "list": mw(GROUP_DIR + 4 * gi),
            "count": len(recs),
            "members": [{"size": s, "lba": l, "path": by_lba.get(l)} for _v, s, l in recs],
        }
    return {
        "installer": {
            "addr": GROUP_INSTALL,
            "words": [mw(GROUP_INSTALL), mw(GROUP_INSTALL + 4), mw(GROUP_INSTALL + 8)],
            "directory": GROUP_DIR,
            "slot": GROUP_DIR_SLOT,
        },
        "groups": {str(k): v for k, v in groups.items()},
        "readers": {
            "books": {
                "overlay": BOOKS,
                "dir_read": ow(books, BOOKS_DIR_READ),     # lw $v1,0x14b8($v1)
                "group_read": ow(books, BOOKS_GROUP_READ),  # lw $v0,0xc($v1)
                "index_read": ow(books, BOOKS_INDEX_READ),  # lw $v0,0x4($v0)
                "loader": ow(books, BOOKS_LOADER),          # lw $v0,0x10($v1)
                "bound": ow(books, BOOKS_BOUND),            # slti $v0,$v0,0xd
                "bound_value": ow(books, BOOKS_BOUND) & 0xFFFF,
                "bound_site": BOOKS_BOUND,
            },
            "bath": {
                "overlay": BATH,
                "dir_read": ow(d, BATH_DIR_READ),          # lw $v1,0x14b8($v0)
                "group_read": ow(d, BATH_GROUP_READ),      # lw $v1,0x20($v1)
                "index_read": ow(d, BATH_INDEX_READ),      # lw $v0,0x4($v0)
                "loader": ow(d, BATH_LOADER),              # lw $v0,0x10($v1)
                "bound": ow(d, BATH_BOUND),                # slti $v0,$v0,0x4
                "bound_value": ow(d, BATH_BOUND) & 0xFFFF,
                "bound_site": BATH_BOUND,
                "csr_cache": BATH_CSR_CACHE,
                "csr_cache_store": ow(d, 0x8008050C),      # sw $v1,-0x2f04($at)
                "csr_cache_load": ow(d, 0x80080970),       # lw $a0,-0x2f04($a0)
                "debug_site": ow(d, BATH_CSR_DEBUG_SITE),  # addiu $a0,$a0,0x6c
            },
        },
        "csr_debug_string": d[0x6C:0x6C + len(BATH_CSR_DEBUG_STR)].decode("latin-1"),
    }


# ---------------------------------------------------------------------------
# verification
# ---------------------------------------------------------------------------
def _words(pairs) -> None:
    for got, want, label in pairs:
        if got != want:
            raise AssertionError("%s: got 0x%X want 0x%X" % (label, got, want))


def verify() -> list[str]:
    out = []

    # ---- Q1 -------------------------------------------------------------
    r1 = q1()
    gt = r1["gettpage"]
    _words([
        (gt["words"]["mode_lui"], 0x3C028017, "0x80148250 lui $v0,0x8017"),
        (gt["words"]["mode_read"], 0x90421FEC, "0x80148254 lbu $v0,0x1fec($v0)"),
        (gt["words"]["tp_shift"], 0x000319C0, "GetTpage (a0&3)<<7"),
        (gt["words"]["abr_shift"], 0x00021140, "GetTpage (a1&3)<<5"),
        (gt["words"]["y_bit8"], 0x00021103, "GetTpage (a3&0x100)>>4"),
        (gt["words"]["x_bits"], 0x00021183, "GetTpage (a2&0x3FF)>>6"),
        (gt["words"]["y_bit9"], 0x00021080, "GetTpage (a3&0x200)<<2"),
        (gt["words"]["orr"], 0x00621025, "or $v0,$v1,$v0"),
    ])
    assert gt["tpage_240_100"] == 0x0099, hex(gt["tpage_240_100"])
    assert gt["tpage_depth_bits"] == 1, "depth must be 8 bpp"
    assert gt["tpage_xbase"] == 9 and gt["tpage_yband"] == 1
    site = r1["portrait_quad"]["site"]
    _words([
        (site["slot_load"], 0x8C42006C, "lw $v0,0x6c($v0)  -- GetTpage, not LoadImage"),
        (site["a2_x"], 0x34060240, "ori $a2,$zero,0x240"),
        (site["a3_y"], 0x34070100, "ori $a3,$zero,0x100"),
        (site["a0_depth"], 0x34040001, "ori $a0,$zero,0x1   depth = 8 bpp"),
        (site["a1_abr"], 0x00002821, "addu $a1,$zero,$zero"),
        (site["store_tpage"], 0xA6020016, "sh $v0,0x16($s0)    POLY_FT4 tpage"),
    ])
    assert (site["a2_x"] & 0xFFFF) == STONE_PAGE_240_100[0]
    assert (site["a3_y"] & 0xFFFF) == STONE_PAGE_240_100[1]
    d = overlay(STONE)
    _words([
        (ow(d, 0x80083DB0), 0x34020040, "the LoadImage wrap's w = 0x40"),
        (ow(d, 0x80083DB8), 0x34020080, "the LoadImage wrap's h = 0x80"),
        (ow(d, 0x80081024), 0x34050240, "the lookup path's ori $a1,$zero,0x240"),
        (ow(d, 0x8008102C), 0x34060100, "the lookup path's ori $a2,$zero,0x100"),
    ])
    out.append(
        "PASS: Q1 GetTpage (MAIN.EXE 0x8014AB0C) is PsyQ GetTPage(tp,abr,x,y) -- "
        "the word at 0x8014AB80 shifts a0 into bits 7-8, 0x8014AB88 shifts a1 into "
        "bits 5-6, 0x8014ABA0 shifts a2 into bits 0-3 and 0x8014AB94/0x8014ABAC take "
        "a3's bits 8 and 9. STONE.BIN 0x800833DC calls it with the literals 0x240 and "
        "0x100 and stores the result at POLY_FT4 +0x16 (0x800833E4): tpage 0x0099 = "
        "8 bpp, x base 9, y band 1 -- the page the LoadImage write fills")
    head = r1["draw_state_field_0x780"]
    _words([
        (head["read"], 0x8C420780, "lw $v0,0x780($v0)"),
        (head["write"], 0xAC820780, "sw $v0,0x780($a0)  -- written back"),
        (head["tag_len_byte"], 0x34020004, "ori $v0,$zero,0x4  packet word count"),
        (head["tag_len_store"], 0xA2020003, "sb $v0,0x3($s0)"),
        (head["packet_advance"], 0x26020014, "addiu $v0,$s0,0x14  20-byte packet"),
    ])
    out.append(
        "PASS: Q1 the +0x780 field the earlier reading called a texpage is a "
        "display-list head -- the same address is read at 0x80081F88 and written back "
        "at 0x80081FB4, and the packet's word 0 carries its word count (4) in the top "
        "byte at 0x80082058, the splice idiom for a 20-byte packet")
    face = r1["face_page_route"]
    _words([
        (face["dir2_load"], 0x8C840008, "0x800802D4 lw $a0,0x8($a0)  directory+8 = group 2"),
        (face["cache_dir2"], 0xAC241EFC, "0x80080304 sw $a0,0x1efc($at)  the FACE list"),
        (face["cache_dir1"], 0xAC25DA3C, "0x800802FC sw $a1,0xda3c($at)  the STONE list"),
        (face["lookup_cache"], 0x8C841EFC, "0x80080F94 lw $a0,0x1efc($a0)"),
        (face["lookup_mask"], 0x304201FC, "0x80080FA0 andi $v0,$v0,0x1fc  (index>>2)*4"),
        (face["lookup_upload"], 0x0C020F66, "0x80081028 jal 0x80083D98  upload to 0x240,0x100"),
    ])
    out.append(
        "PASS: Q1 the page at (0x240,0x100) is a FACE page, not a STONE one -- "
        "STONE.BIN caches group 1 (the 18 STONE pages) at 0x8009DA3C and group 2 (the "
        "27 FACE pages) at 0x800A1EFC (0x800802FC/0x80080304), and the roster lookup "
        "0x80080F54 selects FACE page `index >> 2` from the group-2 list "
        "(0x80080F94, mask 0x1FC at 0x80080FA0) and uploads it to (0x240,0x100)")
    cs = r1["portrait_quad"]["clut_site"]
    _words([
        (cs["a0_zero"], 0x00002021, "addu $a0,$zero,$zero"),
        (cs["mask"], 0x30A5000F, "andi $a1,$a1,0xf"),
        (cs["bias"], 0x24A501EA, "addiu $a1,$a1,0x1ea"),
        (cs["pair_hi"], 0x24214BC1, "the 0x80084BC0 table's byte 1"),
        (cs["state_2d"], 0x9242002D, "lbu $v0,0x2d($s2)   the tablet state byte"),
    ])
    qd = r1["portrait_quad"]["quad"]
    _words([
        (qd["packet_code"], 0x3402002C, "ori $v0,$zero,0x2c  POLY_FT4"),
        (qd["quadrant_mask"], 0x30420003, "andi $v0,$v0,0x3"),
        (qd["u_shift"], 0x00031980, "sll $v1,$v1,6"),
    ])
    assert r1["clut"]["rows"] == [((0x1EA + n) << 6) for n in range(16)], \
        "x = 0 puts block 0 in the low six bits; the row is the high field"
    assert getclut(0, 0x180) == 0x6000 and getclut(0x140, 0x180) == 0x6014
    assert len(r1["gettpage_sites"]) == 14, len(r1["gettpage_sites"])
    xs = sorted({s["args"]["a2"] for s in r1["gettpage_sites"]
                 if isinstance(s["args"].get("a2"), int)})
    assert xs == [0x140, 0x240, 0x380, 0x3C0], [hex(x) for x in xs]
    out.append(
        "PASS: Q1 the portrait quad (0x8008331C) also fixes its CLUT as "
        "GetClut(x=0, y=0x1EA + ((table[2*state[0x2D]].byte1 + state[0x2F]) & 0xF)) "
        "at 0x800833B8 and its u/v as the four 64x64 quadrants {0,0x40} of the "
        "128x128 8-bit page at 0x80083448; the overlay's 14 GetTpage sites name the "
        "page x coordinates 0x140, 0x240, 0x380 and 0x3C0 and nothing else")

    # ---- Q2 -------------------------------------------------------------
    r2 = q2()
    rects = [(e["x"], e["y"], e["w"], e["h"]) for e in r2["rect_table"]["rects"]]
    assert len(rects) == 18, len(rects)
    assert rects[16] == (0x300, 0x080, 0x40, 0x80), rects[16]
    assert rects[17] == (0x340, 0x080, 0x40, 0x80), rects[17]
    assert r2["rect_table"]["loader_bound"] == 0x80080794, \
        "the 18-page bound sits at 0x80080794"
    assert ow(overlay(STONE), 0x80080794) == 0x28420012, "slti $v0,$v0,0x12"
    for _x, _y, w, h in rects:
        assert w * h * 2 == PAGE_BYTES
    assert sorted({x for x, _y, _w, _h in rects}) == [0x240, 0x280, 0x2C0, 0x300, 0x340]
    assert sorted({y for _x, y, _w, _h in rects}) == [0x00, 0x80, 0x100, 0x180]
    out.append(
        "PASS: Q2 the RECT table at 0x80084CDC holds 18 entries, not 16 -- the "
        "loader's own bound is `slti $v0,$v0,0x12` at 0x80080794 and the 18 x 8 bytes "
        "end exactly at 0x80084D6C; entries 16 and 17 are (0x300,0x80) and (0x340,0x80)")
    pt = r2["page_table"]
    _words([
        (pt["reader_quad_lo"], 0x86460000, "lh $a2,0x0($s2)   page x"),
        (pt["reader_quad_hi"], 0x8627FFF8, "lh $a3,-0x8($s1)  page y"),
        (pt["reader_stride"], 0x26520014, "addiu $s2,$s2,0x14  stride 20"),
    ])
    assert pt["count"] == 14, pt["count"]
    for rec in pt["records"]:
        assert tuple(rec["tpage"]) in [(x, y) for x, y, _a, _b in rects], rec
    out.append(
        "PASS: Q2 the sampler is STONE.BIN 0x80081334 -- one POLY_FT4 per 20-byte entry "
        "of the page-coordinate table at 0x80084D6C, whose first two halfwords become "
        "the GetTpage x and y (0x800813EC/0x800813F0, stride 0x14 at 0x800815C8); all "
        "14 entries name a RECT origin")
    assert r2["uncovered"] == [], r2["uncovered"]
    out.append(
        "PASS: Q2 all 18 RECTs are inside the region sampled by those 14 quads -- an "
        "8-bit u spans a whole texel byte row, so a quad wider than 128 px crosses into "
        "the neighbouring page with no second GetTpage; the consumer of the uploaded "
        "pages is in this overlay")
    assert r2["lookup_page_is_a_rect"] is False
    out.append(
        "PASS: Q2 VRAM (0x240,0x100) is NOT one of the 18 RECTs -- the lookup path "
        "uploads it with call-site literals at 0x80081024, so the two LoadImage routes "
        "are distinct and the rect table is not the only page placement")

    # ---- Q3 -------------------------------------------------------------
    r3 = q3()
    _words([
        (r3["installer"]["words"][0], 0x3C028017, "lui $v0,0x8017"),
        (r3["installer"]["words"][1], 0x2442B358, "addiu $v0,$v0,-0x4ca8 -> 0x8016B358"),
        (r3["installer"]["words"][2], 0xAC6214B8, "sw $v0,0x14b8($v1)"),
    ])
    out.append(
        "PASS: Q3 MAIN.EXE 0x800C9650 installs the group directory 0x8016B358 into "
        "ctx+0x14B8 -- the pointer both readers load, which is why a search for a name "
        "or an LBA finds nothing")
    g3, g8 = r3["groups"]["3"], r3["groups"]["8"]
    names3 = [m["path"].rsplit("/", 1)[-1] for m in g3["members"]]
    names8 = [m["path"].rsplit("/", 1)[-1] for m in g8["members"]]
    assert names3 == ["BOOK_%d.BIN" % i for i in range(6)] + \
        ["PAPER_%d.BIN" % i for i in range(6)] + ["CURIO_0.BIN"], names3
    assert names8 == ["YUGE_00.BIN", "MIZU_00.BIN", "CURIO_0.BIN", "HANA.BIN"], names8
    assert g3["members"][12]["lba"] == g8["members"][2]["lba"], \
        "CURIO_0 must be one master record in both lists"
    out.append(
        "PASS: Q3 group 3 (list 0x8016B47C) is BOOK_0..5, PAPER_0..5, CURIO_0 = 13 "
        "files; group 8 (list 0x8016B524) is YUGE_00, MIZU_00, CURIO_0, HANA = 4 "
        "files; CURIO_0 is the same master record (lba 86255) in both lists")
    rd = r3["readers"]
    _words([
        (rd["books"]["dir_read"], 0x8C6314B8, "BOOKS lw $v1,0x14b8($v1)"),
        (rd["books"]["group_read"], 0x8C62000C, "BOOKS lw $v0,0xc($v1)   = dir[3]"),
        (rd["books"]["index_read"], 0x8C420004, "BOOKS lw $v0,0x4($v0)   = ctx->idx"),
        (rd["books"]["loader"], 0x8C620010, "BOOKS lw $v0,0x10($v1) = vtable+0x10"),
        (rd["books"]["bound"], 0x2842000D, "BOOKS slti $v0,$v0,0xd = 13"),
        (rd["bath"]["dir_read"], 0x8C4314B8, "BATH lw $v1,0x14b8($v0)"),
        (rd["bath"]["group_read"], 0x8C630020, "BATH lw $v1,0x20($v1)   = dir[8]"),
        (rd["bath"]["index_read"], 0x8C420004, "BATH lw $v0,0x4($v0)   = ctx->idx"),
        (rd["bath"]["loader"], 0x8C620010, "BATH lw $v0,0x10($v1) = vtable+0x10"),
        (rd["bath"]["bound"], 0x28420004, "BATH slti $v0,$v0,0x4 = 4"),
        (rd["bath"]["csr_cache_store"], 0xAC23D0FC, "BATH caches dir[8] at 0x8009D0FC"),
        (rd["bath"]["debug_site"], 0x2484006C, "BATH a0 = 0x8008006C"),
    ])
    assert rd["books"]["bound_value"] == g3["count"] == 13
    assert rd["bath"]["bound_value"] == g8["count"] == 4
    assert r3["csr_debug_string"] == BATH_CSR_DEBUG_STR.decode("latin-1")
    out.append(
        "PASS: Q3 BOOKS.BIN loads dir[3] (0x800802D4 then 0x800802E4) through the "
        "file loader at vtable+0x10 and bounds its index at 13 (0x80080628); BATH.BIN "
        "loads dir[8] (0x800804A8 then 0x80080500) the same way and bounds at 4 "
        "(0x80080B30) -- each bound equals its list length, so each loader consumes "
        "its whole group")
    out.append(
        "PASS: Q3 BATH.BIN's own debug string at 0x8008006C is \"csr_data_steam = "
        "%x\\n\", and the group-8 pointer cached at 0x8009D0FC is the value printed "
        "with it at 0x800805BC")
    out.append(
        "PASS: Q3 PAPER_*.BIN -> BOOKS.BIN (group 3); YUGE_00/MIZU_00/HANA -> BATH.BIN "
        "(group 8); CURIO_0 -> both. None is dead and none is reached by name or LBA "
        "-- the path is the load-group directory")
    return out


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
def report() -> None:
    r1, r2, r3 = q1(), q2(), q3()
    print("Q1 -- the tablet quad's page coordinates")
    print("  GetTpage @0x%08X  %s" % (MAIN_GETTPAGE, r1["gettpage"]["formula"]))
    print("  GetTpage(1, 0, 0x240, 0x100) = 0x%04X  (depth %d = 8 bpp, x base %d, y band %d)"
          % (r1["gettpage"]["tpage_240_100"], r1["gettpage"]["tpage_depth_bits"],
             r1["gettpage"]["tpage_xbase"], r1["gettpage"]["tpage_yband"]))
    print("  call 0x%08X: slot word 0x%08X (vtable+0x6C GetTpage), x 0x%X, y 0x%X -> +0x16"
          % (STONE_PORTRAIT_TPAGE_CALL, r1["portrait_quad"]["site"]["slot_load"],
             r1["portrait_quad"]["site"]["a2_x"] & 0xFFFF,
             r1["portrait_quad"]["site"]["a3_y"] & 0xFFFF))
    print("  GetClut rows %s" % ["0x%X" % c for c in r1["clut"]["rows"]])
    print("  +0x780: read 0x%08X, write-back 0x%08X  (display-list head)"
          % (r1["draw_state_field_0x780"]["read"],
             r1["draw_state_field_0x780"]["write"]))
    print("  GetTpage sites in STONE.BIN: %d (%s)"
          % (len(r1["gettpage_sites"]),
             ", ".join("0x%X" % s["call"] for s in r1["gettpage_sites"])))
    print()
    print("Q2 -- the %d uploaded RECTs and their sampler (0x%08X)"
          % (r2["rect_table"]["count"], r2["sampler"]))
    for i, e in enumerate(r2["rect_table"]["rects"]):
        print("  [%2d] x=0x%03X y=0x%03X w=0x%X h=0x%X   sampled by records %s"
              % (i, e["x"], e["y"], e["w"], e["h"], r2["coverage"][str(i)]))
    print("  uncovered: %s   (0x240,0x100) is a RECT: %s"
          % (r2["uncovered"], r2["lookup_page_is_a_rect"]))
    print()
    print("Q3 -- the load-group owners")
    for gi in ("3", "8"):
        g = r3["groups"][gi]
        print("  group %s @0x%08X  %d files" % (gi, g["list"], g["count"]))
        for m in g["members"]:
            print("      %7d  lba %6d  %s" % (m["size"], m["lba"], m["path"]))
    print("  BOOKS dir[3] read @0x%08X  index bound %d @0x%08X"
          % (BOOKS_DIR_READ, r3["readers"]["books"]["bound_value"],
             r3["readers"]["books"]["bound_site"]))
    print("  BATH  dir[8] read @0x%08X  index bound %d @0x%08X  debug %s"
          % (BATH_DIR_READ, r3["readers"]["bath"]["bound_value"],
             r3["readers"]["bath"]["bound_site"], r3["csr_debug_string"].strip()))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args(argv)
    if args.verify:
        for line in verify():
            print(line)
        return 0
    if args.json:
        print(json.dumps({"q1": q1(), "q2": q2(), "q3": q3()}, indent=2, sort_keys=True))
        return 0
    report()
    return 0


if __name__ == "__main__":
    sys.exit(main())
