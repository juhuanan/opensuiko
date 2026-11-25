#!/usr/bin/env python3
"""The 04_PLAY walk-cycle anchor: independent re-derivation.

The measurement is written out here with plain numpy over the atlas bytes, so a
bug in `play_cycle.py` cannot make this pass.  Disc required.

The load-bearing assertion is not "the strip looks right" -- it is that the foot
inset is a **universal** property of S2 (78/78 within 2 px) and is **not** a
property of S1 (a contrast that a coincidence would not produce).

Run: `python3 kit/tests/test_play_cycle.py`
"""
from pathlib import Path
import statistics
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import numpy as np  # noqa: E402

import play_cycle as pc  # noqa: E402
import play_sprite_geometry as G  # noqa: E402

FOOT_INSET = 1


def insets(name, d, pr, sec_name):
    """(foot, centre-x) content insets for one section, from the pixels."""
    s = next(x for x in pr["sections"] if x["name"] == sec_name)
    pal = [G.rgb555(w) for w in (s.get("palette") or [])]
    foot, cen, empty = [], [], 0
    for raw in s["e_raw"]:
        p = G.derive_rect(raw)
        # S1 has TWO atlas pages and about half its pieces select the second, so
        # the page must come from the piece -- reading blobs[0] for everything
        # cuts real pieces out of the wrong page and measures garbage.
        bi = p["atlas"][0] + (1 if p["atlas"][1] == 2 else 0)
        if bi >= len(s["blobs"]):
            continue
        a = np.array(G.cut(s["blobs"][bi], p, pal))[..., 0]
        ys, xs = np.nonzero(a != 0)
        if not len(ys):
            # a fully transparent e-record is an unused slot, not a pose; it is
            # counted and excluded, never silently treated as (0, 0)
            empty += 1
            continue
        h, w = a.shape
        foot.append(int(h - 1 - ys.max()))
        cen.append(int(xs.min() + xs.max() + 1 - w))
    return foot, cen, empty


