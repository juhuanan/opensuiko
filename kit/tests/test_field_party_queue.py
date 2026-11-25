#!/usr/bin/env python3
"""Static source checks for room 6 party tracks, poses, and Hero alignment."""
from hashlib import sha256
import json
from itertools import product
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import area_scene as scene
import export_field_party_queue as export
from export_first_room import source
from lzss import decode_strict
import maindec as M
from parse_04play import Parser
from test_canonical_start import assert_main_words

DIRECTIONS = ('down', 'up', 'left', 'right')
DELTAS = dict(zip(DIRECTIONS, ((0, 8), (0, -8), (-8, 0), (8, 0))))
POSITION = ('x', 'y', 'offset_x', 'offset_y')
STARTS = ((3, 22, 0), (25, 25, 3), (27, 23, 1), (27, 25, 2))


def read_json(path):
    return json.loads((ROOT / path).read_text())


def check_source_paths():
    spans = (
        (0x8013A770, 0x8013A808, '951ed3abe86fb2dd98c89e73a7b41a8bc2d2b065ef7b4d55be5b76368bba1ccf'),
        (0x8013A808, 0x8013A9C4, '31e7ee2d7ee20d99a3aec8f5d1869ecb1e2472e8e67884f1463033e9ef91f633'),
        (0x8013C4E4, 0x8013C5F4, '7992507796fb303b831356771851a2a4f22a32b74406c9c02c0c3cd81fb57e07'),
        (0x8013C5F4, 0x8013C6F4, 'c12464b2a495d96ea39558c12c2c4a7dbd3701279427c0262c86913dd74d2db7'),
        (0x8013C6F4, 0x8013C7A4, 'e6f415679a95149b78df7b09aba359b28d4473daef090f9526153aaacc6491c0'),
        (0x8013E7E0, 0x8013ED78, '2303f7929d8371cfad642eeb58188ecb56358ee12ca426725e7d75080de2f2ba'),
        (0x8013CCF0, 0x8013CDE8, '276aca8e80f7d482b4bdbf7bb5337670f62fc707f6d70ec2416684928aa12040'),
        (0x8012F8AC, 0x8012F97C, '6b47ed2c0d24b48fc6b56e8edb4b86a140da7a5b4ac0168bf4a1a53442681e52'),
        (0x8013096C, 0x80130CB8, 'cea716eb029ce1ebd880595aa86e84d2502282bb2c1a2321b580d87fcc524ffe'),
        (0x8012FD10, 0x801300F0, '09ba8f3c67038b7ce923dd3787f1b51222aaacfbbb378f8b25d27cba4fee4bc5'),
        (0x801347D0, 0x80134934, '5d165a08fe58b2fd5d38f0fe8f9633ffdf1c9d71ad501b631325278d69411a50'),
        (0x8013D0B8, 0x8013D158, 'feb9ac3c77039233ea782af05945e1a4446d82e3cf61f555ebbda90ddfa9a3ef'),
        (0x8013E450, 0x8013E6B4, '1d72d77f8f3cf1503fe41fda7c14a110b0a78796542a8e7deebfe0087022f525'),
        (0x800C4244, 0x800C42E8, '753933deb284721faa176a42841e7ff7f9779efe7fed3a432b6fc220a30c3776'),
    )
    for start, end, expected in spans:
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == expected, hex(start)
    assert_main_words({
        0x80171718+4*0x10: (0x8013D0B8, 0x8013CE08),
        0x80171718+4*0x33: (0x8013AE4C,),
        0x80171718+4*0x36: (0x8013C4E4, 0x8013C5F4, 0x8013C6F4),
        # Allocate 24 bytes per follower and initialize zero offsets at speed 2.
        0x8013A828: (0x90420003, 0, 0x2442FFFF, 0x3C018018, 0xAC22BF7C),
        0x8013A894: (0xA220FFEE, 0xA220FFEF, 0x34020002, 0xA222FFF1, 0xA220FFF2),
        0x8013C540: (0x24631A78, 0x00021080, 0x00438821),
        0x8013C64C: (0x24631B38, 0x00021080, 0x00439021),
        0x80171B98: (1, 3, 0, 2),
        # Opcode 33 keeps the stream on its wait until there are zero queue entries.
        0x8013AE54: (0x3C038017, 0x906316B9, 0x2482FFFF, 0x3C018018, 0xAC22AF84,
                     0x14600003, 0, 0x3C018018, 0xAC24AF84),
        # Opcodes 0..3 move or face. Opcode 5 restores speed and frees its queue entry.
        0x800C1A68: (0x8013E968,)*4 + (0x8013E9CC, 0x8013EAD4),
        0x8013E8A4: (0x8E420000, 0x3C03FFFF, 0x00431024, 0x144000D4),
        0x8013E9A8: (0x0C04B6A3, 0xA2020008),
        0x8013E9BC: (0x0C04F33C, 0),
        0x8013EAD4: (0x9202000A, 0x00138080, 0xA2420005),
        0x8013EAF0: (0x0C030B70, 0x26730001, 0x3C028017, 0x904216B9, 0xAE000000,
                     0x2442FFFF, 0x3C018017, 0xA02216B9),
        # Temporary actors emit before settlement, Hero settles before emission.
        0x80130AFC: (0x9205000A, 0x0C030FBC, 0x02602021),
        0x80130B38: (0x0C031091, 0x02602021),
        0x80130C38: (0x92630002, 0x34090001, 0x10690008, 0x34020003, 0x10620006),
        0x80130C64: (0x0C04BE2B, 0x02402021),
        0x8012FD28: (0x0C04BE2B,),
        0x8012FE5C: (0x0C030FBC,),
        0x801347E0: (0x0C04E1B7, 0x34040008, 0x8C500028),
        0x80134500: (0x14620003, 0x34020001, 0x0804D145, 0xA0C00002, 0xA0C20002),
        0x80130094: (0x9042BD79, 0, 0x1840000C, 0x00008021, 0x0C031091),
    })


