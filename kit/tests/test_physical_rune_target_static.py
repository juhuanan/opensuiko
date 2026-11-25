#!/usr/bin/env python3
"""Static source checks for physical-rune target repair and no-target handling."""
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import maindec


class PhysicalRuneTargetSource(unittest.TestCase):
    def test_six_descriptors_and_dispatcher_target_repair(self):
        body = maindec.body()
        for index in range(1, 7):
            descriptor = maindec.mword(0x8016A630 + 4 * index)
            flags = struct.unpack_from('<H', body, descriptor - maindec.MBASE + 0x16)[0]
            self.assertEqual(flags & 3, 3, index)
        words = {
            0x800F5634: 0x30430003,  # descriptor target mode
            0x800F5654: 0x10620015,  # mode 3 enters target repair
            0x800F56AC: 0x0C03E1A0,  # validate selected target
            0x800F56BC: 0x0C03D8D1,  # find a replacement
            0x800F56C8: 0x1220FFED,  # no replacement returns -1
            0x800F56E4: 0xA0510049,  # persist replacement
            0x800F6360: 0x24700001,  # scan starts after the party
            0x800F6370: 0x0C03E181,  # scan candidate availability
            0x800F6380: 0x0C03E1A0,  # scan candidate validity
            0x800F430C: 0x0C03D540,  # dispatcher calls physical/magic handler
            0x800F431C: 0x1062001F,  # -1 selects the skipped-action path
            0x800F439C: 0x0C03D02E,  # mark the owner acted
            0x800F40DC: 0x34030001,
            0x800F40E0: 0xA0430046,  # write the acted byte
        }
        for address, expected in words.items():
            self.assertEqual(maindec.mword(address), expected, hex(address))


if __name__ == '__main__':
    unittest.main()
