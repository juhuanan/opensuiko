#!/usr/bin/env python3
"""Static poison consumers and retained independent field-reference vectors."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_first_room import source


def field_vectors():
    rows=[]
    for maximum,hp,roll in ((100,100,255),(100,21,255),(100,20,255),(100,1,255),(19,1,255),(100,0,255),(100,100,0),(100,1,254),(100,100,4095)):
        cured=((roll//255)&15)==0
        damage=maximum//5 if not cured and hp>maximum//5 else 0
        rows.append(dict(maximum=maximum,hp=hp,roll=roll,result_hp=hp-damage,poisoned=not cured,draws=1))
    return rows


class PoisonRulesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.main,_=source('MAIN.EXE')
        cls.base=struct.unpack_from('<I',cls.main,24)[0]

    def check_window(self,first,last,digest,words):
        self.assertEqual(hashlib.sha256(self.main[2048+first-self.base:2048+last-self.base]).hexdigest(),digest)
        for address,expected in words.items():
            self.assertEqual(struct.unpack_from('<I',self.main,2048+address-self.base)[0],expected,hex(address))

    def test_field_poison_consumer_preserves_other_flags_and_cannot_kill(self):
        self.check_window(0x801264b4,0x801265f8,
            '72494ee6e558bfff87f8444f7559101cd8180016a7a2a8df0e22a571a8436c3b',{
                0x801264d4:0x92620003, # active party size
                0x8012650c:0x94420016, 0x80126514:0x30420001,
                0x80126518:0x10400032, # non-poisoned members skip the draw
                0x80126520:0x0c051f8e, 0x80126528:0x340300ff,
                0x8012652c:0x0043001a, 0x80126554:0x00001012,
                0x8012655c:0x3042000f, # (roll/255)&15
                0x80126578:0x38420001, 0x80126580:0xa4620016,
                0x80126564:0x34020005, 0x8012658c:0x94830004,
                0x80126594:0x0062001a, # maximum HP /5
                0x801265c0:0x94820006, 0x801265c8:0x0062102a,
                0x801265cc:0x10400005, # damage only when current HP > operand
                0x801265dc:0x00431023, 0x801265e0:0xa4820006,
            })

    def test_battle_poison_hp_operand_is_five_percent_including_small_maximum(self):
        self.check_window(0x800f71fc,0x800f725c,
            '48a9c8c5ed7e1263a79e49816375502d09c96e84a7b76a614bb18ea5238c43d9',{
                0x800f7118:0x34120014, # divisor20 is initialized outside this window
                0x800f71fc:0x9602004a, 0x800f7204:0x30420001,
                0x800f7208:0x10400010, 0x800f7210:0x86020010,
                0x800f7218:0x0052001a, 0x800f7240:0x00001012,
                0x800f7248:0x00a22823, # subtract from combined healing accumulator
                0x800f724c:0x10a00003, # zero operand skips the HP service
                0x800f7254:0x0c038595, 0x800f7258:0x00052823,
            })

    def test_retained_field_vectors_match_independent_nonlethal_rule(self):
        rows=json.loads((ROOT/'game/tests/fixtures/field_poison.json').read_text())
        self.assertEqual(len(rows),9)
        self.assertEqual(rows,field_vectors())


if __name__=='__main__':
    if '--write-fixtures' in sys.argv:
        (ROOT/'game/tests/fixtures/field_poison.json').write_text(json.dumps(field_vectors(),indent=2)+'\n')
        sys.argv.remove('--write-fixtures')
    unittest.main()
