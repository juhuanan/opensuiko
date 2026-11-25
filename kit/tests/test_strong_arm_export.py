#!/usr/bin/env python3
"""Static Strong Arm dispatch, relocated children and independent source joins."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import export_counter_actors as exporter
from export_first_room import source
from export_unite_programs import compile_operations
from test_physical_rune_export import independent_stream
import maindec


class StrongArmExport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packet, cls.proof = exporter.build()
        cls.raw, cls.origin = source('/C_DATA.BIN')

    def test_dispatch_callbacks_and_release_guard_are_independently_pinned(self):
        raw = self.raw
        self.assertEqual(struct.unpack_from('<H', raw, 0x253BC + 38)[0], 12)
        self.assertEqual(struct.unpack_from('<I', raw, 0x253BC + 48)[0], 0x80080018)
        self.assertEqual(struct.unpack_from('<I', raw, 0x25414)[0], 0x80081250)
        self.assertEqual(struct.unpack_from('<I', raw, 0x25420)[0], 0x80081050)
        for first, last, digest in (
            (0x1050, 0x1250, 'da3a358f3050ad26abaad0c245730682f80fee8c7f9ff0944a3720dabc323eb7'),
            (0x1250, 0x1550, '76a3c85ca6ce31ec55bd62df2d491755373c0bfa309448243f12fef729977d03')):
            self.assertEqual(hashlib.sha256(raw[first:last]).hexdigest(), digest)
        for pc, word in {0x8008138C:0x10910009, 0x80081394:0x90620045,
                         0x800813A4:0x90A20005, 0x800813AC:0x10400043,
                         0x800813F4:0x24C65424, 0x80081440:0x24C6555C,
                         0x80081464:0x24C65578, 0x800814E4:0x24C65528,
                         0x80081170:0x30420002, 0x800811B0:0x30420010,
                         0x800811C0:0x3402001E, 0x80081244:0xACC00054}.items():
            self.assertEqual(struct.unpack_from('<I', raw, pc - 0x80080000)[0], word, hex(pc))
        self.assertEqual(maindec.mword(0x800E3C48), 0x1482000F)
        self.assertEqual(maindec.mword(0x800E3C84), 0xAC430030)

    def test_each_role_matches_an_independent_relocated_script_walker(self):
        binding = self.packet['cooperation']
        proofs = {row['id']: row for row in self.proof['programs']}
        programs = {row['id']: row for row in self.packet['programs']['programs']}
        addresses = {'fallback':0x25424, 'approach':0x25528, 'lift':0x2555C, 'launch':0x25578}
        for role, offset in addresses.items():
            key = binding[role + '_program']
            self.assertEqual(proofs[key]['operations'], independent_stream(self.raw, offset, 0x253FC, 0x80080000))
        key = 'melee/strong_arm/auxiliary/member_8'
        self.assertEqual(proofs[key]['operations'], independent_stream(self.raw, 0x25464, 0x253FC, 0x80080000))
        child = next(i['command']['child'] for i in programs[binding['fallback_program']]['instructions']
                     if 'child' in i.get('command', {}))
        self.assertEqual((child['resource'], child['program'], child['animation'], child['home'], child['draw_record']),
                         ('strong_arm', key, 14, 'parent_owner', True))
        self.assertIn(dict(command=dict(effect=dict(id='fixed_projectile', binding='self'))), programs[key]['instructions'])

    def test_local_slots_require_the_source_specific_mapping(self):
        ops = [dict(op=35,args=[1,6]),dict(op=0,args=[])]
        self.assertTrue(compile_operations(ops, 'other')[1])
        instructions, blocked, effects = compile_operations(ops, 'melee/strong_arm', {6:'ally_throw'})
        self.assertFalse(blocked)
        self.assertEqual(effects, ['ally_throw'])
        self.assertEqual(instructions[0], dict(command=dict(effect=dict(id='ally_throw', binding='self'))))
        self.assertTrue(compile_operations([dict(op=35,args=[1,9]),dict(op=0,args=[])], 'other')[1])

    def test_all_candidate_ally_resources_and_native_bundle_preserve_named_roles(self):
        binding = self.packet['cooperation']
        self.assertEqual(binding['allies'], ['kobold_type_1','kobold_type_2','kobold_type_3','strong_arm'])
        resources = {row['id']:row for row in self.packet['animations']['resources']}
        for identifier in binding['allies']:
            self.assertTrue({0,1} <= {clip['id'] for clip in resources[identifier]['clips']})
        self.assertTrue({7,8,9,13,14} <= {clip['id'] for clip in resources['strong_arm']['clips']})
        bundle = json.loads((ROOT/'game/tests/fixtures/cover_actor_library.json').read_text())
        self.assertEqual(bundle['schema'], 'suikoden-unite-actors/19')
        self.assertEqual(bundle['counter']['cooperation'], binding)
        world = json.loads((ROOT/'game/tests/fixtures/world_c_actor_library.json').read_text())
        content = world['actor_content']
        self.assertEqual(next(row for row in content['enemies'] if row['id']=='strong_arm')['action_policy'], 'source_melee')
        self.assertIn('world_c_encounter_8', [row['id'] for row in content['encounters']])
        self.assertIn('world_c_encounter_5', [row['id'] for row in content['encounters']])


if __name__ == '__main__':
    unittest.main()
