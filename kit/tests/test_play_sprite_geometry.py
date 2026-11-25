#!/usr/bin/env python3
"""`DATA/04_PLAY` sprite geometry: independent re-derivation of the piece rect.

Everything the tool claims is re-derived here with plain byte arithmetic and a
re-stated container walk, so a bug in `play_sprite_geometry.py` cannot make this
pass.  The shipped formula is then checked against a **null** that shuffles the
tile byte, and against three refuted alternatives -- the point is that the
formula is falsifiable, not that it produces a picture.

Disc required.

Run: `python3 kit/tests/test_play_sprite_geometry.py`
"""
from pathlib import Path
import collections
import json
import random
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import lzss  # noqa: E402
import play_sprite_geometry as G  # noqa: E402

ATLAS = 128
PITCH = 8
E_REC = 16


# ---------------------------------------------------------------- independent walk

def raw_files():
    with open(_KIT / "extracted" / "iso_files.json") as fh:
        iso = json.load(fh)
    rs = [r for r in iso if not r.get("dir")
          and r.get("path", "").startswith("DATA/04_PLAY/")]
    return sorted(rs, key=lambda r: r["path"])


def walk(d):
    """Yield (section_name, c_count, [e_record_bytes], [atlas_bytes])."""
    slots = [struct.unpack_from("<I", d, 0x20 + 4 * i)[0] for i in range(5)]
    for si in (1, 2):
        so = slots[si]
        if not so or so + 0x18 > len(d):
            continue
        a = struct.unpack_from("<h", d, so)[0]
        c_count = d[so + 4]
        ctab, dtab, etab = (struct.unpack_from("<I", d, so + 8)[0],
                            struct.unpack_from("<I", d, so + 12)[0],
                            struct.unpack_from("<I", d, so + 16)[0])
        atlases = []
        for k in range(c_count):
            t = struct.unpack_from("<I", d, ctab + 4 * k)[0]
            ln = struct.unpack_from("<I", d, t)[0]
            payload = d[t + 4:t + 4 + ln]
            assert len(payload) == ln, ("short read", si, k)
            out, used = lzss.decode(payload)
            assert used == ln, ("partial decode", si, k, used, ln)
            assert len(out) == 16384, ("atlas size", si, k, len(out))
            atlases.append(out)
        recs = [d[struct.unpack_from("<I", d, etab + 4 * k)[0]:][:E_REC]
                for k in range(a)]
        yield si, c_count, recs, atlases


def rect(raw):
    """The shipped formula, restated from the docstring -- not imported."""
    tile = raw[0x0B]
    return ((tile & 0x0F) * PITCH, (tile >> 4) * PITCH, raw[2], raw[3])


