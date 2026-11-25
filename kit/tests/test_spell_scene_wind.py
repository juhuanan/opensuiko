#!/usr/bin/env python3
"""Independent raw operands and source strip-writer arithmetic."""
from pathlib import Path
import struct
import sys
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import spell_scene_source as source
import spell_scene_wind as wind
import spell_effect_sweep
from disc import extract


class Wind(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        exe=extract(17976,757760);cls.base,size=struct.unpack_from('<II',exe,24);cls.image=exe[2048:2048+size]
        cls.effects={e['name']:e for e in spell_effect_sweep.build()['effects']}

    def word(self,pc):return struct.unpack_from('<I',self.image,pc-self.base)[0]

    def test_constructor_segments_dimensions_and_instances(self):
        for name,site,count,amplitude,width,height in [('The Shredding',0x80109508,16,80,30,50),('Storm',0x8010A77C,6,200,70,120)]:
            rows=wind.constructors(self.effects[name]);self.assertEqual(len(rows),count)
            expected=10 if name=='The Shredding' else 24
            self.assertEqual(self.word(site),0x0C049656)
            self.assertEqual(self.word(site+4)&65535,expected)
            self.assertEqual([r['instance'] for r in rows],list(range(count)))
            self.assertTrue(all([r['segments'],r['amplitude'],r['width'],r['height']]==[expected,amplitude,width,height] for r in rows))

    def test_curve_points_match_writer_including_negative_truncation(self):
        def div0(n,d):return (abs(n)//d)*(-1 if n<0 else 1)
        for segments in (3,10,24,64):
            for amplitude,width,height in ((80,30,50),(200,198,120),(200,70,120)):
                expected=[];t=4096
                for i in range(segments+1):
                    squared=div0(t*t,4096)-4096
                    x=amplitude+div0(amplitude*squared,4096)
                    inner=x if i==0 else amplitude+div0(width*squared,4096)
                    y=div0(height*t,4096);expected.append([[x,y,0],[inner,y,0]])
                    t-=8192//segments
                self.assertEqual(wind.strip_edges(amplitude,width,height,segments),expected)
        # Both target velocity words are cleared before callers preserve their low Q12 bits.
        self.assertEqual(self.word(0x80125AC4),0xAC400030)
        self.assertEqual(self.word(0x80125AC8),0xAC40002C)
        #24 segments do not divide8192; the writer retains the truncated step.
        self.assertEqual(wind.strip_edges(200,70,120,24)[-1][0][1],-119)
        with self.assertRaises(ValueError):wind.strip_edges(200,70,120,0)

    def test_storm_trail_copy_order_motion_dimensions_and_damage(self):
        effect=self.effects['Storm'];p=wind.storm_program(effect,list(range(len(effect['pieces']))))
        self.assertEqual((p['impact'],p['duration'],p['reaction']['start'],p['reaction']['release']),(224,281,171,15))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(97,60)])
        live=[False]*6;positions=[0]*6;clock=0
        for u in range(281):
            if u==97:live[0]=True
            if 161<=u<=196:
                clock+=1
                if clock>=36:live=[False]*6
                for i in range(5,0,-1):live[i]=live[i-1];positions[i]=positions[i-1]
                if live[0]:positions[0]=-256*(clock+1)*512
            for i,track in enumerate(p['tracks'][1:]):
                self.assertEqual(track[u]['visible'],live[i],(u,i))
                if live[i]:self.assertEqual(track[u]['position'][0],positions[i])
            if 97<=u<=160:self.assertEqual(p['tracks'][1][u]['tint'],[128-2*(u-96),128-(u-96),128])
        self.assertEqual(p['meshes'][0]['strip_edges'][97][12],[[0,0,0],[4,0,0]])
        self.assertEqual(p['meshes'][0]['strip_edges'][160][12],[[0,0,0],[130,0,0]])
        self.assertEqual([t[97]['tint'] for t in p['tracks'][2:]],[[0,60,120],[0,56,112],[0,52,104],[0,48,96],[0,44,88]])

    def test_mutated_curve_height_propagates_and_changed_writer_is_rejected(self):
        from unittest.mock import patch
        image=source.Image();raw=bytearray(image.data)
        struct.pack_into('<I',raw,0x8010A7B0-image.base,0x34A5A000)
        with patch.object(source,'Image',return_value=source.Image(raw,image.base)):
            p=wind.storm_program(self.effects['Storm'],list(range(len(self.effects['Storm']['pieces']))))
        self.assertEqual(p['meshes'][0]['strip_edges'][97][0][0][1],122)
        raw=bytearray(image.data);struct.pack_into('<I',raw,0x801251F8-image.base,0)
        with self.assertRaisesRegex(ValueError,'wind strip source changed'):wind.constructors(self.effects['Storm'],source.Image(raw,image.base))

    def test_paired_heads_and_interleaved_trail_keep_target_relative_motion(self):
        p=wind.shredding_program(self.effects['The Shredding'],list(range(len(self.effects['The Shredding']['pieces']))))
        self.assertEqual((p['impact'],p['duration'],p['reaction']['start']),(208,265,163))
        self.assertEqual(len(p['reaction']['offsets']),15)
        self.assertEqual(p['reaction']['offsets'],[[-5,0]]*5+[[0,5]]*5+[[-5,0]]*5)
        self.assertEqual(p['reaction']['tints'],[[64,64,255]]*15)
        self.assertEqual(p['reaction']['flash_frames'],[3]*15)
        table=struct.unpack_from('<1025h',self.image,0x801765BC-self.base)
        def sine(angle):
            angle%=4096
            if angle<=1024:return table[angle]
            if angle<=2048:return table[2048-angle]
            if angle<=3072:return -table[angle-2048]
            return -table[4096-angle]
        states=[None]*16
        for u in range(265):
            if u==97:states[0]=states[1]=([0,0,0],[0,0,0])
            if 145<=u<=192:
                clock=u-144
                if clock==48:states=[None]*16
                states[2:]=states[:-2]
                if clock<48:
                    z=30*sine(clock*64);wave=60*sine(clock*128)
                    states[0]=([0,-wave,z],[256*(clock+1)]*2+[0]);states[1]=([0,wave,z],[256*(clock+1)]*2+[0])
            for i,track in enumerate(p['tracks'][1:]):
                self.assertEqual(track[u]['visible'],states[i] is not None,(u,i))
                if states[i] is not None:self.assertEqual((track[u]['position'],track[u]['target_weight']),states[i])
        self.assertEqual(p['meshes'][0]['strip_edges'][97][5],[[0,0,0],[3,0,0]])
        self.assertEqual(p['meshes'][0]['strip_edges'][144][5],[[0,0,0],[50,0,0]])

    def test_healing_trail_matches_independent_reverse_copy_and_growth(self):
        p=wind.healing_trail_program(self.effects['Healing Wind'],list(range(len(self.effects['Healing Wind']['pieces']))))
        self.assertEqual((p['impact'],p['duration'],p['reaction']['start'],p['reaction']['release']),(288,289,193,49))
        import spell_scene_objects
        facts,_=source.analyze(int(self.effects['Healing Wind']['initializer'],16))
        nodes=spell_scene_objects.constructors(facts)['objects']
        self.assertEqual([node['slot'] for node in nodes if node['animation']==1],[8+4*i for i in range(30)])
        self.assertNotIn(132,[node['slot'] for node in nodes])
        states=[dict(position=[0,0,0],scale=[4096]*3,angles=[0,0,0],size=1,live=False) for _ in range(30)]
        x=y=z=16777216;rotation=0
        for u in range(289):
            if u==65:
                for state in states:state.update(position=[409600,0,-1228800],live=True)
            if 65<=u<=128:x-=209715;y-=209715;z-=262144
            if 161<=u<=224:z+=174762;x=y=z
            if 65<=u<=224:rotation+=144
            if u==224:
                for state in states:state['live']=False
            states[0].update(scale=[x>>12,y>>12,z>>12],angles=[0,0,rotation])
            for i in range(29,0,-1):
                state=states[i-1];states[i]=dict(state)
            for state in states:
                if state['live']:state['size']=min(2048,state['size']+128)
            for i,track in enumerate(p['tracks'][1:31]):
                actual=track[u];expected=states[i]
                self.assertEqual(actual['piece'] is not None,expected['live'],(u,i))
                self.assertEqual((actual['position'],actual['scale'],actual['angles']),(expected['position'],expected['scale'],expected['angles']),(u,i))
                if expected['live']:self.assertEqual(actual['size'],expected['size'])
                self.assertEqual(actual['tint'],[(29-i)*127//29]*3)
            mesh=p['meshes'][0]
            self.assertEqual(mesh['base_heights'][u],-5-4*min(max(u-128,0),96))
            self.assertEqual(p['tracks'][31][u]['scale'],[4096-64*min(max(u-224,0),64)]*2+[4096])
        self.assertEqual(p['tracks'][1][66]['scale'],p['tracks'][2][66]['scale'])
        self.assertNotEqual(p['tracks'][2][66]['scale'],p['tracks'][3][66]['scale'])

    def test_healing_column_source_height_mutation_reaches_scene(self):
        from unittest.mock import patch
        image=source.Image();raw=bytearray(image.data);struct.pack_into('<I',raw,0x80109F90-image.base,0x2407FFF9)
        with patch.object(source,'Image',return_value=source.Image(raw,image.base)):
            p=wind.healing_trail_program(self.effects['Healing Wind'],list(range(len(self.effects['Healing Wind']['pieces']))))
        self.assertEqual(p['meshes'][0]['base_heights'][129],-11)
        self.assertEqual(p['meshes'][0]['base_heights'][224],-391)

    def test_sleep_changed_source_is_rejected(self):
        from unittest.mock import patch
        image=source.Image();raw=bytearray(image.data)
        struct.pack_into('<I',raw,0x8010911C-image.base,0x24420021)
        effect=self.effects['Wind of Sleep']
        with patch.object(source,'Image',return_value=source.Image(raw,image.base)):
            with self.assertRaisesRegex(ValueError,'sleep scene source changed'):
                wind.sleep_program(effect,list(range(len(effect['pieces']))),list(range(64)))


if __name__=='__main__':unittest.main()