def arrival_anchor():
    area, _ = source('/VB6.BIN')
    stream = scene.entities(area, scene.room_record(area, 6))[5]['stream_offsets'][2]
    assert area[stream] == 0x10
    assert area[stream+8:stream+10] == b'\x36\x33'
    assert area[stream+22:stream+25] == b'\x11\x40\x03'
    assert area[stream+37:stream+40] == b'\x11\x41\x01'
    return dict(zip(('x', 'y'), (cell*8 for cell in area[stream+1:stream+3])))


def get_tracks(proof, packet):
    decoded = {}
    directions = ('up', 'right', 'down', 'left')
    for track in proof['tracks']:
        raw = bytes.fromhex(track['bytes'])
        table = 0x80171A78 if track['id'].startswith('spread_') else 0x80171B38
        _, facing, index = track['id'].split('_')
        assert M.mword(table + 20*DIRECTIONS.index(facing) + 4*int(index)) == track['pointer']
        pos = track['pointer']-M.MBASE
        assert M.body()[pos:pos+len(raw)] == raw
        assert raw[-1] == 5 and len(raw) % 2 == 1
        commands = [{'kind': 'move', 'direction': directions[opcode], 'cells': steps}
                    for opcode, steps in zip(raw[:-1:2], raw[1::2])]
        decoded[track['id']] = commands + [{'kind': 'finish'}]
    assert decoded == {track['id']: track['commands'] for track in packet['tracks']}
    return decoded


def actions(commands):
    for command in commands[:-1]:
        for _ in range(max(1, command['cells'])):
            yield command['direction'], command['cells'] > 0


def moving(actor):
    return bool(actor['offset_x'] or actor['offset_y'])


def step(actor, direction):
    dx, dy = DELTAS[direction]
    actor.update(x=actor['x']+dx, y=actor['y']+dy, offset_x=-dx, offset_y=-dy)


def settle(actor, speed):
    for axis in ('offset_x', 'offset_y'):
        offset = actor[axis]
        actor[axis] = max(0, offset-speed) if offset > 0 else min(0, offset+speed)


def queue_updates(actors, tracks, minimum=1):
    pending = [iter(actions(track)) for track in tracks]
    active = [True]*len(actors)
    for tick in range(80):
        before = []
        for i, actor in enumerate(actors):
            action = None
            if active[i] and not moving(actor):
                action = next(pending[i], None)
                active[i] = action is not None
            if action is not None:
                direction, walk = action
                flags = actor['flags']
                actor['flags'] = {'down': flags & 2, 'up': flags | 1,
                                  'left': flags & 1, 'right': flags | 2}[direction]
                if walk:
                    step(actor, direction)
            before.append((dict(actor), action))
            settle(actor, actor['speed'])
        yield before, dict(active=sum(active), followers=[dict(actor) for actor in actors])
        if tick+1 >= minimum and not any(active):
            return
    raise AssertionError('source queue did not terminate')


def movement_vectors(anchor, tracks):
    rows = []
    for count, facing in product(range(1, 7), DIRECTIONS):
        actors = [dict(anchor, offset_x=0, offset_y=0, flags=0, speed=2) for _ in range(count-1)]
        for phase in ('spread', 'return'):
            if phase == 'return' and actors:
                actors[0]['flags'] &= 1
                if len(actors) > 1:
                    actors[1]['flags'] |= 2
            selected = [tracks[f'{phase}_{facing}_{i}'] for i in range(count-1)]
            samples = [after for _, after in queue_updates(actors, selected)]
            rows.append(dict(count=count, facing=facing, phase=phase, samples=samples))
        assert all((actor['x'], actor['y']) == (anchor['x'], anchor['y']) for actor in actors)
    return rows


def clock(pose, clips, ticks):
    durations = clips[pose['variant']]
    for _ in range(ticks):
        pose['remaining'] -= 1
        if not pose['remaining']:
            pose['frame'] = (pose['frame']+1) % len(durations)
            pose['remaining'] = durations[pose['frame']]


def select(pose, clips, variant, face_only=False):
    if pose['variant'] != variant:
        pose.update(variant=variant, frame=0, remaining=clips[variant][0])
        clock(pose, clips, int(face_only))


