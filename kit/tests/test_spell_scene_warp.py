#!/usr/bin/env python3
"""Independent original operands and state/geometry reference for screen-sampled spells."""
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from disc import extract
import spell_scene_source as source
import spell_scene_warp as warp
import battle_drops


class Warp(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        exe=extract(17976,757760)
        cls.base,size=struct.unpack_from('<II',exe,24);cls.image=exe[2048:2048+size]

    def word(self,pc):return struct.unpack_from('<I',self.image,pc-self.base)[0]

    def sine(self,angle):
        # Independent folded quarter-wave consumer at80150810.
        angle%=4096
        if angle<1024:quadrant=angle;sign=1
        elif angle<2048:quadrant=2048-angle;sign=1
        elif angle<3072:quadrant=angle-2048;sign=-1
        else:quadrant=4096-angle;sign=-1
        return sign*struct.unpack_from('<h',self.image,0x801765BC-self.base+2*quadrant)[0]

    def test_initializer_sampler_material_and_actor_operands(self):
        expected={0x80112B9C:0x34040018,0x80112BA0:0x34050002,0x80112BA4:0x34060078,0x80112BAC:0x3407017C,
                  0x80112BC4:0x34040280,0x80112BC8:0x34050100,0x80112BCC:0x340601FE,0x80112BD4:0x3407017D,
                  0x80112BFC:0x340300B8,0x80112C10:0x34020098,0x80112C1C:0x34020078,
                  0x80112EE4:0x248402AA,0x801131D8:0x2442FE00,0x80113064:0x2442FFAB,0x80113330:0x24420055,
                  0x80113488:0x3402012C,0x80113490:0x34040002,0x80113494:0x34050002,
                  0x8011364C:0x8E230044,0x80113654:0xAC4312FC,0x80113658:0x34030001,0x8011365C:0xA4431324,
                  0x8011F038:0x00621823,0x8011F484:0x00641823,0x8011FDA8:0x00023183,
                  0x800E7F5C:0x2453017C,0x800E7F68:0x3404017C,0x800E7F7C:0x340401FD}
        for pc,word in expected.items():self.assertEqual(self.word(pc),word,hex(pc))
        p=warp.voice_profile();self.assertEqual(p['phases'],[64]*5+[1,1]);self.assertEqual((p['impact'],p['release']),(320,322))
        self.assertEqual(p['ring']['blend'],'subtractive');self.assertEqual(p['ring']['center_color'],[255]*3)
        self.assertEqual([struct.unpack_from('<9h',self.image,pc-self.base) for pc in (0x8016E524,0x8016E540)],
                         [(23,0,32,-120,0,0,0,0,-8),(23,3,32,0,0,0,0,0,-16)])
        # Reserved actor0 supplies the absolute zero origin for mode0, not Hero.
        for pc,word in {0x800DF184:0x24B10050,0x800DF210:0xAE200068,0x800DF218:0xAE20006C,0x800DF220:0xAE200070}.items():self.assertEqual(self.word(pc),word)

    def test_four_source_consumers_reach_the_same_setup_constructor_and_drawer(self):
        for _,initializer,updater in warp.CONSUMERS:
            words=[self.word(pc) for pc in range(initializer,updater,4)]
            self.assertIn(0x0C000000|((0x8011DDD4>>2)&0x3ffffff),words)
            self.assertIn(0x0C000000|((0x8011CE64>>2)&0x3ffffff),words)
            end=source.Image(self.image,self.base).end(updater)
            words=[self.word(pc) for pc in range(updater,end,4)]
            self.assertIn(0x0C000000|((0x8011E0EC>>2)&0x3ffffff),words)
        self.assertEqual([r['spell'] for r in warp.voice_profile()['consumers']],['spell_22','spell_25','spell_26','spell_27'])

    def test_all_voice_states_against_incremental_callback_reference(self):
        phase=0;clock=0;root=1;warp_scale=4096;ring=1;angle=1;tint=0;wash=0;actor=4096;focus=0;pulse_clock=0;sine_clock=0;radii=[120,152,184]
        for u in range(1,323):
            inbound=False;returning=False;damage=False;cleanup=False;pulse=None;active=phase in (2,3,4)
            if phase==0:
                tint+=8192;ring+=64;angle+=64;wash+=4096
            elif phase==1:
                if clock<32:tint-=16384
            elif phase==2:
                if clock<49:root+=349525;focus+=682
                else:root-=1048576
                inbound=clock==16
                if clock>=16:actor-=85
                warp_scale=root>>12
            elif phase==3:
                if clock==0:warp_scale=4096;radii=[40,80,120]
                sine_clock+=1
                a=self.sine(sine_clock*64)*20;b=self.sine((sine_clock+32)*64)*20
                radii[0]=40+(abs(a)//4096)*(-1 if a<0 else 1)
                radii[1]=80+(abs(b)//4096)*(-1 if b<0 else 1)
            elif phase==4:
                focus-=512;returning=clock==16
                if clock<49:actor+=85
                if clock<16:root+=524288;radii[2]+=2;radii[1]+=2
                elif clock<32:root-=524288;radii[2]-=2;radii[1]-=2
                wash-=4096;damage=clock==63
            elif phase==6:cleanup=True
            if damage:active=False
            if active:
                pulse_clock+=1
                if pulse_clock%2==0:pulse=focus
            clock+=1
            if phase<=4 and clock==64:
                if phase==2:root=1
                phase+=1;clock=0
            elif phase==5:phase+=1;clock=0
            row=warp.voice_state(u)
            expected=dict(caster_size=ring,caster_angle=angle,caster_tint=(tint>>12)&255,ring_active=active,warp_active=active,
                          ring_scale=root>>12,warp_scale=warp_scale,warp_radii=radii,actor_scale=actor,wash=wash>>12,
                          actor_inbound=inbound,actor_return=returning,camera_pulse_delta_q12=pulse,damage=damage,cleanup=cleanup)
            for key,value in expected.items():self.assertEqual(row[key],value,(u,key))

    def test_geometry_matches_independent_rotated_axis_equations_and_closes_seam(self):
        # The shared RotMatrix uses a separate interleaved sin/cos table.
        table=struct.unpack_from('<8192h',self.image,0x801725BC-self.base)
        sin_table,cos_table=table[::2],table[1::2]
        def short(v):return ((v+32768)%65536)-32768
        def axis(radius,angle,scale,origin):
            i=abs(angle)&4095;s=sin_table[i]*(-1 if angle<0 else 1);c=cos_table[i]
            return [short(origin[0]+(((-s*scale)>>12)*radius>>12)),short(origin[1]+(((c*scale)>>12)*radius>>12)),origin[2]]
        for scale in (0,1,4096,4181):
            for twist in (0,37,1024,-85):
                for count in (24,30):
                    result=warp.ring_vertices(count,[40,80,120],scale,[-120,0,0],twist=twist)
                    for layer,radius in enumerate((40,80,120)):
                        for i in range(count):
                            angle=-(4096//count)*i
                            self.assertEqual(result['uv'][layer][i],axis(radius,angle,scale,[-120,0,0]))
                            self.assertEqual(result['destination'][layer][i],axis(radius,angle-(2-layer)*twist,scale,[-120,0,0]))
                    self.assertEqual(result['faces'][-1],dict(layer=2,indices=[count-1,0]))
        changed=warp.ring_vertices(24,[120,152,184],4096,[-120,0,0]);self.assertNotEqual(changed['uv'][0],changed['destination'][0])

    def test_parabolic_paths_against_actor_integrator_and_final_snap(self):
        def divide(a,b):return abs(a)//b*(-1 if a<0 else 1)
        for start in ((-120*4096,36*4096,0),(-152*4096-17,-28*4096+11,45*4096+3),(120*4096,50*4096,0)):
            for end,velocity in (((-120*4096,0,0),(0,0,-8*2048)),(start,(0,0,-16*2048))):
                path=warp.parabolic_path(start,end,32,velocity)
                position=list(start);delta=list(velocity);reference=[position.copy()]
                acc=[divide(b-a-v*32,sum(range(32))) for a,b,v in zip(start,end,velocity)]
                for update in range(1,33):
                    position=[a+b for a,b in zip(position,delta)];delta=[a+b for a,b in zip(delta,acc)]
                    reference.append(list(end) if update==32 else position.copy())
                self.assertEqual(path,reference);self.assertEqual(path[-1],list(end))
        path=warp.parabolic_path((0,0,0),(1,1,1),32,(0,0,0))
        self.assertEqual(path[-2],[0,0,0]);self.assertEqual(path[-1],[1,1,1])
        for args in [((0,0,0),(0,0,0),1,(0,0,0)),((0,0,0),(0,0,0),32,(0,0)),((0,0,0),(0,0,0),1024,(32767*4096,0,0))]:
            with self.assertRaises(ValueError):warp.parabolic_path(*args)

    def test_native_geometry_fixture_regenerates_and_retains_warp_boundaries(self):
        fixture=warp.geometry_fixture()
        self.assertEqual(fixture,json.loads((ROOT/'game/tests/fixtures/spell_warp_geometry.json').read_text()))
        self.assertEqual([len(c['commands']) for c in fixture['cases']], [0,0]+[72]*12+[0,0])
        self.assertEqual([warp.ground_depth(z) for z in (-10,0,7,8,512,100000)],[380,380,381,382,508,509])
        mesh=fixture['warp']['samples'][129]
        self.assertEqual(len(mesh['source']),73);self.assertEqual(len(mesh['destination']),73)
        self.assertEqual(fixture['warp']['faces'][23],dict(indices=[0,24,1,0],count=3))
        self.assertEqual(fixture['warp']['faces'][71],dict(indices=[48,25,72,49],count=4))

    def test_imported_actor_timeline_matches_incremental_motion_and_scale(self):
        packet=json.loads((ROOT/'game/tests/fixtures/spell_scene_library.json').read_text())
        program=packet['spells'][21]['program'];motion=program['actor_motion']
        self.assertEqual((motion['start'],motion['returning'],motion['updates']),(145,273,32))
        self.assertEqual((program['impact'],program['duration']),(320,322))
        self.assertTrue(motion['exclude_airborne']);self.assertTrue(motion['exclude_protected'])
        home=[-152,-28,45];origin=[v*4096+d for v,d in zip(home,[-17,11,3])]
        for size_base in (4096,4181):
            position=origin.copy();velocity=None;scale=size_base
            for update in range(323):
                if update in (145,273):
                    end=[-120*4096,0,0] if update==145 else [v*4096 for v in home]
                    velocity=[0,0,-16384 if update==145 else -32768]
                    def divide(a,b):return abs(a)//b*(-1 if a<0 else 1)
                    acceleration=[divide(b-a-v*32,496) for a,b,v in zip(position,end,velocity)]
                if 145<=update<=176 or 273<=update<=304:
                    position=[a+b for a,b in zip(position,velocity)]
                    velocity=[a+b for a,b in zip(velocity,acceleration)]
                    if update in (176,304):position=end.copy()
                if 145<=update<=192:scale-=85
                if 257<=update<=305:scale+=85
                self.assertEqual(size_base+motion['size_delta'][update],scale,update)
                sample=warp.actor_sample(motion,home,update,origin=origin,size_base=size_base)
                if update<145:self.assertIsNone(sample)
                else:self.assertEqual(sample,dict(position=position,size=scale),update)
            self.assertEqual(scale,size_base+85)

    def test_software_background_samples_the_ground_surface_and_requires_it(self):
        import numpy as np
        from battle_drops_preview import Raster
        y,x=np.mgrid[:256,:512];background=np.stack((x%256,y,np.full_like(x,64),np.full_like(x,255)),axis=-1).astype(np.uint8)
        command=dict(kind='background',vertices=[[10,30],[20,30],[10,40],[20,40]],background_uv=[[90,100],[100,100],[90,110],[100,110]],intensity=[127]*3,depth=380,blend='opaque')
        raster=Raster();raster.command(command,[],background)
        self.assertEqual(raster.rgb[35,15].tolist(),[94,104,63])
        self.assertEqual(raster.rgb[29,15].tolist(),[0,0,0])
        self.assertTrue(raster.coverage[35,15]);self.assertFalse(raster.coverage[29,15])
        with self.assertRaises(ValueError):raster.command(command,[])
        command['vertices']=command['vertices'][:3];command['background_uv']=command['background_uv'][:3]
        raster=Raster();raster.command(command,[],background)
        self.assertEqual(raster.rgb[31,11].tolist(),[90,100,63])
        full=Raster(bounds=(0,0,320,240));full.quad([[0,0],[8,0],[0,8],[8,8]],texture=background[:8,:8])
        self.assertNotEqual(full.rgb[1,1].tolist(),[0,0,0])
        transparent=background[:8,:8].copy();transparent[:,:,3]=0
        full=Raster(bounds=(0,0,320,240));full.quad([[0,0],[8,0],[0,8],[8,8]],texture=transparent)
        self.assertFalse(full.coverage.any())

    def test_visible_voice_uvs_stay_inside_the_captured_ground_rectangle(self):
        def clip(points,axis,limit,greater):
            output=[]
            for a,b in zip(points,points[1:]+points[:1]):
                ina=a[axis]>=limit if greater else a[axis]<=limit
                inb=b[axis]>=limit if greater else b[axis]<=limit
                if ina:output.append(a)
                if ina!=inb:
                    t=(limit-a[axis])/(b[axis]-a[axis]);output.append([x+t*(y-x) for x,y in zip(a,b)])
            return output
        fixture=warp.geometry_fixture(range(129,320))
        for case in fixture['cases']:
            for command in case['commands']:
                triangles=((0,1,2),) if len(command['vertices'])==3 else ((0,1,2),(1,3,2))
                for ids in triangles:
                    polygon=[command['vertices'][i]+command['background_uv'][i] for i in ids]
                    for axis,limit,greater in ((0,0,True),(0,320,False),(1,19,True),(1,168,False)):
                        if polygon:polygon=clip(polygon,axis,limit,greater)
                    for _,_,u,v in polygon:
                        self.assertTrue(-1e-5<=u<=320.00001,(case['update'],u,v))
                        self.assertTrue(-1e-5<=v<=240.00001,(case['update'],u,v))

    def test_changed_source_and_bad_geometry_fail(self):
        for pc in (0x80112EE4,0x80113330,0x8011F038,0x8011FDA8,0x800DF210,0x800E7F5C):
            image=bytearray(self.image);struct.pack_into('<I',image,pc-self.base,0)
            with self.assertRaises(ValueError):warp.voice_profile(source.Image(image,self.base))
        for u in (-1,323,1.5):
            with self.assertRaises(ValueError):warp.voice_state(u)
        for args in [(2,[1,2,3],4096,[0,0,0]),(65,[1,2,3],4096,[0,0,0]),(24,[1,2],4096,[0,0,0]),(24,[1,2,3],-1,[0,0,0]),(24,[1,2,3],4096,[40000,0,0])]:
            with self.assertRaises(ValueError):warp.ring_vertices(*args)

    def test_generated_report_is_current_and_keeps_visual_gate(self):
        p=warp.voice_profile();self.assertEqual(p,json.loads((ROOT/'kit/data/reports/spell_voice_earth_warp.json').read_text()))
        self.assertTrue(p['runtime_ready']);self.assertEqual(p['blockers'],[])
        self.assertEqual(p['visual_acceptance'],'pending');self.assertEqual(len(p['samples']),323)
        self.assertEqual(p['sampler']['capture_ground_depth'],[382,509])
        self.assertEqual([u['update'] for u in p['samples'] if u['actor_inbound']],[145])
        self.assertEqual([u['update'] for u in p['samples'] if u['actor_return']],[273])


if __name__=='__main__':unittest.main()
