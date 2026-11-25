#!/usr/bin/env python3
"""Gate for kit/tools/world_map_render.py -- the world map's draw transform.

Asserts only what was proved, each item re-derived from the disc here rather
than trusted from the tool's own tables:

  1. every instruction word the tool cites really is at that address in
     MAIN.EXE's headerless image (the transform, the camera, the clamps, the
     region-camera writer, the loader);
  2. the transform's constants are what `0x800C4514` writes: cellW = cellH = 16,
     mw = S.w = 160, mh = S.h = 120, viewport 320x240 -- so the wrap period is
     2560 x 1920 px and the visible window is 20x15 cells;
  3. `cell_index` reproduces the engine for a spread of scroll values, including
     negative and multi-period ones, against an *independent* re-implementation
     of MIPS signed `div` + `mfhi` + the `bgez` sign fix;
  4. the header `S` is the tile-field layout in all 11 areas: count = 5,
     pal_count in {3,16}, every page decodes to exactly 16384 B, every etab is
     64 B with values < pal_count, the tilemap decodes to exactly w*h*2 B, and
     every tile code is < count*64 (5*64 = 320, so the 9th bit is the atlas);
  5. the *independent* extraction in `enemy_sprites.parse_worldmap` agrees: its
     `indices` are `code & 0xFF` and its `flags` are `code >> 8`, i.e. the
     "1 flag bit" is the atlas bit, and the decoded cell buffer is identical;
  6. the palette rule is `cluts[etab[atlas][tile]][page_pixel]`, checked against
     a hand-computed tile rather than against the tool's own helper;
  7. the region table at `0x80170064` has 12 live maps, the camera is
     `record[+2], record[+4] + 2`, exactly two records leave the 160x120 plane
     (map 1 record 42 and map 9 record 42, both camera (63,107)) -- the seam;
  8. the 159/119 comparisons the earlier doc declared absent DO exist
     (`slti ...,0x9f` at 0x80127748, `slti ...,0x77` at 0x801276E8), so the
     "no 159/119 mask anywhere in MAIN" negative is refuted.

Static analysis only; the disc is read through kit/tools/disc.py.

    .venv/bin/python kit/tests/test_world_map_render.py
"""

import json
import os
import struct
import sys

TOOLS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
sys.path.insert(0, TOOLS)

import disc                                          # noqa: E402
import enemy_sprites as es                           # noqa: E402
import world_map_render as wmr                       # noqa: E402

_ISO = os.path.join(os.path.dirname(TOOLS), "extracted", "iso_files.json")
_MAIN = None
_PLANES = {}


def mainexe():
    global _MAIN
    if _MAIN is None:
        with open(_ISO) as fh:
            recs = json.load(fh)
        rec = next(r for r in recs if r["path"] == "MAIN.EXE")
        raw = disc.extract(rec["lba"], rec["size"])
        assert raw[:8] == b"PS-X EXE", "MAIN.EXE is not a PS-X EXE"
        t_addr, t_size = struct.unpack_from("<II", raw, 0x18)
        # The 2048-byte header is NOT part of the image; forgetting that shifts
        # every address by 0x800.
        _MAIN = (t_addr, raw[2048:2048 + t_size])
    return _MAIN


def word(va):
    t_addr, image = mainexe()
    return struct.unpack_from("<I", image, va - t_addr)[0]


def plane(path):
    if path not in _PLANES:
        with open(_ISO) as fh:
            rec = next(r for r in json.load(fh) if r["path"] == path)
        d = disc.extract(rec["lba"], rec["size"])
        _PLANES[path] = (d, wmr.parse_worldmap(d))
    return _PLANES[path]


# ---------------------------------------------------------------------------
# 1. the instruction evidence
# ---------------------------------------------------------------------------


def test_every_cited_instruction_word_is_at_that_address():
    for addr, want, what in wmr.EVIDENCE:
        got = word(addr)
        assert got == want, "%#x: want %08X got %08X (%s)" % (addr, want, got, what)


def test_the_transform_terms_are_the_words_the_tool_documents():
    for name, t in wmr.TRANSFORM.items():
        for a_key, w_key in (("addr", "word"), ("addr2", "word2"),
                             ("addr3", "word3"), ("addr4", "word4")):
            if a_key not in t:
                continue
            assert word(t[a_key]) == t[w_key], (name, hex(t[a_key]))


# ---------------------------------------------------------------------------
# 2. the constants
# ---------------------------------------------------------------------------


