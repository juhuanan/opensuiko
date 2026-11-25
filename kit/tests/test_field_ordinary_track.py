"""VAA ordinary actor queue against the original constructor, collision and draw consumers."""
from pathlib import Path
import json
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'kit/tools'), str(ROOT / 'kit/tests')]
import area_scene
import maindec as main
from export_first_room import collision_sources, combine_ground, scenery_query, source, terrain_query
from test_canonical_start import assert_main_words
from test_opening_events import assert_span


def ordinary_pose_clips(raw, context):
    table = area_scene.ptr_at(raw, context + 20)
    clips = [area_scene.ptr_at(raw, table + 4 * variant) for variant in range(4)]
    assert all(raw[clip + 1] & 3 == 3 for clip in clips)
    return [tuple(raw[clip + 5 + 2 * frame] or 256 for frame in range(raw[clip])) for clip in clips]


def advance_pose(pose, clips, ticks=1):
    clip = clips[pose['variant']]
    for _ in range(ticks):
        pose['remaining'] -= 1
        if pose['remaining'] == 0:
            pose['frame'] = (pose['frame'] + 1) % len(clip)
            pose['remaining'] = clip[pose['frame']]


def decay_pose_offsets(pose):
    speed = pose['speed']
    for axis in ('offset_x', 'offset_y'):
        value = pose[axis]
        pose[axis] = max(0, value - speed) if value >= 0 else min(0, value + speed)


def source_path(masked=False, returning=False):
    raw, _ = source('/VAA.BIN')
    room = area_scene.room_record(raw, 2)
    section = area_scene.section_off(raw, room['section'])
    entries = area_scene.entities(raw, room)
    compact = [entry for entry in entries if entry['flags'] & 0x101 and entry['stream_offsets'][0] is not None]
    actor = compact[10]
    assert len(compact) == 14 and (actor['index'], actor['id']) == (14, 137)
    context = area_scene.character_bindings(raw, section)[actor['id']]['context']
    durations = ordinary_pose_clips(raw, context)
    objects = collision_sources(raw, section)
    camera = dict(x=320, y=512)
    queued_speed = main.mword(0x8013C4A8) & 0xFFFF
    original_speed = (actor['flags'] >> 2) & 1
    variant = raw[actor['stream_offsets'][0] + 2] & 3
    frame = int(len(durations[variant]) > 1)
    state = dict(x=actor['x_half'] * 8, y=actor['y_half'] * 8, offset_x=0, offset_y=0,
                 flags=(0, 1, 0, 2)[variant], speed=queued_speed, variant=variant,
                 frame=frame, remaining=durations[variant][frame])

    def run(queue, blocked):
        assert raw[queue] == 0x32 and raw[queue + 1] == 10
        state['speed'] = queued_speed
        initial = state.copy()
        samples = []
        probes = []

        def field_update(active=True):
            pose = area_scene.descriptor_sheet(raw, context, state['variant'], state['frame'])['sheet']
            width, height = raw[pose + 2:pose + 4]
            x = state['x'] + state['offset_x'] - camera['x']
            y = state['y'] + state['offset_y'] - camera['y']
            visible = x + 24 >= 1 and x - width < 320 and y + height >= 1 and y - height < 240
            emitted = state.copy() if visible else None
            moving = state['offset_x'] or state['offset_y']
            update_clip = visible if moving else state['frame'] in (0, 2)
            if update_clip:
                advance_pose(state, durations)
            decay_pose_offsets(state)
            samples.append(dict(emitted=emitted, after=state.copy(), active=active))

        cursor = queue + 2
        while raw[cursor] != 5:
            opcode, count = raw[cursor:cursor + 2]
            assert opcode < 4
            direction = main.mword(0x80171B98 + 4 * opcode)
            vector = main.mword(0x801715B0 + 4 * direction)
            dx, dy, ox, oy = struct.unpack_from('<bbbb', main.body(), vector - main.MBASE)
            flags = state['flags']
            state['flags'] = (flags & 2, flags | 1, flags & 1, flags | 2)[direction]
            if state['variant'] != direction:
                state.update(variant=direction, frame=0, remaining=durations[direction][0])
                if count == 0:
                    advance_pose(state, durations)
            for _ in range(count):
                # The ordinary actor queries a two-half-cell footprint before moving one half cell.
                x, y = state['x'] // 8 + 2 * dx, state['y'] // 8 + 2 * dy
                query, support = scenery_query(objects, x, y)
                terrain = terrain_query(raw, section, x, y)
                mask = combine_ground(terrain, query, support, 0) | (13 if blocked else 0)
                probes.append((x, y, mask))
                if mask:
                    assert blocked and mask == 13
                    field_update()
                    continue
                state.update(x=state['x'] + dx * 8, y=state['y'] + dy * 8, offset_x=ox, offset_y=oy)
                field_update()
                while state['offset_x'] or state['offset_y']:
                    field_update()
            if count == 0:
                field_update()
            cursor += 2
        state['speed'] = original_speed
        field_update(active=False)
        return initial, samples, probes

    assert raw[0x50D93:0x50D9B] == bytes.fromhex('320a0008011c0533')
    initial, samples, probes = run(0x50D93, masked)
    assert len(probes) == 36 and probes[0][:2] == (16, 85)
    if returning:
        assert not masked and raw[0x50DA7:0x50DAE] == bytes.fromhex('320a031e010005')
        initial, samples, probes = run(0x50DA7, False)
        assert len(probes) == 30
    assert all(mask == (13 if masked else 0) for _, _, mask in probes)
    return dict(actor='scene_actor_10', entity=actor['index'], character=actor['id'], camera=camera,
                initial=initial, samples=samples)


