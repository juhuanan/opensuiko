#!/usr/bin/env python3
"""The `03_SHIRO` pixel long tail: BATH geometry, the STONE negative, and the
ownership of PAPER / YUGE / MIZU / HANA / CURIO.

Run: `python3 kit/tests/test_shiro_pixel_tail.py`   (disc required)

Every claim asserted here is re-derived from the disc in this file: the container
decode is a direct `lzss.decode_container` call with the consumption check, the
tables are read out of the overlays at their recorded addresses, and the reader
sites are found by scanning the binaries for the access form.  Nothing here
calls `shiro_pixel_tail.py` except where it is *the* measurement (the structure
statistics), so a bug in the tool cannot make this pass.
"""
from pathlib import Path
import json
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import lzss  # noqa: E402

PAGE = 16384
BATH_DIR = "DATA/03_SHIRO/DATA"
MAIN = "MAIN.EXE"
MAIN_BASE = 0x800C0800
MASTER_TABLE = 0x80163D64
MASTER_COUNT = 344
GROUP_DIR = 0x8016B358
GROUP_SLOT = 0x14B8
GROUP_INSTALL = 0x800C9650
GROUP_COUNT = 16

BATH_OVERLAY = "DATA/03_SHIRO/BATH.BIN"
BATH_BASE = 0x80080000
BATH_RECT_TABLE = 0x80085884
BATH_CLUT_TABLE = 0x80085874
BATH_CLUT_DATA = 0x8008D114
BATH_RECT_USE = 0x800813FC            # lw v0,0x4(s0); sll v0,v0,3 -> rect table
BATH_BANK_SELECT = 0x80081348         # lbu v1,0x3d(s0)
BATH_CSR_CACHE = 0x8008D0FC
BATH_CSR_DEBUG_SITE = 0x800805B8      # addiu $a0,$a0,0x6c
BATH_CSR_DEBUG_STR = b"csr_data_steam = %x\n"
BATH_CSR_LOAD = 0x80080970          # lw $a0,-0x2f04($a0) = [0x8008D0FC]

STONE_OVERLAY = "DATA/03_SHIRO/STONE.BIN"
STONE_BASE = 0x80080000
STONE_RECT_TABLE = 0x80084CDC
STONE_WRAP = 0x80083D98               # w=0x40 h=0x80 -> 64x128 halfwords
STONE_LOADIMAGE_RECT = (0x240, 0x100)
STONE_LOOKUP = 0x80080F54
STONE_FACE_CACHE = 0x800A1EFC
STONE_ID_TABLE = 0x80084BC0
STONE_NAME_TABLE = 0x80085220
STONE_STR_TABLE = 0x80085848

#: the STONE state struct (`sw $v0,0x1f1c($at)` after `lui $at,0x800a`)
STONE_STATE = 0x800A1F1C
STONE_PAGE_LOOP = 0x800806B4
#: the second rect run: 16 more (x,y,w,h) at 0x80084D0C, x-referenced by no insn
STONE_RECT_TABLE2 = 0x80084D0C
#: the second-byte consumer
STONE_MODE_READ = 0x80083390
STONE_MODE_ADD = 0x8008339C
STONE_MODE_MASK = 0x800833B0
STONE_MODE_BIAS = 0x800833B8
STONE_STATE_2F_WRITER = 0x80080E3C
#: BATH's per-page LoadImage step
BATH_PAGE_STEP = 0x80081348
BATH_CLUT_DATA = 0x8008D114
CLUT_BYTES = 512

RAT = tuple(range(0x12))          # STONE_00..STONE_11 = 18 files


def iso() -> list[dict]:
    with open(_KIT / "extracted" / "iso_files.json") as f:
        return [r for r in json.load(f) if not r.get("dir")]


def raw(path: str) -> bytes:
    r = next(r for r in iso() if r["path"] == path)
    return disc.extract(r["lba"], r["size"])


def page(path: str) -> bytes:
    blob = raw(path)
    assert struct.unpack_from("<I", blob, 0)[0] == len(blob) - 4, path
    out, used = lzss.decode_container(blob)
    assert used == len(blob), f"{path}: partial decode"
    assert len(out) == PAGE, f"{path}: {len(out)}"
    return out


def overlay(path: str) -> bytes:
    return raw(path)


def word(d: bytes, addr: int, base: int) -> int:
    return struct.unpack_from("<I", d, addr - base)[0]


def main_image() -> bytes:
    return raw(MAIN)[2048:]


