#!/usr/bin/env python3
"""Static front-vacancy scan and position/formation swap consumers."""
from pathlib import Path
import hashlib
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_first_room import source


class FrontPromotionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.main,_=source('MAIN.EXE')
        cls.base=struct.unpack_from('<I',cls.main,24)[0]

    def check_window(self,first,last,digest,words):
        self.assertEqual(hashlib.sha256(self.main[2048+first-self.base:2048+last-self.base]).hexdigest(),digest)
        for address,expected in words.items():
            self.assertEqual(struct.unpack_from('<I',self.main,2048+address-self.base)[0],expected,hex(address))

    def test_party_vacancies_scan_identity_order_and_skip_locked_replacements(self):
        self.check_window(0x800f6614,0x800f670c,
            'ee3930d79f41beff5ca7ae17c7ed85cbacf70a05725ef80ebbd241b52ab26551',{
                0x800f6620:0x8c62001c, # party limit, not all combatants
                0x800f662c:0x34110001, # first identity
                0x800f6634:0x92020045, # committed inactive vacancy
                0x800f663c:0x10400027,
                0x800f6644:0x92020044, # vacancy must be front
                0x800f664c:0x2c420004,
                0x800f6664:0x34050001, # scan replacement identities from one
                0x800f667c:0x90620045, # replacement must be active
                0x800f6684:0x1440000a,
                0x800f668c:0x90820005, # locked replacement skips
                0x800f6694:0x14400006,
                0x800f669c:0x90620044, # replacement must be rear
                0x800f66a4:0x2c420004,
                0x800f66a8:0x10400008,
                0x800f66b4:0x24a50001,
                0x800f66cc:0x0c03d8f0, # position/formation swap helper
                0x800f66d0:0x02202021,
                0x800f66fc:0x26310001,
                0x800f6708:0x26100054,
            })

    def test_complete_swap_preserves_three_axes_and_formation_then_dispatches_motion(self):
        self.check_window(0x800f63c0,0x800f64f0,
            'ba459b0770e6542b92464e410d7d7e8c49ccd901ef9a07784d6a433f36f6e5c2',{
                0x800f63f8:0x8c43005c, 0x800f6410:0x8c450060,
                0x800f6420:0x8c450064, # preserve first actor XYZ
                0x800f643c:0xac45005c, 0x800f644c:0xac450060,
                0x800f645c:0xac450064, # second -> first XYZ
                0x800f646c:0xac65005c, 0x800f647c:0xac650060,
                0x800f648c:0xac650064, # saved first -> second XYZ
                0x800f6490:0x92070044, 0x800f6494:0x90430044,
                0x800f64a4:0xa2030044, 0x800f64ac:0xa0470044,
                0x800f64a8:0x0c038e08, # replacement movement descriptor
                0x800f64b0:0x9602004a, 0x800f64b8:0x30420008,
                0x800f64bc:0x14400007, # status8 skips fallen actor motion
                0x800f64d0:0x0c038e08,
                0x800f64e8:0x03e00008,
            })

    def test_shared_return_descriptor_moves_home_over_twenty_updates(self):
        offset=2048+0x8016c094-self.base
        raw=self.main[offset:offset+20]
        self.assertEqual(hashlib.sha256(raw).hexdigest(),
            'b7bd0f01a971a5a61aeea71501a9e7b40c24e4865f671d1ca63c3edbc6915067')
        self.assertEqual(struct.unpack('<10H',raw),(15,0,1,22,20,21,16,0,1,0))


if __name__=='__main__':unittest.main()
