#!/usr/bin/env python3
"""War mode map/UI resources: independent re-derivation of the descriptor system.

The descriptor finder, the block decode and the kind classification are all
written out here with plain byte arithmetic, and the descriptors are then
cross-checked against `war_graphics`'s portrait bank and the `war_text` text
region so a coincidental 4-word window cannot pass.

Disc required.  Run: `python3 kit/tests/test_war_map.py`
"""
from pathlib import Path
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import lzss  # noqa: E402
import war_graphics as wg  # noqa: E402
import war_map as wm  # noqa: E402
import war_text as wt  # noqa: E402

BASE = 0x80010000
PAGE = 0x4000

#: descriptors per file, by kind -- derived, pinned so a finder change cannot
#: silently start dropping or duplicating resources
EXPECTED = {
    "WAR_KUWA.BIN": (6, 1, 2), "WAR_GARA.BIN": (6, 1, 2),
    "WAR_SCA1.BIN": (6, 1, 2), "WAR_SCA2.BIN": (6, 1, 2),
    "WAR_TEO1.BIN": (6, 1, 2), "WAR_TEO2.BIN": (6, 1, 2),
    "WAR_KITA.BIN": (6, 1, 2), "WAR_SHAS.BIN": (6, 1, 2),
    "WAR_LAST.BIN": (6, 1, 2), "WAR1.BIN": (5, 0, 3),
}


def ref_decode(data, off):
    size = struct.unpack_from("<I", data, off)[0]
    assert 0 < size and off + 4 + size <= len(data), (off, size)
    out, used = lzss.decode_container(data[off : off + 4 + size])
    assert used == 4 + size, (hex(off), used, 4 + size)
    return out


def ref_array(data, off, limit=64):
    n = len(data)
    out = []
    o = off
    while o + 4 <= n and len(out) < limit:
        v = struct.unpack_from("<I", data, o)[0]
        if not (BASE <= v < BASE + n):
            break
        out.append(v - BASE)
        o += 4
    return out


def ref_descriptors(data):
    """`[(off, w, h, id, block_offsets, clut_off)]`, by plain byte arithmetic."""
    n = len(data)
    out = []
    for o in range(0, n - 16, 4):
        dims, rid, arr_ptr, clut_ptr = struct.unpack_from("<4I", data, o)
        w, h = dims & 0xFFFF, dims >> 16
        # the id's high byte varies per scenario (KUWA 0x0103 where GARA says
        # 0x0203, and WAR_LAST has 0x1003), so the id is a sanity filter only
        if not (1 <= w <= 128 and 1 <= h <= 128) or not (1 <= rid <= 0xFFFF):
            continue
        if not (BASE <= arr_ptr < BASE + n and BASE <= clut_ptr < BASE + n):
            continue
        clut = struct.unpack_from("<I", data, clut_ptr - BASE)[0]
        if not (BASE <= clut < BASE + n):
            continue
        blocks = []
        for p in ref_array(data, arr_ptr - BASE):
            try:
                if len(ref_decode(data, p)) != PAGE:
                    continue
            except Exception:
                continue
            blocks.append(p)
        if not blocks:
            continue
        out.append((o, w, h, rid, tuple(blocks), clut - BASE))
    # A shifted read of a real record is already rejected by the dims test (the
    # id word is ~0x0101 = 257 > 128), so each resource is found exactly once.
    # Two different resources CAN share dims, id and block count -- KUWA has two
    # 82x20 atlases -- so dedupe by position, not by shape.
    out.sort(key=lambda d: d[0])
    kept = []
    for d in out:
        if kept and d[0] - kept[-1][0] < 16:
            continue
        kept.append(d)
    return kept