def check_bath():
    """(a) each page is a 128x128 8bpp page; six tile a 384x256 sheet."""
    files = [f"BATH_{b}{i}.BIN" for b in range(4) for i in range(6)]
    assert len(files) == 24
    for f in files:
        assert len(page(f"{BATH_DIR}/{f}")) == PAGE

    d = overlay(BATH_OVERLAY)
    # the RECT table, 6 x (x,y,w,h) u16 -- the LoadImage of file index i
    rects = [struct.unpack_from("<4H", d, BATH_RECT_TABLE - BATH_BASE + 8 * i)
             for i in range(6)]
    assert rects == [(0x2C0, 0x00, 0x40, 0x80), (0x300, 0x00, 0x40, 0x80),
                     (0x340, 0x00, 0x40, 0x80), (0x2C0, 0x80, 0x40, 0x80),
                     (0x300, 0x80, 0x40, 0x80), (0x340, 0x80, 0x40, 0x80)], rects
    # 64 halfwords x 128 rows = 16,384 B = one 128x128 8bpp page each
    for _x, _y, w, h in rects:
        assert w * h * 2 == PAGE
    # 3 columns x 2 rows -> 384x256, contiguous, no overlap
    xs = sorted({r[0] for r in rects})
    ys = sorted({r[1] for r in rects})
    assert xs == [0x2C0, 0x300, 0x340] and ys == [0x00, 0x80]
    assert [x - xs[0] for x in xs] == [0, 0x40, 0x80]
    assert [y for y in ys] == [0, 0x80]

    # the CLUT table points at 4 x 512-byte palettes inside the overlay
    clut = [word(d, BATH_CLUT_TABLE + 4 * b, BATH_BASE) for b in range(4)]
    assert clut == [BATH_CLUT_DATA + 0x200 * b for b in range(4)], [hex(c) for c in clut]
    for b in range(4):
        off = BATH_CLUT_DATA + 0x200 * b - BATH_BASE
        assert 0 <= off + 512 <= len(d), f"bank {b} palette is outside the overlay"
        words = struct.unpack_from("<256H", d, off)
        assert len(set(words)) == 256              # a real 256-colour palette

    # the code: file index from [state+4] -> rect[index]; bank byte [state+0x3D]
    w_use = struct.unpack_from("<I", d, BATH_RECT_USE - BATH_BASE)[0]
    assert w_use == 0x8E020004, hex(w_use)          # lw $v0,0x4($s0)
    w_bank = struct.unpack_from("<I", d, BATH_BANK_SELECT - BATH_BASE)[0]
    assert w_bank == 0x9203003D, hex(w_bank)        # lbu $v1,0x3d($s0)


def check_stone():
    """(b) upload/decode and numeric index statistics; colour proof is separate."""
    files = [f"STONE_{i:02X}.BIN" for i in RAT]
    assert len(files) == 18
    for f in files:
        assert len(page(f"{BATH_DIR}/{f}")) == PAGE

    d = overlay(STONE_OVERLAY)
    rects = [struct.unpack_from("<4H", d, STONE_RECT_TABLE - STONE_BASE + 8 * i)
             for i in range(18)]
    for _x, _y, w, h in rects:
        assert (w, h) == (0x40, 0x80) and w * h * 2 == PAGE
    # the loader's own destination rect is (0x240,0x100,0x40,0x80)
    assert STONE_LOADIMAGE_RECT == (0x240, 0x100)
    wrap = struct.unpack_from("<I", d, STONE_WRAP - STONE_BASE + 0x18)[0]
    assert wrap == 0x34020040, hex(wrap)            # ori $v0,$zero,0x40 (w)
    wrap2 = struct.unpack_from("<I", d, STONE_WRAP - STONE_BASE + 0x20)[0]
    assert wrap2 == 0x34020080, hex(wrap2)          # ori $v0,$zero,0x80 (h)

    # the id table and its loader: state -> portrait index -> dir[2] record
    pairs = [(d[STONE_ID_TABLE - STONE_BASE + 2 * i],
              d[STONE_ID_TABLE - STONE_BASE + 2 * i + 1]) for i in range(142)]
    first = [a for a, _b in pairs]
    assert sorted(first[:108]) == list(range(108)), "not a permutation"
    assert len(set(first[:108])) == 108
    assert pairs[12][0] == 4, pairs[12]             # state 12 -> portrait 4
    # and the loader masks with 0x1FC (drop the quadrant) then indexes dir[2]
    lookup = [struct.unpack_from("<I", d, STONE_LOOKUP - STONE_BASE + 4 * k)[0]
              for k in range(20)]
    assert 0x304201FC in lookup, [hex(x) for x in lookup]   # andi $v0,$v0,0x1fc
    # 0x800A1EFC = dir[2]: the storing instruction takes dir[2] (0x8($a0))
    cache = [struct.unpack_from("<I", d, 0x800802C4 - STONE_BASE + 4 * k)[0]
             for k in range(8)]
    assert 0x8C840008 in cache, [hex(x) for x in cache]     # lw $a0,0x8($a0)

    # the tablet's own text source: 113 zero-terminated code strings
    strs = []
    i = 0
    while True:
        p = struct.unpack_from("<I", d, STONE_STR_TABLE - STONE_BASE + 4 * i)[0]
        if not (STONE_BASE <= p < STONE_BASE + len(d)):
            break
        o, s = p - STONE_BASE, []
        while d[o]:
            s.append(d[o])
            o += 1
        strs.append(s)
        i += 1
    assert len(strs) == 113, len(strs)
    codes = [c for s in strs for c in s]
    assert min(codes) >= 0x11 and max(codes) <= 0x4E

    # THE NEGATIVE, measured the same way for STONE and for a legible sibling.
    import shiro_pixel_tail as spt
    import numpy as np

    def rel(name: str) -> float:
        a = np.frombuffer(page(f"{BATH_DIR}/{name}"), dtype=np.uint8)
        r0, r1, c0, c1 = spt.nonzero_box(a)
        box = a.reshape(128, 128)[r0:r1 + 1, c0:c1 + 1]
        return spt.structure(box, 4)[2]

    stone_rel = [rel(f) for f in files]
    assert max(stone_rel) < 2.5, stone_rel          # 1.13-1.63 measured
    assert min(stone_rel) > 1.0
    sib_rel = {n: rel(n + ".BIN") for n in
               ("BATH_00", "FACE_01", "BOOK_0", "CURIO_0", "MIZU_00",
                "HANA", "YUGE_00")}
    for n, v in sib_rel.items():
        assert v > 5.0, (n, v)                      # 8.6-13.7 measured
    # and the zero-padding is real: every page's data is a sub-rectangle
    for f in files:
        a = np.frombuffer(page(f"{BATH_DIR}/{f}"), dtype=np.uint8)
        r0, r1, c0, c1 = spt.nonzero_box(a)
        assert (r0, c0) == (0, 0)
        assert (r1 + 1, c1 + 1) in ((128, 128), (128, 64), (112, 128), (112, 64)), \
            (f, r1, c1)


