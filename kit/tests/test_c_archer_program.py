#!/usr/bin/env python3
"""Static C-region archer script and animation bindings; no original execution."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))

from area_encounter_tables import BASE
import battle_unite_camera
import maindec
from export_first_room import source
from export_physical_runes import stream
from export_unite_programs import animation_resource, compile_operations


class ArcherProgram(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw, cls.origin = source('/C_DATA.BIN')
        cls.table = 0x2289c

    def script(self, slot, address, size, digest, expected):
        self.assertEqual(struct.unpack_from('<I', self.raw, self.table + 4 * slot)[0], address)
        data = self.raw[address - BASE:address - BASE + size]
        self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
        cursor = 0
        for opcode, args in expected:
            count = 1 + len(args)
            self.assertEqual(struct.unpack_from('<' + 'h' * count, data, cursor), (opcode, *args))
            cursor += count * 2
        self.assertEqual(cursor, len(data))
        operations, _ = stream(self.raw, self.origin, address - BASE, self.table, BASE)
        self.assertEqual(operations, [dict(op=op, args=list(args)) for op, args in expected])
        instructions, blocked, effects = compile_operations(operations, 'archer/kobold_type_2', None, 'kobold_type_2')
        self.assertEqual(blocked, [])
        return operations, instructions, effects

    def test_target_selector_checks_front_row_locks_and_roll_order(self):
        self.assertEqual(struct.unpack_from('<I', self.raw, 0x2285c + 48)[0], 0x8008018c)
        self.assertEqual(hashlib.sha256(self.raw[0x18c:0x300]).hexdigest(),
                         '58bdd4f7dd981cd68db80995dd9610872791c1da4c04a168907723bf446bed3b')
        for address, word in {0x800801d4: 0x92020045, 0x800801ec: 0x2c420004,
                              0x800801f8: 0x92620005, 0x80080218: 0x0040f809,
                              0x80080220: 0x34030064, 0x80080224: 0x0043001a,
                              0x80080254: 0x28630033, 0x800802b8: 0xae34125c}.items():
            self.assertEqual(struct.unpack_from('<I', self.raw, address - BASE)[0], word, hex(address))

    def test_attack_and_projectile_lower_from_original_words(self):
        attack = [(15, (0, 1)), (15, (1, 8)), (9, (0,)), (4, (7,)), (5, ()),
                  (4, (8,)), (5, ()), (24, (11, 17, 6, 10, 0, -24)),
                  (28, (0, 2)), (4, (9,)), (5, ()), (26, (0, 4)), (0, ())]
        child = [(34, (1296,)), (30, (0,)), (35, (0, 1)), (31, (1,)),
                 (14, (2,)), (13, (4,)), (33, (3, 15, 0, 0, 0)),
                 (3, (10,)), (26, (1, 1)), (3, (3,)), (26, (1, 2)),
                 (21, ()), (2, ())]
        operations, compiled, effects = self.script(
            1, 0x800a28bc, 62, '046a810bb7465326f0bd5a58d915ddcb98f812b44e213fc3796ea745ed82347f', attack)
        self.assertEqual(effects, [])
        spawn = compiled[7]['command']['child']
        self.assertEqual((spawn['resource'], spawn['animation'], spawn['offset']), ('kobold_type_2', 17, [10, 0, -24]))
        _, child_code, effects = self.script(
            6, 0x800a28fc, 62, '4b81b65f3fd75a8cf969ffdea6cb04763a43259b3c3b2fe2b0f0fe1a52f6bea9', child)
        self.assertEqual(effects, ['aimed_projectile'])
        self.assertEqual(child_code[6]['command']['motion']['updates'], 15)
        _, main_origin = source('MAIN.EXE')
        _, children = battle_unite_camera.auxiliary_scripts(
            self.raw, self.origin, [dict(script=1, operations=operations)], main_origin,
            self.table + BASE, BASE)
        self.assertEqual([(child['id'], child['resource']) for child in children], [('member:6', 'member')])

    def test_source_zero_count_return_clips_supply_first_pair(self):
        for address, instruction in {0x800E2104: 0x0C038847, 0x800E2168: 0x24630004,
                                     0x800E2178: 0x90440000, 0x800E217C: 0x90420001}.items():
            self.assertEqual(maindec.mword(address), instruction)
        section = struct.unpack_from('<I', self.raw, 0x2285c + 44)[0] - BASE
        table = struct.unpack_from('<I', self.raw, section + 20)[0] - BASE
        resource, _ = animation_resource('kobold_type_2', self.raw, self.origin, {10, 11, 12}, section=section, base=BASE)
        for clip, expected in zip(resource['clips'], ((10, 0, 1), (11, 1, 5), (12, 0, 0)), strict=True):
            index, count, pose = expected
            offset = struct.unpack_from('<I', self.raw, table + 4 * index)[0] - BASE
            self.assertEqual((self.raw[offset], self.raw[offset + 4:offset + 6]), (count, bytes((pose, 1))))
            self.assertEqual((clip['id'], clip['frames'][0]['pose'], clip['frames'][0]['updates']), (index, pose, 1))


if __name__ == '__main__':
    unittest.main()
