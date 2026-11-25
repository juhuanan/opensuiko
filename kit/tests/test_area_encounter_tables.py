#!/usr/bin/env python3
"""Independent re-derivation of the area encounter tables.

Written with plain `struct.unpack_from` and literal pointer arithmetic -- it does
not call the producer's `chain`/`encounters` helpers -- so a bug in
`area_encounter_tables.py` cannot make this pass.

Two anchors come from `battle_placement_resolved.md` and are quoted
there, which is what makes this a check rather than a restatement:

  * `E_DATA.BIN`'s `selectors` is `0x80096188` with **11** encounters;
  * the eight primary A-H areas carry **77** encounters in total.

It also pins the **disproof**: the encounter structs are not a contiguous
`0x18`-stride table. An earlier version of the producer computed
`start = selectors - 0x18*count`, which forces the table to end at `selectors`
and then "finds" a stride that was assumed rather than measured.

Disc required. Run: `python3 kit/tests/test_area_encounter_tables.py`
"""
from pathlib import Path
import collections
import json
import os
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import area_encounter_tables as A  # noqa: E402

BASE = 0x80080000
STRIDE = 0x18
FILE = "DATA/08_AREA.E/E_DATA.BIN"


def listing():
    with open(_KIT / "extracted" / "iso_files.json") as f:
        return {r["path"]: r for r in json.load(f) if not r.get("dir")}


def load(rec):
    return disc.extract(rec["lba"], rec["size"])


def u32(d, off):
    return struct.unpack_from("<I", d, off)[0]


def rd(d, addr):
    """Read a word at a RAM address, refusing to leave the file."""
    o = addr - BASE
    assert 0 <= o <= len(d) - 4, "0x%08X is outside the file" % addr
    return u32(d, o)


def selectors_of(d):
    """D -> resources -> directory -> selectors, exactly as the corpus states."""
    D = u32(d, 0)
    resources = rd(d, D + 0x0C)
    directory = rd(d, resources)
    return rd(d, directory + 0x08), D


def area_files():
    ls = listing()
    out = []
    for p, r in sorted(ls.items()):
        b = os.path.basename(p)
        if b.endswith("_DATA.BIN") and r["size"] > 0x1000:
            out.append((p, r))
    return out


