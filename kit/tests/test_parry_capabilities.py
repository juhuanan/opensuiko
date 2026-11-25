#!/usr/bin/env python3
"""Static writer/reader and independent catalogue checks for the parry weapon guard."""
import json
import hashlib
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import character_table
import maindec


class ParryCapabilities(unittest.TestCase):
    def test_party_attacker_weapon_pointer_is_the_parry_range_input(self):
        for pc, word in {
            0x800DEDC4: 0x8E22001C, 0x800DEDD0: 0x90420044,
            0x800DEDE8: 0x24215890, 0x800DEDF0: 0x8C220000,
            0x800DEDFC: 0xAE820004, 0x800F4944: 0x00808821,
            0x800F495C: 0x00111840, 0x800F4968: 0x00711821,
            0x800F496C: 0x00031880, 0x800F4984: 0x24A50F84,
            0x800F49A4: 0x00659821, 0x800F4A50: 0x8E730004,
            0x800F4AD0: 0x96820026, 0x800F4AFC: 0x30420002,
            0x800F4B04: 0x34020002, 0x800F4B08: 0x92630056,
            0x800F4B10: 0x10620016, 0x800F4B34: 0x8C460004,
            0x800F4B60: 0x24635DB4,
        }.items():
            self.assertEqual(maindec.mword(pc), word, hex(pc))

    def test_all_78_weapon_ranges_independently_agree_on_the_58_melee_and_20_long_guards(self):
        catalogue = json.loads((ROOT / 'game/assets/profiles/character_weapons.json').read_text())['characters']
        by_id = {row['id']: row for row in catalogue}
        counts = {True: 0, False: 0}
        for record in character_table.records():
            pointer = maindec.mword(0x80165890 + 4 * record['weapon_id'])
            actual = maindec.body()[pointer - maindec.MBASE + 0x56]
            self.assertEqual(actual, by_id[record['id']]['range'])
            can_be_parried = actual != 2
            self.assertEqual(can_be_parried, by_id[record['id']]['range_name'] != 'long')
            counts[can_be_parried] += 1
        self.assertEqual(counts, {True: 58, False: 20})

    def test_curated_interaction_contract_names_the_attacker_and_has_a_checked_identity(self):
        packet = json.loads((ROOT / 'game/assets/battle_systems/interactions.json').read_text())
        self.assertEqual(packet['schema'], 'suikoden-battle-interactions/2')
        self.assertNotIn('motion_branch', packet['features'])
        self.assertEqual(packet['features']['parry_weapon_guard']['runtime_field'], 'attacker.can_be_parried')
        digest = packet.pop('content_sha256')
        self.assertEqual(hashlib.sha256(json.dumps(packet, sort_keys=True, separators=(',', ':')).encode()).hexdigest(), digest)
        constants = (ROOT / 'game/src/battle_systems/status/constants.zig').read_text()
        self.assertIn('interactions_sha256 = "' + digest + '"', constants)


if __name__ == '__main__':
    unittest.main()
