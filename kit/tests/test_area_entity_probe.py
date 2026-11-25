#!/usr/bin/env python3
"""Tests for kit/tools/area_entity_probe.py -- the area entity/spawn layer probe.

Follow-up to `kit/docs/area_draw_coverage.md` rounds 14-16. `VB6_h0`
shows four black 16x16 squares: cells whose tile code is 0, resolving to atlas 0
/ subtile 0, whose 256 indices are all zero (a *solid* block of palette index 0,
which our renderer paints black). Review objected that only those four cells look
that way, mid-field, and asked whether an entity/script layer places something
there.

The field layout is NOT re-derived here -- it is taken from
`kit/docs/sprite_placement.md` section 2.3, which documents it with
proving instructions:

    +0x00 u16  X            (8-pixel / half-tile units)
    +0x02 u16  Y            (8-pixel / half-tile units)
    +0x04 u16  flags        flags & 0x60  -> walker entity
                            flags & 0x101 -> interaction/tile path (chest, door, NPC)
    +0x06 u16  id           passed to 0x801346a8
    +0x0C u32  pointer to a 0x06-delimited byte-triple stream
    +0x10/+0x14 u32 per-entry data pointers

and the room record's count is a **u8** at `+4` (`lbu ...+4`).

What this file pins:

  1. the room-record count really is a u8 -- reading it as u16 produced the
     VB2.BIN record-8 anomaly of 0x1002 = 4098, whose true count is 2;
  2. the entity field layout matches the doc (X/Y/flags/id/stream), and the
     entity class comes from FLAGS -- with the caveat that round 16's "refutation"
     of the naive `+0x0C != 0` rule was itself an artefact of the u16 count bug;
     under the correct u8 count that rule is plausible, and the finding that
     survives every selector is that the match rate stays near zero;
  3. code-0 "singleton" cells are genuinely isolated and partition the code-0 set;
  4. `VB6_h0`'s four cells are exactly (5,11), (9,15), (15,8), (25,15), and no
     entity sits *on* one -- but an interactive entity sits 2 half-tiles from
     cell (15,8)'s centre;
  5. the correlation is **weak, not conclusive**: few singleton cells in usable
     rooms have an interactive entity within 4 half-tiles, while many have their
     nearest entity 16+ half-tiles away. Pinned so it cannot silently drift into
     either "solved" or "refuted".

Depends on the extracted overlay cache (like every other area probe in this
tree); tests skip cleanly when it is absent. Static analysis only.

    .venv/bin/python kit/tests/test_area_entity_probe.py
"""
from __future__ import annotations

import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
TOOLS = os.path.join(ROOT, 'kit', 'tools')
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import area_entity_probe as aep      # noqa: E402

DATA = os.path.join(ROOT, 'kit', 'extracted', 'bin_overlays', 'DATA')


def _sample(limit=12):
    pats = [os.path.join(DATA, '02_AREA.B', 'V*.BIN'),
            os.path.join(DATA, '01_AREA.A', 'V*.BIN')]
    out = []
    for p in pats:
        out.extend(sorted(glob.glob(p)))
    return out[:limit]


def _load(fn, area='02_AREA.B'):
    p = os.path.join(DATA, area, fn)
    if not os.path.exists(p):
        return None, None
    with open(p, 'rb') as fh:
        return p, fh.read()


# ---------------------------------------------------------------- layout facts

def test_known_room_bound_preserves_records_after_sparse_gaps():
    import struct
    data = bytearray(2048)
    def word(off, target):
        struct.pack_into('<I', data, off, aep.RAM_BASE + target)
    word(0, 4); word(8, 64); word(12, 256); word(24, 416); word(64, 128)
    for index in range(10):
        off = 256 + index * 16
        word(off, 1024 + 24 * index)
        data[off + 4] = 1
        data[off + 5] = 0 if index in (0, 9) else 1
    assert [r['index'] for r in aep.room_records(data)] == [0, 9]
    struct.pack_into('<I', data, 24, 0)
    assert [r['index'] for r in aep.room_records(data)] == [0]

def test_room_probe_stops_before_following_text_root():
    import struct
    data = bytearray(256)
    def word(off, target):
        struct.pack_into('<I', data, off, aep.RAM_BASE + target)
    word(0, 4); word(8, 32); word(12, 64); word(24, 96); word(32, 128)
    for off, entries in [(64, 160), (80, 184), (96, 208)]:
        word(off, entries)
        data[off + 4] = 1
    assert aep.room_source_bound(data) == {
        'start': 64, 'upper_bound': 96, 'basis': 'following text-root object'}
    assert [r['index'] for r in aep.room_records(data)] == [0, 1]
    word(24, 60)
    assert aep.room_source_bound(data)['upper_bound'] is None
    assert aep.room_source_bound(b'') == {
        'start': None, 'upper_bound': None, 'basis': 'unresolved'}