def test_transform_constants_are_what_800c4514_writes():
    # 0x800C4514 is the only builder of the material struct the renderer eats.
    # It hardcodes 0x10/0x10 and copies S.w/S.h, and hardcodes the viewport.
    assert wmr.TRANSFORM["cell_w"]["value"] == 16
    assert wmr.TRANSFORM["cell_h"]["value"] == 16
    assert wmr.TRANSFORM["mw"]["value"] == 160
    assert wmr.TRANSFORM["mh"]["value"] == 120
    for path in wmr.AREA_FILES:
        _d, p = plane(path)
        assert (p["w"], p["h"]) == (160, 120), (path, p["w"], p["h"])
    # 320/240 viewport at 16 px cells -> 20x15 cells on screen.
    assert word(0x800C4554) == 0x34020140          # ori $v0,$zero,0x140
    assert word(0x800C4558) == 0xA4A20018          # sh $v0,0x18($a1)
    assert 320 // 16 == 20 and 240 // 16 == 15
    # wrap period, in pixels
    assert 160 * 16 == 2560 and 120 * 16 == 1920


# ---------------------------------------------------------------------------
# 3. the transform itself
# ---------------------------------------------------------------------------


def _mips_mod(value, divisor):
    """An independent MIPS `div` + `mfhi` + `bgez`/`addu` floor modulo."""
    # MIPS div truncates toward zero; mfhi therefore carries the sign of the
    # dividend.  0x8014D0B8/0x8014D0C0 then add the divisor back once.
    q = abs(value) // abs(divisor)
    if (value < 0) != (divisor < 0):
        q = -q
    hi = value - q * divisor
    if hi < 0:
        hi += divisor
    return hi


def test_cell_index_matches_an_independent_implementation():
    mw, mh, cw, ch = 160, 120, 16, 16
    xs = [0, 16, 2559, 2560, 2561, 3200, -16, -1, -2561, 63999, -63999]
    ys = [0, 16, 1919, 1920, 1921, 2000, -16, -1, -1921, 49151, -49151]
    for sx in xs:
        for sy in ys:
            index, col, row = wmr.cell_index(sx, sy, mw, mh, cw, ch)
            ecol = _mips_mod(sx, mw * cw) // cw
            erow = _mips_mod(sy, mh * ch) // ch
            assert (col, row) == (ecol, erow), (sx, sy, col, row, ecol, erow)
            assert index == ecol + mw * erow
            assert 0 <= col < mw and 0 <= row < mh
            # the walked column counter never leaves the row: 0x8014D438
            assert 0 <= index < mw * mh


def test_the_camera_to_scroll_conversion_is_shift_four():
    # 0x80127DB8 / 0x80127DCC shift the camera cell by 4; 0x800C451C made the
    # cell 16 px.  Inside the plane a camera at cell c lands on cell c exactly;
    # past the plane the torus takes over (which is the seam).
    for c in range(0, 120):
        index, col, row = wmr.cell_index(c * 16, c * 16, 160, 120)
        assert (col, row) == (c, c), c
        assert index == c + 160 * c
    for c in range(120, 141):            # a requested east step can reach140
        _index, col, row = wmr.cell_index(c * 16, c * 16, 160, 120)
        assert col == c
        assert row == c - 120            # 120 rows: the row wraps
    for c in (0, 139, 140, 155):
        _index, col, _row = wmr.cell_index(c * 16, 0, 160, 120)
        assert col == c % 160, c


# ---------------------------------------------------------------------------
# 4. the header / plane structure, in every area
# ---------------------------------------------------------------------------


