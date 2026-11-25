#!/usr/bin/env python3
"""Pin the Rabbit's target checks and retry decision without executing PS1 code."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from export_first_room import source
import maindec


class RabbitTargetScan(unittest.TestCase):
    def test_decision_and_target_helpers(self):
        raw, origin = source('/B_DATA.BIN')
        self.assertEqual(origin['sha256'], 'b47b1bdf54091143387b41bbd1db08a47490fc2d0f2be9428184b1db9fc1e64e')
        self.assertEqual(hashlib.sha256(raw).hexdigest(), origin['sha256'])
        word = lambda address: struct.unpack_from('<I', raw, address - 0x80080000)[0]
        for address, expected in {
            0x800806E4: 0x28630033,  # projectile chance is at least 51 percent
            0x80080778: 0x00001010,  # scaled target draw modulo party count
            0x80080788: 0x8C62014C,  # projectile uses the shared target-availability helper
            0x80080798: 0x10400022,  # rejected projectile enters the ordinary scan
            0x80080840: 0x8C420154,  # skip targets already inactive
            0x80080860: 0x2C420004,  # front formation slots only
            0x80080874: 0x8C42014C,  # same live/unlocked helper
            0x80080878: 0x2412FFFF,  # active front target makes a rejected scan retry
            0x80080884: 0x1040001C,  # unavailable targets consume no selection draw
            0x800808EC: 0x28630033,  # ordinary selection accepts 51 and above
            0x80080910: 0x1242000A,  # no selection with an active front target waits
            0x80080938: 0xA0430046,  # no active front target marks Rabbit acted
        }.items():
            self.assertEqual(word(address), expected, hex(address))
        for address, expected in {
            0x8016B7CC: 0x800F8604,  # vtable +0x14C
            0x8016B7D4: 0x800F8680,  # vtable +0x154
            0x800F8628: 0x90430055,  # availability checks action lock
            0x800F8650: 0x90830045,  # availability checks inactive marker
            0x800F8670: 0x0002102A,  # availability requires positive remaining HP
            0x800F86BC: 0x90620045,  # inactive check reads the marker
            0x800F86DC: 0x04410002,  # zero remaining HP is not yet inactive
        }.items():
            self.assertEqual(maindec.mword(address), expected, hex(address))


if __name__ == '__main__':
    unittest.main()
