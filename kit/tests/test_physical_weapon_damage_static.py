#!/usr/bin/env python3
"""Static source checks for physical weapon elements and rune-piece modifiers."""
from collections import Counter
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import battle_formulas
import character_table
import maindec
import preparation


class WeaponDamageSource(unittest.TestCase):
    def test_selector_and_modifier_instructions(self):
        words = {
            0x800F8068: 0x90840046, 0x800F8078: 0x2C420005,
            0x800F8088: 0x2421C834, 0x800F8090: 0x90230000,
            0x800F809C: 0x90620055, 0x800F80A4: 0x2443FFFF,
            0x800F80B4: 0x90430020, 0x800F80C4: 0x14620006,
            0x800F80D8: 0x02028021, 0x800F80E0: 0x10820003,
            0x800F80E8: 0x14820015, 0x800F80F4: 0x0202001A,
            0x800F8124: 0x90630002, 0x800F812C: 0x00430018,
            0x800F813C: 0x02028021, 0x800F8140: 0x1E000003,
        }
        for address, expected in words.items():
            self.assertEqual(maindec.mword(address), expected, hex(address))
        offset = 0x8016C834 - maindec.MBASE
        self.assertEqual(list(maindec.body()[offset:offset + 6]), [255, 0, 1, 2, 3, 4])

    def test_every_source_weapon_element_and_bonus_order(self):
        mapping = ('fire', 'water', 'earth', 'lightning', 'wind')
        counts = Counter()
        for record in character_table.records():
            pointer = maindec.mword(0x80165890 + 4 * record['weapon_id'])
            code = maindec.body()[pointer - maindec.MBASE + 0x55]
            counts[code] += 1
            expected = mapping[code - 1] if 1 <= code <= 5 else None
            self.assertEqual(preparation.weapon_element(record), expected, record['name'])
        self.assertEqual(counts, {0: 55, 1: 1, 2: 1, 3: 1, 4: 2, 5: 17, 6: 1})
        for kind in range(6):
            for weak in (False, True):
                for pieces in (0, 3, 9):
                    base = 55
                    after_weakness = base + (base // 2 if weak else 0)
                    expected = after_weakness + (after_weakness // 20 * pieces if kind in (1, 3) else 0)
                    self.assertEqual(battle_formulas.physical_damage(100, 50, 0, element_type=kind,
                        element_index_valid=True, element_match_flag=int(weak), element_bonus=pieces), expected)

    def test_profile_binding_rejects_a_conflicting_existing_element(self):
        content = {'party': [{'id': 'ted', 'weapon': {'element': 'fire'}}]}
        with self.assertRaisesRegex(ValueError, 'differs from source'):
            preparation.bind_weapon_elements(content)
        content['party'][0]['weapon'] = {}
        preparation.bind_weapon_elements(content)
        self.assertEqual(content['party'][0]['weapon']['element'], 'wind')
        self.assertEqual(content['schema'], 'suikoden-battle-trial/33')
        for schema in ('suikoden-battle-trial/34','suikoden-battle-trial/35'):
            content['schema'] = schema
            preparation.bind_weapon_elements(content)
            self.assertEqual(content['schema'], schema)


if __name__ == '__main__':
    unittest.main()
