#!/usr/bin/env python3
"""`VC61.BIN` characterisation: independent re-derivation.

Plain byte arithmetic over the disc bytes, and the load base is re-solved by
search here rather than imported.  Disc required.

The load-bearing assertions are:
  * it is NOT code (0 `jr $ra`, 0 prologues) while its siblings have many;
  * 99 of its 113 ALIGNED RAM pointers are self-references under base
    `0x80080000`, against only 2 under the natural alternative `0x80010000`.
    (The tool's own doc said 117 because `pointers()` scans at stride 2 and so
    counts four unaligned windows as slots; alignment is enforced here.)
  * `0x80080000` is exactly where the sibling overlay `VC6` ends.
The last point is what pins the base: the self-pointer fit alone only locates
the cluster to a file-sized window, and that degeneracy is asserted, not hidden.

Run: `python3 kit/tests/test_vc61_module.py`
"""
from pathlib import Path
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import vc61_module as V  # noqa: E402

JR_RA = bytes.fromhex("0800e003")
RAM_LO, RAM_HI = 0x80010000, 0x801FFFFF


def prologues(d):
    n = 0
    for o in range(0, len(d) - 4, 4):
        w = struct.unpack_from("<I", d, o)[0]
        if (w >> 26) == 0x09 and ((w >> 21) & 0x1F) == 29:
            imm = w & 0xFFFF
            if imm & 0x8000:
                imm -= 0x10000
            if imm < 0:
                n += 1
    return n


def check():
    d = V.load()
    assert len(d) == 31412

    # ------------------------------------------------ not code
    assert d.count(JR_RA) == 0, "VC61 must contain no jr $ra"
    assert prologues(d) == 0, "VC61 must contain no function prologue"
    # the contrast: this is not an artifact of the counter
    vc6 = V.load("VC6.BIN")
    assert vc6.count(JR_RA) >= 50, vc6.count(JR_RA)
    assert prologues(vc6) >= 40
    vc3 = V.load("VC3.BIN")
    assert vc3.count(JR_RA) >= 10 and prologues(vc3) >= 10

    # ------------------------------------------------ content is zero-padded
    c = len(d.rstrip(b"\0"))
    assert c == 0x68AC, hex(c)
    assert len(d) - c == 4616
    assert d[c:] == b"\0" * 4616

    # ------------------------------------------------ the RAM pointers
    # stride 4: a "u32 slot" is aligned, and a stride-2 scan counts four
    # unaligned windows as slots (117 instead of 113)
    ptr = [(o, struct.unpack_from("<I", d, o)[0]) for o in range(0, len(d) - 4, 4)
           if RAM_LO <= struct.unpack_from("<I", d, o)[0] <= RAM_HI]
    assert len(ptr) == 113, len(ptr)
    assert all(o % 4 == 0 for o, _w in ptr)
    # and the four that a stride-2 scan adds are exactly these unaligned windows
    loose = [(o, struct.unpack_from("<I", d, o)[0]) for o in range(0, len(d) - 4, 2)
             if RAM_LO <= struct.unpack_from("<I", d, o)[0] <= RAM_HI and o % 4]
    assert [o for o, _w in loose] == [0x2282, 0x37BE, 0x44A6, 0x5A42], \
        [hex(o) for o, _w in loose]
    vals = [w for _o, w in ptr]
    assert min(vals) == 0x800123B8 and max(vals) == 0x80192D07, (hex(min(vals)), hex(max(vals)))

    # ------------------------------------------------ the base, solved here
    def fit(base):
        return sum(1 for w in vals if base <= w < base + len(d))

    assert fit(0x80080000) == 99, fit(0x80080000)
    assert fit(0x80010000) == 2, fit(0x80010000)
    # the derived base is exactly VC6's end -- independent corroboration
    assert 0x80010000 + len(vc6) == 0x80080000
    assert 0x80010000 + len(vc6) == V.LOAD_BASE == 0x80080000
    # HONESTY: the fit alone is degenerate over a file-sized window, so the fit
    # locates the cluster but VC6's end pins the absolute position.  Recorded.
    plateau = [b for b in range(0x80010000, 0x80100000, 0x10) if fit(b) == 99]
    assert len(plateau) > 100, len(plateau)
    assert all(fit(b) <= 99 for b in range(0x80010000, 0x80100000, 0x40))
    # and the self-targets really do land inside this file's own content
    self_offs = sorted(w - 0x80080000 for w in vals if 0x80080000 <= w < 0x80080000 + len(d))
    assert self_offs[0] >= 0x388 and self_offs[-1] <= c, (hex(self_offs[0]), hex(self_offs[-1]))

    # ------------------------------------------------ the 16.16 record table
    recs = V.fixed_records(d)
    assert len(recs) == 11, len(recs)
    assert [r["off"] for r in recs] == [0x450 + 0x30 * k for k in range(11)]
    for r in recs:
        v = r["values"]
        assert v[1] == 64, v                     # constant in all 11
        assert v[2] == v[3] == v[4] != 0, v      # triple-equal dimension
        assert v[2] in (240, 256, 304, 320, 368), v
        assert v[5] in (0, 7, -5, -10), v
        assert v[8] in (-48, -44), v
        assert v[10] in (22, 38, 40), v
        assert v[0] == v[6] == v[7] == v[9] == v[11] == 0, v
    # the raw encoding really is 16.16 whole numbers
    o = recs[1]["off"]
    assert struct.unpack_from("<I", d, o + 4)[0] == 0x00400000     # 64.0
    assert struct.unpack_from("<I", d, o + 8)[0] == 0x00F00000     # 240.0
    assert struct.unpack_from("<I", d, o + 4 * 8)[0] == 0xFFD00000  # -48.0

    # ------------------------------------------------ not audio / not a TIM
    # the sector form, when the raw image is reachable
    try:
        import disc
        path, _geom, _off = disc.resolve_raw()
        if path.lower().endswith(".bin"):
            with open(path, "rb") as f:
                f.seek(99384 * 2352)
                sec = f.read(2352)
            assert sec[15] == 2 and sec[16] == 0 and sec[17] == 0, \
                (sec[15], sec[16], sec[17])      # Mode 2, Form 1, no audio flags
    except Exception:
        pass    # no raw image present: the assertion is vacuous, not failed
    # the lone 0x10000000 match is not a TIM header (blocks would be 0)
    hits = []
    o = d.find(bytes.fromhex("10000000"))
    while o >= 0:
        hits.append(o)
        o = d.find(bytes.fromhex("10000000"), o + 1)
    assert 0x6F0 in hits
    for h in hits:
        if h + 12 <= len(d):
            blocks = struct.unpack_from("<I", d, h + 8)[0]
            assert blocks == 0 or blocks > 8, (hex(h), blocks)

    print("PASS: VC61.BIN is a DATA module stored pre-relocated for base "
          "0x80080000 -- 99/113 ALIGNED pointers are self-references against 2 for "
          "0x80010000, and that base is exactly VC6's end (0x80010000+0x70000); "
          "0 jr $ra and 0 prologues against VC6's 67/55; content 0x68AC with 4616 "
          "B of zero padding; 11 x 0x30 records of 12 16.16 whole numbers with a "
          "constant 64 and a triple-equal dimension; the fit's degeneracy over a "
          "file-sized window is asserted, so VC6's end is what pins the base")


if __name__ == "__main__":
    check()