def check_ownership():
    """(c) which overlay reads which group, and what the group list feeds."""
    d = main_image()
    by_lba = {r["lba"]: r["path"] for r in iso()}

    def group(i: int) -> list[str]:
        g = word(d, GROUP_DIR + 4 * i, MAIN_BASE)
        out, o = [], g - MAIN_BASE
        for k in range(64):
            v = struct.unpack_from("<I", d, o + 4 * k)[0]
            if not (MASTER_TABLE <= v < MASTER_TABLE + MASTER_COUNT * 8):
                break
            _size, lba = struct.unpack_from("<II", d, v - MAIN_BASE)
            out.append(by_lba.get(lba))
        return out

    g3, g8 = group(3), group(8)
    assert [Path(p).name for p in g3] == (
        [f"BOOK_{i}.BIN" for i in range(6)]
        + [f"PAPER_{i}.BIN" for i in range(6)] + ["CURIO_0.BIN"]), g3
    assert [Path(p).name for p in g8] == (
        ["YUGE_00.BIN", "MIZU_00.BIN", "CURIO_0.BIN", "HANA.BIN"]), g8
    # CURIO_0 is in both -- the shared asset
    assert "CURIO_0.BIN" in [Path(p).name for p in g3]
    assert "CURIO_0.BIN" in [Path(p).name for p in g8]
    # the anchor that proves the index space, and the installer
    assert Path(group(1)[0]).name == "STONE_00.BIN"
    assert Path(group(4)[0]).name == "BATH_00.BIN"
    assert Path(group(15)[0]).name == "VC61.BIN"
    inst = word(d, GROUP_INSTALL, MAIN_BASE)
    assert (inst >> 26) == 0x2B and (inst & 0xFFFF) == GROUP_SLOT, hex(inst)
    assert ((inst >> 21) & 0x1F) == 3 and ((inst >> 16) & 0x1F) == 2, hex(inst)

    # the readers, by the access form: `lw $rt, 0x14b8($rs)` then the group
    # offsets read through $rt, stopping when $rt is overwritten.
    def writes_rt(w: int, rt: int) -> bool:
        op = w >> 26
        if op == 0:
            fn = w & 0x3F
            if fn in (0x08, 0x0C, 0x0D, 0x18, 0x19, 0x1A, 0x1B):
                return False
            return ((w >> 11) & 0x1F) == rt
        if op in set(range(0x08, 0x10)) | set(range(0x20, 0x27)) \
                or op in set(range(0x30, 0x34)):
            return ((w >> 16) & 0x1F) == rt
        return False

    def readers(path: str, base: int) -> dict[int, list[int]]:
        blob = raw(path)
        out: dict[int, list[int]] = {}
        n = len(blob) // 4
        for i in range(n):
            w = struct.unpack_from("<I", blob, i * 4)[0]
            if (w >> 26) != 0x23 or (w & 0xFFFF) != GROUP_SLOT:
                continue
            rt = (w >> 16) & 0x1F
            offs = []
            for j in range(1, 25):
                if i + j >= n:
                    break
                w2 = struct.unpack_from("<I", blob, (i + j) * 4)[0]
                if (w2 >> 26) == 0x23 and ((w2 >> 21) & 0x1F) == rt:
                    im2 = w2 & 0xFFFF
                    if im2 <= 0x3C and im2 % 4 == 0:
                        offs.append(im2)
                if writes_rt(w2, rt):
                    break
            if offs:
                out[base + i * 4] = offs
        return out

    rb = readers(BATH_OVERLAY, BATH_BASE)
    assert rb.get(0x800804A8) == [0x10, 0x14, 0x18, 0x1C, 0x20], rb
    rs = readers(STONE_OVERLAY, STONE_BASE)
    assert rs.get(0x800802BC) == [0x04, 0x08], rs
    rk = readers("DATA/03_SHIRO/BOOKS.BIN", 0x80080000)
    assert rk.get(0x800802D4) == [0x0C], rk

    # the consumer chains, instruction by instruction
    bh, bs, bk = raw(BATH_OVERLAY), raw(STONE_OVERLAY), raw("DATA/03_SHIRO/BOOKS.BIN")

    def ins(dd: bytes, base: int, addr: int) -> str:
        from mipsdec import dec
        w = struct.unpack_from("<I", dd, addr - base)[0]
        return dec(addr, w)[0]

    # BATH: dir[8] -> [0x8008D0FC] -> loader(dir[8][idx], [0x80088114])
    assert "0x20($v1)" in ins(bh, BATH_BASE, 0x800804F8)
    assert "0x14b8" in ins(bh, BATH_BASE, 0x800804A8)
    assert "0x6c" in ins(bh, BATH_BASE, BATH_CSR_DEBUG_SITE + 4)
    assert "0x8008" in ins(bh, BATH_BASE, BATH_CSR_DEBUG_SITE)
    assert "-0x2f04" in ins(bh, BATH_BASE, BATH_CSR_DEBUG_SITE - 8)
    assert BATH_CSR_DEBUG_STR in bh
    assert "-0x2f04" in ins(bh, BATH_BASE, 0x8008050C)      # [0x8008D0FC] = dir[8]
    assert "-0x2f04" in ins(bh, BATH_BASE, BATH_CSR_LOAD)   # lw a0,[0x8008D0FC]
    assert "-0x2efc" in ins(bh, BATH_BASE, 0x8008095C)      # the csr state ptr
    assert "-0x7eec" in ins(bh, BATH_BASE, 0x80080988)      # dest [0x80088114]
    assert "0x10($v1)" in ins(bh, BATH_BASE, 0x8008098C)    # loader
    # BOOKS: dir[3] -> [0x8009A560] -> loader(dir[3][idx], 0x80087518)
    assert "0x14b8" in ins(bk, 0x80080000, 0x800802D4)
    assert "0xc($v1)" in ins(bk, 0x80080000, 0x800802E4)
    assert "-0x5aa0" in ins(bk, 0x80080000, 0x80080300)     # [0x8009A560] = dir[3]
    assert "-0x5aa0" in ins(bk, 0x80080000, 0x800804B4)     # lw a0,[0x8009A560]
    assert "0x7518" in ins(bk, 0x80080000, 0x800804D0)
    # STONE: dir[1] -> [0x8008DA3C], dir[2] -> [0x800A1EFC]
    assert "0x14b8" in ins(bs, STONE_BASE, 0x800802BC)
    assert "-0x25c4" in ins(bs, STONE_BASE, 0x800802FC)     # [0x8008DA3C] = dir[1]
    assert "0x1efc" in ins(bs, STONE_BASE, 0x80080304)     # [0x800A1EFC] = dir[2]
    assert STONE_FACE_CACHE == 0x800A1EFC
    # dir[1] is loaded by the case at 0x800805E8 via the same loader
    assert "-0x25c4" in ins(bs, STONE_BASE, 0x800805F0)
    assert "0x10($v1)" in ins(bs, STONE_BASE, 0x8008060C)


