#!/usr/bin/env python3
"""Independent source-stream and animation checks for batch ranged actors."""
from pathlib import Path
import copy
import json
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from actor_script import OP_LEN_HW
import character_table
import export_battle_sprite_sections
import export_battle_trial
import export_first_room
from export_first_room import source
import export_party_ranged_actors as ranged
import export_physical_runes
import area_encounter_tables
import preparation


def raw_script(data, slot):
    table = struct.unpack_from('<I', data, 32)[0]
    offset = struct.unpack_from('<I', data, table + 4 * slot)[0]
    result = []
    while len(result) < 128:
        op = struct.unpack_from('<H', data, offset)[0]
        length = OP_LEN_HW[op]
        args = list(struct.unpack_from('<' + 'h' * (length - 1), data, offset + 2))
        result.append(dict(op=op, args=args))
        if op in (0, 1, 2):
            return result
        offset += length * 2
    raise AssertionError('unterminated source script')


class RangedActors(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packet, cls.proof = ranged.build()

    def test_batch_covers_member_projectiles_without_guessing_other_families(self):
        self.assertEqual(len(self.packet['bindings']), 18)
        self.assertEqual({row['id'] for row in self.proof['excluded']}, {'clive', 'kasumi'})
        programs = {row['id']: row for row in self.packet['programs']['programs']}
        resources = {row['id']: row for row in self.packet['animations']['resources']}
        for binding in self.packet['bindings']:
            self.assertIn(binding['attack_program'], programs)
            self.assertIn(binding['return_program'], programs)
            for instruction in programs[binding['attack_program']]['instructions']:
                child = instruction.get('command', {}).get('child')
                if child:
                    self.assertEqual(child['resource'], binding['id'])
                    self.assertIn(child['program'], programs)
                    self.assertIn(child['animation'], {clip['id'] for clip in resources[binding['id']]['clips']})

    def test_cleo_and_ted_programs_and_selected_poses_match_source(self):
        records = {preparation.stable_id(row['name']): row for row in character_table.records()}
        proofs = {row['id']: row for row in self.proof['characters']}
        resources = {row['id']: row for row in self.packet['animations']['resources']}
        for identifier in ('cleo', 'ted'):
            raw, _ = source('/' + records[identifier]['sprite_file'])
            programs = {row['id'].rsplit('/', 1)[-1]: row for row in proofs[identifier]['programs']}
            for name, slot in (('attack', 1), ('return', 4), ('hurt', 2), ('critical_hurt', 8), ('member_9', 9)):
                self.assertEqual(programs[name]['operations'], raw_script(raw, slot))
            section = struct.unpack_from('<I', raw, 36)[0]
            reference = export_battle_sprite_sections.decode_section(raw, section, character_id=identifier)
            for clip in resources[identifier]['clips']:
                original = reference.animations[clip['id']]
                self.assertTrue(original.resolved)
                self.assertEqual([(row['pose'], row['updates']) for row in clip['frames']],
                                 [(pose, ticks or 256) for pose, ticks in original.pairs])
            self.assertIn(17, {clip['id'] for clip in resources[identifier]['clips']})

    def test_all_ranged_critical_reactions_and_shared_pose_extent_match_source(self):
        records = {preparation.stable_id(row['name']): row for row in character_table.records()}
        clips = set()
        for character in self.proof['characters']:
            identifier = character['id']
            raw, _ = source('/' + records[identifier]['sprite_file'])
            critical = next(row for row in character['programs'] if row['id'].endswith('/critical_hurt'))
            self.assertEqual(critical['operations'], raw_script(raw, 8))
            used = {row['args'][1] for row in critical['operations'] if row['op'] == 24}
            if used == {3}:
                self.assertEqual(critical['operations'], raw_script(raw, 2))
            clips.update(used)
        self.assertEqual(clips, {3, 19})
        self.assertEqual(self.packet['critical_camera'], dict(updates=20, target=dict(
            position=[0,0,-81920], angles=[-3538944,0,2097152], c=[0,0,4194304], d=[40960000]*3)))
        resource = next(row for row in self.packet['animations']['resources'] if row['id'] == 'shared_impacts')
        self.assertEqual(resource['pose_count'], 98)
        self.assertEqual(self.proof['shared']['declared_pose_count'], 82)
        self.assertEqual({row['id'] for row in resource['clips']} & clips, clips)

    def test_enemy_dodge_bindings_match_capability_and_raw_script(self):
        for target in self.proof['targets']:
            raw, _ = source('/' + target['resource']['source']['file'].split('/')[-1])
            record = target['capability_source_offset'] - 0x26
            self.assertTrue(struct.unpack_from('<H', raw, record + 0x26)[0] & 4)
            base = area_encounter_tables.BASE
            table = struct.unpack_from('<I', raw, record + 40)[0] - base
            offset = struct.unpack_from('<I', raw, table + 12)[0] - base
            operations = []
            for _ in range(128):
                op = struct.unpack_from('<H', raw, offset)[0]
                size = OP_LEN_HW[op]
                args = list(struct.unpack_from('<' + 'h' * (size - 1), raw, offset + 2))
                operations.append(dict(op=op, args=args))
                if op in (0, 1, 2):
                    break
                offset += size * 2
            self.assertEqual(operations, target['operations'])
            self.assertIn(target['id'], {row['id'] for row in self.packet['dodges']})

    def test_candidate_cannot_enter_accepted_staging(self):
        with self.assertRaises(ValueError):
            ranged.export(ROOT / 'kit/work/accepted/ranged')

    def test_merge_extends_only_the_proven_shared_pose_table(self):
        base = json.loads((ROOT / 'game/tests/fixtures/battle_actor_library.json').read_text())
        original = next(row for row in base['animations']['resources'] if row['id'] == 'shared_impacts')
        clips = copy.deepcopy(original['clips'])
        self.assertEqual(original['pose_count'], 82)
        export_physical_runes.merge_libraries(base, self.packet)
        merged = next(row for row in base['animations']['resources'] if row['id'] == 'shared_impacts')
        self.assertEqual(merged['pose_count'], 98)
        self.assertTrue(all(clip in merged['clips'] for clip in clips))
        self.assertTrue({3, 19} <= {clip['id'] for clip in merged['clips']})
        invalid = copy.deepcopy(self.packet)
        next(row for row in invalid['animations']['resources'] if row['id'] == 'shared_impacts')['pose_count'] = 99
        with self.assertRaisesRegex(ValueError, 'conflicting actor pose table'):
            export_physical_runes.merge_libraries(base, invalid)

    def test_projectile_pieces_are_packed_from_their_source_poses(self):
        selected = {'cleo', 'ted'}
        roots = [(row['id'], row[key]) for row in self.packet['bindings'] if row['id'] in selected
                 for key in ('attack_program', 'return_program')]
        atlas = export_first_room.Atlas()
        resources = {'resources': [row['resource'] for row in self.proof['characters']]}
        graphics, _ = export_physical_runes.graphics(self.packet, resources, atlas, selected, roots)
        source_files = {'cleo': 'CRE.BIN', 'ted': 'TED.BIN'}
        for graphic in graphics:
            raw, _ = source('/' + source_files[graphic['id']])
            section = struct.unpack_from('<I', raw, 36)[0]
            poses, animations, _ = export_battle_trial.section_art(raw, section, animation_indices=[17],
                selected_poses_only=True, individual_pieces=True)
            for pose, _ in animations[17]:
                result = next(row for row in graphic['poses'] if row['id'] == pose)
                self.assertEqual(len(result['pieces']), len(poses[pose]))
                for entry, (image, x, y) in zip(result['pieces'], poses[pose]):
                    rect = entry['rect']
                    crop = atlas.image.crop((rect['x'], rect['y'], rect['x'] + rect['w'], rect['y'] + rect['h']))
                    self.assertEqual(crop.tobytes(), image.tobytes())
                    self.assertEqual((entry['anchor_x'], entry['anchor_y']), (x, y))

    def test_runtime_fixture_matches_the_source_batch(self):
        packet = copy.deepcopy(self.packet)
        selected = {'cleo', 'ted', 'juppo'}
        packet['bindings'] = [row for row in packet['bindings'] if row['id'] in selected]
        packet['programs']['programs'] = [row for row in packet['programs']['programs']
                                          if row['id'] == 'ranged/dodge/crow' or any(row['id'].startswith('ranged/' + name + '/') for name in selected)]
        packet['animations']['resources'] = [row for row in packet['animations']['resources'] if row['id'] in selected | {'shared_impacts', 'crow'}]
        packet['dodges'] = [row for row in packet['dodges'] if row['id'] == 'crow']
        fixture = ROOT / 'game/tests/fixtures/party_ranged_actor_library.json'
        self.assertEqual(packet, json.loads(fixture.read_text()))


if __name__ == '__main__':
    unittest.main()
