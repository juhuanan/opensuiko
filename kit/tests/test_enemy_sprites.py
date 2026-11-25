#!/usr/bin/env python3
"""Tests for kit/tools/enemy_sprites.py -- the per-area enemy sprite sections.

    1. every `DATA/*/*_DATA.BIN` parses to its recorded section count, and the
       total is 88 (a framing or signature regression changes either);
    2. every section's every c-blob decodes to exactly 16,384 bytes;
    3. every section has at least one usable 32-word d-table palette, and
       `d_count` equals `d_flags & 0x3F`;
    4. every atlas index used is inside the palette, so the renderer cannot
       silently drop pixels (this is what makes the sheets disc-derived);
    5. `find_sections` is not fooled by the *battle background* descriptor that
       shares the file: the descriptor at word 0 is a 160x120 image, not a
       sprite section, and must not appear in the section list;
    6. two independent readings agree on the enemy count path: the sections
       found by header signature and the sprite-like atlases the disc-wide pool
       scan found in the same files are consistent (no section references an
       atlas the pool scan could not see).

Static analysis only; the disc is read through kit/tools/disc.py.

    .venv/bin/python kit/tests/test_enemy_sprites.py
"""

import json
import os
import struct
import sys

TOOLS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
sys.path.insert(0, TOOLS)

import disc                                    # noqa: E402
import enemy_sprites as es                     # noqa: E402

_ISO = os.path.join(os.path.dirname(TOOLS), "extracted", "iso_files.json")
_CACHE = {}


def parsed(path):
    if path not in _CACHE:
        with open(_ISO) as f:
            rec = [r for r in json.load(f) if r.get("path") == path][0]
        d = disc.extract(rec["lba"], rec["size"])
        _CACHE[path] = (d, es.parse_sections(d)[0])
    return _CACHE[path]


def test_section_counts_match_the_record():
    seen = {}
    for r in es.area_files():
        _d, secs = parsed(r["path"])
        seen[r["path"]] = len(secs)
    for path, want in es.EXPECTED_SECTIONS.items():
        assert seen.get(path) == want, (path, seen.get(path), want)
    total = sum(seen.values())
    assert total == es.EXPECTED_TOTAL, (total, es.EXPECTED_TOTAL)


def test_every_atlas_is_16384_bytes():
    for r in es.area_files():
        _d, secs = parsed(r["path"])
        for s in secs:
            assert s["atlases"], (r["path"], hex(s["header_offset"]))
            for a in s["atlases"]:
                assert len(a["atlas"]) == es.ATLAS, (r["path"], a["offset"])


def test_palette_tables_are_consistent():
    for r in es.area_files():
        _d, secs = parsed(r["path"])
        for s in secs:
            assert s["d_count"] == (int(s["d_flags"], 16) & 0x3F)
            assert s["d_count"] >= 1, (r["path"], hex(s["header_offset"]))
            usable = [p for p in s["palettes"] if p is not None]
            assert usable, (r["path"], hex(s["header_offset"]))
            for p in usable:
                assert len(p) == 32
                assert any(p), "all-zero palette"


def test_every_index_is_inside_the_palette():
    for r in es.area_files():
        _d, secs = parsed(r["path"])
        for s in secs:
            for i, a in enumerate(s["atlases"]):
                pal = s["palettes"][min(i, len(s["palettes"]) - 1)]
                assert pal is not None
                assert max(a["atlas"]) < len(pal), (
                    r["path"], hex(s["header_offset"]), i, max(a["atlas"]))


def test_the_battle_background_descriptor_is_not_a_section():
    """Word 0 of every area data file is a 160x120 image descriptor.

    It must not be mistaken for an enemy section: it has no c-table of
    atlases. Assert the descriptor is present AND absent from the sections.
    """
    for r in es.area_files():
        d, secs = parsed(r["path"])
        n = len(d)
        w0 = struct.unpack_from("<I", d, 0)[0]
        assert es.LOAD_BASE <= w0 < es.LOAD_BASE + n, r["path"]
        o0 = w0 - es.LOAD_BASE
        s_ptr = struct.unpack_from("<I", d, o0)[0]
        s_off = s_ptr - es.LOAD_BASE
        w, h = struct.unpack_from("<HH", d, s_off)
        assert (w, h) == (160, 120), (r["path"], w, h)
        assert all(sec["header_offset"] != o0 for sec in secs)
        assert all(sec["header_offset"] != s_off for sec in secs)