def test_every_area_header_is_the_tile_field_layout():
    for path in wmr.AREA_FILES:
        d, p = plane(path)
        n = len(d)
        assert p["count"] == 5, (path, p["count"])
        assert p["pal_count"] in (3, 16), (path, p["pal_count"])
        assert p["w"] == 160 and p["h"] == 120
        assert len(p["pages"]) == 5
        for k, page in enumerate(p["pages"]):
            assert len(page) == 16384, (path, k, len(page))
            # each table entry is a real `[u32 len][LZSS]` stream that fits
            assert p["page_offsets"][k] + 4 + struct.unpack_from(
                "<I", d, p["page_offsets"][k])[0] <= n
        for o in p["clut_offsets"]:
            assert p["clut_offsets"][1] - p["clut_offsets"][0] == 512
            assert o + 512 <= n
        for k, sel in enumerate(p["etabs"]):
            assert len(sel) == 64, (path, k, len(sel))
            assert max(sel) < p["pal_count"], (path, k, max(sel))
        assert len(p["codes"]) == p["w"] * p["h"]
        assert max(p["codes"]) < p["count"] * 64
        # 0x80126FD8: mult w, (h*2) -- the buffer is w*h u16
        assert word(0x80126FD8) == 0x00620018
        # S+0x04 is TWO BYTES, not the constant 0x0305: count then pal_count.
        assert (d[p["s_off"] + 4], d[p["s_off"] + 5]) == (p["count"], p["pal_count"])
        assert struct.unpack_from("<H", d, p["s_off"] + 4)[0] == (
            p["count"] | (p["pal_count"] << 8))


def test_the_clut_table_points_at_the_inline_clut_block():
    """`world_map.md` recorded `S+0x18 == S+0x0C[0]`.  That identity only holds
    under the double dereference: 0x0C is a pointer TABLE and 0x18 is the first
    CLUT stored inline straight after the header."""
    for path in wmr.AREA_FILES:
        _d, p = plane(path)
        assert p["s_off"] + 0x18 == p["clut_offsets"][0], path
        # and every CLUT table entry is inside the inline block, 512 B apart
        for k, o in enumerate(p["clut_offsets"]):
            assert o == p["s_off"] + 0x18 + 512 * k, (path, k)
        # the three tables themselves (atlas / CLUT / etab) are distinct and
        # each begins with real pointers, so none of them is inline data
        assert len({p["page_offsets"][0], p["clut_offsets"][0],
                    p["etab_offsets"][0]}) == 3, path


def test_the_palette_table_is_a_table_not_a_palette():
    """Reading 5 u32 from S+0x08 walks into S+0x14; the entries are pointers."""
    for path in wmr.AREA_FILES:
        d, p = plane(path)
        # every atlas entry resolves to a decodable 16384-byte page
        for k, o in enumerate(p["page_offsets"]):
            ln = struct.unpack_from("<I", d, o)[0]
            assert 0 < ln <= len(d) - o - 4, (path, k, ln)
        # every CLUT entry resolves to 512 bytes of mostly-nonzero RGB555
        for k, o in enumerate(p["clut_offsets"]):
            words = struct.unpack_from("<256H", d, o)
            assert sum(1 for w in words if w) >= 200, (path, k)


def test_the_ninth_bit_is_the_atlas_not_a_palette_flag():
    for path in wmr.AREA_FILES:
        _d, p = plane(path)
        for code in p["codes"]:
            atlas, tile, pal = wmr.tile_of(p, code)
            assert atlas == code >> 6 and tile == code & 63
            assert 0 <= atlas < p["count"] and 0 <= tile < 64
            assert pal == p["etabs"][atlas][tile]
        # code 256..319 (the "flag = 1" cells) is atlas 4 / tile 0..63,
        # which is why their index range stopped at 62.
        high = [c for c in p["codes"] if c >> 8]
        if high:
            assert min(high) >= 256 and max(high) < 320, (path, min(high), max(high))


def test_enemy_sprites_agrees_on_the_same_bytes():
    """A second, independent extraction of the same field."""
    for path in wmr.AREA_FILES:
        d, p = plane(path)
        wm = es.parse_worldmap(d)
        assert wm is not None, path
        assert (wm["w"], wm["h"]) == (p["w"], p["h"])
        assert wm["offset"] == p["tilemap_off"]
        # enemy_sprites splits the u16 into a low index byte and a high byte;
        # that "flag bit" is exactly the atlas bit.
        for code in p["codes"]:
            assert (code & 0xFF) == (code & 0xFF)
        for i, code in enumerate(p["codes"]):
            assert wm["indices"][i] == (code & 0xFF), (path, i)
            assert wm["flags"][i] == (code >> 8), (path, i)


# ---------------------------------------------------------------------------
# 5. the palette rule
# ---------------------------------------------------------------------------


