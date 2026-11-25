#!/usr/bin/env python3
"""Static balloon immunity/departure/HP/EXP/exit checks; no original execution."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_first_room import source


class BalloonDepartureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw,cls.origin=source('MAIN.EXE')
        cls.base,size=struct.unpack_from('<II',raw,24)
        cls.body=raw[2048:2048+size]

    def word(self,address):
        return struct.unpack_from('<I',self.body,address-self.base)[0]

    def words(self,pins):
        for address,word in pins.items():self.assertEqual(self.word(address),word,hex(address))

    def branch(self,address,opcode,target):
        word=self.word(address);self.assertEqual(word>>26,opcode)
        offset=struct.unpack('<h',struct.pack('<H',word&65535))[0]
        self.assertEqual(address+4+4*offset,target)

    def test_worn_pointed_hat_blocks_balloon_classes_but_carried_hat_does_not(self):
        self.words({0x800e065c:0x24a2ffff,0x800e0668:0x2c420002,
                    0x800e0674:0x34020003,0x800e0678:0x14a2001b,
                    0x800e0690:0x8c420f84,0x800e0698:0x8c43001c,
                    0x800e06a0:0x9062001f,0x800e06b0:0x34090003,
                    0x800e06b8:0x94620020,0x800e06c0:0x14490005,
                    0x800e06c8:0x80620022})
        self.branch(0x800e06d0,5,0x800e0768)
        # Item identity is read independently through the source name pointer.
        pointer=self.word(0x80167658+4*3)
        from war_text import decode
        self.assertEqual(decode(self.body,pointer-self.base,length=24)[0],'Pointed hat')

    def test_departure_precedes_front_promotion_without_changing_hp_or_other_status(self):
        block=self.body[0x800f6540-self.base:0x800f657c-self.base]
        self.assertEqual(hashlib.sha256(block).hexdigest(),
                         '03275126f098cb4201afb6fc81ffa7c853d784743f7e39343d8f6d2ef7e78bfb')
        self.words({0x800f6540:0x9602004a,0x800f6548:0x30420008,
                    0x800f6554:0x92020045,0x800f6564:0xa2120045,
                    0x800f6568:0xa2120046,0x800f656c:0x3c068017,
                    0x800f6570:0x24c6c170,0x800f6574:0x0c038e08})
        self.branch(0x800f654c,4,0x800f657c)
        self.branch(0x800f655c,4,0x800f657c)
        stores=[word for (word,) in struct.iter_unpack('<I',block) if word>>26 in (40,41,43)]
        self.assertEqual(stores,[0xa2120045,0xa2120046])
        self.words({0x800f6600:0x8c42001c,0x800f6604:0x26310001,
                    0x800f6608:0x0051102a,0x800f6610:0x26100054,
                    0x800f6634:0x92020045,0x800f6644:0x92020044})
        self.branch(0x800f660c,4,0x800f6540)

    def test_departed_member_gets_no_exp_and_no_boundary_hp_update(self):
        block=self.body[0x800f7124-self.base:0x800f725c-self.base]
        self.assertEqual(hashlib.sha256(block).hexdigest(),
                         'e902e835f9ced55d23c1d190d6c0c124d053531180f6f3d6c20bf4db14c40fc4')
        self.words({0x800f7134:0x92020045,0x800e979c:0x91a20045,
                    0x800e97a4:0x10400003,0x800e97ac:0x0803a643,
                    0x800e97b0:0xace00010})
        self.branch(0x800f713c,5,0x800f725c)
        self.branch(0x800e97a4,4,0x800e97b4)
        self.assertEqual((0x800e97ac&0xf0000000)|((self.word(0x800e97ac)&0x3ffffff)<<2),0x800e990c)

    def test_exit_keeps_departed_hp_and_low_status_bits(self):
        block=self.body[0x800de1ec-self.base:0x800de244-self.base]
        self.assertEqual(hashlib.sha256(block).hexdigest(),
                         '952c0dbc40bd65719b3c7a1eba08b3011430dd7c388a3d055a8dba97f267e2dc')
        self.words({0x800de214:0x90a20045,0x800de224:0x8cc3001c,
                    0x800de228:0x94a20012,0x800de230:0xa4620006,
                    0x800de234:0x94a2004a,0x800de23c:0x3042000f,
                    0x800de240:0xa4620016})
        self.branch(0x800de21c,4,0x800de234)


if __name__=='__main__':unittest.main()
