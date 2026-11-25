#!/usr/bin/env python3
"""Tests for kit/tools/psx_vram.py — the offline PS1 VRAM model.

Stdlib only. Run directly:
    python3 kit/tests/test_psx_vram.py
or with pytest (if installed):
    python3 -m pytest kit/tests/test_psx_vram.py
"""

import hashlib
import json
import os
import struct
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))

from psx_vram import (  # noqa: E402
    PsxVram, TP_4BIT, TP_8BIT, TP_16BIT,
    rgb555_to_rgb888, texpage_base, texpage_encode,
    clut_base, clut_encode, make_provenance,
    atlas_matches_at, find_atlas,
)


def distinct_atlas():
    """16,384 B atlas with no repeated row and no repeated byte run, so
    strided-vs-contiguous placement is unambiguous."""
    return bytes((r * 3 + c * 5) & 0xFF for r in range(128) for c in range(128))


# -- 1. strided LoadImage row layout ---------------------------------------

def test_strided_loadimage_row_layout():
    v = PsxVram()
    atlas = distinct_atlas()
    v.upload_rect(320, 256, 64, 128, atlas)
    img = v.to_bytes()
    assert len(img) == 1024 * 512 * 2
    for n in (0, 1, 63, 127):
        off = ((256 + n) * 1024 + 320) * 2
        assert img[off:off + 128] == atlas[n * 128:(n + 1) * 128], \
            "row %d not at strided offset" % n
    # rows are 2048 bytes apart in the 1 MB image
    off0 = ((256 + 0) * 1024 + 320) * 2
    off1 = ((256 + 1) * 1024 + 320) * 2
    assert off1 - off0 == 2048


# -- 2. naive contiguous search misses; strided search hits (0/78 regression)

def test_naive_contiguous_search_misses_strided_hits():
    v = PsxVram()
    atlas = distinct_atlas()
    v.upload_rect(320, 256, 64, 128, atlas)
    # the old bug: searching the 1 MB dump as contiguous bytes finds nothing
    assert v.to_bytes().find(atlas) == -1
    # the canonical strided search finds it exactly once, at the upload site
    assert find_atlas(v, atlas) == [(320, 256)]
    assert atlas_matches_at(v, atlas, 320, 256)
    # ...but not shifted by a row or at an empty site
    assert not atlas_matches_at(v, atlas, 320, 257)
    assert not atlas_matches_at(v, atlas, 0, 0)


def test_find_atlas_absent_and_bounds():
    v = PsxVram()
    v.upload_rect(320, 256, 64, 128, distinct_atlas())
    other = bytes(((r + c * 7 + 1) & 0xFF) for r in range(128)
                  for c in range(128))
    assert other != distinct_atlas()
    assert find_atlas(v, other) == []
    assert not atlas_matches_at(v, other, 320, 256)
    # out-of-bounds / wrong-size queries are clean misses, not crashes
    assert not atlas_matches_at(v, distinct_atlas(), 1024 - 63, 0)
    assert not atlas_matches_at(v, distinct_atlas(), 0, 512 - 127)
    assert not atlas_matches_at(v, distinct_atlas()[:100], 320, 256)
    try:
        find_atlas(v, distinct_atlas()[:100])
    except ValueError:
        pass
    else:
        raise AssertionError("find_atlas accepted a short atlas")


# -- 3. 8-bit indexed sampling through the d32 CLUT path --------------------

def test_8bit_indexed_sampling_with_d32():
    v = PsxVram()
    pal_words = [0x0000] * 32
    pal_words[5] = 0x7FFF   # white
    pal_words[7] = 0x001F   # red
    pal_words[9] = 0x03E0   # green
    pal_words[11] = 0x7C00  # blue
    pal_words[13] = 0x0421  # (1,1,1) -> (8,8,8) by the linear rescale
    atlas = bytearray(16384)
    atlas[3 * 128 + 2] = 5
    atlas[3 * 128 + 3] = 7    # odd u -> high byte of the word
    atlas[10 * 128 + 5] = 9
    atlas[7 * 128 + 7] = 11
    atlas[9 * 128 + 9] = 13
    v.upload_rect(320, 256, 64, 128, bytes(atlas))
    v.upload_rect(368, 48, 32, 1,
                  b"".join(struct.pack("<H", w) for w in pal_words))
    tp = texpage_encode(320, 256, TP_8BIT)
    cl = clut_encode(368, 48)
    assert tp == 0x95 and cl == 0x0C17
    assert v.sample_color(tp, cl, 2, 3) == (255, 255, 255)
    assert v.sample_color(tp, cl, 3, 3) == (255, 0, 0)
    assert v.sample_color(tp, cl, 5, 10) == (0, 255, 0)
    assert v.sample_color(tp, cl, 7, 7) == (0, 0, 255)
    assert v.sample_color(tp, cl, 9, 9) == (8, 8, 8)
    # texel indices come back raw
    assert v.sample_texel(tp, 2, 3) == 5
    assert v.sample_texel(tp, 3, 3) == 7
    # index-0 transparency: RGBA rows, (0,0,0,0) for index 0
    piece = v.sample_piece(tp, cl, 0, 0, 4, 4, transparent_index=0)
    assert piece[0][0] == (0, 0, 0, 0)
    assert piece[3][2] == (255, 255, 255, 255)
    # without transparent_index the classic RGB path is unchanged
    plain = v.sample_piece(tp, cl, 0, 0, 1, 1)
    assert plain[0][0] == (0, 0, 0) and len(plain[0][0]) == 3


# -- 4. 16-bit direct sampling ignores the CLUT -----------------------------