def test_pool_scan_agrees_the_atlases_exist():
    """Second, unrelated reading: the disc-wide pool found these atlases.

    Membership is by atlas SHA-1, not by (file, offset): the pool manifest
    records each distinct atlas ONCE, at its first occurrence, so a section may
    legitimately reference an atlas whose recorded first location is another
    file (B_DATA.BIN does exactly that).
    """
    import hashlib
    man_path = os.path.join(os.path.dirname(TOOLS), "work", "atlas_pool",
                            "manifest.json")
    if not os.path.exists(man_path):
        print("   (skipped: kit/work/atlas_pool/manifest.json absent)")
        return
    with open(man_path) as f:
        man = json.load(f)
    pool = {a["sha1"] for a in man["atlases"]}
    checked = 0
    for r in es.area_files():
        _d, secs = parsed(r["path"])
        for s in secs:
            for a in s["atlases"]:
                h = hashlib.sha1(a["atlas"]).hexdigest()
                assert h in pool, (r["path"], hex(a["offset"]), h)
                checked += 1
    assert checked > 100, checked


def test_enemy_tables_resolve_to_sections():
    """Each area's roster table: count, then records whose +0x2C is a section."""
    found = {}
    for r in es.area_files():
        d, secs = parsed(r["path"])
        tabs = es.find_enemy_tables(d, secs)
        if tabs:
            assert len(tabs) == 1, (r["path"], len(tabs))
            found[r["path"]] = (tabs[0]["table_offset"], tabs[0]["count"])
            for t in tabs:
                assert t["count"] == len(set(t["section_offsets"]))
                for ro in t["record_offsets"]:
                    assert ro + 0x30 <= len(d)
                for so in t["section_offsets"]:
                    assert any(x["header_offset"] == so for x in secs)
    for path, want in es.EXPECTED_TABLES.items():
        assert found.get(path) == want, (path, found.get(path), want)
    # every area data file except the stub and J_DATA.BIN has a roster
    missing = [r["path"] for r in es.area_files()
               if r["path"] not in found and not r["path"].endswith("J_DATA.BIN")]
    assert missing == [], missing


def test_battle_background_descriptor_is_parseable():
    """The 160x120 descriptor at word 0 yields 5 terrain pages and 3 CLUTs."""
    for r in es.area_files():
        d, _secs = parsed(r["path"])
        bg = es.parse_background(d)
        assert bg is not None, r["path"]
        assert (bg["w"], bg["h"]) == (160, 120), (r["path"], bg["w"], bg["h"])
        assert len(bg["pages"]) == 5, (r["path"], len(bg["pages"]))
        assert len(bg["cluts"]) == 3, (r["path"], len(bg["cluts"]))
        for p in bg["pages"]:
            assert len(p["atlas"]) == es.ATLAS
        for c in bg["cluts"]:
            assert len(c["words"]) == 256
        # only CLUT 0 colours the pages: record that CLUT 1/2 are not it
        w0 = bg["cluts"][0]["words"]
        w1 = bg["cluts"][1]["words"]
        assert w0 != w1

def test_multi_palette_sections_exist_and_are_recolours():
    """d_count > c_count means one atlas drawn in several palettes.

    Area E has a 14-palette scenery section (h1c674, absent from the roster)
    and a 3-palette small-enemy section (h28328). Asserting both keeps the
    "count section x palette, not section" claim honest.
    """
    d, secs = parsed("DATA/08_AREA.E/E_DATA.BIN")
    multi = [s for s in secs if len(s["palettes"]) > 1]
    assert len(multi) == 2, [hex(s["header_offset"]) for s in multi]
    counts = {s["header_offset"]: len(s["palettes"]) for s in multi}
    assert counts.get(0x1C674) == 14, counts
    assert counts.get(0x28328) == 3, counts
    tables = es.find_enemy_tables(d, secs)
    roster = set(tables[0]["section_offsets"])
    # the 14-palette one is scenery, not a roster enemy
    assert 0x1C674 not in roster, sorted(hex(x) for x in roster)
    # the 3-palette one is not in the roster either (it is the small-enemy set,
    # reached from its own table) -- record that rather than assume
    assert 0x28328 not in roster

