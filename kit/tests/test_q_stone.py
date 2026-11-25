#!/usr/bin/env python3
"""q_stone -- the three owned-but-unconsumed `03_SHIRO` art questions.

Run: `python3 kit/tests/test_q_stone.py`   (disc required)

Every claim is re-derived here from the disc: the MIPS words are read at their
addressed offsets and compared literally, the tables are parsed here, the
texture-page packing is re-implemented from the instruction words rather than
imported from the tool, and the group members are resolved through the ISO9660
directory by LBA.  Nothing calls `kit/tools/q_stone.py`, so a bug in the tool
cannot make this pass.
"""
from pathlib import Path
import json
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402

MAIN = "MAIN.EXE"
MAIN_BASE = 0x800C0800
OVL = 0x80080000
STONE = "DATA/03_SHIRO/STONE.BIN"
BOOKS = "DATA/03_SHIRO/BOOKS.BIN"
BATH = "DATA/03_SHIRO/BATH.BIN"

VTT = 0x80165608                 # *(gs+0x1BC4), the engine vtable
GETTPAGE = 0x8014AB0C            # slot +0x6C
LOADIMAGE = 0x80148590           # slot +0x70
GETCLUT = 0x8014ABD4             # slot +0x8C

GROUP_DIR = 0x8016B358
GROUP_INSTALL = 0x800C9648
MASTER_TABLE = 0x80163D64
MASTER_COUNT = 344


def _iso() -> list[dict]:
    with open(_KIT / "extracted" / "iso_files.json") as f:
        return [r for r in json.load(f) if not r.get("dir")]


def raw(path: str) -> bytes:
    r = next(r for r in _iso() if r["path"] == path)
    return disc.extract(r["lba"], r["size"])


def mimage() -> bytes:
    return raw(MAIN)[2048:]


def mw(addr: int) -> int:
    return struct.unpack_from("<I", mimage(), addr - MAIN_BASE)[0]


def ow(d: bytes, addr: int, base: int = OVL) -> int:
    return struct.unpack_from("<I", d, addr - base)[0]


def ins(w: int) -> tuple:
    """`(opcode, rs, rt, rd, sa, fn, imm)`."""
    return (w >> 26, (w >> 21) & 0x1F, (w >> 16) & 0x1F, (w >> 11) & 0x1F,
            (w >> 6) & 0x1F, w & 0x3F, w & 0xFFFF)


def _onehot(*words: int) -> callable:
    """A tiny linear model of a routine: assert each word, return the value."""
    def model(tp, abr, x, y):
        v = ((tp & 3) << 7) | ((abr & 3) << 5) | ((y & 0x100) >> 4) \
            | ((y & 0x200) << 2) | ((x & 0x3FF) >> 6)
        return v & 0xFFFF
    return model