def check():
    ls = listing()
    rows = area_files()
    assert len(rows) == 11, [p for p, _ in rows]

    total = collections.Counter()
    all_active = []
    all_gaps = set()
    consts = collections.Counter()
    per_file = {}

    for path, rec in rows:
        d = load(rec)
        tag = os.path.basename(path)[0]
        try:
            sel, _D = selectors_of(d)
            assert BASE <= sel < BASE + len(d)
            so = sel - BASE
            count = u32(d, so)
            assert 1 <= count <= 64
            ptrs = [u32(d, so + 4 + 4 * i) for i in range(count)]
        except AssertionError:
            # J and K: the corpus also says their root layout is unsupported
            assert tag in "JK", (path, "unexpected chain failure")
            per_file[tag] = None
            continue

        per_file[tag] = count
        total[tag] = count
        targets = []
        actives = []
        for k, p in enumerate(ptrs):
            o = p - BASE
            assert 0 <= o <= len(d) - STRIDE, (path, k, hex(p))
            active = u32(d, o)
            roster = list(d[o + 4 : o + 0x0A])         # always six slots
            assert len(roster) == 6
            assert 1 <= active <= 6, (path, k, active)
            # THE CORROBORATED FIELD: +0 is the number of non-zero roster bytes
            assert active == sum(1 for x in roster if x), (path, k, active, roster)
            assert all(x <= 8 for x in roster), (path, k, roster)
            # the two padding bytes are unused
            assert list(d[o + 0x0A : o + 0x0C]) == [0, 0], (path, k)
            c0, c1 = u32(d, o + 0x0C), u32(d, o + 0x10)
            consts[(c0, c1)] += 1
            assert c0 == 100 and c1 == 0, (path, k, c0, c1)
            aux = u32(d, o + 0x14)
            assert BASE <= aux < BASE + len(d), (path, k, hex(aux))
            targets.append(o)
            all_active.append(active)

        # ---- the anchors, quoted from the corpus -------------------------
        if tag == "E":
            assert sel == 0x80096188, hex(sel)
            assert count == 11, count
            # the corpus's E encounter 1 is the pointer at selectors[1],
            # file offset 0x160B0, roster [3,3,3,1,0,0]
            assert ptrs[0] - BASE == 0x160B0, hex(ptrs[0])
            o = ptrs[0] - BASE
            assert u32(d, o) == 4          # four ACTIVE enemies
            assert list(d[o + 4 : o + 10]) == [3, 3, 3, 1, 0, 0]
            # ...and its aux dereferences to the position table at 0x15FE4
            aux = u32(d, o + 0x14)
            assert aux == 0x8009602C, hex(aux)
            assert u32(d, aux - BASE) == 0x80095FE4, hex(u32(d, aux - BASE))
            xs = [struct.unpack_from("<3h", d, 0x15FE4 + 6 * i)
                  for i in range(6)]
            assert xs == [(40, 0, 0), (40, -50, 0), (40, 50, 0),
                          (-40, 0, 0), (-40, -50, 0), (-40, 50, 0)], xs

        # ---- the disproof -------------------------------------------------
        g = {targets[i + 1] - targets[i] for i in range(len(targets) - 1)}
        all_gaps |= g
        # nothing here is a uniform 0x18 table unless the gaps say so
        assert (g == {0x18}) == (tag in "DFH"), (tag, sorted(g))

    # the A-H total the corpus records
    ah = sum(v for t, v in total.items() if t in "ABCDEFGH")
    assert ah == 77, ah
    assert total["E"] == 11
    assert sum(total.values()) == 90, sum(total.values())

    # every struct carries the same two constants
    assert set(consts) == {(100, 0)}, consts
    assert sum(consts.values()) == 90, consts

    # the active-count distribution, which is what an encounter table should
    # look like: 1-6 enemies, never zero, never more than six slots
    dist = collections.Counter(all_active)
    assert dict(sorted(dist.items())) == {1: 21, 2: 23, 3: 16, 4: 17, 5: 9, 6: 4}, dict(dist)
    assert 0 not in dist and max(dist) == 6

    # the structs are NOT a contiguous 0x18 table: real gaps are wider and
    # sometimes negative, so the pointers are not even sorted
    assert 0x18 in all_gaps
    assert any(x > 0x18 for x in all_gaps), sorted(all_gaps)
    assert any(x < 0 for x in all_gaps), sorted(all_gaps)

    # and the circular construction genuinely disagrees with the pointers:
    # `selectors - 0x18*count` is not where the first struct is, for A
    d = load(ls["DATA/01_AREA.A/A_DATA.BIN"])
    sel, _ = selectors_of(d)
    so, cnt = sel - BASE, u32(d, sel - BASE)
    ptrs = [u32(d, so + 4 + 4 * i) for i in range(cnt)]
    assert so - STRIDE * cnt != min(ptrs) - BASE, "the circular reading would agree"
    assert so - STRIDE * cnt == 0x16550 and min(ptrs) - BASE == 0x16400

    # ---- the unsound code heuristic, reproduced ---------------------------
    # A run of zeros scores 100 % "workhorse opcode" share, because opcode 0 is
    # in the workhorse set. That is how the tracked inventory's DATA/TABLE
    # class was assigned, so it is not a verified data classification.
    WORK = {0, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF}
    zeros = b"\x00" * 0x800
    c = collections.Counter(u32(zeros, i) >> 26 for i in range(0, 0x800, 4))
    share = 100.0 * sum(v for k, v in c.items() if k in WORK) / sum(c.values())
    assert share == 100.0, share
    assert set(c) == {0}
    # the real test separates them
    vc = load(ls["DATA/06_AREA.C/VC61.BIN"])
    assert A.code_signals(vc) == {"jr_ra": 0, "prologues": 0}
    assert A.verdict(vc) == "DATA"
    war = load(ls["DATA/16_WAR/WAR_KUWA.BIN"])
    assert A.code_signals(war)["jr_ra"] > 100

    print("PASS: area encounter tables -- E_DATA selectors 0x80096188 with 11 "
          "encounters; 90/90 selector pointers resolve to structs whose +0 is the "
          "number of NON-ZERO bytes in the six-slot roster at +4 (the corroborated "
          "field, distribution %s) and whose +0xC/+0x10 are the constant pair "
          "(100, 0); E encounter 1 is active=4 roster=[3,3,3,1,0,0] with aux "
          "0x8009602C -> positions 0x80095FE4 carrying the corpus's six coordinates; "
          "A-H totals 77 as the corpus records; and the contiguous-0x18-stride "
          "reading is DISPROVEN (gaps reach 0x78 and go negative, and "
          "selectors-0x18*count is 0x16550 where A's first struct is 0x16400). "
          "Also pinned: a zero run scores 100%% on the workhorse-opcode heuristic "
          "that assigned the inventory's DATA/TABLE class."
          % dict(sorted(dist.items())))


if __name__ == "__main__":
    check()