def graphics_vectors(anchor, tracks, resources):
    rows = []
    for resource, facing in product(resources, DIRECTIONS):
        clips = [clip['ticks'] for clip in resource['clips']]
        assert all(clip['flags'] == 3 for clip in resource['clips'])
        actor = dict(anchor, offset_x=0, offset_y=0, flags=0, speed=2)
        pose = dict(variant=0, frame=0, remaining=clips[0][0])
        for phase in ('spread', 'return'):
            if phase == 'return':
                select(pose, clips, 2, face_only=True)
            initial = dict({key: actor[key] for key in POSITION}, **pose)
            samples = []
            track = tracks[f'{phase}_{facing}_0']
            for before, after in queue_updates([actor], [track], minimum=21):
                state, action = before[0]
                if action is not None:
                    direction, walk = action
                    select(pose, clips, DIRECTIONS.index(direction), face_only=not walk)
                emitted = dict({key: state[key] for key in POSITION}, **pose)
                clock(pose, clips, int(moving(state) or pose['frame'] not in (1, 3)))
                following = dict({key: after['followers'][0][key] for key in POSITION}, **pose)
                samples.append(dict(emitted=emitted, after=following))
            rows.append(dict(character=resource['character'], facing=facing, phase=phase,
                             initial=initial, samples=samples))
    return rows


def source_clips(file, character):
    raw, _ = source('/04_PLAY/'+file+'.BIN')
    assert raw[0] == character
    parser = Parser(raw, 0)
    parser.parse_header()
    base, = struct.unpack_from('<I', raw, 0x28)
    section = parser.parse_section('S2', base)
    for entry in section['c']['entries']:
        blob = entry['blob']
        offset = blob['data_file_offset']
        assert len(decode_strict(raw[offset:offset+blob['data_len']])) == 16384
    count, = struct.unpack_from('<H', raw, base+2)
    table, = struct.unpack_from('<I', raw, base+0x14)
    assert count == 4
    clips = []
    for offset in struct.unpack_from('<4I', raw, table):
        assert raw[offset:offset+2] == b'\x04\x03'
        clips.append([duration or 256 for duration in raw[offset+5:offset+12:2]])
    assert clips == [[duration or 256 for _, duration in entry['sequence']['pairs']]
                     for entry in section['f']['entries']]
    return clips


def hero_vectors(anchor, clips, starts=STARTS):
    rows = []
    for x, y, variant in starts:
        actor = dict(x=x*8, y=y*8, offset_x=0, offset_y=0)
        pose = dict(variant=variant, frame=1, remaining=clips[variant][1])
        initial = dict(actor, **pose)
        dx, dy = anchor['x']-actor['x'], anchor['y']-actor['y']
        stages = (['right' if dx > 0 else 'left']*(abs(dx)//8) + [None] +
                  ['down' if dy > 0 else 'up']*(abs(dy)//8) + [None])
        samples = []
        for direction in stages:
            if direction is not None:
                step(actor, direction)
                select(pose, clips, DIRECTIONS.index(direction))
            for _ in range(4):
                settle(actor, 2)
                emitted = dict(actor, **pose)
                clock(pose, clips, 2 if moving(actor) else int(pose['frame'] not in (1, 3)))
                samples.append(dict(emitted=emitted, after=dict(actor, **pose)))
        assert not moving(actor) and (actor['x'], actor['y']) == (anchor['x'], anchor['y'])
        rows.append(dict(initial=initial, samples=samples))
    return rows


class PartyQueue(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        check_source_paths()
        cls.anchor = arrival_anchor()
        cls.packet, cls.proof = export.export()
        cls.tracks = get_tracks(cls.proof, cls.packet)

    def test_hero_alignment_sprite_consumer(self):
        rows = hero_vectors(self.anchor, source_clips('SHU', 8))
        self.assertEqual(rows, read_json('game/tests/fixtures/field_hero_graphics.json'))

    def test_producer_consumer_and_named_tracks(self):
        rows = movement_vectors(self.anchor, self.tracks)
        self.assertEqual(rows, read_json('game/tests/fixtures/field_party_queue.json'))

    def test_loaded_party_graphics_consumer(self):
        packet, proof = export.graphics()
        self.assertEqual(packet, read_json('game/assets/field_party_graphics.json'))
        self.assertEqual(proof, read_json('kit/data/reports/field_party_graphics.json'))
        for resource, file in zip(packet['resources'], ('GRE', 'PAN', 'VIC', 'YAM'), strict=True):
            self.assertEqual(source_clips(file, resource['character']), [clip['ticks'] for clip in resource['clips']])
        rows = graphics_vectors(self.anchor, self.tracks, packet['resources'])
        self.assertEqual(rows, read_json('game/tests/fixtures/field_party_graphics.json'))

    def test_export_is_current(self):
        self.assertEqual(self.packet['anchor'], self.anchor)
        self.assertEqual(self.packet, read_json('game/assets/field_party_queue.json'))
        self.assertEqual(self.proof, read_json('kit/data/reports/field_party_queue.json'))


if __name__ == '__main__':
    unittest.main()
