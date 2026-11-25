#!/usr/bin/env python3
"""Independent original operands, lifecycle clocks and wave-wait reference."""
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from disc import extract
import spell_scene_source as source
import spell_scene_soul as soul


class Soul(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        exe=extract(17976,757760)
        cls.base,size=struct.unpack_from('<II',exe,24);cls.image=exe[2048:2048+size]

    def word(self,pc):return struct.unpack_from('<I',self.image,pc-self.base)[0]

    def test_phase_and_helper_operands_independently(self):
        words={0x80113FA8:0x28420040,0x8011404C:0x28420020,0x80114110:0x28630050,
               0x80114154:0x2442FFFF,0x80114240:0x2442FFFF,0x801142BC:0xAE020018,
               0x80114D7C:0x28420040,0x80114E28:0x28420020,0x80114F88:0x28420050,
               0x80114FA4:0x3402000A,0x80114FFC:0x34020040,0x80115034:0x3042001F,
               0x80115C6C:0x34020080,0x80115D08:0x2442FFFF,0x80115D74:0x1C400103,
               0x80115E6C:0x144000C5,0x80115E80:0x34020078,
               0x80115758:0x34040006,0x8011575C:0x340500B4,0x80115764:0x34060024,
               0x801157D0:0x340500B4,0x801157D8:0x00003021,
               0x801157BC:0x34030002,0x801157C0:0xAC430020,
               0x80124EE4:0xAE20001C,0x80124EE8:0xAE200034,
               0x80124FA8:0x00431021,0x80124FB0:0x0044102A,0x80124FDC:0xACA00014,
               0x80116464:0x2442E800,0x80116480:0x0C0493E1}
        for pc,value in words.items():self.assertEqual(self.word(pc),value,hex(pc))

    def test_hell_states_match_separate_phase_integrator_and_source_capture_depths(self):
        for pc,value in {0x80115A40:0x30840FFF,0x80115A44:0x00832025,
                         0x80115928:0x3407017A,0x80115990:0x3407017C,
                         0x80115DAC:0x8E230030,0x80115DB0:0x34020005,
                         0x80115EC0:0x34070007,0x8011FE1C:0x8C42FFFC,
                         0x80115F80:0x24420008,0x80115F90:0x30420001}.items():self.assertEqual(self.word(pc),value,hex(pc))
        for fraction,velocity_fraction in ((0,0),(1,4095),(4095,2048)):
            root=4096+fraction;radii=[180,210,240];twist=0
            rows=soul.hell_states(fraction,velocity_fraction)
            for u,row in enumerate(rows):
                if 97<=u<=224:
                    root+=131072+velocity_fraction
                    if root//4096>4096:root=16777216+root%4096
                if 225<=u<=316:
                    for i,limit in enumerate((60,120,180)):radii[i]=max(limit,radii[i]-2)
                if u==317:radii=[60,120,180]
                if 317<=u<=436:
                    twist+=8
                    if (436-u)%2==0:radii[1]-=1;radii[0]=radii[1]//2
                self.assertEqual((row['root_q12'],row['scale']),(root,root//4096))
                self.assertEqual((row['warp_radii'],row['warp_twist']),(radii,twist))
                self.assertEqual(row['warp_visible'],97<=u<436)
        self.assertEqual((rows[145]['sub_visible'],rows[146]['sub_visible']),(True,False))
        for pair in ((-1,0),(0,4096),(None,0),(True,0)):
            with self.assertRaises(ValueError):soul.hell_states(*pair)

    def test_late_capture_includes_actors_and_excludes_later_depth_buckets(self):
        from types import SimpleNamespace
        import numpy as np
        from battle_drops_preview import Preview
        view=object.__new__(Preview);view.scene=SimpleNamespace(textures=[])
        floor=np.full((240,320,4),[5,6,7,255],dtype=np.uint16)
        view.ground_image=lambda block,minimum_depth:floor
        actor=dict(vertices=[[40,40],[50,40],[40,50],[50,50]],texture=np.full((2,2,4),[255,0,0,255],dtype=np.uint8))
        low=dict(kind='color',vertices=[[40,40],[50,40],[40,50],[50,50]],colors=[[0,0,255]]*4,blend='opaque',depth=7)
        jobs=[(20,'actor',actor),(7,'effect',low)]
        capture=view.capture_background([],jobs,8,{})
        self.assertEqual(capture[45,45].tolist(),[255,0,0,255])
        self.assertEqual(view.capture_background([],jobs,22,{})[45,45].tolist(),[5,6,7,255])
        actor['visible']=False
        self.assertEqual(view.capture_background([],jobs,8,{})[45,45].tolist(),[5,6,7,255])
        earlier=dict(kind='background',depth=10,blend='opaque',intensity=[128]*3,
                     vertices=actor['vertices'],background_uv=actor['vertices'])
        surface=np.full((256,512,4),[0,255,0,255],dtype=np.uint16)
        capture=view.capture_background([],[(10,'effect',earlier)]+jobs,8,{10:surface})
        self.assertEqual(capture[45,45].tolist(),[0,255,0,255])

    def test_hell_diagnostic_program_and_native_vectors_remain_separate(self):
        packet=json.loads((ROOT/'game/tests/fixtures/spell_scene_library.json').read_text())
        self.assertIsNotNone(next(s for s in packet['spells'] if s['id']=='spell_27')['program'])
        fixture=soul.hell_fixture(packet)
        self.assertEqual(fixture,json.loads((ROOT/'game/tests/fixtures/hell_scene_diagnostic.json').read_text()))
        p=fixture['packet']['spells'][0]['program']
        self.assertEqual((p['impact'],p['duration']),(436,497))
        self.assertEqual([w['depth'] for w in p['background_warps']],[379,6])
        for u in range(498):self.assertLessEqual(sum(w['samples'][u] is not None for w in p['background_warps']),1)
        self.assertEqual([p['tracks'][9][u]['visible'] for u in (96,97,186,187,188,277,278)],[False,True,True,False,True,True,False])
        self.assertEqual([p['screen_washes'][0]['colors'][u] for u in (376,377,436,437,496,497)],
                         [None,[4]*3,[255]*3,[250]*3,[0]*3,None])

    def test_preview_diagnostics_keep_canonical_packet_and_explicit_startup(self):
        from battle_spell_preview import review_packet
        packet=json.loads((ROOT/'game/tests/fixtures/spell_scene_library.json').read_text())
        before=json.dumps(packet,separators=(',',':'))
        unchanged,startup=review_packet(packet,'spell_26')
        self.assertIs(unchanged,packet);self.assertIsNone(startup)
        for spell,name in (('spell_26','shadow_scene_diagnostic.json'),('spell_27','hell_scene_diagnostic.json')):
            result,metadata=review_packet(packet,spell,True)
            expected=json.loads((ROOT/'game/tests/fixtures'/name).read_text())
            self.assertEqual(result,expected['packet'])
            self.assertEqual(metadata,dict(status=expected['status'],startup=expected['startup']))
            self.assertIsNotNone(next(s for s in packet['spells'] if s['id']==spell)['program'])
        with self.assertRaises(ValueError):review_packet(packet,'spell_5',True)
        self.assertEqual(json.dumps(packet,separators=(',',':')),before)

    def test_fixed_root_matches_independent_store_array_and_numeric_bound(self):
        import math
        for pc,value in {0x8014EC78:0x3C03005D,0x8014EC7C:0x346350AD,
                         0x8014EC9C:0x34020004,0x8014EDAC:0x28E20007,
                         0x8014EDB8:0x8FA2001C,0x8014EDF0:0x34030008,
                         0x8014EE20:0x2610FFFA}.items():self.assertEqual(self.word(pc),value,hex(pc))
        def reference(value):
            if value==0:return 0
            shift=0;scaled=value
            # The source's negative-shift branch normalizes into a lower interval.
            if value>=1<<23:
                while scaled>=1<<25:scaled//=4;shift+=1
            else:
                while scaled<1<<21:scaled*=4;shift-=1
            xs=[scaled+6115501];ys=[scaled-6115501]
            for power in (1,2,3,4,4,5,6):
                sign=1 if ys[-1]>=0 else -1
                xs.append(xs[-1]-sign*(ys[-1]//(2**power)))
                ys.append(ys[-1]-sign*(xs[-2]//(2**power)))
            return xs[-1]*(2**(shift-6)) if shift>=6 else xs[-1]//(2**(6-shift))
        values={0,1,4095,4096,4097,0x7fffffff}
        values.update((180**2-z*z)<<12 for z in range(-176,1,4))
        values.update(1<<i for i in range(31))
        for v in sorted(values):
            actual=soul.sqrt_q12(v);self.assertEqual(actual,reference(v),v)
            exact=math.isqrt(v<<12)
            self.assertLessEqual(abs(actual-exact),max(1,exact//1000),v)
        for value in (-1,0x80000000,1.5,True,None):
            with self.assertRaises(ValueError):soul.sqrt_q12(value)

    def test_hell_pulse_shape_lifetime_scale_handoff_and_source_operands(self):
        for pc,value in {0x80116234:0x2402FF4C,0x80116248:0x3402005A,
                         0x801162A8:0x24840004,0x801162D8:0x3C0407E9,
                         0x801162E0:0x0C053B72,0x801162F8:0x24430001,
                         0x80116300:0x2442000B,0x80116320:0x24420080,
                         0x801163E4:0x2463E96D}.items():self.assertEqual(self.word(pc),value,hex(pc))
        scales=[1+32*i for i in range(91)];samples=soul.hell_pulse_samples(scales)
        for age,row in enumerate(samples):
            height=min(-180+4*(age+1),0);shape=row['shape']
            self.assertEqual(row['visible'],age<90)
            self.assertEqual(row['scale'],scales[age] if age<=44 else scales[44]+128*(age-44))
            self.assertEqual((shape['height'],shape['base_height']),(height,height))
            self.assertEqual(shape['radius']-shape['top_radius'],10)
            self.assertEqual(shape['inner'],[((127<<12)-5779*age)>>12]*3)
        self.assertEqual((samples[44]['shape']['radius'],samples[44]['shape']['top_radius']),(191,181))
        for scales in (None,[],[0]*90,[0]*92,[-1]*91,[65537]*91):
            with self.assertRaises(ValueError):soul.hell_pulse_samples(scales)

    def test_hell_pulse_native_vectors_are_reproducible(self):
        self.assertEqual(soul.pulse_geometry_fixture(),json.loads((ROOT/'game/tests/fixtures/hell_pulse_geometry.json').read_text()))

    def test_shadow_root_residue_and_all_phase_samples(self):
        for pc,value in {0x80114C6C:0x30630FFF,0x80114C70:0x34631000,
                         0x80114F30:0x34429999,0x80114FE4:0x34846667,
                         0x801150CC:0x34849999,0x80114F68:0x8C450044,
                         0x80114F6C:0x0C044DF7,0x80114EFC:0x24420060,
                         0x80114F0C:0x3405014A}.items():self.assertEqual(self.word(pc),value,hex(pc))
        for residue in (0,1,7,2048,4095):
            rows=soul.shadow_states(residue)
            for u,row in enumerate(rows):
                root=4096+residue+104857*(min(max(u-96,0),80)-min(max(u-176,0),10)+min(max(u-186,0),64))
                self.assertEqual((row['root_q12'],row['scale']),(root,root//4096),u)
                self.assertEqual(row['main_visible'],97<=u<250)
                self.assertEqual(row['sub_visible'],97<=u<128)
                self.assertEqual(row['sub_angle'],min(max(u-96,0),31)*96)
        self.assertEqual([soul.shadow_states(r)[97]['scale'] for r in (0,4095)],[26,27])
        for residue in (-1,4096,True,None):
            with self.assertRaises(ValueError):soul.shadow_states(residue)

    def test_shadow_program_has_explicit_startup_and_independent_materials(self):
        import spell_effect_sweep
        e=next(e for e in spell_effect_sweep.build()['effects'] if e['name']=='Black Shadow')
        p=soul.shadow_program(e,list(range(len(e['pieces']))),incoming_root_fraction=0,point_initial_scales=[4096]*40)
        self.assertEqual((p['impact'],p['duration'],p['initial_draws']),(310,311,0))
        self.assertEqual([c['at'] for c in p['cameras']],[1,97,250])
        self.assertEqual(len(p['meshes']),8)
        # Six bands are source quarter-wave endpoints, not six equal-height slices.
        radii=[0,51,99,141,173,193,200];heights=[-200,-193,-173,-141,-100,-51,0]
        for i,mesh in enumerate(p['meshes'][:6]):
            shape=mesh['shape_samples'][97]
            self.assertEqual([shape[k] for k in ('radius','top_radius','base_height','height')],
                             [radii[i],radii[i+1],heights[i],heights[i+1]])
            self.assertEqual((shape['inner'],shape['outer']),([21*(i+1)-1]*3,[21*i]*3))
        self.assertEqual((p['meshes'][6]['segment_gap'],p['meshes'][6]['depth']),(330,1))
        self.assertEqual(p['meshes'][6]['shape_samples'][97]['top_radius'],0)
        self.assertEqual((p['emitter']['start'],p['emitter']['spawn_stop'],p['emitter']['stop']),(97,176,310))
        self.assertEqual((p['reaction']['start'],p['reaction']['release']),(187,63))
        self.assertEqual(len(p['reaction']['offsets']),64)
        for scales in ([],[1]*39,[1]*41,[65537]*40,[None]*40):
            with self.assertRaises(ValueError):soul.shadow_program(e,[],incoming_root_fraction=0,point_initial_scales=scales)

    def test_shadow_native_diagnostic_remains_reproducible_after_startup_approval(self):
        packet=json.loads((ROOT/'game/tests/fixtures/spell_scene_library.json').read_text())
        self.assertIsNotNone(next(s for s in packet['spells'] if s['id']=='spell_26')['program'])
        fixture=soul.shadow_fixture(packet)
        self.assertEqual(fixture,json.loads((ROOT/'game/tests/fixtures/shadow_scene_diagnostic.json').read_text()))
        self.assertEqual(fixture['status'],'diagnostic_not_qualified')
        cases={c['update']:c for c in fixture['cases']}
        self.assertEqual(cases[96]['draw_count'],0)
        self.assertGreater(cases[97]['draw_count'],0)
        self.assertEqual(cases[176]['draw_count'],cases[311]['draw_count'])
        self.assertEqual(len(cases[311]['commands']),0)

    def test_complete_soul_rng_lifetimes_against_independent_source_reference(self):
        from PIL import Image
        from spell_scene_player import Player
        import spell_effect_sweep
        table=struct.unpack_from('<192h',self.image,0x8017242C-self.base)
        def sqrt(value):
            if not value:return 0
            exponent=(value.bit_length()-1)//2;mantissa=value*64//(1<<(2*exponent))
            return table[mantissa-64]*(1<<exponent)//4096
        def div(a):return abs(a)//4096*(-1 if a<0 else 1)
        for name,native,radius,spawn_stop,stop,duration,builder in (
                ('Black Shadow',26,200,176,310,311,soul.shadow_program),
                ('Hell',27,180,224,496,497,soul.hell_program)):
            effect=next(e for e in spell_effect_sweep.build()['effects'] if e['name']==name)
            for residue in (0,4095):
                args=dict(incoming_root_fraction=residue,point_initial_scales=[4096]*40)
                if native==27:args['incoming_velocity_fraction']=residue
                program=builder(effect,list(range(len(effect['pieces']))),**args)
                for seed in (0,17):
                    packet=dict(entries=[],spells=[dict(id=f'spell_{native}',name='diagnostic',program=program)])
                    player=Player(packet,f'spell_{native}',Image.new('RGBA',(1,1)),seed=seed)
                    particles=[dict(active=False,life=0,head=[0]*3,velocity=[0]*3,scale=4096) for _ in range(40)]
                    state=seed;used=0;root=4096+residue
                    def draw():
                        nonlocal state,used
                        state=(state*1103515245+12345)&0xffffffff;used+=1;return (state>>16)&32767
                    for u in range(duration+1):
                        if native==26:
                            if 97<=u<=176 or 187<=u<=250:root+=104857
                            if 177<=u<=186:root-=104857
                        elif 97<=u<=224:
                            root+=131072+residue
                            if root//4096>4096:root=16777216+root%4096
                        if 97<=u<stop:
                            for p in particles:
                                if not p['active'] and u<=spawn_stop:
                                    x=draw()%(2*(radius-1))+1-radius;extent=sqrt(radius*radius-x*x)
                                    y=draw()%(2*extent)-extent;z=-sqrt(radius*radius-x*x-y*y)
                                    speed=draw()%64+128;p['life']=draw()%120
                                    for axis,v in enumerate((x,y,z)):
                                        p['head'][axis]=(div(v*p['scale'])<<12)|(p['head'][axis]&4095)
                                        p['velocity'][axis]=-v*speed
                                    p['active']=True
                                if not p['life'] or abs(p['head'][0]>>12)<5:p['active']=False
                                else:
                                    p['life']-=1;p['head']=[v+d for v,d in zip(p['head'],p['velocity'])];p['scale']=root>>12
                        player.advance(u)
                        self.assertEqual((player.draw_count,player.seed),(used,state),(residue,seed,u))
                        for actual,expected in zip(player.particles[:40],particles):
                            self.assertEqual({k:actual[k] for k in ('active','life','head','velocity')},
                                             {k:expected[k] for k in ('active','life','head','velocity')},(residue,seed,u))
                            self.assertEqual(actual['spawn_scale'][0],expected['scale'])

    def test_hemisphere_endpoints_match_independent_folded_lookup(self):
        def sine(a):
            a%=4096
            folded=min(a%2048,2048-a%2048)
            return struct.unpack_from('<h',self.image,0x801765BC-self.base+2*folded)[0]*(-1 if a>=2048 else 1)
        def div(v):return (abs(v)//4096)*(-1 if v<0 else 1)
        for radius in (1,180,200,1024):
            for count in (1,5,6,16):
                expected=[];r,z=0,-radius
                for i in range(count):
                    a=((i+1)<<10)//count;nr=-div(radius*sine(a));nz=-div(radius*sine(a+1024))
                    expected.append(dict(lower=[r,z],upper=[nr,nz]));r,z=nr,nz
                self.assertEqual(soul.hemisphere(radius,count),expected)

    def test_hell_wait_matches_vertical_integrator_and_observation_order(self):
        profile=soul.catalogue()['spells'][2];bands=profile['object_wait']['bands']
        index=0;height=bands[0]['lower'][1];enabled=True;phase_end=None
        for update in range(225,318):
            if not enabled:phase_end=update;break
            height+=2
            if height>=bands[index]['upper'][1]:
                index+=1
                if index==6:enabled=False
                else:height=bands[index]['lower'][1]
        self.assertEqual(phase_end,316)
        self.assertEqual(profile['object_wait']['helper_updates'],91)
        self.assertEqual(profile['phases'][3]['updates'],92)
        self.assertEqual(profile['phases'][4]['start'],316)
        self.assertEqual((profile['impact'],profile['cleanup']),(436,497))

    def test_collapse_shapes_match_independent_per_band_elapsed_equations(self):
        # Endpoints independently read from the original quarter-wave table above.
        radii=[0,-46,-89,-127,-155,-173,-180];heights=[-180,-173,-155,-127,-90,-46,0]
        lengths=[4,9,14,19,22,23];ends=[];clock=0
        for length in lengths:clock+=length;ends.append(clock)
        for age,row in enumerate(soul.collapse_shapes()):
            first=sum(age>=end for end in ends)
            self.assertEqual(row['first_band'],first);self.assertEqual(row['enabled'],first<6)
            shade=max(6,(144*4096-6144*age)//4096)//6
            for i,shape in enumerate(row['shapes']):
                previous=ends[i-1] if i else 0
                elapsed=min(lengths[i],max(0,age-previous))
                began=age>=previous if i else age>0
                radial_steps=min(lengths[i]-1+bool(i),elapsed+bool(i)) if began else 0
                step=(abs(radii[i+1]-radii[i])<<24)//((heights[i+1]-heights[i])<<12)
                self.assertEqual(shape['radius'],abs(radii[i]-2*((step*radial_steps)>>12)),(age,i))
                self.assertEqual(shape['base_height'],heights[i]+2*elapsed,(age,i))
                self.assertEqual(shape['height'],heights[i+1]);self.assertEqual(shape['top_radius'],abs(radii[i+1]))
                self.assertEqual(shape['inner'],[shade*(i+1)-1]*3)
                self.assertEqual(shape['outer'],[shade*i]*3)

    def test_band_colour_consumer_increments_previous_upper_before_next_division(self):
        for pc,value in {0x80124604:0x2442FFFF,0x80124718:0x90620014,
                         0x80124720:0x24420001,0x80124724:0xA0820004,
                         0x801247AC:0x90820004,0x801247B4:0x00431021,
                         0x801247B8:0x2442FFFF}.items():self.assertEqual(self.word(pc),value,hex(pc))
        for age,row in enumerate(soul.collapse_shapes()):
            q=max(6,(144*4096-6144*age)>>12)//6
            previous=0
            for band in row['shapes']:
                self.assertEqual(band['outer'],[previous]*3)
                upper=previous+q-1
                self.assertEqual(band['inner'],[upper]*3)
                previous=upper+1

    def test_sampled_column_fixture_regenerates_with_all_handoff_boundaries(self):
        fixture=soul.geometry_fixture()
        self.assertEqual(fixture,json.loads((ROOT/'game/tests/fixtures/soul_column_geometry.json').read_text()))
        counts={c['update']:len(c['commands']) for c in fixture['cases']}
        self.assertEqual([counts[u] for u in (224,225,227,228,237,251,270,292,314,315,316,317)],
                         [0,216,216,180,144,108,72,36,36,0,0,0])

    def test_point_fixture_matches_independent_birth_and_motion_reference(self):
        fixture=soul.point_fixture()
        self.assertEqual(fixture,json.loads((ROOT/'game/tests/fixtures/soul_point_geometry.json').read_text()))
        e=fixture['packet']['spells'][0]['program']['emitter']
        table=struct.unpack_from('<192h',self.image,0x8017242C-self.base)
        def root(value):
            if not value:return 0
            exponent=(value.bit_length()-1)//2
            mantissa=(value*64)//(1<<(2*exponent))
            return table[mantissa-64]*(1<<exponent)//4096
        self.assertEqual(e['roots'],[root(n) for n in range(40001)])
        def divide(a,b):return abs(a)//b*(-1 if a<0 else 1)
        for run in fixture['runs']:
            state=run['seed'];used=0
            def draw():
                nonlocal state,used
                state=(state*1103515245+12345)&0xffffffff;used+=1;return (state>>16)&32767
            particles=[dict(active=False,life=0,head=[0]*3,velocity=[0]*3,scale=scale) for scale in e['point_initial_scales']]
            for case in run['cases']:
                u=case['update']
                if 1<=u<80:
                    for p in particles:
                        if not p['active'] and u<=40:
                            x=draw()%398-199;extent=root(40000-x*x)
                            y=draw()%(extent*2)-extent;z=-root(40000-x*x-y*y)
                            speed=draw()%64+128;p['life']=draw()%120
                            for axis,v in enumerate((x,y,z)):
                                p['head'][axis]=divide(v*p['scale'],4096)*4096+(p['head'][axis]%4096)
                                p['velocity'][axis]=-v*speed
                            p['active']=True
                        if p['life']==0 or abs(p['head'][0]//4096)<5:p['active']=False
                        else:
                            p['life']-=1;p['head']=[a+b for a,b in zip(p['head'],p['velocity'])];p['scale']=1+56*u
                self.assertEqual(used,case['draw_count'],(run['seed'],u))
                self.assertEqual(particles,case['particles'],(run['seed'],u))
                self.assertEqual(len(case['commands']),sum(p['active'] for p in particles) if u<80 else 0)
                for command in case['commands']:
                    a,b,c,d=command['vertices']
                    self.assertEqual(b,[a[0]+1,a[1]]);self.assertEqual(c,[a[0],a[1]+1]);self.assertEqual(d,[a[0]+1,a[1]+1])
                    self.assertEqual(command['depth'],0);self.assertEqual(command['colors'],[[255]*3]*4)

    def test_point_helper_operand_widths_lifetime_and_draw_consumer(self):
        for pc,word in {0x801138E0:0x8E830030,0x801138E8:0x00031B03,
                        0x801139A4:0x0C051F8E,0x801139C8:0x24420080,
                        0x80113A0C:0x34030078,0x80113A40:0xAE830040,
                        0x80115530:0xAC830030,0x80115534:0x2442FFFF,
                        0x8011378C:0x8CA5C21C,0x8014AF1C:0x34020068}.items():
            self.assertEqual(self.word(pc),word,hex(pc))

    def test_deadly_states_against_closed_phase_and_pulse_equations(self):
        rows=soul.deadly_states()
        intervals=[(97,156),(158,217),(219,245),(246,305),(307,365)]
        for u,row in enumerate(rows):
            root=1+64*min(max(u-96,0),80)-32*min(max(u-236,0),10)+64*min(max(u-246,0),60)
            self.assertEqual(row['scale'],root,u)
            # All root increments are whole Q12 units, so initial low bits cannot affect consumers.
            for residue in (0,1,2048,4095):self.assertEqual(((root<<12)+residue)>>12,root)
            active=next(((a,b) for a,b in intervals if a<=u<=b),None)
            self.assertEqual(row['pulse_visible'],active is not None,u)
            if active:
                start=active[0];age=u-start
                initial=rows[start]['scale']
                self.assertEqual(row['pulse_size'],initial+128*(age+1),u)
                self.assertEqual(row['pulse_tint'],(127*4096-8669*age)>>12,u)
            for i,start in enumerate((186,211,236)):
                self.assertEqual(row['echo_visible'][i],start<=u<start+40,u)
                if start<=u<start+40:self.assertEqual(row['echo_scales'][i],5121-128*(u-start+1))
        self.assertEqual([r['sub_angle'] for r in rows[97:100]],[32,64,96])
        self.assertEqual((rows[235]['sub_height'],rows[236]['sub_visible']),(-5,False))

    def test_deadly_line_constructor_and_gapped_column_operands(self):
        expected={0x80123B18:0xAE22006C,0x80123B1C:0xAE220068,0x80123B20:0xAE220064,
                  0x80123B24:0xAE200060,0x8012413C:0x34030032,0x80124194:0x2463000A,
                  0x801241AC:0x34030005,0x801241E4:0x24630005,0x801241F8:0x34030046,
                  0x8011449C:0xAC820068,0x801144A4:0xAC820064,0x801144AC:0x34050064,
                  0x801146D0:0x340500C8,0x80121608:0x00491023,0x8012160C:0x00621823,
                  0x801216C0:0x00491023,0x801217AC:0x28A2017B,
                  0x8014AF6C:0x34020040}
        for pc,value in expected.items():self.assertEqual(self.word(pc),value,hex(pc))

    def test_white_reaction_offsets_and_inclusive_palette_boundaries(self):
        from export_spell_scenes import reaction_track
        r=reaction_track(0x8016F1CC)
        expected=[[0,0]]+sum(([[-5,0]]*5+[[0,5]]*5 for _ in range(3)),[])+[[0,5]]
        self.assertEqual(r['offsets'],expected);self.assertEqual(r['release'],31)
        self.assertEqual(r['flash_frames'],[None]+[3]*30+[None])

    def test_countdown_damage_reactions_and_cleanup(self):
        profiles=soul.catalogue()['spells']
        for row,counts in zip(profiles,([64,32,80,60,10,60,60],[64,32,80,10,64,60],[64,32,128,92,120,60])):
            clock=0
            for phase,count in zip(row['phases'],counts):
                self.assertEqual(phase['start'],clock);self.assertEqual(phase['updates'],count);clock+=count
            self.assertEqual(row['cleanup'],clock+1)
        self.assertEqual([(p['impact'],p['cleanup']) for p in profiles],[(306,367),(310,311),(436,497)])
        self.assertEqual([187+i for i in range(64) if (64-i)&31==0],profiles[1]['reactions'])
        self.assertEqual(profiles[0]['reactions'],[246])
        self.assertEqual([[c['at'] for c in p['cameras']] for p in profiles],[[1,97,306],[1,97,250],[1,65,225]])

    def test_report_preserves_unknown_original_startup_and_records_approved_policy(self):
        p=soul.catalogue()
        self.assertEqual(json.loads(json.dumps(p)),json.loads((ROOT/'kit/data/reports/spell_soul_scenes.json').read_text()))
        self.assertEqual([s['id'] for s in p['spells']],['spell_25','spell_26','spell_27'])
        for row in p['spells']:
            self.assertTrue(row['runtime_ready'])
            self.assertFalse(row['blockers'])
            self.assertEqual(row['visual_acceptance'],'pending' if row['id']=='spell_25' else 'user_memory_match_2026-11-12')
            if row['id']!='spell_25':
                self.assertIsNone(row['allocation_startup']['root_fraction'])
                self.assertEqual(row['allocation_startup']['policy'],'user_approved_deterministic_startup_2026-11-12')

    def test_mutated_sources_and_invalid_dimensions_fail(self):
        for pc in (0x80115E6C,0x80124FDC,0x80114F88,0x80114110,0x801138C8,0x8014EC7C,0x8014EDAC,0x801162E0):
            raw=bytearray(self.image);struct.pack_into('<I',raw,pc-self.base,0)
            with self.assertRaises(ValueError):soul.catalogue(source.Image(raw,self.base))
        for args in ((0,6),(180,0),(1025,6),(180,17),(180,1.5)):
            with self.assertRaises(ValueError):soul.hemisphere(*args)
        for speed in (0,-1,1025,1.5):
            with self.assertRaises(ValueError):soul.collapse_updates(soul.hemisphere(180,6),speed)


if __name__=='__main__':unittest.main()
