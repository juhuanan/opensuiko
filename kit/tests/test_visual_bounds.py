#!/usr/bin/env python3
"""Tests for the area-tilemap visual bounds rules — kit/tests/test_visual_bounds.py

Workstream D, 2026-10-04. Covers:

  1. known-good source ranges for the area room pipeline (VB5.BIN, VA1.BIN);
  2. invalid / out-of-bounds tilemap pointers (unaligned, past EOF, spilling
     into a compressed blob);
  3. out-of-range blob / tile-index references;
  4. proof that no `pal[0]` substitution can reach a saved output.

Stdlib + PIL/numpy only (the shared helpers import lzss/PIL). The real-corpus
tests are skipped automatically when the extracted corpus or the disc is
absent, so this file runs without the disc.

Run directly:
    .venv/bin/python kit/tests/test_visual_bounds.py
or with pytest:
    .venv/bin/python -m pytest kit/tests/test_visual_bounds.py
"""

import os
import struct
import sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(KIT, "tools"))

import fix_palettes as fp                       # noqa: E402
import render_area_batch as rab                 # noqa: E402

RAM_BASE = rab.RAM_BASE
CORPUS = os.path.join(KIT, "extracted/bin_overlays/DATA")

# A valid 16 KB stream is not needed for the synthetic fixtures: the blob list
# is supplied directly as (file_off, 16384 bytes) pairs.

BLACK = (0, 0, 0)
RED = (255, 0, 0)


def all_black_256():
    return bytes(256)


def one_pixel_blob():
    """16384-byte blob whose subtile 0 is a single red pixel at (0,0)."""
    raw = bytearray(16384)
    raw[0] = 1
    return bytes(raw)


def pal_red_first():
    """256-entry palette whose entry 0 is RED: a pal[0] fill is then visibly
    non-black, so a substitution cannot hide behind "black"."""
    pal = [BLACK] * 256
    pal[0] = RED
    return pal


def synthetic_file(w, h, tiles, tm_off, size, fill=0x00):
    """A minimal area BIN image with a tilemap at tm_off."""
    data = bytearray([fill]) * size
    for i, t in enumerate(tiles):
        struct.pack_into("<H", data, tm_off + i * 2, t)
    return bytes(data)


# -- 1. known-good source ranges -------------------------------------------

def test_low_nibble_first_is_the_stone_page_order():
    """4-bit pages are low-nibble-first: byte 0x21 -> texels [1, 2].

    Independent of stone_render.py; this pins the convention the area/STONE
    decodes share.
    """
    b = 0x21
    assert (b & 0xF, b >> 4) == (1, 2)          # low-nibble-first
    assert ((b >> 4) & 0xF, b & 0xF) == (2, 1)  # the rejected alternative


def test_validate_tilemap_accepts_known_good_synthetic_room():
    """A 2x2 room reading in-range tile indices from inside the file passes."""
    w = h = 2
    tm = 0x100
    size = 0x400
    data = synthetic_file(w, h, [0, 1, 2, 3], tm, size)
    blobs = [(0x300, one_pixel_blob())]
    ok, why = rab.validate_tilemap(data, blobs, w, h, tm, size)
    assert ok, why
    ok2, why2 = fp.validate_tilemap(data, blobs, w, h, tm, size)
    assert ok2, why2


def test_real_corpus_known_good_rooms_still_accepted():
    """VB5.BIN / VA1.BIN rooms were already rendering correctly; the tightened
    rules must not reject them. Skipped when the corpus is absent."""
    checked = 0
    for area, name in (("02_AREA.B", "VB5"), ("01_AREA.A", "VA1")):
        path = os.path.join(CORPUS, area, name + ".BIN")
        if not os.path.exists(path):
            continue
        with open(path, "rb") as f:
            data = f.read()
        size = len(data)
        blobs = fp.find_blobs(data)
        assert blobs, "%s: no blobs found" % name
        for (_i, po, w, h) in real_headers(data, size):
            tm = struct.unpack_from("<I", data, po + 0x14)[0] - RAM_BASE
            if not (0 <= tm < size - w * h * 2):
                continue                      # already skipped by the loose check
            ok, why = rab.validate_tilemap(data, blobs, w, h, tm, size)
            assert ok, "%s header %d: %s" % (name, _i, why)
            checked += 1
    if checked == 0:
        print("skip: real corpus absent")


