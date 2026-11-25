#!/usr/bin/env python3
"""Tests for kit/tools/vram_residency.py -- the disc-wide VRAM residency map.

    1. the slot packing round-trips: a synthetic 128x128 index plane packed as
       lo/hi word pairs comes back byte-identical from `slot_plane`, and the
       *wrong* reading (low bytes = left half) does not reproduce it;
    2. the slot grid is the legal PSX texpage grid: x at every multiple of 32
       words, y at every row, 11,935 slots, and the two misreadings of the 14
       known slots match nothing;
    3. the capture is the only 1 MiB file in the tree (no second VRAM capture);
    4. all 2,006 pool atlases re-decode from their (file, offset) to exactly the
       manifest SHA-1 -- the pool manifest is not trusted;
    5. the container-only match set reproduces `battle_vram_residency.md`
       exactly: 14 slots (this is the regression anchor for the packing);
    6. every one of the 25 byte-exact slots really does equal its atlas, and the
       one container blob checked by an *independent* path (parse_04play) agrees;
    7. only the all-zero atlas produces degenerate blank-slot hits, and those
       hits are blank planes -- never counted as residency;
    8. the container atlases (234 distinct) are a subset of the pool;
    9. the party layout, with the corrections the extended scan forces: CRE,
       KAM, TAI and VIC contribute S1.c0 + S1.c1 + S2.c0; SHU and GRE contribute
       only S2.c0;
   10. the unexplained index-plane-looking windows are 4bpp nibble-structured
       data (byte set {0,1,16,17}), not 8-bit sprite planes, and 1,154 other
       such windows have no unexplained non-zero pixel at all;
   11. the capture's left band (x=0..319 words) is not an index plane at all:
       >90% of its bytes are >31 (dense direct-colour image data).

Static analysis only; disc read through kit/tools/disc.py. No emulator, no new
capture. The capture is a measuring instrument and its pixels are never promoted.

    .venv/bin/python kit/tests/test_vram_residency.py
"""

import hashlib
import json
import os
import sys
import tempfile

import numpy as np

TOOLS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
sys.path.insert(0, TOOLS)

import disc                                    # noqa: E402
import lzss                                    # noqa: E402
import overlay_sprites as ov                   # noqa: E402
import vram_residency as vr                    # noqa: E402
from parse_04play import parse_04play           # noqa: E402

# The 14 slots recorded by docs/battle_vram_residency.md (an
# independent source: this list is not recomputed from the tool).
PRIOR_14 = [(320, 256), (384, 256), (448, 128), (448, 256), (512, 128),
            (512, 256), (576, 128), (576, 256), (640, 256), (640, 384),
            (704, 256), (768, 256), (832, 256), (896, 256)]

_CACHE = {}


def _iso():
    return vr.iso_index()


def _fetch(path):
    if path not in _CACHE:
        rec = _iso()[path]
        _CACHE[path] = disc.extract(rec["lba"], rec["size"])
    return _CACHE[path]


def _vram():
    if "vram" not in _CACHE:
        _CACHE["vram"] = vr.load_vram()
    return _CACHE["vram"]


def _index():
    if "index" not in _CACHE:
        pool, _man = vr.load_pool()
        index, problems = vr.decode_pool(pool, _fetch)
        _CACHE["index"], _CACHE["problems"], _CACHE["pool"] = index, problems, pool
    return _CACHE["index"]


def _report():
    if "report" not in _CACHE:
        _CACHE["report"] = vr.analyse(root=vr.os.path.dirname(vr._KIT))
    return _CACHE["report"]


# --------------------------------------------------------------------------

def test_slot_plane_packing_round_trip():
    """Pack a synthetic plane the way the hardware stores it; read it back."""
    rng = np.random.RandomState(7)
    plane = rng.randint(0, 32, size=(128, 128)).astype(np.uint8)
    vram = np.zeros((vr.VRAM_H, vr.VRAM_W), dtype="<u2")
    x, y = 96, 40
    lo = plane[:, 0::2].astype("uint16")
    hi = plane[:, 1::2].astype("uint16")
    vram[y:y + 128, x:x + 64] = lo | (hi << 8)
    assert vr.slot_plane(vram, x, y) == plane.tobytes()
    # shifting by one word is a different plane (no accidental invariance here)
    assert vr.slot_plane(vram, x + 1, y) != plane.tobytes()
    # the wrong reading (low bytes only = left half) is NOT the plane
    low_half = vram.view(np.uint8).reshape(vr.VRAM_H, 2 * vr.VRAM_W)[y:y + 128,
                                                                    0::2][:, x:x + 64]
    assert low_half.tobytes() != plane.tobytes()


