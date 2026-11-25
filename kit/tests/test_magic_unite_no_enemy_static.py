#!/usr/bin/env python3
"""Static source checks for spell/Unite dispatch and fixed-roster combined damage."""
from pathlib import Path
import json
import hashlib
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import maindec


class EmptyEnemySource(unittest.TestCase):
    def test_spell_modes_match_exported_target_sides(self):
        spells = json.loads((ROOT / 'game/tests/fixtures/journey_battle.json').read_text())['systems']['spells']
        self.assertEqual(len(spells), 33)
        body = maindec.body()
        for spell in spells:
            native = int(spell['id'].removeprefix('spell_'))
            descriptor = maindec.mword(0x8016D33C + 4 * native)
            flags = struct.unpack_from('<H', body, descriptor - maindec.MBASE + 0x16)[0] & 3
            expected = (0 if spell['group'] else 2) if spell['allies'] else (1 if spell['group'] else 3)
            self.assertEqual(flags, expected, spell['id'])

    def test_unite_modes_and_dispatch_rejection(self):
        body = maindec.body()
        modes = []
        for index in range(32):
            descriptor = maindec.mword(0x8016D190 + 4 * index)
            modes.append(struct.unpack_from('<H', body, descriptor - maindec.MBASE + 0x16)[0] & 3)
        self.assertEqual((modes.count(1), modes.count(3)), (8, 24))
        words = {
            0x800F5570: 0x0C03D3FB,  # spells wait for the shared actor-lock gate
            0x800F57B8: 0x0C03D3FB,  # Unites use the same gate
            0x800F57C0: 0x1040005F,  # locked gate returns pending before member/target writes
            0x800F4FF8: 0x8C440024,  # gate includes every party/enemy combatant
            0x800F5008: 0x244300DC,  # start at the first live actor record
            0x800F5024: 0x90620005,  # gate reads each actor's lock byte
            0x800F502C: 0x14400006,  # a lock delays dispatch
            0x800F5034: 0x2463008C,  # actor stride
            0x800F503C: 0x1040FFF9,  # scan through the final combatant
            0x800F5044: 0x34020001,  # success only after the entire scan
            0x800F5664: 0x3C028018,
            0x800F5670: 0x8C42002C,  # enemy count for mode 1
            0x800F5680: 0x0803D5DA,  # empty enemy count returns -1
            0x800F56AC: 0x0C03E1A0,  # mode 3 validates its target
            0x800F56BC: 0x0C03D8D1,  # mode 3 scans for a replacement
            0x800F58C0: 0x8C42002C,  # Unite mode 1 checks enemy count
            0x800F58D4: 0x2402FFFF,  # no enemy returns -1
            0x800F58D8: 0x0C03E1A0,  # Unite mode 3 validates its target
            0x800F58E8: 0x0C03D8D1,  # Unite mode 3 scans for a replacement
            0x800F436C: 0x0C03D5E4,  # coordinator invokes Unite dispatch
            0x800F437C: 0x10620007,  # rejected action follows acted path
            0x800F4384: 0x1060000F,  # pending action retains dispatch without priority rerolls
            0x800F439C: 0x0C03D02E,  # mark the selected owner acted
        }
        for address, expected in words.items():
            self.assertEqual(maindec.mword(address), expected, hex(address))

    def test_unite_rejects_down_members_before_initializer_and_keeps_fixed_damage_roster(self):
        # Dispatch validates every same-record participant, then skips without installing an initializer.
        words = {
            0x800F5800: 0x82030047,  # participant command
            0x800F5808: 0x1462000A,  # only Unite commands
            0x800F5810: 0x82030048,
            0x800F5814: 0x82620048,
            0x800F581C: 0x14620005,  # same Unite record
            0x800F5824: 0x0C03E1A0,  # participant validator
            0x800F582C: 0x14400044,  # invalid participant returns before initializer write
            0x800F5830: 0x2402FFFF,  # rejected, not pending
            0x800F43A0: 0x02002021,  # rejected command retires only the selected actor
            0x800F40E0: 0xA0430046,  # mark its acted byte; leave the other queued commands
            0x800F584C: 0x1040FFEC,  # all party members scanned
            0x800F86BC: 0x90620045,  # committed inactive byte
            0x800F86C4: 0x14400008,
            0x800F86CC: 0x84620012,  # HP minus pending change
            0x800F86D0: 0x8463004E,
            0x800F86DC: 0x04410002,
            0x800F951C: 0x8E040000,  # fixed matched member list
            0x800F9520: 0x0C03DFA4,  # physical result for each member
            0x800F955C: 0x1440FFEF,  # full count, no participant-eligibility branch
            0x800F9650: 0x8E040000,
            0x800F965C: 0x0C03DFA4,
            0x800F966C: 0x1440FFF8,
            0x800F7EF4: 0x94630030,  # physical reader starts with attack and target defense
            0x800F7EF8: 0x94420032,
        }
        for address, expected in words.items():
            self.assertEqual(maindec.mword(address), expected, hex(address))
        # Full consumer spans accompany the call/loop operands; none execute original instructions.
        for start, end, digest in (
            (0x800F9488, 0x800F95E8, '88a76988964995db271967bcd5615bca4a42c0cb319cc0c9e2364affe56da346'),
            (0x800F95E8, 0x800F96F8, '81302535be2e271566ac8eef3712ddff47f5c69b65f75213d9ccd2f9dbcce4ac'),
            (0x800F7E90, 0x800F8174, 'a78631c956365dcb5221cbc934a4573e64bf4208cb29ade3ffdce475a75521b8'),
        ):
            self.assertEqual(hashlib.sha256(maindec.body()[start-maindec.MBASE:end-maindec.MBASE]).hexdigest(), digest)


if __name__ == '__main__':
    unittest.main()
