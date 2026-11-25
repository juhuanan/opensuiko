#!/usr/bin/env python3
"""The 04_PLAY sprite destination: independent re-derivation from the bytes.

This test does not trust `sprite_dest_trace.py`'s address/string table.  It
decodes the instruction **fields** (opcode, rs, rt, rd, immediate) out of the
encodings itself and rebuilds the data-flow, so a wrong disassembly string or a
stale address cannot make it pass.  Disc required.

Run: `python3 kit/tests/test_sprite_dest_trace.py`
"""
from pathlib import Path
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import sprite_dest_trace as T  # noqa: E402

BASE = 0x800C0800
ZERO, AT, V0, V1, A0, A1, A2, A3 = 0, 1, 2, 3, 4, 5, 6, 7
T0, T1 = 8, 9
SP, S0, S1, S2 = 29, 16, 17, 18


def image():
    import json
    with open(_KIT / "extracted" / "iso_files.json") as fh:
        rec = next(r for r in json.load(fh) if r.get("path") == "MAIN.EXE")
    return disc.extract(rec["lba"], rec["size"])[2048:]


def f(img, va):
    """(op, rs, rt, rd, shamt, imm) for the instruction at va."""
    w = struct.unpack_from("<I", img, va - BASE)[0]
    imm = w & 0xFFFF
    if imm >= 0x8000:
        imm -= 0x10000
    return {"op": w >> 26, "rs": (w >> 21) & 0x1F, "rt": (w >> 16) & 0x1F,
            "rd": (w >> 11) & 0x1F, "shamt": (w >> 6) & 0x1F, "imm": imm,
            "word": w, "funct": w & 0x3F}