def test_slot_grid_is_the_texpage_grid():
    vram = _vram()
    slots = list(vr.enumerate_slots(vram))
    n_x = (vr.VRAM_W - vr.SLOT_WORDS) // vr.X_STEP_WORDS + 1
    n_y = vr.VRAM_H - vr.SLOT_ROWS + 1
    assert len(slots) == n_x * n_y == 31 * 385 == 11935
    xs = sorted({x for x, _y in slots})
    assert xs == list(range(0, 961, 32)), xs[:5]        # legal texpage bases
    ys = sorted({y for _x, y in slots})
    assert ys[0] == 0 and ys[-1] == 384 and len(ys) == 385
    assert max(x for x, _ in slots) + vr.SLOT_WORDS == vr.VRAM_W


def test_the_misreadings_of_the_14_known_slots_match_nothing():
    """The trap, pinned down: the low-half reading of the known slots is not
    any atlas. (The interleaved reading is what reproduces them.)"""
    vram, index = _vram(), _index()
    idx = vram.view(np.uint8).reshape(vr.VRAM_H, 2 * vr.VRAM_W)
    for x, y in PRIOR_14:
        low_half = idx[y:y + 128, 0::2][:, x:x + 64].tobytes()
        assert hashlib.sha1(low_half).hexdigest() not in index, (x, y)


def test_capture_is_the_only_1mib_file_in_the_tree():
    caps = vr.find_vram_captures(vr.os.path.dirname(vr._KIT))
    assert [r["path"] for r in caps["exact_1MiB"]] == ["kit/work/cache/oracles/vram_raw.bin"]
    # nothing else in the tree is even shaped like a second capture
    assert all(r["size"] == vr.VRAM_BYTES for r in caps["exact_1MiB"])


def test_capture_alias_is_not_an_additional_capture():
    with tempfile.TemporaryDirectory() as root:
        physical = os.path.join(root, "vram_raw.bin")
        with open(physical, "wb") as f:
            f.truncate(vr.VRAM_BYTES)
        os.symlink("vram_raw.bin", os.path.join(root, "old_vram.bin"))
        caps = vr.find_vram_captures(root)
        assert caps["exact_1MiB"] == [{"path": "vram_raw.bin", "size": vr.VRAM_BYTES}]
        assert len(caps["named"]) == 1


def test_pool_redecodes_byte_exact():
    index, problems, pool = _index(), _CACHE["problems"], _CACHE["pool"]
    assert len(pool) == 2006 and len(index) == 2006
    assert problems == [], problems[:3]
    for sha1, rec in index.items():
        assert len(rec["plane"]) == vr.ATLAS_BYTES
        assert hashlib.sha1(rec["plane"]).hexdigest() == sha1


def test_container_only_match_set_reproduces_the_prior_14():
    sources, stats = vr.container_sources(_fetch)
    # 78 DATA/04_PLAY containers always; the 35 embedded ones need the recorded
    # overlay manifest (kit/work/overlay_sprites/manifest.json). 234 distinct
    # atlases either way; 339 atlas streams when the embedded set is present.
    assert stats["containers"] in (78, 113) and not stats["errors"]
    assert stats["atlases"] == (339 if stats["containers"] == 113 else 234)
    assert len(sources) == 234
    index = {h: _index()[h] for h in sources if h in _index()}
    matches, degen = vr.scan_slots(_vram(), index)
    assert sorted((h["x"], h["y"]) for h in matches) == sorted(PRIOR_14)
    assert degen == []


def test_every_match_is_byte_exact_and_the_packing_agrees_off_tool():
    vram, index = _vram(), _index()
    matches, degen = vr.scan_slots(vram, index)
    assert len(matches) == 25 and len({h["sha1"] for h in matches}) == 25
    for hit in matches:
        plane = vr.slot_plane(vram, hit["x"], hit["y"])
        assert plane == index[hit["sha1"]]["plane"]      # byte equality
        assert len(plane) == 16384
    # independent path: parse CRE.BIN with parse_04play and check S1.c1
    data = _fetch("DATA/04_PLAY/CRE.BIN")
    fd, tmp = tempfile.mkstemp(suffix=".bin")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        parsed = parse_04play(tmp)
    finally:
        os.unlink(tmp)
    assert not parsed["validation"]["errors"]
    ent = parsed["sections"]["S1"]["c"]["entries"][1]
    blob = ent["blob"]
    raw = lzss.decode_strict(data[blob["data_file_offset"]:
                                  blob["data_file_offset"] + blob["data_len"]])
    assert raw == vr.slot_plane(vram, 320, 256)