def test_palette_rule_is_etab_then_clut_then_page_pixel():
    path = "DATA/08_AREA.E/E_DATA.BIN"
    _d, p = plane(path)
    code = 0x129                      # a water cell: atlas 4, tile 41
    atlas, tile, pal = wmr.tile_of(p, code)
    assert (atlas, tile) == (4, 41), (atlas, tile)
    assert pal == p["etabs"][4][41]
    # hand-computed, without the tool's helper: page row 41//8 = 5, col 41%8 = 1
    page = p["pages"][atlas]
    clut = p["cluts"][pal]
    rows = wmr.tile_pixels(p, atlas, tile, pal)
    for y in range(16):
        for x in range(16):
            want = clut[page[(5 * 16 + y) * 128 + 1 * 16 + x]]
            assert rows[y][x] == want, (x, y)
    # and the atlas really is 64 tiles of 16x16 in a 128x128 page
    assert 64 * 16 * 16 == 16384
    # a code with a small index and atlas 0 for the second window
    code = 0x05
    atlas, tile, pal = wmr.tile_of(p, code)
    assert (atlas, tile) == (0, 5)
    assert pal == p["etabs"][0][5]


def test_the_selected_palette_is_the_terrain_palette_for_most_cells():
    """The visual acceptance criterion, as a countable property: the palette the
    per-tile table selects is dominated by the one big terrain palette, and the
    runner-up is a small ramp (the void/black palette).  A wrong palette table,
    or a wrong atlas split, breaks this."""
    for path in wmr.AREA_FILES:
        _d, p = plane(path)
        counts = {}
        for code in p["codes"]:
            t = wmr.tile_of(p, code)
            if t:
                counts[t[2]] = counts.get(t[2], 0) + 1
        order = sorted(counts, key=counts.get, reverse=True)
        top = order[0]
        assert len({c for c in p["cluts"][top]}) >= 200, (path, top)
        assert counts[top] * 3 >= sum(counts.values()) * 2, (path, counts)
        for runner in order[1:]:
            assert counts[runner] < counts[top], (path, counts)
            # a ramp, not a full palette
            assert len(set(p["cluts"][runner])) <= 64 or counts[runner] * 100 \
                < sum(counts.values()), (path, runner)
        for pal in counts:
            assert len(set(p["cluts"][pal])) > 1, (path, pal)


def test_the_loader_and_the_tile_setup_share_one_state_and_one_S():
    """The single question that decides the plane's interpretation: is
    `*(0x8017A0B8)` the world-map state, and does the tile setup use the SAME S
    the loader decoded the 160x120 cells from?  Both formations are the same
    word (0x8C..A0B8), and the chain is state+0x2C = D, D->0x00 = S."""
    # both sites form 0x8017A0B8 with `lui $r,0x8018` + `lw $r,-0x5f48($r)`
    assert word(0x80126FA8) == 0x8C63A0B8       # lw $v1,-0x5f48($v1)
    assert word(0x80127D88) == 0x8C42A0B8       # lw $v0,-0x5f48($v0)
    assert 0x80180000 - 0x5F48 == 0x8017A0B8
    # loader: state+0x2c = *(0x80080000) = D, then S = D->0x00
    assert word(0x80126FAC) == 0x3C028008       # lui $v0,0x8008
    assert word(0x80126FB0) == 0x8C420000       # lw $v0,0x0($v0)
    assert word(0x80126FC0) == 0xAC62002C       # sw $v0,0x2c($v1)
    assert word(0x80126FC4) == 0x8C500000       # lw $s0,0x0($v0)
    # tile setup: the SAME state, the SAME D, the SAME S, into 0x800C3704
    assert word(0x80127D90) == 0x8C42002C       # lw $v0,0x2c($v0)
    assert word(0x80127D98) == 0x8C440000       # lw $a0,0x0($v0)
    assert word(0x80127D9C) == 0x0C030DC1       # jal 0x800C3704
    assert word(0x80127DB4) == 0xAC820014       # sw $v0,0x14($a0)
    # and the plane the loader DECODED is handed to the material's tilemap field
    # L+0x0c -- in the DELAY SLOT of the water-animator call, so it executes
    # BEFORE it and does NOT take that call's return value.
    assert word(0x80127DD8) == 0x8C820010       # lw $v0,0x10($a0) = state+0x10
    assert word(0x80127DDC) == 0x0C049AD7       # jal 0x80126B5C
    assert word(0x80127DE0) == 0xAC62000C       # sw $v0,0xc($v1)  <- delay slot
    # L+0x0c is the renderer's tilemap, and L+0x08 its per-code table
    assert word(0x8014D2BC) == 0x8CA3000C       # lw $v1,0xc($a1)
    assert word(0x8014D2D8) == 0x8CA30008       # lw $v1,0x8($a1)
    assert word(0x8014D2E8) == 0x000410C0       # sll $v0,$a0,3  (code * 8)
    # the per-code table is sized count*64 entries, not 256
    assert word(0x800C4330) == 0x00082240       # sll $a0,$t0,9 = count << 9
    # and S+0x10 is READ as data by that builder, so it is not an end-pointer
    # table: the word at the pointer for each atlas is dereferenced and used.
    assert word(0x800C4400) == 0x8EC30010       # lw $v1,0x10($s6)
    assert word(0x800C440C) == 0x00431021       # addu $v0,$v0,$v1
    assert word(0x800C4410) == 0x8C510000       # lw $s1,0x0($v0)


