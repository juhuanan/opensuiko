#!/usr/bin/env python3
"""Independent raw script, capability and F-table checks for the counter batch."""
import hashlib
import copy
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import character_table
import export_counter_actors as exporter
from export_first_room import source
import maindec
import preparation
from test_physical_rune_export import independent_stream


class CounterActors(unittest.TestCase):
    def test_schema_ten_survives_merges_and_unknown_schema_fails_before_mutation(self):
        from export_physical_runes import merge_libraries
        base = copy.deepcopy(self.packet)
        extra = dict(programs=dict(schema='suikoden-actor-programs/8', programs=[dict(id='noop',instructions=[dict(halt={})])]), animations=dict(resources=[]))
        merge_libraries(base, extra)
        self.assertEqual(base['programs']['schema'], 'suikoden-actor-programs/10')
        lower = copy.deepcopy(extra)
        merge_libraries(lower, self.packet)
        self.assertEqual(lower['programs']['schema'], 'suikoden-actor-programs/10')
        status = dict(programs=dict(schema='suikoden-actor-programs/10', programs=[dict(id='status',instructions=[dict(command=dict(status=dict(kind='poison',threshold_percent=20))),dict(halt={})])]), animations=dict(resources=[]))
        merge_libraries(base, status)
        self.assertEqual(base['programs']['schema'], 'suikoden-actor-programs/10')
        self.assertIn(status['programs']['programs'][0],base['programs']['programs'])
        sleep=copy.deepcopy(status)
        sleep['programs']['schema']='suikoden-actor-programs/11'
        sleep['programs']['programs'][0]['id']='sleep_status'
        sleep['programs']['programs'][0]['instructions'][0]['command']['status']['kind']='sleep'
        merge_libraries(base,sleep)
        self.assertEqual(base['programs']['schema'],'suikoden-actor-programs/11')
        self.assertIn(sleep['programs']['programs'][0],base['programs']['programs'])
        before = copy.deepcopy(base)
        extra['programs']['schema'] = 'suikoden-actor-programs/14'
        with self.assertRaisesRegex(ValueError, 'unsupported actor program schema'):
            merge_libraries(base, extra)
        self.assertEqual(base, before)

    def test_owner_callback_pointer_and_body_changes_are_rejected(self):
        original = exporter.source
        for offset in (0x23430, 0x8d4):
            def changed(path):
                raw, origin = original(path)
                if path == '/A_DATA.BIN':
                    raw = bytearray(raw)
                    raw[offset] ^= 1
                    raw = bytes(raw)
                return raw, origin
            with patch.object(exporter, 'source', side_effect=changed):
                with self.assertRaisesRegex(ValueError, 'Wild boar recipient callback changed'):
                    exporter.build()

    def test_crow_callback_pointer_curve_and_decision_mutations_are_rejected(self):
        original = exporter.source
        for offset in (0x21ab0, 0x178, 0x438, 0x604):
            def changed(path):
                raw, origin = original(path)
                if path == '/A_DATA.BIN':
                    raw = bytearray(raw);raw[offset] ^= 1;raw = bytes(raw)
                return raw, origin
            with patch.object(exporter, 'source', side_effect=changed):
                with self.assertRaisesRegex(ValueError, 'Crow dive callback changed'):
                    exporter.build()

    @classmethod
    def setUpClass(cls):
        cls.packet, cls.proof = exporter.build()

    def test_all_78_weapon_classes_and_13_enemy_flags_select_the_batch(self):
        catalogue = json.loads((ROOT / 'game/assets/profiles/character_weapons.json').read_text())['characters']
        by_id = {row['id']: row for row in catalogue}
        eligible = []
        for record, row in zip(character_table.records(), self.proof['party_capabilities'], strict=True):
            self.assertEqual(row['id'], preparation.stable_id(record['name']))
            self.assertEqual(row['weapon_range'], by_id[record['id']]['range'])
            if by_id[record['id']]['range_name'] in ('short', 'medium'):
                eligible.append(row['id'])
        self.assertEqual([row['id'] for row in self.packet['defenders']], eligible)
        self.assertEqual(len(eligible), 58)
        self.assertEqual(len(self.packet['enemies']), 13)
        self.assertEqual([row['id'] for row in self.packet['enemies'] if row['counterable']], ['red_soldier_ant', 'kobold_type_1'])
        for binding, proof in zip(self.packet['enemies'], self.proof['enemy_capabilities'], strict=True):
            raw, _ = source('/' + proof['source']['file'].split('/')[-1])
            features = int.from_bytes(raw[proof['source_offset']:proof['source_offset'] + 2], 'little')
            self.assertEqual((binding['id'], binding['counterable']), (proof['id'], bool(features & 1)))
            self.assertEqual(binding['counterable'], binding['attack_program'] is not None)
            self.assertEqual(binding['counterable'], binding['return_program'] is not None)

    def test_each_party_and_enemy_root_agrees_with_an_independent_script_walker(self):
        proofs = {row['id']: row for row in self.proof['programs']}
        members = {preparation.stable_id(row['name']): row for row in character_table.records()}
        for binding in self.packet['defenders']:
            raw, _ = source('/' + members[binding['id']]['sprite_file'])
            table = int.from_bytes(raw[32:36], 'little')
            for role, slot in (('response', 3), ('strike', 5), ('hurt', 2)):
                offset = int.from_bytes(raw[table + 4 * slot:table + 4 * slot + 4], 'little')
                self.assertEqual(proofs[binding[role + '_program']]['operations'], independent_stream(raw, offset, table))
        for binding in self.packet['enemies']:
            if not binding['counterable']:
                continue
            row = next(row for row in self.proof['resources'] if row['id'] == binding['id'])
            raw, _ = source('/' + row['source']['file'].split('/')[-1])
            table = int.from_bytes(raw[row['record_source_offset'] + 40:row['record_source_offset'] + 44], 'little') - row['pointer_base']
            for role, slot in (('attack', 1), ('return', 4)):
                offset = int.from_bytes(raw[table + 4 * slot:table + 4 * slot + 4], 'little') - row['pointer_base']
                self.assertEqual(proofs[binding[role + '_program']]['operations'], independent_stream(raw, offset, table, row['pointer_base']))

    def test_program_children_and_all_animation_frames_resolve(self):
        programs = {p['id']: p for p in self.packet['programs']['programs']}
        resources = {r['id']: r for r in self.packet['animations']['resources']}
        self.assertEqual((len(programs), len(resources)), (424, 88))
        for program in programs.values():
            self.assertEqual(program['instructions'][-1], dict(halt={}))
            for instruction in program['instructions']:
                child = instruction.get('command', {}).get('child')
                if child:
                    self.assertIn(child['program'], programs)
                    self.assertIn(child['animation'], [clip['id'] for clip in resources[child['resource']]['clips']])
        for proof in self.proof['resources']:
            raw, _ = source('/' + proof['source']['file'].split('/')[-1])
            section = proof['section_offset']; base = proof['pointer_base']
            table = int.from_bytes(raw[section + 20:section + 24], 'little') - base
            for clip in resources[proof['id']]['clips']:
                offset = int.from_bytes(raw[table + clip['id'] * 4:table + clip['id'] * 4 + 4], 'little') - base
                flags = raw[offset + 1]; count = max(1, raw[offset])
                expected = [(raw[offset + 4 + i * 2], raw[offset + 5 + i * 2] or 256) for i in range(count)]
                self.assertEqual([(frame['pose'], frame['updates']) for frame in clip['frames']], expected)
                self.assertEqual((clip['advances'], clip['loop'], clip['semitransparent']), (bool(flags & 1), bool(flags & 2), bool(flags & 4)))

    def test_relocated_archer_child_uses_its_enemy_script_table(self):
        resource = next(row for row in self.proof['resources'] if row['id'] == 'kobold_type_2')
        raw, _ = source('/' + resource['source']['file'].split('/')[-1])
        base = resource['pointer_base']
        table = int.from_bytes(raw[resource['record_source_offset'] + 40:resource['record_source_offset'] + 44], 'little') - base
        offset = int.from_bytes(raw[table + 6 * 4:table + 7 * 4], 'little') - base
        child = next(row for row in self.proof['programs'] if row['id'] == 'melee/kobold_type_2/auxiliary/member_6')
        self.assertEqual(child['spans'][0]['source_offset'], offset)
        self.assertEqual(child['operations'], independent_stream(raw, offset, table, base))

    def test_parry_roles_match_raw_capabilities_and_each_original_stream(self):
        parries = self.packet['parries']
        self.assertEqual(len(parries['attackers']), 58)
        self.assertEqual([row['id'] for row in parries['defenders']], ['kobold_type_1'])
        self.assertEqual({row['id'] for row in parries['attackers']}, {row['id'] for row in self.packet['defenders']})
        proofs = {row['id']: row for row in self.proof['programs']}
        members = {preparation.stable_id(row['name']): row for row in character_table.records()}
        for binding in parries['attackers']:
            raw, _ = source('/' + members[binding['id']]['sprite_file'])
            table = int.from_bytes(raw[32:36], 'little')
            for role, slot in (('attack', 1), ('return', 4)):
                offset = int.from_bytes(raw[table + 4 * slot:table + 4 * slot + 4], 'little')
                self.assertEqual(proofs[binding[role + '_program']]['operations'], independent_stream(raw, offset, table))
        for binding in parries['defenders']:
            origin = next(row for row in self.proof['resources'] if row['id'] == binding['id'])
            raw, _ = source('/' + origin['source']['file'].split('/')[-1])
            record = origin['record_source_offset']; base = origin['pointer_base']
            self.assertEqual(int.from_bytes(raw[record + 38:record + 40], 'little') & 2, 2)
            table = int.from_bytes(raw[record + 40:record + 44], 'little') - base
            for role, slot in (('response', 3), ('strike', 5), ('hurt', 2)):
                offset = int.from_bytes(raw[table + 4 * slot:table + 4 * slot + 4], 'little') - base
                self.assertEqual(proofs[binding[role + '_program']]['operations'], independent_stream(raw, offset, table, base))

    def test_cover_scripts_and_lock_wait_have_independent_source_writers(self):
        raw, _ = source('MAIN.EXE')
        proofs = {row['id']: row for row in self.proof['programs']}
        programs = {row['id']: row for row in self.packet['programs']['programs']}
        for role, address in (('guard', 0x8016C270), ('ward', 0x8016C29C), ('return', 0x8016C2B4)):
            key = self.packet['cover'][role + '_program']
            self.assertEqual(proofs[key]['operations'], independent_stream(raw,
                maindec.EXE_HEADER + address - maindec.MBASE, 0, maindec.MBASE - maindec.EXE_HEADER))
        self.assertEqual(programs['cover/return']['instructions'][0],
            dict(wait=dict(highlight_clear=dict(target='owner', bits=9))))
        self.assertEqual(self.packet['programs']['schema'], 'suikoden-actor-programs/10')
        for party in self.packet['melee']['party_reactions']:
            resource = next(row for row in self.packet['animations']['resources'] if row['id'] == party['id'])
            self.assertTrue({0, 1, 2, 5, 6} <= {row['id'] for row in resource['clips']})
        for pc, word in {0x800F4DA8:0x24C6C270, 0x800F4DBC:0x24C6C29C,
                         0x800F5ED4:0x30420002, 0x800F5F08:0x0C03DFA4,
                         0x800F5F0C:0x02002821, 0x800F5F14:0x0C038595,
                         0x800F5F2C:0x8C660008, 0x800F5F44:0x24C6C2B4,
                         0x800E4008:0x94480004, 0x800E403C:0x90420005,
                         0x800E4044:0x01021024, 0x800E4048:0x1440000B}.items():
            self.assertEqual(maindec.mword(pc), word, hex(pc))

    def test_source_melee_and_all_party_dodge_bindings_match_raw_streams(self):
        proofs = {row['id']: row for row in self.proof['programs']}
        members = {preparation.stable_id(row['name']): row for row in character_table.records()}
        self.assertEqual(len(self.packet['melee']['party_reactions']), 78)
        for binding in self.packet['melee']['party_reactions']:
            raw, _ = source('/' + members[binding['id']]['sprite_file'])
            table = int.from_bytes(raw[32:36], 'little')
            offset = int.from_bytes(raw[table + 12:table + 16], 'little')
            self.assertEqual(proofs[binding['response_program']]['operations'], independent_stream(raw, offset, table))
        self.assertEqual([row['id'] for row in self.packet['melee']['enemies']], ['bonbon','mosquito','crow','wild_boar','red_soldier_ant','kobold_type_1','kobold_type_2','kobold_type_3','strong_arm'])
        for binding in self.packet['melee']['enemies']:
            origin = next(row for row in self.proof['resources'] if row['id'] == binding['id'])
            raw, _ = source('/' + origin['source']['file'].split('/')[-1])
            record = origin['record_source_offset']; base = origin['pointer_base']
            callback = {'bonbon': 0x80080004, 'mosquito': 0x80080004, 'wild_boar': 0x80080760, 'crow': 0x80080604, 'red_soldier_ant': 0x80080adc, 'kobold_type_2': 0x8008018c, 'kobold_type_3': 0x80080490}.get(binding['id'], 0x80080018)
            self.assertEqual(int.from_bytes(raw[record + 48:record + 52], 'little'), callback)
            table = int.from_bytes(raw[record + 40:record + 44], 'little') - base
            for role, slot in (('attack', 1), ('hurt', 2), ('return', 4)):
                offset = int.from_bytes(raw[table + slot * 4:table + slot * 4 + 4], 'little') - base
                self.assertEqual(proofs[binding[role + '_program']]['operations'], independent_stream(raw, offset, table, base))
        refusals = self.proof['melee_refusals']
        self.assertEqual(refusals, [])
        callback = next(row for row in self.proof['callbacks'] if row['id'] == 'wild_boar_recipient_spin')
        self.assertEqual((callback['source_offset'], callback['byte_length']), (0x8d4, 0x7c))
        self.assertIn('wild_boar', [row['id'] for row in self.packet['melee']['enemies']])
        ant = next(row for row in self.packet['melee']['enemies'] if row['id'] == 'red_soldier_ant')
        raw, _ = source('/A_DATA.BIN')
        for role, address in (('attack', 0x800A5460), ('hurt', 0x800A5550)):
            row = proofs[ant['special'][role + '_program']]
            self.assertEqual(row['operations'], independent_stream(raw, address - 0x80080000, 0x800A5388 - 0x80080000, 0x80080000))
        raw, _ = source('/C_DATA.BIN')
        for pc, word in {0x80080068: 0x14400020, 0x80080078: 0x2C420004,
                         0x8008008C: 0x14400017, 0x80080090: 0x2414FFFF,
                         0x800800B0: 0x0043001A, 0x800800E0: 0x28630033,
                         0x80080108: 0x1282000A, 0x80080130: 0xA0430046}.items():
            self.assertEqual(int.from_bytes(raw[pc - 0x80080000:pc - 0x80080000 + 4], 'little'), word)
        for pc, word in {0x800F59A8: 0x30420002, 0x800F59B8: 0x02002021,
                         0x800F59BC: 0x0C03DFA4, 0x800F59C0: 0x02402821,
                         0x800F59C4: 0x02402021, 0x800F59C8: 0x0C038595,
                         0x800F59D8: 0x34420010, 0x800F5A64: 0x8C460008,
                         0x800F5A90: 0x24635CD0, 0x800E55D4: 0x8C650008,
                         0x800E5618: 0x00081080, 0x800E5620: 0x8C440000,
                         0x800E5630: 0xAC640054}.items():
            self.assertEqual(maindec.mword(pc), word, hex(pc))

    def test_locked_only_reference_corrections_have_static_delay_slot_writers(self):
        import area_encounter_tables
        policy = json.loads((ROOT / 'game/assets/campaign_policies/enemy_policy.json').read_text())
        vectors = json.loads((ROOT / 'game/assets/campaign_policies/enemy_policy_vectors.json').read_text())
        corrected = {row['record']: row for row in vectors['decisions'] if row['name'].endswith('/locked_only')}
        self.assertEqual(len(corrected), 15)
        for area in policy['areas']:
            raw, _ = source('/' + area['id'][-1].upper() + '_DATA.BIN')
            _, _, directory, _ = area_encounter_tables.chain(raw)
            table = int.from_bytes(raw[directory + 12 - 0x80080000:directory + 16 - 0x80080000], 'little') - 0x80080000
            for record in area['records']:
                if record['id'] not in corrected:continue
                native = int(record['id'].split('.')[-1])
                start = int.from_bytes(raw[table + 4 * native:table + 4 * native + 4], 'little') - 0x80080000
                callback = int.from_bytes(raw[start + 48:start + 52], 'little') - 0x80080000
                words = struct.unpack_from('<96I', raw, callback)
                matches = [i for i in range(3, len(words)) if words[i] == 0x2414FFFF and words[i - 1] & 0xFFFF0000 == 0x14400000 and words[i - 3] & 0xFC1FFFFF == 0x90020005]
                self.assertTrue(matches, record['id'])
                self.assertEqual(corrected[record['id']]['expect'], dict(draws_used=0, eligible_seen=True, kind='pending'))

    def test_extra_kobold_hurt_white_and_ko_pixels_match_independent_vram_sampling(self):
        import export_spell_scenes
        from test_export_unite_review import vram_pose
        packet, images, proof = export_spell_scenes.build(extra_hurt_ids=('kobold_type_1',))
        origin = next(row for row in self.proof['resources'] if row['id'] == 'kobold_type_1')
        raw, _ = source('/C_DATA.BIN')
        section = origin['section_offset']; base = origin['pointer_base']
        table = int.from_bytes(raw[section + 20:section + 24], 'little') - base
        binding = next(row for row in packet['hurt_poses'] if row['id'] == 'kobold_type_1')
        for field, animation, white in (('entry', 1, False), ('white_entry', 1, True), ('knockout', 3, False)):
            offset = int.from_bytes(raw[table + animation * 4:table + animation * 4 + 4], 'little') - base
            pose = raw[offset + 4]
            expected, x, y = vram_pose(raw, section, pose, base=base, white=white)
            index = binding[field]['entry'] if field == 'knockout' else binding[field]
            entry = packet['entries'][index]
            actual = images[entry['bitmap']]
            self.assertEqual((actual.size, entry['dx'], entry['dy']), (expected.size, -x, -y))
            self.assertEqual(actual.tobytes(), expected.tobytes())
        self.assertEqual(binding['knockout']['duration'], 94)
        fact = next(row for row in proof['airborne_facts'] if row['id'] == 'kobold_type_1')
        self.assertEqual(fact['source']['sha256'], origin['source']['sha256'])

    def test_callback_producers_consumers_and_hp_direction_are_pinned(self):
        for pc, word in {
            0x800F4F04: 0x0C03DF57, 0x800F4F14: 0x0C03DE39,
            0x800F4F2C: 0x8C460004, 0x800F4F3C: 0x24425DB4,
            0x800F5DF0: 0x30420001, 0x800F5E24: 0x8C46000C,
            0x800F5FD0: 0x30420002, 0x800F5FE0: 0xA4600040,
            0x800F5FE8: 0x8C460014, 0x800F6070: 0x30420002,
            0x800F6080: 0x02202021, 0x800F6084: 0x0C03DFA4,
            0x800F6088: 0x02002821, 0x800F608C: 0x02002021,
            0x800F6090: 0x0C038595, 0x800F6098: 0x8E420008,
            0x800F609C: 0xA6400040, 0x800F60A0: 0x8C460008,
            0x800F60CC: 0x24635CD0, 0x800F5D10: 0x30420004,
            0x800F5D20: 0x0C03DF16, 0x800F5D30: 0x0C03D247,
            0x800F5D68: 0x8C460010,
            0x800E0C7C: 0x86620012, 0x800E0C84: 0x1C400009,
            0x800E0C8C: 0x92020005, 0x800E0C94: 0x1440000E,
            0x800E0C9C: 0x0C038B6B, 0x800E2E1C: 0x8C46001C,
            0x800E2E24: 0x0C038E08,
            0x800F737C: 0x34100001, 0x800F7380: 0x26510054,
            0x800F7384: 0x8E220050, 0x800F7394: 0x0040F809,
            0x800F7398: 0x02002821, 0x800F73AC: 0x26100001,
            0x800F73B4: 0x1040FFF3,
        }.items():
            self.assertEqual(maindec.mword(pc), word, hex(pc))
        expected = ['8a8e34d6852a78f48836be34ec9d51bf0a384e78741c8821bbdff6398a174a06',
                    'b70bbe5d9d0e8e19e425b9b352595af988dfa40514c28705bcb35db5fbb6ca36',
                    'b964795a3e7fe962092d33f3edc9a7635a084b446f24ca844626c3038780e138',
                    'd2d57199dfcdb4c0657b05d1e26ead50d03a32099a6d5efeea46107ea96cfe53']
        self.assertEqual([row['sha256'] for row in self.proof['callbacks'][:4]], expected)
        for row in [*self.proof['callbacks'], *(span for program in self.proof['programs'] for span in program['spans'])]:
            filename = row['source']['file'].split('/')[-1]
            raw, _ = source('MAIN.EXE' if filename == 'MAIN.EXE' else '/' + filename)
            off = row['source_offset']; size = row['byte_length']
            self.assertLessEqual(off + size, len(raw))
            self.assertEqual(hashlib.sha256(raw[off:off + size]).hexdigest(), row['sha256'])

    def test_export_is_reproducible_matches_native_fixture_and_never_promotes(self):
        with tempfile.TemporaryDirectory(prefix='counter-export-') as temporary:
            exporter.export(Path(temporary))
            actual = json.loads((Path(temporary) / 'counter_actors.json').read_text())
            self.assertEqual(actual, self.packet)
            self.assertEqual(actual, json.loads((ROOT / 'game/tests/fixtures/counter_actor_library.json').read_text()))
        with self.assertRaisesRegex(ValueError, 'promotion is separate'):
            exporter.export(ROOT / 'kit/work/accepted/counter-forbidden')

    def test_combined_library_preserves_older_actions_and_refuses_conflicting_clips(self):
        original = json.loads((ROOT / 'game/tests/fixtures/battle_actor_library.json').read_text())
        before = copy.deepcopy(original)
        combined = exporter.combine(original, self.packet)
        self.assertEqual(original, before)
        old = json.loads((ROOT / 'game/tests/fixtures/battle_parry_library.json').read_text())
        current_programs = {row['id']: row for row in combined['programs']['programs']}
        for row in old['programs']['programs']:
            self.assertEqual(current_programs[row['id']], row)
        self.assertEqual(combined['schema'], 'suikoden-unite-actors/18')
        self.assertEqual(combined['counter']['cover'], self.packet['cover'])
        self.assertEqual(combined['unites'], original['unites'])
        self.assertEqual(combined['physical'], original['physical'])
        self.assertEqual(len(combined['programs']['programs']), 529)
        broken = copy.deepcopy(self.packet)
        resource = next(row for row in broken['animations']['resources'] if row['id'] == 'hero')
        resource['clips'][0]['frames'][0]['updates'] += 1
        with self.assertRaisesRegex(ValueError, 'conflicting actor animation'):
            exporter.combine(original, broken)

    def test_combined_candidate_body_art_matches_independent_vram_sampling(self):
        from export_first_room import Atlas
        import export_physical_runes
        from test_export_unite_review import vram_pose
        physical, proof = export_physical_runes.build()
        export_physical_runes.merge_libraries(physical, self.packet)
        identifiers = {'hero', 'gremio', 'pahn', 'viktor', 'tai_ho', 'yam_koo', 'maas', 'kasumi', 'valeria', 'ronnie', 'juppo', 'bonbon', 'wild_boar', 'crow', 'red_soldier_ant', 'kobold_type_1', 'kobold_type_2', 'strong_arm'}
        atlas = Atlas()
        graphics, origins = export_physical_runes.graphics(physical, proof, atlas, identifiers, exporter.graphic_roots(self.packet))
        count = whites = 0
        for graphic, origin in zip(graphics, origins, strict=True):
            raw, _ = source('/' + origin['source']['file'].split('/')[-1])
            resource = next(row for row in physical['animations']['resources'] if row['id'] == graphic['id'])
            needed = {frame['pose'] for clip in resource['clips'] for frame in clip['frames']}
            self.assertEqual({pose['id'] for pose in graphic['poses']}, needed)
            for pose in graphic['poses']:
                expected, x, y = vram_pose(raw, origin['section_offset'], pose['id'], packet=True, base=origin['pointer_base'])
                r = pose['sprite']['rect']; actual = atlas.image.crop((r['x'], r['y'], r['x'] + r['w'], r['y'] + r['h']))
                self.assertEqual((actual.size, pose['sprite']['anchor_x'], pose['sprite']['anchor_y']), (expected.size, x, y))
                self.assertEqual(actual.tobytes(), expected.tobytes())
                if 'white' in pose:
                    expected, x, y = vram_pose(raw, origin['section_offset'], pose['id'], packet=True, white=True, base=origin['pointer_base'])
                    r = pose['white']['rect']; actual = atlas.image.crop((r['x'], r['y'], r['x'] + r['w'], r['y'] + r['h']))
                    self.assertEqual((actual.size, pose['white']['anchor_x'], pose['white']['anchor_y']), (expected.size, x, y))
                    self.assertEqual(actual.tobytes(), expected.tobytes())
                    self.assertEqual(origin['white_palette']['byte_length'], 64)
                    whites += 1
                count += 1
        self.assertGreater(count, 50)
        self.assertGreater(whites, 0)


if __name__ == '__main__':
    unittest.main()
