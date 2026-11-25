#!/usr/bin/env python3
"""Static A/B/C selector and Ant impact evidence; never execute original code."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from export_first_room import source

FRONT_DIGEST = '9c901e462024912c44d42860ecfd768b3bfbde347e0242b65eac190d3ea1afd3'


def verify_front_selector(raw, start):
    """Compare complete selectors, normalizing only their relocated direct jumps."""
    reference, _ = source('/A_DATA.BIN')
    reference = reference[4:0x178]
    assert hashlib.sha256(reference).hexdigest() == FRONT_DIGEST
    candidate = raw[start:start + len(reference)]
    assert len(candidate) == len(reference)
    for offset in range(0, len(reference), 4):
        expected = struct.unpack_from('<I', reference, offset)[0]
        actual = struct.unpack_from('<I', candidate, offset)[0]
        assert expected >> 26 == actual >> 26, hex(start + offset)
        if expected >> 26 in (2, 3):
            reference_pc = 0x80080004 + offset
            actual_pc = 0x80080000 + start + offset
            expected = (((reference_pc + 4) & 0xf0000000) | ((expected & 0x3ffffff) << 2)) - 0x80080004
            actual = (((actual_pc + 4) & 0xf0000000) | ((actual & 0x3ffffff) << 2)) - (0x80080000 + start)
        assert actual == expected, hex(start + offset)


class EnemyPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.area, cls.origin = source('/A_DATA.BIN')

    def word(self, address):
        return struct.unpack_from('<I', self.area, address - 0x80080000)[0]

    def pins(self, words):
        for address, expected in words.items():
            self.assertEqual(self.word(address), expected, hex(address))

    def branch(self, address, opcode, destination):
        word = self.word(address)
        self.assertEqual(word >> 26, opcode)
        displacement = struct.unpack('<h', struct.pack('<H', word & 65535))[0]
        self.assertEqual(address + 4 + 4 * displacement, destination)

    def test_front_and_all_row_scans_preserve_guards_rng_loop_and_result_stores(self):
        self.assertEqual(self.origin['sha256'], '1739375bf8292fbfdbf0eba749035a772448dc060e68a1d102db2ec66d882045')
        verify_front_selector(self.area, 4)
        self.assertEqual(hashlib.sha256(self.area[0x604:0x760]).hexdigest(),
                         'f7b1c2b988290b84698e7ac73a31083e21497088dba0c96c7f34296bd65ca8b7')
        self.pins({0x8008004c:0x92020045, 0x8008005c:0x92020044,
                   0x80080064:0x2c420004, 0x80080070:0x92620005,
                   0x8008007c:0x2414ffff, 0x80080088:0x8c420000,
                   0x80080090:0x0040f809, 0x80080098:0x34030064,
                   0x8008009c:0x0043001a, 0x800800c4:0x00001810,
                   0x800800cc:0x28630033, 0x800800d8:0x2673008c,
                   0x800800ec:0x26100054, 0x8008011c:0xa0430046,
                   0x80080130:0xae34125c, 0x80080148:0xa0540049,
                   0x8008064c:0x92420045, 0x8008065c:0x92620005,
                   0x80080668:0x2414ffff, 0x8008067c:0x0040f809,
                   0x80080688:0x0043001a, 0x800806b0:0x00001810,
                   0x800806b8:0x28630033, 0x80080704:0xa0430046,
                   0x80080730:0xa0540049})
        for address, opcode, target in ((0x80080054,5,0x800800d8),
                (0x80080068,4,0x800800d8),(0x80080078,5,0x800800d8),
                (0x800800d0,4,0x80080128),(0x800800e8,4,0x8008004c),
                (0x800800f4,4,0x80080120),(0x800800fc,5,0x80080130),
                (0x80080654,5,0x800806c4),(0x80080664,5,0x800806c4),
                (0x800806bc,4,0x80080710),(0x800806d0,4,0x8008064c)):
            self.branch(address, opcode, target)
        # Crow's full scan body has no formation-byte load; it can reach both rows.
        crow = struct.unpack('<' + 'I' * ((0x6d8-0x64c)//4), self.area[0x64c:0x6d8])
        self.assertFalse(any(word >> 26 == 36 and word & 65535 == 0x44 for word in crow))

    def test_b_and_c_ordinary_selectors_are_relocated_copies_of_the_complete_front_selector(self):
        for region, start in (('B', 0x6c), ('C', 0x18)):
            raw, _ = source('/' + region + '_DATA.BIN')
            verify_front_selector(raw, start)

    def test_relocation_comparison_rejects_changed_row_guard_branch_jump_and_truncation(self):
        for offset in (0x64, 0xe8, 0x120):
            changed = bytearray(self.area)
            changed[offset] ^= 1
            with self.assertRaises(AssertionError):
                verify_front_selector(changed, 4)
        with self.assertRaises(AssertionError):
            verify_front_selector(self.area[:0x174], 4)

    def test_eight_later_enemies_share_the_complete_ordinary_front_selector(self):
        from war_text import decode
        cases = (('D',2,'Mad Ivy'), ('E',3,'Hell Hound'), ('E',4,'Grave Master'),
                 ('F',1,'Ivy'), ('G',2,'Grizzly Bear'), ('H',1,'Rabbit Bird'),
                 ('Z',2,'Simurgh'), ('Z',3,'Orc'))
        for region, native, name in cases:
            raw, _ = source('/' + region + '_DATA.BIN')
            pointer = lambda offset: struct.unpack_from('<I', raw, offset)[0] - 0x80080000
            directory = pointer(pointer(pointer(0) + 12))
            table = pointer(directory + 12)
            record = pointer(table + native*4)
            self.assertEqual(decode(raw[record:record+16], length=16)[0].strip(), name)
            verify_front_selector(raw, pointer(record + 48))

    def test_ant_special_uses_scaled_remainder_threshold_and_installs_twenty_update_callback(self):
        self.assertEqual(hashlib.sha256(self.area[0xadc:0xd1c]).hexdigest(),
                         'f506a62b8ead908269158ed527bfbd12b758000f2976b3afe2f1cf76308f3ec1')
        self.pins({0x80080c20:0xa2140049, 0x80080c2c:0x8c420000,
                   0x80080c34:0x0040f809, 0x80080c3c:0x00021840,
                   0x80080c40:0x00621821, 0x80080c44:0x000318c0,
                   0x80080c48:0x00621821, 0x80080c4c:0x00031880,
                   0x80080c50:0x34027fff, 0x80080c54:0x0062001a,
                   0x80080c7c:0x00001812, 0x80080c80:0x34020064,
                   0x80080c84:0x0062001a, 0x80080cac:0x00001010,
                   0x80080cb4:0x2842004d, 0x80080cc4:0x34020014,
                   0x80080cc8:0xae421264, 0x80080cd0:0x8c620004,
                   0x80080cd4:0x3c06800a, 0x80080cd8:0x24c65460,
                   0x80080cdc:0x0040f809, 0x80080ce4:0x3c028008,
                   0x80080ce8:0x24420950, 0x80080cec:0xae020050})
        self.branch(0x80080cb8,5,0x80080cf4)
        vectors = json.loads((ROOT / 'game/tests/fixtures/ant_special.json').read_text())
        self.assertEqual(vectors, [[roll, (roll*100//32767)%100 >= 77]
                                  for roll in (0,1,20000,25000,25230,25231,25232,25559,30000,32439,32766,32767)])
        self.assertEqual(vectors[-1], [32767, False])

    def test_ant_impact_flag_gates_hurt_double_damage_and_callback_clear(self):
        self.assertEqual(hashlib.sha256(self.area[0x950:0xa28]).hexdigest(),
                         '4e7cfe57e05f81a6b3e4c0a8d1cf514229fb89be493a51c32affb72f7d23e994')
        self.pins({0x8008098c:0x94620040, 0x80080994:0x30420002,
                   0x800809a4:0x90700004, 0x800809a8:0x8c420004,
                   0x800809ac:0x3c06800a, 0x800809b0:0x24c65550,
                   0x800809b4:0x0040f809, 0x800809c4:0x8c42000c,
                   0x800809cc:0x0040f809, 0x800809dc:0x8c630010,
                   0x800809e4:0x0060f809, 0x800809e8:0x00022840,
                   0x80080a04:0xac400050})
        self.branch(0x80080998,4,0x80080a08)

    def test_rabbit_scales_both_draws_and_marks_front_eligibility_before_selectability(self):
        raw, _ = source('/B_DATA.BIN')
        word = lambda address: struct.unpack_from('<I', raw, address - 0x80080000)[0]
        self.assertEqual(word(0x80080000 + 0x1f748 + 48), 0x80080664)
        self.assertEqual(hashlib.sha256(raw[0x664:0x988]).hexdigest(),
                         'e346180e41b3bedf8b3687c4085890fa3dc6e3281a6d407999d0157a29a02a7a')
        pins = {0x8008069c:0x34107fff, 0x800806a0:0x00021840,
                0x800806a4:0x00621821, 0x800806a8:0x000318c0,
                0x800806ac:0x00621821, 0x800806b0:0x00031880,
                0x800806b4:0x0070001a, 0x800806dc:0x00001812,
                0x800806e4:0x28630033, 0x80080708:0x00021840,
                0x8008070c:0x00621821, 0x80080710:0x000318c0,
                0x80080714:0x00621821, 0x80080718:0x00031880,
                0x8008071c:0x0070001a, 0x80080744:0x00001812,
                0x80080748:0x8e22001c, 0x80080750:0x0062001a,
                0x80080778:0x00001010, 0x80080780:0x24520001,
                0x80080788:0x8c62014c, 0x80080840:0x8c420154,
                0x80080858:0x92620044, 0x80080860:0x2c420004,
                0x80080874:0x8c42014c, 0x80080878:0x2412ffff,
                0x8008087c:0x0040f809, 0x8008089c:0x0040f809,
                0x800808bc:0x0062001a, 0x800808e4:0x00001812,
                0x800808ec:0x28630033, 0x80080938:0xa0430046}
        for address, expected in pins.items():
            self.assertEqual(word(address), expected, hex(address))
        for address, opcode, target in ((0x80080798,4,0x80080824),
                (0x800807a8,4,0x80080824),(0x80080864,4,0x800808f8),
                (0x80080884,4,0x800808f8),(0x80080910,4,0x8008093c),
                (0x80080918,5,0x80080944)):
            value = word(address)
            self.assertEqual(value >> 26, opcode)
            displacement = struct.unpack('<h', struct.pack('<H', value & 65535))[0]
            self.assertEqual(address + 4 + 4*displacement, target)
        main, _ = source('MAIN.EXE')
        base, size = struct.unpack_from('<II', main, 24)
        main = main[2048:2048+size]
        value = lambda address: struct.unpack_from('<I', main, address-base)[0]
        self.assertEqual(value(0x8016b680+0x14c), 0x800f8604)
        self.assertEqual(value(0x8016b680+0x154), 0x800f8680)
        self.assertEqual(hashlib.sha256(main[0x800f8604-base:0x800f8680-base]).hexdigest(),
                         '5289d8bb85b4d7b09dd9f97c1384823bbd537929ec055690cd411b05539cfa04')
        # Selectability checks action locks, inactivity and HP minus pending damage.
        for address, expected in {0x800f8628:0x90430055, 0x800f8650:0x90830045,
                                  0x800f8660:0x84820012, 0x800f8664:0x8483004e,
                                  0x800f866c:0x00431023}.items():
            self.assertEqual(value(address), expected, hex(address))

    def test_rabbit_vectors_keep_source_scaling_and_normalize_native_actor_ids_to_zero_based_slots(self):
        data = json.loads((ROOT / 'game/assets/battle_systems/enemy_vectors.json').read_text())
        cases = {case['name']: case for case in data['decisions']}
        for name in ('killer_rabbit_special_random_slot', 'killer_rabbit_special_rejected_slot'):
            case = cases[name]
            self.assertGreaterEqual(case['draws'][0]*100//32767, 51)
            slot = (case['draws'][1]*100//32767) % case['source_slot_count']
            selectable = any(row['slot'] == slot and row['active'] and not row['locked']
                             for row in case['party'])
            if name.endswith('random_slot'):
                self.assertTrue(selectable)
                self.assertEqual(case['expect']['target_slot'], slot)
                self.assertEqual(case['expect']['kind'], 'special')
                self.assertEqual(case['expect']['draws_used'], 2)
            else:
                self.assertFalse(selectable)
                self.assertEqual(case['expect'], dict(kind='attack', target_slot=0, draws_used=3))

    def test_remaining_regional_records_have_four_readable_ordinary_script_sets(self):
        from battle_placement import area_encounters
        from export_physical_runes import stream
        from export_unite_programs import compile_operations
        from preparation import stable_id
        from test_physical_rune_export import independent_stream
        from war_text import decode
        admitted = {row['id'] for row in json.loads(
            (ROOT / 'game/tests/fixtures/journey_unites_battle.json').read_text())['enemies']}
        expected = {
            ('D', 3): 'Creeper',
            ('F', 2): 'Shadow Man', ('F', 3): 'Mirage',
            ('H', 2): 'Mirage',
        }
        unadmitted = {}
        found = {}; blocked = {}
        for region in 'DEFGHZ':
            raw, origin = source('/' + region + '_DATA.BIN')
            placement = area_encounters(raw)
            pointer = lambda offset: struct.unpack_from('<I', raw, offset)[0] - 0x80080000
            table = pointer(placement['directory_offset'] + 12)
            native_ids = {native for row in placement['encounters'] for native in row['roster'] if native}
            for native in sorted(native_ids):
                record = pointer(table + 4*native)
                name = decode(raw[record:record+16], length=16)[0].strip()
                enemy_id = f'mirage_{region.lower()}' if name == 'Mirage' else stable_id(name)
                if enemy_id not in admitted:
                    unadmitted[region, native] = name
                if (region, native) not in expected:
                    continue
                found[region, native] = name
                scripts = pointer(record + 40)
                for slot in (1, 2, 4):
                    offset = pointer(scripts + 4*slot)
                    operations, spans = stream(raw, origin, offset, scripts, 0x80080000)
                    self.assertEqual(operations, independent_stream(raw, offset, scripts, 0x80080000))
                    for span in spans:
                        body = raw[span['source_offset']:span['source_offset']+span['byte_length']]
                        self.assertEqual(hashlib.sha256(body).hexdigest(), span['sha256'])
                    _, unsupported, effects = compile_operations(operations, 'melee/' + enemy_id)
                    self.assertEqual(effects, [])
                    if unsupported:
                        blocked[region, native, slot] = [row['operands'] for row in unsupported]
        self.assertEqual(unadmitted, {})
        self.assertEqual(found, expected)
        self.assertEqual(blocked, {
            ('F', 2, 1): [[1, 9]], ('F', 2, 2): [[2, 8], [1, 9]], ('F', 2, 4): [[1, 9]],
            ('F', 3, 1): [[1, 6]], ('F', 3, 4): [[1, 8]],
            ('H', 2, 1): [[1, 6]], ('H', 2, 4): [[1, 8]],
        })

    def test_ninja_and_golem_complete_selectors_differ_only_in_threshold_and_callback(self):
        cases = (
            ('Z', 0x178, 0x364, 51, 0x364,
             'e0c73966a838b21b03fcb4f1d64b4c9a3d7cab04d420515b3b9fa1c1bbc09c29'),
            ('H', 0x2c18, 0x2e04, 71, 0x3a2c,
             '8636fe8632ba410db6b772c39467653224cd099104c3cb47643cfbfb13785263'),
        )
        normalized = []
        for region, start, end, threshold, callback, digest in cases:
            raw, _ = source('/' + region + '_DATA.BIN')
            body = raw[start:end]
            self.assertEqual(hashlib.sha256(body).hexdigest(), digest)
            words = list(struct.unpack('<' + 'I' * (len(body)//4), body))
            # The second draw is floor(draw*100/32767), not draw%100.
            self.assertEqual(words[0x160//4:0x178//4],
                             [0x00021840, 0x00621821, 0x000318c0,
                              0x00621821, 0x00031880, 0x34027fff])
            self.assertEqual(words[0x178//4], 0x0062001a)
            self.assertEqual(words[0x1a0//4], 0x00001812)
            self.assertEqual(words[0x1a8//4], 0x28630000 | threshold)
            self.assertEqual(words[0x1ac//4], 0x14600005)
            self.assertEqual(words[0x1b4//4:0x1c4//4],
                             [0x3c028008, 0x24420000 | callback, 0xae42000c, 0x34020001])
            for i, word in enumerate(words):
                if word >> 26 in (2, 3):
                    pc = 0x80080000 + start + 4*i
                    target = ((pc+4) & 0xf0000000) | ((word & 0x3ffffff) << 2)
                    words[i] = (word & 0xfc000000) | (((target-(0x80080000+start)+0x80080004) >> 2) & 0x3ffffff)
            words[0x1a8//4] = words[0x1b8//4] = 0
            normalized.append(words)
            boundary = (threshold*32767 + 99)//100
            self.assertLess((boundary-1)*100//32767, threshold)
            self.assertGreaterEqual(boundary*100//32767, threshold)
            self.assertEqual(32767*100//32767, 100)
        self.assertEqual(normalized[0], normalized[1])


if __name__ == '__main__':
    unittest.main()
