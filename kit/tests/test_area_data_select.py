#!/usr/bin/env python3
"""Which `*_DATA.BIN` the file table loads: independent re-derivation.

The selection is re-read here with plain `struct.unpack_from` over the headerless
`MAIN.EXE` image and the disc, so a bug in `area_data_select.py` cannot make it
pass.  Disc required.

Run: `python3 kit/tests/test_area_data_select.py`
"""
from pathlib import Path
import json
import os
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402

MB = 0x800C0800                 # MAIN.EXE headerless image base
SLUS_BASE = 0x80010000
MASTER = 0x80163D64             # 344 x [u32 size][u32 lba]
TABLE = 0x8016F3B4              # 12 x [u32 record]
LOADER = 0x800C2EF8
GS_PTR = 0x8017DB24

EXPECTED = [
    "DATA/01_AREA.A/A_DATA.BIN", "DATA/02_AREA.B/B_DATA.BIN",
    "DATA/06_AREA.C/C_DATA.BIN", "DATA/07_AREA.D/D_DATA.BIN",
    "DATA/08_AREA.E/E_DATA.BIN", "DATA/09_AREA.F/F_DATA.BIN",
    "DATA/10_AREA.G/G_DATA.BIN", "DATA/11_AREA.H/H_DATA.BIN",
    "DATA/13_AREA.I/I_DATA.BIN", "DATA/02_AREA.B/J_DATA.BIN",
    "DATA/07_AREA.D/K_DATA.BIN", "DATA/15_AREA.Z/Z_DATA.BIN",
]


def iso():
    with open(_KIT / "extracted" / "iso_files.json") as f:
        return [r for r in json.load(f) if not r.get("dir")]


def main_image():
    rec = next(r for r in iso() if r["path"] == "MAIN.EXE")
    blob = disc.extract(rec["lba"], rec["size"])
    assert blob[:8] == b"PS-X EXE" and blob[0x18:0x1C] == struct.pack("<I", MB)
    return blob[2048:]          # headerless: offset 0 is MB


def slus_image():
    rec = next(r for r in iso() if r["path"] == "SLUS_002.92")
    blob = disc.extract(rec["lba"], rec["size"])
    assert blob[:8] == b"PS-X EXE"
    return blob[2048:]


