#!/usr/bin/env python3
"""Independent static joins and shared-healer clocks for Dragon seal incense."""
from pathlib import Path
import json
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from disc import extract
from war_text import decode
import export_shop


class Incense(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        exe=extract(17976,757760)
        cls.base,size=struct.unpack_from('<II',exe,24)
        cls.image=exe[2048:2048+size]
        cls.item=export_shop.battle_reusables()[0][0]
    def word(self,pc):return struct.unpack_from('<I',self.image,pc-self.base)[0]

    def test_original_identity_field_help_and_group_dispatch(self):
        record=self.word(0x80167658+80*4)
        raw=self.image[record-self.base:record-self.base+36]
        self.assertEqual(decode(raw,0)[0],self.item['name'])
        self.assertEqual(struct.unpack_from('<IHBBI',raw,24),(0,12,0,11,0x800F09F0))
        self.assertEqual(self.word(0x80167928+11*4),0x800D1244)
        self.assertIn('only during battles',decode(self.image[0x8016AB28-self.base:0x8016AB80-self.base],0)[0])
        for pc,w in {0x800D1268:0x2463AB28,0x800D1278:0x24630D60,
                     0x800F0A6C:0x90A20045,0x800F0A7C:0x90620005,
                     0x800F0AB4:0x34100001,0x800F0ABC:0x92220045,
                     0x800F0AC4:0x14400006,0x800F0AD4:0x24C6C3DC,
                     0x800F0AD8:0x0C038E08,0x800F0AF0:0x26100001,
                     0x800F0AF4:0x0050102A,0x800F5268:0x82620003,
                     0x800F5270:0x18400009,0x800F527C:0xA2620003,
                     0x800F5290:0x0C032902}.items():self.assertEqual(self.word(pc),w,hex(pc))
        self.assertFalse(self.item['field_usable'])
        self.assertEqual(self.item['battle']['targeting'],'party')
        self.assertFalse(self.item['battle']['reset_pose'])

    def test_recipient_script_selects_two_frozen_clones_and_one_extra_yield(self):
        cursor=0x8016C3DC-self.base;ops=[]
        sizes={15:3,30:2,35:3,34:2,31:2,3:2,16:3,0:1}
        while True:
            op=struct.unpack_from('<h',self.image,cursor)[0];n=sizes[op]
            args=struct.unpack_from('<'+'h'*(n-1),self.image,cursor+2)
            ops.append((op,args));cursor+=n*2
            if op==0:break
        self.assertEqual(ops,[(15,(0,1)),(30,(2,)),(35,(0,9)),(34,(1290,)),(31,(99,)),(3,(1,)),(16,(0,1)),(0,())])
        self.assertEqual(self.word(0x8016BB70+9*4),0x800F215C)
        for pc,w in {0x800F21FC:0x2402FFCE,0x800F2230:0xAE830000,
                     0x800F2238:0x2631C380,0x800F227C:0x90450000,
                     0x800F2280:0x0C03878F,0x800F2290:0x34050040,
                     0x800F22A0:0x34060080,0x800F22A8:0x00003821,
                     0x800F247C:0x3402001E,0x800F274C:0x0C038595,
                     0x800F2784:0x2442FFFC,0x800F278C:0x28420081,
                     0x800F27A8:0x34020063}.items():self.assertEqual(self.word(pc),w,hex(pc))
        # Actor script sees callback state on the next update; its final wait adds one more.
        counter=30;phase='timer';white=255;signal=False;wait=None;pending=release=None
        for age in range(1,80):
            if signal:
                if wait is None:wait=1
                else:release=age;break
            if phase=='timer':
                counter-=1
                if counter==0:phase='heal'
            elif phase=='heal':pending=age;phase='white'
            elif phase=='white':
                white-=4
                if white<=128:signal=True
        self.assertEqual((pending,pending+1,release),(31,32,65))
        b=self.item['battle']
        self.assertEqual((b['pending_delay'],b['impact_delay'],b['release_delay']),(31,32,65))
        vectors=struct.unpack_from('<6h',self.image,0x8016C380-self.base)
        self.assertEqual(vectors,(0,20,0,0,-20,0))
        velocity=[[int(v*4096/30) for v in vectors[i:i+3]] for i in (0,3)]
        acceleration=[[int(-v*30/435) for v in row] for row in velocity]
        position=[[0]*3 for _ in range(2)]
        for frame in b['particles']:
            for i in range(2):
                for axis in range(3):
                    position[i][axis]+=velocity[i][axis];velocity[i][axis]+=acceleration[i][axis]
                self.assertEqual(frame[i],[v/4096 for v in position[i]])

    def test_export_and_curated_runtime_projection_match_source_identity(self):
        packet=export_shop.export()['items.json']
        self.assertEqual(packet,json.loads((ROOT/'game/assets/items.json').read_text()))
        self.assertEqual(len(packet['consumables']),4)
        ledger=json.loads((ROOT/'game/assets/campaign_policies/item_shared_ledger.json').read_text())
        row=next(i for i in ledger['items'] if i['source_item_id']==80)
        self.assertEqual((row['label'],row['max_uses'],row['price']),(self.item['name'],0,0))
        self.assertEqual(row['controller'],dict(kind='items_enum',tag=self.item['id']))
        menu=json.loads((ROOT/'game/assets/combat_systems/menu_lists.json').read_text())
        entry=next(i for i in menu['items'] if i['id']==self.item['id'])
        self.assertEqual((entry['label'],entry['uses'],entry['source_records']),(self.item['name'],0,[80]))
        self.assertEqual(menu['capacities']['admitted_items'],len(menu['items']))
        self.assertEqual(ledger['bindings']['items_enum_bound'],sum(i['controller']['kind']=='items_enum' for i in ledger['items']))


if __name__=='__main__':unittest.main()
