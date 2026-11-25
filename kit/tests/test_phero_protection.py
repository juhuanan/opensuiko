#!/usr/bin/env python3
"""Static Phero selector/header proof; existing oracle metadata is not regenerated."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import maindec
import character_table
import preparation
from export_first_room import source
import export_world_travel


class PheroProtection(unittest.TestCase):
    def test_fallback_reads_rune_type_inactivity_and_lock_then_wraps_without_rng(self):
        words = {0x800F7B58:0x9043004C,0x800F7B5C:0x3402001A,
                 0x800F7B60:0x14620030,0x800F7B68:0x92C9000A,
                 0x800F7B6C:0x26A30001,0x800F7BBC:0x90820045,
                 0x800F7BC4:0x1440000B,0x800F7BCC:0x90A20005,
                 0x800F7BD4:0x14400007,0x800F7BDC:0x8CC20000,
                 0x800F7BE4:0x9042000A,0x800F7BEC:0x1522000E,
                 0x800F7BF0:0x00601021,0x800F7BFC:0x24630001,
                 0x800F7C00:0x0043102A,0x800F7C18:0x34030001,
                 0x800F7C1C:0x1475FFE7,0x800F7C24:0x00001021}
        for pc, expected in words.items():
            self.assertEqual(maindec.mword(pc), expected, hex(pc))
        span = [maindec.mword(pc) for pc in range(0x800F7B50,0x800F7C28,4)]
        self.assertFalse(any(word >> 26 == 3 for word in span))  # no call/RNG in this arm
        # Unlike the relationship candidate helper, this complete arm has no halfword HP reads.
        self.assertFalse(any(word >> 26 in (0x21,0x25) for word in span))

    def test_exported_types_agree_with_independent_character_headers(self):
        exported = export_world_travel.protection_export()[0]
        expected = {}
        for row in character_table.records():
            raw, _ = source('/' + row['sprite_file'])
            self.assertEqual(raw[0], row['id'])
            expected[preparation.stable_id(row['name'])] = raw[10]
        self.assertEqual({r['id']:r['character_type'] for r in exported['characters']},expected)
        for asset in ('world_b_battle.json','world_c_battle.json'):
            self.assertEqual(json.loads((ROOT/'game/assets'/asset).read_text())['protection'], exported)

    def test_retained_oracle_identity_and_source_relationship_table(self):
        # This existing artifact is read only; no PS1 instructions or emulator run.
        data = (ROOT/'game/tests/fixtures/world_protection.json').read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), 'd89ecf0c9f8f219fbe59bce7f7af358b94815ac97d8637e5f989d7fa257eca54')
        cases = json.loads(data)
        self.assertEqual(len(cases),144)
        self.assertEqual({row['hp'] for row in cases},{24,25})
        self.assertEqual({row['target'] for row in cases},set(range(6)))
        self.assertTrue(any(row['phero'] and row['protector'] is not None for row in cases))
        names={row['id']:preparation.stable_id(row['name']) for row in character_table.records()}
        pairs=[]
        for offset in range(0,216,2):
            a,b=struct.unpack_from('BB',maindec.body(),0x8016C814-maindec.MBASE+offset)
            if a==255:break
            pairs.append(dict(ward=names[a],protector=names[b]))
        self.assertEqual(export_world_travel.protection_export()[0]['pairs'],pairs)
        print('retained protection oracle SHA256',hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    unittest.main()
