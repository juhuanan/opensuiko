#!/usr/bin/env python3
"""Pin Roc's source target scan without executing original instructions."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
from export_first_room import source
import maindec


class RocTargetScan(unittest.TestCase):
    def test_record_and_scan(self):
        raw, origin = source("/B_DATA.BIN")
        self.assertEqual(origin["sha256"], "b47b1bdf54091143387b41bbd1db08a47490fc2d0f2be9428184b1db9fc1e64e")
        self.assertEqual(hashlib.sha256(raw).hexdigest(), origin["sha256"])
        word = lambda address: struct.unpack_from("<I", raw, address - 0x80080000)[0]
        self.assertEqual(word(0x800A3688 + 0x30), 0x8008006C)
        words = {
            0x800800B4: 0x92020045,  # skip inactive party members
            0x800800CC: 0x2C420004,  # accept only the front row
            0x800800D8: 0x92620005,  # inspect the target lock
            0x800800E0: 0x14400017,  # locked members skip the RNG draw
            0x800800E4: 0x2414FFFF,  # delay slot records a living front member
            0x80080100: 0x34030064,  # unlocked candidates draw modulo 100
            0x80080134: 0x28630033,  # accept values at least 51
            0x8008015C: 0x1282000A,  # eligible but unselected stays pending
            0x80080164: 0x1680000C,  # selected target starts the attack
            0x80080184: 0xA0430046,  # no living front target marks the enemy acted
            0x8008018C: 0x00001021,  # pending and no-target return without an attack
        }
        for address, expected in words.items():
            self.assertEqual(word(address), expected, hex(address))

    def test_buddha_preserves_the_source_active_flag(self):
        words = {
            0x800E2CF0: 0x34060053,  # look for item 83
            0x800E2D08: 0x0C032902,  # remove its inventory slot
            0x800E2D1C: 0x0C038E08,  # start its revival script
            0x800E2D24: 0x08038B65,  # skip ordinary inactive writes
            0x800E2D7C: 0xA0430045,  # ordinary knockout sets inactive
            0x800E2D80: 0xA0430046,  # ordinary knockout marks acted
        }
        for address, expected in words.items():
            self.assertEqual(maindec.mword(address), expected, hex(address))


if __name__ == "__main__":
    unittest.main()