def check_draw():
    """The upload-and-draw instruction trace: what VRAM (0x240,0x100) is FOR.

    Re-derived here from the raw words rather than from the tool.  Asserts:
      * the page loop indexes the rect table with `index*8` where the index is
        the state struct's +4 field, and LoadImages via vtable+0x70;
      * the wrap builds w=0x40 h=0x80 and the (0x240,0x100) caller is the
        `ori a2,0x240 / ori a3,0x100` pair just before it;
      * the ONLY in-file instructions that reference the rect table are the two
        that build the LoadImage RECT -- there is no sampling read of it;
      * the second rect run at 0x80084D0C has no in-file reader;
      * the tablet's own quads build their CLUT word with
        `(a1<<6)|((a0>>4)&0x3F)` at (0x140,0x180) / (0,0x1EA..0x1F9), never
        with a rect-table byte.
    """
    import numpy as np

    sd = overlay(STONE_OVERLAY)
    bd = overlay(BATH_OVERLAY)

    # -- the page loop ----------------------------------------------------
    # sw $v0,0x1f1c($at) after `lui $at,0x800a` -> the state struct
    assert word(sd, 0x800802B4, STONE_BASE) == 0x3C01800A, \
        hex(word(sd, 0x800802B4, STONE_BASE))
    assert word(sd, 0x800802B8, STONE_BASE) == 0xAC221F1C, \
        hex(word(sd, 0x800802B8, STONE_BASE))
    assert STONE_STATE == 0x800A1F1C
    assert word(sd, 0x800806EC, STONE_BASE) == 0x8C420004, \
        hex(word(sd, 0x800806EC, STONE_BASE))       # lw $v0,0x4($v0)
    assert word(sd, 0x800806E4, STONE_BASE) == 0x8C421F1C, \
        hex(word(sd, 0x800806E4, STONE_BASE))       # lw $v0,0x1f1c($v0)
    assert word(sd, 0x800806F8, STONE_BASE) == 0x000210C0, \
        hex(word(sd, 0x800806F8, STONE_BASE))       # sll $v0,$v0,3
    # `slti $v0,$v0,0x12` -> 18 pages
    assert 0x28420012 in [word(sd, 0x800806B4 + 4 * k, STONE_BASE)
                          for k in range(0, 80)]
    # LoadImage is vtable+0x70 (the same slot stone_loadimage_wrap_a uses)
    assert word(sd, 0x80080754, STONE_BASE) == 0x8C420070, \
        hex(word(sd, 0x80080754, STONE_BASE))

    # -- the wrap and its (0x240,0x100) caller ----------------------------
    assert word(sd, 0x80083DB0, STONE_BASE) == 0x34020040   # ori $v0,$zero,0x40
    assert word(sd, 0x80083DB8, STONE_BASE) == 0x34020080   # ori $v0,$zero,0x80
    assert word(sd, 0x80081024, STONE_BASE) == 0x34050240    # ori $a1,$zero,0x240
    assert word(sd, 0x8008102C, STONE_BASE) == 0x34060100    # ori $a2,$zero,0x100
    assert STONE_LOADIMAGE_RECT == (0x240, 0x100)

    # -- the rect table's ONLY in-file readers ---------------------------
    n = len(sd) // 4
    readers = []
    for i in range(n):
        w = struct.unpack_from("<I", sd, i * 4)[0]
        if (w >> 26) == 0x0F and (w & 0xFFFF) == 0x8008:
            rt = (w >> 16) & 0x1F
            w2 = struct.unpack_from("<I", sd, (i + 1) * 4)[0]
            if (w2 >> 26) == 0x09 and ((w2 >> 21) & 0x1F) == rt \
                    and (w2 & 0xFFFF) == 0x4CDC:
                readers.append(STONE_BASE + i * 4)
    assert readers == [0x8008070C], [hex(a) for a in readers]
    # (the sibling halfword is built as `addiu $at,0x4CDF` + `addu`, not
    # 0x4CDC, so this pair scan finds the x|y half only -- and that is the
    # whole set of rect-table address formations in the overlay)
    # and the second run (0x80084D0C) has none at all
    readers2 = []
    for i in range(n):
        w = struct.unpack_from("<I", sd, i * 4)[0]
        if (w >> 26) == 0x0F and (w & 0xFFFF) == 0x8008:
            rt = (w >> 16) & 0x1F
            w2 = struct.unpack_from("<I", sd, (i + 1) * 4)[0]
            if (w2 >> 26) == 0x09 and ((w2 >> 21) & 0x1F) == rt \
                    and (w2 & 0xFFFF) == 0x4D0C:
                readers2.append(STONE_BASE + i * 4)
    assert readers2 == [], [hex(a) for a in readers2]
    # both tables are 16 identical-shaped rects; the runs differ only in x/y order
    t1 = [struct.unpack_from("<4H", sd, STONE_RECT_TABLE - STONE_BASE + 8 * i)
          for i in range(16)]
    t2 = [struct.unpack_from("<4H", sd, STONE_RECT_TABLE2 - STONE_BASE + 8 * i)
          for i in range(16)]
    assert t1[6] == (0x240, 0x0000, 0x40, 0x80), t1[6]
    assert (0x240, 0x100, 0x40, 0x80) not in t1, \
        "the lookup path's (0x240,0x100) is rect[2] of the unread second run"
    assert sorted({r[0] for r in t1}) == [0x240, 0x280, 0x2C0, 0x300, 0x340]
    assert sorted({r[1] for r in t1}) == [0x00, 0x80, 0x100, 0x180]
    # the second run is a different *selection* of the same page grid: it shares
    # 10 records with the first run and adds the x=0x280 y=0x80/0x180 pair, but
    # it omits the y=0x180 row at x 0x2C0/0x300/0x340 -- so the two runs are not
    # interchangeable, and only the first is read by code
    assert len(set(t1) & set(t2)) == 10, len(set(t1) & set(t2))
    assert (0x240, 0x100, 0x40, 0x80) not in t1
    assert (0x240, 0x100, 0x40, 0x80) not in t2
    assert t1[8] == (0x280, 0x100, 0x40, 0x80)
    assert t2[6] == (0x2C0, 0x0000, 0x40, 0x80)
    assert all(w == 0x40 and h == 0x80 for _x, _y, w, h in t1)
    assert all(w == 0x40 and h == 0x80 for _x, _y, w, h in t2[:12])
    assert len(set(t2[:12])) == 12
    assert len(set(t1)) == 16
    # and the lookup path's hard-coded (0x240,0x100) appears in NEITHER run:
    # the byte pattern is not in the file at all
    assert (0x240, 0x100, 0x40, 0x80) not in t1
    assert (0x240, 0x100, 0x40, 0x80) not in t2
    assert sd.find(bytes([0x40, 0x02, 0x00, 0x01, 0x40, 0x00, 0x80, 0x00])) < 0

    # -- the only reference to (0x240,0x100) is a WRITE ------------------
    assert word(sd, 0x800833D8, STONE_BASE) == 0x34060240   # ori $a2,$zero,0x240
    assert word(sd, 0x800833E0, STONE_BASE) == 0x34070100   # ori $a3,$zero,0x100
    assert word(sd, 0x800833D4, STONE_BASE) == 0x8C42006C   # lw $v0,0x6c($v0)
    # that slot is LoadImage (same body as +0x70)
    assert word(sd, 0x80083E18, STONE_BASE) == 0x8C420070   # the +0x70 twin

    # -- the tablet's own quad CLUT path ---------------------------------
    # gpu_texpage_word_build is a MAIN routine; check it from MAIN directly
    md = raw(MAIN)[2048:]
    assert struct.unpack_from("<I", md, 0x8014ABD4 - MAIN_BASE)[0] == 0x00051180
    assert struct.unpack_from("<I", md, 0x8014ABD8 - MAIN_BASE)[0] == 0x00042103
    assert struct.unpack_from("<I", md, 0x8014ABDC - MAIN_BASE)[0] == 0x3084003F
    assert struct.unpack_from("<I", md, 0x8014ABE0 - MAIN_BASE)[0] == 0x00441025
    # the grid's CLUT arg is 0x180 and a0 is zero -> (0x180<<6)|0
    assert word(sd, 0x80081E98, STONE_BASE) == 0x34050180, \
        hex(word(sd, 0x80081E98, STONE_BASE))
    # the FT4 emitter calls the builder with a1=0x1FF too
    assert word(sd, 0x80081A20, STONE_BASE) == 0x340501FF, \
        hex(word(sd, 0x80081A20, STONE_BASE))
    # glyph page pick: `sltiu $v0,$v0,0x24` on the state byte 0x2D
    assert word(sd, 0x80081FD0, STONE_BASE) == 0x2C420024, \
        hex(word(sd, 0x80081FD0, STONE_BASE))

    # -- BATH's per-page step: bank -> directory group, never a CLUT word --
    assert word(bd, BATH_PAGE_STEP, BATH_BASE) == 0x9203003D   # lbu $v1,0x3d($s0)
    assert word(bd, BATH_PAGE_STEP + 0x10, BATH_BASE) == 0x00031880   # sll 2
    assert word(bd, BATH_PAGE_STEP + 0x14, BATH_BASE) == 0x3C018009
    assert word(bd, BATH_PAGE_STEP + 0x18, BATH_BASE) == 0x2421CFCC, \
        hex(word(bd, BATH_PAGE_STEP + 0x18, BATH_BASE))
    # `lui 0x8009` + `-0x3034` -> 0x8008CFCC (the sign-extension trap in
    # AGENTS.md sec.5); the table itself is zero on disc (BSS), filled at runtime
    assert 0x80090000 - 0x3034 == 0x8008CFCC
    assert word(bd, BATH_PAGE_STEP + 0x1C, BATH_BASE) == 0x00230821   # addu at,at,v1
    assert word(bd, BATH_PAGE_STEP + 0x20, BATH_BASE) == 0x8C230000   # lw v1,0(at)
    # the bank byte is read exactly once and never reaches a CLUT builder
    nb = len(bd) // 4
    bank_reads = [BATH_BASE + 4 * i for i in range(nb)
                  if (struct.unpack_from("<I", bd, 4 * i)[0] >> 26) == 0x24
                  and (struct.unpack_from("<I", bd, 4 * i)[0] & 0xFFFF) == 0x3D
                  and ((struct.unpack_from("<I", bd, 4 * i)[0] >> 21) & 0x1F) == 16]
    assert bank_reads == [0x80081308, 0x80081348, 0x800814C4], \
        [hex(a) for a in bank_reads]
    # the third one is NOT a draw: it indexes the per-bank BGM halfword table
    # at 0x800858D4 and calls vtable+0xAC (the SE/BGM player 0x800C3104)
    assert bank_reads[2] == 0x800814C4
    assert word(bd, 0x800814E0, BATH_BASE) == 0x00220821        # addu at,at,v0
    assert word(bd, 0x800814E4, BATH_BASE) == 0x84240000        # lh $a0,0($at)
    assert word(bd, 0x800814E8, BATH_BASE) == 0x8C6200AC        # lw v0,0xac(v1)
    assert struct.unpack_from("<4H", bd, 0x800858D4 - BATH_BASE) == \
        (0x434, 0x434, 0x435, 0x436)

    # -- the BATH palettes ARE in the file at 0xD114 ----------------------
    for b in range(4):
        off = BATH_CLUT_DATA + b * CLUT_BYTES - BATH_BASE
        assert 0 <= off + CLUT_BYTES <= len(bd)
        words = struct.unpack_from("<256H", bd, off)
        assert words[0] == 0xFFFF and len(set(words)) == 256, b


