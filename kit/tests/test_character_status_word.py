#!/usr/bin/env python3
"""Static whole cure/exit consumers; opaque high status bits remain unnamed."""
from pathlib import Path
import hashlib
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_first_room import source


class CharacterStatusWord(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw,_=source('MAIN.EXE')
        cls.base=struct.unpack_from('<I',cls.raw,24)[0]

    def check_window(self,first,last,digest,pins):
        block=self.raw[2048+first-self.base:2048+last-self.base]
        self.assertEqual(hashlib.sha256(block).hexdigest(),digest)
        for address,word in pins.items():
            self.assertEqual(struct.unpack_from('<I',self.raw,2048+address-self.base)[0],word,hex(address))
        return [word for (word,) in struct.iter_unpack('<I',block) if word>>26 in (40,41,43)]

    def test_poison_cure_changes_one_halfword_bit_and_only_sounds_on_success(self):
        stores=self.check_window(0x800d0c08,0x800d0c60,
            '7aedd5a3b028a7d3d1a6b7fdb337404b199e37f7ab5aa07c7a7b76fba0c0ac77',{
                0x800d0c18:0xac4022b8, 0x800d0c1c:0x8c84001c,
                0x800d0c24:0x94830016, 0x800d0c2c:0x30620001,
                0x800d0c30:0x14400003, 0x800d0c34:0x3062fffe,
                0x800d0c3c:0x00001021, 0x800d0c40:0xa4820016,
                0x800d0c44:0x0c030c41, 0x800d0c48:0x3404050a,
                0x800d0c4c:0x34020001, 0x800d0c58:0x03e00008,
            })
        self.assertEqual(stores,[0xafbf0010,0xac4022b8,0xa4820016])

    def test_balloon_cure_preserves_other_bits_and_uses_eight_four_two_priority(self):
        stores=self.check_window(0x800d0c60,0x800d0cd8,
            '401fccee61bccd80bc1788232dc14a3b82326c449e5de6b17a4bcacf0753c108',{
                0x800d0c70:0xac4022b8, 0x800d0c74:0x8c84001c,
                0x800d0c7c:0x94830016, 0x800d0c84:0x3062000e,
                0x800d0c88:0x1040000e, 0x800d0c8c:0x30620008,
                0x800d0c90:0x14400007, 0x800d0c94:0x3062fff7,
                0x800d0c98:0x30620004, 0x800d0c9c:0x10400003,
                0x800d0ca8:0x3062fffb, 0x800d0cac:0x3062fffd,
                0x800d0cb0:0xa4820016, 0x800d0cb4:0x0c030c41,
                0x800d0cb8:0x3404081c, 0x800d0cc0:0x34020001,
                0x800d0cc4:0x00001021, 0x800d0cd0:0x03e00008,
            })
        self.assertEqual(stores,[0xafbf0010,0xac4022b8,0xa4820016])

    def test_battle_exit_commits_low_nibble_with_independent_hp_gate_and_count(self):
        stores=self.check_window(0x800de1ec,0x800de27c,
            '611266017a563c71a9613df4fc0dcf62e507165754a56b84379ab995c0cea650',{
                0x800de1f8:0x8c62001c, 0x800de200:0x18400015,
                0x800de20c:0x25250b94, 0x800de210:0x25270f90,
                0x800de214:0x90a20045, 0x800de21c:0x10400005,
                0x800de220:0x24e7000c, 0x800de224:0x8cc3001c,
                0x800de228:0x94a20012, 0x800de230:0xa4620006,
                0x800de234:0x94a2004a, 0x800de23c:0x3042000f,
                0x800de240:0xa4620016, 0x800de254:0x24a50054,
                0x800de260:0x2442e27c, 0x800de270:0xac220000,
                0x800de278:0x2402ffff,
            })
        self.assertEqual(stores,[0xa4620006,0xa4620016,0xac220000])


if __name__=='__main__':unittest.main()
