#!/usr/bin/env python3
"""Static source and independent arithmetic, placement and pixel checks for the battle trial."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import export_battle_trial as export
import maindec
from export_first_room import source
from test_damage_instructions import check_source as check_damage_source, hit_reference, physical_reference
from spell_scene_warp import parabolic_path
from test_export_unite_review import vram_pose


def arithmetic_vectors():
    check_damage_source()
    damage, accuracy, speed = [], [], []
    for attack, defense in [(0, 0), (5, 31), (14, 5), (15, 5), (31, 23), (35, 19), (65, 23), (65535, 0)]:
        for roll in (0, 1, 3, 19, 32767):
            for defending in (False, True):
                damage.append(dict(attack=attack, defense=defense, roll=roll,
                                   defending=defending,
                                   damage=physical_reference(attack - defense, roll, party_defend=defending)))
    for skill, target in [(0, 100), (5, 28), (28, 5), (15, 24), (0, 0), (65535, 0)]:
        for roll in (0, 59, 60, 79, 80, 98, 99, 100, 32767):
            accuracy.append(dict(skill=skill, target_skill=target, roll=roll,
                                 hit=hit_reference(skill, target, roll)))
    for values, rolls in [([24, 20, 16], [0, 9, 5]), ([20, 20, 20], [0, 1, 9]),
                          ([0, 0, 0], [9, 0, 8]), ([20, 20, 20], [5, 5, 5])]:
        scores = [10 * value - 5 + roll % 10 for value, roll in zip(values, rolls, strict=True)]
        speed.append(dict(speeds=values, rolls=rolls, chosen=scores.index(max(scores))))
    return dict(damage=damage, accuracy=accuracy, speed=speed)


def pin_words(words):
    for pc, expected in words.items():
        assert maindec.mword(pc) == expected, hex(pc)


def pin_span(start, end, digest):
    body = maindec.body()
    assert hashlib.sha256(body[start-maindec.MBASE:end-maindec.MBASE]).hexdigest() == digest, hex(start)


def source_leaps():
    pin_span(0x800E4738, 0x800E4974, '5b768463b9a0481cc308d9c9f6f0d62638a5d27ad2ab78e5795024c1b4d5437e')
    pin_span(0x800E3710, 0x800E37C4, '6db2ea2f2dce39fcd6c0b67b0b4cf2ea436bd5d38ddc79b0b1bc1b3c4f182449')
    pin_words({
        0x800E4768: 0x84430006, 0x800E477C: 0x8443000A, 0x800E4784: 0x84480004,
        0x800E478C: 0x0004C2C0, 0x800E4794: 0x84440002, 0x800E4798: 0x0005CAC0,
        0x800E47A4: 0x00037AC0, 0x800E4874: 0x00C7001A, 0x800E48B4: 0x00A7001A,
        0x800E48F4: 0x0087001A, 0x800E4940: 0xAC58002C, 0x800E4958: 0xAC460020,
        0x800E3744: 0x00AD2821, 0x800E3748: 0xAF050068, 0x800E3760: 0xAF08002C,
        0x800E3778: 0xA7020010, 0x800E3794: 0x8F040014, 0x800E37A8: 0xAF040068,
    })
    home, target, retreat_origin = (120, 50, 0), (-128, 0, 0), (-88, 0, 0)
    rows = []
    for code, approach, retreat in (('SHU', 0x286, 0x30A), ('GRE', 0x196, 0x1F2), ('A_DATA', 0x1F1A8, 0x1F1E0)):
        data, _ = source('/' + code + '.BIN')
        for offset, mode in ((approach, 2), (retreat, 3)):
            op, raw_mode, duration, x, y, z, vx, vy, vz = struct.unpack_from('<9h', data, offset)
            assert (op, raw_mode) == (23, mode), (code, offset)
            start = home if mode == 2 else retreat_origin
            destination = tuple(n + d for n, d in zip(target, (x, y, z))) if mode == 2 else home
            velocity = [n << 11 for n in (vx, vy, vz)]
            samples = parabolic_path([n << 12 for n in start], [n << 12 for n in destination], duration, velocity)
            rows.append({
                'character': code,
                'source_offset': offset,
                'start': dict(zip(('x', 'y', 'z'), start)),
                'destination': dict(zip(('x', 'y', 'z'), map(float, destination))),
                'motion': {'ticks': duration, 'acceleration_step': 1/4096, 'offset': {'x': 0, 'y': 0, 'z': 0},
                           'velocity': dict(zip(('x', 'y', 'z'), (value / 4096 for value in velocity)))},
                'samples': [dict(zip(('x', 'y', 'z'), start))] + [
                    dict(zip(('x', 'y', 'z'), (n / 4096 for n in sample))) for sample in samples[1:]
                ],
            })
    return rows


def source_pose(data, section, base, animation, step):
    """Read the selected F/E pair and sample its pixels through the independent VRAM model."""
    frame_table = struct.unpack_from('<I', data, section + 20)[0] - base
    frame = struct.unpack_from('<I', data, frame_table + 4 * animation)[0] - base
    assert 0 <= step < (data[frame] or 1)
    return vram_pose(data, section, data[frame + 4 + 2 * step], base=base)


class BattleTrialTests(unittest.TestCase):
    def test_trial_export_is_reproducible_and_matches_fixture(self):
        with tempfile.TemporaryDirectory() as tmp:
            one, two = Path(tmp) / 'a', Path(tmp) / 'b'
            content = export.export(one)
            export.export(two)
            self.assertEqual(content, json.loads((ROOT / 'game/tests/fixtures/battle_trial.json').read_text()))
            for name in ('trial.json', 'actors.png', 'floor.png', 'ground.png', 'review.png', 'provenance.json'):
                self.assertEqual(hashlib.sha256((one / name).read_bytes()).hexdigest(), hashlib.sha256((two / name).read_bytes()).hexdigest())
        with self.assertRaisesRegex(ValueError, 'accepted content'):
            export.export(ROOT / 'kit/work/accepted/battle_trial')

    def test_enemy_fields_and_money_follow_the_selected_source_records(self):
        pin_span(0x800DEE44, 0x800DF144, '7d631e8df5dafb59a6aa5c354d981e3a6b41dad3c6ce079fa2958787e8a9637b')
        pin_span(0x800E9940, 0x800E9CEC, 'e7052aeb018715fee8d9cff1a0a2a58e89577d46c2f66ae07fdd14fd36301100')
        pin_words({
            0x800DF0B4: 0x96220012, 0x800DF0BC: 0xA6420010, 0x800DF0CC: 0xA6420012,
            0x800DF0D0: 0x94A20014, 0x800DF0DC: 0xA4620014, 0x800DF0E0: 0x28820006,
            0x800E99F0: 0x96030034, 0x800E9A04: 0x00031C00, 0x800E9A0C: 0x0062001A,
            0x800E9A78: 0xAC43224C,
        })
        data, _ = source('/A_DATA.BIN')
        pointer = lambda off: struct.unpack_from('<I', data, off)[0] - 0x80080000
        directory = pointer(pointer(pointer(0) + 12))
        selectors, records = pointer(directory + 8), pointer(directory + 12)
        content = json.loads((ROOT / 'game/tests/fixtures/battle_trial.json').read_text())
        stable_ids = {1: 'bonbon', 4: 'wild_boar'}
        values = {}
        for number, offset, expected_money in ((1, 0x1F3FC, 70), (4, 0x233DC, 300)):
            record = pointer(records + 4 * number)
            self.assertEqual(record, offset)
            enemy = next(e for e in content['enemies'] if e['id'] == stable_ids[number])
            hp, attack, skill, defense, speed = struct.unpack_from('<5H', data, record + 18)
            self.assertEqual((enemy['level'], enemy['max_hp']), (data[record + 16], hp))
            self.assertEqual(enemy['stats'], dict(attack=attack, skill=skill, defense=defense, speed=speed))
            encoded = struct.unpack_from('<h', data, record + 52)[0]
            self.assertGreaterEqual(encoded, 0)
            values[number] = (encoded // 10) * 100 if encoded & 1 else encoded
            self.assertEqual((enemy['money'], values[number]), (expected_money, expected_money))
        for encounter, selector, expected_money in zip(content['encounters'], (1, 2, 5), (70, 210, 300), strict=True):
            record = pointer(selectors + 4 * selector)
            roster = [number for number in data[record + 4:record + 10] if number]
            self.assertEqual(encounter['enemies'], [stable_ids[number] for number in roster])
            self.assertEqual(sum(values[number] for number in roster), expected_money)

    def test_experience_from_static_award_table_and_eligibility_branch(self):
        pin_span(0x800E9744, 0x800E9940, '288522d1e3fbe7deb0ab767a163d1e0dba02b22ea1325e1da2e7ce417ec1acab')
        pin_words({
            0x800E979C: 0x91A20045, 0x800E97A4: 0x10400003, 0x800E97B0: 0xACE00010,
            0x800E9828: 0x90440010, 0x800E982C: 0x9062000D, 0x800E9834: 0x00822023,
            0x800E9838: 0x2882FFF2, 0x800E9840: 0x28820010, 0x800E9864: 0x8C420000,
            0x800E9870: 0xAD230010, 0x800E9898: 0x8D43001C, 0x800E98A0: 0x0043001A,
            0x800E98D4: 0x28420005,
        })
        content = json.loads((ROOT / 'game/tests/fixtures/battle_trial.json').read_text())
        party = [actor['level'] for actor in content['party']]
        self.assertEqual(party, [5, 5])
        levels = {e['id']: e['level'] for e in content['enemies']}
        table = struct.unpack_from('<30I', maindec.body(), 0x8016BD90 - maindec.MBASE)
        for encounter, expected in zip(content['encounters'], (100, 300, 450), strict=True):
            enemies = [levels[name] for name in encounter['enemies']]
            for level in party:
                total = sum(table[max(0, min(29, enemy - level + 14))] for enemy in enemies)
                self.assertEqual(max(5, total // len(party)), expected)
            self.assertEqual(encounter['experience_per_member'], expected)
        self.assertEqual(sum(e['experience_per_member'] for e in content['encounters']), 850)

    def test_descriptor_poses_against_static_quad_layout_and_vram(self):
        from PIL import Image
        import export_demo_batch

        pin_span(0x800E211C, 0x800E256C, '31258efb3f524c3b4633922184aa8b82ca8c4e3fbde5102b7f91686fa700e5e3')
        pin_words({
            # The animation object selects an F pair, then an E record and its eight-byte pieces.
            0x800E214C: 0x8E830030, 0x800E2154: 0x8C630014, 0x800E2164: 0x92820002,
            0x800E2168: 0x24630004, 0x800E2170: 0x00021040, 0x800E2178: 0x90440000,
            0x800E2188: 0x8C620010, 0x800E2198: 0x8C820000, 0x800E21A8: 0x905E0000,
            0x800E21CC: 0x001510C0, 0x800E21D8: 0x24420008, 0x800E21E4: 0x92620002,
            0x800E2280: 0x92620006, 0x800E22A4: 0x260501E0, 0x800E22A8: 0x0C052AF5,
            0x800E22D8: 0x92620003, 0x800E232C: 0x92630007, 0x800E234C: 0x92630004,
            0x800E236C: 0x92630005, 0x800E243C: 0x1440FF63,
        })

        for producer in (export.export, export_demo_batch.export):
            with tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp)
                content = producer(output)
                with Image.open(output / 'actors.png') as atlas:
                    def compare(sprite, pose):
                        expected, ax, ay = pose
                        r = sprite['rect']
                        actual = atlas.crop((r['x'], r['y'], r['x'] + r['w'], r['y'] + r['h']))
                        self.assertEqual((actual.size, sprite['anchor_x'], sprite['anchor_y']),
                                         (expected.size, ax, ay))
                        self.assertEqual(actual.tobytes(), expected.tobytes())

                    sources = ('/SHU.BIN', '/GRE.BIN', '/PAN.BIN', '/VIC.BIN', '/KAM.BIN', '/TAI.BIN')
                    for suffix, actor in zip(sources, content['party']):
                        raw, _ = source(suffix)
                        section = struct.unpack_from('<I', raw, 36)[0]
                        idle = source_pose(raw, section, 0, 0, 0)
                        compare(actor['sprite'], idle)
                        expected, _, ay = idle
                        self.assertEqual(actor['foot_offset_y'], expected.getchannel('A').getbbox()[3] - 1 - ay)
                        poses = {}
                        for frame in actor['attack']:
                            index = frame['source_pose']
                            if index not in poses:
                                poses[index] = vram_pose(raw, section, index)
                            compare(frame['pose'], poses[index])

                    data, _ = source('/A_DATA.BIN')
                    pointer = lambda off: struct.unpack_from('<I', data, off)[0] - 0x80080000
                    for address, actor in zip((0x1F3FC, 0x233DC), content['enemies'], strict=True):
                        section = pointer(address + 44)
                        compare(actor['sprite'], source_pose(data, section, 0x80080000, 0, 0))

    def test_ground_palette_selection_and_scenery_static_reads(self):
        from lzss import decode_strict

        pin_span(0x800DF144, 0x800DF3B4, '5acc151a445e96310855f260a50df26afc269cd9aff5ea73e8bdf19dcf1937cb')
        pin_words({
            0x800E7C3C: 0x8EA30010, 0x800E7C40: 0x00108080, 0x800E7C48: 0x8E030000,
            0x800E7C50: 0x92A50007, 0x800E7C58: 0x90630000, 0x800E7C60: 0x24A501E0,
            0x800E7C64: 0x0C052AF5, 0x800E7C68: 0x00652821,
            0x800DF180: 0x8C550014, 0x800DF258: 0x24540FD8, 0x800DF264: 0x86A20000,
            0x800DF270: 0xAC620028, 0x800DF280: 0x86250008, 0x800DF284: 0x8622000A,
            0x800DF288: 0x8623000C, 0x800DF28C: 0x8624000E, 0x800DF2A4: 0x00021300,
            0x800DF2A8: 0xAE020004, 0x800DF2B0: 0xAE030008, 0x800DF2B8: 0xAE04000C,
            0x800DF338: 0x1440FFD1, 0x800DF33C: 0x26310008,
        })
        data, _ = source('/A_DATA.BIN')
        word = lambda off: struct.unpack_from('<I', data, off)[0]
        pointer = lambda off: word(off) - 0x80080000
        directory = pointer(pointer(pointer(0) + 12))
        section = pointer(directory)
        terrain, proof = export.ground_tiles(data, directory + 0x80080000)
        palette_table = pointer(section + 16)
        selectors = list(data[pointer(palette_table):pointer(palette_table) + 16])
        self.assertEqual(proof['palette_selectors'], [selectors])
        self.assertEqual(set(selectors), {5})

        palettes = [struct.unpack_from('<256H', data, pointer(pointer(section + 12) + 4 * i))
                    for i in range(data[section + 5] & 63)]
        blob = pointer(pointer(section + 8))
        plane = decode_strict(data[blob + 4:blob + 4 + word(blob)])
        tilemap = struct.unpack_from('<256H', data, pointer(section + 20))
        for cell, tile in enumerate(tilemap):
            for x, y in ((0, 0), (15, 19), (31, 31)):
                texel = palettes[selectors[tile]][plane[(tile // 4 * 32 + y) * 128 + tile % 4 * 32 + x]]
                self.assertEqual(terrain.getpixel((cell % 16 * 32 + x, cell // 16 * 32 + y)),
                                 tuple(((texel >> n) & 31) * 255 // 31 for n in (0, 5, 10)))

        fixture = json.loads((ROOT / 'game/tests/fixtures/battle_trial.json').read_text())
        records = pointer(directory + 20)
        count = struct.unpack_from('<h', data, records)[0]
        self.assertEqual(count, 20)
        self.assertEqual(len(fixture['scenery']), count)
        for i, prop in enumerate(fixture['scenery']):
            _, x, y, z = struct.unpack_from('<4h', data, records + 8 + 8*i)
            self.assertEqual(prop['position'], dict(x=x, y=y, z=z))

    def test_attack_motion_against_original_jump_and_integrator(self):
        rows = source_leaps()
        self.assertEqual(rows, json.loads((ROOT / 'game/tests/fixtures/battle_motion.json').read_text()))
        content = json.loads((ROOT / 'game/tests/fixtures/battle_trial.json').read_text())
        for index, actor in enumerate(content['party']):
            for key, source_row in zip(('approach', 'retreat'), rows[index * 2:index * 2 + 2]):
                self.assertEqual(actor['motion'][key]['ticks'], source_row['motion']['ticks'])
                self.assertEqual(actor['motion'][key]['velocity'], source_row['motion']['velocity'])
                self.assertLess(min(p['z'] for p in source_row['samples']), -30)

    def test_arithmetic_vectors_match_tracked_fixture(self):
        self.assertEqual(arithmetic_vectors(), json.loads((ROOT / 'game/tests/fixtures/battle_math.json').read_text()))


if __name__ == '__main__':
    if '--write-fixture' in sys.argv:
        (ROOT / 'game/tests/fixtures/battle_motion.json').write_text(json.dumps(source_leaps(), indent=2) + '\n')
        value = arithmetic_vectors()
        (ROOT / 'game/tests/fixtures/battle_math.json').write_text(json.dumps(value, indent=2) + '\n')
        with tempfile.TemporaryDirectory() as tmp:
            content = export.export(Path(tmp))
            (ROOT / 'game/tests/fixtures/battle_trial.json').write_text(json.dumps(content, indent=2) + '\n')
        print('Wrote static arithmetic and motion vectors and the trial fixture')
    else:
        unittest.main()
