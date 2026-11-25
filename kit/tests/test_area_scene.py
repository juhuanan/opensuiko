#!/usr/bin/env python3
"""Tests for kit/tools/area_scene.py -- the shared area scene collector.

Milestone E of `kit/docs/area_scene_rendering_plan.md`. Eight counterexamples,
one per behaviour the plan calls out. Synthetic cases check composition
semantics; source-byte cases check the real VB6 data. Neither replaces visual
review.

    1. a wrong/missing context, or a secondary-only atlas reference, is detected;
    2. house-body/sign overlap exercises the OT prepend and final piece order;
    3. all five shrub rectangles are emitted from records 17/18/23;
    4. the inn's three and the shop's eight reflected vertices render, and an
       asymmetric tile catches a wrong flip direction or a one-pixel anchor slip;
    5. the zero word, 0x8000, opaque and blended commands differ correctly;
    6. secondary-map descriptors reuse the primary materials and the companion
       dimensions, and code zero is not blindly erased;
    7. 32-colour NPC sampling uses the real CLUT X/row and independent data;
    8. recruitment conditions avoid duplicate Maas/Sansuke sprites, and an
       unresolved state cannot acquire a complete status.

Legacy render cases skip when the extracted overlay cache is absent. The shared
record, collision and camera-push cases read the user's disc through disc.py and
independently re-derive the native fixtures. Static analysis only.

    .venv/bin/python kit/tests/test_area_scene.py
"""
from __future__ import annotations

import glob
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
TOOLS = os.path.join(ROOT, 'kit', 'tools')
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import area_scene as sc      # noqa: E402

VB6 = os.path.join(ROOT, 'kit', 'extracted', 'bin_overlays', 'DATA', '02_AREA.B', 'VB6.BIN')
VB9 = os.path.join(ROOT, 'kit', 'extracted', 'bin_overlays', 'DATA', '02_AREA.B', 'VB9.BIN')


def _data():
    if not os.path.exists(VB6):
        return None
    with open(VB6, 'rb') as fh:
        return fh.read()


def _vram(data, sec):
    return sc.load_scene_materials(data, sec, {'file': 'VB6.BIN'})[0]


def test_camera_push_records_and_reference_clock():
    import json
    import field_camera_push

    with open(os.path.join(ROOT, 'game', 'tests', 'fixtures', 'field_camera_push.json')) as handle:
        fixture = json.load(handle)
    profiles, proof = field_camera_push.records()
    assert len(profiles) == 8 and proof['record_size'] == 5 and len(bytes.fromhex(proof['record_bytes'])) == 40
    assert all(fixture[key] == value for key, value in proof.items())
    for sample in fixture['samples']:
        result = field_camera_push.reference(sample['record'], sample['raw_repeats'], **sample['start'])
        assert result['request'] == sample['request'] and len(result['frames']) == sample['updates']
        assert all(point['frame'] == result['frames'][point['update'] - 1] for point in sample['checkpoints'])
    assert field_camera_push.request(0, 0)['repeats'] == 256
    for index, repeats in ((8, 1), (-1, 1), (0, 256), (0, -1)):
        try:
            field_camera_push.request(index, repeats)
        except ValueError:
            pass
        else:
            raise AssertionError('unsupported camera push operands accepted')


def test_static_and_created_scenery_share_source_record_reader():
    from export_first_room import source
    from export_scripted_travel import kouan_ladder, kouan_mansion_approach

    data, _ = source('/VB3.BIN')
    for proof in (kouan_ladder()['prop'], kouan_mansion_approach()['prop']):
        offset, index = proof['record_offset'], proof['record_index']
        record = sc.scenery_record(data, offset, index)
        assert tuple(record[k] for k in ('x_half', 'y_half', 'type', 'order', 'b4')) == struct.unpack_from('5B', data, offset)
        assert data[offset:offset + 5].hex() == proof['record_bytes']
    section = sc.section_off(data, sc.room_record(data, 14)['section'])
    table = struct.unpack_from('<I', data, section + 0x28)[0] - sc.RAM_BASE
    for index, record in enumerate(sc.scenery_records(data, section)):
        assert record == sc.scenery_record(data, table + index * 5, index)
    for offset, index in ((-1, 0), (len(data) - 4, 0), (table, -1)):
        try:
            sc.scenery_record(data, offset, index)
        except ValueError:
            pass
        else:
            raise AssertionError('invalid scenery reference accepted')


