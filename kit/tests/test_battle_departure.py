#!/usr/bin/env python3
"""Independently check the source departure motion without executing PS1 code."""
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import battle_departure
import maindec


class Departure(unittest.TestCase):
    def test_descriptor_and_callback_writers(self):
        expected = {
            0x800F6548: 0x30420008,  # third balloon at the round boundary
            0x800F6564: 0xA2120045,  # owner becomes inactive
            0x800F6574: 0x0C038E08,  # installs its actor descriptor
            0x8016BBA8: 0x800F3C5C,  # shared callback table slot 14
            0x800E56E0: 0xA4440010,  # opcode 37 replaces the movement timer
            0x800E368C: 0x1840004D,  # zero timer skips the ordinary integrator
            0x800E37F4: 0x0040F809,  # callback follows actor-script processing
            0x800F3D7C: 0x96420042,
            0x800F3D80: 0x34030060,  # initialize 96-update counter
            0x800F3DA4: 0x3402001E,  # 30-update sway period
            0x800F3E18: 0x0C054204,  # fixed-point sine
            0x800F3E38: 0x0C05423B,  # fixed-point cosine
            0x800F3E6C: 0x34020063,  # completion mailbox
        }
        for pc, word in expected.items():
            with self.subTest(pc=hex(pc)):
                self.assertEqual(maindec.mword(pc), word)

    def test_all_samples_match_independent_quarter_table_sum(self):
        raw = maindec.body()
        quarter = struct.unpack_from('<1025h', raw, 0x801765BC - maindec.MBASE)

        def trig(angle):
            quadrant, offset = divmod(angle & 4095, 1024)
            return ((quarter[offset], quarter[1024 - offset]),
                    (quarter[1024 - offset], -quarter[offset]),
                    (-quarter[offset], -quarter[1024 - offset]),
                    (-quarter[1024 - offset], quarter[offset]))[quadrant]

        result = battle_departure.build()
        self.assertEqual(result, json.loads(battle_departure.REPORT.read_text()))
        self.assertEqual(battle_departure.runtime_source(result), battle_departure.RUNTIME.read_text())
        self.assertEqual(len(result['samples_q12']), 97)
        for count, sample in enumerate(result['samples_q12']):
            phases = [trig(((95 - n) % 30) * 4096 // 30) for n in range(count)]
            expected = [4 * sum(pair[0] for pair in phases),
                        4 * sum(pair[1] for pair in phases), -8533 * count]
            with self.subTest(count=count):
                self.assertEqual(sample, expected)
        self.assertEqual(result['samples_q12'][1], [14180, 8208, -8533])
        self.assertEqual(result['samples_q12'][30], [0, 0, -255990])
        self.assertEqual(result['samples_q12'][96], [46028, 79816, -819168])

    def test_modified_source_is_rejected(self):
        raw = maindec.body()
        for address in (0x8016C170, 0x800F3DA4, 0x801765BC):
            changed = bytearray(raw)
            changed[address - maindec.MBASE] ^= 1
            with self.subTest(address=hex(address)):
                with self.assertRaisesRegex(ValueError, 'departure source changed'):
                    battle_departure.build(changed)


if __name__ == '__main__':
    unittest.main()
