#!/usr/bin/env python3
"""Tests for the battle asset decoders (BATTLE.BIN + embedded sprite containers).

    1. BATTLE.BIN parses with no structural error: 8 sections, each with an
       in-file c-table;
    2. the c-tables yield exactly the 13 recorded atlas offsets, in the two
       recorded groups -- section 0's 3 and the shared pool of 10;
    3. `d_flags` and the pixel data AGREE independently: section 0 is
       c_count=3 / d_flags=0x83 and its 3 planes have max index < 64, while
       sections 1-7 are c_count=10 / d_flags=0x00 and their 10 planes reach
       index 255. Two unrelated readings of the same fact;
    4. section 0's 3 d-table palettes are 32-word RGB555 blocks inside the
       file, and the 256-colour sections have no d-table at all -- the precise
       reason only 3 planes render with disc-derived colour;
    5. no 256-word RGB555 palette exists anywhere in BATTLE.BIN (so the
       10 effect planes' colour genuinely is not in this file);
    6. every atlas is exactly 16,384 bytes and re-decodes identically from its
       recorded `[u32 len]` framing (strict mode rejects trailing input);
    7. the embedded 04_PLAY-container scan finds exactly 113 containers with
       the recorded 78-at-DATA/04_PLAY / 35-embedded split;
    8. a container lifted out of an overlay parses with the canonical parser
       and decodes 3 x 16384 bytes -- the property `overlay_sprites` rests on.

Static analysis only; no emulator, no new VRAM capture. The disc is read
through kit/tools/disc.py.

    .venv/bin/python kit/tests/test_battle_bin.py
"""

import json
import os
import struct
import sys

TOOLS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
sys.path.insert(0, TOOLS)

import disc                                            # noqa: E402
import lzss                                            # noqa: E402
import battle_bin as bb                                # noqa: E402
import overlay_sprites as osp                          # noqa: E402

_ROOT = os.path.dirname(TOOLS)
_ISO_JSON = os.path.join(_ROOT, "extracted", "iso_files.json")

_CACHE = {}


def parsed():
    if "p" not in _CACHE:
        _CACHE["p"] = bb.parse()
    return _CACHE["p"]


def battle_data():
    if "d" not in _CACHE:
        lba, size = bb.battle_bin_lba()
        _CACHE["d"] = disc.extract(lba, size)
    return _CACHE["d"]


def iso_files():
    if "f" not in _CACHE:
        with open(_ISO_JSON) as f:
            _CACHE["f"] = [r for r in json.load(f) if not r.get("dir")]
    return _CACHE["f"]


def test_structure_parses_clean():
    sections, atlases, errors, data = parsed()
    assert errors == [], errors
    assert len(sections) == bb.EXPECTED_SECTIONS
    for s in sections:
        assert s["tables"]["c"] is not None, s
        assert s["c_count"] > 0


def test_atlas_offsets_are_stable_and_grouped():
    sections, atlases, _e, _d = parsed()
    assert len(atlases) == bb.EXPECTED_ATLASES
    assert sections[0]["atlas_offsets"] == [0x0B7C, 0x1600, 0x228C]
    assert sections[0]["c_count"] == bb.EXPECTED_SECTION0["c_count"]
    assert sections[0]["d_flags"] == "0x%02x" % bb.EXPECTED_SECTION0["d_flags"]
    shared = [0x4644, 0x65E8, 0x802C, 0x9ACC, 0xB730,
              0xDAC0, 0xEE34, 0x11540, 0x121DC, 0x1429C]
    for s in sections[1:]:
        assert s["c_count"] == 10
        assert s["atlas_offsets"] == shared, s["index"]
    # the 13 records are the union, in file order
    assert [a["offset"] for a in atlases] == [0x0B7C, 0x1600, 0x228C] + shared


def test_d_flags_and_pixels_agree_independently():
    sections, atlases, _e, _d = parsed()
    by_off = {a["offset"]: a for a in atlases}
    for off in sections[0]["atlas_offsets"]:
        path, hi, _n = bb.classify(by_off[off]["atlas"])
        assert path == "32-colour" and hi < 64, (hex(off), path, hi)
    for s in sections[1:]:
        assert s["palette_path"] == "256-color"
        for off in s["atlas_offsets"]:
            path, hi, _n = bb.classify(by_off[off]["atlas"])
            assert path == "256-colour" and hi == 255, (hex(off), path, hi)


def test_only_the_32_colour_section_has_on_disc_palettes():
    sections, atlases, _e, data = parsed()
    assert sections[0]["palette_offsets"] == [0x20, 0x60, 0xA0]
    for s in sections[1:]:
        assert s["tables"]["d"] is None
        assert s["palette_offsets"] == []
    # each palette really is a 32-word RGB555 block inside the file
    for po in sections[0]["palette_offsets"]:
        words = struct.unpack_from("<32H", data, po)
        assert any(w != 0 for w in words)
    three = [a for a in atlases if a.get("palette") is not None]
    assert len(three) == 3
    for a in three:
        assert a["palette_offset"] in (0x20, 0x60, 0xA0)


def test_no_256_word_rgb555_palette_exists():
    """The documented negative: the 10 effect planes' colour is not in the file."""
    d = battle_data()
    size = 256 * 2
    for off in range(0, len(d) - size + 1, 2):
        w = struct.unpack_from("<256H", d, off)
        if all(x != 0 and not (x & 0x8000) for x in w):
            raise AssertionError("256-word RGB555 palette at %#x" % off)


def test_every_atlas_is_16384_bytes_and_reframes_exactly():
    _s, atlases, _e, data = parsed()
    for a in atlases:
        assert len(a["atlas"]) == bb.ATLAS_BYTES
        raw = lzss.decode_strict(
            data[a["offset"] + 4:a["offset"] + 4 + a["compressed_len"]])
        assert raw == a["atlas"], hex(a["offset"])


def test_embedded_container_scan_matches_the_recorded_split():
    embedded = 0
    play = 0
    for r in iso_files():
        data = disc.extract(r["lba"], r["size"])
        cs = osp.find_containers(data)
        if r["path"].startswith("DATA/04_PLAY/"):
            assert len(cs) == 1 and cs[0]["offset"] == 0, r["path"]
            play += 1
            continue
        embedded += len(cs)
        for c in cs:
            assert struct.unpack_from("<I", data, c["offset"] + 0x20)[0] == 0x34
    assert play == 78, play
    assert embedded == 35, embedded


def test_extracted_container_parses_and_decodes():
    """The property `overlay_sprites` depends on: a lifted container is valid."""
    found = None
    for r in iso_files():
        if r["path"] == "DATA/01_AREA.A/VA1.BIN":
            found = disc.extract(r["lba"], r["size"])
    assert found is not None, "VA1.BIN vanished from the ISO listing"
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        parsed_c, atlases, notes = osp.decode_container(found, 0x5A324, td)
    assert parsed_c["validation"]["errors"] == []
    assert len(atlases) == 3, (len(atlases), notes)
    for a in atlases:
        assert len(a["atlas"]) == 16384
        assert a["content_px"] > 0


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
