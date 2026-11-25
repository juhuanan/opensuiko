#!/usr/bin/env python3
"""Independent static checks for Guardian's signed pointer and visual consumers."""
from pathlib import Path
import struct
import sys
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from disc import extract
import spell_rules


class GuardianRule(unittest.TestCase):
    def test_raw_pointer_complete_script_dispatch_table_and_packet_consumers(self):
        exe=extract(17976,757760)
        base,size=struct.unpack_from('<II',exe,24)
        body=exe[2048:2048+size]
        def word(address):return struct.unpack_from('<I',body,address-base)[0]
        upper,lower=word(0x80112600),word(0x80112604)
        self.assertEqual((upper,lower),(0x3C068017,0x24C6F234))
        pointer=((upper&65535)<<16)+struct.unpack('<h',struct.pack('<H',lower&65535))[0]
        self.assertEqual(pointer,0x8016F234)
        chain=struct.unpack_from('<18H',body,pointer-base)
        self.assertEqual(chain,(4,0,3,2,38,41,255,255,64,3,48,41,128,128,128,39,0,0))
        self.assertEqual([word(0x8016BABC+4*i) for i in (0,3,4,38,39,41)],
                         [0x800E38F0,0x800E3900,0x800E3A58,0x800E57E4,0x800E58D8,0x800E5A08])
        # Both packet buffers receive RGB bytes; this is separate from stat writes.
        self.assertEqual([word(a) for a in (0x800E5A60,0x800E5A70,0x800E5A80,0x800E5A90,0x800E5AA0,0x800E5AB0)],
                         [0xA0490004,0xA0480005,0xA0470006]*2)
        report,asset=spell_rules.build()
        self.assertEqual(report['coverage']['supported'],33)
        guardian=asset['spells'][32]
        self.assertEqual(guardian['status'],'supported')
        self.assertEqual(guardian['steps'],[dict(order=0,op='scale_bonus',target='all_allies',field='defense',percent=150)])
        self.assertIsNone(guardian['blocker'])


if __name__=='__main__':unittest.main()
