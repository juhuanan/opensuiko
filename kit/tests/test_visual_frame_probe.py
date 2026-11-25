#!/usr/bin/env python3
"""Tests for the area frame-candidate probe -- kit/tests/test_visual_frame_probe.py

Workstream U, 2026-10-04. Covers the pure helpers of
`kit/tools/area_frame_probe.py` (colour-space step metric, pair similarity,
ladder detection, connected-group collapse) with synthetic fixtures, plus
real-corpus invariants for `VB4_h0` that pin down the facts Phase A rests on.

The real-corpus tests are skipped automatically when the extraction is absent,
so this file also runs without the disc.

Run directly:
    .venv/bin/python kit/tests/test_visual_frame_probe.py
or with pytest:
    .venv/bin/python -m pytest kit/tests/test_visual_frame_probe.py
"""

import os
import struct
import sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(KIT, "tools"))

import area_frame_probe as afp                     # noqa: E402

CORPUS = os.path.join(KIT, "extracted/bin_overlays/DATA")
RAM_BASE = afp.RAM_BASE

# ---------------------------------------------------------------------------
# synthetic fixtures
# ---------------------------------------------------------------------------
# A blob is 128x128 8-bit indexed; code = blob*64 + subtile.
# Cell (blob 0, subtile 1) is at (16, 0); subtile 2 at (32, 0).


