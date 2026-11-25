#!/usr/bin/env python3
"""Independent static sleep writers/reset/cure checks; no original code execution."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from export_first_room import source


class SleepLifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw, cls.origin = source('MAIN.EXE')
        cls.base, size = struct.unpack_from('<II', raw, 0x18)
        cls.body = raw[2048:2048 + size]
        assert cls.base == 0x800C0800 and len(cls.body) == size

    def word(self, address):
        return struct.unpack_from('<I', self.body, address - self.base)[0]

    def words(self, expected):
        for address, value in expected.items():
            self.assertEqual(self.word(address), value, hex(address))

    def test_party_sleep_setter_marks_acted_and_selects_the_sleep_symbol(self):
        self.words({0x800C11C8: 0x800E0580, 0x800E0598: 0x34030001,
                    0x800E059C: 0xA0430046, 0x800E05A4: 0x3407000F,
                    0x800E0700: 0x9443004A, 0x800E0710: 0x94240000,
                    0x800E071C: 0x00641825, 0x800E0720: 0xA443004A})
        self.assertEqual(struct.unpack_from('<H', self.body, 0x8016BAA8 + 5*2 - self.base)[0], 32)

    def test_round_launch_initializes_sleeping_party_and_enemy_acted_flags_before_selection(self):
        self.words({0x800F6DE0: 0x8C620024, 0x800F6DF4: 0x0C03E1A0,
                    0x800F6DFC: 0x14400006, 0x800F6E0C: 0x30420020,
                    0x800F6E18: 0x0803DB89, 0x800F6E1C: 0xA2020046,
                    0x800F6E20: 0xA2000046, 0x800F6E38: 0x0051102A,
                    0x800F6E40: 0x26100054})
        branch = 0x800F6E10
        offset = struct.unpack('<h', struct.pack('<H', self.word(branch) & 65535))[0]
        self.assertEqual(branch + 4 + offset*4, 0x800F6E20)

    def test_wake_rng_is_in_the_enemy_reset_loop_after_the_party_stat_restore(self):
        # The entire party stat-restore block is bounded by its source loop.
        block = self.body[0x800F6E84-self.base:0x800F6EF4-self.base]
        self.assertEqual(hashlib.sha256(block).hexdigest(),
                         'df65ff94972d86784aa0e4bdea1bab8ce2107cae3bc98dbc6a91146b88e1aaff')
        self.words({0x800F6E90: 0x8C62001C, 0x800F6EAC: 0x8C420F84,
                    0x800F6EB8: 0x0C0353B0, 0x800F6ECC: 0x8C62001C,
                    0x800F6EEC: 0x8C43001C, 0x800F6EF4: 0x24710001,
                    0x800F6F48: 0x0C03E1A0, 0x800F6F50: 0x14400021,
                    0x800F6F60: 0x30420020, 0x800F6F64: 0x1040001C,
                    0x800F6F6C: 0x0C051F8E, 0x800F6F88: 0x34027FFF,
                    0x800F6FBC: 0x28630032, 0x800F6FD0: 0x3042FFDF,
                    0x800F6FD4: 0xA602004A})
        calls = [word for (word,) in struct.iter_unpack('<I', block) if word >> 26 == 3]
        self.assertEqual(calls, [0x0C0353B0])
        # Independent exact endpoints for the source multiply/divide/compare.
        self.assertEqual([roll*100//32767 < 50 for roll in (0, 16383, 16384, 32767)],
                         [True, True, False, False])

    def test_general_cure_and_battle_exit_remove_sleep_without_a_wake_roll(self):
        self.words({0x80120508: 0x0C0381DE, 0x8012050C: 0x34050005,
                    0x800DE234: 0x94A2004A, 0x800DE23C: 0x3042000F,
                    0x800DE240: 0xA4620016})
        for status in (32, 33, 0x80FF):
            self.assertEqual(status & 15 & 32, 0)


if __name__ == '__main__':
    unittest.main()
