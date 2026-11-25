#!/usr/bin/env python3
"""Independent raw item/script joins, particle integrator and direct buff setter."""
from pathlib import Path
import json
import struct
import sys
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from disc import extract
import export_shop

class BattleItems(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw=extract(17976,757760);cls.base,size=struct.unpack_from('<II',raw,24)
        cls.image=raw[2048:2048+size];cls.catalogue={v['id']:v for v in export_shop.consumables()[0]}
    def word(self,address):return struct.unpack_from('<I',self.image,address-self.base)[0]
    def test_records_and_descriptors_select_the_four_independent_handlers(self):
        for native,key,callback,site,descriptor in ((25,'medicine',0x800F0708,0x800F0788,0x8016C2F0),(72,'mega_medicine',0x800F07AC,0x800F082C,0x8016C314),(26,'antitoxin',0x800F0850,0x800F08F4,0x8016C390),(71,'needle',0x800F0920,0x800F09C4,0x8016C3B8)):
            record=self.word(0x80167658+4*native)
            self.assertEqual(self.word(record+32),callback)
            upper=self.word(site-4)&65535;lower=struct.unpack('<h',struct.pack('<H',self.word(site)&65535))[0]
            self.assertEqual((upper<<16)+lower,descriptor)
            words=struct.unpack_from('<18H',self.image,descriptor-self.base)
            self.assertEqual(words[:3],(15,0,1))
            self.assertIn(31,words)
        self.assertEqual((self.word(0x800F2218)&65535,self.word(0x800F222C)&65535),(65436,65036))
        self.assertEqual((self.word(0x800F21E8)&65535,self.word(0x800F21D4)&65535),(4,8))
        self.assertEqual([(v['battle']['impact_delay'],v['battle']['release_delay']) for v in self.catalogue.values()],[(32,64),(31,33),(12,14),(32,64)])
    def test_particle_rows_agree_with_an_independent_step_integrator(self):
        for key,address,count in (('medicine',0x8016C338,4),('mega_medicine',0x8016C350,8)):
            raw=struct.unpack_from('<'+'h'*(count*3),self.image,address-self.base)
            velocity=[[int(v*4096/30) for v in raw[3*i:3*i+3]] for i in range(count)]
            acceleration=[[int(-v*30/435) for v in row] for row in velocity]
            positions=[[0]*3 for _ in range(count)]
            for frame in self.catalogue[key]['battle']['particles']:
                for i in range(count):
                    for axis in range(3):
                        positions[i][axis]+=velocity[i][axis];velocity[i][axis]+=acceleration[i][axis]
                    self.assertEqual(frame[i],[v/4096 for v in positions[i]])
        for tick,row in enumerate(self.catalogue['antitoxin']['battle']['particles'],1):self.assertEqual(row,[[0,0,-tick*(tick-1)/16]])
    def test_burst_uses_disc_animation_duration_and_extra_cleanup_wait(self):
        data=extract(18698,91451);base=0x800AA000
        section=struct.unpack_from('<I',data,0)[0]-base
        table=struct.unpack_from('<I',data,section+20)[0]-base
        frame=struct.unpack_from('<I',data,table+20)[0]-base
        self.assertEqual(data[frame:frame+8],bytes((2,1,1,0,29,4,30,6)))
        # Clear status follows animation-finished detection and a yielded callback.
        self.assertEqual(self.word(0x800F2F54),0x24423084)
        self.assertEqual(self.word(0x800F3114),0xA482004A)
        self.assertEqual(struct.unpack_from('<4H',self.image,0x8016C3CC-self.base),(31,99,3,1))
        self.assertEqual(struct.unpack_from('<4H',self.image,0x8016C3A8-self.base),(31,99,3,1))
    def test_copper_flesh_uses_the_direct_setter_instead_of_turtle_acquisition(self):
        self.assertEqual((self.word(0x80111220),self.word(0x80111224)),(0x0C038137,0x34050008))
        setter=[self.word(pc) for pc in range(0x800E04DC,0x800E0778,4)]
        self.assertNotIn(0x0C051F8E,setter)
        self.assertEqual(self.word(0x800E05F4),0x34020002)
        self.assertEqual(self.word(0x800E0618),0x00852025)
        self.assertEqual(self.word(0x800C11B4+8*4),0x800E05DC)
        self.assertEqual(self.word(0x800EF29C),0x30420061)
    def test_generated_items_are_current(self):
        self.assertEqual(json.loads((ROOT/'game/assets/items.json').read_text()),export_shop.export()['items.json'])
    def test_script_before_callback_order_derives_cure_and_release_boundaries(self):
        for key,kind in (('medicine','heal'),('mega_medicine','heal'),('antitoxin','poison'),('needle','balloon')):
            phase='start' if kind=='balloon' else 'timer';timer=30;colour=255
            frames=[4,6];index=0;remaining=0;done=False;selector=False;wait=None
            effect=None;release=None
            for age in range(1,80):
                # The script waits on the previous callback's selector, then its optional one-update wait.
                if selector:
                    if kind=='heal':release=age;break
                    if wait is None:wait=1
                    else:
                        wait-=1
                        if wait==0:release=age;break
                if phase=='timer':
                    timer-=1
                    if timer==0:phase='commit'
                elif phase=='start':phase='burst';remaining=frames[0]
                elif phase=='burst' and done:phase='commit'
                elif phase=='commit':
                    effect=age+(1 if kind=='heal' else 0)
                    if kind=='heal':phase='fade'
                    else:selector=True;phase='free'
                elif phase=='fade':
                    colour-=4
                    if colour<=128:selector=True
                if phase=='burst' and not done:
                    remaining-=1
                    if remaining==0:
                        index+=1
                        if index==len(frames):done=True
                        else:remaining=frames[index]
            actual=self.catalogue[key]['battle']
            self.assertEqual((actual['impact_delay'],actual['release_delay']),(effect,release))

if __name__=='__main__':unittest.main()