def test_16bit_direct_ignores_clut():
    v = PsxVram()
    v.upload_rect(320, 0, 2, 2,
                  struct.pack("<4H", 0x7FFF, 0x001F, 0x03E0, 0x7C00))
    assert rgb555_to_rgb888(0x7FFF) == (255, 255, 255)
    assert rgb555_to_rgb888(0x001F) == (255, 0, 0)
    assert rgb555_to_rgb888(0x03E0) == (0, 255, 0)
    assert rgb555_to_rgb888(0x7C00) == (0, 0, 255)
    assert rgb555_to_rgb888(0x0000) == (0, 0, 0)
    # bit 15 (semi-transparency flag) is ignored for color
    assert rgb555_to_rgb888(0xFFFF) == (255, 255, 255)
    tp = 0x0105  # -> (320, 0), 16-bit
    for clut in (0x0000, 0x0C17, 0xFFFF):
        assert v.sample_color(tp, clut, 0, 0) == (255, 255, 255)
        assert v.sample_color(tp, clut, 1, 0) == (255, 0, 0)
        assert v.sample_color(tp, clut, 0, 1) == (0, 255, 0)
        assert v.sample_color(tp, clut, 1, 1) == (0, 0, 255)
    assert v.sample_texel(tp, 1, 0) == 0x001F  # raw word, no CLUT


# -- 5. 4-bit sampling path keeps working -----------------------------------

def test_4bit_sampling_still_works():
    v = PsxVram()
    v.upload_rect(0, 0, 1, 1, b"\x9a\xcb")  # word 0xCB9A: nibbles A,9,B,C
    tp = texpage_encode(0, 0, TP_4BIT)
    assert tp == 0x00
    assert v.sample_texel(tp, 0, 0) == 0xA
    assert v.sample_texel(tp, 1, 0) == 0x9
    assert v.sample_texel(tp, 2, 0) == 0xB
    assert v.sample_texel(tp, 3, 0) == 0xC
    pal16 = [0x0000] * 16
    pal16[0xB] = 0x7FFF
    v.upload_rect(16, 0, 16, 1, struct.pack("<16H", *pal16))
    cl = clut_encode(16, 0)
    assert v.sample_color(tp, cl, 2, 0) == (255, 255, 255)
    piece = v.sample_piece(tp, cl, 0, 0, 4, 1, transparent_index=0xA)
    assert piece[0][0] == (0, 0, 0, 0)
    assert piece[0][2] == (255, 255, 255, 255)


# -- 6. provenance + hash recording, tamper detection -----------------------

def test_provenance_hash_and_tamper():
    v = PsxVram()
    data = bytes(range(256)) * 64  # 16384 B
    prov = make_provenance("CRE.BIN", section="S1", blob_index=1, kind="atlas")
    rec = v.upload_rect(320, 256, 64, 128, data, provenance=prov)
    assert rec["sha256"] == hashlib.sha256(data).hexdigest()
    assert rec["bytes"] == 16384
    assert (rec["x"], rec["y"], rec["w"], rec["h"]) == (320, 256, 64, 128)
    p = rec["provenance"]
    assert p["source_file"] == "CRE.BIN"
    assert p["section"] == "S1"
    assert p["blob_index"] == 1
    assert p["kind"] == "atlas"
    assert rec in v.uploads
    assert v.verify_upload(rec)
    assert all(ok for _, ok in v.verify_all())
    assert v.region_hash(320, 256, 64, 128) == rec["sha256"]
    # tamper with one word -> verification fails, and verify_all flags it
    v.set_word(321, 256, v.get_word(321, 256) ^ 0xFFFF)
    assert not v.verify_upload(rec)
    bad = [r for r, ok in v.verify_all() if not ok]
    assert any(r is rec for r in bad)
    # uploads without provenance still record coords + hash
    rec2 = v.upload_rect(0, 0, 1, 1, b"\x00\x00")
    assert rec2["provenance"] is None
    assert v.verify_upload(rec2)
    # deterministic: identical uploads produce identical records
    v2 = PsxVram()
    r1 = v2.upload_rect(320, 256, 64, 128, data, provenance=prov)
    v3 = PsxVram()
    r2 = v3.upload_rect(320, 256, 64, 128, data, provenance=prov)
    assert r1 == r2
    json.loads(v2.upload_log_json())  # log is JSON-serializable


# -- 7. texpage / CLUT decode (+encode) sanity ------------------------------

def test_texpage_clut_decode_encode_sanity():
    assert texpage_base(0x0105) == (320, 0, TP_16BIT)
    assert texpage_base(0x391b) == (704, 256, TP_16BIT)
    assert texpage_base(0x95) == (320, 256, TP_8BIT)
    assert clut_base(0x0c17) == (368, 48)
    assert clut_base(0x7800) == (0, 480)
    for tp in (0x0105, 0x95, 0x00, 0x391b):
        bx, by, mode = texpage_base(tp)
        assert texpage_encode(bx, by, mode) == tp & 0x19F  # base+mode bits
    for cl in (0x0c17, 0x7800, 0x0000):
        assert clut_encode(*clut_base(cl)) == cl


def main():
    tests = sorted(n for n, f in globals().items()
                   if n.startswith("test_") and callable(f))
    failed = 0
    for name in tests:
        try:
            globals()[name]()
        except Exception as ex:  # noqa: BLE001 - report, don't stop
            failed += 1
            print("FAIL %s: %s: %s" % (name, type(ex).__name__, ex))
        else:
            print("ok   %s" % name)
    print("----\n%d passed, %d failed" % (len(tests) - failed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