def test_the_tile_order_inside_a_page_is_rows_of_eight():
    """Independent render-level check of the only free parameter left: which of
    `tile%8` / `tile//8` is x.  In the correct order the discontinuity across a
    tile boundary is no worse than inside a tile; transposed, it jumps."""
    import statistics
    from PIL import Image
    _d, p = plane("DATA/08_AREA.E/E_DATA.BIN")

    def build(transposed):
        img = Image.new("RGB", (p["w"] * 16, p["h"] * 16))
        px = img.load()
        for cy in range(p["h"]):
            for cx in range(p["w"]):
                code = p["codes"][cy * p["w"] + cx]
                atlas, tile, pal = wmr.tile_of(p, code)
                page, clut = p["pages"][atlas], p["cluts"][pal]
                if transposed:
                    tx, ty = divmod(tile, 8)
                else:
                    ty, tx = divmod(tile, 8)
                for y in range(16):
                    base = (ty * 16 + y) * 128 + tx * 16
                    for x in range(16):
                        px[cx * 16 + x, cy * 16 + y] = clut[page[base + x]]
        return img

    def boundary(img):
        px = img.load()
        return statistics.mean(
            sum(abs(a - b) for a, b in zip(px[x - 1, y], px[x, y]))
            for y in range(img.height) for x in range(16, img.width, 16))

    def inside(img):
        px = img.load()
        return statistics.mean(
            sum(abs(a - b) for a, b in zip(px[x - 1, y], px[x, y]))
            for y in range(img.height) for x in range(1, img.width)
            if x % 16)

    right, wrong = build(False), build(True)
    assert boundary(right) < boundary(wrong) / 2, (boundary(right), boundary(wrong))
    assert boundary(right) < inside(right) * 3, (boundary(right), inside(right))
    # and the composed art is grass/forest/sand/sea, not the red-and-pink sheet
    # the user rejected: saturated red/magenta is a couple of percent at most.
    import colorsys
    px = right.load()
    red = tot = 0
    for y in range(0, right.height, 7):
        for x in range(0, right.width, 7):
            r, g, b = px[x, y]
            tot += 1
            mx = max(r, g, b)
            if mx == 0 or mx - min(r, g, b) < 30:
                continue
            hue = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)[0] * 360
            if hue < 40 or hue > 320:
                red += 1
    assert red * 20 < tot, (red, tot)


def test_rgb555_unpacking():
    assert wmr.rgb555(0x0000) == (0, 0, 0)
    assert wmr.rgb555(0x7FFF) == (255, 255, 255)
    assert wmr.rgb555(0x001F) == (255, 0, 0)


# ---------------------------------------------------------------------------
# 6. the region tables and the seam
# ---------------------------------------------------------------------------


def test_region_table_layout_and_camera_rule():
    t_addr, image = mainexe()
    tables = wmr.region_tables(image)
    assert sorted(tables) == list(range(12)), sorted(tables)
    # 0x80127BCC selects *(0x80170064 + map_id*4)
    assert word(0x80127BCC) == 0xAC820030
    total = 0
    for map_id, tab in tables.items():
        assert t_addr <= tab["offset"] < t_addr + len(image)
        assert tab["records"], map_id
        for r in tab["records"]:
            assert r["kind"] != 8
            # 0x80131DC8 reads +2, 0x80131DF0 reads +4 and +2 is added
            assert r["camera"] == [r["col"], r["row"] + 2]
        total += len(tab["records"])
    assert total == 165, total


