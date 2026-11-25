"""Static VAA ordinary/Hero overlap, frame order, and camera vectors."""
from pathlib import Path
import json
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'kit/tests'), str(ROOT / 'kit/tools')]
import area_scene
import maindec as main
from export_first_room import collision_sources, combine_ground, scenery_query, source, terrain_query
from parse_04play import Parser
from test_field_ordinary_track import advance_pose, decay_pose_offsets, ordinary_pose_clips, source_path
from test_opening_events import assert_span


def source_overlap():
    raw, _ = source('/VAA.BIN')
    room = area_scene.room_record(raw, 2)
    section = area_scene.section_off(raw, room['section'])
    populated = [entry for entry in area_scene.entities(raw, room)
                 if entry['flags'] & 0x101 and entry['stream_offsets'][0] is not None]
    bindings = area_scene.character_bindings(raw, section)
    contexts = [bindings[populated[i]['id']]['context'] for i in (10, 12)]
    durations = [ordinary_pose_clips(raw, context) for context in contexts]
    hero_raw, _ = source('/04_PLAY/SHU.BIN')
    parser = Parser(hero_raw, 0x80A00000)
    parser.parse_header()
    hero_section = parser.parse_section('S2', parser.u32(40))
    durations.append([tuple(ticks for _, ticks in entry['sequence']['pairs'])
                      for entry in hero_section['f']['entries'][:4]])

    first_track = source_path(returning=True)
    camera = first_track['camera'].copy()
    # The retained overlap starts partway through the return, with Teo and Hero settled.
    teo = populated[12]
    actor_ids = (10, 12, 128)
    speed = main.mword(0x8013C4A8) & 0xFFFF
    actors = [first_track['samples'][25]['after'].copy(),
              dict(x=teo['x_half'] * 8, y=teo['y_half'] * 8, offset_x=0, offset_y=0, flags=2,
                   speed=(teo['flags'] >> 2) & 1, variant=3, frame=1, remaining=durations[1][3][1]),
              dict(x=496, y=624, offset_x=0, offset_y=0, flags=0, speed=speed,
                   variant=2, frame=1, remaining=durations[2][2][1])]
    original_speeds = [first_track['samples'][-1]['after']['speed'], actors[1]['speed'], actors[2]['speed']]
    before = dict(actors=[pose.copy() for pose in actors], camera=camera.copy())
    width, height = struct.unpack_from('<hh', raw, section)
    objects = collision_sources(raw, section)
    queues = [[], [], []]
    active = [False, False, False]
    polls = 0

    def start(actor, queue, completed=0):
        assert tuple(raw[queue:queue + 2]) == (0x32, actor_ids[actor])
        cursor = queue + 2
        while raw[cursor] != 5:
            op, count = raw[cursor:cursor + 2]
            assert op < 4
            queues[actor].append((main.mword(0x80171B98 + 4 * op), count - completed))
            completed = 0
            cursor += 2
        actors[actor]['speed'] = speed
        active[actor] = True

    def step(actor):
        nonlocal polls
        pose = actors[actor]
        if not active[actor]:
            return
        if pose['offset_x'] or pose['offset_y']:
            if actor == 2:
                advance_pose(pose, durations[actor], pose['speed'])
            return
        if not queues[actor]:
            pose['speed'] = original_speeds[actor]
            active[actor] = False
            return
        direction, count = queues[actor][0]
        flags = pose['flags']
        pose['flags'] = (flags & 2, flags | 1, flags & 1, flags | 2)[direction]
        if pose['variant'] != direction:
            pose.update(variant=direction, frame=0, remaining=durations[actor][direction][0])
        if count == 0:
            advance_pose(pose, durations[actor])
        else:
            vector = main.mword(0x801715B0 + 4 * direction)
            dx, dy, ox, oy = struct.unpack_from('<bbbb', main.body(), vector - main.MBASE)
            distance = 1 if actor == 2 else 2
            x, y = pose['x'] // 8 + distance * dx, pose['y'] // 8 + distance * dy
            scenery, support = scenery_query(objects, x, y)
            assert combine_ground(terrain_query(raw, section, x, y), scenery, support, 0) == 0
            polls += 1
            pose.update(x=pose['x'] + dx * 8, y=pose['y'] + dy * 8, offset_x=ox, offset_y=oy)
        if count <= 1:
            queues[actor].pop(0)
        else:
            queues[actor][0] = direction, count - 1

    samples = []
    start(0, 0x50DA7, completed=7)
    for tick in range(151):
        if tick == 0:
            start(1, 0x50DB0)
        if tick == 1:
            start(2, 0x50DB5)
        hero_was_active = active[2]
        for index in range(3):
            step(index)
        hero = actors[2]
        if hero_was_active:
            for axis, limit, viewport, focus in (('x', width, 320, 152), ('y', height, 240, 112)):
                position = hero[axis] + hero['offset_' + axis] - focus
                camera[axis] = min(max(0, position), limit * 16 - viewport)
        decay_pose_offsets(hero)
        emitted = [dict(actor=2, pose=hero.copy())]
        if hero['offset_x'] or hero['offset_y']:
            advance_pose(hero, durations[2], hero['speed'])
        elif hero['frame'] in (0, 2):
            advance_pose(hero, durations[2])
        for index in range(2):
            pose = actors[index]
            sheet = area_scene.descriptor_sheet(raw, contexts[index], pose['variant'], pose['frame'])['sheet']
            w, h = raw[sheet + 2:sheet + 4]
            x = pose['x'] + pose['offset_x'] - camera['x']
            y = pose['y'] + pose['offset_y'] - camera['y']
            visible = x + 24 >= 1 and x - w < 320 and y + h >= 1 and y - h < 240
            if visible:
                emitted.append(dict(actor=index, pose=pose.copy()))
            moving = pose['offset_x'] or pose['offset_y']
            update_clip = visible if moving else pose['frame'] in (0, 2)
            if update_clip:
                advance_pose(pose, durations[index])
            decay_pose_offsets(pose)
        samples.append(dict(count=sum(active), slots=[actor_ids[i] if active[i] else None for i in range(3)],
                            camera=camera.copy(), actors=[pose.copy() for pose in actors], emitted=emitted))
        if not any(active):
            return dict(before=before, samples=samples, collision_queries=polls)
    raise AssertionError('source overlap did not finish')


class Overlap(unittest.TestCase):
    def test_original_selected_overlap(self):
        assert_span(0x8012CA44, 0x8012CB10, 'fb3a8817c90548747383159d274e17aba697137168c06a052d3b4804b9e42520')
        assert_span(0x8012FD10, 0x801300E4, 'e7501ffbdf2c261bed17964f1b7fca645c9cf2d2b8a5341bd165b9cebd5d8714')
        assert_span(0x8013E7E0, 0x8013ED6C, 'ca92c929a4f31214cdd8c5ae474cef46d4bf2044af67e12b27306a58a34058a8')
        assert_span(0x80130514, 0x8013096C, '8b1e8efceafcd8b31fc041b748115a2a6c8f2e08a3943e7f3027e7880d7f74d5')
        expected = json.loads((ROOT / 'game/tests/fixtures/field_overlap.json').read_text())
        observed = source_overlap()
        self.assertEqual(observed['before'], expected['before'])
        self.assertEqual(observed['collision_queries'], expected['collision_queries'])
        self.assertEqual(len(observed['samples']), len(expected['samples']))
        for index, (actual, retained) in enumerate(zip(observed['samples'], expected['samples'])):
            self.assertEqual(actual, retained, f'tick {index}')


if __name__ == '__main__':
    unittest.main()