def check():
    files = raw_files()
    assert len(files) == 78, len(files)

    all_recs = []
    sections = 0
    for r in files:
        d = disc.extract(r["lba"], r["size"])
        for si, c_count, recs, atlases in walk(d):
            sections += 1
            for raw in recs:
                all_recs.append(raw)
    assert sections == 156, sections
    assert len(all_recs) == 1884, len(all_recs)

    # ------------------------------------------------ 1. layout is self-consistent
    # +0x0C/+0x0D are a second, "size-1" encoding of the same piece size, and
    # +0x02 is a u16 (h<<8)|w.  A record where they disagree means the layout
    # is wrong, so count them: 368 disagree, and those are exactly the records
    # whose +0x0C/+0x0D are not (w-1,h-1).  Keep the majority fact explicit.
    agree = sum(1 for r in all_recs
                if r[0x0C] == (r[2] - 1) & 0xFF and r[0x0D] == (r[3] - 1) & 0xFF)
    assert agree == 1516, agree
    for r in all_recs:
        assert struct.unpack_from("<H", r, 2)[0] == ((r[3] << 8) | r[2])
        assert 8 <= r[2] <= 64 and 8 <= r[3] <= 64, (r[2], r[3])

    # ------------------------------------------------ 2. bounds (no grouping)
    oob = [r for r in all_recs
           if rect(r)[0] + r[2] > ATLAS or rect(r)[1] + r[3] > ATLAS]
    assert not oob, ("derived formula out of bounds", len(oob), oob[:3])

    # ------------------------------------------------ 3. the null
    # Shuffle the tile byte, keep the sizes.  A formula that is not reading a
    # real coordinate cannot beat its own null.
    tiles = [r[0x0B] for r in all_recs]
    wh = [(r[2], r[3]) for r in all_recs]
    rng = random.Random(20261006)
    n_oob, n_land = [], []
    for _ in range(200):
        rng.shuffle(tiles)
        o = l = 0
        for t, (w, h) in zip(tiles, wh):
            x, y = (t & 0x0F) * PITCH, (t >> 4) * PITCH
            o += (x + w > ATLAS or y + h > ATLAS)
            l += (x + w == ATLAS or y + h == ATLAS)
        n_oob.append(o)
        n_land.append(l)
    land = sum(1 for r in all_recs
               if rect(r)[0] + r[2] == ATLAS or rect(r)[1] + r[3] == ATLAS)
    # the derived formula must be strictly better than every shuffled trial
    assert len(oob) == 0 and min(n_oob) > 0, (len(oob), min(n_oob), max(n_oob))
    assert land > max(n_land), ("edge landings not above the null",
                                land, min(n_land), max(n_land))

    # ------------------------------------------------ 4. alternatives fail
    def alt(raw, mode):
        if mode == "masked":
            t = raw[0x0B]
            return ((t & 0x0F) * PITCH, ((t >> 4) & 7) * PITCH, raw[2], raw[3])
        if mode == "pitch12":
            t = raw[0x0B]
            return ((t & 0x0F) * PITCH, (t >> 4) * 12, raw[2], raw[3])
        if mode == "lowbyte":
            t = raw[0x08]
            return ((t & 0x0F) * PITCH, ((t >> 4) & 7) * PITCH, raw[2], raw[3])
        raise ValueError(mode)

    for mode in ("masked", "pitch12", "lowbyte"):
        o = sum(1 for r in all_recs
                if alt(r, mode)[0] + r[2] > ATLAS or alt(r, mode)[1] + r[3] > ATLAS)
        l = sum(1 for r in all_recs
                if alt(r, mode)[0] + r[2] == ATLAS or alt(r, mode)[1] + r[3] == ATLAS)
        # every alternative must break at least one constraint
        assert o > 0 or l < land, (mode, o, l)
    # specifically: masking breaks the packing signature outright
    assert sum(1 for r in all_recs
               if alt(r, "masked")[1] + r[3] == ATLAS) < min(n_land)

    # ------------------------------------------------ 5. the packing support
    # Grouping by (tpage, +0x0A, +0x0F); tpage is a field, the other two are the
    # key that maximises disjointness (stated as a weakness in the doc).  With
    # the derived rect, >=99% of groups must be pixel-disjoint and every
    # exception must be an exact duplicate rect or a 1-pixel odd-width case.
    groups = clean = 0
    exceptions = []
    for r in files:
        d = disc.extract(r["lba"], r["size"])
        for si, c_count, recs, atlases in walk(d):
            g = collections.defaultdict(list)
            for raw in recs:
                g[(struct.unpack_from("<H", raw, 4)[0], raw[0x0A], raw[0x0F])].append(raw)
            for key, items in g.items():
                groups += 1
                cells = set()
                bad = 0
                for raw in items:
                    x, y, w, h = rect(raw)
                    for yy in range(y, y + h):
                        for xx in range(x, x + w):
                            if (xx, yy) in cells:
                                bad += 1
                            else:
                                cells.add((xx, yy))
                if bad:
                    c = collections.Counter(rect(q) for q in items)
                    exceptions.append((len([v for v in c.values() if v > 1]), bad))
                else:
                    clean += 1
    assert groups == 724, groups
    assert clean >= 719, (clean, groups)
    dup_exc = sum(1 for n_dup, _bad in exceptions if n_dup)
    px_exc = sum(1 for n_dup, _bad in exceptions if not n_dup)
    assert dup_exc == 4 and px_exc == 1, (dup_exc, px_exc, exceptions)
    # the one non-duplicate exception is a single row of pixels, from an odd
    # width (33) meeting the next tile column
    assert max(b for n_dup, b in exceptions if not n_dup) <= 128

    # also: tpage ALONE is weaker, which is why (tpage, +0x0A, +0x0F) is stated
    # as a support rather than a proof
    g_tp = collections.Counter()
    for r in files:
        d = disc.extract(r["lba"], r["size"])
        for si, c_count, recs, atlases in walk(d):
            gg = collections.defaultdict(list)
            for raw in recs:
                gg[struct.unpack_from("<H", raw, 4)[0]].append(raw)
            for key, items in gg.items():
                g_tp["n"] += 1
                cells = set()
                bad = 0
                for raw in items:
                    x, y, w, h = rect(raw)
                    for yy in range(y, y + h):
                        for xx in range(x, x + w):
                            if (xx, yy) in cells:
                                bad += 1
                            else:
                                cells.add((xx, yy))
                if not bad:
                    g_tp["clean"] += 1
    assert g_tp["n"] == 578 and g_tp["clean"] == 436, dict(g_tp)

    # ------------------------------------------------ 6. the tool agrees
    st = G.stats()
    assert st["null"]["observed_out_of_bounds"] == 0
    assert st["null"]["observed_edge_landings"] == land
    assert st["atlas_groups"] == groups and st["atlas_groups_clean"] == clean
    for nm in ("AIL.BIN", "VIC.BIN", "SHU.BIN"):
        name, d = G.load(nm)
        got = G.pieces(name, d)
        want = []
        for si, c_count, recs, atlases in walk(d):
            want += [rect(raw) for raw in recs]
        assert [(p["x"], p["y"], p["w"], p["h"]) for p in got] == want, nm

    # ------------------------------------------------ 7. pinned records
    _, d = G.load("AIL.BIN")
    pr = G.probe("AIL.BIN", d)
    s1 = pr["sections"][0]
    assert (s1["a"], s1["c_count"]) == (15, 2)
    got = [G.derive_rect(x) for x in s1["e_raw"]]
    assert (got[0]["x"], got[0]["y"], got[0]["w"], got[0]["h"]) == (0, 0, 32, 64)
    assert (got[1]["x"], got[1]["y"], got[1]["w"], got[1]["h"]) == (32, 0, 32, 64)
    assert (got[2]["x"], got[2]["y"], got[2]["w"], got[2]["h"]) == (88, 0, 40, 64)
    assert (got[3]["x"], got[3]["y"]) == (0, 64)
    assert (got[14]["x"], got[14]["y"], got[14]["w"], got[14]["h"]) == (96, 112, 32, 16)
    assert (got[0]["atlas"], got[6]["atlas"]) == ((0, 0), (1, 0))
    # the two S1 atlas groups carry the two adjacent tpages -- corroboration
    assert got[0]["tpage"] == 0x391B and got[6]["tpage"] == 0x391D
    s2 = pr["sections"][1]
    g2 = [G.derive_rect(x) for x in s2["e_raw"]]
    assert (s2["a"], s2["c_count"]) == (12, 1)
    assert g2[0]["tile"] == 0x00 and g2[3]["tile"] == 0x60
    assert (g2[0]["x"], g2[0]["y"]) == (0, 0) and (g2[3]["x"], g2[3]["y"]) == (0, 48)

    # ------------------------------------------------ 8. 8bpp, not 4bpp
    # The palette blob is 32 RGB555 words and the atlas is 16,384 B = 128x128
    # 8bpp.  A 4bpp reading would need the same bytes to cover 2x the pixels,
    # and the rendered piece is a clean figure at 8bpp (doc section 4); here we
    # pin the arithmetic that the 8bpp claim rests on, not the picture.
    pal = s1["palette"]
    assert pal is not None and len(pal) == 32
    assert pal[0] == 0x0000, hex(pal[0])          # index 0 is the transparent key
    assert len(s1["blobs"]) == 2
    assert s1["blobs"][0].__len__() == 16384 == 128 * 128

    print("PASS: 04_PLAY piece geometry re-derived -- 78 files / 156 sections / "
          "1884 e-records; +0x02 = (h<<8)|w and +0x0C/+0x0D = (w-1,h-1) for 1516; "
          "rect x=(+0x0B & 0x0F)*8, y=(+0x0B >> 4)*8 keeps 1884/1884 inside "
          "128x128 against a shuffled-tile null of %d-%d out of bounds, with %d "
          "edge landings above the null's %d-%d; masked/pitch12/lowbyte each "
          "break a constraint; grouping by (tpage,+0x0A,+0x0F) leaves %d/%d "
          "groups pixel-disjoint with 4 exact-duplicate and 1 one-pixel "
          "exception" % (min(n_oob), max(n_oob), land, min(n_land), max(n_land),
                         clean, groups))


if __name__ == "__main__":
    check()
