"""Static Commander decision, group-target and callback evidence."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from export_first_room import source


class CommanderSource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw, cls.origin = source('/B_DATA.BIN')

    def word(self, address):
        return struct.unpack_from('<I', self.raw, address - 0x80080000)[0]

    def pins(self, values):
        for address, value in values.items():
            self.assertEqual(self.word(address), value, hex(address))

    def branch(self, address, opcode, destination):
        word = self.word(address)
        self.assertEqual(word >> 26, opcode)
        displacement = struct.unpack('<h', struct.pack('<H', word & 65535))[0]
        self.assertEqual(address + 4 + displacement * 4, destination)

    def test_complete_decision_and_group_callbacks_preserve_source_identity(self):
        self.assertEqual(self.origin['lba'], 56693)
        self.assertEqual(self.origin['sha256'],
                         'b47b1bdf54091143387b41bbd1db08a47490fc2d0f2be9428184b1db9fc1e64e')
        self.assertEqual(self.word(0x800a2208 + 48), 0x80080f00)
        for start, end, digest in (
            (0xf00, 0x11b0, '2752f45ff3dd0df19e5b65870250cd8ddfa048f7143d7b9cd9277d22c6a267d1'),
            (0x11b0, 0x1374, 'b3260161d091bdf228403cf869b389d34e0a1bd900f039a0ba4a0ddeb43fafcd'),
            (0x1374, 0x145c, 'f63348ffba4c9ce686aac7acbef9d6ed3759115a93177c3044eb311bc87ecafe'),
            (0x145c, 0x14f4, '56418ca2dd6f5db0470738cdaab9502e563a335e2087467dc4997d206e68f993'),
            (0x14f4, 0x15b8, '1d87cde3d7119a1a66e20e7e0541713e78af21bb2a3c9e81d4f4d4b5e9c7b977'),
        ):
            self.assertEqual(hashlib.sha256(self.raw[start:end]).hexdigest(), digest)

    def test_group_admission_and_solo_target_scan_both_skip_locked_actors(self):
        self.pins({0x80080f68: 0x90820046, 0x80080f90: 0x90420005,
                   0x80080fa0: 0x90820044, 0x80080fa8: 0x2c420004,
                   0x80080fdc: 0x90420044, 0x80080fe4: 0x2c420004,
                   0x80081048: 0x92420005, 0x80081058: 0x92620045,
                   0x8008108c: 0x8c420000, 0x8008109c: 0x34030064,
                   0x800810c8: 0x00001810, 0x800810d0: 0x28630033})
        for address, opcode, target in (
            (0x80080f70, 5, 0x80080fb8), (0x80080f98, 5, 0x80080fbc),
            (0x80080fac, 4, 0x80080fbc), (0x80080fe8, 5, 0x80081030),
            (0x80081050, 5, 0x800810dc), (0x80081060, 5, 0x800810dc),
            (0x800810d4, 4, 0x80081028),
        ):
            self.branch(address, opcode, target)

    def test_group_assignment_checks_each_ally_and_target_then_uses_own_scripts(self):
        self.pins({0x80081238: 0x90420046, 0x8008125c: 0x90420005,
                   0x80081280: 0x90c20005, 0x80081290: 0x90620045,
                   0x800812a0: 0x90620044, 0x800812e4: 0xa2020046,
                   0x80081300: 0xa4400040, 0x8008130c: 0x8c460004,
                   0x80081324: 0x24421374, 0x80081340: 0x3402003c,
                   0x80081344: 0xae421264, 0x800813bc: 0x30420002,
                   0x800813d0: 0x8c42000c, 0x800813e8: 0x8c630010,
                   0x80081400: 0x8c460008, 0x80081430: 0x2463145c,
                   0x80081494: 0x30420004, 0x800814a8: 0x8c460010,
                   0x800814d8: 0xac400050})
        for address, target in (
            (0x80081240, 0x8008132c), (0x80081264, 0x8008132c),
            (0x80081288, 0x800812b4), (0x80081298, 0x800812b4),
            (0x800812a8, 0x800812b4),
        ):
            self.branch(address, 5, target)
        self.branch(0x80081338, 4, 0x80081214)

    def test_solo_callback_reads_the_child_signal_and_dispatches_the_recipient_once(self):
        self.pins({0x80081534: 0x92130004, 0x80081554: 0x30420002,
                   0x80081568: 0x8c420004, 0x8008156c: 0x3c06800a,
                   0x80081570: 0x24c6229c, 0x80081578: 0x02202821,
                   0x80081594: 0xac400050})
        self.branch(0x80081558, 4, 0x80081598)


if __name__ == '__main__':
    unittest.main()