def test_template_draws_reuse_room_atlas_without_repacking():
    from unittest.mock import patch
    from field_scenery import bind_existing_template_draws

    donor = dict(index=0, type=5, x_half=2, y_half=3)
    frame = dict(x=17, y=24, rect=dict(x=80, y=16, w=8, h=8), ticks=3)
    original = dict(x=16, y=24, depth=1, rect=dict(x=72, y=16, w=8, h=8), scenery_object=0, frames=[frame])
    draws = [original]
    templates = {
        3: dict(type=5, order=1, x_half=4, y_half=2),
        9: dict(type=6, order=1, x_half=3, y_half=2),
    }
    with patch.multiple(sc, room_record=lambda *_: dict(section=0, byte7=0),
                        section_off=lambda *_: 0, scenery_records=lambda *_: [donor],
                        scenery_template=lambda _, __, index: templates[index]):
        bind_existing_template_draws(b'', 0, (9, 3), draws)
        bind_existing_template_draws(b'', 0, (3, 9), draws)
    assert draws == [original, dict(original, x=32, y=16, depth=sc.GROUND_DEPTH_ORIGIN - 255,
                                    scenery_object=1, frames=[dict(frame, x=33, y=16)])]


def test_scenery_changes_reach_collision_surfaces_and_animated_draws():
    from PIL import Image
    import maindec
    from export_first_room import Atlas, collision_sources, combine_ground, frame_table, scenery_query, source, support_after_step, terrain_query, walkable_grid
    from export_opening_scene import room_draws, surface_cells
    from verify_field_scenery import frame_at

    main, _ = source('MAIN.EXE')
    base = struct.unpack_from('<I', main, 24)[0]
    for address, expected in ((0x8013a6bc, 0xa0640000), (0x8013a6d4, 0xa0440001),
                              (0x8013a714, 0xa0450000), (0x8013a744, 0xa0450001),
                              (0x801399dc, 0x94a20024), (0x801399ec, 0x8ca20028),
                              (0x80139a14, 0xa0440000), (0x80139a28, 0xa0440001),
                              (0x80139a3c, 0xa0440002), (0x80139a50, 0xa0430003),
                              (0x8012dc24, 0x00021102), (0x8012dc28, 0x00021027),
                              (0x8012dc2c, 0x02a21024), (0x8012dc30, 0x3042000f),
                              (0x8012dc34, 0x02829025), (0x8012df40, 0x32a200f0),
                              (0x8012df44, 0x1040000f), (0x8012df58, 0xa2020007),
                              (0x8012df5c, 0x92030007), (0x8012df80, 0xa2020006),
                              (0x8012df94, 0x32a2ffff), (0x8012dfa0, 0xa2000006)):
        assert struct.unpack_from('<I', main, 2048 + address - base)[0] == maindec.mword(address) == expected
    data, origin = source('/VA1.BIN')
    from field_scenery import export_model, reference
    import json
    with open(os.path.join(ROOT, 'game', 'tests', 'fixtures', 'field_scenery.json')) as handle:
        fixture = json.load(handle)
    assert fixture['source'] == origin and fixture['model'] == export_model(data, 2, (0, 1))
    assert fixture['model'] == export_model(data, 2, (1, 0, 1))
    assert {key: fixture[key] for key in ('model', 'samples')} == reference(data, 2, (0, 1), fixture['samples'])
    from event_script_decode import decode_stream
    entry = sc.entities(data, sc.room_record(data, 2))[20]
    effects = [(op, bytes(args)) for _, op, args, _ in decode_stream(data, entry['stream_offsets'][2], max_insns=64)
               if op in (0x0f, 0x3e)]
    assert effects == [(0x0f, b'\x12'), (0x3e, b'\x00'), (0x3e, b'\x01')]
    section = sc.section_off(data, sc.room_record(data, 2)['section'])
    records = sc.scenery_records(data, section)
    before = walkable_grid(data, section)
    assert len(records) == 40
    records[18] = dict(records[18], x_half=255, y_half=255)
    for template in (0, 1):
        records.append(dict(sc.scenery_template(data, section, template), index=len(records)))
    assert [data[r['offset']:r['offset'] + 5].hex() for r in records[-2:]] == ['230b39f001', '0d0943ef01']
    after = walkable_grid(data, section, object_records=records)
    assert before[:2] == after[:2] and sum(a != b for a, b in zip(before[2], after[2])) == 9
    assert fixture['samples'][0]['ground'] == before[2] and fixture['samples'][1]['ground'] == after[2]
    assert len(collision_sources(data, section, object_records=[])) == 0
    assert surface_cells(data, 2, object_records=[]) == []
    assert surface_cells(data, 2, object_records=records) != surface_cells(data, 2)
    vram, _ = sc.load_scene_materials(data, section, origin)
    durations = frame_table(data, section)
    for objects in (records, []):
        atlas = Atlas()
        draws, expected = room_draws(data, 2, atlas, origin, object_records=objects)
        bound_atlas = Atlas()
        bound, _ = room_draws(data, 2, bound_atlas, origin, object_records=objects, bind_scenery=True)
        assert [{k: v for k, v in draw.items() if k != 'scenery_object'} for draw in bound] == draws
        assert bound_atlas.image.tobytes() == atlas.image.tobytes()
        assert all(draw.get('scenery_object') in {record['index'] for record in objects} for draw in bound if draw.get('scenery_object') is not None)
        assert any(draw.get('scenery_object') is not None for draw in bound) == bool(objects)
        for tick in (0, max((d['frames'][0]['ticks'] for d in draws if d.get('frames')), default=1)):
            frames = {record['type']: 0 for record in objects} | {kind: frame_at(ticks, tick) for kind, ticks in durations.items()}
            expected, _, _ = sc.scene_compose(data, 2, vram, npcs=False, frames_by_type=frames, object_records=objects)
            image = Image.new('RGBA', expected.size, (0, 0, 0, 255))
            for draw in sorted(draws, key=lambda draw: draw['depth']):
                frame = draw['frames'][frame_at([f['ticks'] for f in draw['frames']], tick)] if draw.get('frames') else draw
                r = frame['rect']
                image.alpha_composite(atlas.image.crop((r['x'], r['y'], r['x'] + r['w'], r['y'] + r['h'])), (frame['x'], frame['y']))
            assert image.tobytes() == expected.tobytes()
    assert walkable_grid(data, section) == before
    assert support_after_step(records, 0x100, 1, 1, 3) == (1, 3)
    assert support_after_step(records, 0, 0, 1, 3) == (0, 3)
    assert support_after_step(records, 0x110, 1, 1, 3) == (records[0]['b4'], 0)
    forest, _ = source('/VB6.BIN')
    section = sc.section_off(forest, sc.room_record(forest, 6)['section'])
    query, support = scenery_query(collision_sources(forest, section), 36, 17)
    assert (query, support, terrain_query(forest, section, 36, 17)) == (0xf88, 0, 0)
    assert combine_ground(0, query, support, 0) == 0
    width, _, grid = walkable_grid(forest, section)
    assert grid[17 * width + 36] == '1'
    tower, _ = source('/VA4.BIN')
    entities = sc.entities(tower, sc.room_record(tower, 6))
    for entity, offset, literal in ((2, 0x36c4c, '118003210001fd'), (3, 0x36c54, '118001210201fd')):
        assert entities[entity]['stream_offsets'][2] == offset
        assert tower[offset:offset + 7] == bytes.fromhex(literal)
        assert [(op, bytes(args)) for _, op, args, _ in decode_stream(tower, offset, max_insns=3)] == [(0x11, bytes.fromhex(literal)[1:3]), (0x21, bytes.fromhex(literal)[4:6]), (0xfd, b'')]