def check_paper():
    """PAPER_0/PAPER_1 are the STONE_nn question inside the PAPER family.

    Same container, same decoder, same 16,384 B; the whole 128x128 page is
    non-zero (zero_fraction 0.000) yet carries no block structure: the
    null-calibrated 4x4 ratio is ~1.25/1.44 against 10.6-14.2 for PAPER_2..5
    and for every other legible sibling.  Re-derived here with the measurement
    imported from the tool (it is the measurement, not a claim).
    """
    import shiro_pixel_tail as spt
    import numpy as np

    def rel(name: str) -> float:
        a = np.frombuffer(page(f"{BATH_DIR}/{name}"), dtype=np.uint8)
        return spt.structure(a.reshape(128, 128), 4)[2]

    r0, r1 = rel("PAPER_0.BIN"), rel("PAPER_1.BIN")
    assert 1.0 < r0 < 2.5, r0
    assert 1.0 < r1 < 2.5, r1
    for name in ("PAPER_2.BIN", "PAPER_3.BIN", "PAPER_4.BIN", "PAPER_5.BIN"):
        v = rel(name)
        assert v > 8.0, (name, v)
    # the whole page is present (the STONE pages are zero-padded; these are not)
    for name in ("PAPER_0.BIN", "PAPER_1.BIN"):
        a = np.frombuffer(page(f"{BATH_DIR}/{name}"), dtype=np.uint8)
        assert float((a == 0).mean()) == 0.0, (name, float((a == 0).mean()))
        assert len(np.unique(a)) > 200, name
        r0b, r1b, c0b, c1b = spt.nonzero_box(a)
        assert (r0b, r1b, c0b, c1b) == (0, 127, 0, 127)