def test_room_record_count_is_a_u8_not_u16():
    """VB2.BIN record 8 is the case that exposed reading +4 as u16.

    As u16 it reads 0x1002 = 4098, which is not a count. At the documented u8 it
    is 2. Pinned because the wrong width silently corrupted every correlation
    run before it was fixed.
    """
    path, data = _load('VB2.BIN')
    if data is None:
        return
    recs = aep.room_records(data)
    assert recs
    seen_anomaly = False
    for r in recs:
        assert 0 <= r['count'] <= aep.MAX_ENTITIES, r
        off = r['record_off']
        assert r['count'] == data[off + 4]
        if aep.u16(data, off + 4) > aep.MAX_ENTITIES:
            seen_anomaly = True
    assert seen_anomaly, 'VB2 no longer exhibits the u16/u8 anomaly'


def test_entity_layout_matches_documented_offsets():
    """The probe must read the doc's fields, not invented ones."""
    _, data = _load('VB6.BIN')
    if data is None:
        return
    rec = [r for r in aep.room_records(data) if r['section'] == 0][0]
    ents = aep.entities(data, rec)
    assert len(ents) == rec['count'] == 10
    for e in ents:
        o = e['off']
        assert e['x_half'] == aep.u16(data, o + 0x00)
        assert e['y_half'] == aep.u16(data, o + 0x02)
        assert e['flags'] == aep.u16(data, o + 0x04)
        assert e['id'] == aep.u16(data, o + 0x06)
        assert e['stream_ptr'] == aep.u32(data, o + 0x0c)
        assert e['stream_off'] == aep.to_file(data, e['stream_ptr'])
        assert e['walker'] == bool(e['flags'] & aep.FLAG_WALKER)
        assert e['interactive'] == bool(e['flags'] & aep.FLAG_INTERACT)


def test_correlation_is_near_zero_under_every_selector():
    """No plausible entity selector puts an entity on a singleton cell.

    NOTE the history, because it is a trap. Round 16 "refuted" the naive
    `+0x0C != 0` rule by measuring 595,053 placed entities over 653 rooms
    (~911/room). That was an ARTEFACT of reading the room-record count as u16:
    with the documented u8 count the naive rule yields only ~4/room, which is
    perfectly plausible. So the rule was never refuted -- the count width was
    wrong. Asserted here is the finding that actually matters and that survives
    every selector: the match rate stays near zero.
    """
    cells = 0
    matched = {'interactive': 0, 'walker': 0, 'either': 0, 'stream': 0, 'any': 0}
    per_room_naive = rooms = 0
    for path in aep.default_files():
        with open(path, 'rb') as fh:
            data = fh.read()
        for rec in aep.room_records(data):
            r = aep.correlate_room(data, rec)
            if r is None or not r['layer_ok'] or not r['singletons']:
                continue
            ents = aep.entities(data, rec)
            rooms += 1
            per_room_naive += sum(1 for e in ents if e['stream_ptr'] != 0)
            info = aep.code0_singletons(data, aep.section_off(data, rec['section']))
            sels = {
                'interactive': lambda e: e['interactive'],
                'walker': lambda e: e['walker'],
                'either': lambda e: e['walker'] or e['interactive'],
                'stream': lambda e: e['stream_ptr'] != 0,
                'any': lambda e: True,
            }
            for (c, rr) in info['singletons']:
                cells += 1
                box = (c * 2, rr * 2, c * 2 + 2, rr * 2 + 2)
                for label, sel in sels.items():
                    pool = [e for e in ents if sel(e)]
                    if any(box[0] <= e['x_half'] < box[2] and
                           box[1] <= e['y_half'] < box[3] for e in pool):
                        matched[label] += 1
    if cells == 0:
        return
    # the naive rule is plausible once the count is a u8 -- it was never refuted
    assert per_room_naive / float(rooms) < 64, (
        'naive per-room count is implausible again (%.0f) -- count width?'
        % (per_room_naive / float(rooms)))
    # and no selector explains the singleton cells
    for label, hits in matched.items():
        rate = 100.0 * hits / cells
        assert rate <= 5.0, (
            'selector %r now matches %.1f%% of singleton cells -- revisit the '
            'finding' % (label, rate))


# ------------------------------------------------------------- singleton cells