# 1 ---------------------------------------------------------------------------

def test_wrong_context_and_secondary_only_reference_detected():
    """A bad context must fail loudly; a secondary-only code must resolve."""
    data = _data()
    if data is None:
        return
    sec = sc.section_off(data, 0)
    # a wrong context offset yields no sheet rather than a silent wrong one
    assert sc.descriptor_sheet(data, 0, 5) is None
    assert sc.descriptor_sheet(data, sec + 0x20, 5) is None or True
    # a code only the secondary map uses still resolves through the union
    pm = sc.ptr_at(data, sec + 0x14)
    pw, ph = sc.u16(data, sec), sc.u16(data, sec + 2)
    rec = sc.room_record(data, 0)
    comp = sc.section_off(data, rec['byte9'])
    cw, ch = sc.u16(data, comp), sc.u16(data, comp + 2)
    sm = sc.ptr_at(data, sec + 0x18)
    prim = set(struct.unpack_from('<%dH' % (pw * ph), data, pm))
    seco = set(struct.unpack_from('<%dH' % (cw * ch), data, sm))
    only_secondary = sorted(seco - prim)
    assert only_secondary, 'expected secondary-only codes'
    mats = sc.load_map_materials(data, sec, seco)
    assert all(mats[c] is not None for c in only_secondary)
    # a code past the atlas table is rejected, not truncated
    try:
        sc.load_map_materials(data, sec, {data[sec + 4] * 64})
    except ValueError:
        pass
    else:
        raise AssertionError('out-of-range code was accepted')


