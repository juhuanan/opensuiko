#!/usr/bin/env python3
"""Static extraction, equivalence/diff, party clip-3 and admission gates for regional enemies."""
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
import character_table
import export_enemy_regional as exporter
from export_first_room import Atlas, source
import preparation
from test_export_unite_review import vram_pose
from test_physical_rune_export import independent_stream


class RegionalEnemySource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packet = exporter.build()
        cls.raw = {
            name: source(name)[0]
            for name in ('MAIN.EXE', '/D_DATA.BIN', '/F_DATA.BIN', '/H_DATA.BIN')
        }

    def test_scripts_and_all_78_party_returns_match_independent_disc_streams(self):
        progs = {p['id']: p for p in self.packet['programs']['programs']}
        self.assertEqual(self.packet['programs']['schema'], 'suikoden-actor-programs/13')
        self.assertIn('party_reaction/clive/return', progs)
        self.assertEqual(len(self.packet['party_return_compiled']), 78)
        self.assertEqual(len(self.packet['provenance']['party_returns']), 78)
        self.assertEqual(len(self.packet['provenance']['party_resources']), 78)

        recs = {preparation.stable_id(r['name']): r for r in character_table.records()}
        by_record = self.packet['provenance']['records']
        for ident, proof in self.packet['provenance']['party_returns'].items():
            raw, _ = source('/' + recs[ident]['sprite_file'])
            table = struct.unpack_from('<I', raw, 32)[0]
            self.assertEqual(proof['operations'], independent_stream(raw, proof['spans'][0]['source_offset'], table, 0), ident)
            for span in proof['spans']:
                self.assertEqual(
                    hashlib.sha256(raw[span['source_offset']:span['source_offset'] + span['byte_length']]).hexdigest(),
                    span['sha256'],
                )
        for prog_id, proof in self.packet['provenance']['programs'].items():
            spans = proof['spans']
            first_span = spans[0]
            if prog_id == 'party_reaction/clive/return':
                raw, _ = source('/' + recs['clive']['sprite_file'])
                table = struct.unpack_from('<I', raw, 32)[0]
                expected_ops = independent_stream(raw, first_span['source_offset'], table, 0)
            elif prog_id == 'melee/shadow_man/hurt':
                raw = self.raw['/F_DATA.BIN']
                op_args = {0: 0, 3: 1, 4: 1, 14: 1, 21: 0, 23: 8, 24: 6, 26: 2, 30: 1, 35: 2, 36: 1, 38: 0, 39: 0}
                cursor = first_span['source_offset']
                expected_ops = []
                while True:
                    op, = struct.unpack_from('<h', raw, cursor)
                    cursor += 2
                    argc = op_args[op]
                    args = list(struct.unpack_from(f'<{argc}h', raw, cursor)) if argc else []
                    cursor += 2 * argc
                    expected_ops.append(dict(op=op, args=args))
                    if op in (0, 36):
                        break
                self.assertEqual(expected_ops[-1], {'op': 36, 'args': [4]})
            elif '/auxiliary/' in prog_id:
                raw = self.raw['MAIN.EXE']
                expected_ops = independent_stream(raw, first_span['source_offset'], None, 0)
            else:
                ident = prog_id.split('/')[1]
                src_file = by_record[ident]['source']['file'].split('/')[-1]
                raw = self.raw['/' + src_file]
                table = by_record[ident]['atab_offset']
                expected_ops = independent_stream(raw, first_span['source_offset'], table, exporter.BASE)
            self.assertEqual(proof['operations'], expected_ops, prog_id)
            for span in spans:
                span_file = span['source']['file'].split('/')[-1]
                s_raw, _ = source('MAIN.EXE' if span_file == 'MAIN.EXE' else '/' + span_file)
                self.assertEqual(
                    hashlib.sha256(s_raw[span['source_offset']:span['source_offset'] + span['byte_length']]).hexdigest(),
                    span['sha256'],
                )

        # Verify hold_coordinator_dispatch and tail_return VM encodings
        creeper_sp = progs['melee/creeper/special']['instructions']
        self.assertTrue(any(ins.get('command', {}).get('hold_coordinator_dispatch') for ins in creeper_sp))
        shadow_hurt = progs['melee/shadow_man/hurt']['instructions']
        self.assertEqual(shadow_hurt[-2:], [{'command': {'tail_return': True}}, {'halt': {}}])

    def test_enemy_and_party_clip3_animations_match_independent_raw_tables(self):
        resources = {r['id']: r for r in self.packet['animations']['resources']}
        self.assertEqual(len(self.packet['animations']['resources']), 4 + 78 + 1)
        for ident, disc, section, end_clips in (
            ('creeper', '/D_DATA.BIN', 0x24894, 24),
            ('shadow_man', '/F_DATA.BIN', 0x22E78, 15),
            ('mirage_f', '/F_DATA.BIN', 0x24F7C, 16),
            ('mirage_h', '/H_DATA.BIN', 0x21A84, 16),
        ):
            raw = self.raw[disc]
            res = resources[ident]
            p = lambda off: struct.unpack_from('<I', raw, off)[0] - exporter.BASE
            frames, poses = p(section + 20), p(section + 16)
            self.assertEqual(res['pose_count'], struct.unpack_from('<H', raw, section)[0])
            for clip in res['clips']:
                self.assertLess(clip['id'], end_clips)
                off = p(frames + clip['id'] * 4)
                expected = []
                for i in range(max(1, raw[off])):
                    pose, dur = raw[off + 4 + 2 * i:off + 6 + 2 * i]
                    entry = p(poses + 4 * pose)
                    expected.append(dict(pose=pose, updates=dur or 256, attachment=[raw[entry + 6] - raw[entry + 4], raw[entry + 7] - raw[entry + 5]]))
                self.assertEqual(clip['frames'], expected)

        for rec in character_table.records():
            ident = preparation.stable_id(rec['name'])
            res = resources[ident]
            self.assertEqual([c['id'] for c in res['clips']], [3])
            raw, _ = source('/' + rec['sprite_file'])
            section = struct.unpack_from('<I', raw, 36)[0]
            frames = struct.unpack_from('<I', raw, section + 20)[0]
            off = struct.unpack_from('<I', raw, frames + 3 * 4)[0]
            pose_count = max(1, raw[off])
            self.assertEqual(len(res['clips'][0]['frames']), pose_count)

    def test_mips_callbacks_and_f3_h2_separate_qualification(self):
        raw_d = self.raw['/D_DATA.BIN']
        raw_f = self.raw['/F_DATA.BIN']
        raw_h = self.raw['/H_DATA.BIN']

        # D3 shrink_spin: draw_angles[0] += 255, draw_angles[1] = 1, draw_size_q12 -= 128 until < 256
        self.assertEqual(struct.unpack_from('<I', raw_d, 0x1C84)[0], 0x34020001)
        self.assertEqual(struct.unpack_from('<I', raw_d, 0x1C9C)[0], 0x244200FF)
        self.assertEqual(struct.unpack_from('<I', raw_d, 0x1CB4)[0], 0x2442FF80)
        self.assertEqual(struct.unpack_from('<I', raw_d, 0x1CBC)[0], 0x28420100)
        # D3 spit_expand: += 128 until >= 4096
        self.assertEqual(struct.unpack_from('<I', raw_d, 0x1D0C)[0], 0x24420080)
        self.assertEqual(struct.unpack_from('<I', raw_d, 0x1D14)[0], 0x28421000)

        # F2 atab[8] +-0x5000 camera Z shake and atab[9] 80-tick threshold
        self.assertEqual(struct.unpack_from('<I', raw_f, 0x1C90)[0], 0x34025000)
        self.assertEqual(struct.unpack_from('<I', raw_f, 0x1C94)[0], 0x2402B000)
        self.assertEqual(struct.unpack_from('<I', raw_f, 0x210C)[0], 0x28420050)

        # F3 vs H2 Mirage exact diffs
        by_id = {r['id']: r for r in self.packet['enemy_regional']}
        self.assertEqual(by_id['shadow_man']['shadow_column'], dict(
            segments=32, radial_start_q12=1, step_q12=64,
            shape=dict(radius=120, top_radius=120, base_height=-5, height=0,
                       inner=[128]*3, outer=[0]*3)))
        self.assertEqual(struct.unpack_from('<I', raw_f, 0x21D8)[0], 0x24420040)
        self.assertEqual(struct.unpack_from('<I', raw_f, 0x21F8)[0], 0x24420040)
        self.assertEqual(struct.unpack_from('<I', raw_f, 0x221C)[0], 0x2442FFC0)
        self.assertTrue(by_id['mirage_f']['wait_100'])
        self.assertFalse(by_id['mirage_h']['wait_100'])
        for identifier, raw, start in (('mirage_f', raw_f, 0x25B0), ('mirage_h', raw_h, 0xB28)):
            self.assertEqual(by_id[identifier]['mirage_visual'], dict(
                pose=0, crop=[8, 0, 39, 63], copies=7, modulation=128, spread_step_q12=4096))
            self.assertEqual(struct.unpack_from('<I', raw, start + 0x2AC)[0], 0x2A820007)
            self.assertEqual(struct.unpack_from('<I', raw, start + 0x234)[0], 0x34050002)
            self.assertEqual(struct.unpack_from('<I', raw, start + 0x310)[0], 0x34020080)
            self.assertEqual(struct.unpack_from('<I', raw, start + 0x570)[0], 0x26521000)
        self.assertEqual(struct.unpack_from('<I', raw_f, 0x28EC)[0], 0x3C03FFFE)  # -2 * 65536 = -32*4096
        self.assertEqual(struct.unpack_from('<I', raw_f, 0x3C74)[0], 0x3C030002)  # +2 * 65536 = +32*4096
        self.assertEqual(struct.unpack_from('<I', raw_h, 0xB28 + (0x28EC - 0x25B0))[0], 0x3C03FFFE)
        self.assertEqual(struct.unpack_from('<I', raw_h, 0x1EB0 + (0x3C74 - 0x3938))[0], 0x3C030002)

        # Main script dispatcher check
        main = self.raw['MAIN.EXE']
        for p in self.packet['provenance']['main_scripts']:
            self.assertEqual(
                hashlib.sha256(main[p['source_offset']:p['source_offset'] + p['byte_length']]).hexdigest(),
                p['sha256'],
            )

    def test_combine_validation_and_normal_admission(self):
        from PIL import Image
        battle = json.loads((ROOT / 'game/tests/fixtures/journey_unites_battle.json').read_text())
        actors = json.loads((ROOT / 'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        ids = {'creeper', 'shadow_man', 'mirage_f', 'mirage_h'}
        added_encounters = {
            'area_d_7', 'area_d_8', 'area_d_9', 'area_d_10', 'area_d_12',
            'area_f_4', 'area_f_5', 'area_f_6', 'area_f_7', 'area_f_8',
            'area_h_4', 'area_h_5', 'area_h_6', 'area_h_10', 'area_h_12',
        }
        battle['enemies'] = [r for r in battle['enemies'] if r['id'] not in ids]
        battle['encounters'] = [r for r in battle['encounters'] if r['id'] not in added_encounters]
        battle['unite_graphics'] = [r for r in battle['unite_graphics'] if r['id'] not in ids]
        actors.pop('enemy_regional', None)
        actors['programs']['programs'] = [
            p for p in actors['programs']['programs']
            if p['id'] != 'party_reaction/clive/return' and not any(p['id'].startswith(f'melee/{i}/') for i in ids)
        ]
        for res in actors['animations']['resources']:
            res['clips'] = [c for c in res['clips'] if c['id'] != 3 or res['id'] not in {preparation.stable_id(r['name']) for r in character_table.records()}]
        actors['animations']['resources'] = [r for r in actors['animations']['resources'] if r['id'] not in ids]
        for r in actors['counter']['melee']['party_reactions']:
            r.pop('return_program', None)
        for rows in (
            actors['counter']['enemies'],
            actors['counter']['melee']['enemies'],
            actors['counter']['ranged']['dodges'],
            actors['counter']['party_melee']['dodges'],
        ):
            rows[:] = [r for r in rows if r['id'] not in ids]

        merged = exporter.combine(actors, self.packet)
        self.assertEqual(merged['schema'], 'suikoden-unite-actors/40')
        self.assertEqual(exporter.combine(merged, self.packet), merged)

        bad = copy.deepcopy(merged)
        bad['enemy_regional'][0]['special_hits'] = 99
        with self.assertRaisesRegex(ValueError, 'Conflicting enemy_regional'):
            exporter.combine(bad, self.packet)

        atlas = Atlas()
        atlas.image = Image.new('RGBA', (4096, 4096))
        atlas.y = 4
        atlas.image.paste((17, 31, 49, 255), (0, 0, 4096, 3))
        proof = exporter.append_content(battle, actors, atlas)
        self.assertEqual((battle['schema'], actors['schema']), ('suikoden-battle-trial/43', 'suikoden-unite-actors/40'))
        self.assertEqual((len(battle['party']), len(battle['enemies']), len(battle['encounters'])), (53, 32, 96))
        self.assertEqual({r['id'] for r in proof['catalogue']['formations']}, added_encounters)

        for ident, disc, sec in (
            ('creeper', '/D_DATA.BIN', 0x24894),
            ('shadow_man', '/F_DATA.BIN', 0x22E78),
            ('mirage_f', '/F_DATA.BIN', 0x24F7C),
            ('mirage_h', '/H_DATA.BIN', 0x21A84),
        ):
            raw = self.raw[disc]
            graphic = next(r for r in battle['unite_graphics'] if r['id'] == ident)
            for pose in graphic['poses']:
                for key, white in (('sprite', False), ('white', True)):
                    if key not in pose:
                        continue
                    expected, ax, ay = vram_pose(raw, sec, pose['id'], packet=True, white=white, base=exporter.BASE)
                    sprite = pose[key]
                    r = sprite['rect']
                    actual = atlas.image.crop((r['x'], r['y'], r['x'] + r['w'], r['y'] + r['h']))
                    self.assertEqual((actual.size, sprite['anchor_x'], sprite['anchor_y']), (expected.size, ax, ay))
                    self.assertEqual(actual.tobytes(), expected.tobytes())

    def test_determinism_and_changed_source_refusal(self):
        self.assertEqual(self.packet, exporter.build())
        real = exporter.source
        for name, offset in (
            ('/D_DATA.BIN', 0x1C38),
            ('/D_DATA.BIN', 0x24830),
            ('/F_DATA.BIN', 0x2280),
            ('/F_DATA.BIN', 0x22B18 + 8),
            ('/H_DATA.BIN', 0x1DC0),
            ('MAIN.EXE', 2048 + 0x800E557C - 0x800C0000),
        ):
            changed = bytearray(self.raw[name])
            changed[offset] ^= 1
            with patch.object(
                exporter,
                'source',
                side_effect=lambda filename: (bytes(changed), real(filename)[1]) if filename == name else real(filename),
            ):
                with self.assertRaises(ValueError):
                    exporter.build()


if __name__ == '__main__':
    unittest.main()