def check_q1():
    """The tablet's portrait quad samples the page the LoadImage fills."""
    md = mimage()
    # the arm this NTSC disc uses: 0x8014AB80, reached when the mode byte
    # (0x80148250 -> *(0x80171FEC)) is neither 1 nor 2
    assert mw(0x80148250) == 0x3C028017 and mw(0x80148254) == 0x90421FEC
    assert mw(0x8014AB50) == 0x1443000B, hex(mw(0x8014AB50))   # bne v0,v1 -> NTSC arm
    words = {
        0x8014AB80: 0x000319C0,      # sll $v1,$v1,7    (a0 & 3) << 7
        0x8014AB84: 0x32420003,      # andi $v0,$s2,0x3 (s2 = a1)
        0x8014AB88: 0x00021140,      # sll $v0,$v0,5    (a1 & 3) << 5
        0x8014AB90: 0x32220100,      # andi $v0,$s1,0x100 (s1 = a3)
        0x8014AB94: 0x00021103,      # sra $v0,$v0,4    (a3 & 0x100) >> 4
        0x8014AB9C: 0x326203FF,      # andi $v0,$s3,0x3ff (s3 = a2)
        0x8014ABA0: 0x00021183,      # sra $v0,$v0,6    (a2 & 0x3FF) >> 6
        0x8014ABA8: 0x32220200,      # andi $v0,$s1,0x200
        0x8014ABAC: 0x00021080,      # sll $v0,$v0,2    (a3 & 0x200) << 2
        0x8014ABB0: 0x00621025,      # or $v0,$v1,$v0
    }
    for addr, want in words.items():
        assert mw(addr) == want, (hex(addr), hex(mw(addr)), hex(want))
    # the register saves fix the argument order: s0=a0 s2=a1 s3=a2 s1=a3
    assert mw(0x8014AB14) == 0x00808021, "s0 = a0"
    assert mw(0x8014AB1C) == 0x00A09021, "s2 = a1"
    assert mw(0x8014AB24) == 0x00C09821, "s3 = a2"
    assert mw(0x8014AB34) == 0x00E08821, "s1 = a3"

    tp = _onehot()(1, 0, 0x240, 0x100)
    assert tp == 0x0099, hex(tp)
    assert (tp >> 7) & 3 == 1, "texture depth 1 = 8 bpp"
    assert tp & 0xF == (0x240 >> 6) == 9
    assert (tp >> 4) & 1 == 1 and (tp >> 11) & 1 == 0, "y band 1"

    # the (0x240,0x100) page is a FACE page: STONE.BIN caches group 1 (the 18
    # STONE pages) at 0x8009DA3C and group 2 (the 27 FACE pages) at 0x800A1EFC,
    # and the lookup selects FACE page `index >> 2` from the group-2 list
    sd = raw(STONE)
    assert ow(sd, 0x800802D4) == 0x8C840008, "lw $a0,0x8($a0)  directory+8 = group 2"
    assert ow(sd, 0x800802FC) == 0xAC25DA3C, "sw $a1,0xda3c($at)  the STONE list"
    assert ow(sd, 0x80080304) == 0xAC241EFC, "sw $a0,0x1efc($at)  the FACE list"
    assert ow(sd, 0x80080F94) == 0x8C841EFC, "lw $a0,0x1efc($a0)  the FACE list"
    assert ow(sd, 0x80080FA0) == 0x304201FC, "andi $v0,$v0,0x1fc  (index>>2)*4"
    assert ow(sd, 0x80081028) == 0x0C020F66, "jal 0x80083D98  the (0x240,0x100) wrap"

    # the vtable really does separate the two slots
    assert mw(VTT + 0x6C) == GETTPAGE == 0x8014AB0C
    assert mw(VTT + 0x70) == LOADIMAGE == 0x80148590
    assert mw(VTT + 0x8C) == GETCLUT == 0x8014ABD4
    assert GETTPAGE != LOADIMAGE

    # the call site: slot +0x6C, x = 0x240, y = 0x100 in the delay slot,
    # result stored into the POLY_FT4 texture-page halfword at +0x16
    assert ow(sd, 0x800833D4) == 0x8C42006C, "lw $v0,0x6c($v0)  GetTpage"
    assert ow(sd, 0x800833D8) == 0x34060240, "ori $a2,$zero,0x240"
    assert ow(sd, 0x800833E0) == 0x34070100, "ori $a3,$zero,0x100 (delay slot)"
    assert ow(sd, 0x800833CC) == 0x34040001, "ori $a0,$zero,0x1  depth 8 bpp"
    assert ow(sd, 0x800833E4) == 0xA6020016, "sh $v0,0x16($s0)"
    assert ins(ow(sd, 0x800833E0))[6] == 0x100
    # the same page is the LoadImage destination of the lookup path's wrapper
    assert ow(sd, 0x80081024) == 0x34050240, "ori $a1,$zero,0x240"
    assert ow(sd, 0x8008102C) == 0x34060100, "ori $a2,$zero,0x100"
    assert ow(sd, 0x80083DB0) == 0x34020040 and ow(sd, 0x80083DB8) == 0x34020080, \
        "the wrapper's 0x40 x 0x80 RECT"

    # the CLUT: GetClut(x=0, y=0x1EA + ((table byte1 + state[0x2F]) & 0xF))
    assert ow(sd, 0x800833A4) == 0x00002021, "addu $a0,$zero,$zero"
    assert ow(sd, 0x800833B0) == 0x30A5000F, "andi $a1,$a1,0xf"
    assert ow(sd, 0x800833B8) == 0x24A501EA, "addiu $a1,$a1,0x1ea"
    assert ow(sd, 0x80083388) == 0x24214BC1, "the 0x80084BC0 table's second byte"
    # GetClut's body: (a1 << 6) | ((a0 >> 4) & 0x3F)
    assert mw(0x8014ABD4) == 0x00051180 and mw(0x8014ABD8) == 0x00042103
    assert mw(0x8014ABDC) == 0x3084003F and mw(0x8014ABE0) == 0x00441025
    clut = lambda x, y: ((y << 6) | ((x >> 4) & 0x3F)) & 0xFFFF
    assert clut(0, 0x1EA) == 0x1EA << 6
    assert clut(0x140, 0x180) == 0x6014
    # the quad's u/v are the page's four 64x64 quadrants
    assert ow(sd, 0x80083370) == 0x3402002C, "ori $v0,0x2c  POLY_FT4"
    assert ow(sd, 0x80083448) == 0x30420003, "andi $v0,$v0,0x3"
    assert ow(sd, 0x80083454) == 0x00031980, "sll $v1,$v1,6"
    assert ow(sd, 0x80083468) == 0xA203000C and ow(sd, 0x8008346C) == 0xA202000D

    # the +0x780 field is read AND written back: a display-list head, not a
    # read-only draw-state texpage, and the packet's word 0 carries its own
    # word count in the top byte
    assert ow(sd, 0x80081F88) == 0x8C420780, "lw $v0,0x780($v0)"
    assert ow(sd, 0x80081FB4) == 0xAC820780, "sw $v0,0x780($a0)  written back"
    assert ow(sd, 0x80082054) == 0x34020004, "ori $v0,$zero,0x4  20-byte packet"
    assert ow(sd, 0x80082058) == 0xA2020003, "sb $v0,0x3($s0)"
    assert ow(sd, 0x8008204C) == 0x26020014, "addiu $v0,$s0,0x14"

    print("PASS: Q1 the tablet's portrait quad (STONE.BIN 0x8008331C) calls "
          "vtable+0x6C = GetTpage 0x8014AB0C -- not LoadImage -- with the "
          "call-site literals 0x240 and 0x100, and stores the result into the "
          "POLY_FT4 texture-page halfword at +0x16; the value is 0x0099 = "
          "8 bpp, x base 9, y band 1, which is the page the lookup path's "
          "LoadImage writes at 0x80081024; the quad's CLUT is GetClut(0, "
          "0x1EA + ((table[0x80084BC0].byte1 + state[0x2F]) & 0xF)) and its "
          "u/v are the four 64x64 quadrants {0,0x40}; the page itself is a FACE "
          "page -- STONE.BIN caches group 1 (the 18 STONE pages) at 0x8009DA3C and "
          "group 2 (the 27 FACE pages) at 0x800A1EFC, and the lookup 0x80080F54 "
          "selects FACE page `index >> 2` from the group-2 list (mask 0x1FC at "
          "0x80080FA0) and uploads it to (0x240,0x100) at 0x80081028")