def _blob_with_cells(cells):
    """16,384-byte blob; `cells` maps subtile -> 16x16 index grid generator."""
    buf = bytearray(16384)
    for si, gen in cells.items():
        sx, sy = (si % 8) * 16, (si // 8) * 16
        for y in range(16):
            for x in range(16):
                buf[(sy + y) * 128 + sx + x] = gen(x, y)
    return bytes(buf)


GREY = [(0, 0, 0), (64, 64, 64), (128, 128, 128), (255, 255, 255)]
# palette index -> colour; index 0/1 alternate -> a high-contrast texture,
# index 2 -> a flat surface that must score step == 0.
PAL = [(0, 0, 0), (255, 255, 255), (128, 128, 128),
       (0, 0, 0), (40, 40, 40), (80, 80, 80), (120, 120, 120),
       (160, 160, 160)]


def test_colour_step_flat_is_zero():
    flat = _blob_with_cells({2: lambda x, y: 2})
    cell = afp.cell_of([flat], 2)
    assert afp.colour_step(cell, PAL) == 0.0


def test_colour_step_alternating_is_max():
    alt = _blob_with_cells({1: lambda x, y: (x + y) & 1})
    cell = afp.cell_of([alt], 1)
    # every adjacent pair is index 0 next to index 1 -> |0-255|/3 per channel
    assert abs(afp.colour_step(cell, PAL) - 255.0) < 1e-6


def test_cell_of_uses_blob_and_subtile_not_subtile_alone():
    # subtile 1 of blob 0 is all 2s, subtile 1 of blob 1 is all 0s
    b0 = _blob_with_cells({1: lambda x, y: 2})
    b1 = _blob_with_cells({1: lambda x, y: 0})
    assert set(afp.cell_of([b0, b1], 1)) == {2}
    assert set(afp.cell_of([b0, b1], 65)) == {0}


def test_pair_similarity_identical_and_disjoint():
    b0 = _blob_with_cells({1: lambda x, y: 2})
    b1 = _blob_with_cells({1: lambda x, y: 2})
    jac, eq, mad = afp.pair_similarity(afp.cell_of([b0, b1], 1),
                                       afp.cell_of([b0, b1], 65))
    assert (jac, eq, mad) == (1.0, 1.0, 0.0)

    a = _blob_with_cells({1: lambda x, y: 1 if (x + y) & 1 else 0})
    z = _blob_with_cells({1: lambda x, y: 0})
    jac, eq, mad = afp.pair_similarity(afp.cell_of([a, z], 1),
                                       afp.cell_of([a, z], 65))
    assert (round(jac, 3), round(eq, 3), round(mad, 3)) == (0.5, 0.5, 0.5)


def test_ladder_pairs_accepts_verified_frames():
    # two cells that share indices and are close, both far above the room median
    a = _blob_with_cells({1: lambda x, y: 1 if (x + y) & 1 else 0})
    b = _blob_with_cells({2: lambda x, y: 1 if (x + y) & 1 else 2})
    # a third, calm code used by the room so the median is meaningful; it is a
    # smooth gradient, i.e. a low colour step
    c = _blob_with_cells({0: lambda x, y: 3 + (x * 4) // 16})
    blobs = [a, c]                      # code 64 is blob 1 subtile 0 (calm)
    cells = {1: afp.cell_of(blobs, 1), 2: afp.cell_of(blobs, 2),
             64: afp.cell_of(blobs, 64)}
    steps = {1: afp.colour_step(cells[1], PAL),
             2: afp.colour_step(cells[2], PAL),
             64: afp.colour_step(cells[64], PAL)}
    lads, med = afp.ladder_pairs({1, 2, 64}, cells, steps)
    assert med > 0.0, "the room median must come from the calm code"
    by_pair = {(l['code_a'], l['code_b']): l for l in lads}
    cand = by_pair[(1, 2)]
    # 1<->2 is a frame candidate: adjacent, shared palette indices, close grids,
    # and far above the room's own colour-step median
    assert cand['is_frame_candidate'] is True, cand
    assert cand['jaccard'] == 0.5 and cand['mean_abs_index_diff'] == 0.5
    assert cand['step_a'] > 1.5 * med


def test_ladder_pairs_rejects_unrelated_art():
    # same index set and adjacency, but a large pixel distance -> not a frame
    a = _blob_with_cells({1: lambda x, y: (x + y) & 1})
    b = _blob_with_cells({2: lambda x, y: 1 - ((x + y) & 1)})
    steps = {1: 200.0, 2: 200.0}
    lads, _med = afp.ladder_pairs(
        {1, 2}, {1: afp.cell_of([a], 1), 2: afp.cell_of([b], 2)}, steps,
        mad_max=0.5)
    assert lads[0]['is_frame_candidate'] is False


def test_collapse_map_collapses_a_ladder_to_one_representative():
    lads = [{'code_a': 1, 'code_b': 2}, {'code_a': 2, 'code_b': 3},
            {'code_a': 3, 'code_b': 4}, {'code_a': 174, 'code_b': 175}]
    m = afp.collapse_map(lads)
    assert m == {2: 1, 3: 1, 4: 1, 175: 174}


def test_parse_clut_override():
    assert afp.parse_clut_override('1,2,3,4,204,205=4') == {
        1: 4, 2: 4, 3: 4, 4: 4, 204: 4, 205: 4}
    assert afp.parse_clut_override('1=2;9,10=3') == {1: 2, 9: 3, 10: 3}
    assert afp.parse_clut_override(None) == {}


def test_per_tile_clut_keeps_base_unless_strictly_better():
    # two synthetic cells: one flat under entry 0, one high-contrast under 0
    # and flat under entry 1
    calm = bytes([2] * 256)
    hot = bytes([1 if (x + y) & 1 else 0 for y in range(16) for x in range(16)])
    info = {'cells': {1: calm, 2: hot}}
    # entry 0: 0 -> black, 1 -> white, 2 -> grey ; entry 1 maps 0 and 1 both grey
    p0 = [(0, 0, 0), (255, 255, 255), (128, 128, 128)]
    p1 = [(128, 128, 128), (128, 128, 128), (128, 128, 128)]
    out = afp.per_tile_clut(info, [p0, p1], base_entry=0, ratio=1.0)
    assert out['per_code'] == {'1': 0, '2': 1}
    assert out['codes_by_entry']['1'] == [2]


def test_per_tile_clut_ratio_blocks_weak_improvements():
    hot = bytes([1 if (x + y) & 1 else 0 for y in range(16) for x in range(16)])
    info = {'cells': {2: hot}}
    p0 = [(0, 0, 0), (255, 255, 255), (128, 128, 128)]
    # entry 1 maps 0 -> (0,0,0) and 1 -> (250,250,250): only 2% better
    p1 = [(0, 0, 0), (250, 250, 250), (128, 128, 128)]
    out = afp.per_tile_clut(info, [p0, p1], base_entry=0, ratio=0.5)
    assert out['per_code'] == {'2': 0}


def test_region_boxes_groups_adjacent_hot_tiles():
    grid = [[1, 1, 0], [0, 1, 0], [0, 0, 1]]
    boxes = afp._region_boxes(grid, 3, 3)
    assert boxes[0]['tile_count'] == 3
    assert boxes[0]['tiles_x'] == [0, 1] and boxes[0]['tiles_y'] == [0, 1]
    assert boxes[1]['tile_count'] == 1


# ---------------------------------------------------------------------------
# real-corpus invariants (VB4_h0)
# ---------------------------------------------------------------------------
def _vb4():
    p = os.path.join(CORPUS, "02_AREA.B", "VB4.BIN")
    if not os.path.exists(p):
        return None, None
    with open(p, "rb") as fh:
        return p, fh.read()


def test_vb4_h0_header_shape():
    p, data = _vb4()
    if data is None:
        return
    hs = afp.list_headers(data)
    h0 = [x for x in hs if x[0] == 0]
    assert h0, "VB4.BIN header slot 0 must enumerate"
    i, po, w, h = h0[0]
    assert (po, w, h) == (0x9150, 40, 22)


def test_vb4_h0_room_blob_table_has_four_live_slots():
    p, data = _vb4()
    if data is None:
        return
    tbl, raws = afp.room_blob_table(data, 0x9150)
    live = [o for o, r in tbl if r is not None]
    assert len(tbl) == 8
    assert live == [0x918C, 0xC8A8, 0x102A4, 0x134BC]


def test_vb4_h0_tile_codes_reference_only_the_four_live_blobs():
    p, data = _vb4()
    if data is None:
        return
    hs = {i: (po, w, h) for i, po, w, h in afp.list_headers(data)}
    po, w, h = hs[0]
    tm = struct.unpack_from("<I", data, po + 0x14)[0] - RAM_BASE
    tiles = struct.unpack_from("<%dH" % (w * h), data, tm)
    assert max(tiles) // 64 == 3
    assert sorted(set(t // 64 for t in tiles)) == [0, 1, 2, 3]


def test_vb4_h0_water_codes_are_colour_step_outliers():
    p, data = _vb4()
    if data is None:
        return
    hs = {i: (po, w, h) for i, po, w, h in afp.list_headers(data)}
    po, w, h = hs[0]
    pals, _tbl = afp.clut_palettes(data, po)
    pal = pals[0]
    blobs = [r for _, r in afp.room_blob_table(data, po)[0]]
    tm = struct.unpack_from("<I", data, po + 0x14)[0] - RAM_BASE
    tiles = struct.unpack_from("<%dH" % (w * h), data, tm)
    steps = {}
    for c in sorted(set(tiles)):
        steps[c] = afp.colour_step(afp.cell_of(blobs, c), pal)
    med = afp._median(list(steps.values()))
    # The four codes that make the complaint regions are all >= 2x the room
    # median: that is the measurement the whole diagnosis rests on.
    for c in (1, 2, 3, 4):
        assert steps[c] >= 2.0 * med, (c, steps[c], med)
    # and a code from the room's coherent floor is not
    assert steps[125] < 2.0 * med


def test_vb4_h0_frame_candidates_are_the_water_ladder():
    p, data = _vb4()
    if data is None:
        return
    hs = {i: (po, w, h) for i, po, w, h in afp.list_headers(data)}
    po, w, h = hs[0]
    pals, _tbl = afp.clut_palettes(data, po)
    blobs = [r for _, r in afp.room_blob_table(data, po)[0]]
    rep, _info = afp.analyse_room(data, 0, po, w, h, pals[0])
    cand = sorted((l['code_a'], l['code_b']) for l in rep['ladders']
                  if l['is_frame_candidate'])
    assert (1, 2) in cand and (2, 3) in cand and (3, 4) in cand
    # all three complaint regions must be found as high-contrast boxes
    boxes = rep['regions']
    assert any(b['tiles_x'][0] == 0 and b['tiles_y'][0] == 0 for b in boxes)
    assert any(b['tiles_x'][0] >= 30 and b['tiles_y'][0] == 0 for b in boxes)
    assert any(b['tiles_x'][0] >= 30 and b['tiles_y'][0] >= 16 for b in boxes)


def test_vb4_h0_blob_order_agrees_with_global_list():
    p, data = _vb4()
    if data is None:
        return
    blobs = afp.find_blobs_global(data)
    offs = [o for o, _ in blobs]
    # For this file the renderers' global, offset-sorted list starts with the
    # room's own four blobs in the same order -- the blob-index defect does not
    # reach VB4_h0.
    assert offs[:4] == [0x918C, 0xC8A8, 0x102A4, 0x134BC]


def test_probe_has_no_write_path_under_area_tiles():
    """The tool must not be able to write into the reviewed render tree."""
    with open(os.path.join(KIT, "tools", "area_frame_probe.py")) as fh:
        src = fh.read()
    write_terms = [".save(", "open(", "makedirs("]
    for term in write_terms:
        for line in src.splitlines():
            if term in line and "area_tiles" in line:
                raise AssertionError("write path into area_tiles: %s" % line)


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