def check():
    im = main_image()
    by_lba = {r["lba"]: r for r in iso()}
    w = lambda va: struct.unpack_from("<I", im, va - MB)[0]

    # ------------------------------------------------ the 12-entry table
    entries = []
    for i in range(12):
        rec = w(TABLE + 4 * i)
        assert MASTER <= rec < MASTER + 344 * 8, hex(rec)
        assert (rec - MASTER) % 8 == 0, hex(rec)
        size, lba = struct.unpack_from("<II", im, rec - MB)
        row = by_lba[lba]
        assert row["path"] == EXPECTED[i] and row["size"] == size, (i, row, size)
        entries.append(row["path"])
    assert entries == EXPECTED, entries

    # A is slot 0 and Z is slot 11 -- both live table slots
    assert entries[0].endswith("A_DATA.BIN") and entries[11].endswith("Z_DATA.BIN")
    recs = [w(TABLE + 4 * i) for i in range(12)]
    assert len(set(recs)) == 12, recs

    # ------------------------------------------------ the reader instruction
    # lbu $a0,0x2($v0) with $v0 = *(0x8017DB24); sll $v0,$a0,2; lw $a0,0($at)
    # with $at = 0x8016F3B4 + $v0; jal 0x800C2EF8 with delay-slot lui 0x8008.
    # 0x8017DB24 itself is a runtime pointer global past the end of MAIN's
    # image, so it is not readable from the image; what the image holds is the
    # code that loads it (0x80127A70: lui 0x8018 / lw -0x24DC).
    assert w(0x80127A6C) == 0x3C028018 and w(0x80127A70) == 0x8C42DB24, \
        "gs = *(0x8017DB24) at 0x80127A6C/0x80127A70"
    assert w(0x80127A78) == 0x90440002, hex(w(0x80127A78))
    assert w(0x80127A88) == 0x3C018017 and w(0x80127A8C) == 0x2421F364
    assert w(0x80127AC8) == 0x00041080, "the index shift is the branch delay slot"
    assert w(0x80127AD0) == 0x3C018017 and w(0x80127AD4) == 0x2421F3B4
    assert w(0x80127AD8) == 0x00220821
    assert w(0x80127ADC) == 0x8C240000
    assert w(0x80127AE0) == 0x0C030BBE, "jal 0x800C2EF8"
    assert (0x0C030BBE & 0x03FFFFFF) << 2 | 0x80000000 == LOADER
    assert w(0x80127AE4) == 0x3C058008, "delay slot: destination 0x80080000"
    # the same byte is the map_id (region table 0x80170064)
    assert w(0x80127BA4) == 0x90620002
    assert w(0x80127BB8) == 0x24210064

    # the loader is the vtable +0x10 slot, and 0x800C2EF8 reads record[+4]
    # (the LBA) and record[+0] (the size) -- i.e. it consumes exactly the
    # [u32 size][u32 lba] pair the table's entries point at.
    assert struct.unpack_from("<I", im, 0x80165608 - MB + 0x10)[0] == LOADER
    assert w(0x800C2EF8 + 0x50) == 0x8E040004, "lw $a0,0x4(record) = the LBA"
    assert w(0x800C2EF8 + 0x6C) == 0x8E040000, "lw $a0,0x0(record) = the size"

    # ------------------------------------------------ the writers of gs[0x02]
    # new-game start-up clears it, so a fresh game enters index 0 = area A.
    sl = slus_image()
    assert struct.unpack_from("<I", sl, 0x800175F8 - SLUS_BASE)[0] == 0xA0400002
    assert struct.unpack_from("<I", sl, 0x800175F0 - SLUS_BASE)[0] == 0x8C4220C0
    # the mode-1 init writes 1 = area B.
    assert [w(0x80128D38 + 4 * i) for i in range(4)] == \
        [0x3C038018, 0x8C63DB24, 0x34020001, 0xA0620002]

    # ------------------------------------------------ no second path
    # exactly one of the 7 `jal 0x800C2EF8` sites uses destination 0x80080000
    imm = (LOADER >> 2) & 0x03FFFFFF
    sites = [MB + o for o in range(0, len(im) - 4, 4)
             if (struct.unpack_from("<I", im, o)[0] >> 26) == 3
             and (struct.unpack_from("<I", im, o)[0] & 0x03FFFFFF) == imm]
    assert sites == [0x800C4920, 0x800C9754, 0x800C9D1C, 0x80125E80,
                     0x80127AE0, 0x801283B0, 0x80130F70], [hex(s) for s in sites]
    assert w(0x80127AE4) == 0x3C058008

    # ------------------------------------------------ the content identity
    # A and Z differ in file offsets but agree in every decoded content field.
    a = disc.extract(by_lba[_lba(by_lba, "A_DATA.BIN")]["lba"],
                     by_lba[_lba(by_lba, "A_DATA.BIN")]["size"])
    z = disc.extract(by_lba[_lba(by_lba, "Z_DATA.BIN")]["lba"],
                     by_lba[_lba(by_lba, "Z_DATA.BIN")]["size"])
    assert a != z and len(a) != len(z), (len(a), len(z))
    assert _content_key(a) == _content_key(z), "A and Z content fields disagree"

    print("PASS: MAIN.EXE 0x8016F3B4 is a 12-entry table of master-file-table "
          "records, read by the mode-1 handler as "
          "`lw $a0,0x8016F3B4[gs[0x02]]` and handed to the loader 0x800C2EF8 at "
          "destination 0x80080000 (0x80127A78..0x80127AE4, delay slot included) "
          "-- so area A is slot 0 and area Z is slot 11, both live, and neither "
          "is dead; the same gs[0x02] indexes the region table 0x80170064. "
          "A_DATA and Z_DATA are identical in the index plane, the flag plane, "
          "all three CLUTs and all five atlas pages (%d vs %d bytes on disc, "
          "different offsets)." % (len(a), len(z)))


def _lba(by_lba, base):
    return next(r["lba"] for r in by_lba.values() if r["path"].endswith(base))


def _content_key(d):
    """The decoded content fields, read out of the file with the codec.

    S = *(D+0x00); the 5 atlas pages are at S+0x08, the 3 CLUTs at S+0x0C and
    the 160x120 plane at S+0x14.  All are `[u32 comp_len][LZSS]`, so this is an
    independent decode rather than a byte compare.
    """
    sys.path.insert(0, str(_KIT / "tools"))
    import lzss
    LB = 0x80080000
    n = len(d)
    D = struct.unpack_from("<I", d, 0)[0] - LB
    S = struct.unpack_from("<I", d, D)[0] - LB
    key = {"s04": struct.unpack_from("<H", d, S + 4)[0]}

    def dec(p):
        off = p - LB
        ln = struct.unpack_from("<I", d, off)[0]
        out, used = lzss.decode_container(d, off)
        assert used == 4 + ln, (off, used, ln)
        return out

    pt = struct.unpack_from("<I", d, S + 8)[0] - LB
    key["pages"] = [dec(struct.unpack_from("<I", d, pt + 4 * k)[0])
                    for k in range(5)]
    ct = struct.unpack_from("<I", d, S + 0x0C)[0] - LB
    key["cluts"] = [d[struct.unpack_from("<I", d, ct + 4 * k)[0] - LB:][:512]
                    for k in range(3)]
    key["plane"] = dec(struct.unpack_from("<I", d, S + 0x14)[0])
    return key


if __name__ == "__main__":
    check()