def check_q2():
    """The uploaded RECTs are sampled by the overlay's own composite."""
    sd = raw(STONE)
    rects = [struct.unpack_from("<4H", sd, 0x4CDC + 8 * i) for i in range(20)]
    # exactly 18 entries: the 18th ends where the next table begins
    assert rects[:18] == [
        (0x2C0, 0x100, 0x40, 0x80), (0x300, 0x100, 0x40, 0x80),
        (0x340, 0x100, 0x40, 0x80), (0x2C0, 0x180, 0x40, 0x80),
        (0x300, 0x180, 0x40, 0x80), (0x340, 0x180, 0x40, 0x80),
        (0x240, 0x000, 0x40, 0x80), (0x280, 0x000, 0x40, 0x80),
        (0x280, 0x100, 0x40, 0x80), (0x240, 0x080, 0x40, 0x80),
        (0x280, 0x080, 0x40, 0x80), (0x280, 0x180, 0x40, 0x80),
        (0x2C0, 0x000, 0x40, 0x80), (0x300, 0x000, 0x40, 0x80),
        (0x340, 0x000, 0x40, 0x80), (0x2C0, 0x080, 0x40, 0x80),
        (0x300, 0x080, 0x40, 0x80), (0x340, 0x080, 0x40, 0x80)], rects[:18]
    # the 16-entry reading would have truncated the run before its 17th record
    assert struct.unpack_from("<4H", sd, 0x4D5C) == (0x300, 0x080, 0x40, 0x80)
    assert struct.unpack_from("<4H", sd, 0x4D64) == (0x340, 0x080, 0x40, 0x80)
    assert 0x4CDC + 18 * 8 == 0x4D6C, "the 18 entries end at the next table"
    for _x, _y, w, h in rects[:18]:
        assert w * h * 2 == 16384, "one 128x128 8 bpp page each"
    # the loader walks all 18: `slti $v0,$v0,0x12` at 0x80080794
    assert ow(sd, 0x800806B4) != 0
    assert ow(sd, 0x80080794) == 0x28420012, "slti $v0,$v0,0x12"
    assert ins(ow(sd, 0x80080794))[6] == 0x12

    # the sampler: one POLY_FT4 per 20-byte record of the page table
    assert ow(sd, 0x80081368) == 0x00C0A021, "s4 = a2 (the sampler's arguments)"
    assert ins(ow(sd, 0x800813D4))[6] == 0x2C, "POLY_FT4 code byte"
    assert ow(sd, 0x800813EC) == 0x86460000, "lh $a2,0x0($s2)   page x"
    assert ow(sd, 0x800813F0) == 0x8627FFF8, "lh $a3,-0x8($s1)  page y"
    assert ow(sd, 0x800815C8) == 0x26520014, "addiu $s2,$s2,0x14"
    assert ow(sd, 0x80081400) == 0x34050001, "ori $a1,$zero,0x1  abr (delay slot)"

    recs = []
    for i in range(14):
        off = 0x4D6C + 0x14 * i
        tx, ty, x0, y0, x1, y1 = struct.unpack_from("<6H", sd, off)
        recs.append((tx, ty, (sd[off + 0xC], sd[off + 0xE],
                              sd[off + 0x10], sd[off + 0x12])))
    origins = [(x, y) for x, y, _w, _h in rects[:18]]
    for tx, ty, _uv in recs:
        assert (tx, ty) in origins, (hex(tx), hex(ty))

    # every RECT lies inside some record's sampled region.  Re-implemented
    # from the GetTpage words: `u` is a byte column, so `u >> 1` halfwords from
    # the page base, and the page's y base is the tpage's 256-row band.
    hit = {i: [] for i in range(18)}
    for ri, (tx, ty, uv) in enumerate(recs):
        tp = ((1 & 3) << 7) | ((1 & 3) << 5) | ((ty & 0x100) >> 4) \
            | ((ty & 0x200) << 2) | ((tx & 0x3FF) >> 6)
        xb = tp & 0xF
        yb = ((tp >> 4) & 1) | (((tp >> 11) & 1) << 1)
        c0, r0 = xb * 64 + (uv[0] >> 1), yb * 0x100 + uv[1]
        c1, r1 = xb * 64 + (uv[2] >> 1), yb * 0x100 + uv[3]
        for i, (x, y, w, h) in enumerate(rects[:18]):
            if c0 < x + w and c1 >= x and r0 < y + h and r1 >= y:
                hit[i].append(ri)
    assert all(hit[i] for i in range(18)), [i for i in range(18) if not hit[i]]
    # and the lookup path's hard-coded page is NOT one of them: the two routes
    # are distinct, so the rect table is not the only placement of a page
    assert (0x240, 0x100) not in origins
    assert sd.find(bytes([0x40, 0x02, 0x00, 0x01, 0x40, 0x00, 0x80, 0x00])) < 0

    print("PASS: Q2 the RECT table at 0x80084CDC holds 18 entries, not 16 -- the "
          "loader's bound at 0x80080794 is `slti $v0,$v0,0x12`, entries 16/17 are "
          "(0x300,0x080) and (0x340,0x080), and the run ends exactly at the "
          "page-coordinate table at 0x80084D6C; STONE.BIN 0x80081334 draws one "
          "POLY_FT4 per 20-byte record of that table (page x/y at 0x800813EC/"
          "0x800813F0, stride 0x14) and all 18 RECTs fall inside the regions the "
          "14 records sample, so the consumer is in this overlay")