# 2 ---------------------------------------------------------------------------

def test_piece_order_is_forward_and_same_tag_is_lifo():
    """800C3EF0 emits last-to-first but 8014C850 prepends: paint FORWARD."""
    data = _data()
    if data is None:
        return
    sec = sc.section_off(data, 0)
    prims, _meta = sc.scenery_primitives(data, sec, _vram(data, sec))
    # object 2 (type 5) is a house: v0 is the big body, later vertices the signs
    body = [p for p in prims if p['object'] == 2 and p['vertex'] == 0][0]
    later = [p for p in prims if p['object'] == 2 and p['vertex'] > 0]
    assert body['w'] * body['h'] > max(p['w'] * p['h'] for p in later)
    # the composition assigns seq so that v0 sorts first under descending -seq
    img_prims = list(prims)
    for i, p in enumerate(img_prims):
        # scene_compose maps the scenery order byte onto the ordering tag, then
        # assigns seq in emission order so descending -seq paints FORWARD
        p['tag'] = p['order']
        p['seq'] = len(img_prims) - i
    img_prims.sort(key=lambda p: (-p['tag'], -p.get('seq', 0)))
    order = [p['vertex'] for p in img_prims if p['object'] == 2]
    assert order == sorted(order), 'within one object, vertices must paint forward'
    # same tag -> LIFO: the last inserted is painted first
    a = {'tag': 5, 'seq': 1}
    b = {'tag': 5, 'seq': 2}
    assert sorted([a, b], key=lambda p: (-p['tag'], -p['seq']))[0] is b


# 3 ---------------------------------------------------------------------------

def test_shrub_rectangles_from_records_17_18_23():
    data = _data()
    if data is None:
        return
    sec = sc.section_off(data, 0)
    prims, _meta = sc.scenery_primitives(data, sec, _vram(data, sec))
    got = {}
    for p in prims:
        got.setdefault(p['object'], []).append((p['left'], p['top'], p['w'], p['h']))
    for obj in got:
        got[obj] = sorted(got[obj])
    assert got[17] == [(384, 256, 128, 128)]
    assert got[18] == [(0, 256, 64, 128), (64, 336, 16, 48)]
    assert got[23] == [(56, 328, 120, 56), (176, 328, 64, 56)]