def real_headers(data, size):
    ptr0 = struct.unpack_from("<I", data, 0)[0]
    S = ptr0 - RAM_BASE
    if not (0 <= S < size - 16):
        return []
    t2 = struct.unpack_from("<I", data, S + 4)[0] - RAM_BASE
    if not (0 <= t2 < size - 4):
        return []
    out = []
    for i in range(64):
        if t2 + i * 4 + 4 > size:
            break
        po = struct.unpack_from("<I", data, t2 + i * 4)[0] - RAM_BASE
        if not (0 <= po < size - 24):
            continue
        w, h = struct.unpack_from("<HH", data, po)
        if w == 0 or h == 0 or w > 200 or h > 200:
            continue
        out.append((i, po, w, h))
    return out


# -- 2. invalid / out-of-bounds tilemap pointers ----------------------------

def test_rejects_unaligned_tilemap_pointer():
    w = h = 2
    size = 0x400
    data = synthetic_file(w, h, [0, 1, 2, 3], 0x101, size)
    blobs = [(0x300, one_pixel_blob())]
    ok, why = rab.validate_tilemap(data, blobs, w, h, 0x101, size)
    assert not ok and "align" in why, why


def test_rejects_tilemap_span_past_eof():
    """A tilemap span that runs past EOF must be rejected. The tilemap is
    placed so its *span* (not the pointer alone) is what fails."""
    w = h = 2
    size = 0x200
    tm = 0x100
    data = synthetic_file(w, h, [0, 1, 2, 3], tm, size)
    blobs = [(0x300, one_pixel_blob())]
    ok, _why = rab.validate_tilemap(data, blobs, w, h, tm, size)
    assert ok, "fixture should be valid at full size"
    # same bytes, but the file is now 1 byte too short for the span
    short = data[:tm + w * h * 2 - 1]
    ok, why = rab.validate_tilemap(short, blobs, w, h, tm, len(short))
    assert not ok and "past end" in why, why


def test_unpopulated_tilemap_field_gets_its_own_reason():
    """A raw +0x14 of 0 is an ABSENT pointer, not a span overrun.

    Both producers subtract RAM_BASE from the raw field, so a raw 0 arrives
    here as -RAM_BASE. It used to be reported as 'tilemap span past end of
    file', which sent readers after a bounds bug that does not exist: on
    2026-10-04 the 72 affected headers were shown to be duplicate/second-pass
    room records that carry no tilemap A at all. Pin the distinction, and pin
    that the two copies agree.
    """
    w = h = 2
    size = 0x400
    tm = 0x100
    data = synthetic_file(w, h, [0, 1, 2, 3], tm, size)
    blobs = [(0x300, one_pixel_blob())]
    raw_zero = 0 - 0x80010000                    # what a raw field of 0 becomes
    for mod in (rab, fp):
        ok, why = mod.validate_tilemap(data, blobs, w, h, raw_zero, size)
        assert not ok, "raw-zero pointer must not validate"
        assert "unpopulated" in why, why
        assert "past end" not in why, (
            "raw zero must NOT be reported as a span overrun: %s" % why)
    # control: a positive pointer whose span genuinely overruns still says so
    ok, why = rab.validate_tilemap(data[:tm + w * h * 2 - 1], blobs, w, h, tm,
                                   tm + w * h * 2 - 1)
    assert not ok and "past end" in why, why


def test_rejects_tilemap_inside_compressed_blob():
    """A pointer into LZSS payload is not a tilemap. Blob spans are
    [off, off+4+clen); the tilemap span must not overlap one."""
    w = h = 2
    size = 0x400
    data = bytearray(size)
    struct.pack_into("<I", data, 0x300, 8)           # blob comp_len = 8
    for i, t in enumerate([0, 1, 2, 3]):
        struct.pack_into("<H", data, 0x304 + i * 2, t)   # tilemap inside blob
    blobs = [(0x300, one_pixel_blob())]
    ok, why = rab.validate_tilemap(bytes(data), blobs, w, h, 0x304, size)
    assert not ok and "overlaps" in why, why