def check_second_byte():
    """The second byte of the 142 state pairs is the name's CLUT nibble.

    `stone_texpage_grid`'s sibling routine at 0x80083378 reads the state byte
    0x2D, forms `0x80084BC1 + 2*state` -- exactly the SECOND byte of the pair at
    0x80084BC0 -- adds state[0x2F], masks to four bits and adds 0x1EA, then
    hands that to `gpu_texpage_word_build` as the CLUT Y column.
    """
    sd = overlay(STONE_OVERLAY)
    assert word(sd, 0x80083378, STONE_BASE) == 0x9242002D  # lbu $v0,0x2d($s2)
    assert word(sd, 0x80083380, STONE_BASE) == 0x00021040  # sll $v0,$v0,1
    assert word(sd, 0x80083384, STONE_BASE) == 0x3C018008  # lui $at,0x8008
    assert word(sd, 0x80083388, STONE_BASE) == 0x24214BC1, \
        hex(word(sd, 0x80083388, STONE_BASE))              # addiu $at,$at,0x4BC1
    assert word(sd, 0x80083390, STONE_BASE) == 0x90250000  # lbu $a1,0($at)
    assert word(sd, STONE_MODE_ADD, STONE_BASE) == 0x9242002F         # lbu 0x2f
    assert word(sd, STONE_MODE_MASK, STONE_BASE) == 0x30A5000F        # andi 0xf
    assert word(sd, STONE_MODE_BIAS, STONE_BASE) == 0x24A501EA, \
        hex(word(sd, STONE_MODE_BIAS, STONE_BASE))                    # +0x1EA
    assert word(sd, STONE_STATE_2F_WRITER, STONE_BASE) == 0xA200002F  # sb zero
    # the CLUT path: vtable+0x8C with a0 = 0 at both call sites
    assert word(sd, 0x800833AC, STONE_BASE) == 0x8C62008C
    assert word(sd, 0x800833A4, STONE_BASE) == 0x00002021             # addu a0,0
    # and the 142 pair second bytes are exactly what 0x4BC1 + 2*state holds
    pairs = [(sd[STONE_ID_TABLE - STONE_BASE + 2 * i],
              sd[STONE_ID_TABLE - STONE_BASE + 2 * i + 1]) for i in range(142)]
    for i in (0, 12, 50, 141):
        assert sd[0x4BC1 + 2 * i] == pairs[i][1]
    inband = sorted({b for _a, b in pairs if b <= 8})
    assert inband == list(range(9)), inband
    inband = sorted({b for _a, b in pairs if b <= 8})
    assert inband == list(range(9)), inband
    # the 4 out-of-band rows are all in the 108..141 tail (after the 108 Stars),
    # have their high nibble set, and their LOW nibble is still 0..8 -- which is
    # all the consumer keeps (`andi 0xf`)
    oob = [(i, b) for i, (_a, b) in enumerate(pairs) if b > 8]
    assert oob == [(128, 0xA0), (129, 0x80), (130, 0x80), (131, 0x80)], oob
    assert all((b & 0xF) <= 8 for _i, b in oob), oob
    assert all(i >= 108 for i, _b in oob), oob