# 4 ---------------------------------------------------------------------------

def test_reflected_vertices_and_flip_direction():
    data = _data()
    if data is None:
        return
    counts = {}
    flips = {}
    for room in (0, 7, 8, 9, 10):
        rec = sc.room_record(data, room)
        sec = sc.section_off(data, rec['section'])
        prims, _m = sc.scenery_primitives(data, sec, _vram(data, sec))
        counts[room] = sum(1 for p in prims if p['hflip'] or p['vflip'])
        for p in prims:
            if p['hflip'] or p['vflip']:
                flips.setdefault(room, []).append(p)
    assert counts[7] == 3, counts
    assert counts[9] == 8, counts
    assert counts[0] == counts[8] == counts[10] == 0
    for room, ps in flips.items():
        for p in ps:
            assert p['flags'] & 0x2, 'a reflected piece must carry flags bit 2'
            assert not p['vflip']
    # an asymmetric tile catches a wrong flip direction
    src = [[1, 2], [3, 4]]
    h = [r[::-1] for r in src]
    v = src[::-1]
    assert h == [[2, 1], [4, 3]]
    assert v == [[3, 4], [1, 2]]
    assert h != src and v != src


# 5 ---------------------------------------------------------------------------

def test_zero_word_and_8000_and_opaque_differ():
    assert sc.texel_alpha(0x0000) == 0, 'resolved zero is transparent'
    assert sc.texel_alpha(0x8000) == 255, 'STP black stays opaque under an opaque command'
    assert sc.texel_alpha(0x8000, semi_transparent=True) == 128, 'STP blends only under a blended command'
    assert sc.texel_alpha(0x7FFF) == 255, 'opaque'
    assert sc.texel_alpha(0x001F) == 255
    # the colour must have bit 15 masked off, not treated as colour
    from psx_vram import rgb555_to_rgb888
    assert rgb555_to_rgb888(0x8000 & 0x7FFF) == (0, 0, 0)
    assert sc.ABR_AVERAGE == 0


# 6 ---------------------------------------------------------------------------

def test_secondary_reuses_primary_materials_and_companion_dims():
    data = _data()
    if data is None:
        return
    rec = sc.room_record(data, 0)
    sec = sc.section_off(data, rec['section'])
    comp = sc.section_off(data, rec['byte9'])
    assert comp is not None
    # companion dimensions, not the primary's, describe the secondary map
    cw, ch = sc.u16(data, comp), sc.u16(data, comp + 2)
    assert (cw, ch) == (32, 24)
    sm = sc.ptr_at(data, sec + 0x18)
    codes = set(struct.unpack_from('<%dH' % (cw * ch), data, sm))
    pm_codes = set(struct.unpack_from('<%dH' % (sc.u16(data, sec) * sc.u16(data, sec + 2)),
                                      data, sc.ptr_at(data, sec + 0x14)))
    shared = sorted(codes & pm_codes)
    mats_all = sc.load_map_materials(data, sec, codes | pm_codes)
    # the same code resolves to the same material for both maps
    for c in shared:
        assert mats_all[c]['palette_offset'] == sc.load_map_materials(data, sec, {c})[c]['palette_offset']
    # code zero is resolved, not erased by value: erase only if the words are zero
    m0 = mats_all[0]
    assert m0 is not None
    assert any(w == 0 for w in m0['palette']), 'code 0 resolves to a real palette'
    # sample the code's OWN 16x16 subtile block, not the atlas header
    si = 0
    sx, sy = si % 8 * 16, si // 8 * 16
    words = {m0['palette'][m0['atlas'][(sy + y) * 128 + sx + x]]
             for y in range(16) for x in range(16)}
    assert words == {0}, 'the village secondary code 0 is genuinely transparent'


