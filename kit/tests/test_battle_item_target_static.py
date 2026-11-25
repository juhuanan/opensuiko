#!/usr/bin/env python3
"""Check item target modes and coordinator dispatch without executing MIPS."""
from pathlib import Path
import hashlib
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
import maindec


class ItemTargetSource(unittest.TestCase):
    def test_logic_wait_does_not_skip_the_independent_actor_update(self):
        body = maindec.body()
        self.assertEqual(hashlib.sha256(body[0x800de0b0-maindec.MBASE:0x800de1ec-maindec.MBASE]).hexdigest(),
                         'b4c0ab7297a6048319311760ccc9d126d414a95f6d37eff784e337a7afcbbb38')
        for pc, word in {0x800de0e0:0x0040f809, 0x800de0f4:0x2402ffff,
                         0x800de0f8:0x1062002c, 0x800de100:0x1462002a,
                         0x800de1b8:0x8c42134c, 0x800de1c0:0x10400004,
                         0x800de1c8:0x0c03800d, 0x800e0044:0x0c03826f,
                         0x800e0a74:0x0c038aa7, 0x800e0a7c:0x0c038d63}.items():
            self.assertEqual(maindec.mword(pc), word, hex(pc))

    def test_item_modes(self):
        body = maindec.body()
        # Medicine, Antitoxin, Needle, Mega medicine, Dragon seal incense.
        for item_id, expected in ((25, 2), (26, 2), (71, 2), (72, 2), (80, 0)):
            descriptor = maindec.mword(0x80167658 + 4 * item_id)
            flags = struct.unpack_from("<H", body, descriptor - maindec.MBASE + 0x1C)[0]
            self.assertEqual(flags & 3, expected, item_id)

    def test_item_dispatch_wait_reject_and_spend(self):
        words = {
            0x800F4FF8: 0x8C440024,  # actor count
            0x800F5000: 0x18800010,  # empty actor set is ready
            0x800F5024: 0x90620005,  # actor lock byte
            0x800F502C: 0x14400006,  # a lock returns zero
            0x800F5034: 0x2463008C,  # next actor record
            0x800F503C: 0x1040FFF9,  # scan the actor records
            0x800F5044: 0x34020001,  # all locks clear: ready
            0x800F5094: 0x0C03D3FB,  # wait for the global actor lock gate
            0x800F5108: 0x30430003,  # select the item target mode
            0x800F5240: 0x0C03E1A0,  # validate a single target
            0x800F5248: 0x14400032,  # invalid target returns -1
            0x800F524C: 0x2402FFFF,
            0x800F5250: 0x0C03E181,  # check target readiness
            0x800F5258: 0x14400003,
            0x800F5264: 0x00001021,  # unready target returns 0
            0x800F527C: 0xA2620003,  # decrement uses only after acceptance
            0x800F433C: 0x0C03D414,  # coordinator calls item dispatch
            0x800F434C: 0x10620013,  # rejection marks the owner acted
            0x800F4354: 0x1060001B,  # zero waits
            0x800F439C: 0x0C03D02E,
        }
        for address, expected in words.items():
            self.assertEqual(maindec.mword(address), expected, hex(address))


if __name__ == "__main__":
    unittest.main()