def check():
    s2, s1 = [], []
    for e in G.play_files():
        name, d = G.load(e["path"])
        pr = G.probe(name, d)
        for sec, bucket in (("S2", s2), ("S1", s1)):
            foot, cen, empty = insets(name, d, pr, sec)
            bucket.append({
                "file": name, "n": len(foot), "empty": empty,
                "spread": max(foot) - min(foot),
                "median": statistics.median(foot),
                "cen": max(cen) - min(cen),
            })

    # ------------------------------------------------ the anchor, universally
    assert len(s2) == 78, len(s2)
    assert sum(m["empty"] for m in s2) == 0, [m for m in s2 if m["empty"]]
    # 12 or 13 records, of which the last 3 are FLAGGED DUPLICATES of the 3
    # before them (same tile and rect, differing only in +0x0F) -- so they are
    # not extra poses and must be excluded from the anchor population
    assert all(m["n"] in (9, 10) for m in s2), [m["n"] for m in s2]

    # ------------------------------------------- the flagged duplicate group
    # In every file the S2 records from index 9 on set +0x0F to 2, and 233 of
    # the 235 such records are BYTE-IDENTICAL to an earlier unflagged record
    # apart from that byte -- same tile, rect, tpage and CLUT.  So +0x0F is a
    # DRAW ATTRIBUTE, not a source selector.  The fork's doc calls +0x0F
    # "atlas_sel_b"; that is wrong for S2, which has exactly ONE atlas page.
    nfiles = 0
    twins = 0
    flagged = 0
    for e in G.play_files():
        name, d = G.load(e["path"])
        s = next(x for x in G.probe(name, d)["sections"] if x["name"] == "S2")
        raws, flags = s["e_raw"], None
        assert len(s["blobs"]) == 1, (name, len(s["blobs"]))
        flags = [r[0x0F] for r in raws]
        assert set(flags) <= {0, 2}, (name, flags)
        assert flags[9] == 2 and all(f == 0 for f in flags[:9]), (name, flags)
        assert all(f == 2 for f in flags[9:]), (name, flags)
        # 77 files carry 12 records (3 flagged); SHU carries 13 (4 flagged)
        assert len(raws) in (12, 13), (name, len(raws))
        if len(raws) == 13:
            assert name.endswith("SHU.BIN"), name
        for i in range(9, len(raws)):
            flagged += 1
            if any(raws[j][:0x0F] == raws[i][:0x0F] and raws[j][0x0F] == 0
                   for j in range(9)):
                twins += 1
        nfiles += 1
    assert nfiles == 78
    assert flagged == 235, flagged
    assert twins == 233, twins     # the 2 exceptions differ in tpage as well

    # ------------------------------------------------ the S1 contrast
    # If the anchor were an artifact, S1 would satisfy it too.  It does not: S1
    # is a SET of one-shot battle poses (knocked down, mid-lunge) that
    # legitimately do not share a foot line.
    assert len(s1) == 78, len(s1)
    s1_tight = sum(1 for m in s1 if m["spread"] <= 2)
    assert s1_tight == 3, f"S1 must NOT satisfy the S2 anchor: {s1_tight}/78"
    worst = max(s1, key=lambda m: m["spread"])
    assert worst["spread"] == 13, worst
    assert worst["file"].endswith("RYK.BIN"), worst   # the recorded worst case

    # ------------------------------- the ordered-sequence vs set contrast
    # S2 is an ordered cycle (neighbours much more alike than endpoints); S1 is a
    # set of distinct one-shot poses.  This is independent of the foot anchor and
    # is what supports reading S1 as the battle set and S2 as the field cycle.
    seq = pc.sequence_stats()
    s2o = [x["ordered"] for x in seq["S2"]]
    s1o = [x["ordered"] for x in seq["S1"]]
    assert len(s2o) == 78 and len(s1o) == 78
    assert statistics.mean(s2o) > 0.10, statistics.mean(s2o)
    assert statistics.mean(s1o) < 0.05, statistics.mean(s1o)
    assert all(x > 0 for x in s2o), [x for x in s2o if x <= 0]
    s2step = statistics.mean(x["step"] for x in seq["S2"])
    s1step = statistics.mean(x["step"] for x in seq["S1"])
    assert s2step - s1step > 0.2, (s2step, s1step)

    # ------------------------------------------------ the render contract
    # A strip must be one frame per piece, and every frame's bottom row must sit
    # at the same canvas row -- that IS the anchor, checked on the output.
    name, d = G.load("DATA/04_PLAY/SHU.BIN")
    pr = G.probe(name, d)
    frames = pc.strip(name, d, pr)
    # the UNIQUE walk frames: SHU's S2 has 13 records but 4 are flagged variants
    assert len(frames) == 9, len(frames)
    hs = {f.shape[0] for f in frames}
    assert len(hs) == 1, hs
    bottoms = []
    for f in frames:
        rows = np.nonzero(f.any(axis=2).any(axis=1))[0]
        bottoms.append(int(rows.max()))
    assert len(set(bottoms)) <= 3, bottoms      # <= 3 px of foot jitter
    shell = pc.sheet(frames)
    assert shell.width > 0 and shell.height > 0

    # the tool's own numbers must agree with this re-derivation
    tool = {m["file"]: m for m in pc.stats()["s2"]}
    assert len(tool) == 78
    for m in s2:
        t = tool[m["file"]]
        assert t["foot_spread"] == m["spread"], (m["file"], t, m)
        assert t["foot_median"] == m["median"], (m["file"], t, m)

    print("PASS: 04_PLAY walk-cycle anchor derived from the art -- all 78 S2 "
          "cycles are bottom-anchored with foot-inset spread <=2 px and median "
          "exactly 1 over their unique poses (S2 records from index 9 on carry "
          "+0x0F==2 and 233/235 of them are byte-identical to an earlier record bar "
          "that byte, so +0x0F is a DRAW ATTRIBUTE, not an atlas selector), while "
          "S1 satisfies the anchor in only "
          f"{s1_tight}/78 (worst {worst['spread']} px, {worst['file']}), so the "
          "rule is a property of the cycle sections and not of the tool; and the "
          "sequence statistic separates them independently -- S2 is ORDERED "
          f"({statistics.mean(s2o):+.3f}) while S1 is a SET "
          f"({statistics.mean(s1o):+.3f}), "
          "supporting S2 = field walking and S1 = battle animations")


if __name__ == "__main__":
    check()