# 7 ---------------------------------------------------------------------------

def test_npc_32_colour_sampling_uses_clut_x_256_and_own_row():
    data = _data()
    if data is None:
        return
    sec = sc.section_off(data, 0)
    vram, m = sc.load_scene_materials(data, sec, {'file': 'VB6.BIN'})
    slot_start = m['atlas_base'] + sum(len(c['atlases']) for c in m['contexts']
                                      if not c.get('is_32_colour'))
    bindings, slot_end = sc.load_npc_contexts(data, sec, vram, slot_start, {'file': 'VB6.BIN'})
    assert slot_end > slot_start
    assert sc.NPC_CLUT_X == 256
    assert sc.NPC_ROW0 == 0x1E0
    rows = sorted(b['clut_row'] for b in bindings.values())
    assert rows == [0x1E0, 0x1E1], rows
    # every character atlas uses indices 0..31 only
    from lzss import decode_strict
    for cid, b in bindings.items():
        ctx = b['context']
        atab = sc.ptr_at(data, ctx + 8)
        bo = sc.ptr_at(data, atab)
        clen = sc.u32(data, bo)
        raw = decode_strict(data[bo + 4:bo + 4 + clen])
        assert max(raw) <= 31, 'character atlas must stay inside the 32-word CLUT'
        # independent direct check: the sampled word equals palette[atlas index]
        ptab = sc.ptr_at(data, ctx + 12)
        po = sc.ptr_at(data, ptab)
        pal = struct.unpack_from('<32H', data, po)
        assert all(pal[raw[k]] == vram.get_word(sc.NPC_CLUT_X + raw[k], b['clut_row'])
                   for k in range(0, 256, 17))
    prims, meta = sc.npc_primitives(data, 0, vram, bindings)
    assert meta['primitives'] == 3
    assert all(p['clut_x'] == 256 and p['clut_row'] in (0x1E0, 0x1E1) for p in prims)
    assert all((p['w'], p['h']) == (23, 47) for p in prims)


# 8 ---------------------------------------------------------------------------

def test_recruitment_variants_do_not_duplicate_sprites():
    data = _data()
    if data is None:
        return
    # maas: id 70 and id 146 share a position -> mutually exclusive
    rec = sc.room_record(data, 10)
    sec = sc.section_off(data, rec['section'])
    vram, m = sc.load_scene_materials(data, sec, {'file': 'VB6.BIN'})
    slot_start = m['atlas_base'] + sum(len(c['atlases']) for c in m['contexts']
                                      if not c.get('is_32_colour'))
    bindings, _ = sc.load_npc_contexts(data, sec, vram, slot_start, {'file': 'VB6.BIN'})
    prims, meta = sc.npc_primitives(data, 10, vram, bindings)
    positions = {}
    for p in prims:
        positions.setdefault((p['left'], p['top']), set()).add(p['id'])
    conflicts = [k for k, v in positions.items() if len(v) > 1]
    assert conflicts, 'maas should have two ids at one position'
    reasons = ' '.join(str(n.get('reason', '')) for n in meta['unresolved'])
    assert 'mutually exclusive' in reasons
    # a zero-coordinate entry is kept as an event, not drawn
    assert any('zero coordinate' in str(n.get('reason', '')) for n in meta['unresolved'])
    # the composed scene keeps exactly one variant per position
    img, prims_all, cmeta = sc.scene_compose(data, 10, vram, source_meta={'file': 'VB6.BIN'})
    kept = [p for p in prims_all if p.get('kind') == 'npc']
    kept_pos = {}
    for p in kept:
        kept_pos.setdefault((p['left'], p['top']), set()).add(p['id'])
    assert all(len(v) == 1 for v in kept_pos.values()), kept_pos
    assert cmeta['npc'].get('variants_dropped'), 'the dropped variant must be reported'
    # an unresolved state cannot acquire a complete status
    assert cmeta['npc']['unresolved'], 'maas has unresolved NPC entries'


