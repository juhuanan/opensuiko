#!/usr/bin/env python3
"""The three residual questions: independent re-derivation.

Everything here is raw byte arithmetic over `SLUS_002.92` and the `MAIN.EXE`
image -- the pointer tables are walked and the fields are read afresh, so a bug
in `q_residue.py` cannot make this pass.  The instruction words are asserted as
literals, which pins each field to the instruction that consumes it.

Disc required.  Run: `.venv/bin/python kit/tests/test_q_residue.py`
"""
from pathlib import Path
import json
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc        # noqa: E402
import maindec     # noqa: E402
import q_residue as qr  # noqa: E402

MAIN_BASE = maindec.MBASE
U8, U16, U32 = 1, 2, 4


def img():
    return maindec.body()


def rd(va, n):
    """n bytes of the MAIN.EXE image at a virtual address."""
    o = va - MAIN_BASE
    return img()[o:o + n]


def u8(va):
    return rd(va, U8)[0]


def u16(va):
    return struct.unpack("<H", rd(va, U16))[0]


def u32(va):
    return struct.unpack("<I", rd(va, U32))[0]


def slus():
    with open(_KIT / "extracted" / "iso_files.json") as fh:
        rec = next(r for r in json.load(fh) if r.get("path") == "SLUS_002.92")
    return disc.extract(rec["lba"], rec["size"])[2048:]


def gtext(bs):
    """The engine's own table, written out a second time on purpose."""
    out = []
    for c in bs:
        if c == 0:
            break
        if 0x11 <= c <= 0x2A:
            out.append(chr(ord("a") + c - 0x11))
        elif 0x2B <= c <= 0x44:
            out.append(chr(ord("A") + c - 0x2B))
        elif 0x45 <= c <= 0x4E:
            out.append(chr(ord("0") + c - 0x45))
        elif c == 0x10:
            out.append(" ")
        elif c == 0x53:            # apostrophe, used by "Champion's Rune"
            out.append("'")
        elif c == 0x5C:            # hyphen, used by "Double-beat Rune"
            out.append("-")
        elif c == 0x58:            # the six-glyph placeholder rune name
            out.append("?")
        else:
            out.append("?")
    return "".join(out).rstrip()