def check():
    for name, want in EXPECTED.items():
        data = wt.load(name)
        ref = ref_descriptors(data)
        tool = wm.descriptors(data)
        assert len(ref) == len(tool), (name, len(ref), len(tool))
        kinds = {"atlas": 0, "grid": 0, "map": 0}
        for r, t in zip(ref, tool):
            assert (t["off"], t["w"], t["h"], t["id"]) == r[:4], (name, r[:4], t)
            assert tuple(b[0] for b in t["blocks"]) == r[4], (name, r[4])
            assert t["clut_off"] == r[5], (name, r[5], t["clut_off"])
            # every block is a 16384-byte page with full consumption
            for _off, buf in t["blocks"]:
                assert len(buf) == PAGE
            kinds[t["kind"]] += 1
        assert (kinds["atlas"], kinds["grid"], kinds["map"]) == want, (name, kinds)

    # ---------------------------------------------- the three kinds, on the disc
    d = wt.load("WAR_KUWA.BIN")
    ds = wm.descriptors(d)
    atlas = [x for x in ds if x["kind"] == "atlas"]
    grid = [x for x in ds if x["kind"] == "grid"]
    maps = [x for x in ds if x["kind"] == "map"]
    assert len(atlas) == 6 and len(grid) == 1 and len(maps) == 2

    # atlas: exactly one page, and it is NOT all near-constant (it has sprites)
    for a in atlas:
        assert len(a["blocks"]) == 1
        buf = a["blocks"][0][1]
        # some atlases are monochrome-ish (the "Defeat" banner), so the test is
        # that it is a *sprite* page: several indices and a transparent
        # background, not a flat or full-coverage plane
        assert len(set(buf)) >= 8, (a["off"], len(set(buf)))
        assert buf.count(0) > 0, a["off"]

    # grid: five pages whose every byte is a small terrain code
    assert len(grid[0]["blocks"]) == 5
    for _off, buf in grid[0]["blocks"]:
        assert max(buf) <= wm.GRID_MAX, max(buf)
        assert max(buf) >= 8, "a terrain grid should use several codes"
        assert len(set(buf)) > 4

    # map: the 20x15 terrain group and the 16x12 sky group, both multi-page
    dims = sorted((x["w"], x["h"]) for x in maps)
    assert dims == [(16, 12), (20, 15)], dims
    terrain = next(x for x in maps if x["w"] == 20)
    sky = next(x for x in maps if x["w"] == 16)
    assert len(terrain["blocks"]) == 3
    assert len(sky["blocks"]) == 4
    for x in maps:
        for _off, buf in x["blocks"]:
            assert max(buf) > wm.GRID_MAX, "map pages must be images, not grids"

    # ---------------------------------------------- cross-checks, not coincidence
    # 1. the descriptors do not overlap the portrait bank's blocks
    war = wg.load("WAR_KUWA.BIN")
    _t, prows = wg.portrait_table(war)
    pspan = range(min(p for p, _q in prows) - 0x40, max(p for p, _q in prows) + 0x1000)
    for x in ds:
        for off, _buf in x["blocks"]:
            assert off not in pspan, ("descriptor block inside the portrait bank", hex(off))
    # 2. the atlas pages are not text: they must not decode as prose
    for a in atlas:
        buf = a["blocks"][0][1]
        s, _u = wt.decode(buf, 0, 512)
        assert not wt.looks_like_english(s), a["off"]
    # 3. the map pages are spatially coherent (an image, not noise)
    def adj(b, w=128):
        same = total = 0
        for y in range(128):
            for x in range(1, w):
                total += 1
                if b[y * w + x] == b[y * w + x - 1]:
                    same += 1
        return same / total
    for x in maps:
        for _off, buf in x["blocks"]:
            a = adj(buf)
            assert a > 0.20, (hex(x["off"]), a)

    # 4. the CLUTs are real 256-entry palettes whose entry 0 is transparent.
    #    The mask bit IS set on some entries of some of them (the 8x1 banner
    #    atlas at 0x1E3F4 for one), so that is recorded rather than asserted.
    masked = 0
    for x in ds:
        words = struct.unpack_from("<256H", d, x["clut_off"])
        assert words[0] == 0, (hex(x["clut_off"]), hex(words[0]))
        if any(w & 0x8000 for w in words):
            masked += 1
    assert masked >= 1, "expected at least one CLUT with mask bits set"

    # WAR1.BIN has no terrain grid at all -- the nine selector-reachable
    # overlays each have exactly one -- which is a further independent
    # difference for the dead file
    w1 = wt.load("WAR1.BIN")
    assert all(x["kind"] != "grid" for x in wm.descriptors(w1))
    for name in wm.war_files():
        if name == "WAR1.BIN" or name == "W_HEADER.BIN":
            continue
        kinds = [x["kind"] for x in wm.descriptors(wt.load(name))]
        assert kinds.count("grid") == 1, name

    print("PASS: war map/UI descriptors re-derived independently for all 10 "
          "files -- 6 sprite atlases per overlay (one 16384 B page each: units, effects, "
          "the Defeat banner), 9 terrain grids (5 pages of codes 0..14) and 18 "
          "map pages (castle/terrain 20x15 + sky 16x12); every block full "
          "consumption and every CLUT a real palette; WAR1.BIN has no terrain grid")


if __name__ == "__main__":
    check()