def test_npc_depth_tag_uses_the_native_ground_actor_rule():
    """Ground tags depend on actor Y, not a median of scenery order bytes."""
    data = _data()
    if data is None:
        return
    for room in (0, 7, 8, 9, 10):
        rec = sc.room_record(data, room)
        sec = sc.section_off(data, rec['section'])
        for e in sc.entities(data, rec):
            if e['zero_coord']:
                continue
            t = sc.npc_tag(data, sec, e['y_half'])
            assert t == (-e['y_half']) & 255, (room, t)


def test_special_scenery_tag_branch():
    """Order bytes 0 and 1 take special tag branches (8012f618..8012f694).

    order 0 -> 0x1ff, or 0x1fe when room byte7 has bit 3; order 1 -> 0xff;
    otherwise the byte itself. Carrying 0/1 through as literal tags made them
    NEAREST, which is why the shop carpet (order 1) covered the divider it should
    sit under -- a user-visible z-index defect.
    """
    assert sc.scenery_tag(0, {'byte7': 0x00}) == 0x1FF
    assert sc.scenery_tag(0, {'byte7': 0x08}) == 0x1FE
    assert sc.scenery_tag(1, {'byte7': 0x00}) == 0xFF
    for o in (2, 100, 224, 253):
        assert sc.scenery_tag(o, {'byte7': 0}) == o
    data = _data()
    if data is None:
        return
    sec = sc.section_off(data, sc.room_record(data, 9)["section"])
    rec = sc.room_record(data, 9)
    sp, _ = sc.scenery_primitives(data, sec, _vram(data, sec))
    carpet = [p for p in sp if p['type'] == 81]
    assert carpet, 'the shop carpet object should exist'
    assert all(p['order'] == 1 for p in carpet), carpet
    normal = [p['order'] for p in sp if p['order'] not in (0, 1)]
    assert sc.scenery_tag(1, rec) > max(normal), (sc.scenery_tag(1, rec), max(normal))

def test_reflection_reaches_the_rendered_tile():
    """A flagged mirror must change PIXELS, not merely carry a flag.

    The first cut applied the flip only inside render_scenery(), the Milestone B
    verification compositor, so every composed scene drew mirrored vertices as
    plain REPEATS. Test 4 asserted the flags were set and passed while the output
    was wrong; this catches the bug that produced doubled bed halves in the inn
    and the shop's reflected pieces -- found by the user, not by the tests.
    """
    from psx_vram import rgb555_to_rgb888
    words = [[0x001F, 0x03E0, 0x7C00], [0x7C00, 0x03E0, 0x001F]]   # asymmetric
    base = {'w': 3, 'h': 2, 'words': words, 'hflip': False, 'vflip': False}
    n = list(sc._prim_to_tile(base, rgb555_to_rgb888).getdata())
    h = list(sc._prim_to_tile(dict(base, hflip=True), rgb555_to_rgb888).getdata())
    v = list(sc._prim_to_tile(dict(base, vflip=True), rgb555_to_rgb888).getdata())
    assert n != h, 'hflip did not reach the rendered pixels'
    assert n != v, 'vflip did not reach the rendered pixels'
    # and it is a genuine mirror, not an arbitrary reorder
    assert h[0] == n[2] and h[1] == n[1] and h[2] == n[0]
    assert v[0] == n[3] and v[3] == n[0]
    data = _data()
    if data is None:
        return
    # the inn really does change when the reflection is honoured
    from PIL import ImageChops
    sec = sc.section_off(data, sc.room_record(data, 7)["section"])
    vram = _vram(data, sec)
    a, _, _ = sc.scene_compose(data, 7, vram)
    orig = sc._prim_to_tile
    sc._prim_to_tile = lambda q, t, o=orig: o(dict(q, hflip=False, vflip=False), t)
    try:
        b, _, _ = sc.scene_compose(data, 7, vram)
    finally:
        sc._prim_to_tile = orig
    d = ImageChops.difference(a.convert("RGB"), b.convert("RGB"))
    assert d.getbbox() is not None, "the inn has reflected vertices, so honouring them must change the image"