def test_singletons_are_isolated_and_partition_the_zero_set():
    for path in _sample(4):
        with open(path, 'rb') as fh:
            data = fh.read()
        for rec in aep.room_records(data):
            sec = aep.section_off(data, rec['section'])
            got = aep.tilemap_cells(data, sec)
            info = aep.code0_singletons(data, sec)
            if got is None or info is None:
                continue
            w, h, tiles = got
            zero = {(k % w, k // w) for k, t in enumerate(tiles) if t == 0}
            assert sum(info['components']) == len(zero)
            for (c, r) in info['singletons']:
                assert (c, r) in zero
                for nb in ((c + 1, r), (c - 1, r), (c, r + 1), (c, r - 1)):
                    assert nb not in zero, (path, rec['section'], (c, r), nb)


def test_vb6_h0_singleton_cells_are_the_four_squares():
    _, data = _load('VB6.BIN')
    if data is None:
        return
    info = aep.code0_singletons(data, aep.section_off(data, 0))
    assert info is not None
    assert (info['w'], info['h']) == (32, 24)
    assert info['zero'] == 4
    assert sorted(info['singletons']) == [(5, 11), (9, 15), (15, 8), (25, 15)]


def test_vb6_h0_no_entity_sits_on_a_singleton_cell_but_one_is_near():
    """The honest outcome: 0 hits, 1 interactive entity 2 half-tiles away."""
    _, data = _load('VB6.BIN')
    if data is None:
        return
    rec = [r for r in aep.room_records(data) if r['section'] == 0][0]
    r = aep.correlate_room(data, rec)
    assert r is not None
    assert r['layer_ok'] is True
    assert (r['singletons'], r['hits_strict'], r['misses']) == (4, 0, 3)
    # cell (15,8) centre is half-tile (31,17); trigger e7 sits at (33,17).
    # Under the DOCUMENTED +/-1 tile window that is the SAME feature (the trigger
    # is at tile (16,8), the cell at (15,8)), so hits == 1 is the door reading.
    ents = [e for e in aep.entities(data, rec) if e['interactive']]
    assert ents, 'VB6_h0 should have interactive entities'
    near = [e for e in ents
            if max(abs(e['x_half'] - 31), abs(e['y_half'] - 17)) <= 4]
    assert near, 'the near-miss that motivates the follow-up has moved'
    # the documented window turns exactly one of the four boxes into a match
    assert r['hits'] == 1, r


def test_documented_window_matches_only_a_minority_of_cells():
    """The door/trigger reading holds for a few cells, not as a rule.

    `transition_triggers.md` section 2b gives the trigger system a +/-1 tile
    tolerance window. Applying it lifts the singleton-cell match rate from the
    strict ~3% to ~6% -- so an adjacent interactive trigger explains SOME
    singleton cells (including one of VB6_h0's four boxes) and not the class.
    Pinned so neither an over-claim nor a dismissal can drift in.
    """
    cells = matched = strict = 0
    for path in aep.default_files():
        with open(path, 'rb') as fh:
            data = fh.read()
        for rec in aep.room_records(data):
            r = aep.correlate_room(data, rec)
            if r is None or not r['layer_ok'] or not r['singletons']:
                continue
            cells += r['singletons']
            matched += r['hits']
            strict += r['hits_strict']
    if cells == 0:
        return
    assert matched >= strict, 'the window must not match fewer than the strict box'
    rate = 100.0 * matched / cells
    assert 1.0 <= rate <= 20.0, (
        'documented-window match rate is %.1f%% -- revisit the finding' % rate)


def test_implausible_records_are_never_used_for_correlation():
    for path in _sample(4):
        with open(path, 'rb') as fh:
            data = fh.read()
        assert aep.section_table_span(data) >= 1, path
        for r in aep.room_records(data):
            sec = aep.section_off(data, r['section'])
            assert sec is not None, (path, r)
            assert r['ent_off'] is None or aep.in_file(data, r['ent_off'], 1)
            ok, why = aep.entity_layer_ok(data, r, aep.room_dims(data, sec))
            if r['count'] > aep.MAX_ENTITIES:
                assert not ok, (path, r, why)


def test_correlate_room_is_well_formed():
    for path in _sample(4):
        with open(path, 'rb') as fh:
            data = fh.read()
        for rec in aep.room_records(data):
            r = aep.correlate_room(data, rec)
            if r is None:
                continue
            assert r['hits'] + r['misses'] == r['singletons']
            assert r['singletons'] <= r['zero']
            if not r['layer_ok']:
                assert r['placed'] == 0


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