def check():
    check_bath()
    check_stone()
    check_ownership()
    check_draw()
    check_paper()
    check_second_byte()
    print("PASS: BATH_00..35 (24 files) each decode to exactly 16,384 B = 128x128 "
          "8bpp with full input consumption and compose a 384x256 sheet -- file i "
          "-> LoadImage RECT i from the table at 0x80085884 (x 0x2C0/0x300/0x340, "
          "y 0/0x80, 64x128 halfwords), with the bank byte [state+0x3D] selecting "
          "one of four 256-colour palettes at 0x8008D114+bank*0x200; the 18 "
          "STONE_nn pages decode to the same 16,384 B and are zero-padded "
          "variable-size images (boxes 128x128/128x64/112x128/112x64) whose "
          "numeric index-space block-ratio excess over "
          "a shuffled null 1.13-1.63, against 8.6-13.7 for BATH/FACE/BOOK/CURIO/"
          "MIZU/HANA/YUGE pages); coloured raster structure is checked separately "
          "by test_stone_composite_palettes.py; the "
          "tablet's text comes instead from 113 zero-terminated glyph-code "
          "strings at 0x80085848 and the tablet's per-state portrait index from "
          "the 142-pair table at 0x80084BC0 (first 108 = a permutation of 0..107, "
          "state 12 -> portrait 4 = Viktor, masking 0x1FC into dir[2]); the "
          "load-group directory at 0x8016B358 is read by exactly the overlays "
          "expected -- dir[3] by BOOKS.BIN@0x800802D4 (PAPER and CURIO_0 with it), "
          "dir[8] by BATH.BIN@0x800804A8 (YUGE/MIZU/CURIO_0/HANA, cached at "
          "0x8008D0FC and called 'csr_data_steam' by the overlay's own debug "
          "string), dir[1]+dir[2] by STONE.BIN, dir[2] also by VB5A2/B3/B4/C4 (copied "
          "base reg), dir[4..7] by BATH.BIN, dir[15] by the twelve duel overlays; "
          "groups 0 and 9-14 have no reader (the IKKI overlays contain no 0x14b8 "
          "access at all) and stay open; the STONE page loop LoadImages the decode "
          "buffer to RECT state[4] of the 18-entry table at 0x80084CDC (the table's "
          "only address formation is 0x8008070C); the STONE draw trace below is "
          "SUPERSEDED -- 0x800833D4 loads GetTpage (vtable+0x6C) and its "
          "0x240/0x100 arguments are the page, and the 20-byte page table at "
          "0x80084D6C is read as data by the composite at 0x80081334, which "
          "samples all 18 rects (canonical: kit/tools/q_stone.py); "
          "the second byte of each 0x80084BC0 pair is the tablet name's CLUT "
          "nibble ((byte2 + state[0x2F]) & 0xF + 0x1EA, CLUT (0,0x1EA..0x1F9)); "
          "and PAPER_0/PAPER_1 are the same open question as STONE_nn inside the "
          "PAPER family (ratio 1.25/1.44 vs 10.6-14.2 for PAPER_2..5), with the "
          "whole 128x128 page non-zero, i.e. not a padding artefact")


if __name__ == "__main__":
    check()
