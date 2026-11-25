#!/usr/bin/env python3
"""Pin the shared BonBon, Ant and Kobold target scans without executing them."""
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from export_first_room import source
import maindec


class SourceTargetScan(unittest.TestCase):
    def test_active_front_lock_and_retry(self):
        expected = {
            0x48: 0x92020045,  # inactive marker, not HP alone
            0x50: 0x14400020,  # skip committed inactive members
            0x58: 0x92020044,  # formation slot
            0x60: 0x2C420004,  # front row
            0x64: 0x1040001B,
            0x6C: 0x92620005,  # actor lock
            0x74: 0x14400017,  # skip locked target without a draw
            0x78: 0x2414FFFF,  # delay slot retains active front eligibility
            0x94: 0x34030064,
            0x98: 0x0043001A,  # draw modulo 100
            0xC8: 0x28630033,  # accept 51 and above
            0xF0: 0x1282000A,  # retry active but unselected targets
        }
        for filename, digest, callbacks in (
            ('/A_DATA.BIN', '1739375bf8292fbfdbf0eba749035a772448dc060e68a1d102db2ec66d882045', (0x80080004, 0x80080760, 0x80080ADC)),
            ('/C_DATA.BIN', '81e095355a5301acf5c155e09c2133a2d712e78cd053bf896f016c03d4da34e7',
             (0x80080018, 0x8008018C, 0x80080490)),
        ):
            raw, origin = source(filename)
            self.assertEqual(origin['sha256'], digest)
            for start in callbacks:
                for offset, word in expected.items():
                    with self.subTest(filename=filename, address=hex(start + offset)):
                        self.assertEqual(struct.unpack_from('<I', raw, start + offset - 0x80080000)[0], word)
                selector=raw[start-0x80080000:start-0x80080000+0x174]
                loads=[word for (word,) in struct.iter_unpack('<I',selector) if word>>26 in (32,33,35,36,37)]
                self.assertFalse(any(word&65535==0x4a for word in loads))
        raw,_=source('/C_DATA.BIN')
        self.assertEqual(struct.unpack_from('<I',raw,0x2285c+48)[0],0x8008018c)

    def test_ant_special_choice_and_impact_sites(self):
        raw, origin = source('/A_DATA.BIN')
        self.assertEqual(origin['sha256'], '1739375bf8292fbfdbf0eba749035a772448dc060e68a1d102db2ec66d882045')
        expected = {
            0x80080C34: 0x0040F809,  # draw after target selection
            0x80080C50: 0x34027FFF, 0x80080C54: 0x0062001A,
            0x80080C80: 0x34020064, 0x80080C84: 0x0062001A,
            0x80080CB4: 0x2842004D, 0x80080CB8: 0x1440000E,  # below 77 is ordinary
            0x80080CC4: 0x34020014, 0x80080CC8: 0xAE421264,  # special wait 20
            0x80080CD4: 0x3C06800A, 0x80080CD8: 0x24C65460,  # special descriptor
            0x80080CE4: 0x3C028008, 0x80080CE8: 0x24420950,  # special callback
            0x80080994: 0x30420002, 0x80080998: 0x1040001B,  # impact signal
            0x800809C4: 0x8C42000C, 0x800809CC: 0x0040F809,  # physical helper
            0x800809DC: 0x8C630010, 0x800809E4: 0x0060F809, 0x800809E8: 0x00022840,  # double and apply
            0x80080A04: 0xAC400050,  # clear callback
        }
        for address, word in expected.items():
            self.assertEqual(struct.unpack_from('<I', raw, address - 0x80080000)[0], word, hex(address))
        # The shared selector decrements the Ant's stored wait before choosing;
        # the dispatch wrapper distinguishes special return 1 from ordinary -1.
        for address, word in {
            0x800F3EAC: 0x8C621264, 0x800F3EB4: 0x2442FFFF,
            0x800F3EB8: 0x1C400047, 0x800F3EBC: 0xAC621264,
            0x800F3EC0: 0x0C03D1A6, 0x800F41EC: 0x0040F809,
            0x800F41F8: 0x2402FFFF, 0x800F41FC: 0x1062000B,
            0x800F4204: 0x14600015, 0x800F422C: 0x0C03D399,
            0x800F425C: 0xA2220046,
        }.items():
            self.assertEqual(maindec.mword(address), word, hex(address))


if __name__ == '__main__':
    unittest.main()