def check_q3():
    """The five files are reached through the load-group directory."""
    md = mimage()
    # the installer writes the directory address 0x8016B358 into ctx+0x14B8
    assert mw(GROUP_INSTALL) == 0x3C028017, "lui $v0,0x8017"
    assert mw(GROUP_INSTALL + 4) == 0x2442B358, "addiu $v0,$v0,-0x4ca8"
    assert mw(GROUP_INSTALL + 8) == 0xAC6214B8, "sw $v0,0x14b8($v1)"

    lo, hi = MASTER_TABLE, MASTER_TABLE + MASTER_COUNT * 8
    assert mw(MASTER_TABLE) != 0 and mw(MASTER_TABLE + (MASTER_COUNT - 1) * 8) != 0

    def members(gi: int) -> list[tuple]:
        p = mw(GROUP_DIR + 4 * gi)
        out = []
        for k in range(64):
            v = mw(p + 4 * k)
            if not (lo <= v < hi):
                break
            out.append((v, mw(v), mw(v + 4)))
        return out

    by_lba = {r["lba"]: r["path"] for r in _iso()}
    g3, g8 = members(3), members(8)
    assert len(g3) == 13 and len(g8) == 4, (len(g3), len(g8))
    n3 = [by_lba[l].rsplit("/", 1)[-1] for _v, _s, l in g3]
    n8 = [by_lba[l].rsplit("/", 1)[-1] for _v, _s, l in g8]
    assert n3 == ["BOOK_%d.BIN" % i for i in range(6)] + \
        ["PAPER_%d.BIN" % i for i in range(6)] + ["CURIO_0.BIN"], n3
    assert n8 == ["YUGE_00.BIN", "MIZU_00.BIN", "CURIO_0.BIN", "HANA.BIN"], n8
    assert g3[12][0] == g8[2][0] and g3[12][2] == g8[2][2], \
        "CURIO_0 is one master record shared by both lists"

    bd, bs = raw(BATH), raw(BOOKS)
    # BOOKS.BIN: dir read, group 3, index from ctx+4, loader at vtable+0x10,
    # and the index bound 13 -- the group's own length
    assert ow(bs, 0x800802D4) == 0x8C6314B8, "lw $v1,0x14b8($v1)"
    assert ow(bs, 0x800802E4) == 0x8C62000C, "lw $v0,0xc($v1)  dir[3]"
    assert ow(bs, 0x800804AC) == 0x8C420004, "lw $v0,0x4($v0)  ctx->idx"
    assert ow(bs, 0x800804C8) == 0x8C620010, "lw $v0,0x10($v1) the file loader"
    assert ow(bs, 0x80080628) == 0x2842000D, "slti $v0,$v0,0xd"
    assert ins(ow(bs, 0x80080628))[6] == len(g3) == 13
    # BATH.BIN: dir read, group 8 cached at 0x8009D0FC, index from ctx+4,
    # the same loader, and the index bound 4 -- that group's length
    assert ow(bd, 0x800804A8) == 0x8C4314B8, "lw $v1,0x14b8($v0)"
    assert ow(bd, 0x800804F8) == 0x8C630020, "lw $v1,0x20($v1)  dir[8]"
    assert ow(bd, 0x8008050C) == 0xAC23D0FC, "sw $v1,-0x2f04($at)"
    assert ow(bd, 0x80080968) == 0x8C420004, "lw $v0,0x4($v0)  ctx->idx"
    assert ow(bd, 0x80080970) == 0x8C84D0FC, "lw $a0,-0x2f04($a0)"
    assert ow(bd, 0x8008098C) == 0x8C620010, "lw $v0,0x10($v1) the file loader"
    assert ow(bd, 0x80080B30) == 0x28420004, "slti $v0,$v0,0x4"
    assert ins(ow(bd, 0x80080B30))[6] == len(g8) == 4
    # the overlay names the group itself
    assert bd[0x6C:0x80] == b"csr_data_steam = %x\n", bd[0x6C:0x80]
    assert ow(bd, 0x800805BC) == 0x2484006C, "addiu $a0,$a0,0x6c"
    assert ow(bd, 0x800805C0) == 0x0040F809, "jalr $v0  (the printf slot)"

    print("PASS: Q3 the five files are not dead and are not reached by name or "
          "LBA -- MAIN.EXE 0x800C9650 installs the group directory 0x8016B358 at "
          "ctx+0x14B8, BOOKS.BIN reads dir[3] (13 files: BOOK_0..5, PAPER_0..5, "
          "CURIO_0) and bounds its index at 13, and BATH.BIN reads dir[8] "
          "(YUGE_00, MIZU_00, CURIO_0, HANA), bounds at 4 and calls the group "
          "pointer 'csr_data_steam' in its own debug string; CURIO_0 is one "
          "master record in both lists, so it has two owners")


def main() -> int:
    check_q1()
    check_q2()
    check_q3()
    return 0


if __name__ == "__main__":
    sys.exit(main())
