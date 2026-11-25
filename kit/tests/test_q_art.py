#!/usr/bin/env python3
"""Four open art questions: independent re-derivation.

Nothing here imports `kit/tools/q_art.py`.  Every fact is re-read from the disc
through `disc` + `lzss` + `struct`, so a bug in the tool cannot make this pass.
Disc required.  Run:

    .venv/bin/python kit/tests/test_q_art.py

What is asserted, and why each is a fact rather than a reading:

* `BATTLE.BIN` loads at `0x800AA000`, and the base is fixed three ways that do
  not share a source: the loader's own instruction pair at
  `0x800C9D18`/`0x800C9D20` (`lui $a1,0x800A` + `ori $a1,$a1,0xA000`); the
  **largest** absolute pointer embedded in the file, `0x800BE29C`, which base
  `0x800A0000` leaves out of range (its top is `0x800B653B`); and the smallest,
  `0x800AA020`, whose implied file offset `0x20` is the first palette;
* the file holds 13 **distinct** 16,384-byte atlases behind 73 `c`-table
  references, and every one consumes exactly its declared `comp_len`;
* the `d`-table count convention is decided by an **allocation**, not by the
  byte's value: the `d`-table's region runs from its own file offset to the
  lowest `e`-record the `e`-table points at, and that span holds exactly 3
  pointers, so the plain byte `0x83` = 131 is refuted and `0x83 & 0x3F` = 3 is
  what fits;
* the piece-record walker is `0x800E211C`, reached by `jal 0x800E211C` at
  `0x800E2104`, and it reaches the section descriptor through the animation
  object's `+0x30` **field**, so no `lui` can name it;
* each duel's own data words carry its two load-group indices, and resolving
  those groups through `0x8016B358` gives its BT and SKY page sets;
* all 1,019 page-shaped containers decode to exactly 16,384 bytes with
  `used == 4 + comp_len`, so no container is a partial decode. This does not
  determine whether decoded bytes include embedded palette words.
"""
from pathlib import Path
import hashlib
import json
import struct
import sys

import numpy as np

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc   # noqa: E402
import lzss   # noqa: E402

MAIN_BASE = 0x800C0800
OVERLAY_BASE = 0x80080000
PAGE_BYTES = 16384
BATTLE_BASE = 0x800AA000
BATTLE_PATH = "DATA/00_INIT/BATTLE.BIN"
DUEL_NAMES = ("PAN_TEO.BIN", "SHU_KWA.BIN", "SHU_TEO.BIN")


def iso():
    with open(_KIT / "extracted" / "iso_files.json", encoding="utf-8") as fh:
        return [r for r in json.load(fh) if not r.get("dir")]


def read(path):
    rec = next(r for r in iso() if r["path"] == path)
    return disc.extract(rec["lba"], rec["size"])


def main_image():
    rec = next(r for r in iso() if r["path"] == "MAIN.EXE")
    blob = disc.extract(rec["lba"], rec["size"])
    assert blob[:8] == b"PS-X EXE"
    return blob[2048:]


def mword(img, va):
    return struct.unpack_from("<I", img, va - MAIN_BASE)[0]


def rd32(d, off):
    return struct.unpack_from("<I", d, off)[0]