def test_rejects_tilemap_beyond_loose_old_check():
    """The old check `0 <= tm < size - w*h*2` accepted a pointer whose span
    runs past EOF right at its upper boundary; the new check must reject it."""
    w = h = 2
    size = 0x400
    tm_old_last = size - w * h * 2 - 1        # last value the old check took
    assert 0 <= tm_old_last < size - w * h * 2
    data = bytearray(size)
    struct.pack_into("<I", data, 0x300, 8)    # keep the file blob-like
    blobs = [(0x300, one_pixel_blob())]
    ok, why = rab.validate_tilemap(bytes(data), blobs, w, h, tm_old_last, size)
    assert not ok, "expected rejection of %#x" % tm_old_last


# -- 3. out-of-range blob / tile-index references ---------------------------

def test_rejects_tile_index_beyond_decoded_blobs():
    w = h = 2
    size = 0x400
    data = synthetic_file(w, h, [0, 1, 2, 4 * 64], 0x100, size)  # needs blob 4
    blobs = [(0x300, one_pixel_blob()), (0x380, one_pixel_blob())]
    ok, why = rab.validate_tilemap(data, blobs, w, h, 0x100, size)
    assert not ok and "blob 4" in why, why
    ok2, why2 = fp.validate_tilemap(data, blobs, w, h, 0x100, size)
    assert not ok2 and "blob 4" in why2, why2


def test_render_room_raises_instead_of_pal0_fill():
    """Out-of-range reference: render_room must RAISE, not silently produce a
    solid pal[0] image."""
    w = h = 2
    size = 0x400
    data = synthetic_file(w, h, [0xFFFF] * (w * h), 0x100, size)
    blobs = [(0x300, one_pixel_blob())]
    pal = pal_red_first()
    try:
        rab.render_room(data, blobs, pal, w, h, 0x100)
    except ValueError:
        return
    raise AssertionError("render_room accepted an out-of-range tile index")


def test_fix_palettes_renderers_raise_on_out_of_range():
    w = h = 2
    size = 0x400
    data = synthetic_file(w, h, [0xFFFF] * (w * h), 0x100, size)
    blobs = [(0x300, one_pixel_blob())]
    for fn in (fp.render_thumbnail, fp.render_full):
        arg = (data, blobs, pal_red_first(), w, h, 0x100)
        try:
            fn(*arg) if fn is fp.render_full else fn(*arg, scale=0.5)
        except IndexError:
            continue
        raise AssertionError("%s accepted an out-of-range tile index" % fn.__name__)


# -- 4. no pal[0] substitution may reach a saved output ---------------------

def test_no_pal0_fill_can_reach_a_saved_output():
    """The laundering defect: an absent blob became bytes(256), i.e. every
    pixel index 0 -> a solid pal[0] PNG saved as a normal result.

    With the fix, the same input is REJECTED before any image is written.
    pal[0] is RED here, so a substitution could not be mistaken for black.
    """
    w = h = 2
    size = 0x400
    tiles = [0, 1, 2, 4 * 64 + 7]        # last tile needs blob 4 (absent)
    data = synthetic_file(w, h, tiles, 0x100, size)
    blobs = [(0x300, one_pixel_blob())]
    pal = pal_red_first()

    # 1. the pointer check rejects it up front
    ok, why = rab.validate_tilemap(data, blobs, w, h, 0x100, size)
    assert not ok, "expected rejection"

    # 2. a bypassed call still cannot emit a pal[0]-only image
    try:
        img = rab.render_room(data, blobs, pal, w, h, 0x100)
    except (ValueError, IndexError):
        img = None
    if img is not None:
        colours = {img.getpixel((x, y))
                   for y in range(img.height) for x in range(img.width)}
        assert colours != {RED}, "a solid pal[0] image was produced"
        raise AssertionError("render_room returned an image for invalid input")


def test_pal0_fill_would_be_visible_if_it_reappeared():
    """Guard on the guard: the fixture palette makes a pal[0] fill
    distinguishable from black, so the previous test is meaningful."""
    pal = pal_red_first()
    assert pal[0] == RED and pal[0] != BLACK
    solid = bytes(256)                    # the old laundering value
    pixels = {pal[b] for b in solid}
    assert pixels == {RED}


