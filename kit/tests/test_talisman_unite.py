#!/usr/bin/env python3
"""Static paired-Unite setup/damage/return checks; native tests own execution."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_first_room import source
import q_residue
from test_physical_rune_export import independent_stream


class PairedUniteSource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw,_ = source('MAIN.EXE')
        cls.base,size = struct.unpack_from('<II',raw,0x18)
        cls.body = raw[2048:2048+size]

    def word(self,address):
        return struct.unpack_from('<I',self.body,address-self.base)[0]

    def pins(self,expected):
        for address,word in expected.items(): self.assertEqual(self.word(address),word,hex(address))

    def test_both_initializers_bind_two_own_script9_tracks_and_one_target(self):
        rows=q_residue.unites()
        for index,name,members,initializer,update,digest in (
            (0,'Talisman attack',[6,2],0x800F9758,0x800F98A0,'4779c8982e4106ceac972d7561224a45b9a9439b3a4e0d97a388d1acd844509d'),
            (1,'Fisherman attack',[32,38],0x800F9920,0x800F9A68,'6266a122b20f35b1902aea1e0424d70b06a40cb5b8be7ebb8f11af10ead62c99')):
            pointer=self.word(0x8016D190+index*4)-self.base
            count,unite_id=struct.unpack_from('<2B',self.body,pointer+24)
            self.assertEqual((count,unite_id),(2,index+1))
            self.assertEqual(list(self.body[pointer+26:pointer+26+count]),members)
            self.assertEqual((rows[index]['name'],rows[index]['members'],rows[index]['unite_id']),(name,members,unite_id))
            self.assertEqual(self.word(0x8016D2D0+4*unite_id),initializer)
            self.assertEqual(hashlib.sha256(self.body[initializer-self.base:update-self.base]).hexdigest(),digest)
        self.pins({0x800F97E4:0x8C460024,0x800F97E8:0x0C038E08,0x800F97EC:0x02602821,
                   0x800F9818:0x8C460024,0x800F981C:0x0C038E08,0x800F9820:0x02602821,
                   0x800F9874:0x246398A0,0x800F9878:0xAC830018,
                   0x800F99AC:0x8C460024,0x800F99B0:0x0C038E08,0x800F99B4:0x02602821,
                   0x800F99E0:0x8C460024,0x800F99E4:0x0C038E08,0x800F99E8:0x02602821,
                   0x800F9A3C:0x24639A68,0x800F9A40:0xAC830018})

    def test_updates_sum_two_contributions_scale_once_and_consume_both_hit_flags(self):
        for start,end,digest in (
            (0x800F98A0,0x800F9920,'7ef2193b388e214c0e80b73fbad379d41a79f73bf0a4507765965dd52bd88691'),
            (0x800F9A68,0x800F9AE8,'586136dcd22b10ba429e6ae08ee5556d3d13d3aa6b24b66fc2b510e5d1c72033'),
            (0x800F9488,0x800F95E8,'88a76988964995db271967bcd5615bca4a42c0cb319cc0c9e2364affe56da346')):
            self.assertEqual(hashlib.sha256(self.body[start-self.base:end-self.base]).hexdigest(),digest)
        self.pins({0x800F98B8:0x34050002,0x800F98BC:0x34060014,0x800F98C0:0x0C03E522,
                   0x800F9A80:0x34050002,0x800F9A84:0x3406001E,0x800F9A88:0x0C03E522,
                   0x800F94FC:0x80940B89,0x800F9500:0x30420002,0x800F9504:0x1040002D,
                   0x800F951C:0x8E040000,0x800F9520:0x0C03DFA4,0x800F9524:0x02802821,
                   0x800F9530:0x02429021,0x800F9550:0x26100004,0x800F9554:0x0236102A,
                   0x800F9558:0x3084FFFD,0x800F955C:0x1440FFEF,0x800F9560:0xA4640040,
                   0x800F9564:0x02570018,0x800F9570:0x3402000A,0x800F9574:0x00A2001A,
                   0x800F95A0:0x0C038595,0x800F95A4:0x02802021})
        block=self.body[0x800F9488-self.base:0x800F95E8-self.base]
        words=[w for (w,) in struct.iter_unpack('<I',block)]
        self.assertEqual(words.count(0x0C03DFA4),1) # One loop call site.
        self.assertEqual(words.count(0x0C038595),1) # One combined publication.
        branch=self.word(0x800F9504)
        self.assertEqual(0x800F9508+struct.unpack('<h',struct.pack('<H',branch&65535))[0]*4,0x800F95BC)

    def test_fisherman_return_contains_recovery_while_talisman_return_does_not(self):
        self.pins({0x800F9860:0x2442D214,0x800F9868:0xAC22A020,
                   0x800F9A28:0x2442D258,0x800F9A30:0xAC22A020})
        talisman=independent_stream(self.body,0x8016D214-self.base,base=self.base)
        fisherman=independent_stream(self.body,0x8016D258-self.base,base=self.base)
        recovery=dict(op=40,args=[7,100])
        self.assertFalse(any(row['op']==40 and row['args'][0]==7 for row in talisman))
        self.assertEqual([row for row in fisherman if row['op']==40 and row['args'][0]==7],[recovery])
        self.assertEqual(self.word(0x800C11B4+7*4),0x800E05B0)
        self.assertEqual(struct.unpack_from('<H',self.body,0x8016BAA8+7*2-self.base)[0],0x40)
        self.pins({0x800E05C8:0x34030001,0x800E05CC:0xA043004D,
                   0x800E05D0:0xA0430046,0x800F6584:0x30420040,
                   0x800F6590:0x9202004D,0x800F6598:0x14400003,
                   0x800F65A0:0x0C0381DE,0x800F65A4:0x34050007,
                   0x800F65B0:0x2442FFFF,0x800F65B4:0xA202004D})



if __name__=='__main__':
    unittest.main()