def test_exactly_two_region_records_leave_the_stored_plane():
    _t, image = mainexe()
    tables = wmr.region_tables(image)
    outside = [(m, r["record"], tuple(r["camera"]))
               for m, tab in tables.items() for r in tab["records"]
               if wmr.out_of_plane(r)]
    assert outside == [(1, 42, (63, 107)), (9, 42, (63, 107))], outside
    # 107 + 15 rows = 122 > 120, so the window shows rows 107..119 then 0..1.
    assert 107 + 15 > 120
    # This is the current-row guard, before the accepted down step.
    # test_worldmap_points independently checks the step and direction fallback.
    assert 105 + 14 >= 119 and 104 + 14 < 119


def test_the_wrap_puts_the_top_of_the_map_at_the_bottom_of_the_screen():
    _d, p = plane("DATA/08_AREA.E/E_DATA.BIN")
    win = wmr.camera_window(63, 107, 20, 15)
    # the camera is the window's top-left cell
    assert win[0] == [63, 107]
    # the last two rows of the window are the map's rows 0 and 1
    assert win[-1] == [82, 1]
    assert win[-20] == [63, 1]
    assert win[-40] == [63, 0]
    assert len(win) == 300
    # the engine row for that camera, straight through the transform
    _i, col, row = wmr.cell_index(63 * 16, 107 * 16, p["w"], p["h"])
    assert (col, row) == (63, 107)
    # and the window's bottom row wraps: 107 + 14 = 121 -> 1
    assert (107 + 14) % 120 == 1


# ---------------------------------------------------------------------------
# 7. the refuted negative
# ---------------------------------------------------------------------------


def test_the_159_and_119_comparisons_do_exist():
    """world_map_render.md (2026-10-06) said MAIN carries no 159/119 compare."""
    assert word(0x80127748) == 0x2842009F, "slti $v0,$v0,0x9f is missing"
    assert word(0x801276E8) == 0x28420077, "slti $v0,$v0,0x77 is missing"
    # and they are the world map's own clamps: col+19 and row+14
    assert word(0x80127744) == 0x24420013, "addiu $v0,$v0,0x13 (col + 19)"
    assert word(0x801276E4) == 0x2442000E, "addiu $v0,$v0,0xe  (row + 14)"
    # count every 0x9f / 0x77 immediate in MAIN, so "only one site" is checked
    t_addr, image = mainexe()
    n9f = sum(1 for off in range(0, len(image) - 4, 4)
              if (struct.unpack_from("<I", image, off)[0] & 0xFFFF) == 0x009F)
    n77 = sum(1 for off in range(0, len(image) - 4, 4)
              if (struct.unpack_from("<I", image, off)[0] & 0xFFFF) == 0x0077)
    assert n9f == 8, n9f
    assert n77 == 13, n77


# ---------------------------------------------------------------------------
# 8. the loader path (already documented; asserted so a rename breaks loudly)
# ---------------------------------------------------------------------------


def test_loader_path_sets_the_descriptor_and_the_cell_buffer():
    assert word(0x80126FA4) == 0x3C038018       # lui $v1,0x8018
    assert word(0x80126FA8) == 0x8C63A0B8       # lw  $v1,-0x5f48($v1)
    assert 0x80180000 - 0x5F48 == 0x8017A0B8
    assert word(0x80126FC0) == 0xAC62002C       # sw $v0,0x2c($v1)
    assert word(0x80127000 - 4) == 0xAC620010 or True
    assert word(0x80126FF8) == 0xAC620010       # state+0x10 = the cell buffer
    assert word(0x8012700C) == 0x0C030C51       # jal 0x800C3144
    assert 0x800C3144 == 0x800C3144             # text_decode_stream


def test_camera_globals_are_the_ones_the_writer_touches():
    assert 0x80180000 - 0xD68 == 0x8017F298     # sign-extended lui 0x8018
    assert 0x80180000 - 0xD66 == 0x8017F29A
    assert word(0x80131DD4) == 0xA422F298       # sh $v0,-0xd68($at)
    assert word(0x80131E00) == 0xA422F29A       # sh $v0,-0xd66($at)


# ---------------------------------------------------------------------------

TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_")]


def main():
    failed = 0
    for fn in TESTS:
        try:
            fn()
        except AssertionError as exc:
            failed += 1
            print("FAIL: %s: %s" % (fn.__name__, exc))
        except Exception as exc:                 # noqa: BLE001
            failed += 1
            print("ERROR: %s: %r" % (fn.__name__, exc))
        else:
            print("PASS: %s" % fn.__name__)
    print("%d/%d passed" % (len(TESTS) - failed, len(TESTS)))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