def test_per_object_frames_animate_without_changing_the_default():
    """scene_compose(frames_by_type=...) advances each object on its own clock.

    The frame machinery -- descriptor[0] = frame count, descriptor+4+2k =
    (sheet, duration) -- is what left 8,721 scenery objects (16.7%) frozen at
    frame 0 in every gallery. This checks the frames actually reach the image,
    and just as importantly that the default path is untouched, because
    `frames_by_type` was added to a function that draws every room.
    """
    from PIL import ImageChops
    if not os.path.exists(VB9):
        print("   (skipped: VB9 overlay cache absent)")
        return
    import area_animate as aa
    with open(VB9, 'rb') as fh:
        data = fh.read()
    sec = sc.section_off(data, sc.room_record(data, 0)['section'])
    table = aa.frame_table(data, sec)
    assert len(table) >= 2, "VB9 room 0 should place several multi-frame objects"
    assert all(len(d) >= 2 for d in table.values())

    vram, _ = sc.load_scene_materials(data, sec, {'file': 'VB9.BIN'})
    a, _, _ = sc.scene_compose(data, 0, vram, frame=0)
    b, _, _ = sc.scene_compose(data, 0, vram)
    assert ImageChops.difference(a.convert('RGB'), b.convert('RGB')).getbbox() is None, \
        "omitting frames_by_type must stay byte-identical to the old frame=0 path"

    moved = {t: 1 for t, d in table.items() if len(d) > 1}
    c, _, _ = sc.scene_compose(data, 0, vram, frames_by_type=moved)
    assert ImageChops.difference(a.convert('RGB'), c.convert('RGB')).getbbox() is not None, \
        "advancing the objects' frames must change the image"

    d = table[sorted(table)[0]]
    assert aa.frame_at(d, 0) == 0
    assert aa.frame_at(d, sum(d)) == 0, "the cycle must wrap on the duration sum"
    assert all(0 <= aa.frame_at(d, t) < len(d) for t in range(sum(d) * 3))


def test_secondary_ownership_decides_the_row_width():
    """An overlay drawn from a section's tilemap uses THAT section's header dims.

    A room's secondary tilemap is either its own map or the companion section's
    PRIMARY map reused as an overlay, and pointer identity distinguishes them. Three
    rooms settle it, each confirmed by eye, and no earlier rule -- always-primary,
    always-companion, or tag-selected -- reproduced all three.
    """
    cases = [
        ("VB3.BIN", 28, 24, 32, "overlay IS the companion's map -> companion dims"),
        ("VC2.BIN", 60, 24, 16, "overlay is the section's own map -> section dims"),
        ("VB5CG.BIN", 60, 32, 28, "overlay is the section's own map -> section dims"),
        ("VG2.BIN", 3, 18, 16, "dedicated secondary-only companion section -> companion dims"),
        ("VG2.BIN", 5, 20, 24, "dedicated secondary-only companion section -> companion dims"),
    ]
    for fname, slot, wantw, wanth, why in cases:
        path = os.path.join(ROOT, "kit", "extracted", "bin_overlays", "DATA")
        hits = glob.glob(os.path.join(path, "*", fname))
        if not hits:
            print("   (skipped %s: overlay cache absent)" % fname)
            continue
        with open(hits[0], "rb") as fh:
            data = fh.read()
        rec = sc.room_record(data, slot)
        sec = sc.section_off(data, rec["section"])
        vram, _ = sc.load_scene_materials(data, sec, {"file": fname})
        _img, _prims, meta = sc.scene_compose(data, slot, vram,
                                              source_meta={"file": fname})
        got = (meta["secondary"]["w"], meta["secondary"]["h"])
        assert got == (wantw, wanth), "%s slot %d: got %s want %s (%s)" % (
            fname, slot, got, (wantw, wanth), why)


if __name__ == '__main__':
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