def test_only_clut0_is_a_plausible_worldmap_palette():
    """Two-factor test, because a one-factor one gives the WRONG answer.

    (Renamed from ..._terrain_palette: the user identified this art as the
    WORLD MAP, not a battle terrain -- docs/world_map.md.)

    A palette is plausible for index art when it (a) does not collapse -- it
    maps the indices to many distinct colours -- AND (b) keeps neighbours that
    differ in INDEX close in RGB. Measured on area E (and the same shape holds
    for A and H):

        CLUT0  243 distinct words,   2/256 grey  -> the world-map art palette
        CLUT1   23 distinct words, 236/256 grey, 253/255 non-decreasing red
                                                 -> a 23-level GREY RAMP
        CLUT2  256 distinct words,   9/256 grey  -> a second full palette

    CLUT1's flatness is therefore not a defect: it is a ramp, i.e. a different
    KIND of palette (shading/mask), not a broken terrain palette.

    A naive mean-|left-right| over ALL pixel pairs ranks CLUT1 best, because a
    mostly-black palette is flat. That is the trap this test pins down.
    """
    import numpy as np
    d, _secs = parsed("DATA/08_AREA.E/E_DATA.BIN")
    bg = es.parse_background(d)
    assert len(bg["cluts"]) == 3
    stats = []
    for cl in bg["cluts"]:
        pal = np.array([es.rgb555(w) for w in cl["words"]], int)
        cols, diffs = [], []
        for page in bg["pages"]:
            a = np.frombuffer(page["atlas"], np.uint8).reshape(128, 128)
            img = pal[a]
            cols.append(len(set(map(tuple, img.reshape(-1, 3)))))
            m = a[:, 1:] != a[:, :-1]
            dd = np.abs(img[:, 1:] - img[:, :-1]).mean(axis=2)
            diffs.append(float(dd[m].mean()))
        stats.append((min(cols), sum(diffs) / len(diffs)))
    do_not_collapse, neighbour = 0, 1
    assert stats[0][do_not_collapse] > 150, stats          # CLUT0 is full
    assert stats[0][neighbour] < 45, stats                 # and coherent
    assert stats[1][do_not_collapse] < 40, stats           # CLUT1 is sparse
    assert stats[2][neighbour] > 50, stats                 # CLUT2 is not a ramp
    # the mechanism: CLUT1 is a grey ramp, CLUT2 is not
    def greys(cl):
        cols = [es.rgb555(w) for w in cl["words"]]
        return sum(1 for (r, g, b) in cols if r == g == b)
    assert greys(bg["cluts"][1]) > 200, greys(bg["cluts"][1])
    assert greys(bg["cluts"][0]) < 20, greys(bg["cluts"][0])
    assert greys(bg["cluts"][2]) < 20, greys(bg["cluts"][2])
    # the three CLUTs are global: another area has the same word counts
    d2, _s2 = parsed("DATA/15_AREA.Z/Z_DATA.BIN")
    bg2 = es.parse_background(d2)
    assert [len(set(c["words"])) for c in bg2["cluts"]] == \
           [len(set(c["words"])) for c in bg["cluts"]], "CLUTs should be global"
    # and the one-factor metric really is misleading
    assert stats[1][neighbour] < stats[0][neighbour] < stats[2][neighbour]

def test_two_bit_texture_unpack_matches_the_engine_order():
    """`0x800C3958` walks input and output BACKWARD, low 2 bits first.

    Asserting the order matters because the wrong order still gives a coherent
    image (it is a mirror), so a mistake is invisible to the eye.
    """
    payload = bytes([0b11100100, 0b00011011])      # 2 bytes -> 8 pixels
    got = es.unpack_2bit(payload, out_size=8)
    assert got is not None
    # last input byte 0b00011011 -> pixels 4..7 written backward:
    #   out[7]=0b11, out[6]=0b10, out[5]=0b01, out[4]=0b00
    # first input byte 0b11100100 -> out[3]=0b00, out[2]=0b01, out[1]=0b10, out[0]=0b11
    assert list(got) == [3, 2, 1, 0, 0, 1, 2, 3], list(got)
    assert es.unpack_2bit(b"\x00" * 3, out_size=8) is None


def test_every_area_has_a_two_bit_texture():
    for r in es.area_files():
        d, _secs = parsed(r["path"])
        tb = es.parse_twobit_texture(d)
        assert tb is not None, r["path"]
        off, px = tb
        assert len(px) == 16384
        assert set(px) <= {0, 1, 2, 3}

def test_world_map_image_parses_to_w_times_h_times_2():
    """The 160x120 dual-palette world-map image at S+0x14.

    User-identified as the WORLD MAP (docs/world_map.md). Asserting
    w*h*2 bytes and a high byte restricted to {0,1} keeps the 9-bit reading
    honest -- if either fails, this is not the image this doc describes.
    """
    for r in es.area_files():
        d, _secs = parsed(r["path"])
        wm = es.parse_worldmap(d)
        assert wm is not None, r["path"]
        assert (wm["w"], wm["h"]) == (160, 120), (r["path"], wm["w"], wm["h"])
        assert len(wm["indices"]) == 19200
        assert len(wm["flags"]) == 19200
        assert set(wm["flags"]) <= {0, 1}, (r["path"], sorted(set(wm["flags"])))
        assert wm["cluts"], r["path"]

def test_fresh_output_contains_current_footprint_metadata():
    import contextlib
    import io
    from pathlib import Path
    import tempfile
    from unittest.mock import patch
    source=es.area_files()[0]
    with tempfile.TemporaryDirectory(prefix='suikoden-enemy-output-') as tmp:
        output=Path(tmp)/'new'
        with patch.object(es,'area_files',return_value=[source]),contextlib.redirect_stdout(io.StringIO()):
            assert es.main(['--out',str(output)])==0
        manifest=json.loads((output/'manifest.json').read_text())
        assert manifest['tool']==es.PARSER_ID
        entry,=manifest['files'];assert entry['path']==source['path']
        assert entry['strongest'] and all('formation_footprint' in r and 'variant' not in r for r in entry['strongest'])
        tag=source['path'].split('/')[1]
        assert (output/tag/('worldmap_%06x.png'%entry['worldmap']['offset'])).is_file()


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
