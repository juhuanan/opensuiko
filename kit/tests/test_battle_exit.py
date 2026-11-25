#!/usr/bin/env python3
"""Static root-menu/escape contracts; native Zig tests own escape execution."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from export_first_room import source


class BattleExitSource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw, _ = source('MAIN.EXE')
        cls.base, size = struct.unpack_from('<II', raw, 0x18)
        cls.body = raw[2048:2048 + size]

    def word(self, address):
        return struct.unpack_from('<I', self.body, address - self.base)[0]

    def pins(self, expected):
        for address, word in expected.items():
            self.assertEqual(self.word(address), word, hex(address))

    def test_complete_source_spans_and_escape_order(self):
        for start, end, digest in (
            (0x800F8464, 0x800F8578, '2969090dc1ce04fc2a117fae9a02acc346f414212342835356a78a2fa777849d'),
            (0x800EEF58, 0x800EF104, '5c508516051a50880a28bba042e72319b69f73cce8f2ce3356fc60409f1d5000'),
            (0x800EA2A8, 0x800EA510, '71e84f360c3b14143caad008111235e42bb477a7f4639b4a77603bee4ed215a0'),
            (0x800EE124, 0x800EE38C, 'a3187d48e5804688475825f6b5df1ecae9a0a2611fe7871c6d97ac8ddb9187f4')):
            self.assertEqual(hashlib.sha256(self.body[start-self.base:end-self.base]).hexdigest(), digest)
        self.pins({0x800F847C: 0x8C42000C, 0x800F8484: 0x04400038,
                   0x800F848C: 0x8CA2126C, 0x800F8490: 0x8CA40020,
                   0x800F8494: 0x00021900, 0x800F8498: 0x00621823,
                   0x800F849C: 0x00031880, 0x800F84A0: 0x0064001A,
                   0x800F84CC: 0x8CA41268, 0x800F84D0: 0x8CA5001C,
                   0x800F84D4: 0x00041100, 0x800F84D8: 0x00441023,
                   0x800F84DC: 0x00021080, 0x800F84E0: 0x0045001A,
                   0x800F8510: 0x0043102A, 0x800F8514: 0x10400014,
                   0x800F8518: 0x2402FFFF, 0x800F851C: 0x0C051F8E,
                   0x800F8524: 0x34030064, 0x800F8528: 0x0043001A,
                   0x800F8550: 0x00001810, 0x800F8558: 0x28630033,
                   0x800F855C: 0x14600002, 0x800F8560: 0x00001021,
                   0x800F8564: 0x2402FFFF})
        words = [w for (w,) in struct.iter_unpack('<I', self.body[0x800F8464-self.base:0x800F8578-self.base])]
        self.assertEqual(words.count(0x0C051F8E), 1)

    def test_labels_dispatch_and_defend_preparation(self):
        self.pins({0x800EF008: 0x0062182A, 0x800EF00C: 0x14600016,
                   0x800EF01C: 0x8C42000C, 0x800EF024: 0x04400010,
                   0x800EF03C: 0x24A5BD38, 0x800EF05C: 0x24A5BD44,
                   0x800EF07C: 0x24A5BD38, 0x800EF0A0: 0x24A5BD40,
                   0x800EF0C4: 0x24A5BD4C, 0x800EF0E8: 0x24A5BD54,
                   0x800EA430: 0x10B3000A, 0x800EA444: 0x10B00009,
                   0x800EA44C: 0x10A2000B, 0x800EA460: 0x2442E124,
                   0x800EA470: 0x2442E38C, 0x800EA488: 0x2442E5B8,
                   0x800EA4B0: 0x2442A510, 0x800EA4C0: 0xAC220000,
                   0x800EE1F4: 0x34050001, 0x800EE228: 0xA0450047,
                   0x800EE240: 0x0082102A, 0x800EE244: 0x1440FFEC,
                   0x800EE24C: 0x0C03E119, 0x800EE254: 0x10400008,
                   0x800EE26C: 0x3403000A, 0x800EE274: 0xAC430004,
                   0x800EE280: 0x34020014, 0x800EE288: 0xAC620004})
        # Game glyphs use space=0x10, a-z=0x11..0x2a, A-Z=0x2b..0x44; zero terminates.
        alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
        for address, label in ((0x8016BD38, 'Fight'), (0x8016BD40, 'Run'),
                               (0x8016BD44, 'Let go'), (0x8016BD4C, 'Bribe'),
                               (0x8016BD54, 'Free Will')):
            data = self.body[address-self.base:].split(b'\0', 1)[0]
            self.assertEqual(''.join(' ' if b == 0x10 else alphabet[b-0x11] for b in data), label)

    def test_retained_semantic_fixture_matches_statically_derived_rules(self):
        rows = json.loads((ROOT / 'game/tests/fixtures/battle_exit.json').read_text())
        self.assertEqual(len(rows), 56)
        self.assertEqual(len({(tuple(r['party_levels']), tuple(r['enemy_levels']), r['allowed']) for r in rows}), 14)
        for row in rows:
            strong = sum(row['party_levels'])*60//len(row['party_levels']) >= sum(row['enemy_levels'])*60//len(row['enemy_levels'])
            self.assertEqual(row['let_go'], row['allowed'] and strong)
            self.assertEqual(row['success'], row['allowed'] and (strong or row['roll'] >= 51))


if __name__ == '__main__':
    unittest.main()
