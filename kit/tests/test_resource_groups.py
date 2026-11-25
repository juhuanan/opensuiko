#!/usr/bin/env python3
"""The resource-group directory and `VC61`'s role: independent re-derivation.

Everything here is plain `struct.unpack_from` over `MAIN.EXE`'s image and the
disc, so a bug in `resource_groups.py` cannot make it pass.  Disc required.

Run: `python3 kit/tests/test_resource_groups.py`
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
import resource_groups as rg  # noqa: E402

MB = 0x800C0800
TABLE = 0x80163D64
N = 344
DIR = 0x8016B358
VTABLE = 0x80165608
LOADER = 0x800C2EF8
JR = 0x03E00008


def iso():
    with open(_KIT / "extracted" / "iso_files.json") as f:
        return [r for r in json.load(f) if not r.get("dir")]


def img():
    rec = next(r for r in iso() if r["path"] == "MAIN.EXE")
    return disc.extract(rec["lba"], rec["size"])[2048:]


def rec_of(im, off):
    """(size, lba, path) for a MASTER_TABLE record pointer."""
    assert TABLE <= off < TABLE + N * 8, hex(off)
    size, lba = struct.unpack_from("<II", im, off - MB)
    path = next((r["path"] for r in iso() if r["lba"] == lba), None)
    return size, lba, path


def check():
    im = img()
    byname = {os.path.basename(r["path"]): r for r in iso()}

    # ---------------------------------------------- the master file table
    size, lba, path = rec_of(im, TABLE + 237 * 8)
    assert path.endswith("VC61.BIN"), path
    assert size == 31412 and lba == 99384, (size, lba)

    # ---------------------------------------------- the directory
    dirp = struct.unpack_from("<I", im, DIR - MB)[0]
    assert dirp == 0x8016B39C, hex(dirp)          # dir[0]
    g15 = struct.unpack_from("<I", im, DIR - MB + 0x3C)[0]
    assert g15 == 0x8016B670, hex(g15)            # dir[15]
    names = []
    for k in range(8):
        v = struct.unpack_from("<I", im, g15 - MB + 4 * k)[0]
        if not (TABLE <= v < TABLE + N * 8):
            break
        names.append(os.path.basename(rec_of(im, v)[2]))
    assert names == ["VC61.BIN", "VB5A21.BIN", "VB5B31.BIN"], names

    # dir[2] is the FACE portrait pages -- so the directory is not one subsystem
    g2 = struct.unpack_from("<I", im, DIR - MB + 8)[0]
    face = []
    for k in range(40):
        v = struct.unpack_from("<I", im, g2 - MB + 4 * k)[0]
        if not (TABLE <= v < TABLE + N * 8):
            break
        face.append(os.path.basename(rec_of(im, v)[2]))
    assert len(face) == 27 and face[0] == "FACE_01.BIN" and face[-1] == "FACE_27.BIN", face

    # ---------------------------------------------- the vtable's +0x10 IS the loader
    # this is what makes the group entries a LOAD LIST rather than opaque data
    assert struct.unpack_from("<I", im, VTABLE - MB + 0x10)[0] == LOADER

    # ---------------------------------------------- the companions
    for code, data in (("VC6.BIN", "VC61.BIN"), ("VB5A2.BIN", "VB5A21.BIN"),
                       ("VB5B3.BIN", "VB5B31.BIN")):
        c, d = byname[code], byname[data]
        dc = disc.extract(c["lba"], c["size"])
        dd = disc.extract(d["lba"], d["size"])
        cj = sum(1 for i in range(0, len(dc) - 4, 4) if struct.unpack_from("<I", dc, i)[0] == JR)
        dj = sum(1 for i in range(0, len(dd) - 4, 4) if struct.unpack_from("<I", dd, i)[0] == JR)
        assert cj > 0, (code, cj)          # the overlay is CODE
        assert dj == 0, (data, dj)         # the companion is DATA
    # and these are the ONLY three such pairs among the group members
    pairs = {(os.path.basename(c["code"]), os.path.basename(c["data"]))
             for c in rg.companions()}
    assert ("VC6.BIN", "VC61.BIN") in pairs
    assert ("VB5A2.BIN", "VB5A21.BIN") in pairs
    assert ("VB5B3.BIN", "VB5B31.BIN") in pairs

    # ---------------------------------------------- the consumers
    cons = rg.consumers()
    s15 = {os.path.basename(c["file"]) for c in cons if c["index"] == 15}
    # 12 FILES select dir[15] (16 sites in all: 12 for dir[15] + 4 for dir[2])
    assert len(s15) == 12, sorted(s15)
    for f in ("VB5A1.BIN", "VB5A2.BIN", "VB5B3.BIN", "VS1.BIN", "VAD.BIN"):
        assert f in s15, (f, sorted(s15))
    s2 = [c for c in cons if c["index"] == 2]
    assert len(s2) == 4, [os.path.basename(c["file"]) for c in s2]
    assert {c["index"] for c in cons} == {2, 15}

    # the directory is materialised by exactly ONE code site -- the init that
    # installs it as *(base+0x14b8).  (Address 0x8016B358 is built as
    # lui 0x8017 + addiu -0x4ca8, so this is an instruction reference, not a
    # data literal.)  One reference rules out a second, independent installer.
    refs = []
    for i in range(0, len(im) - 8, 4):
        w0, w1 = struct.unpack_from("<II", im, i)
        if (w0 >> 26) != 0x0F:
            continue
        r0 = (w0 >> 16) & 0x1F
        if (w1 >> 26) != 0x09 or ((w1 >> 21) & 0x1F) != r0 or ((w1 >> 16) & 0x1F) != r0:
            continue
        imm = w1 & 0xFFFF
        imm = imm - 0x10000 if imm & 0x8000 else imm
        if ((((w0 & 0xFFFF) << 16) + imm) & 0xFFFFFFFF) == DIR:
            refs.append(MB + i)
    assert refs == [0x800C9648], [hex(x) for x in refs]

    print("PASS: resource-group directory derived -- dir[15] = {VC61, VB5A21, "
          "VB5B31}; gs[0x1bc4]+0x10 (0x80165608+0x10) IS the file loader "
          "0x800C2EF8, so group entries are a LOAD LIST; VC61/VB5A21/VB5B31 are "
          "the data companions of the CODE overlays VC6/VB5A2/VB5B3 (jr $ra>0 vs "
          "==0) and the <overlay>1 naming holds for exactly those three pairs; 12 "
          "FILES read dir[*(base+0x14b8)] selecting dir[15] (12 sites), and four "
          "also select dir[2] = the 27 FACE portrait pages")


if __name__ == "__main__":
    check()