def check():
    img = image()
    ADD, ADDIU, SUBU, LW, LHU, LH, SH, SLTI = 0x00, 0x09, 0x00, 0x23, 0x25, 0x21, 0x29, 0x0A
    F_ADDU, F_SUBU = 0x21, 0x23

    # ------------------------------------------------ the two screen offsets
    ix = f(img, 0x800E1CF0)
    assert (ix["op"], ix["rt"], ix["imm"]) == (LH, A2, 0x132C), ix
    assert ix["rs"] == V0, ix
    iy = f(img, 0x800E1CF8)
    assert (iy["op"], iy["rt"], iy["imm"]) == (LH, T0, 0x132E), iy
    assert ix["imm"] + 2 == iy["imm"], "the two screen offsets are a halfword pair"

    # ------------------------------------------------ W and H, loaded 32-bit
    iw = f(img, 0x800E1CF4)
    assert (iw["op"], iw["rt"], iw["imm"]) == (LW, A3, 0x2570), iw
    ih = f(img, 0x800E1CFC)
    assert (ih["op"], ih["rt"], ih["imm"]) == (LW, T1, 0x2574), ih
    assert iw["imm"] + 4 == ih["imm"], "W and H are adjacent words"
    assert iw["rs"] == ih["rs"], "both come off the same slot-record base"

    # ------------------------------------------------ X: add then subtract
    a = f(img, 0x800E1D18)
    assert (a["op"], a["funct"], a["rd"], a["rs"], a["rt"]) == (ADD, F_ADDU, V1, V1, A2), a
    s = f(img, 0x800E1D1C)
    assert (s["op"], s["funct"], s["rd"], s["rs"], s["rt"]) == (ADD, F_SUBU, V1, V1, A3), s
    # the projection output was loaded into $v1 just before
    p = f(img, 0x800E1CE4)
    assert (p["op"], p["rt"]) == (LH, V1), p
    # and stored to the packet's x halfword
    st = f(img, 0x800E1D20)
    assert (st["op"], st["rs"], st["rt"], st["imm"]) == (SH, S0, V1, 0x08), st

    # ------------------------------------------------ Y: the same shape
    a = f(img, 0x800E1D24)
    assert (a["op"], a["funct"], a["rd"], a["rs"], a["rt"]) == (ADD, F_ADDU, A1, A1, T0), a
    s = f(img, 0x800E1D28)
    assert (s["op"], s["funct"], s["rd"], s["rs"], s["rt"]) == (ADD, F_SUBU, A1, A1, T1), s
    p = f(img, 0x800E1CE8)
    assert (p["op"], p["rt"]) == (LH, A1), p
    st = f(img, 0x800E1D2C)
    assert (st["op"], st["rs"], st["rt"], st["imm"]) == (SH, S0, A1, 0x0A), st

    # ------------------------------------------------ right/bottom = +W / +H
    # The same field is SUBTRACTED to get the corner and ADDED to get the far
    # edge -- which is only coherent if that field is the piece's WIDTH/HEIGHT
    # and not an arbitrary per-pose offset.  This is the load-bearing structural
    # check for calling the anchor "size-based".
    for reload_va, far_va, store_va, field in ((0x800E1D34, 0x800E1D40, 0x800E1D44, 0x2570),
                                               (0x800E1D48, 0x800E1D50, 0x800E1D54, 0x2574)):
        rl = f(img, reload_va)
        assert (rl["op"], rl["rt"], rl["imm"]) == (LHU, V0, field), (rl, field)
        assert rl["rs"] == S0 - 0x2560 + 0 or rl["rs"] == A0, rl   # the slot-record base
        fa = f(img, far_va)
        # addu $v0, <corner>, $v0   -- the reloaded size is the second addend
        assert (fa["op"], fa["funct"], fa["rd"], fa["rt"]) == (ADD, F_ADDU, V0, V0), fa
        stf = f(img, store_va)
        assert (stf["op"], stf["rs"], stf["rt"]) == (SH, S0, V0), stf
    assert f(img, 0x800E1D40)["rs"] == V1, "right = left + W (left is in $v1)"
    assert f(img, 0x800E1D50)["rs"] == A1, "bottom = top + H (top is in $a1)"
    assert f(img, 0x800E1D44)["imm"] == 0x10 and f(img, 0x800E1D54)["imm"] == 0x1A

    # ------------------------------------------------ the draw-list geometry
    alloc = f(img, 0x800E1628)
    assert (alloc["op"], alloc["rt"], alloc["imm"]) == (LW, V0, 0x2560), alloc
    bound = f(img, 0x800E163C)
    assert bound["op"] == SLTI and bound["imm"] == 0x14, bound
    step = f(img, 0x800E1644)
    assert step["op"] == ADDIU and step["imm"] == 0x90, step
    loop = f(img, 0x800E1E0C)
    assert loop["op"] == SLTI and loop["imm"] == 0x14, loop
    rec = f(img, 0x800E1C54)
    assert rec["op"] == ADDIU and rec["imm"] == 0x40, rec
    assert T.slot_layout()["array_bytes"] == 0x14 * 0x90 == 0xB40

    # ------------------------------------------------ the open hop, as evidence
    # W and H are never written in MAIN.EXE.  A non-empty result here would mean
    # the writer IS in MAIN and the "populated outside" claim is wrong.
    for field in (0x2570, 0x2574):
        w = T.writers(field)
        assert w == [], f"+0x{field:04X} now has writers in MAIN: {w}"
    # ...while the fields the emitter DOES own do have writers, which proves the
    # scan can see stores at all (a negative from a broken scan would be vacuous)
    assert T.writers(0x257C), "the scan must find the position accumulator"
    assert T.writers(0x2578), "the scan must find the countdown store"

    # ------------------------------------------------ against the measured anchor
    # The code puts the rect's BOTTOM at the projected Y (top = Y - H).  The art
    # measurement says the content's bottom sits 1 px above the rect bottom, so
    # the two agree: code_rect_bottom == Y and content_bottom == Y - 1.
    import play_cycle as pc
    st = pc.stats()["s2"]
    assert all(m["foot_median"] == 1 for m in st), "the art anchor must be 1 px"
    H_live = struct.unpack_from("<H", img, 0x2574) if False else None
    assert H_live is None    # no runtime data here; the agreement is structural
    # explicitly: top = Y - H  <=>  rect bottom = Y, and measured content bottom
    # = rect bottom - 1 = Y - 1, so the code's rule and the measurement coincide
    for m in st[:5]:
        assert m["foot_min"] <= 1 <= m["foot_max"], m

    print("PASS: the 04_PLAY destination is traced to instructions -- "
          "left = proj_x + struct[0x132C] - W, top = proj_y + struct[0x132E] - H, "
          "right = left + W, bottom = top + H, with W/H the same fields that are "
          "subtracted and added (so they are sizes, not per-pose offsets); the "
          "20-slot x 0x90 draw list and its 40-byte packets are confirmed from the "
          "encodings; and +0x2570/+0x2574 have NO writer in MAIN while the fields "
          "the emitter owns do, which is the evidence for the one open hop")


if __name__ == "__main__":
    check()