class OrdinaryTrack(unittest.TestCase):
    def test_actual_queue_collision_and_draw(self):
        assert_main_words({
            0x80171718 + 4 * 0x32: (0x8013C354, 0x8013AE4C),
            # Both initial and continuing steps use the collision consumer.
            0x8013E9A8: (0x0C04B6A3,),
            0x8013EBB0: (0x0C04B6A3,),
            0x8012DB2C: (0x00031840, 0x00839021, 0x00021040, 0x00A28821, 0x02402021, 0x0C04B823),
            0x8012DC88: (0x10400006, 0, 0x3C028017, 0x90421C28, 0, 0x104000C1),
            # Opcode 0x33 backs up the cursor only while the active count is nonzero.
            0x8013AE58: (0x906316B9, 0x2482FFFF, 0x3C018018, 0xAC22AF84, 0x14600003, 0, 0x3C018018, 0xAC24AF84),
            # The end marker restores speed and clears the queue slot after freeing it.
            0x8013EAD4: (0x9202000A, 0x00138080, 0xA2420005),
            0x8013EAF0: (0x0C030B70,),
            0x8013EB00: (0xAE000000,),
        })
        for start, end, digest in (
            (0x8013C354, 0x8013C4EC, '5f46e74e09aadad67ae4fa148f2196db6ee5081cb3b2b1a0842e519d93a1d28d'),
            (0x8013E7E0, 0x8013ED6C, 'ca92c929a4f31214cdd8c5ae474cef46d4bf2044af67e12b27306a58a34058a8'),
            (0x8012DA8C, 0x8012E08C, '288156054788eaedfbcd92bd5d515c5a3dd3d7c0464a410c72649988ce166beb'),
            (0x8013AE4C, 0x8013AE80, 'c19438a831d2eece169c3524095594db6da4e3e2715809fbb9aeee433b0d11b9'),
            (0x80130514, 0x8013096C, '8b1e8efceafcd8b31fc041b748115a2a6c8f2e08a3943e7f3027e7880d7f74d5'),
            (0x8012F8AC, 0x8012F97C, '6b47ed2c0d24b48fc6b56e8edb4b86a140da7a5b4ac0168bf4a1a53442681e52'),
        ):
            assert_span(start, end, digest)
        expected = json.loads((ROOT/'game/tests/fixtures/field_ordinary_track.json').read_text())
        self.assertEqual(source_path(masked=True), expected.pop('masked'))
        self.assertEqual(source_path(returning=True), expected.pop('returning'))
        self.assertEqual(source_path(), expected)


if __name__ == '__main__': unittest.main()