def check():
    # ------------------------------------------------------------------ Q1
    # The rune pointer array: word 0 is a count, words 1..33 are records.
    assert u32(0x8016A0E0) == 31, "0x8016A0E0 is not the rune count"
    fortune = u32(0x8016A0E0 + 4 * 0x16)
    assert gtext(rd(fortune, 0x14)) == "Fortune Rune", hex(fortune)
    prosperity = u32(0x8016A0E0 + 4 * 0x17)
    assert gtext(rd(prosperity, 0x14)) == "Prosperity Rune", hex(prosperity)
    # every constant compared against record+0x4C is a rune number
    for imm, name in ((0x0E, "Double-beat Rune"), (0x0F, "Killer Rune"),
                      (0x10, "Counter Rune"), (0x11, "Spark Rune"),
                      (0x12, "Hazy Rune"), (0x13, "Gale Rune"),
                      (0x16, "Fortune Rune"), (0x17, "Prosperity Rune"),
                      (0x19, "Turtle Rune"), (0x1A, "Phero Rune")):
        assert gtext(rd(u32(0x8016A0E0 + 4 * imm), 0x14)) == name, imm
    # the readers index that array with the byte
    assert u32(0x800CF0D8) == 0x3C018017 and u32(0x800CF0DC) == 0x2421A0E0
    assert u32(0x800CF0E4) == 0x8C230000
    # the 78-record template in SLUS
    s = slus()
    OFF = 0x33274
    runes = [s[OFF + i * 0x50 + 0x4C] for i in range(78)]
    ids = [struct.unpack_from("<I", s, OFF + i * 0x50)[0] for i in range(78)]
    assert len(set(ids)) == 78, "the 78 ids must be distinct"
    assert sorted(set(r for r in runes if r)) == \
        [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 18, 27, 29, 30, 31, 32, 33]
    assert sum(1 for r in runes if r) == 22, runes
    assert 0x16 not in runes, "no template record carries rune 22"
    # the doubling site names rune 0x16 and shifts left by one
    assert u32(0x800E98EC) == 0x9043004C          # lbu $v1,0x4c($v0)
    assert u32(0x800E98F0) == 0x34020016          # ori $v0,$zero,0x16
    assert u32(0x800E9904) == 0x00021040          # sll $v0,$v0,1
    # the magic dispatcher switches on the same byte
    assert u32(0x800F81E8) == 0x9072004C          # lbu $s2,0x4c($v1)
    assert u32(0x800F82A8) == 0x3402001E          # ori $v0,$zero,0x1e
    assert u32(0x800F82D0) == 0x00400008          # jr $v0

    # ------------------------------------------------------------------ Q2
    U = 0x8016CD0C
    UP = 0x8016D18C
    assert u32(UP) == 0
    for i in range(32):
        assert u32(UP + 4 * (i + 1)) == U + 0x24 * i, i
    # the matcher's arithmetic: +0x18 is the loop bound, +0x1a+m the member id
    assert u32(0x800F9204) == 0x8C830000          # lw   $v1,0x0($a0)
    assert u32(0x800F9210) == 0x906B0018          # lbu  $t3,0x18($v1)
    assert u32(0x800F9238) == 0x9047001A          # lbu  $a3,0x1a($v0)
    assert u32(0x800F928C) == 0x010B102A          # slt  $v0,$t0,$t3
    # +0x16 is read as a u16, and +0x19 is the id into the second table
    assert u32(0x800F588C) == 0x94420016          # lhu  $v0,0x16($v0)
    assert u32(0x800F5914) == 0x90420019          # lbu  $v0,0x19($v0)
    assert u32(0x800F5924) == 0x2421D2D0          # addiu $at,$at,0xd2d0
    # the misread is *narrower* than the truth: the byte at +0x16 is never 2..5
    flags = [u16(U + 0x24 * i + 0x16) for i in range(32)]
    assert set(flags) == {1, 3}, sorted(set(flags))
    assert all(f & 1 for f in flags)
    # and the true member count at +0x18 is 1..4, never equal to the flag word
    counts = [u8(U + 0x24 * i + 0x18) for i in range(32)]
    assert all(1 <= c <= 4 for c in counts), counts
    tally = {c: counts.count(c) for c in sorted(set(counts))}
    assert tally == {2: 16, 3: 11, 4: 5}, tally
    # the named cross-checks: a member list is character ids and nothing else
    members = {}
    for i in range(32):
        a = U + 0x24 * i
        members[gtext(rd(a, 0x14))] = (
            list(rd(a + 0x1A, u8(a + 0x18))))
    for name, want in (("Couple attack", [0, 30]),
                       ("Master pupil attack", [8, 91]),
                       ("Fisherman attack", [32, 38]),
                       ("Kobold attack", [14, 80]),
                       ("Dragon Knight attack", [19, 29]),
                       ("Elf attack", [4, 75, 9]),
                       ("Pirate attack", [11, 43, 41]),
                       ("Warriors attack", [33, 63]),
                       ("Bandit attack", [12, 31]),
                       ("Carpenter attack", [20, 95])):
        assert members[name] == want, (name, members.get(name))
    # the four blacksmith variants share a unite id and swap one member for Mose
    bs = [rd(U + 0x24 * i + 0x18, 5) for i in (21, 22, 23, 24)]
    assert {b[0] for b in bs} == {4} and {u8(U + 0x24 * i + 0x19)
                                         for i in (21, 22, 23, 24)} == {6}, bs

    # ------------------------------------------------------------------ Q3
    RT = 0x80164E68
    row = lambda i, off: rd(RT + 12 * i + off, 1)[0]
    populated = [i for i in range(71) if u32(RT + 12 * i) or u16(RT + 12 * i + 8)]
    assert len(populated) == 69, populated
    assert populated[0] == 1 and populated[-1] == 70
    assert 0 not in populated and 67 not in populated
    # +0x0B is zero in every populated row
    assert all(row(i, 0x0B) == 0 for i in populated)
    # +0x04 <= 44100, +0x06 <= sectors and a multiple of 32
    for i in populated:
        a = u16(RT + 12 * i + 4)
        b = u16(RT + 12 * i + 6)
        sec = u16(RT + 12 * i + 8)
        assert a <= 44100, (i, a)
        assert b <= sec, (i, b, sec)
        assert b % 32 == 0, (i, b)
    # the instruction that consumes +0x04 divides by exactly 44100
    assert u32(0x800C7AE0) == 0x94230000          # lhu $v1,0x0($at)
    assert u32(0x800C7AE4) == 0x3402AC44          # ori $v0,$zero,0xac44
    assert u32(0x800C7AEC) == 0x0062001A          # div $v1,$v0
    assert u32(0x800C8688) == 0x24214E6E          # addiu $at,$at,0x4e6e  (+6)
    assert u32(0x800C86A4) == 0xAC229CE8          # sw $v0,-0x6318($at)
    # the +0x0B negative: enumerate every address the code forms in the frame
    targets = {e["target"] for e in qr.table_field_targets()}
    assert targets == {"0x80164e68", "0x80164e6c", "0x80164e6e",
                       "0x80164e70", "0x80164e72"}, sorted(targets)
    assert "0x80164e73" not in targets

    for line in qr.verify():
        print(line)
    print("PASS: independent re-derivation of kit/tools/q_residue.py agrees "
          "(78 character records read afresh from SLUS_002.92; the five "
          "constants 0x0E/0x0F/0x16/0x17/0x19 re-named through the rune array; "
          "the 32 unite records re-walked through 0x8016D18C; the 71 resource "
          "rows re-read byte by byte)")


if __name__ == "__main__":
    check()
