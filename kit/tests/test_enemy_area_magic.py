"""Independent streams, animation records, worker contracts and admission checks."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from export_first_room import source
import export_enemy_area_magic as exporter
from test_physical_rune_export import independent_stream


class AreaMagicSource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packet = exporter.build()
        cls.raw = {name: source(name)[0] for name in ('/E_DATA.BIN', '/G_DATA.BIN', '/H_DATA.BIN', '/C_DATA.BIN', 'MAIN.EXE')}

    def test_all_three_components_have_independently_read_root_recipient_and_auxiliary_closure(self):
        self.assertEqual(len(self.packet['programs']['programs']), 28)
        ids = {p['id'] for p in self.packet['programs']['programs']}
        tables = {a['id']: a['provenance']['script_table_source_offset'] for a in self.packet['actors']}
        for row in self.packet['provenance']['programs']:
            span = row['spans'][0]; name = span['source']['file'].split('/')[-1]
            raw = self.raw['MAIN.EXE' if name == 'MAIN.EXE' else '/' + name]
            table = None if name == 'MAIN.EXE' else tables[row['id'].split('/')[1]]
            self.assertEqual(row['operations'], independent_stream(raw, span['source_offset'], table, 0 if table is None else exporter.BASE))
            for proof in row['spans']:
                self.assertEqual(hashlib.sha256(raw[proof['source_offset']:proof['source_offset'] + proof['byte_length']]).hexdigest(), proof['sha256'])
        for actor in self.packet['actors']:
            for key, value in actor.items():
                if key.endswith('_program'):
                    self.assertIn(value, ids)
        for program in self.packet['programs']['programs']:
            for instruction in program['instructions']:
                child = instruction.get('command', {}).get('child')
                if child:
                    self.assertIn(child['program'], ids)
        self.assertEqual(self.packet['unbound_effects'], [])
        self.assertEqual(self.packet['admission'], 'qualified')

    def test_frames_flags_durations_and_anchors_match_independent_raw_tables(self):
        self.assertEqual([len(r['clips']) for r in self.packet['animations']['resources']], [12, 13, 13])
        for actor, resource in zip(self.packet['actors'], self.packet['animations']['resources'], strict=True):
            proof = actor['provenance']; raw = self.raw['/' + proof['source']['file'].split('/')[-1]]
            p = lambda off: struct.unpack_from('<I', raw, off)[0] - exporter.BASE
            section = p(proof['record_source_offset'] + 44); frames, poses = p(section + 20), p(section + 16)
            self.assertEqual(resource['pose_count'], struct.unpack_from('<H', raw, section)[0])
            for clip in resource['clips']:
                off = p(frames + clip['id'] * 4); expected = []
                for i in range(max(1, raw[off])):
                    pose, duration = raw[off + 4 + 2 * i:off + 6 + 2 * i]; entry = p(poses + 4 * pose)
                    expected.append(dict(pose=pose, updates=duration or 256,
                        attachment=[raw[entry + 6] - raw[entry + 4], raw[entry + 7] - raw[entry + 5]]))
                self.assertEqual(clip['frames'], expected)
                for key, bit in (('advances', 1), ('loop', 2), ('semitransparent', 4)):
                    self.assertEqual(clip[key], bool(raw[off + 1] & bit))

    def test_selector_and_primary_completion_operands_keep_sorcerer_delay_difference(self):
        for actor, (_, region, _, _, _, _, _, threshold, _, blocks) in zip(self.packet['actors'], exporter.SOURCES, strict=True):
            raw = self.raw['/' + region + '_DATA.BIN']; word = lambda o: struct.unpack_from('<I', raw, o)[0]
            start = blocks[0][0]
            self.assertEqual(word(start + 0xc0), 0x00001810)  # Front draw uses remainder.
            self.assertEqual(word(start + 0x178), 0x0062001a)
            self.assertEqual(word(start + 0x1a0), 0x00001812)  # Secondary draw uses quotient.
            self.assertEqual(word(start + 0x1a8) & 65535, threshold)
            special = actor['special']
            self.assertEqual(special['completion_sets_delay'], region != 'E')
            first, last, _ = blocks[2]; poll = list(struct.unpack('<' + 'I' * ((last - first) // 4), raw[first:last]))
            if region == 'E':
                self.assertNotIn(0xac821264, poll)
                self.assertIn(0x0002102b, poll)
                self.assertIn(0x00021023, poll)
            else:
                self.assertIn(0x3402001e, poll)
                self.assertIn(0xac821264, poll)
            for span in actor['provenance']['callbacks']:
                self.assertEqual(hashlib.sha256(raw[span['source_offset']:span['source_offset'] + span['byte_length']]).hexdigest(), span['sha256'])
        self.assertEqual(self.raw['/E_DATA.BIN'][4:14], b'SOS TURN \n')
        self.assertTrue(self.raw['/E_DATA.BIN'][16:].startswith(b'SOS TURN'))
        main = self.raw['MAIN.EXE']; base = struct.unpack_from('<I', main, 24)[0]
        self.assertEqual(struct.unpack_from('<I', main, 2048 + 0x8016b688 - base)[0], 0x80147d78)
        self.assertEqual(struct.unpack_from('<3I', main, 2048 + 0x80147d78 - base), (0x240a00a0, 0x01400008, 0x2409003f))

    def test_siren_camera_callback_and_golem_projectile_match_their_consumers(self):
        raw = self.raw['/G_DATA.BIN']; words = list(struct.unpack('<33I', raw[0x5ac:0x630]))
        self.assertEqual([w & 65535 for w in words if w >> 26 == 35 and (w >> 21) & 31 == 4], [0x12a0, 0x12a4, 0x12a8] * 2)
        self.assertEqual([w & 65535 for w in words if w >> 26 == 41], [0x18, 0x1a, 0x1c, 2, 4, 6])
        self.assertEqual(sum(w >> 26 == 0 and w & 63 == 3 and (w >> 6) & 31 == 12 for w in words), 6)
        reference = self.raw['/C_DATA.BIN']; golem = self.raw['/H_DATA.BIN']
        self.assertEqual(struct.unpack_from('<I', reference, 0x253fc + 9 * 4)[0], 0x80081050)
        self.assertEqual(struct.unpack_from('<I', golem, 0x23974 + 5 * 4)[0], 0x80082a18)
        for off in range(0, 0x200, 4):
            a = struct.unpack_from('<I', reference, 0x1050 + off)[0]; b = struct.unpack_from('<I', golem, 0x2a18 + off)[0]
            if a >> 26 in (2, 3):
                self.assertEqual(a >> 26, b >> 26)
                a = (a & 0x3ffffff) * 4 - 0x81050; b = (b & 0x3ffffff) * 4 - 0x82a18
            self.assertEqual(a, b, hex(off))

    def test_dispatch_install_after_movement_and_mailbox_protocol_have_raw_operands(self):
        main = self.raw['MAIN.EXE']; base = struct.unpack_from('<I', main, 24)[0]
        word = lambda pc: struct.unpack_from('<I', main, 2048 + pc - base)[0]
        for pc, value in {
            0x800e55d4: 0x8c650008, 0x800e5620: 0x8c440000,
            0x800e5630: 0xac640054, 0x800e5634: 0x24420006,
            0x800e3778: 0xa7020010, 0x800e37dc: 0x8c420054,
            0x800e37f4: 0x0040f809,
        }.items():
            self.assertEqual(word(pc), value, hex(pc))
        for proof in self.packet['provenance']['main_consumers']:
            self.assertEqual(hashlib.sha256(main[proof['source_offset']:proof['source_offset'] + proof['byte_length']]).hexdigest(), proof['sha256'])
        for actor in self.packet['actors']:
            special = actor['special']; self.assertEqual(special['first_callback_update'], 32 if actor['id'] == 'sorcerer' else 38)
            self.assertEqual(special['ready_mailboxes'], [99, 100] if actor['id'] == 'siren' else [99])
            self.assertEqual(special['warmup_updates'], 20 if actor['id'] == 'siren' else 0)
        siren = self.raw['/G_DATA.BIN']; w = lambda o: struct.unpack_from('<I', siren, o)[0]
        for off, value in {
            0x6f0: 0x34020014, 0x704: 0x2442ffff, 0x760: 0x080201e7,
            0x774: 0x080201e7, 0x778: 0xa6020042, 0x794: 0xae000058,
            0x798: 0xae000054,
        }.items():
            self.assertEqual(w(off), value, hex(off))

    def test_worker_damage_and_elemental_resistance_fallbacks_match_source_registers(self):
        by_id = {a['id']: a for a in self.packet['actors']}
        self.assertEqual(by_id['sorcerer']['damage']['element'], 6)
        self.assertEqual(by_id['sorcerer']['damage']['fallback_element'], 1)
        self.assertEqual(by_id['siren']['damage']['element'], 8)
        self.assertEqual(by_id['siren']['damage']['fallback_element'], 0)
        self.assertEqual(by_id['earth_golem']['damage']['element'], 3)
        self.assertTrue(by_id['earth_golem']['damage']['fallback_by_slot'])
        # Sorcerer element is 6: rune 7 (selector 6) and rune 1 (universal selector 7) halve damage; fallback s1 = 1 does not match 6.
        sorc_base = exporter.magic_damage(by_id['sorcerer'], 100, 50, 0, 0)
        self.assertEqual(exporter.magic_damage(by_id['sorcerer'], 100, 50, 7, 0), max(1, sorc_base // 2))
        self.assertEqual(exporter.magic_damage(by_id['sorcerer'], 100, 50, 1, 0), max(1, sorc_base // 2))
        self.assertEqual(exporter.magic_damage(by_id['sorcerer'], 100, 50, 2, 0), sorc_base)
        # Siren element is 8: only rune 1 (universal selector 7) halves damage; other runes leave it unhalved.
        siren_base = exporter.magic_damage(by_id['siren'], 100, 50, 0, 0)
        self.assertEqual(exporter.magic_damage(by_id['siren'], 100, 50, 1, 0), max(1, siren_base // 2))
        self.assertEqual(exporter.magic_damage(by_id['siren'], 100, 50, 7, 0), siren_base)
        # Earth Golem element is 3; party slot 2 has fallback_element = 3 (s1 = slot + 1), halving damage on rune 0 or 8..26.
        base = exporter.magic_damage(by_id['earth_golem'], 120, 40, 0, 0, party_slot=0)
        halved = exporter.magic_damage(by_id['earth_golem'], 120, 40, 0, 0, party_slot=2)
        self.assertEqual(halved, max(1, base // 2))
        self.assertEqual(exporter.magic_damage(by_id['earth_golem'], 120, 40, 10, 0, party_slot=2), halved)
        self.assertEqual(exporter.magic_damage(by_id['earth_golem'], 120, 40, 6, 0, party_slot=0), halved)
        # An attached non-Earth elemental rune (e.g. rune 2 -> selector 1) overrides the slot fallback.
        self.assertEqual(exporter.magic_damage(by_id['earth_golem'], 120, 40, 2, 0, party_slot=2), base)

    def test_library_merge_and_normal_admission_retain_all_ten_formations(self):
        from PIL import Image
        from export_first_room import Atlas
        from test_export_unite_review import vram_pose
        battle = json.loads((ROOT / 'game/tests/fixtures/journey_unites_battle.json').read_text())
        actors = json.loads((ROOT / 'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        ids = {'sorcerer', 'siren', 'earth_golem'}
        added = {'area_e_7', 'area_e_8', 'area_e_9', 'area_g_6', 'area_g_8', 'area_g_9', 'area_h_7', 'area_h_8', 'area_h_9', 'area_h_11'}
        battle['enemies'] = [r for r in battle['enemies'] if r['id'] not in ids]
        battle['encounters'] = [r for r in battle['encounters'] if r['id'] not in added]
        battle['unite_graphics'] = [r for r in battle['unite_graphics'] if r['id'] not in ids]
        actors.pop('enemy_area_magic', None)
        actors['programs']['programs'] = [p for p in actors['programs']['programs'] if not any(p['id'].startswith(f'melee/{i}/') for i in ids)]
        actors['animations']['resources'] = [r for r in actors['animations']['resources'] if r['id'] not in ids]
        for rows in (actors['counter']['enemies'], actors['counter']['melee']['enemies'],
                     actors['counter']['ranged']['dodges'], actors['counter']['party_melee']['dodges']):
            rows[:] = [r for r in rows if r['id'] not in ids]
        before = copy.deepcopy(actors)
        merged = exporter.combine(actors, self.packet)
        self.assertEqual(actors, before)
        self.assertEqual(exporter.combine(merged, self.packet), merged)
        atlas = Atlas(); atlas.image = Image.new('RGBA', (4096, 4096)); atlas.y = 4
        atlas.image.paste((17, 31, 49, 255), (0, 0, 4096, 3))
        proof = exporter.append_content(battle, actors, atlas)
        self.assertEqual(atlas.image.getpixel((4095, 2)), (17, 31, 49, 255))
        self.assertEqual({r['id'] for r in proof['catalogue']['formations']}, added)
        for identifier, region, section in (('sorcerer', 'E', 0x22aa0), ('siren', 'G', 0x216c8), ('earth_golem', 'H', 0x23d4c)):
            raw = self.raw['/' + region + '_DATA.BIN']
            graphic = next(r for r in battle['unite_graphics'] if r['id'] == identifier)
            for pose in graphic['poses']:
                for key, white in (('sprite', False), ('white', True)):
                    if key not in pose:
                        continue
                    expected, ax, ay = vram_pose(raw, section, pose['id'], packet=True, white=white, base=exporter.BASE)
                    sprite = pose[key]; r = sprite['rect']
                    actual = atlas.image.crop((r['x'], r['y'], r['x'] + r['w'], r['y'] + r['h']))
                    self.assertEqual((actual.size, sprite['anchor_x'], sprite['anchor_y']), (expected.size, ax, ay))
                    self.assertEqual(actual.tobytes(), expected.tobytes())

    def test_fixture_determinism_and_changed_source_refusal(self):
        self.assertEqual(self.packet, exporter.build())
        self.assertEqual(self.packet, json.loads((ROOT / 'game/tests/fixtures/enemy_area_magic_source.json').read_text()))
        real = exporter.source
        for name, offset in [('/E_DATA.BIN', 0x14a0), ('/G_DATA.BIN', 0x7b0), ('/G_DATA.BIN', 0x630),
                             ('/G_DATA.BIN', 0x5ac), ('/H_DATA.BIN', 0x2a18), ('/H_DATA.BIN', 0x2e04),
                             ('/E_DATA.BIN', 0x2240c + 40), ('/C_DATA.BIN', 0x1050)]:
            changed = bytearray(self.raw[name]); changed[offset] ^= 1
            with patch.object(exporter, 'source', side_effect=lambda filename: (bytes(changed), real(filename)[1]) if filename == name else real(filename)):
                with self.assertRaises(ValueError):
                    exporter.build()


if __name__ == '__main__':
    unittest.main()