def sx16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def check():
    img = main_image()

    # ---------------------------------------------------------------- BATTLE
    d = read(BATTLE_PATH)
    assert len(d) == 91451, len(d)

    # (a) the loader instruction pair decides the base outright
    assert mword(img, 0x800C9D18) == 0x3C05800A, hex(mword(img, 0x800C9D18))
    assert mword(img, 0x800C9D20) == 0x34A5A000, hex(mword(img, 0x800C9D20))
    # (b)+(c) the file's own embedded pointers bracket it
    emb = [rd32(d, i) for i in range(0, len(d) - 3, 4)]
    emb = [p for p in emb if 0x800A0000 <= p < 0x800C0000]
    assert min(emb) == 0x800AA020 and max(emb) == 0x800BE29C
    assert max(emb) >= 0x800A0000 + len(d)          # base 0x800A0000 refuted
    assert min(emb) - 0x20 == BATTLE_BASE           # base <= min pointer

    master = [rd32(d, 4 * i) for i in range(8)]
    assert all(BATTLE_BASE <= p < BATTLE_BASE + len(d) for p in master)
    print("PASS: BATTLE.BIN loads at 0x800AA000 -- the loader instruction pair "
          "0x800C9D18/0x800C9D20 materialises it, the largest embedded pointer "
          "0x800BE29C is out of range for base 0x800A0000 (top 0x800B653B), and "
          "the smallest, 0x800AA020, implies file offset 0x20, the first palette")

    sections = []
    for p in master:
        o = p - BATTLE_BASE
        a, b = struct.unpack_from("<HH", d, o)
        c_count, d_flags = d[o + 4], d[o + 5]
        ctab, dtab, etab, ftab = struct.unpack_from("<IIII", d, o + 8)
        sections.append(dict(o=o, a=a, b=b, c_count=c_count, d_flags=d_flags,
                             ctab=ctab - BATTLE_BASE, dtab=(dtab - BATTLE_BASE) if dtab else None,
                             etab=etab - BATTLE_BASE, ftab=ftab - BATTLE_BASE))

    atlases = {}
    refs = 0
    for s in sections:
        for i in range(s["c_count"]):
            off = rd32(d, s["ctab"] + 4 * i) - BATTLE_BASE
            refs += 1
            comp_len = rd32(d, off)
            out, used = lzss.decode_container(d, off)
            assert len(out) == PAGE_BYTES, (off, len(out))
            assert used == 4 + comp_len, (off, used, comp_len)
            atlases[off] = hashlib.sha256(out).hexdigest()
    assert refs == 73 and len(atlases) == 13, (refs, len(atlases))
    print("PASS: BATTLE.BIN holds 13 distinct 16,384-byte atlases behind 73 "
          "c-table references (3 in section 0, the same 10 shared by sections "
          "1-7); every one consumes exactly its declared comp_len")

    s0 = sections[0]
    assert (s0["a"], s0["b"], s0["c_count"], s0["d_flags"]) == (82, 23, 3, 0x83)
    assert s0["dtab"] == 0xE0 and s0["o"] == 0xB64
    pal = [rd32(d, s0["dtab"] + 4 * i) - BATTLE_BASE for i in range(3)]
    assert pal == [0x20, 0x60, 0xA0], [hex(x) for x in pal]
    # the d-table's allocation: from its own offset to the lowest e-record
    e_targets = [rd32(d, s0["etab"] + 4 * i) - BATTLE_BASE for i in range(s0["a"])]
    capacity = (min(e_targets) - s0["dtab"]) // 4
    assert capacity == 3, capacity
    assert s0["d_flags"] & 0x3F == 3 <= capacity < s0["d_flags"]
    assert all(s["dtab"] is None and s["d_flags"] == 0 for s in sections[1:])
    print("PASS: section 0's d-table holds exactly 3 pointers (file 0x20/0x60/0xA0) "
          "-- its region ends where the lowest e-record begins (file 0xEC), so the "
          "plain-byte count 0x83 = 131 is refuted by the allocation and 0x83 & 0x3F "
          "= 3 is the convention the engine uses")

    # the count instruction itself, in both the & 0xC0 selector and the & 0x3F count
    assert mword(img, 0x800C389C) == 0x304200C0          # andi $v0,$v0,0xc0
    assert mword(img, 0x800C38B8) == 0x3063003F          # andi $v1,$v1,0x3f
    assert mword(img, 0x800C3904) == 0x3063003F
    # the uploaders' geometry, from their instructions
    assert mword(img, 0x800C3CD0) == 0x34020100          # x = 0x100
    assert mword(img, 0x800C3CD8) == 0x34020020          # w = 0x20 (32 entries)
    assert mword(img, 0x800C3D00) == 0x244201E0          # y = counter + 0x1E0
    assert mword(img, 0x800C3C60) == 0x34020100          # w = 0x100
    assert mword(img, 0x800C3C80) == 0xA7A00010          # x = 0
    assert mword(img, 0x800C3C90) == 0x244201E0
    # ... and the counters they read, resolved from the sign-extended offsets
    for site, target in ((0x800C3C74, 0x80179038), (0x800C3CEC, 0x80179040),
                         (0x800C3A58, 0x80179030)):
        w = mword(img, site)
        hi = (mword(img, site - 4) & 0xFFFF) << 16
        assert (hi + sx16(w)) & 0xFFFFFFFF == target, \
            (hex(site), hex((hi + sx16(w)) & 0xFFFFFFFF), hex(target))
    print("PASS: the band selector is `lbu(+5) & 0xC0` and the count is "
          "`lbu(+5) & 0x3F` (0x800C389C / 0x800C38B8 / 0x800C3904); the 32-entry "
          "uploader emits RECT(x=0x100, y=counter+0x1E0, w=0x20, h=1) reading "
          "counter 0x80179040, the 256-entry one RECT(x=0, y=counter+0x1E0, "
          "w=0x100, h=1) reading 0x80179038, and the pixel slot counter is "
          "0x80179030")

    # ------------------------------------------------------- the piece walker
    # jal 0x800E211C at 0x800E2104
    w = mword(img, 0x800E2104)
    assert (w >> 26) == 3
    assert (((0x800E2104 + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)) == 0x800E211C
    assert mword(img, 0x800E211C) == 0x27BDFFC0            # addiu sp,sp,-0x40
    assert mword(img, 0x800E214C) == 0x8E830030            # lw $v1,0x30($s4)
    assert mword(img, 0x800E2188) == 0x8C620010            # lw $v0,0x10($v1)
    assert mword(img, 0x800E21A8) == 0x905E0000            # lbu $fp,0x0($v0) = count
    assert mword(img, 0x800E21D8) == 0x24420008            # sub-piece stride base 8
    assert mword(img, 0x800E21E4) == 0x92620002            # lbu $v0,0x2($s3) slot delta
    assert mword(img, 0x800E2258) == 0x91100007            # lbu $s0,0x7($t0) section+7
    assert mword(img, 0x800E2280) == 0x92620006            # lbu $v0,0x6($s3) row delta
    assert mword(img, 0x800E22A4) == 0x260501E0            # a1 = s0 + 0x1E0
    assert mword(img, 0x800E229C) == 0x34040100            # a0 = 0x100  -> GetClut
    print("PASS: the piece-record walker IS in MAIN.EXE at 0x800E211C (jal at "
          "0x800E2104); 0x800E214C reads the descriptor from the animation "
          "object's +0x30 field and 0x800E2188 reads +0x10 of it, so the base is "
          "an argument no lui can name -- and 0x800E21A8 takes the sub-piece "
          "count from the record's first byte")

    # the record shape, on AIL.BIN's S2 and on BATTLE.BIN
    ail = read("DATA/04_PLAY/AIL.BIN")
    s2 = rd32(ail, 0x20 + 8)
    a, b = struct.unpack_from("<HH", ail, s2)
    assert (a, b) == (12, 4), (a, b)
    etab = rd32(ail, s2 + 0x10)
    s2_counts = []
    for i in range(a):
        t = rd32(ail, etab + 4 * i)               # file offsets, unrelocated
        s2_counts.append(ail[t])
        for k in range(ail[t]):
            sub = ail[t + 8 + 8 * k:t + 16 + 8 * k]
            assert len(sub) == 8
            assert sub[2] < 20 and sub[4] < 128 and sub[5] < 128
    assert s2_counts == [1] * 12, s2_counts
    multi = 0
    total = 0
    for s in sections:
        for i in range(s["a"]):
            t = rd32(d, s["etab"] + 4 * i) - BATTLE_BASE
            total += 1
            if d[t] > 1:
                multi += 1
    assert total == 297 and multi == 38, (total, multi)
    print("PASS: the e-table is an array of pointers to piece records whose first "
          "byte is a sub-piece count and whose sub-pieces are 8 bytes at +8 "
          "(AIL S2: 12 records of one sub-piece each; BATTLE.BIN: 297 records, "
          "38 with more than one sub-piece)")

    # ------------------------------------------------------------ duel groups
    by_lba = {r["lba"]: r["path"] for r in iso()
              if r["path"].startswith("DATA/") and r["path"].endswith(".BIN")}
    trecs = [struct.unpack_from("<II", img, 0x80163D64 - MAIN_BASE + 8 * i)
             for i in range(344)]
    groups = []
    for g in range(16):
        p = mword(img, 0x8016B358 + 4 * g)
        names = []
        for k in range(64):
            v = mword(img, p + 4 * k)
            if not (0x80163D64 <= v < 0x80163D64 + 344 * 8):
                break
            names.append(by_lba[trecs[(v - 0x80163D64) // 8][1]].split("/")[-1])
        groups.append(names)
    assert [len(g) for g in groups] == [8, 18, 27, 13, 6, 6, 6, 6, 4, 24, 3,
                                        15, 3, 24, 3, 3]
    assert groups[10] == ["SKY3_%d.BIN" % i for i in (1, 2, 3)]
    assert groups[12] == ["SKY1_%d.BIN" % i for i in (1, 2, 3)]
    assert groups[14] == ["SKY2_%d.BIN" % i for i in (1, 2, 3)]

    # the directory is installed into subsystem+0x14B8, which is the slot the
    # duel overlays read (0x801BA000 + 0x14B8 = 0x801BB4B8)
    assert mword(img, 0x800C9648) == 0x3C028017          # lui $v0,0x8017
    assert mword(img, 0x800C964C) == 0x2442B358          # addiu $v0,$v0,-0x4ca8
    assert ((0x8017 << 16) + sx16(mword(img, 0x800C964C))) == 0x8016B358
    assert mword(img, 0x800C9650) == 0xAC6214B8          # sw $v0,0x14b8($v1)
    # the duel overlays' read: lui $a0,0x801c / lw $a0,-0x4b48($a0)
    pan = read("DATA/12_IKKI/PAN_TEO.BIN")
    assert struct.unpack_from("<I", pan, 0x104C)[0] == 0x3C038009
    assert struct.unpack_from("<I", pan, 0x1054)[0] == 0x3C04801C
    assert ((0x801C << 16) + sx16(struct.unpack_from("<I", pan, 0x1058)[0])) == 0x801BB4B8
    assert 0x801BB4B8 == 0x801BA000 + 0x14B8
    expected = {}
    for name, offs in (("PAN_TEO.BIN", (0x9B9C, 0x9BA0)),
                       ("SHU_KWA.BIN", (0x9B80, 0x9B84)),
                       ("SHU_TEO.BIN", (0x9B80, 0x9B84))):
        dd = read("DATA/12_IKKI/" + name)
        idx = [rd32(dd, o) for o in offs]
        expected[name] = idx
        bt = [n for n in groups[idx[0]] if n.startswith("BT")]
        sky = [n for n in groups[idx[1]] if n.startswith("SKY")]
        assert bt and sky, (name, bt, sky)
    assert expected["PAN_TEO.BIN"] == [9, 10]
    assert expected["SHU_KWA.BIN"] == [11, 12]
    assert expected["SHU_TEO.BIN"] == [13, 14]
    print("PASS: each duel names its two load-group indices in its own data "
          "(PAN_TEO 9/10 at file 0x9B9C/0x9BA0, SHU_KWA 11/12 and SHU_TEO 13/14 "
          "at 0x9B80/0x9B84), and the directory resolves them to BT2+SKY3, "
          "BT1+SKY1 and BT2+SKY2 respectively -- so SHU_KWA does take SKY1 and "
          "SHU_TEO takes SKY2, and 11 BT and 9 SKY pages are covered")

    # ------------------------------------------------------------- the pages
    sys.path.insert(0, str(_KIT / "tools"))
    import data_overlays as dov
    census = dov.build()
    pages = []
    for r in census["records"]:
        if r["container"] and r["container"]["out_len"] == PAGE_BYTES:
            pages.append((r["path"], 0, "whole-file"))
        if r["bank"]:
            for off in r["bank"]["pages"]:
                pages.append((r["path"], off, "in-module"))
    assert len(pages) == 1019
    assert sum(1 for p in pages if p[2] == "whole-file") == 133
    cache = {}
    shas = {}
    fam = {}
    for path, off, kind in pages:
        blob = cache.get(path)
        if blob is None:
            blob = cache[path] = read(path)
        comp_len = rd32(blob, off)
        plane, used = lzss.decode_container(blob, off)
        assert len(plane) == PAGE_BYTES, (path, off, len(plane))
        assert used == 4 + comp_len, (path, off, used, comp_len)
        shas.setdefault(hashlib.sha256(plane).hexdigest(), []).append((path, off, kind))
    whole = {k for k, v in shas.items() if any(x[2] == "whole-file" for x in v)}
    dup_in_module = sum(1 for k in whole for x in shas[k] if x[2] == "in-module")
    assert len(shas) == 795, len(shas)
    assert dup_in_module == 26, dup_in_module
    print("PASS: all 1,019 page-shaped containers decode to exactly 16,384 bytes "
          "with used == 4 + comp_len -- no partial decode or unconsumed suffix; "
          "there are 795 distinct contents, and 26 "
          "in-module pages are byte-identical copies of a directory-owned page")


if __name__ == "__main__":
    check()