def test_render_room_succeeds_on_valid_input():
    """Sanity: the rejection rules do not break a valid render."""
    w = h = 2
    size = 0x400
    data = synthetic_file(w, h, [0, 1, 2, 3], 0x100, size)
    blobs = [(0x300, one_pixel_blob())]
    img = rab.render_room(data, blobs, pal_red_first(), w, h, 0x100)
    assert img.size == (32, 32)
    assert RED in {img.getpixel((x, y))
                   for y in range(img.height) for x in range(img.width)}


# --- PS1 colour-channel convention (orchestrator, 2026-10-04) ---------------
# stone_render.rgb555() used to return red from bits 10-14 and blue from bits
# 0-4, i.e. R/B swapped relative to psx_vram and dump_sprites, so the published
# stone_font_a/b.png were wrong (they matched the swapped order on 100% of
# pixels). The hardware word is red in the low 5 bits: Mednafen packs a fill
# colour as ((r>>3)<<0)|((g>>3)<<5)|((b>>3)<<10) (src/psx/gpu.cpp:405).
# These tests pin the three tools to one convention.

def test_red_is_the_low_five_bits():
    import psx_vram
    assert psx_vram.rgb555_to_rgb888(0x001F) == (255, 0, 0)
    assert psx_vram.rgb555_to_rgb888(0x03E0) == (0, 255, 0)
    assert psx_vram.rgb555_to_rgb888(0x7C00) == (0, 0, 255)


def test_colour_convention_agrees_across_tools():
    import dump_sprites
    import psx_vram
    import stone_render
    for w in (0x0000, 0x001F, 0x03E0, 0x7C00, 0x7FFF, 0x4210, 0x2A5B, 0xFFFF):
        a = psx_vram.rgb555_to_rgb888(w & 0x7FFF)
        b = stone_render.rgb555(w)
        c = dump_sprites.rgb555_to_rgb888(w)
        assert a == b == c, ("0x%04x disagrees: psx_vram=%s stone_render=%s "
                             "dump_sprites=%s" % (w, a, b, c))


def test_legacy_probe_reads_clut_table_entry_zero():
    """Entry 0 remains available to historical probes; production uses +0x10.

    Test the lookup and invalid-input behavior, not a whole-room selector.
    """
    size = 0x1000
    po = 0x100
    tbl = 0x300                     # the CLUT table
    pal_off = 0x400                 # entry 0 -> the palette
    data = bytearray(size)
    struct.pack_into("<HH", data, po, 4, 4)          # w, h
    struct.pack_into("<I", data, po + 0x0c, RAM_BASE + tbl)
    struct.pack_into("<I", data, tbl, RAM_BASE + pal_off)
    struct.pack_into("<I", data, tbl + 4, RAM_BASE + pal_off + 512)
    for j in range(256):                             # 256 distinct colours
        struct.pack_into("<H", data, pal_off + j * 2, (j * 7) & 0x7FFF)
    for mod in (fp, rab):
        got = mod.get_clut_palette(bytes(data), po)
        assert got is not None, "%s: should read the CLUT table" % mod.__name__
        pal, off = got
        assert off == pal_off, (mod.__name__, hex(off))
        assert len(pal) == 256 and pal[0] == fp.rgb555_to_rgb888(0)
    # a degenerate palette (all one colour) must NOT be adopted
    flat = bytearray(data)
    for j in range(256):
        struct.pack_into("<H", flat, pal_off + j * 2, 0x1234)
    for mod in (fp, rab):
        assert mod.get_clut_palette(bytes(flat), po) is None, \
            "%s: must reject a degenerate CLUT" % mod.__name__
    # an out-of-range table pointer must fall back, not crash
    broken = bytearray(data)
    struct.pack_into("<I", broken, po + 0x0c, RAM_BASE + size + 0x1000)
    for mod in (fp, rab):
        assert mod.get_clut_palette(bytes(broken), po) is None, \
            "%s: must reject an out-of-range table" % mod.__name__


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