def test_only_the_blank_atlas_is_degenerate_and_its_hits_are_blank():
    vram, index = _vram(), _index()
    constant = [h for h, r in index.items() if vr.is_constant(r["plane"])]
    assert len(constant) == 1
    rec = index[constant[0]]
    assert rec["plane"] == bytes(16384)                  # all-zero plane
    assert rec["first_file"] == "DATA/06_AREA.C/VC1.BIN"
    matches, degen = vr.scan_slots(vram, index)
    assert len(degen) == 324
    assert constant[0] not in {h["sha1"] for h in matches}
    for hit in degen:
        assert set(vr.slot_plane(vram, hit["x"], hit["y"])) == {0}


def test_container_atlases_are_a_subset_of_the_pool():
    sources, _stats = vr.container_sources(_fetch)
    index = _index()
    assert not (set(sources) - set(index))
    assert len(set(sources)) == 234


def test_party_layout_with_the_measured_corrections():
    """Slot -> blob. CRE/KAM/TAI/VIC supply S1.c0+S1.c1+S2.c0; SHU and GRE
    supply S2.c0 only (their S1 sheets are NOT resident in this capture)."""
    sources, _stats = vr.container_sources(_fetch)
    expected = {
        ("CRE.BIN", "S1", 0): (576, 128), ("CRE.BIN", "S1", 1): (320, 256),
        ("CRE.BIN", "S2", 0): (832, 256),
        ("KAM.BIN", "S1", 0): (384, 256), ("KAM.BIN", "S1", 1): (448, 256),
        ("KAM.BIN", "S2", 0): (896, 256),
        ("TAI.BIN", "S1", 0): (512, 256), ("TAI.BIN", "S1", 1): (576, 256),
        ("TAI.BIN", "S2", 0): (640, 384),
        ("VIC.BIN", "S1", 0): (448, 128), ("VIC.BIN", "S1", 1): (512, 128),
        ("VIC.BIN", "S2", 0): (768, 256),
        ("SHU.BIN", "S2", 0): (640, 256),
        ("GRE.BIN", "S2", 0): (704, 256),
    }
    index = _index()
    conn = {}
    for sha1, srcs in sources.items():
        for s in srcs:
            conn[(os.path.basename(s["file"]), s["section"], s["blob"])] = sha1
    for key, slot in expected.items():
        assert key in conn, key
        vram = _vram()
        assert vr.slot_plane(vram, *slot) == index[conn[key]]["plane"], key
    # the non-resident sheets are genuinely absent from every slot
    resident = {h["sha1"] for h in vr.scan_slots(_vram(), index)[0]}
    for key in (("SHU.BIN", "S1", 0), ("SHU.BIN", "S1", 1),
                ("GRE.BIN", "S1", 0), ("GRE.BIN", "S1", 1)):
        assert conn[key] not in resident, key


def test_unexplained_windows_are_4bpp_text_not_sprite_planes():
    rep = _report()
    u = rep["unexplained"]
    ip = u["index_planes"]
    bad = [r for r in ip if r["unexplained_pixels"] > 0]
    assert len(ip) == 1234
    assert len(bad) == 80
    assert max(r["unexplained_pixels"] for r in bad) == 597
    # every one of the 80 lives in the same 4bpp text/logo region ...
    assert {r["x"] for r in bad} == {640, 768}
    assert min(r["y"] for r in bad) == 45 and max(r["y"] for r in bad) == 93
    # ... and has a byte set inside the two-level 4bpp signature {0,1,16,17}
    for r in bad:
        assert set(r["nibble_closure"]["byte_values"]) <= {0, 1, 16, 17}, r
    assert sum(1 for r in bad if r["nibble_closure"]["is_nibble_closure"]) == 79
    # the other 1,154 have no unexplained non-zero pixel at all
    assert len(ip) - len(bad) == 1154
    assert all(r["unexplained_pixels"] == 0 for r in ip if r not in bad)


def test_left_band_is_direct_colour_not_an_index_plane():
    vram = _vram()
    for x in (0, 64, 128, 192, 256):
        s = vr.plane_stats(vr.slot_plane(vram, x, 0))
        assert s["bytes_over_31"] > 0.85 * 16384, (x, s)
        assert s["class"] == "tile-like", (x, s)
    # and it is therefore not reported as an unexplained index plane
    rep = _report()
    assert not any(r["x"] < 320 and r["unexplained_pixels"] >= 0
                   for r in rep["unexplained"]["index_planes"])
    # the matched party sheet IS a 32-colour index plane
    s = vr.plane_stats(vr.slot_plane(vram, 320, 256))
    assert s["bytes_over_31"] == 0 and s["max_byte"] <= 31
    assert s["class"] == "sprite-like"


if __name__ == "__main__":
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
        except Exception as ex:            # noqa: BLE001 - report all
            failed += 1
            print("FAIL %s: %s: %s" % (name, type(ex).__name__, ex))
        else:
            print("ok   %s" % name)
    print("\n%d passed, %d failed" % (len(tests) - failed, failed))
    sys.exit(1 if failed else 0)
