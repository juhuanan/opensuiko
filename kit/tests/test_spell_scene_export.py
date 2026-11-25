#!/usr/bin/env python3
"""Disc witnesses, reusable export reproducibility and independent player checks."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import disc
import battle_drops
import export_spell_scenes as exporter
from spell_scene_player import Player,geometry_vectors,beauty_vectors


class SpellScenes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.out=Path(cls.temp.name)/'native'
        cls.base_package=Path(cls.temp.name)/'base';cls.base_package.mkdir()
        for name in ('actors.png','floor.png','ground.png'):Image.new('RGBA',(1,1)).save(cls.base_package/name)
        (cls.base_package/'trial.json').write_text('{}\n')
        (cls.base_package/'provenance.json').write_text('{"test_fixture":true}\n')
        cls.packet=exporter.export(cls.base_package,cls.out)
        cls.atlas=Image.open(cls.out/cls.packet['atlas']).convert('RGBA')
        exe=disc.extract(17976,757760)
        cls.base,size=struct.unpack_from('<II',exe,24);cls.image=exe[2048:2048+size]

    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def test_warriors_scene_and_reaction_fixture_are_source_exported(self):
        packet, _, proof = exporter.build(include_warriors=True)
        scene = next(row for row in packet['unite_scenes'] if row['id'] == 'warriors')
        scene = exporter.compact_tracks(dict(spells=[], unite_scenes=[scene]))['unite_scenes'][0]
        reaction = next(row for row in packet['unite_reactions'] if row['record'] == 15 and row['variant'] == 1)
        expected = json.loads((ROOT/'game/tests/fixtures/unite_warriors_scene.json').read_text())
        self.assertEqual(dict(scene=scene, reaction=reaction), expected)
        self.assertEqual(proof['warriors_effect']['recipient']['script'], 15)

    def test_beauty_shared_player_obeys_raw_heart_animation_and_phase_boundaries(self):
        import battle_bin
        import battle_unite_camera
        raw,_=battle_unite_camera.field.source('/BATTLE.BIN')
        sections,_,errors,_=battle_bin.parse(need_atlases=False)
        self.assertFalse(errors)
        header=sections[7]['header_offset']
        table=struct.unpack_from('<I',raw,header+20)[0]-battle_bin.LOAD_BASE
        offset=struct.unpack_from('<I',raw,table+13*4)[0]-battle_bin.LOAD_BASE
        pairs=[tuple(raw[offset+4+2*i:offset+6+2*i]) for i in range(raw[offset])]
        self.assertEqual(pairs,[(20,7),(21,7),(22,7),(23,12),(22,7),(21,7)])
        program=self.packet['unite_scenes'][0]['program']
        self.assertEqual((program['impact'],program['duration']), (224,225))
        self.assertEqual([(c['at'],c['updates']) for c in program['cameras']],[(2,60)])
        coefficients=struct.unpack_from('<192h',self.image,0x8017242C-self.base)
        def root(value):
            if not value:return 0
            shift=(32-value.bit_length())&~1
            normalized=value<<(shift-24) if shift>=24 else value>>(24-shift)
            return (coefficients[normalized-64]<<((31-shift)//2))>>12
        def sine(angle):
            angle%=4096;sign=1
            if angle>2048:angle-=2048;sign=-1
            if angle>1024:angle=2048-angle
            return sign*struct.unpack_from('<h',self.image,0x801765BC+2*angle-self.base)[0]
        for seed in (0,17,32767):
            player=Player(self.packet,'beauty',self.atlas,seed=seed,unite=True)
            self.assertEqual(player.draw_count,150)
            tape=[];random_state=seed
            for _ in range(4096):
                random_state=(random_state*1103515245+12345)&0xffffffff
                tape.append((random_state>>16)&32767)
            def point(at):
                x=tape[at]%298-149;edge=root(22500-x*x)
                y=tape[at+1]%(2*edge)-edge
                return [x<<12,y<<12,-(tape[at+2]%(root(22500-x*x-y*y)+1))<<12]
            points=[point(5*i+2) for i in range(30)]
            baselines=[p[2] for p in points];phases=[tape[5*i+1]%64 for i in range(30)]
            self.assertEqual(player.draws,tape[:150])
            for actual,expected in zip(player.particles,points):self.assertEqual(actual['head'],expected)
            # Follow the raw F-record duration counters, independently of the
            # expanded animation track consumed by the player.
            clocks=[]
            for i in range(30):
                warm=player.draws[5*i]%32;frame=0
                while warm>=pairs[frame][1]:warm-=pairs[frame][1];frame+=1
                clocks.append([frame,pairs[frame][1]-warm,True])
            expected_draws=150
            for update in range(1,226):
                for i,clock in enumerate(clocks):
                    if update>=224:clock[2]=False;continue
                    if not clock[2] and update<=192:
                        clock[:]=[0,pairs[0][1],True]
                        points[i]=point(expected_draws);expected_draws+=3
                    if not clock[2]:continue
                    points[i][2]=baselines[i]+30*sine(phases[i]*32);phases[i]+=1
                    clock[1]-=1
                    if clock[1]==0:
                        clock[0]+=1
                        if clock[0]==len(pairs):
                            if update<=64:clock[0]=0
                            else:clock[2]=False;continue
                        clock[1]=pairs[clock[0]][1]
                player.advance(update)
                self.assertEqual(player.draw_count,expected_draws)
                for i,(particle,(frame,remaining,active)) in enumerate(zip(player.particles,clocks)):
                    self.assertEqual(particle['active'],active)
                    self.assertEqual(particle['head'],points[i])
                    self.assertEqual(particle['base_z'],baselines[i])
                    self.assertEqual(particle['phase'],phases[i])
                    if active:
                        age=sum(ticks for _,ticks in pairs[:frame])+pairs[frame][1]-remaining
                        self.assertEqual(particle['age'],age)
                self.assertEqual(program['screen_layers'][0]['samples'][update] is not None,update<224)

    def test_beauty_vfx_witnesses_are_reproducible_for_full_and_compact_tracks(self):
        expected=json.loads((ROOT/'game/tests/fixtures/unite_beauty_vfx_vectors.json').read_text())
        self.assertEqual(beauty_vectors(self.packet,self.atlas),expected)
        self.assertEqual(beauty_vectors(exporter.compact_tracks(self.packet),self.atlas),expected)

    def test_batch_preview_indexes_all_spells_without_promoting_diagnostics(self):
        import battle_spell_preview as preview
        original=json.dumps(self.packet,separators=(',',':'))
        for diagnostics,expected_rendered in ((False,33),(True,33)):
            with tempfile.TemporaryDirectory() as directory:
                output=Path(directory);rendered=[]
                def render(packet,native,spell,out,knockouts,metadata):
                    selected=next(s for s in packet['spells'] if s['id']==spell)
                    self.assertIsNotNone(selected['program'])
                    self.assertEqual(native,self.out)
                    self.assertFalse(knockouts)
                    rendered.append(spell);out.mkdir()
                    result=dict(status='diagnostic_not_qualified' if metadata else 'candidate',
                                scenario='VFX only; no damage formula simulation',files={f'{spell}_preview.mp4':'fixture'})
                    (out/'manifest.json').write_text(json.dumps(result)+'\n')
                    return result
                with patch.object(preview,'render_preview',side_effect=render):
                    report=preview.batch_reviews(self.packet,self.out,output,diagnostics=diagnostics)
                self.assertEqual(len(rendered),expected_rendered)
                self.assertEqual(len(set(rendered)),expected_rendered)
                self.assertEqual(report['canonical_programs'],33)
                self.assertEqual([r['id'] for r in report['spells']],[s['id'] for s in self.packet['spells']])
                self.assertEqual(len(report['spells']),33)
                self.assertEqual([r['id'] for r in report['spells'] if r['status']=='blocked'],[])
                for row in report['spells']:
                    if row['status']=='blocked':self.assertNotIn('manifest',row)
                    else:self.assertEqual(hashlib.sha256((output/row['manifest']).read_bytes()).hexdigest(),row['sha256'])
                self.assertEqual(report,json.loads((output/'index.json').read_text()))
                from html.parser import HTMLParser
                class Page(HTMLParser):
                    def __init__(self):super().__init__();self.cards=[];self.videos=[];self.controls=True
                    def handle_starttag(self,tag,attrs):
                        attrs=dict(attrs)
                        if tag=='article':self.cards.append(attrs['id'])
                        if tag=='video':
                            self.videos.append(attrs['src'])
                            self.controls&='controls' in attrs and 'autoplay' not in attrs
                page=Page();page.feed((output/'index.html').read_text())
                self.assertEqual(page.cards,[s['id'] for s in self.packet['spells']])
                self.assertEqual(page.videos,[f'{s}/{s}_preview.mp4' for s in rendered])
                self.assertTrue(page.controls)
                report['spells'][0]['name']='<script> & "quoted"'
                first=output/report['spells'][0]['manifest'];manifest=json.loads(first.read_text())
                manifest['files']={'preview.gif':'fixture'};first.write_text(json.dumps(manifest))
                preview.write_review_page(report,output)
                html=(output/'index.html').read_text()
                self.assertIn('&lt;script&gt; &amp; &quot;quoted&quot;',html)
                self.assertNotIn('<script>',html)
                self.assertIn('href="spell_1/preview.gif"',html)
        self.assertEqual(json.dumps(self.packet,separators=(',',':')),original)

    def test_airborne_exports_match_original_enemy_records(self):
        proof=json.loads((self.out/'provenance.json').read_text())
        for fact in proof['airborne_facts']:
            source=fact['source'];raw=disc.extract(source['lba'],source['size'])
            self.assertEqual(hashlib.sha256(raw).hexdigest(),source['sha256'])
            self.assertEqual(bool(struct.unpack_from('<H',raw,fact['offset'])[0]&32),fact['airborne'])
        # C/B fixtures include Roc: the flag must come from data, not species naming.
        for filename in ('world_b_battle.json','world_c_battle.json'):
            content=json.loads((ROOT/'game/assets'/filename).read_text())
            suffix='/'+filename.removeprefix('world_')[0].upper()+'_DATA.BIN'
            raw,_=exporter.actor_art.source(suffix)
            import battle_placement
            from war_text import decode
            records={decode(raw[slot['stats_offset']:],length=16)[0]:slot['stats_offset']
                     for encounter in battle_placement.area_encounters(raw)['encounters'] for slot in encounter['slots']}
            for enemy in content['enemies']:
                record=records[enemy['name']]
                self.assertEqual(enemy['airborne'],bool(struct.unpack_from('<H',raw,record+38)[0]&32),enemy['id'])

    def test_charm_arrow_erodes_disc_texture_with_native_rejections(self):
        import battle_bin
        sections,atlases,errors,_=battle_bin.parse();self.assertFalse(errors)
        raw=next(a['atlas'] for a in atlases if a['offset']==sections[2]['atlas_offsets'][8])
        self.assertEqual(len(raw),16384)
        p=self.packet['spells'][7]['program'];e=p['erosion']
        self.assertEqual((p['impact'],p['duration'],p['initial_draws']),(224,225,0))
        self.assertEqual((e['start'],e['stop'],e['budget']),(161,225,160))
        self.assertEqual((sum(e['levels']),sum(bool(b&15)+bool(b>>4) for b in raw)),(17060,16496))
        self.assertEqual([c['at'] for c in p['cameras']],[1,97])
        self.assertEqual((p['reaction']['start'],p['objects'][1]['anchor'],p['objects'][1]['screen_depth'],p['objects'][1]['blend']),(176,'screen',6,'opaque'))
        self.assertEqual([p['tracks'][0][u]['tint'][0] for u in (1,64,65,95)],[2,128,124,4])
        self.assertEqual([p['tracks'][1][u]['size'] for u in (96,97,160,223)],[1,65,4097,4097])
        for seed in (0,17):
            data=bytearray(raw);state=seed;draws=0;player=Player(self.packet,'spell_8',self.atlas,seed=seed)
            for update in range(1,226):
                if 161<=update<=224:
                    weight=sum(2 if value>=16 else bool(value) for value in data)
                    if weight<160:data[:]=bytes(16384)
                    else:
                        removed=0
                        while removed<160:
                            state=(1103515245*state+12345)&0xffffffff;draws+=1;cell=((state>>16)&32767)%16384
                            if not data[cell]:continue
                            data[cell]=data[cell]&15 if data[cell]>=16 else 0;removed+=1
                frame=player.frame(update,[120,50,0],[-128,0,0])
                self.assertEqual((player.draw_count,player.seed),(draws,state))
                self.assertEqual(player.coverage,[2 if value>=16 else int(value!=0) for value in data])
                expected=np.asarray([[bool(data[(64+y)*128+x//2] & (240 if x%2 else 15)) for x in range(64)] for y in range(64)])
                self.assertTrue(np.array_equal(player.textures[e['entry']][:,:,3]!=0,expected))
                glyph=[c for c in frame['commands'] if c.get('texture')==e['entry']]
                self.assertEqual(len(glyph),int(97<=update<224))
                if glyph:self.assertEqual(glyph[0]['depth'],6)
            self.assertEqual(sum(bool(b&15)+bool(b>>4) for b in data),6256)

    def test_charm_arrow_source_windows_fail_closed(self):
        import spell_scene_erosion as erosion,spell_scene_source as source
        from unittest.mock import patch
        image=source.Image();changed=bytearray(image.data);changed[0x801056a4-image.base]^=1
        with patch.object(source,'Image',return_value=source.Image(bytes(changed),image.base)):
            with self.assertRaisesRegex(ValueError,'source changed'):
                erosion.charm_program(dict(initializer='0x801050B4'),[],[],[],[],bytes(16384))

    def word(self,pc):return struct.unpack_from('<I',self.image,pc-self.base)[0]

    def test_deadly_fingertips_line_pool_matches_independent_rng_and_unobservable_fractions(self):
        program=self.packet['spells'][24]['program'];self.assertIsNotNone(program)
        self.assertEqual((program['impact'],program['duration'],program['initial_draws']),(306,367,0))
        self.assertEqual([c['at'] for c in program['cameras']],[1,97,306])
        self.assertEqual(program['meshes'][0]['segment_gap'],200)
        self.assertEqual(program['background_warps'][0]['anchor'],'target')
        table=struct.unpack_from('<192h',self.image,0x8017242C-self.base)
        def root(value):
            if not value:return 0
            exponent=(value.bit_length()-1)//2
            return table[value*64//(1<<(2*exponent))-64]*(1<<exponent)//4096
        for seed in (0,17):
            player=Player(self.packet,'spell_25',self.atlas,seed=seed)
            fractional=Player(self.packet,'spell_25',self.atlas,seed=seed)
            for i,p in enumerate(fractional.particles[:30]):
                p['head']=[(i*73+a*19+1)%4096 for a in range(3)];p['tail']=[(i*29+a*31+7)%4096 for a in range(3)]
            nodes=[dict(active=False,life=0,head=[0]*3,tail=[0]*3,velocity=[0]*3,scale=[4096]*3) for _ in range(30)]
            state=seed;used=0
            def draw():
                nonlocal state,used
                state=(1103515245*state+12345)&0xffffffff;used+=1;return (state>>16)&32767
            for u in range(368):
                if 97<=u<366:
                    if u<=305:
                        scale=1+64*min(u-96,80)-32*min(max(u-236,0),10)+64*min(max(u-246,0),60)
                        for node in nodes:
                            node['scale']=[scale,scale,4096]
                            if node['active']:continue
                            x=draw()%198-99;extent=root(10000-x*x);y=draw()%(2*extent)-extent
                            node['head']=[x*4096,y*4096,0];trail=10+draw()%50
                            node['tail']=[x*4096,y*4096,-trail*4096]
                            node['velocity']=[0,0,-(5+draw()%5)*4096];node['life']=draw()%70;node['active']=True
                    for node in nodes:
                        if node['life']==0 or node['head'][2]//4096<-300:node['active']=False
                        else:
                            node['life']-=1
                            for key in ('head','tail'):node[key]=[a+b for a,b in zip(node[key],node['velocity'])]
                frame=player.frame(u,[120,50,0],[-152,-28,45]);other=fractional.frame(u,[120,50,0],[-152,-28,45])
                self.assertEqual(frame,other,(seed,u,'constructor fractions'))
                self.assertEqual(player.draw_count,used,(seed,u))
                for expected,actual in zip(nodes,player.particles[:30]):
                    for key in ('active','life','head','tail','velocity'):self.assertEqual(expected[key],actual[key],(seed,u,key))
                    self.assertEqual(expected['scale'],actual['spawn_scale'])
                lines=[c for c in frame['commands'] if len(c['vertices'])==2]
                self.assertEqual(len(lines),sum(n['active'] for n in nodes) if 97<=u<366 else 0)
                for line in lines:self.assertEqual((line['colors'],line['blend']),([[64,96,144]]*2,'opaque'))

    def test_deadly_gapped_column_matches_original_fixed_rotation_equations(self):
        import battle_drops
        player=Player(self.packet,'spell_25',self.atlas)
        table=struct.unpack_from('<8192h',self.image,0x801725BC-self.base)
        def short(v):return (v+32768)%65536-32768
        target=[-152,-28,45]
        for u in (97,128,160,176,186,211,235):
            frame=player.frame(u,[120,50,0],target);block=frame['camera']
            scale=1+64*min(u-96,80);angle=32*(u-96);height=-300+5*max(u-176,0)
            def vertex(a,z):
                index=abs(a)&4095;sin=table[2*index]*(-1 if a<0 else 1);cos=table[2*index+1]
                world=[short(target[0]+(((cos*scale)>>12)*100>>12)),
                       short(target[1]+(((sin*scale)>>12)*100>>12)),short(target[2]+(scale*z>>12))]
                return battle_drops.projected(world,block)
            for i,command in enumerate(frame['commands'][:10]):
                a=angle-409*i;b=a-209
                points=[vertex(a,0),vertex(b,0),vertex(a,height),vertex(b,height)]
                self.assertEqual(command['vertices'],[p[:2] for p in points],(u,i))
                self.assertEqual(command['depth'],max(1,min(378,sum(p[2] for p in points)//16)),(u,i))
                self.assertEqual(command['colors'],[[80,80,16]]*2+[[0]*3]*2)
                self.assertEqual(command['blend'],'subtractive')

    def test_all_art_and_complete_programs_match_native_fixture(self):
        # This retained fixture predates Mosquito; the current five-enemy export has its own raw-pixel gate.
        legacy={key:value for key,value in exporter.ENEMY_IDS.items() if key!='mosquito'}
        with patch.dict(exporter.ENEMY_IDS,legacy,clear=True):
            native=exporter.export(self.base_package,Path(self.temp.name)/'with_c_targets',extra_hurt_ids=('kobold_type_1','kobold_type_2','kobold_type_3','strong_arm'))
        previous=json.loads((ROOT/'game/tests/fixtures/spell_scene_library.json').read_text())
        current=exporter.compact_tracks(native)
        self.assertEqual(len(current['entries']),len(previous['entries'])+6)
        self.assertEqual([clip['id'] for clip in current['unite_impacts']],[0,1,2,18,19,3])
        current['entries']=current['entries'][:len(previous['entries'])]
        current['unite_impacts']=current['unite_impacts'][:-1]
        warriors = [reaction for reaction in current['unite_reactions'] if reaction['record'] == 15]
        self.assertEqual([(reaction['record'], reaction['variant']) for reaction in warriors], [(15, 1)])
        current['unite_reactions'] = [reaction for reaction in current['unite_reactions'] if reaction['record'] != 15]
        current['schema']=previous['schema']
        self.assertEqual(current,previous)
        self.assertEqual(native['spells'],self.packet['spells'])
        self.assertEqual(len(self.packet['spells']),33)
        self.assertEqual([s['id'] for s in self.packet['spells'] if s['program']],[f'spell_{i}' for i in range(1,34)])
        for s in self.packet['spells']:
            if s['program'] is None:self.assertEqual(s['blocker'],'object_choreography_not_exported')
        # A separate effect atlas leaves scene actor bytes intact.
        self.assertEqual((self.out/'actors.png').read_bytes(),(self.base_package/'actors.png').read_bytes())
        for name,digest in json.loads((self.out/'manifest.json').read_text())['files'].items():
            self.assertEqual(hashlib.sha256((self.out/name).read_bytes()).hexdigest(),digest)
        proof=json.loads((self.out/'provenance.json').read_text())
        self.assertEqual(proof['producer'],'spell-scene-export/52')
        self.assertIn('spell_5',proof['positive_visual_review'])
        self.assertEqual(proof['approved_adaptations'][-1]['visual_acceptance'],'user_accepted_2026-11-12')
        self.assertEqual(proof['approved_adaptations'][0]['spells'],['spell_26','spell_27'])
        for native,filename in ((26,'shadow_scene_diagnostic.json'),(27,'hell_scene_diagnostic.json')):
            approved=json.loads((ROOT/'game/tests/fixtures'/filename).read_text())['packet']['spells'][0]['program']
            self.assertEqual(self.packet['spells'][native-1]['program'],approved)
        self.assertEqual(proof['custom_quad_contracts']['spell_5'],json.loads((ROOT/'kit/data/reports/spell_scolding_quads.json').read_text()))
        self.assertEqual(proof['custom_warp_contracts']['spell_22'],json.loads((ROOT/'kit/data/reports/spell_voice_earth_warp.json').read_text()))
        self.assertEqual(proof['soul_lifecycles'],json.loads((ROOT/'kit/data/reports/spell_soul_scenes.json').read_text()))
        self.assertEqual([s['id'] for s in proof['soul_lifecycles']['spells'] if s['runtime_ready']],['spell_25','spell_26','spell_27'])

        self.assertEqual(proof['texture_bindings']['schema'],'suikoden-spell-effect-sweep/2')
        sleep=next(row for row in proof['texture_bindings']['effects'] if row['name']=='Wind of Sleep')
        self.assertEqual((sleep['section'],sleep['auxiliary_sections']),(4,[3]))
        self.assertEqual(proof['scalar_compiler'],json.loads((ROOT/'kit/data/reports/spell_scalar_programs.json').read_text()))
        self.assertEqual(proof['object_compiler'],json.loads((ROOT/'kit/data/reports/spell_object_constructors.json').read_text()))
        self.assertEqual(proof['column_compiler'],json.loads((ROOT/'kit/data/reports/spell_column_constructors.json').read_text()))
        self.assertEqual(proof['column_motion'],json.loads((ROOT/'kit/data/reports/spell_column_motion.json').read_text()))

    def test_unite_impact_centers_use_header_centers_and_hurt_pose_palettes(self):
        proof=json.loads((self.out/'provenance.json').read_text())
        self.assertEqual(self.packet['schema'],'suikoden-spell-scenes/46')
        self.assertEqual(len(self.packet['unite_impacts']),6)
        self.assertEqual(len(self.packet['unite_reactions']),39)
        by_id={p['id']:p for p in self.packet['hurt_poses']}
        sources=[(f['id'],f['source'],f['offset']-38) for f in proof['airborne_facts']]
        for identifier,source,record in sources:
            raw=disc.extract(source['lba'],source['size']);base=0x80080000
            section=struct.unpack_from('<I',raw,record+44)[0]-base
            ft=struct.unpack_from('<I',raw,section+20)[0]-base
            et=struct.unpack_from('<I',raw,section+16)[0]-base
            frame=struct.unpack_from('<I',raw,ft+4)[0]-base
            pose=struct.unpack_from('<I',raw,et+4*raw[frame+4])[0]-base
            expected=[((raw[pose+6+i]-raw[pose+4+i]+128)%256)-128 for i in range(2)]
            self.assertEqual(by_id[identifier]['impact_offset'],expected)
        for source in proof['party_actor_sources']:
            pose=by_id[source['id']]
            normal=self.packet['entries'][pose['unite_entry']]
            white=self.packet['entries'][pose['unite_white_entry']]
            self.assertEqual([normal[k] for k in ('dx','dy','w','h')],[white[k] for k in ('dx','dy','w','h')])
            self.assertNotEqual(pose['entry'],pose['unite_entry'])

    def test_idle_flash_frames_match_source_animation_and_independent_pixels(self):
        from lzss import decode_strict
        proof=json.loads((self.out/'provenance.json').read_text())
        poses={p['id']:p for p in self.packet['hurt_poses']}
        palettes=[np.array(struct.unpack_from('<32H',self.image,0x8016B8A8-self.base+64*row),dtype=np.uint16) for row in (1,2,3)]
        for fact in proof['airborne_facts']:
            raw=disc.extract(fact['source']['lba'],fact['source']['size']);base=0x80080000
            pointer=lambda off:struct.unpack_from('<I',raw,off)[0]-base
            section=pointer(fact['offset']-38+44)
            ct,dt,et,ft=(pointer(section+i) for i in (8,12,16,20))
            normal_palettes=[np.frombuffer(raw[pointer(dt+4*i):pointer(dt+4*i)+64],dtype='<u2') for i in range(raw[section+5]&63)]
            planes=[]
            for i in range(raw[section+4]):
                blob=pointer(ct+4*i);length=struct.unpack_from('<I',raw,blob)[0]
                planes.append(np.frombuffer(decode_strict(raw[blob+4:blob+4+length]),dtype=np.uint8).reshape(128,128))
            animation=pointer(ft);flags=raw[animation+1]
            pairs=[tuple(raw[animation+4+2*i:animation+6+2*i]) for i in range(raw[animation])]
            idle=poses[fact['id']]['idle_flash']
            self.assertEqual((idle['advances'],idle['loop']),(bool(flags&1),bool(flags&2)))
            self.assertEqual([f['ticks'] for f in idle['frames']],[ticks for _,ticks in pairs])
            for (source_pose,_),frame in zip(pairs,idle['frames'],strict=True):
                off=pointer(et+4*source_pose);count,_,w,h,ax,ay=raw[off:off+6]
                pieces=list(struct.iter_unpack('8B',raw[off+8:off+8+8*count]))
                w=max([w]+[p[0]+p[4]+1 for p in pieces]);h=max([h]+[p[1]+p[5]+1 for p in pieces])
                for palette,entry_id in zip(palettes+[None],frame['entries']+[frame['normal']],strict=True):
                    canvas=np.zeros((h,w,4),dtype=np.uint8)
                    for x,y,page,tile,wm,hm,pal,flip in pieces:
                        u,v=(tile&15)*8,(tile>>4)*8
                        selected=normal_palettes[pal] if palette is None else palette
                        words=selected[planes[page][v:v+hm+1,u:u+wm+1]].astype(np.uint32)
                        rgba=np.stack([((words>>shift)&31)*255//31 for shift in (0,5,10)]+[(words!=0)*255],axis=-1).astype(np.uint8)
                        if flip&1:rgba=rgba[::-1]
                        if flip&2:rgba=rgba[:,::-1]
                        target=canvas[y:y+hm+1,x:x+wm+1];target[rgba[:,:,3]!=0]=rgba[rgba[:,:,3]!=0]
                    entry=self.packet['entries'][entry_id]
                    self.assertEqual((entry['dx'],entry['dy'],entry['w'],entry['h']),(-ax,-ay,w,h))
                    x,y=entry['x'],entry['y']
                    self.assertEqual(self.atlas.crop((x,y,x+w,y+h)).tobytes(),canvas.tobytes(),fact['id'])

    def test_geometry_vectors_are_reproducible(self):
        self.assertEqual(geometry_vectors(self.packet,self.atlas),json.loads((ROOT/'game/tests/fixtures/spell_scene_geometry.json').read_text()))
        compact=json.loads((self.out/'spells.json').read_text())
        self.assertEqual(geometry_vectors(compact,self.atlas),json.loads((ROOT/'game/tests/fixtures/spell_scene_geometry.json').read_text()))

    def test_compact_tracks_preserve_nondefault_samples_and_do_not_mutate(self):
        original=json.dumps(self.packet,separators=(',',':'))
        compact=exporter.compact_tracks(self.packet)
        self.assertEqual(json.dumps(self.packet,separators=(',',':')),original)
        self.assertEqual(exporter.compact_tracks(compact),compact)
        self.assertLess(len(json.dumps(compact,separators=(',',':'))),len(original))
        defaults=dict(piece=None,target_weight=[0,0,0],visible=True,position=[0,0,0],scale=[4096,4096,4096],angles=[0,0,0],node_angles=[0,0,1],size=4096,tint=[127,127,127])
        for before,after in zip(self.packet['spells'],compact['spells'],strict=True):
            if before['program'] is None:continue
            for a,b in zip(before['program']['tracks'],after['program']['tracks'],strict=True):
                for full,small in zip(a,b,strict=True):self.assertEqual(defaults|full,defaults|small)

    def test_generic_drops_preserves_reviewed_geometry_and_pixels(self):
        # Old separately written source scene is the regression oracle, not the new tracks.
        player=Player(self.packet,'spell_9',self.atlas)
        old=battle_drops.Scene(player.draws)
        def normalized(frame,textures):
            result=[]
            for c in frame['commands']:
                color=c.get('intensity',127)
                if isinstance(color,int):color=[color]*3
                result.append(json.dumps(dict(vertices=c['vertices'],colors=c.get('colors'),tint=color if c['kind']=='texture' else None,depth=c['depth'],pixels=hashlib.sha256(textures[c['texture']].tobytes()).hexdigest() if c['kind']=='texture' else None),sort_keys=True))
            return sorted(result)
        for n in (0,1,32,64,95,96,97,150,186,220,246,305,306):
            a=player.frame(n,(120,50,0),(112,0,0));b=old.frame(n,(120,50,0),(112,0,0))
            self.assertEqual(a['camera'],b['camera'])
            self.assertEqual(a['wash'],b['wash'])
            self.assertEqual(normalized(a,player.textures),normalized(b,old.textures),n)

    def test_flaming_source_phase_camera_damage_and_emitter_witnesses(self):
        witnesses={0x800FEE90:0x28420040,0x800FEF80:0x28420060,0x800FF0D8:0x2842004A,0x800FF158:0x2842003C,
                   0x800FEFF4:0x34050020,0x800FF174:0x0C0496CA,
                   0x80123B94:0x0C051F8E,0x80123BF0:0x0C053BF9,
                   0x80123BF8:0x0C051F8E,0x80123C48:0x0C053BF9,
                   0x8014F000:0x30480001,0x8014F048:0x85AD242C,
                   0x800F6BCC:0x2484B878,0x800F6BD4:0x3405001E,0x800F7598:0x2484B878,0x800F75A0:0x3405001E}
        for pc,expected in witnesses.items():self.assertEqual(self.word(pc),expected,hex(pc))
        p=self.packet['spells'][0]['program']
        self.assertEqual((p['impact'],p['duration']),(294,295))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(161,32)])
        self.assertEqual([o['start'] for o in p['objects'][1:16]],[161+(i+1)*64//15 for i in range(15)])
        self.assertEqual(p['objects'][-1]['start'],225)
        # Independent integer root table evaluation uses bit pairs, not bit_length normalization.
        raw=struct.unpack_from('<192h',self.image,0x8017242C-self.base)
        for n,r in enumerate(p['emitter']['roots']):
            if n==0:self.assertEqual(r,0);continue
            exp=0
            while 4**(exp+1)<=n:exp+=1
            mantissa=(n*64)//(4**exp)
            self.assertEqual(r,(raw[mantissa-64]*(2**exp))//4096)
        player=Player(self.packet,'spell_1',self.atlas)
        counts=[]
        for n in (64,65,160,161,225,294):
            f=player.frame(n,(120,50,0),(-120,40,0));counts.append((n,len(f['commands']),player.draw_count))
        self.assertEqual(counts,[(64,1,0),(65,21,80),(160,0,484),(161,0,484),(225,12,484),(294,0,484)])

    def test_firestorm_source_clock_flight_group_and_teardown(self):
        p=self.packet['spells'][1]['program']
        for pc,word in {0x800FF860:0x28420040,0x800FF890:0x28630020,
                        0x800FF954:0x28630040,0x800FFA30:0x28420040,
                        0x800FFC60:0x28420070,0x800FFD40:0x28420040,
                        0x800FFB04:0x14400005,0x800FFB14:0x24420001,
                        0x800FFB74:0x34020050,0x800FFBE4:0x10550017,
                        0x800FFC0C:0x0C043035,0x800FFC3C:0x0C038E08,
                        0x800FFCBC:0x0C0496CA}.items():self.assertEqual(self.word(pc),word,hex(pc))
        # A separate state-machine walk keeps the counter held until the falling
        # ball crosses ground, rather than reusing the exporter's event constants.
        phase=counter=0;flight=False;z=0;starts=[];hits=[];camera=[];bursts=[]
        for update in range(1,435):
            entered=phase
            if phase in (0,1,2,3,5):
                counter+=1
                if phase==3 and counter==11:flight=True;z=0
                if counter==[64,32,64,64,112,64][phase]:
                    phase+=1;counter=1 if phase==4 else 0;starts.append(update+1)
                    if phase==4:flight=True;z=-300*4096
            elif phase==4:
                if counter==48:camera.append(update)
                if not flight:counter+=1
                if counter==80:bursts.append(update)
                if counter==112:hits.append(update);phase=5;counter=0
            if entered==4 and flight:
                if z>0:flight=False
                else:z+=38400
        self.assertEqual(starts,[65,97,161,225,434])
        self.assertEqual((camera,bursts,hits),([306],[337],[369]))
        self.assertEqual((p['impact'],p['duration']),(hits[0],434))
        self.assertTrue(p['group']);self.assertFalse(p['center_after_reaction'])
        self.assertEqual([(e['at'],e['updates']) for e in p['cameras']],[(1,60),(161,90),(306,64)])
        arrows=[o for o in p['objects'] if o.get('start',0)>=277 and o['anchor']=='world']
        self.assertEqual(sorted(o['start'] for o in arrows),sorted([277+10*r for r in range(8)]*4))
        player=Player(self.packet,'spell_2',self.atlas)
        targets=[dict(position=[-128,40,0],center=[3,-9]),dict(position=[-144,-40,0],center=[-5,-13])]
        for update in (97,160,171,225,257,258,259,277,306,337,338,369,396,433,434):
            f=player.frame(update,(120,50,0),(-128,40,0),targets=targets)
            self.assertEqual(f['draw_count'],0)
            if update in (258,337):self.assertEqual(f['camera'][:3],[-163 if update==258 else -160,0,5])
            if update in (259,338):self.assertEqual(f['camera'][:3],[-160,0,0])
            if update>=433:self.assertEqual((len(f['commands']),f['wash']),(0,[0,0,0]))
        group=next(o for o in p['objects'] if o['anchor']=='each_target')
        self.assertEqual((group['start'],p['reaction']['start']),(337,337))
        one=Player(self.packet,'spell_2',self.atlas).frame(337,(120,50,0),(-128,40,0),targets=targets[:1])
        two=Player(self.packet,'spell_2',self.atlas).frame(337,(120,50,0),(-128,40,0),targets=targets)
        first=p['tracks'][group['track']][1]['piece']
        self.assertEqual(len(two['commands'])-len(one['commands']),len(self.packet['pieces'][first]))

    def test_knockout_source_busy_gate_script_and_color_callback(self):
        for pc,word in {0x800E0C8C:0x92020005,0x800E0C94:0x1440000E,
                        0x800E0C9C:0x0C038B6B,0x800E2E1C:0x8C46001C,
                        0x800E3FC0:0xA0A20005,0x800F10C4:0x34030080,
                        0x800F11CC:0x34050002,0x800F1230:0x2442FFFE,
                        0x800F123C:0xACA00000}.items():self.assertEqual(self.word(pc),word,hex(pc))
        self.assertEqual(struct.unpack_from('<I',self.image,0x8016BB70+12-self.base)[0],0x800F1018)
        self.assertEqual(self.packet['spells'][1]['program']['reaction']['release'],34)
        # Independent source opcode listing plus concurrent callback phases.
        from export_battle_trial import source
        from area_encounter_tables import chain,BASE
        from journey_battle import ENEMY_IDS
        from actor_script import OP_LEN_HW
        raw,_=source('/A_DATA.BIN');read=lambda a:struct.unpack_from('<I',raw,a-BASE)[0]
        _,_,directory,_=chain(raw);table=read(directory+12)
        for pose in self.packet['hurt_poses']:
            if pose['id'] not in ENEMY_IDS:continue
            record=read(table+4*ENEMY_IDS[pose['id']]);scripts=read(record+40)
            cursor=read(scripts+28);rows=[]
            for _ in range(20):
                op=struct.unpack_from('<H',raw,cursor-BASE)[0]
                if op==0:break
                size=OP_LEN_HW[op];args=struct.unpack_from('<'+'h'*(size-1),raw,cursor-BASE+2)
                rows.append((op,args));cursor+=size*2
            self.assertEqual(sum(args[0] for op,args in rows if op==3),92)
            self.assertEqual(sum(op==30 for op,args in rows),2)
            self.assertIn((35,(0,3)),rows);self.assertIn((4,(3,)),rows)
            self.assertEqual(pose['knockout']['duration'],94)
            elapsed=0;milestones=[]
            for op,args in rows:
                if op==30:elapsed+=1
                elif op==3:elapsed+=args[0]
                elif op==4:milestones.append(('pose',elapsed))
                elif op==8:milestones.append(('hide',elapsed))
                elif op==16 and args==(0,1):milestones.append(('release',elapsed))
            self.assertEqual(milestones,[('pose',1),('hide',92),('release',94)])
        player=Player(self.packet,'spell_2',self.atlas)
        for update,tint,blend in [(371,128,'opaque'),(372,128,'opaque'),(373,128,'subtractive'),(374,126,'subtractive'),(437,0,'subtractive')]:
            response=player.knockout(update,'bonbon')
            self.assertEqual((response['intensity'],response['blend']),(tint,blend))
            self.assertEqual(response['offset'],[0,5])
        self.assertTrue(player.knockout(462,'bonbon')['visible'])
        self.assertFalse(player.knockout(463,'bonbon')['visible'])
        self.assertIsNone(player.knockout(370,'bonbon'))

    def test_fog_source_phases_and_screen_strip_geometry(self):
        p=self.packet['spells'][9]['program']
        table=struct.unpack_from('<9I',self.image,0x800C1534-self.base)
        self.assertEqual(table,(0x80106360,0x801063E8,0x80106448,0x801064B0,0x80106520,0x80106598,0x801065CC,0x801066EC,0x8010674C))
        # Source timer writes and tests define nine boundaries, independently
        # accumulated here instead of copying producer visibility intervals.
        lengths=[self.word(0x801063D0)&65535,self.word(0x80106420)&65535,
                 self.word(0x8010649C)&65535,32,32,self.word(0x80106594)&65535,32,32,32]
        ends=np.cumsum(lengths).tolist()
        self.assertEqual(ends,[64,96,128,160,192,222,254,286,318])
        self.assertEqual((p['impact'],p['duration']),(ends[5]+1,ends[-1]+1))
        self.assertEqual([(e['at'],e['updates']) for e in p['cameras']],[(1,60),(97,60)])
        for pc,word in {0x80122D38:0x34050001,0x80122D3C:0x34060340,
                        0x80122D44:0x34070100,0x80122DAC:0x340300E0,
                        0x80122E60:0x0C052B4D,0x80122E68:0x2A820040,
                        0x80122E74:0x26F70A00,0x80122E78:0x2AE21404,
                        0x8010663C:0x34030005,0x80106640:0x00021080,
                        0x80106674:0xA6420036}.items():self.assertEqual(self.word(pc),word,hex(pc))
        # The separate quarter-wave sine table consumed by 80150810 agrees
        # with the rotation table used by the exporter, including quadrant fold.
        quarter=struct.unpack_from('<1025h',self.image,0x801765BC-self.base)
        def sine(angle):
            angle&=4095;sign=-1 if angle>2048 else 1;angle=angle if angle<=2048 else angle-2048
            return sign*quarter[angle if angle<=1024 else 2048-angle]
        for layer,(start,stop,period) in zip(p['screen_layers'],[(161,254,200),(129,286,300)]):
            self.assertEqual(layer['copies'],2)
            self.assertEqual([i for i,s in enumerate(layer['samples']) if s is not None],list(range(start,stop)))
            for update in (start,start+31,stop-1):
                sample=layer['samples'][update]
                amplitude=min(update-160,32)-min(max(update-222,0),32) if period==200 else 100
                phase=(update-start+1)%period
                for row,quad in enumerate(sample['vertices']):
                    wave=[(sine(((row*4+phase+d)*4096)//period)*amplitude)//4096 for d in (0,3)]
                    self.assertEqual(quad,[[wave[0]-amplitude*2,row*4],[wave[0]+320+amplitude*2,row*4],[wave[1]-amplitude*2,row*4+4],[wave[1]+320+amplitude*2,row*4+4]])
        player=Player(self.packet,'spell_10',self.atlas)
        for n,count in ((96,0),(128,0),(129,128),(160,128),(161,256),(222,256),(254,128),(286,0),(318,0),(319,0)):
            f=player.frame(n,(120,50,0),(-128,0,0));self.assertEqual(len(f['commands']),count,n)
            self.assertEqual(player.draw_count,0)
        self.assertEqual(player.camera(156)[:3],[-160,0,0])

    def test_fog_strip_texture_and_white_flash_match_independent_vram_samples(self):
        import battle_bin
        from psx_vram import PsxVram,texpage_encode,clut_encode,TP_4BIT
        sections,atlases,errors,_=battle_bin.parse();self.assertFalse(errors)
        pages={a['offset']:a['atlas'] for a in atlases};vram=PsxVram()
        vram.upload_rect(832,384,64,128,pages[sections[3]['atlas_offsets'][8]])
        # Reproduce the upload residency, then the helper's literal texture page
        # and descriptor-selected CLUT, without entry_image's nibble reader.
        bank=pages[sections[1]['atlas_offsets'][9]];slot=73
        colors=bank[128*(slot//2)+64+32*(slot%2):][:32]
        vram.upload_rect(944,420,16,1,colors)
        pixels=vram.sample_piece(texpage_encode(832,256,TP_4BIT),clut_encode(944,420),128,128,96,64,transparent_index=0)
        player=Player(self.packet,'spell_10',self.atlas)
        for y,entry in enumerate(player.program['screen_layers'][0]['entries']):self.assertTrue(np.array_equal(np.asarray([pixels[y]],dtype=np.uint8),player.textures[entry]))
        for pose in self.packet['hurt_poses']:
            normal=player.textures[pose['entry']];white=player.textures[pose['white_entry']]
            self.assertTrue(np.array_equal(normal[:,:,3],white[:,:,3]))
            self.assertTrue(np.all(white[:,:,:3][white[:,:,3]>0]==255))
            self.assertEqual(player.reaction(223,pose['id'])['entry'],pose['entry'])
            self.assertEqual(player.reaction(224,pose['id'])['entry'],pose['white_entry'])
            self.assertEqual(player.reaction(225,pose['id'])['entry'],pose['entry'])
            self.assertEqual(player.reaction(254,pose['id'])['entry'],pose['entry'])
            self.assertIsNone(player.reaction(255,pose['id']))

    def test_unready_spell_is_explicit_and_accepted_output_is_refused(self):
        blocked=dict(self.packet,spells=[dict(id='spell_5',name='Unavailable test fixture',program=None,blocker='missing_program')])
        with self.assertRaisesRegex(ValueError,'missing_program'):Player(blocked,'spell_5',self.atlas)
        with self.assertRaisesRegex(ValueError,'cannot promote'):exporter.export(self.out,ROOT/'kit/work/accepted/unsafe')

    def test_flaming_reaction_precedes_hp_commit_and_is_exported_from_actor_script(self):
        p=self.packet['spells'][0]['program']
        self.assertEqual(self.word(0x800FF074),0x0C038E08)
        self.assertEqual(self.word(0x800FF070),0x24C6F0D0)
        self.assertEqual(self.word(0x800FF05C),0x34020040)
        # The target script selects hurt animation1, then starts colour callback13.
        raw=struct.unpack_from('<15h',self.image,0x8016F0D0-self.base)
        self.assertEqual(raw,(15,0,1,4,1,42,3,0,1,4,30,0,35,0,13))
        self.assertEqual(self.word(0x800E0C64),0x0C038D63)
        self.assertEqual(self.word(0x800E0044),0x0C03826F)
        self.assertEqual(self.word(0x800DE1C8),0x0C03800D)
        self.assertEqual(self.word(0x800E4F48),0xA0A70078)
        self.assertEqual(self.word(0x800E4F50),0xA0A80079)
        reaction=p['reaction'];self.assertEqual(reaction['start'],225)
        self.assertLess(reaction['start'],p['impact'])
        offsets=reaction['offsets']
        self.assertEqual(offsets[:2],[[0,0]]*2)
        for step in range(6):self.assertEqual(offsets[2+step*5:7+step*5],([[-5,0]] if step%2==0 else [[0,5]])*5)
        self.assertEqual(offsets[32:],[[0,5]]*4)
        self.assertEqual({p['id']:p['center'] for p in self.packet['hurt_poses'] if 'center' in p},{'bonbon':[-2,-8],'wild_boar':[-11,-15],'crow':[3,-9],'red_soldier_ant':[-4,-11],'mosquito':[-1,-28]})
        player=Player(self.packet,'spell_1',self.atlas)
        self.assertIsNone(player.reaction(224,'bonbon'))
        for record in self.packet['hurt_poses']:
            en=self.packet['entries'][record['entry']]
            self.assertTrue(np.any(player.textures[record['entry']][:,:,3]))
            self.assertLessEqual(en['w'],256)
        self.assertEqual(player.reaction(228,'bonbon')['offset'],[-5,0])
        self.assertIsNotNone(player.reaction(228,'bonbon')['entry'])
        self.assertIsNone(player.reaction(261,'bonbon'))
        self.assertIsNone(Player(self.packet,'spell_9',self.atlas).reaction(225,'bonbon'))

    def test_flash_upload_cycle_and_independent_indexed_sprite_sampling(self):
        from psx_vram import PsxVram,texpage_encode,clut_encode,TP_8BIT
        from lzss import decode_strict
        from journey_battle import ENEMY_IDS
        import area_encounter_tables as area
        source=json.loads((self.out/'provenance.json').read_text())['actor_source']
        raw=disc.extract(source['lba'],source['size'])
        vram=PsxVram()
        bank=self.image[0x8016B8A8-self.base:0x8016B8A8-self.base+448]
        vram.upload_rect(288,496,32,7,bank)
        for pc,word in {0x800DEA4C:0x34020120,0x800DEA54:0x340201F0,
                        0x800DEA5C:0x34020020,0x800DEA64:0x34020007,
                        0x800DEA70:0x24A5B8A8,0x800DEA74:0x0C052164,
                        0x800F3B70:0x2442FFFF,0x800F3B84:0x26430003,
                        0x800F3BD8:0x24A501F0,0x800F3BFC:0xA462000E,
                        0x800E0928:0x24840FFF,0x800E0980:0x24630FFF,
                        0x800E37F4:0x0040F809}.items():self.assertEqual(self.word(pc),word,hex(pc))
        # This consumer interprets the updater's counter/row state, independently
        # of the exported timeline formula.
        program=self.packet['spells'][0]['program'];frames=program['reaction']['flash_frames']
        counter=4;row=1;expected=[None]
        for age in range(1,len(frames)):
            if age>=32:expected.append(None);continue
            counter-=1
            if counter<=0:counter=4;row=1+(row%3)
            expected.append(row-1)
        self.assertEqual(frames,expected)
        _,_,directory,_=area.chain(raw)
        read=lambda off:struct.unpack_from('<I',raw,off)[0]-area.BASE
        table=read(directory-area.BASE+12)
        player=Player(self.packet,'spell_1',self.atlas)
        for pose in self.packet['hurt_poses']:
            if pose['id'] not in ENEMY_IDS:continue
            record=read(table+4*ENEMY_IDS[pose['id']]);section=read(record+44)
            ct,et,ft=(read(section+n) for n in (8,16,20))
            f=read(ft+4);piece=raw[f+4];e=read(et+4*piece)
            self.assertEqual(raw[e],1)
            x,y,page,tile,wm,hm,palette,flip=raw[e+8:e+16]
            blob=read(ct+4*page);length=struct.unpack_from('<I',raw,blob)[0]
            indices=decode_strict(raw[blob+4:blob+4+length])
            vram.upload_rect(0,256,64,128,indices)
            for variant,entry_id in enumerate(pose['flash_entries']):
                pixels=vram.sample_piece(texpage_encode(0,256,TP_8BIT),clut_encode(288,497+variant),(tile&15)*8,(tile>>4)*8,wm+1,hm+1,transparent_index=0)
                if flip&2:pixels=[row[::-1] for row in pixels]
                if flip&1:pixels=pixels[::-1]
                image=Image.new('RGBA',(max(raw[e+2],x+wm+1),max(raw[e+3],y+hm+1)))
                image.paste(Image.fromarray(np.asarray(pixels,dtype=np.uint8)),(x,y))
                self.assertTrue(np.array_equal(np.asarray(image),player.textures[entry_id]),(pose['id'],variant))
            for variant,entry_id in enumerate(pose['shock_entries']):
                pixels=vram.sample_piece(texpage_encode(0,256,TP_8BIT),clut_encode(288,500+variant),(tile&15)*8,(tile>>4)*8,wm+1,hm+1,transparent_index=0)
                if flip&2:pixels=[row[::-1] for row in pixels]
                if flip&1:pixels=pixels[::-1]
                image=Image.new('RGBA',(max(raw[e+2],x+wm+1),max(raw[e+3],y+hm+1)))
                image.paste(Image.fromarray(np.asarray(pixels,dtype=np.uint8)),(x,y))
                self.assertTrue(np.array_equal(np.asarray(image),player.textures[entry_id]),(pose['id'],'shock',variant))
            # Independently sample the KO animation's page and normal palette;
            # these pixels do not come from section_art or the shared producer.
            f=read(ft+12);e=read(et+4*raw[f+4])
            self.assertEqual(raw[e],1)
            x,y,page,tile,wm,hm,palette,flip=raw[e+8:e+16]
            blob=read(ct+4*page);length=struct.unpack_from('<I',raw,blob)[0]
            vram.upload_rect(0,256,64,128,decode_strict(raw[blob+4:blob+4+length]))
            dt=read(section+12);clut=read(dt+4*palette);bank=raw[clut:clut+64]
            # Every used normal colour carries STP, as callback3's subtractive
            # pass requires; index zero stays transparent.
            self.assertTrue(all(w==0 or w&0x8000 for w in struct.unpack('<32H',bank)))
            vram.upload_rect(256,480,32,1,bank)
            pixels=vram.sample_piece(texpage_encode(0,256,TP_8BIT),clut_encode(256,480),(tile&15)*8,(tile>>4)*8,wm+1,hm+1,transparent_index=0)
            if flip&2:pixels=[row[::-1] for row in pixels]
            if flip&1:pixels=pixels[::-1]
            image=Image.new('RGBA',(max(raw[e+2],x+wm+1),max(raw[e+3],y+hm+1)))
            image.paste(Image.fromarray(np.asarray(pixels,dtype=np.uint8)),(x,y))
            self.assertTrue(np.array_equal(np.asarray(image),player.textures[pose['knockout']['entry']]),pose['id'])
        for n,index in ((225,None),(226,0),(228,0),(229,1),(232,1),(233,2),(236,2),(237,0),(256,1),(257,None)):
            pose=self.packet['hurt_poses'][0]
            self.assertEqual(player.reaction(n,pose['id'])['entry'],pose['entry'] if index is None else pose['flash_entries'][index])


    def test_healing_family_is_selected_from_helper_structure_and_preserves_both_source_variants(self):
        import spell_scene_source
        import spell_effect_sweep
        profiles={effect['name']:profile for effect in spell_effect_sweep.build()['effects'] if (profile:=spell_scene_source.healing_orbit_profile(effect)) is not None}
        self.assertEqual(set(profiles),{'Drops of Kindness','Water of Kindness','Rain of Kindness'})
        drops,water=(profiles[name] for name in ('Drops of Kindness','Water of Kindness'))
        for profile in (drops,water):self.assertEqual(profile['random_fields'],{'size':(4096,2048),'angle':(4096,0)})
        self.assertEqual((drops['count'],drops['per_party'],drops['height_range'],drops['rotation'],drops['rotate_when_visible']),(6,False,100,32,True))
        self.assertEqual((water['count'],water['per_party'],water['height_range'],water['rotation'],water['rotate_when_visible']),(4,True,200,64,False))
        for pc,word in {0x801069D0:0x00152100,0x801069FC:0x00021303,0x80106A08:0x24420800,0x80106A9C:0x00021303,0x80106A48:0x340300C8,0x801070C4:0x24420040,
                        0x80106CFC:0x28420040,0x80106D70:0x28630020,0x80106E28:0x2884005A,
                        0x80106E88:0x2442FFFF,0x80106F78:0x2484FFFF,0x80106ED8:0x0C038595}.items():self.assertEqual(self.word(pc),word)
        program=self.packet['spells'][10]['program']
        self.assertEqual((program['impact'],program['duration'],program['initial_draws_per_party']),(246,307,12))
        self.assertEqual([(event['at'],event['updates']) for event in program['cameras']],[(1,60),(65,60),(187,60)])
        self.assertEqual(program['meshes'][0]['origin'],[128,0,0])
        self.assertEqual(program['meshes'][0]['radius'],120)
        self.assertEqual(program['tracks'][1][97]['scale'],[45,45,4096])
        self.assertEqual(program['tracks'][1][97]['angles'],[0,0,97*64])
        for count in range(1,7):
            player=Player(self.packet,'spell_11',self.atlas,party=[dict(position=[128,0,0])]*count)
            frame=player.frame(97,[120,50,0],[128,0,0])
            self.assertEqual((player.draw_count,len(frame['commands'])),(count*12,64+count*4))
        with self.assertRaisesRegex(ValueError,'party bindings'):Player(self.packet,'spell_11',self.atlas)

    def test_support_idle_and_white_pixels_match_independent_descriptor_vram_sampling(self):
        import character_table
        from export_first_room import source
        from lzss import decode_strict
        from psx_vram import PsxVram,texpage_encode,clut_encode,TP_8BIT
        records=character_table.by_id()
        party=[dict(position=[128,0,0])]
        player=Player(self.packet,'spell_11',self.atlas,party=party)
        white=struct.unpack_from('<32H',self.image,0x8016B8A8-self.base)
        for native,identifier in ((8,'hero'),(2,'gremio'),(6,'pahn'),(35,'viktor'),(38,'yam_koo'),(32,'tai_ho'),(70,'maas')):
            raw,_=source('/'+records[native]['sprite_file'])
            read=lambda off:struct.unpack_from('<I',raw,off)[0]
            section=read(36);ct,dt,et,ft=(read(section+n) for n in (8,12,16,20))
            animation=read(ft);piece=raw[animation+4];e=read(et+4*piece)
            descriptors=[raw[e+8+8*i:e+16+8*i] for i in range(raw[e])]
            width=max([raw[e+2]]+[d[0]+d[4]+1 for d in descriptors]);height=max([raw[e+3]]+[d[1]+d[5]+1 for d in descriptors])
            pose=next(p for p in self.packet['hurt_poses'] if p['id']==identifier)
            for white_variant,key in ((False,'entry'),(True,'white_entry')):
                expected=Image.new('RGBA',(width,height));vram=PsxVram()
                for x,y,page,tile,wm,hm,palette,flip in descriptors:
                    blob=read(ct+4*page);length=read(blob)
                    vram.upload_rect(0,256,64,128,decode_strict(raw[blob+4:blob+4+length]))
                    colors=white if white_variant else struct.unpack_from('<32H',raw,read(dt+4*palette))
                    vram.upload_rect(288,496,32,1,struct.pack('<32H',*colors))
                    pixels=vram.sample_piece(texpage_encode(0,256,TP_8BIT),clut_encode(288,496),(tile&15)*8,(tile>>4)*8,wm+1,hm+1,transparent_index=0)
                    if flip&2:pixels=[row[::-1] for row in pixels]
                    if flip&1:pixels=pixels[::-1]
                    expected.alpha_composite(Image.fromarray(np.asarray(pixels,dtype=np.uint8)),(x,y))
                self.assertTrue(np.array_equal(np.asarray(expected),player.textures[pose[key]]),(identifier,key))
            self.assertEqual(player.reaction(246,identifier)['entry'],pose['entry'])
            self.assertEqual(player.reaction(248,identifier)['entry'],pose['white_entry'])
            self.assertEqual(player.reaction(248,identifier)['intensity'],[255,255,64])
            self.assertEqual(player.reaction(295,identifier)['entry'],pose['entry'])
            self.assertEqual(player.reaction(295,identifier)['intensity'],[128]*3)
            self.assertIsNotNone(player.reaction(306,identifier))
            self.assertIsNone(player.reaction(307,identifier))



    def test_rising_column_source_bounds_spawn_reuse_and_support_restarts(self):
        p=next(s['program'] for s in self.packet['spells'] if s['name']=='Clay Guardian')
        self.assertEqual((p['impact'],p['duration']),(177,337))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(65,30)])
        self.assertEqual([p['tracks'][1][u]['scale'] for u in (0,96,97,176,272,273,335)],[[0,0,4096],[0,0,4096],[51,51,4096],[4095,4095,4096],[4095,4095,4096],[4031,4031,4096],[63,63,4096]])
        for pc,word in {0x8011057C:0x2A82000A,0x80110868:0x28840050,0x80110958:0x28420060,0x80110AB8:0x3403003C,0x80110A78:0x2414CAAB,0x80110B2C:0x2842FF38,0x80110900:0x24630001,0x801108FC:0x34020022,0x80110948:0x0C038E08,0x80122EDC:0x0C051F8E,0x80122F58:0x0C051F8E,0x80122FB0:0x24840FFF,0x80123448:0xAC430034}.items():self.assertEqual(self.word(pc),word,hex(pc))
        player=Player(self.packet,'spell_21',self.atlas)
        supplied=iter([0,0,59]*200)
        player.next=lambda: next(supplied)
        player.advance(177)
        for particle in player.particles[:10]:
            self.assertTrue(particle['active']);self.assertEqual(particle['life'],58)
            self.assertEqual(particle['head'],[-29*4096,-7*4096,-13653])
        player.advance(235)
        self.assertTrue(player.particles[0]['active']);self.assertEqual(player.particles[0]['life'],0)
        fraction=player.particles[0]['head'][2]&4095
        player.advance(236);self.assertFalse(player.particles[0]['active'])
        player.advance(237)
        self.assertEqual(player.particles[0]['head'],[-28*4096,-6*4096,fraction-13653])
        ordinary=Player(self.packet,'spell_21',self.atlas)
        ordinary.advance(272);draws=ordinary.draw_count
        ordinary.advance(337);self.assertEqual(ordinary.draw_count,draws)
        for at in (177,210,244):
            self.assertEqual(ordinary.reaction(at,'gremio')['intensity'],[128]*3)
            self.assertEqual(ordinary.reaction(at+1,'gremio')['intensity'],[255,255,64])
        self.assertEqual(ordinary.reaction(293,'gremio')['intensity'],[128]*3)
        self.assertEqual(p['reaction']['release'],116)


    def test_scheduled_columns_preserve_delayed_zero_spawn_ring_growth_and_group_response(self):
        p=self.packet['spells'][32]['program']
        self.assertEqual((p['impact'],p['duration'],p['initial_draws']),(289,353,40))
        for pc,word in {0x801120B0:0x34160030,0x8011219C:0x2A820028,
                        0x8011227C:0x34050096,0x80112280:0x34060078,
                        0x80112288:0x2407FED4,0x801126D8:0xAE4000E0,
                        0x8011286C:0x2842FED4,0x80112990:0x24420040}.items():
            self.assertEqual(self.word(pc),word,hex(pc))
        self.assertEqual([p['tracks'][1][u]['scale'][0] for u in (96,97,160,288,289,351)], [0,64,4096,4096,4032,64])
        # Independently integrate the annuli's activation, radial clamp and height.
        for ring in range(5):
            enabled=False;x=z=1
            for update in range(161,353):
                if update<=288 and (update==161+16*ring or not enabled and update>161+16*ring):enabled=True;x=z=1
                if enabled and update<352:
                    limit=4096 if update<=288 else 4096-64*(update-288)
                    x=min(x+128,limit)
                    if x==limit:z+=64
                    if z>4096:enabled=False
                row=p['tracks'][3+ring][update]
                self.assertEqual((row['visible'],row['scale']),(enabled and update<352,[x,x,z]),(ring,update))
        for mesh in p['meshes'][1:]:
            self.assertEqual((mesh['top_radius'],mesh['radius']),(150,120))
            self.assertEqual(set(mesh['heights']+mesh['base_heights']),{-300})
        player=Player(self.packet,'spell_33',self.atlas)
        for particle in player.particles:particle['life']=0
        player.next=lambda: 0
        player.advance(287)
        self.assertTrue(all(p['pending'] for p in player.particles[:p['emitter']['count']]))
        player.advance(288)
        for particle in player.particles[:p['emitter']['count']]:
            self.assertFalse(particle['pending']);self.assertTrue(particle['active'])
            self.assertEqual(particle['head'],[-119*4096,-15*4096,-38400])
        player.advance(321)
        self.assertTrue(all(not p['active'] for p in player.particles))
        self.assertEqual(player.particles[0]['head'][2],-34*38400)
        normal=Player(self.packet,'spell_33',self.atlas)
        normal.advance(320);draws=normal.draw_count
        normal.advance(353);self.assertEqual(normal.draw_count,draws)
        for at in (161,193,225,257):
            self.assertEqual(normal.reaction(at,'gremio')['intensity'],[128]*3)
            self.assertEqual(normal.reaction(at+1,'gremio')['intensity'],[255,255,64])
        self.assertEqual(normal.reaction(306,'gremio')['intensity'],[128]*3)
        self.assertEqual(p['reaction']['release'],145)

    def test_banded_support_geometry_lifecycle_and_stagger_match_independent_source_equations(self):
        import battle_drops as math
        p=self.packet['spells'][22]['program']
        self.assertEqual((self.packet['schema'],p['impact'],p['duration']),('suikoden-spell-scenes/46',225,449))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(65,30),(161,60)])
        self.assertEqual([o['start'] for o in p['objects'][1:]],[225+5*i for i in range(16)])
        for pc,word in {0x80121F68:0x00431021,0x801222C4:0x00431023,
                        0x8012245C:0x00441021,0x801227A0:0x00441023,
                        0x8014F5EC:0x00021083,0x80111558:0x24420100,
                        0x80111580:0x24422000,0x80111220:0x0C038137}.items():self.assertEqual(self.word(pc),word,hex(pc))
        for update in range(449):
            count=[min(max(update-start,0),duration) for start,duration in ((0,64),(64,32),(96,64),(160,64),(224,96),(320,64),(384,64))]
            opening=(131072+63488*count[3]-65536*count[5])>>12;width=opening//5
            starts=[opening-(i+1)*width for i in range(4)]+[0]
            for i,mesh in enumerate(p['meshes'][1:]):
                self.assertEqual((mesh['opening'][update],mesh['spread'][update]),(starts[i],width if i<4 else starts[3]))
                self.assertEqual((mesh['start'],mesh['stop'],mesh['blend']),(97,384,'subtractive'))
            self.assertEqual(p['wash'][update],[count[0]-count[6]]*3)
        track=p['tracks'][p['objects'][1]['track']]
        self.assertEqual((track[1]['size'],track[1]['position'][2]),(257,-56*4096))
        self.assertEqual((track[16]['size'],track[16]['position'][2]),(4096,-54*4096))
        self.assertEqual((len(track),track[-1]['position'][2]),(44,0))
        player=Player(self.packet,'spell_23',self.atlas)
        frame=player.frame(161,(120,50,0),(112,0,0))
        self.assertEqual(len(frame['commands']),192)
        # Independent second-column matrix evaluation from the disc trig table.
        def trig(angle):
            sine,cosine=struct.unpack_from('<hh',self.image,0x801725BC-self.base+(abs(angle)&4095)*4)
            return (-sine if angle<0 else sine),cosine
        mesh=p['meshes'][1]
        def vertex(i,upper):
            sign=1 if i<16 else -1
            latitude=sign*(mesh['opening'][161]+(mesh['spread'][161] if upper else 0))
            sy,cy=trig(latitude);sz,cz=trig(-128*i)
            point=[112+((((-sz*cy)>>12)*60)>>12),(cz*60)>>12,((-((sz*-sy)>>12))*60)>>12]
            return math.projected(point,frame['camera'])
        for i in (0,1,15,16,17,31):
            j=(i+1)%32;command=frame['commands'][32+i]
            expected=[vertex(i,True),vertex(j,True),vertex(i,False),vertex(j,False)]
            self.assertEqual(command['vertices'],[v[:2] for v in expected])
            self.assertEqual(command['depth'],max(1,min(509,expected[2][2]//4)))
            self.assertEqual(command['blend'],'subtractive')
            self.assertEqual(command['colors'],[[0,80,208]]*4)

    def test_mother_ocean_uses_shared_bands_party_orbits_and_original_revive_timing(self):
        p=self.packet['spells'][29]['program']
        self.assertEqual((p['impact'],p['duration'],p['initial_draws_per_party']),(366,431,12))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(97,60),(187,60)])
        self.assertEqual((p['reaction']['start'],p['reaction']['release']),(247,49))
        self.assertEqual([o['member_index'] for o in p['objects'][1:]],[i//4 for i in range(24)])
        self.assertEqual([o['random_size']['draw'] for o in p['objects'][1:]],[3*i for i in range(24)])
        for u in range(431):
            counts=[min(max(u-start,0),duration) for start,duration in ((0,64),(64,32),(96,90),(186,60),(246,60),(306,60),(366,64))]
            opening=(4194304 if u>=246 else 131072+67720*counts[3])-69905*counts[5]
            width=(opening//5)>>12;starts=[(opening>>12)-(i+1)*width for i in range(4)]+[0]
            for i,m in enumerate(p['meshes'][1:]):
                self.assertEqual((m['start'],m['stop'],m['origin'],m['blend']),(97,366,[128,0,0],'additive'))
                self.assertEqual((m['opening'][u],m['spread'][u]),(starts[i],width if i<4 else starts[3]))
            expected=None
            if 307<=u<=366:expected=[((u-306)*(0xff000//60))>>12]*3
            elif 367<=u<=426:expected=[((426-u)*(0xff000//60))>>12]*3
            self.assertEqual(p['screen_washes'][0]['colors'][u],expected)
            orb=p['tracks'][2][u]
            self.assertEqual(orb['angles'][2],64*u)
            self.assertEqual(orb['piece'] is not None,247<=u<430)
        # Independent producer witnesses for white ramps, final heal, KO reset and idle script.
        for pc,word in {0x80108624:0x0C047499,0x8010874C:0x0C0474F5,
                        0x80108674:0x1C60005E,0x801086B8:0xA0400B85,0x801086C0:0x0C038595,
                        0x801086C8:0x0C04813B,0x801089A8:0x24630040}.items():self.assertEqual(self.word(pc),word,hex(pc))
        self.assertEqual(struct.unpack_from('<4h',self.image,0x8016F080-self.base),(4,0,5,0))

    def test_shared_screen_ramp_preserves_resets_and_rejects_unresolved_guards(self):
        import spell_scene_support as support,spell_effect_sweep
        effects={e['name']:e for e in spell_effect_sweep.build()['effects']}
        ramp=support.screen_flashes(effects['Angry Blow'])[0]['colors']
        level=0xff000;counter=0;expected=[None]*129
        for update in range(129,len(ramp)):
            color=None
            if update<=176 and counter<32:level-=0xff000//32;counter+=1;color=[(level>>12)&255]*3
            if update==145:level=0xff000;counter=0
            expected.append(color)
        self.assertEqual(ramp,expected)
        ramp=support.screen_flashes(effects['Rainstorm'])[0]['colors']
        level=0xff000;counter=0;expected=[None]*129
        for u in range(129,len(ramp)):
            color=None
            if u<=224:
                if counter<32:level-=0xff000//32;counter+=1;color=[(level>>12)&255]*3
                clock=u-129
                if clock<64 and counter==20:level=0xff000;counter=0
                if clock==64:level=0xff000;counter=0
                if clock==95:level=0xff000;counter=0
            expected.append(color)
        self.assertEqual(ramp,expected)
        # The nested helper field is bound explicitly; an unrelated offset stays unknown.
        from unittest.mock import patch
        import spell_scene_source as source
        raw=bytearray(self.image);struct.pack_into('<I',raw,0x8010D070-self.base,self.word(0x8010D070)+12)
        with patch.object(source,'Image',return_value=source.Image(raw,self.base)):
            with self.assertRaisesRegex(ValueError,'unresolved flash guard'):support.screen_flashes(effects['Rainstorm'])

    def test_rain_particles_agree_with_independent_source_integrator_and_splash_restart(self):
        p=self.packet['spells'][11]['program'];e=p['emitter']
        self.assertEqual((self.packet['schema'],p['impact'],p['duration']),('suikoden-spell-scenes/46',396,397))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(65,60),(187,60)])
        self.assertEqual((p['reaction']['start'],p['reaction']['release']),(277,49))
        self.assertEqual((e['start'],e['spawn_stop'],e['stop'],e['count']),(97,335,396,32))
        self.assertEqual([(m['start'],m['stop']) for m in p['meshes']],[(187,336)]*2)
        self.assertEqual(p['meshes'][1]['top_radius'],100)
        self.assertEqual(p['tracks'][e['splash_track']][1]['node_angles'],[-864,0,609])
        for pc,word in {0x80107388:0x2A420020,0x801073D0:0x2463FCA0,0x801073E8:0x24420260,
                        0x80107C60:0x1840000D,0x80107C70:0xAC62001C,0x80107C94:0xAD000060,
                        0x80123F90:0x24A50032,0x80123FE0:0x2463000A,
                        0x80107B30:0x0C038595,0x80107B38:0x0C04813B}.items():self.assertEqual(self.word(pc),word,hex(pc))
        table=struct.unpack_from('<192h',self.image,0x8017242C-self.base)
        def root(n):
            exponent=0
            while 4**(exponent+1)<=n:exponent+=1
            return (table[(n*64//4**exponent)-64]*(2**exponent))//4096
        state=17;draw_count=0
        def random():
            nonlocal state,draw_count
            state=(state*1103515245+12345)&0xffffffff;draw_count+=1
            return (state>>16)&32767
        party=[dict(position=[112,40,0]),dict(position=[128,-40,0])]
        player=Player(self.packet,'spell_12',self.atlas,party=party)
        for _ in range(24):random()
        particles=[dict(active=False,head=[0,0,0],tail=[0,0,0],speed=0,enabled=False,age=0,splash=[0,0,0]) for _ in range(32)]
        restarted_after_spawn=False
        for u in range(1,398):
            if 97<=u<396:
                if u<=335:
                    for particle in particles:
                        if particle['active']:continue
                        x=random()%238-119;extent=root(14400-x*x);y=random()%(2*extent)-extent
                        particle['head']=[x*4096,y*4096,-300*4096]
                        particle['tail']=[x*4096,y*4096,(-350-random()%100)*4096]
                        particle['speed']=(10+random()%5)*4096;random();particle['active']=True
                for particle in particles:
                    if particle['head'][2]//4096>0:
                        particle['splash']=particle['head'].copy()
                        if not particle['enabled']:
                            particle['age']=0
                            if u>365:restarted_after_spawn=True
                        particle['enabled']=True;particle['active']=False
                    if particle['active']:
                        particle['head'][2]+=particle['speed'];particle['tail'][2]+=particle['speed']
                    if particle['enabled']:
                        particle['age']+=1
                        if particle['age']==25:particle['enabled']=False
            player.advance(u)
            self.assertEqual((player.seed,player.draw_count),(state,draw_count),u)
            for actual,want in zip(player.particles,particles):
                self.assertEqual((actual['active'],actual['head'],actual['tail'],actual['splash_active'],actual['splash_age'],actual['splash_position']),
                                 (want['active'],want['head'],want['tail'],want['enabled'],want['age'],want['splash']),u)
        self.assertTrue(restarted_after_spawn)
        self.assertEqual(player.frame(397,(120,50,0),(112,0,0))['commands'],[])
        ramp=p['screen_washes'][0]['colors']
        self.assertEqual((ramp[276],ramp[277],ramp[336],ramp[337],ramp[396]),(None,[4]*3,[255]*3,[250]*3,[0]*3))

    def test_lightning_bolts_land_with_source_draw_order_spark_life_ring_and_focus_kicks(self):
        import math
        p=self.packet['spells'][16]['program'];e=p['emitter']
        self.assertEqual((p['impact'],p['duration'],e['spawn_at']),(240,305,[177,189]))
        self.assertEqual((p['reaction']['start'],p['reaction']['release']),(189,34))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(65,60)])
        for pc,word in {0x8010C24C:0x2A420006,0x8010C290:0x2A420002,0x8010C64C:0x3C160001,
                        0x8010C650:0x36D69000,0x8010C678:0x0C048BAD,0x8010C6E8:0x0C0496CA,
                        0x8010C914:0xAC620024,0x80120830:0x24420200,0x80120844:0x2442FF00,
                        0x8010C934:0xAC6212FC,0x8010C938:0xA4731324,0x800E1324:0x8C821294,
                        0x800E1328:0x8C8312F4,0x800E14C0:0x8C821294}.items():self.assertEqual(self.word(pc),word,hex(pc))
        state=17;draws=[];seeds=[state]
        for _ in range(6):state=(state*1103515245+12345)&0xffffffff;draws.append(state>>16&32767);seeds.append(state)
        positions=[]
        for j in (0,2):
            x=draws[j]%18-9;extent=math.isqrt(100-x*x);y=draws[j+1]%(2*extent)-extent
            positions.append([x*4096,y*4096])
        lifetimes=[48+draws[4]%32,48+draws[5]%32]
        player=Player(self.packet,'spell_17',self.atlas)
        for u in range(306):
            player.advance(u)
            count=0 if u<177 else 2 if u<189 else 5 if u<201 else 6
            self.assertEqual((player.draw_count,player.seed),(count,seeds[count]),u)
            for i,at in enumerate((177,189)):
                land=at+12;a=max(0,u-land+1);pulse_age=min(a,48);spark_age=min(a,lifetimes[i]-1)
                part=player.particles[i];self.assertEqual(part['active'],at<=u<land,u)
                expected_head=positions[i]+[min(0,(-300+25*max(0,u-at+1))*4096)] if u>=at else [0]*3
                self.assertEqual(part['head'],expected_head,u)
                self.assertEqual((part['age'],part['splash_age'],part['splash_active']),(min(max(0,u-at+1),12),spark_age,land<=u<land+lifetimes[i]-1),u)
                self.assertEqual((part['pulse_life'],part['pulse_size']),(48-pulse_age if a else 0,1+512*min(pulse_age,16)-256*max(pulse_age-16,0)),u)
            expected_focus=p['cameras'][-1]['target']['position'].copy()
            if u in (189,201):expected_focus[2]+=10
            if u>=125:self.assertEqual(player.camera(u)[:3],expected_focus,u)
        self.assertEqual(player.frame(305,(120,50,0),(-120,40,0))['commands'],[])
        # The two-update pre-flash wait and the electrical bank are source descriptor data.
        self.assertEqual(struct.unpack_from('<12h',self.image,0x8016F150-self.base),(15,0,1,4,1,3,2,42,3,0,4,4))
        frames=p['reaction']['flash_frames'];self.assertEqual(frames[:4],[None,None,None,4])
        self.assertEqual(set(v for v in frames if v is not None),{4,5,6})

    def test_shared_bolt_stagger_follows_a_changed_constructor_operand(self):
        from unittest.mock import patch
        import spell_scene_source as source,spell_effect_sweep
        effect=next(e for e in spell_effect_sweep.build()['effects'] if e['name']=='Angry Blow')
        self.assertEqual(self.word(0x8010C298),0x2610000C)
        raw=bytearray(self.image);struct.pack_into('<I',raw,0x8010C298-self.base,0x2610000B)
        image=source.Image(raw,self.base)
        base=self.packet['spells'][16]['program']['tracks'][0][1]['piece']
        pieces=list(range(base,base+len(effect['pieces'])))
        with patch.object(source,'Image',return_value=image):p=exporter.lightning_program(effect,pieces)
        self.assertEqual(p['emitter']['spawn_at'],[177,188])
        self.assertIsNotNone(p['focus_samples'][200]);self.assertIsNone(p['focus_samples'][201])

    def test_repeating_lightning_retains_target_slots_and_matches_full_source_lifecycles(self):
        p=self.packet['spells'][17]['program'];e=p['emitter']
        self.assertEqual((p['impact'],p['duration'],p['reaction']['start']),(345,409,289))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(65,60),(225,60)])
        self.assertEqual((e['repeat_until'],e['strike_at'],e['spark_life_min'],e['spark_life_range']),(224,289,56,0))
        self.assertEqual(e['spawn_at'],[129+5*i for i in range(12)])
        for o in p['objects'][6:]:self.assertEqual((o['anchor'],o['origin'],o['origin_until']),('world',[-128,0,0],289))
        for pc,word in {0x8010CD58:0x26100005,0x8010D02C:0x8C42B814,0x8010D034:0x8C63B818,
                        0x8010D108:0x14400016,0x8010D120:0x14400010,0x8010D130:0x1440000C,
                        0x8010D28C:0x14400019,0x8010D2CC:0xAE80002C,
                        0x8010D588:0x34020038,0x8010D5D0:0x34020030,
                        0x8010D3C8:0x0C0496CA}.items():self.assertEqual(self.word(pc),word,hex(pc))
        table=struct.unpack_from('<192h',self.image,0x8017242C-self.base)
        def root(n):
            if n==0:return 0
            exponent=0
            while 4**(exponent+1)<=n:exponent+=1
            return table[(64*n//4**exponent)-64]*(2**exponent)//4096
        self.assertEqual(e['roots'],[root(n) for n in range(22501)])
        targets=[dict(formation_slot=0,position=[-120,36,0],center=[3,-9]),dict(formation_slot=2,position=[-152,-28,45],center=[-11,-15])]
        state=17;seeds=[state];draws=[]
        for _ in range(30):state=(state*1103515245+12345)&0xffffffff;draws.append(state>>16&32767);seeds.append(state)
        def circle(index):
            x=draws[index]%298-149;extent=root(22500-x*x)
            return [x*4096,(draws[index+1]%(2*extent)-extent)*4096]
        initial=[circle(2*i) for i in range(12)];repeated=circle(24)
        player=Player(self.packet,'spell_18',self.atlas,targets=targets)
        for u in range(410):
            player.advance(u)
            count=2*sum(u>=129+5*i for i in range(12))+(2 if u>=197 else 0)+(4 if u>=289 else 0)
            self.assertEqual((player.draw_count,player.seed),(count,seeds[count]),u)
            for i,part in enumerate(player.particles[:12]):
                start=129+5*i;flights=[(start,initial[i])]+([(197,repeated)] if i==0 else [])
                landings=[at+12 for at,xy in flights]
                assigned=next((t for t in targets if t['formation_slot']==i),None)
                if assigned:landings.append(289)
                previous=[at for at in landings if at<=u]
                a=u-max(previous)+1 if previous else 0;age=min(a,48)
                spark_age=sum(min(max(u-at+1,0),55) for at in landings)
                primary_age=sum(min(max(u-at+1,0),12) for at,xy in flights)
                self.assertEqual((part['active'],part['age']), (any(at<=u<at+12 for at,xy in flights),primary_age), (u,i))
                latest=[(at,xy) for at,xy in flights if at<=u]
                head=latest[-1][1]+[min(0,(-300+25*(u-latest[-1][0]+1))*4096)] if latest else [0]*3
                if assigned and u>=289:head=assigned['position'][:2]+[0];head=[v*4096 for v in head]
                self.assertEqual(part['head'],head,(u,i))
                self.assertEqual((part['splash_active'],part['splash_age'],part['life']),(bool(previous and a<56),spark_age,max(0,56-a) if previous else 0),(u,i))
                self.assertEqual((part['pulse_life'],part['pulse_size']),(max(0,48-a) if previous else 0,1+512*min(age,16)-256*max(age-16,0)),(u,i))
                self.assertEqual(part['center'],assigned['center'] if assigned and u>=289 else [0,0],(u,i))
        self.assertEqual(player.draw_count,30)
        self.assertEqual(player.frame(409,(120,50,0),(-128,0,0))['commands'],[])
        for n in range(1,7):
            bindings=[dict(position=[-128,i*16,0],center=[i,0]) for i in range(n)]
            other=Player(self.packet,'spell_18',self.atlas,targets=bindings);other.advance(409)
            self.assertEqual(other.draw_count,26+2*n)
        for bindings in ([],[dict(formation_slot=6,position=[0]*3,center=[0]*2)],targets+[targets[0]]):
            other=Player(self.packet,'spell_18',self.atlas,targets=bindings)
            with self.assertRaisesRegex(ValueError,'target slots'):other.advance(1)
            self.assertEqual((other.elapsed,other.draw_count),(0,0))

    def test_repeating_bolt_schedule_follows_changed_source_stagger(self):
        from unittest.mock import patch
        import spell_scene_source as source,spell_effect_sweep
        effect=next(e for e in spell_effect_sweep.build()['effects'] if e['name']=='Rainstorm')
        raw=bytearray(self.image);struct.pack_into('<I',raw,0x8010CD58-self.base,0x26100006)
        image=source.Image(raw,self.base);base=self.packet['spells'][17]['program']['tracks'][0][1]['piece']
        with patch.object(source,'Image',return_value=image):p=exporter.lightning_program(effect,list(range(base,base+len(effect['pieces']))))
        self.assertEqual(p['emitter']['spawn_at'],[129+6*i for i in range(12)])
        self.assertIsNotNone(p['focus_samples'][207])
        self.assertIsNone(p['focus_samples'][196])

    def test_preview_commands_preserve_subtractive_mesh_and_texture_blending(self):
        from battle_drops_preview import Raster
        line=Raster();line.rgb[:]=[240,230,220]
        line.command(dict(kind='color',vertices=[[10,30],[20,30]],colors=[[16,48,64]]*2,blend='additive'),[])
        self.assertEqual(line.rgb[30,15].tolist(),[255,255,255])
        for vertices in ([[10,30],[20,30],[10,40]],[[10,30],[20,30],[10,40],[20,40]]):
            raster=Raster();raster.rgb[:]=[200,150,100]
            raster.command(dict(kind='color',vertices=vertices,colors=[[0,80,208]]*len(vertices),blend='subtractive'),[])
            self.assertEqual(raster.rgb[31,11].tolist(),[200,70,0])
            self.assertEqual(raster.rgb[31,9].tolist(),[200,150,100])
        raster=Raster();raster.rgb[:]=[200,150,100]
        texture=np.full((2,2,4),[32,16,128,255],dtype=np.uint8)
        raster.command(dict(kind='texture',texture=0,vertices=[[10,30],[20,30],[10,40],[20,40]],blend='subtractive'),[texture])
        self.assertEqual(raster.rgb[31,11].tolist(),[168,134,0])


    def test_sound_source_changes_update_parameters_or_refuse_changed_helpers(self):
        from unittest.mock import patch
        import spell_scene_source as source,spell_scene_sound as sound,spell_effect_sweep
        effect=next(e for e in spell_effect_sweep.build()['effects'] if e['name']=='Yell')
        image=source.Image();raw=bytearray(image.data)
        struct.pack_into('<I',raw,0x801042F4-image.base,0x34030032)
        with patch.object(source,'Image',return_value=source.Image(raw,image.base)):
            self.assertEqual(sound.profile(effect)['height'],50)
        raw=bytearray(image.data);struct.pack_into('<I',raw,0x801042E4-image.base,0)
        with patch.object(source,'Image',return_value=source.Image(raw,image.base)):
            with self.assertRaisesRegex(ValueError,'sound pulse source changed'):sound.profile(effect)
        raw=bytearray(image.data);struct.pack_into('<I',raw,0x80103AF0-image.base,0x34060300)
        with patch.object(source,'Image',return_value=source.Image(raw,image.base)):
            with self.assertRaisesRegex(ValueError,'sound split texture source changed'):sound.profile(effect)

    def test_sound_pulses_match_independent_aliased_counter_and_rng(self):
        table=struct.unpack_from('<192h',self.image,0x8017242C-self.base)
        def root(n):
            exponent=0
            while 4**(exponent+1)<=n:exponent+=1
            return table[n*64//4**exponent-64]*2**exponent//4096
        for spell,count,delay,phase_end,height,radius,expected in [('spell_6',5,10,240,60,25,11),('spell_7',20,2,236,100,100,54)]:
            player=Player(self.packet,spell,self.atlas);program=player.program
            self.assertEqual((program['impact'],program['duration']),(phase_end+128,phase_end+129))
            timers=[i*delay for i in range(count)];active=[False]*count;sizes=[4096]*count;positions=[[0]*3 for _ in timers]
            events=[];seed=17;draws=0
            def draw():
                nonlocal seed,draws
                seed=(seed*1103515245+12345)&0xffffffff;draws+=1;return (seed>>16)&32767
            for update in range(1,program['duration']):
                clock=update-176
                for index in range(count):
                    if 177<=update<phase_end and timers[index]==clock:
                        z=draw()%height;x=draw()%(2*radius-2)+1-radius
                        extent=root(radius*radius-x*x);y=draw()%(2*extent)-extent
                        positions[index]=[x*4096,y*4096,-z*4096];timers[index]=48;sizes[index]=1;active[index]=True;events.append(dict(at=update,index=index))
                    if active[index]:
                        sizes[index]=max(1,sizes[index]+(512 if timers[index]>32 else -256));timers[index]-=1
                        if timers[index]==0:active[index]=False;sizes[index]=1
                player.advance(update)
                for index,particle in enumerate(player.particles[:count]):
                    self.assertEqual(particle['pulse_life'],timers[index] if active[index] else 0,(spell,update,index))
                    if active[index]:self.assertEqual((particle['pulse_size'],particle['splash_position']),(sizes[index],positions[index]))
                self.assertEqual(player.draw_count,draws)
            self.assertEqual(program['emitter']['pulse_spawns'],events)
            self.assertEqual(len(events),expected)
            self.assertEqual(draws,3*expected)

    def test_sound_split_uvs_match_physical_upload_and_packet_copy(self):
        import battle_bin
        from spell_effect_entries import palette
        sections,atlases,errors,data=battle_bin.parse();self.assertFalse(errors)
        blobs={a['offset']:a['atlas'] for a in atlases};raw=blobs[sections[1]['atlas_offsets'][8]];bank=blobs[sections[1]['atlas_offsets'][9]]
        for spell,u0,slot,split,stop in [('spell_6',0,88,241,304),('spell_7',64,135,237,300)]:
            p=Player(self.packet,spell,self.atlas);layers=p.program['screen_layers'];colors=palette(bank,slot)
            self.assertEqual([v['blend'] for v in layers],['opaque','opaque'])
            for half,entry in enumerate(layers[1]['entries']):
                image=p.textures[entry]
                for y in range(57):
                    for x in range(32):
                        u=u0+31*half+x;byte=raw[y*128+u//2];color=(byte>>(4*(u&1)))&15
                        self.assertEqual(image[y,x].tolist(),list(colors[color]) + [255] if color else [0,0,0,0])
            original=layers[0]['samples'][split-1]['vertices'][0]
            for update in (split,split+1,stop):
                quads=layers[1]['samples'][update]['vertices']
                for half,q in enumerate(quads):
                    for left,right in ((0,1),(2,3)):
                        width=int((original[right][0]-original[left][0])/2)
                        shift=(6 if half else -6)*(update-split+1)
                        self.assertEqual(q[left],[original[left][0]+half*width+shift,original[left][1]])
                        self.assertEqual(q[right],[original[left][0]+(half+1)*width+shift,original[right][1]])
            self.assertIsNone(layers[1]['samples'][stop+1])


    def test_sleep_sphere_rng_gate_rotation_and_source_scale_lifetime(self):
        import json
        from PIL import Image
        from spell_scene_player import Player
        packet=self.packet;atlas=self.atlas
        # Independent SDK sqrt normalization and source LCG; no original code execution.
        table=struct.unpack_from('<192h',self.image,0x8017242C-self.base)
        def root(n):
            if not n:return 0
            shift=0
            while n<64:n*=4;shift-=1
            while n>=256:n//=4;shift+=1
            v=table[n-64];shift+=3
            return (v<<shift)>>12 if shift>=0 else v>>(12-shift)
        for seed in (17,1,3):
            state=seed;count=0
            def rand():
                nonlocal state,count
                count+=1;state=(1103515245*state+12345)&0xffffffff
                return (state>>16)&32767
            player=Player(packet,'spell_13',atlas,seed=seed);program=player.program
            self.assertEqual(program['emitter']['roots'],[root(i) for i in range(40001)])
            for i,obj in enumerate(program['objects'][1:]):
                size=rand()%4096+1365;angle=rand()%4096
                self.assertEqual(player.variation(obj['random_size']),size)
                self.assertEqual(player.variation(obj['random_node_angle']),angle)
                self.assertNotIn('random_angle',obj)
            expected=[dict(live=False,age=0,head=[0]*3) for _ in range(50)]
            x=y=z=1;velocity=0;zero_lives=0
            for u in range(418):
                if u==129:velocity=524288
                if 129<=u<=192:x+=131072;y+=131072;velocity-=8192;z+=velocity
                if 193<=u<=256:x+=131072;y+=131072;velocity+=8192;z-=velocity
                if u==256:z=1;velocity=0
                if 257<=u<=352:velocity+=8192;z+=velocity
                if 129<=u<352:
                    for part in expected:
                        if not part['live']:
                            a=rand()%398-199;extent=root(40000-a*a)
                            b=rand()%(2*extent)-extent;c=-(rand()%(root(40000-a*a-b*b)+1))
                            life=rand()%180;part['head']=[v*4096 for v in (a,b,c)];part['live']=life>0
                            zero_lives+=not life
                        if part['live']:part['age']+=1
                player.advance(u)
                self.assertEqual(player.draw_count,count,(seed,u))
                for actual,reference in zip(player.particles,expected):
                    self.assertEqual((actual['head'],actual['active'],actual['age']),(reference['head'],reference['live'],reference['age']),(seed,u))
                if u<417:
                    self.assertEqual(program['tracks'][1][u]['scale'],[x>>12,y>>12,z>>12],u)
                    self.assertEqual(program['tracks'][1][u]['angles'],[0,0,32*min(max(u-256,0),96)])
            if seed==3:self.assertGreater(zero_lives,0)
        self.assertEqual(self.word(0x801092CC),0x8E020024)
        self.assertEqual(self.word(0x801092D4),0x1C400003)
        self.assertEqual(self.word(0x801092A8),0xAE030024)

    def test_sleep_wave_uses_auxiliary_bank_and_script_waits_before_status(self):
        import json
        packet=self.packet;p=packet['spells'][12]['program']
        self.assertEqual((p['impact'],p['duration'],p['initial_draws']),(361,417,100))
        self.assertEqual((p['reaction']['start'],p['reaction']['release']),(193,168))
        self.assertEqual(p['reaction']['active_samples'],[True]*167+[False])
        # Raw descriptor operands independently establish3/164/1 waits and one home update.
        from actor_script import OP_LEN_HW
        pc=0x8016DE9C;waits=[];moves=[];status=[]
        for _ in range(32):
            op=struct.unpack_from('<h',self.image,pc-self.base)[0]
            if op==0:break
            args=struct.unpack_from('<'+'h'*(OP_LEN_HW[op]-1),self.image,pc+2-self.base)
            if op==3:waits.append(args[0])
            if op==22:moves.append(args[0])
            if op==40:status.append(args)
            pc+=2*OP_LEN_HW[op]
        self.assertEqual((waits,moves,status),([3,164,1],[1],[(5,30)]))
        self.assertEqual(193+sum(waits)+sum(moves)-1,p['impact'])
        self.assertEqual(self.word(0x800E4734),0x2402FFFF) # Start move continues into wait21.
        self.assertEqual(self.word(0x800E3684),0x87020010) # Integration follows the VM.
        layer=p['screen_layers'][0];self.assertEqual(layer['copies'],2)
        sine=struct.unpack_from('<1025h',self.image,0x801765BC-self.base)
        def lookup(a):
            a%=4096
            return sine[a] if a<=1024 else sine[2048-a] if a<=2048 else -sine[a-2048] if a<=3072 else -sine[4096-a]
        for u,sample in enumerate(layer['samples']):
            if not 129<=u<352:self.assertIsNone(sample);continue
            rise=min(u-128,64);fall=max(0,u-256)
            self.assertEqual(sample['rgb'],[max(0,(6144*rise-4096*fall)>>12)]+[max(0,(4096*rise-2730*fall)>>12)]*2)
            for row,quad in enumerate(sample['vertices']):
                a=lookup(((4*row+(u-128)%200)*4096)//200)*50>>12
                b=lookup(((4*row+(u-128)%200+3)*4096)//200)*50>>12
                self.assertEqual(quad,[[a-100,row*4],[a+420,row*4],[b-100,row*4+4],[b+420,row*4+4]])
        fog=packet['spells'][9]['program']['screen_layers'][0]
        from PIL import Image
        atlas=self.atlas
        def crop(e):return atlas.crop((e['x'],e['y'],e['x']+e['w'],e['y']+e['h'])).tobytes()
        self.assertEqual([crop(packet['entries'][i]) for i in layer['entries']],[crop(packet['entries'][i]) for i in fog['entries']])



    def test_dancing_groups_match_raw_loop_fields_and_every_animation_boundary(self):
        p=self.packet['spells'][2]['program'];self.assertEqual((p['impact'],p['duration'],p['initial_draws']),(493,494,30))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(97,80),(238,96),(338,92)])
        self.assertEqual(len(p['objects']),69)
        for address,expected in {0x80100698:0x28420040,0x80100790:0x2842004D,0x80100AB4:0x288400C0,
                                 0x80100B7C:0x28420040,0x801009D4:0x34030024,0x80100A78:0x34020064,
                                 0x80100AA0:0x34425555,0x80100C74:0xAE02003C,0x80100D50:0x24420080,
                                 0x80100750:0x24420080,0x80100DF4:0x34040525}.items():self.assertEqual(self.word(address),expected)
        by_track=lambda i:p['tracks'][p['objects'][i]['track']]
        for u in range(494):
            self.assertEqual(by_track(0)[u]['piece'] is not None,0<u<96)
            for i in range(4):
                a=by_track(1+i)[u]
                self.assertEqual(a['piece'] is not None,97<=u<160)
                if 97<=u<160:
                    self.assertEqual(a['position'],[30*4096,0,-38400*(u-96)])
                    self.assertEqual(a['angles'],[0,0,1024*i+128*(u-96)])
                    self.assertEqual(a['node_angles'],[0,0,2049])
            falling=by_track(5)[u]
            self.assertEqual(falling['piece'] is not None,161<=u<193)
            if 161<=u<193:self.assertEqual(falling['position'][2],-300*4096+(u-160)*38400)
            for i in range(4):
                burst=by_track(6+i)[u];flame=by_track(50+i)[u]
                self.assertEqual(burst['piece'] is not None,193<=u<252)
                self.assertEqual(flame['piece'] is not None,193<=u<493)
                self.assertEqual(flame['size'],min(4096,1+128*min(max(u-193,0),44)))
                self.assertEqual(flame['node_angles'],[0,16*min(max(u-429,0),64),1])
                self.assertEqual(flame['angles'],[0,0,1024*i+16*min(max(u-237,0),192)])
            scale=16777216 if u<160 else 1+87381*min(max(u-237,0),192)
            for i in range(40):
                group,index=divmod(i,10);start=238+6*index;last=start
                while last+48<=min(u,429):last+=48
                age=u-last+1;a=by_track(10+i)[u]
                self.assertEqual(a['piece'] is not None,u>=start and age<48,(u,i))
                self.assertEqual(a['scale'],[scale>>12]*3)
                if u>=start:self.assertEqual(a['angles'][2]+p['objects'][10+i]['random_angle']['bias'],group*1024+16*(last-237))
            color=[max(0,int(step*(min(u,64)-min(max(u-429,0),64))//4096)) for step in (2048,4096,4096)]
            self.assertEqual(p['wash'][u],color)
        self.assertEqual(p['focus_samples'][193],[-163,0,5]);self.assertIsNone(p['focus_samples'][194])
        reaction=p['reaction'];self.assertEqual((reaction['start'],reaction['release']),(238,214))
        self.assertEqual([reaction['offsets'][36*i] for i in range(6)],[[0,0]]*6)

    def test_dancing_cycling_sprites_match_independent_rng_prior_scale_and_fade_stop(self):
        p=self.packet['spells'][2]['program'];e=p['emitter'];seed=17;cursor=0
        def rand():
            nonlocal seed,cursor
            cursor+=1;seed=(1103515245*seed+12345)&0xffffffff
            return (seed>>16)&32767
        delays=[];sizes=[]
        for i in range(15):delays.append(rand()%16);sizes.append(rand()%2048+4096)
        player=Player(self.packet,'spell_3',self.atlas)
        nodes=[dict(active=False,pending=True,age=0,scale=4096,head=[0,0,0]) for i in range(15)]
        for i,obj in enumerate(p['objects'][-15:]):self.assertEqual(player.variation(obj['random_size']),sizes[i])
        roots=e['roots'] # The root-table consumer is independently checked by the fire-arrow test.
        for u in range(495):
            scale=(16777216 if u<160 else 1+87381*min(max(u-237,0),192))>>12
            if 238<=u<493:
                for i,node in enumerate(nodes):
                    if u<=429 and (node['pending'] and u-238==delays[i] or not node['pending'] and not node['active']):
                        x=rand()%298-149;extent=roots[22500-x*x];y=rand()%(2*extent)-extent
                        def div0(v):return (abs(v)//4096)*(-1 if v<0 else 1)
                        node.update(active=True,pending=False,age=0,head=[div0(x*node['scale'])<<12,div0(y*node['scale'])<<12,0])
                    if node['active']:
                        node['age']+=1;node['scale']=scale
                        if node['age']==55:node['active']=False
            player.advance(u);self.assertEqual(player.draw_count,cursor,u)
            for actual,expected in zip(player.particles,nodes):
                self.assertEqual((actual['active'],actual['pending'],actual['age'],actual['head']),(expected['active'],expected['pending'],expected['age'],expected['head']),u)
        self.assertEqual(cursor,150);self.assertTrue(all(not p['active'] for p in player.particles))
        from unittest.mock import patch
        import spell_scene_source as source,spell_scene_fire
        image=source.Image();raw=bytearray(image.data);struct.pack_into('<I',raw,0x80100944-image.base,0x24420011)
        effect=next(e for e in exporter.spell_effect_sweep.build()['effects'] if e['name']=='Dancing Flames')
        with patch.object(source,'Image',return_value=source.Image(raw,image.base)):
            with self.assertRaisesRegex(ValueError,'dancing fire source changed'):spell_scene_fire.dancing_program(effect,list(range(len(effect['pieces']))))


    def test_multiple_groups_keep_particle_storage_delays_and_draw_order_separate(self):
        import copy
        packet=copy.deepcopy(self.packet);packet['schema']='suikoden-spell-scenes/19'
        p=packet['spells'][2]['program'];first=p.pop('emitter');second=dict(first,particle_start=15)
        p['emitters']=[first,second]
        for obj in copy.deepcopy(p['objects'][-15:]):obj['particle_index']+=15;p['objects'].append(obj)
        player=Player(packet,'spell_3',self.atlas)
        player.next=lambda:0
        # Delay zero in both groups gives two independent, simultaneous batches.
        for node in player.particles[:30]:node['life']=0
        player.advance(238)
        for a,b in zip(player.particles[:15],player.particles[15:30]):
            self.assertEqual(a,b);self.assertTrue(a['active']);self.assertEqual(a['head'][0],-149*4096)
        player.advance(293)
        for a,b in zip(player.particles[:15],player.particles[15:30]):self.assertEqual(a,b);self.assertEqual(a['age'],1)
        first['spawn_stop']=238
        player.advance(348)
        self.assertTrue(all(not n['active'] for n in player.particles[:15]))
        self.assertTrue(all(n['active'] for n in player.particles[15:30]))
        self.assertEqual(player.emitter_for(0),first);self.assertEqual(player.emitter_for(29),second)


    def test_judgment_transforms_auxiliary_bank_columns_and_reaction_boundaries(self):
        p=self.packet['spells'][27]['program'];self.assertEqual((p['impact'],p['duration'],p['initial_draws']),(504,505,30))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(97,80),(444,60)])
        self.assertEqual(len(p['objects']),64)
        for address,word in {0x80116C54:0x2442FFF0,0x80116CE0:0x24421900,0x80116D00:0x2442FF80,
                             0x80116E84:0x24421FC0,0x80116EE0:0x2442FFFC,0x801173F0:0x34634000,
                             0x80117424:0x14400002,0x80117520:0x2631FFFF,0x801172A8:0x0C03D844,
                             0x801171CC:0x26310001}.items():self.assertEqual(self.word(address),word)
        # Nested animation9 comes from auxiliary Earth bank6, held at constructor frame0.
        trail=p['objects'][5];piece=p['tracks'][trail['track']][0]['piece']
        effects={e['name']:e for e in exporter.spell_effect_sweep.build()['effects']}
        names=exporter.item_tables.spell_names();auxiliary=effects[names[23]]
        base=sum(len(effects[name]['pieces']) for name in names[:23])
        local=int(auxiliary['animations'][9]['frames'][0]['piece'].removeprefix('piece_'))
        self.assertEqual(self.packet['pieces'][piece],self.packet['pieces'][base+local])
        self.assertEqual([(o['particle_index'],o['trail_index']) for o in p['objects'][5:45]],[(group,index) for group in range(4) for index in range(10)])
        for u in range(505):
            scale=1+64*(min(max(u-96,0),64)+min(max(u-384,0),60))
            for i,obj in enumerate(p['objects'][1:5]):
                sample=p['tracks'][obj['track']][u]
                self.assertEqual(sample['piece'] is not None,161<=u<444)
                if sample['piece'] is not None:
                    self.assertEqual(sample['scale'],[scale,scale,4096])
                    self.assertEqual(sample['angles'],[0,0,1024*i+16*min(u-160,64)])
                    self.assertEqual(sample['tint'],[(8128*min(u-160,64)>>12)&255]*3)
            for mesh in p['meshes'][:2]:
                self.assertTrue(mesh['animated_angles']);self.assertEqual((mesh['start'],mesh['stop']),(97,444))
                sample=p['tracks'][mesh['track']][u]
                self.assertEqual(sample['scale'],[scale]*3)
                self.assertEqual(sample['angles'],[0,0,-16*(min(max(u-96,0),128)+min(max(u-384,0),60))])
                self.assertEqual(mesh['base_heights'][u],-5-4*min(max(u-160,0),64))
            self.assertEqual(p['wash'][u],[4369*min(max(u-96,0),64)>>12]*3 if u<504 else [0]*3)
        self.assertEqual((p['reaction']['start'],p['reaction']['release'],len(p['reaction']['offsets'])),(303,121,122))
        self.assertEqual(p['screen_washes'][-1]['colors'][384],None)

    def test_judgment_complete_rng_trail_copy_order_and_first_births_before_repeats(self):
        p=self.packet['spells'][27]['program'];player=Player(self.packet,'spell_28',self.atlas);state=17;cursor=0
        def rand():
            nonlocal state,cursor
            cursor+=1;state=(1103515245*state+12345)&0xffffffff
            return (state>>16)&32767
        initial=[rand() for _ in range(30)]
        heads=[dict(pending=True,live=False,position=[0]*3,age=0,spark=False,spark_age=0,spark_position=[0]*3,history=[([0]*3,False) for _ in range(10)]) for _ in range(4)]
        motes=[dict(pending=True,live=False,position=[0]*3,age=0) for _ in range(11)]
        roots=p['emitters'][0]['roots'];mote_roots=p['emitters'][1]['roots'];landings=[];last_focus=0
        def circle(radius,table):
            x=rand()%(2*radius-2)+1-radius;t=table[radius*radius-x*x];y=rand()%(2*t)-t
            return [4096*x,4096*y,0]
        for u in range(506):
            if 289<=u<504:
                for i,node in enumerate(heads):
                    if u<=384 and (node['pending'] and u==289+6*i or not node['pending'] and not node['live']):
                        node.update(pending=False,live=True,position=circle(50,roots),age=0);node['position'][2]=-300*4096
                for i,node in enumerate(heads):
                    if node['live']:
                        node['position'][2]+=20*4096;node['age']+=1
                        if node['position'][2]>=0:
                            node['live']=False;last_focus=u
                            if i==0:landings.append(u)
                            node['spark_position']=node['position'].copy()
                            if not node['spark']:node['spark_age']=0
                            node['spark']=True
                    node['history'][0]=(node['position'].copy(),node['live'])
                    for j in range(9,0,-1):node['history'][j]=node['history'][j-1]
                    if node['spark']:
                        node['spark_age']+=1
                        if node['spark_age']==34:node['spark']=False
                def spawn(node):
                    height=rand()%100;node.update(pending=False,live=True,position=circle(70,mote_roots),age=0);node['position'][2]=-height*4096
                if u<=384:
                    for i,node in enumerate(motes):
                        if node['pending'] and u-289==initial[8+2*i]%48:spawn(node)
                    for node in motes:
                        if not node['pending'] and not node['live']:spawn(node);last_focus=u
                for node in motes:
                    if node['live']:
                        node['age']+=1
                        if node['age']==34:node['live']=False
            player.advance(u);self.assertEqual(player.draw_count,cursor,u);self.assertEqual(player.last_landing,last_focus,u)
            for actual,node in zip(player.particles[:4],heads):
                self.assertEqual((actual['head'],actual['active'],actual['pending'],actual['age']),(node['position'],node['live'],node['pending'],node['age']),u)
                self.assertEqual([(p['position'],p['visible']) for p in actual['history']],node['history'],u)
                self.assertEqual((actual['splash_age'],actual['splash_active'],actual['splash_position']),(node['spark_age'],node['spark'],node['spark_position']),u)
            for actual,node in zip(player.particles[4:15],motes):self.assertEqual((actual['head'],actual['active'],actual['pending'],actual['age']),(node['position'],node['live'],node['pending'],node['age']),u)
        self.assertEqual(landings,list(range(303,394,15)))
        self.assertEqual(cursor,30+50+3*sum(1+(95-initial[2*i]%48)//34 for i in range(4,15)))
        from unittest.mock import patch
        import spell_scene_judgment as compiler,spell_scene_source as source
        raw=bytearray(self.image);struct.pack_into('<I',raw,0x801173F0-self.base,0x34633000)
        effects=exporter.spell_effect_sweep.build()['effects'];effect=next(e for e in effects if e['name']=='Judgment');aux=next(e for e in effects if e['section']==6)
        with patch.object(source,'Image',return_value=source.Image(raw,self.base)):
            with self.assertRaisesRegex(ValueError,'Judgment source changed'):compiler.program(effect,list(range(len(effect['pieces']))),aux,list(range(len(aux['pieces']))))


    def test_shining_wind_source_operands_transforms_and_split_reactions(self):
        p=self.packet['spells'][30]['program']
        self.assertEqual((self.packet['schema'],p['impact'],p['duration'],p['initial_draws']),('suikoden-spell-scenes/46',384,385,120))
        self.assertEqual(len(p['objects']),91)
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(64,60)])
        for pc,word in {0x8010B144:0x2A220014,0x8010B180:0x2A220014,0x8010B208:0x2A22001E,0x8010B290:0x2A220014,
                        0x8010B4C0:0x24420800,0x8010B524:0x2442FE70,0x8010B5C8:0x00431021,
                        0x8010B620:0x0043001A,0x8010B768:0x0C048BAD,0x8010BA44:0xAE020024,
                        0x8010BBAC:0xAC820024,0x8010BBCC:0xA4820044,0x8010BBDC:0xA462001C,
                        0x8010BCF0:0x24421E00,0x8010BD1C:0x24421E00,0x8010BD5C:0xAE030024,
                        0x8010B8A8:0x2405FE0C,0x8010B904:0x340201F4}.items():self.assertEqual(self.word(pc),word)
        for u in range(385):
            expected=(1+262144*(min(max(u-96,0),64)-min(max(u-320,0),64)))>>12
            self.assertEqual(p['tracks'][5][u]['scale'],[expected,expected,4096])
            self.assertEqual(p['wash'][u],[max(0,2048*(min(u,64)-min(max(u-256,0),64))>>12)]*3)
        for age,row in enumerate(p['tracks'][1]):
            self.assertEqual(row['angles'],[0,0,96*age]);self.assertEqual(row['node_angles'],[0,0,1+64*age])
            self.assertEqual(row['piece'],p['tracks'][1][0]['piece'])
        player=Player(self.packet,'spell_31',self.atlas)
        for at in (161,197,233,269,305):
            self.assertEqual(player.reaction(at,'bonbon')['offset'],[0,0])
            self.assertEqual(player.reaction(at+1,'gremio',party=True)['intensity'],[255,255,64])
        self.assertIsNone(player.reaction(337,'bonbon'));self.assertIsNone(player.reaction(354,'gremio',party=True))
        roots=p['emitters'][2]['roots'];raw=struct.unpack_from('<192h',self.image,0x8017242C-self.base)
        for n,r in enumerate(roots):
            if n==0:self.assertEqual(r,0);continue
            exponent=0
            while 4**(exponent+1)<=n:exponent+=1
            self.assertEqual(r,(raw[(n*64)//(4**exponent)-64]*(2**exponent))//4096)

    def test_shining_wind_full_lifetime_rng_order_pulse_alias_and_positive_height_gate(self):
        p=self.packet['spells'][30]['program'];all_events=[]
        for seed in (0,17):
            player=Player(self.packet,'spell_31',self.atlas,seed=seed);state=seed;draws=0
            def draw():
                nonlocal state,draws
                state=(1103515245*state+12345)&0xffffffff;draws+=1;return (state>>16)&32767
            initial=[draw() for _ in range(120)];self.assertEqual(player.draws,initial)
            def xy(radius,old):
                x=draw()%(2*radius-2)+1-radius;extent=p['emitters'][0 if radius==50 else 2]['roots'][radius*radius-x*x]
                return [(x*4096)|(old[0]&4095),((draw()%(2*extent)-extent)*4096)|(old[1]&4095),old[2]&4095]
            orbits=[dict(active=False,age=0,head=[0]*3) for _ in range(20)]
            pulses=[dict(active=False,counter=2*i,size=1,head=[0]*3,born=False) for i in range(20)]
            motes=[dict(active=False,age=0,head=[0]*3,velocity=[0]*3,life=0) for _ in range(50)]
            events=[]
            for u in range(1,386):
                if 161<=u<320:
                    for i,node in enumerate(orbits):
                        if u==161+2*i:
                            height=draw()%200;node.update(active=True,age=0,head=xy(50,node['head']));node['head'][2]=(-height*4096)|(node['head'][2]&4095)
                    for node in orbits:
                        if node['active']:
                            node['age']+=1
                            if node['age']>=120:node['active']=False
                if 161<=u<384:
                    if u<320:
                        births=[i for i,node in enumerate(pulses) if node['counter']==u-160]
                        for i in births:pulses[i].update(active=True,counter=48,size=1,born=True)
                        idle=[i for i,node in enumerate(pulses) if not node['active'] and node['counter']==0]
                        for i in idle:pulses[i].update(active=True,counter=48,size=1,born=True)
                        for i in births+idle:
                            height=draw()%200;pulses[i]['head']=xy(50,pulses[i]['head']);pulses[i]['head'][2]=-height*4096;events.append(dict(at=u,index=i))
                    for node in pulses:
                        if node['active']:
                            node['size']=node['size']+512 if node['counter']>32 else max(1,node['size']-256)
                            node['counter']-=1
                            if node['counter']==0:node.update(active=False,size=1)
                if 97<=u<384:
                    if u<320:
                        for node in motes:
                            if node['active']:continue
                            height=160+draw()%80;node.update(active=True,age=0,head=xy(300,node['head']));node['head'][2]=(-height*4096)|(node['head'][2]&4095)
                            node['velocity']=[7680+draw()%1024,0,7680+draw()%1024];node['life']=draw()%180
                    for node in motes:
                        if not node['active']:continue
                        if node['life']==0 or node['head'][2]>>12>0:node['active']=False;continue
                        node['head']=[a+b for a,b in zip(node['head'],node['velocity'])];node['age']+=1
                player.advance(u);self.assertEqual(player.draw_count,draws,(seed,u))
                for index,node in enumerate(orbits):
                    actual=player.particles[index]
                    for key in ('active','age','head'):self.assertEqual(actual[key],node[key],(seed,u,index,key))
                for index,node in enumerate(pulses,20):
                    actual=player.particles[index]
                    self.assertEqual(actual['pulse_life'],node['counter'] if node['born'] else 0,(seed,u,index))
                    self.assertEqual(actual['pulse_size'],node['size'],(seed,u,index))
                    self.assertEqual(actual['splash_position'],node['head'],(seed,u,index))
                for index,node in enumerate(motes,40):
                    actual=player.particles[index]
                    for key in ('active','age','head','velocity','life'):self.assertEqual(actual[key],node[key],(seed,u,index,key))
            self.assertEqual(events,p['emitters'][1]['pulse_spawns']);all_events.append((seed,draws))
        self.assertGreater(all_events[0][1],120)


    def test_shining_wind_rejects_changed_source_before_publishing_a_scene(self):
        import spell_scene_source as source
        import spell_scene_wind as wind
        from unittest.mock import patch
        effect=next(e for e in exporter.spell_effect_sweep.build()['effects'] if e['name']=='Shining Wind')
        image=source.Image();changed=bytearray(image.data)
        struct.pack_into('<I',changed,0x8010BD1C-image.base,self.word(0x8010BD1C)+1)
        with patch.object(source,'Image',return_value=source.Image(changed,image.base)):
            with self.assertRaisesRegex(ValueError,'Shining Wind source changed'):
                wind.shining_program(effect,list(range(len(effect['pieces']))))


    def test_explosion_source_geometry_scale_boundaries_and_reaction(self):
        p=self.packet['spells'][3]['program']
        self.assertEqual((self.packet['schema'],p['impact'],p['duration'],p['initial_draws']),('suikoden-spell-scenes/46',448,449,70))
        self.assertEqual(len(p['objects']),36);self.assertEqual(len(p['meshes']),7)
        self.assertEqual([(e['at'],e['updates']) for e in p['cameras']],[(1,60),(65,60),(129,90)])
        for pc,word in {0x80101258:0x34040006,0x8010125C:0x34050096,0x80101260:0x34060024,
                        0x8010127C:0x34030048,0x80101344:0x34030060,0x80101444:0x3442AAAA,
                        0x80101624:0xAE230118,0x80101690:0x34020020,0x8010169C:0x34020044,
                        0x80101730:0x0C048BAD,0x801017B0:0x24421000,0x80101804:0x3403003C,
                        0x8010194C:0x34030050,0x80101994:0x2442FFD8,0x801019E0:0xAE22011C,
                        0x80101AB0:0x340202BC,0x80124A58:0x34020400,0x80124AD8:0,
                        0x801245FC:0x00001012,0x80124604:0x2442FFFF,0x80124720:0x24420001}.items():self.assertEqual(self.word(pc),word)
        # Independently sample the immutable SDK quarter-wave table, then lower negative-radius columns.
        table=struct.unpack_from('<1025h',self.image,0x801765BC-self.base)
        def sine(angle):
            angle%=4096
            if angle<=1024:return table[angle]
            if angle<=2048:return table[2048-angle]
            if angle<=3072:return -table[angle-2048]
            return -table[4096-angle]
        previous=(0,-150)
        for i,m in enumerate(p['meshes'][:6]):
            angle=1024*(i+1)//6
            radius=-(150*sine(angle)//4096);height=-(150*sine(angle+1024)//4096)
            self.assertEqual((m['radius'],m['top_radius'],m['base_heights'][0],m['heights'][0]),(-previous[0],-radius,previous[1],height))
            self.assertEqual((m['angles'],m['segments'],m['inner'],m['outer']),([0,0,2048],36,[2*(i+1)-1,16*(i+1)-1,16*(i+1)-1],[2*i,16*i,16*i]))
            previous=(radius,height)
        player=Player(self.packet,'spell_4',self.atlas)
        for u in range(449):
            self.assertEqual(p['tracks'][1][u]['scale'],[min(16777216,4096+174762*min(max(u-96,0),128))//4096+32*min(max(u-320,0),64)]*3)
        for u in (257,293):self.assertIsNotNone(player.reaction(u,'bonbon'))
        self.assertEqual(p['reaction']['release'],36+exporter.reaction_track()['release'])
        self.assertIn('explosion_fractional_scale',json.loads((self.out/'provenance.json').read_text())['visual_limits'])

    def test_explosion_complete_source_rng_spawn_order_fractional_motion_and_scale_noise(self):
        p=self.packet['spells'][3]['program']
        for seed in (0,17):
            player=Player(self.packet,'spell_4',self.atlas,seed=seed);state=seed;draws=0;noise=0
            def draw():
                nonlocal state,draws
                state=(1103515245*state+12345)&0xffffffff;draws+=1;return (state>>16)&32767
            initial=[draw() for _ in range(70)]
            # Native source arrays are visited small flames, large bursts, then common inward lines.
            flames=[dict(pending=True,active=False,age=0,delay=initial[40+2*i]%96,head=[0]*3,scale=4096,size=0) for i in range(15)]
            bursts=[dict(pending=True,active=False,age=0,delay=initial[2*i]%72,head=[0]*3,scale=4096,size=0) for i in range(20)]
            lines=[dict(active=False,life=0,head=[0]*3,tail=[0]*3,velocity=[0]*3) for _ in range(30)]
            def div0(n,d):return n//d if n>=0 else -((-n)//d)
            def birth(node,height):
                roots=p['emitters'][0]['roots'];x=draw()%158-79;r=roots[6400-x*x];y=draw()%(2*r)-r
                node['head']=[(div0(v*node['scale'],4096)<<12)|(node['head'][i]&4095) for i,v in enumerate((x,y,-height))]
                node.update(pending=False,active=True,age=0)
            for u in range(1,450):
                focus=False
                if 225<=u<=320:
                    for node in flames:
                        if node['pending'] and node['delay']==u-225:birth(node,0)
                    for node in flames:
                        if not node['pending'] and not node['active']:birth(node,0);node['size']=4096+draw()%4096
                    for node in bursts:
                        if node['pending'] and node['delay']==u-225:birth(node,draw()%60);focus=True
                    for node in bursts:
                        if not node['pending'] and not node['active']:birth(node,draw()%60);focus=True
                    noise+=draw()%80-40
                effective=p['tracks'][1][min(u,448)]['scale'][0]+noise
                for nodes,life in ((flames,55),(bursts,60)):
                    for node in nodes:
                        if node['active']:
                            node['scale']=effective;node['age']+=1
                            if node['age']==life:node['active']=False
                if u>=97:
                    for node in lines:
                        if not node['active'] and u<=223:
                            roots=p['emitters'][2]['roots'];x=draw()%298-149;r=roots[22500-x*x];y=draw()%(2*r)-r;z=-roots[22500-x*x-y*y]
                            speed=128+draw()%64;node['life']=draw()%100
                            node['head']=[(v<<12)|(node['head'][i]&4095) for i,v in enumerate((x,y,z))]
                            node['tail']=[(div0(v*5,6)<<12)|(node['tail'][i]&4095) for i,v in enumerate((x,y,z))]
                            node['velocity']=[-v*speed for v in (x,y,z)];node['active']=True
                        if not node['active']:continue
                        if node['life']==0 or abs(node['tail'][0]>>12)<5:node['active']=False;continue
                        node['life']-=1
                        for i in range(3):node['head'][i]+=node['velocity'][i];node['tail'][i]+=node['velocity'][i]
                player.advance(u);self.assertEqual((player.draw_count,player.noise_scale),(draws,noise),(seed,u))
                self.assertEqual(player.last_landing==u,focus,(seed,u))
                for i,node in enumerate(flames+bursts):
                    actual=player.particles[i]
                    for key in ('pending','active','age','head'):self.assertEqual(actual[key],node[key],(seed,u,i,key))
                    self.assertEqual(actual['size_override'],node['size'],(seed,u,i,'size'))
                    if node['active']:self.assertEqual(actual['spawn_scale'],[node['scale']]*3,(seed,u,i,'prior scale'))
                for i,node in enumerate(lines,35):
                    actual=player.particles[i]
                    for key in ('active','life','head','tail','velocity'):self.assertEqual(actual[key],node[key],(seed,u,i,key))
            if seed==17:self.assertEqual((draws,noise),(1275,243))

    def test_explosion_changed_source_dome_and_rng_equations_are_rejected(self):
        import spell_scene_source as source
        import spell_scene_fire as fire
        from unittest.mock import patch
        effect=next(e for e in exporter.spell_effect_sweep.build()['effects'] if e['name']=='Explosion');image=source.Image()
        for pc in (0x80101994,0x80124A58,0x80124604):
            changed=bytearray(image.data);struct.pack_into('<I',changed,pc-image.base,self.word(pc)+1)
            with patch.object(source,'Image',return_value=source.Image(changed,image.base)):
                with self.assertRaisesRegex(ValueError,'Explosion source changed'):fire.explosion_program(effect,list(range(len(effect['pieces']))))


    def test_earthquake_source_material_rotation_cameras_and_impact_boundaries(self):
        p=self.packet['spells'][23]['program'];e=p['emitter']
        self.assertEqual((self.packet['schema'],p['impact'],p['duration'],p['initial_draws']),('suikoden-spell-scenes/46',257,321,100))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(65,60)])
        self.assertEqual(len(p['objects']),41);self.assertEqual(e['spawn_at'],list(range(129,168,2)))
        self.assertEqual((e['velocity_x'],e['gravity'],e['bounce_divisor'],e['min_x'],e['spin_modulus']),(-27306,4096,2,-500,256))
        # Object+20 -> node bit2 -> the final writer's SetSemiTrans overrides the material setup.
        for pc,word in {0x80111810:0xAE000020,0x801118B0:0x24029556,0x80111B8C:0x3402001E,
                        0x80111C34:0x34060190,0x80111CD4:0x340202BC,0x80111E08:0x24421000,
                        0x80111E38:0xAE000008,0x80111E48:0x00021043,0x80111EB0:0x00021200,
                        0x80111EE0:0x2842FE0C,0x801234A0:0xAC430020,0x80123554:0x00431024,
                        0x800E2994:0x30420004,0x800E2998:0x10400009,0x800E29D8:0x00002821,
                        0x8014AE04:0x304200FD}.items():self.assertEqual(self.word(pc),word)
        _,atlases,errors,_=exporter.battle_bin.parse();self.assertFalse(errors)
        sweep=exporter.spell_effect_sweep.build()
        palette=next(a['atlas'] for a in atlases if a['offset']==sweep['effects'][0]['palette_source']['blob_offset'])
        slots={entry[6] for effect in sweep['effects'] for piece in effect['pieces'] for entry in piece['entries']}
        self.assertEqual(len(slots),82)
        for slot in slots:
            colors=struct.unpack_from('<16H',palette,128*(slot//2)+64+32*(slot%2))
            self.assertEqual(colors[0],0)
            self.assertTrue(all(color&32768 for color in colors[1:]))
        for i in range(20):
            rock,burst=p['objects'][1+2*i:3+2*i]
            self.assertEqual(rock['blend'],'opaque');self.assertEqual(burst['particle_part'],'spark')
            self.assertEqual([(v['draw'],v['modulus']) for v in rock['random_node_angles']],[(4*i+1,341),(4*i+2,341),(4*i+3,4096)])
            self.assertEqual((rock['random_size']['draw'],burst['random_size']['draw']),(4*i,80+i))
        for u,row in enumerate(p['tracks'][0]):
            self.assertEqual(row['piece'] is not None,0<u<97)
            self.assertEqual((row['size'],row['node_angles']),(1+64*min(u,64),[0,0,1+64*min(u,64)]))
            self.assertEqual(p['wash'][u],[min(u,64)-min(max(u-256,0),64)]*3)
        player=Player(self.packet,'spell_24',self.atlas)
        self.assertIsNone(player.reaction(158,'bonbon'));self.assertIsNotNone(player.reaction(159,'bonbon'));self.assertIsNone(player.reaction(191,'bonbon'))
        frame=player.frame(129,(120,50,0),(-128,0,0))
        self.assertTrue(all(c.get('blend')=='opaque' for c in frame['commands'] if c['kind']=='texture'))

    def test_earthquake_full_lifetime_rng_bounces_spin_focus_stride_and_burst_position_hold(self):
        p=self.packet['spells'][23]['program'];roots=p['emitter']['roots']
        for seed in (0,17):
            player=Player(self.packet,'spell_24',self.atlas,seed=seed);state=seed;draws=0
            def draw():
                nonlocal state,draws
                state=(1103515245*state+12345)&0xffffffff;draws+=1;return (state>>16)&32767
            initial=[draw() for _ in range(100)];self.assertEqual(initial,player.draws)
            nodes=[dict(active=False,head=[0]*3,velocity=[0]*3,age=0,node_rotation=0,splash_active=False,splash_age=0,splash_position=[0]*3) for _ in range(20)]
            hits=[];held=0
            def halve(value):return value//2 if value>=0 else -((-value)//2)
            for u in range(1,322):
                focus=False
                if 129<=u<320:
                    for i,node in enumerate(nodes):
                        if u==129+2*i:
                            x=draw()%198-99;extent=roots[10000-x*x];y=draw()%(2*extent)-extent
                            node.update(active=True,head=[x*4096,y*4096,-400*4096],velocity=[-27306,0,0])
                    for i,node in enumerate(nodes):
                        if not node['active']:continue
                        if node['head'][2]//4096>0:
                            node['head'][2]=0;node['velocity'][2]=halve(-node['velocity'][2]);hits.append((u,i))
                            if i%2==0:focus=True
                            if node['splash_active']:held+=1
                            else:node.update(splash_active=True,splash_age=0,splash_position=node['head'].copy())
                        else:node['velocity'][2]+=4096
                        node['node_rotation']=(node['node_rotation']-(draw()&255))%65536
                        node['head']=[x+v for x,v in zip(node['head'],node['velocity'])];node['age']+=1
                        if node['head'][0]//4096 < -500:node['active']=False
                    for node in nodes:
                        if node['splash_active']:
                            node['splash_age']+=1
                            if node['splash_age']==36:node['splash_active']=False
                player.advance(u);self.assertEqual(player.draw_count,draws,(seed,u));self.assertEqual(player.last_landing==u,focus,(seed,u))
                for i,node in enumerate(nodes):
                    for key,value in node.items():self.assertEqual(player.particles[i][key],value,(seed,u,i,key))
            self.assertEqual(hits[0],(157,0));self.assertGreater(held,0)
            self.assertFalse(any(n['active'] or n['splash_active'] for n in nodes))

    def test_earthquake_source_mutations_refuse_changed_motion_or_material(self):
        import spell_scene_source as source
        import spell_scene_earth as earth
        from unittest.mock import patch
        effect=next(e for e in exporter.spell_effect_sweep.build()['effects'] if e['name']=='Earthquake');image=source.Image()
        for pc in (0x80111810,0x80111E08,0x80111E48):
            changed=bytearray(image.data);struct.pack_into('<I',changed,pc-image.base,self.word(pc)+1)
            with patch.object(source,'Image',return_value=source.Image(changed,image.base)):
                with self.assertRaisesRegex(ValueError,'Earthquake source changed'):earth.earthquake_program(effect,list(range(len(effect['pieces']))))


    def test_thunder_god_source_groups_timing_and_material_axes(self):
        p=self.packet['spells'][31]['program']
        self.assertEqual((p['impact'],p['duration'],p['initial_draws']),(484,485,96))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(65,60)])
        self.assertEqual([e['count'] for e in p['emitters']],[8,24])
        self.assertEqual(p['emitters'][0]['spawn_at'],list(range(177,248,10)))
        self.assertFalse(p['emitters'][1]['initial_delays'])
        for pc,word in {0x8010F5FC:0x0C048CED,0x8010F634:0xA4820018,0x8010F658:0xA482001C,
                        0x8010F704:0xA4820018,0x8010F728:0xA482001C,0x8010FB64:0x3406012C,
                        0x8010FB70:0xAE020000,0x8010FB74:0xAE000004,0x8010FB90:0xAE020014,
                        0x8010FC78:0x8E02001C,0x8010FCC4:0x34050050,0x80110024:0xAC620024,
                        0x8011006C:0xAC620024,0x80110128:0x2842FED5,0x80110148:0x2442FFEE,
                        0x8010FE8C:0x34020384,0x8010FEA0:0x0C0496CA}.items():self.assertEqual(self.word(pc),word)
        sprites=[o for o in p['objects'] if o.get('particle_index',0)>=8]
        for i,obj in enumerate(sprites):
            self.assertEqual(obj['random_size'],exporter.variation(4*i+1,4096,2048))
            self.assertEqual(obj['random_node_angles'],[exporter.variation(4*i+2,2048),None,exporter.variation(4*i+3,2048)])
            self.assertTrue(all(row.get('node_angles')==[0,0,0] for row in p['tracks'][obj['track']]))
        player=Player(self.packet,'spell_32',self.atlas)
        self.assertIsNone(player.reaction(356,'bonbon'));self.assertIsNotNone(player.reaction(357,'bonbon'))
        for u in (128,176,188,189,252,268,269,356,357,397,420,421,483,484):
            frame=player.frame(u,(120,50,0),(-128,0,0))
            self.assertLessEqual(len(frame['commands']),512)
        self.assertEqual(len(frame['commands']),0)
        import spell_scene_source as source,spell_scene_lightning as lightning
        from unittest.mock import patch
        effect=next(e for e in exporter.spell_effect_sweep.build()['effects'] if e['name']=='Thunder God');image=source.Image()
        for pc in (0x8010FB70,0x8010FC78,0x80110148,0x80120830,0x80122FB4):
            changed=bytearray(image.data);struct.pack_into('<I',changed,pc-image.base,0)
            with patch.object(source,'Image',return_value=source.Image(changed,image.base)):
                with self.assertRaisesRegex(ValueError,'Thunder God source changed'):lightning.thunder_program(effect,list(range(len(effect['pieces']))))

    def test_thunder_god_full_lifetime_unused_delays_radial_births_and_spark_rise(self):
        table=struct.unpack_from('<192h',self.image,0x8017242C-self.base)
        def root(n):
            if not n:return 0
            exponent=3
            while n<64:n*=4;exponent-=1
            while n>=256:n//=4;exponent+=1
            return (table[n-64]<<exponent)>>12
        for seed in (0,17):
            player=Player(self.packet,'spell_32',self.atlas,seed=seed);state=seed;draws=0
            def draw():
                nonlocal state,draws
                state=(1103515245*state+12345)&0xffffffff;draws+=1;return (state>>16)&32767
            self.assertEqual([draw() for _ in range(96)],player.draws)
            bolts=[dict(active=False,head=[0]*3,age=0,splash_active=False,splash_position=[0]*3,splash_age=0,spark_height=0,life=0,pulse_life=0,pulse_size=1) for _ in range(8)]
            sprites=[dict(active=False,head=[0]*3,age=0) for _ in range(24)]
            births=[]
            for u in range(1,486):
                if 177<=u<484:
                    for i,b in enumerate(bolts):
                        if u==177+10*i:draw();draw();b.update(active=True,head=[150*4096,0,-300*4096])
                    for b in bolts:
                        if not b['active']:continue
                        b['head'][2]+=25*4096
                        if b['head'][2]>0:
                            b['head'][2]=0;b.update(active=False,splash_active=True,splash_position=b['head'].copy(),life=64,pulse_life=48,pulse_size=1)
                        else:b['age']+=1
                    for b in bolts:
                        if b['splash_active']:
                            if b['life']>0:b['life']-=1
                            if b['life']==0:
                                if b['spark_height']//4096 < -299:b['splash_active']=False
                                b['spark_height']-=18*4096
                            if b['splash_active']:b['splash_age']+=1
                        if b['pulse_life']:
                            b['pulse_size']=b['pulse_size']+512 if b['pulse_life']>32 else max(1,b['pulse_size']-256)
                            b['pulse_life']-=1
                            if b['pulse_life']==0:b['pulse_size']=1
                if 357<=u<484:
                    if u<=404:
                        for i,node in enumerate(sprites):
                            if node['active']:continue
                            h=draw()%200;x=draw()%158-79;extent=root(6400-x*x);y=draw()%(extent*2)-extent
                            node.update(active=True,head=[x*4096,y*4096,-h*4096],age=0);births.append((u,i))
                    for node in sprites:
                        if node['active']:
                            node['age']+=1
                            if node['age']==10:node['active']=False
                player.advance(u);self.assertEqual(player.draw_count,draws,(seed,u))
                for i,node in enumerate(bolts+sprites):
                    for key,value in node.items():self.assertEqual(player.particles[i][key],value,(seed,u,i,key))
            self.assertEqual(draws,472)
            self.assertEqual(sorted(set(u for u,_ in births)),[357,367,377,387,397])
            self.assertEqual(len(births),120)
            self.assertFalse(any(node['active'] or node.get('splash_active') for node in bolts+sprites))


    def test_final_flame_source_clocks_dome_and_caster_boundary(self):
        p=self.packet['spells'][28]['program']
        self.assertEqual((p['impact'],p['duration'],p['initial_draws'],len(p['objects'])),(584,586,120,131))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(129,60),(393,128)])
        self.assertEqual([e['particle_start'] if 'particle_start' in e else 0 for e in p['emitters']],[0,20,50,49])
        self.assertEqual([e['count'] for e in p['emitters']],[20,29,30,1])
        self.assertEqual(p['tracks'][0][97]['tint'],[252]*3)
        self.assertIsNotNone(p['tracks'][0][97]['piece']);self.assertIsNone(p['tracks'][0][98]['piece'])
        self.assertEqual(p['emitters'][2]['delay_bias'],20)
        for pc,word in {0x80102088:0xAC620014,0x80102488:0x3405001E,0x8010251C:0xAC46000C,
                        0x80102524:0xAC450014,0x80102618:0x2A22001D,0x80102710:0x340200B4,
                        0x801027B8:0x0C049316,0x801029A8:0x2842FED5,0x801029E4:0x2442FEAB,
                        0x80102A90:0x2842012C,0x80102AA8:0xAC6212FC,0x80102BF4:0xAE000014,
                        0x80102C18:0x0C0493E1,0x80102C40:0xAE040010,0x80124AA0:0xAE200018,
                        0x80124C84:0xAE200018,0x80125128:0x14400003,0x80125134:0xAC820000}.items():self.assertEqual(self.word(pc),word)
        # Constructor and reset both select uniform expansion, not the alternative sweep branch.
        for u in range(393,489):
            self.assertEqual(p['tracks'][8][u]['scale'],[((1+174762*(u-392))>>12)]*3)
        for i,mesh in enumerate(p['meshes'][:5]):
            self.assertEqual((mesh['start'],mesh['stop'],mesh['segments']),(393,489,24))
            self.assertEqual(mesh['outer'],[51*i,39*i,32*i]);self.assertEqual(mesh['inner'],[51*(i+1)-1,39*(i+1)-1,32*(i+1)-1])
        flash=p['screen_washes'][0]['colors']
        self.assertIsNone(flash[392]);self.assertEqual(flash[393],[2]*3);self.assertEqual(flash[488],[255]*3)
        self.assertEqual(flash[584],[0]*3);self.assertIsNone(flash[585])
        import spell_scene_source as source,spell_scene_fire as fire
        from unittest.mock import patch
        effect=next(e for e in exporter.spell_effect_sweep.build()['effects'] if e['name']=='Final Flame');image=source.Image()
        for pc in (0x80102618,0x801029E4,0x80124C84):
            changed=bytearray(image.data);struct.pack_into('<I',changed,pc-image.base,0)
            with patch.object(source,'Image',return_value=source.Image(changed,image.base)):
                with self.assertRaisesRegex(ValueError,'Final Flame source changed'):fire.final_program(effect,list(range(len(effect['pieces']))))

    def test_final_flame_full_lifetime_source_birth_order_ballistics_and_cached_scales(self):
        roots=exporter.square_roots(14400)
        def div0(v,d):return abs(v)//d*(-1 if v<0 else 1)
        for seed in (0,17):
            player=Player(self.packet,'spell_29',self.atlas,seed=seed);state=seed;draws=0
            def draw():
                nonlocal state,draws
                state=(1103515245*state+12345)&0xffffffff;draws+=1;return (state>>16)&32767
            initial=[draw() for _ in range(120)];self.assertEqual(initial,player.draws)
            meteors=[dict(active=False,head=[0]*3,velocity=[0]*3,age=0) for _ in range(20)]
            balls=[dict(active=False,head=[0]*3,velocity=[0]*3,splash_active=False,splash_age=0,splash_position=[0]*3) for _ in range(30)]
            flames=[dict(active=False,head=[0]*3,age=0,spawn_scale=[4096]*3,pending=True,delay=20+initial[60+2*i]%64) for i in range(30)]
            def circle(node,radius,height=0):
                x=draw()%(2*(radius-1))+1-radius;extent=roots[radius*radius-x*x];y=draw()%(extent*2)-extent
                scale=node.get('spawn_scale',[4096]*3)
                node['head']=[div0(v*scale[i],4096)*4096 for i,v in enumerate((x,y,-height))];node['active']=True
            raw_scale=1;special=None;focuses=[]
            for u in range(1,587):
                if u==64:raw_scale=0x1000000
                if 65<=u<=192:
                    for i,node in enumerate(meteors):
                        if u-65==3*i:
                            height=draw()%40;circle(node,30,height);node['velocity']=[0]*3
                if 193<=u<=488:
                    clock=u-193
                    if clock==0:raw_scale=1
                    for i,node in enumerate(balls[:29]):
                        if clock==200*i//30:circle(node,120);node['velocity']=[-38400,0,76800]
                    if clock>=20:
                        for node in flames:
                            if clock==node['delay']:circle(node,120);node.update(pending=False,delay=0,age=0)
                        for node in flames:
                            if node['delay']==0 and not node['active']:circle(node,120);node['age']=0
                        raw_scale=min(0x1000000,raw_scale+93206)
                    if clock==180:
                        before=draws;circle(balls[29],2);balls[29]['velocity']=[-38400,0,76800];special=(before,draws,balls[29]['head'].copy())
                focus=False
                if u<585:
                    for node in meteors:
                        if node['head'][2]//4096 < -299:node['active']=False
                        if not node['active']:continue
                        node['age']+=1;node['velocity'][2]-=341;node['head'][2]+=node['velocity'][2]
                    for node in balls:
                        if not node['active']:continue
                        node['head']=[v+d for v,d in zip(node['head'],node['velocity'])]
                        if node['head'][2]//4096>=300:
                            node.update(active=False,splash_active=True,splash_age=0,splash_position=node['head'].copy());focus=True
                    for node in balls:
                        if node['splash_active']:
                            node['splash_age']+=1
                            if node['splash_age']==30:node['splash_active']=False
                    for node in flames:
                        if node['active']:
                            node['spawn_scale']=[raw_scale>>12]*3;node['age']+=1
                            if node['age']==55:node['active']=False
                if focus:focuses.append(u)
                player.advance(u);self.assertEqual(player.draw_count,draws,(seed,u));self.assertEqual(player.last_landing==u,focus,(seed,u))
                for i,node in enumerate(meteors+balls+flames):
                    for key,value in node.items():
                        if key in ('delay','pending'):continue
                        self.assertEqual(player.particles[i][key],value,(seed,u,i,key))
            self.assertIsNotNone(special);self.assertEqual(special[1]-special[0],2)
            self.assertEqual(focuses[0],208);self.assertIn(388,focuses)
            self.assertFalse(any(node['active'] for node in meteors+balls+flames))


class ArrangedLightning(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packet,_,_=exporter.build()

    def test_arranged_bolts_follow_source_motion_and_persistent_spark_closure(self):
        p=self.packet['spells'][18]['program'];e=p['emitter']
        self.assertEqual((p['impact'],p['duration'],p['reaction']['start']),(337,401,268))
        self.assertEqual([(c['at'],c['updates']) for c in p['cameras']],[(1,60),(65,60)])
        self.assertEqual(e['spawn_at'],[129]*4+[154]*4+[179]*4+[257]*4)
        for height in (-350,-100,0,45,1675,1700):
            player=Player(dict(self.packet,entries=[]),'spell_19',Image.new('RGBA',(1,1)),target=(0,0,height))
            for update in range(402):
                player.advance(update);u=min(update,399)
                for index,particle in enumerate(player.particles[:16]):
                    at=e['spawn_at'][index];land=at+max(1,(height+300)//25+1)-1
                    arrived=at<=u;hit=arrived and u>=land
                    self.assertEqual(particle['active'],arrived and not hit,(height,u,index))
                    if arrived:self.assertEqual(particle['head'][2],(height if hit else -300+25*(u-at+1))*4096)
                    self.assertEqual(particle['age'],max(0,min(u,land-1)-at+1))
                    big=index>=12
                    live=hit and ((u<336 or land>=336) if big else u<land+47)
                    self.assertEqual(particle['splash_active'],live,(height,u,index))
                    if hit:
                        self.assertEqual(particle['life'],48 if big else max(0,47-(u-land)))
                        self.assertEqual(particle['splash_position'],[e['fixed_positions'][index][0],0,height*4096])
                    self.assertEqual(particle['spark_angle'],min(1024,32*max(0,min(u,336)-303)) if big else 0)
                    self.assertEqual(particle['pulse_life'],max(0,47-(u-land)) if hit else 0)
                    pulse=1
                    for remaining in range(48,max(0,47-(u-land)),-1) if hit else ():
                        pulse=pulse+512 if remaining>32 else max(1,pulse-256)
                    if hit and u-land>=47:pulse=1
                    self.assertEqual(particle['pulse_size'],pulse)
                self.assertEqual(player.draw_count,0)
                if update<400 and any(update==at+max(1,(height+300)//25+1)-1 for at in e['spawn_at']):self.assertEqual(player.camera(update)[2],5)
        self.assertEqual(p['wash'][64],[96]*3)
        self.assertEqual(p['wash'][337],[94]*3)
        self.assertEqual(p['wash'][400],[0]*3)

    def test_arranged_export_follows_changed_constructor_radius(self):
        import spell_effect_sweep,spell_scene_source as source
        from unittest.mock import patch
        effect=next(e for e in spell_effect_sweep.build()['effects'] if e['name']=='Raging Blow')
        image=source.Image();raw=bytearray(image.data)
        struct.pack_into('<I',raw,0x8010D9EC-image.base,0x34020079)
        with patch.object(source,'Image',return_value=source.Image(raw,image.base)):
            program=exporter.arranged_lightning_program(effect,list(range(len(effect['pieces']))))
        self.assertEqual([v[0] for v in program['emitter']['fixed_positions']],[121*4096]*4+[81*4096]*4+[41*4096]*4+[20*4096]*4)

    def test_helper_camera_condition_is_checked_against_constructor_and_writer(self):
        import spell_scene_support as support,spell_effect_sweep,spell_scene_source as source
        from unittest.mock import patch
        effect=next(e for e in spell_effect_sweep.build()['effects'] if e['name']=='Raging Blow')
        image=source.Image()
        for pc,word in {0x8010DBBC:0x3404000C,0x8010DBD8:0xAC400050,
                        0x8011D21C:0xAE36004C,0x8011D220:0xAE360050,
                        0x8011D3F8:0x8D030050,0x8011D400:0x0064182A,
                        0x8011D404:0x1060004E,0x8011D538:0x24420001,
                        0x8010DEBC:0x34020041,0x8010DEC0:0x1462000C}.items():self.assertEqual(image.word(pc),word)
        cameras={0x8010DED0:[]};colors=support.screen_flashes(effect,cameras)[0]['colors']
        self.assertEqual(cameras[0x8010DED0],[])
        self.assertEqual(colors[129:141],[[((0xff000-(n+1)*(0xff000//12))>>12)&255]*3 for n in range(12)])
        # A reachable helper-counter compare produces a real event without spell overrides.
        raw=bytearray(image.data);struct.pack_into('<I',raw,0x8010DEBC-image.base,0x34020005)
        with patch.object(source,'Image',return_value=source.Image(raw,image.base)):
            changed={0x8010DED0:[]};support.screen_flashes(effect,changed)
        self.assertEqual(changed[0x8010DED0],[133,138,143,148,153,158,163,168,173,178,183,188,193,198,203,208,213,218,223,228,233,238,243,248,253])



class ContractingLightning(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.packet,_,_=exporter.build()

    def test_stationary_contact_preserves_animation_and_independent_contraction_clock(self):
        program=self.packet['spells'][19]['program'];e=program['emitter']
        self.assertEqual((program['impact'],program['duration'],e['flight_stop'],e['spark_stop']),(384,385,209,289))
        self.assertEqual(e['spawn_at'],[145]*3+[161]*3)
        self.assertEqual([(m['start'],m['stop']) for m in program['meshes']],[(157,289),(173,289)])
        for height in (-350,0,45,1700):
            player=Player(dict(self.packet,entries=[]),'spell_20',Image.new('RGBA',(1,1)),target=(0,0,height))
            for update in range(386):
                player.advance(update);u=min(update,383)
                for index,p in enumerate(player.particles[:6]):
                    at=e['spawn_at'][index];land=at+max(1,(height+300)//25+1)-1;hit=land<=u and land<209
                    self.assertEqual(p['active'],at<=u<209,(height,u,index))
                    self.assertEqual(p['landed'],hit,(height,u,index))
                    self.assertEqual(p['age'],max(0,min(u,208)-at+1))
                    self.assertEqual(p['splash_active'],hit and u<289)
                    self.assertEqual(p['splash_age'],max(0,min(u,288)-land+1) if hit else 0)
                    self.assertEqual(p['life'],70 if hit else 0)
                    self.assertEqual(p['pulse_life'],max(0,47-(u-land)) if hit else 0)
                    if at<=u:
                        z=min(height,-300+25*(min(u,208)-at+1)) if hit else -300+25*(min(u,208)-at+1)
                        self.assertEqual(p['head'][2],z*4096)
                self.assertEqual(player.draw_count,0)
                for index,m in enumerate(program['meshes']):
                    self.assertEqual(m['base_heights'][min(update,384)],max(-300,-5-10*max(0,update-(157+16*index)+1)))
                    track=program['tracks'][m['track']][min(update,384)]
                    scale=max(0,4096-64*max(0,update-224))
                    self.assertEqual(track['scale'],[scale,scale,4096])
                    self.assertEqual(m['angles'],[0,0,index*2048])
                reacting=any(start<=update<start+34 for start in (225,261,297))
                self.assertEqual(player.reaction(update,'crow') is not None,reacting)
        for obj in program['objects']:
            if 'piece_track' in obj:
                self.assertEqual(program['tracks'][obj['track']][225]['size'],4032)
                self.assertEqual(program['tracks'][obj['track']][288]['size'],0)
        import maindec
        for pc,word in {0x8010F118:0xAE000014,0x8010F124:0x1040000B,0x8010EDBC:0x2442FFC0,
                        0x8010EDD4:0x34030024,0x8010EF30:0x340203E8,0x8010F2B0:0xAC62004C}.items():self.assertEqual(struct.unpack_from('<I',maindec.body(),pc-maindec.MBASE)[0],word)

    def test_contracting_constructor_mutation_changes_export_without_spell_override(self):
        import spell_effect_sweep,spell_scene_source as source
        from unittest.mock import patch
        effect=next(e for e in spell_effect_sweep.build()['effects'] if e['name']=='Ball of Lightning')
        image=source.Image();raw=bytearray(image.data);struct.pack_into('<I',raw,0x8010E6BC-image.base,0x34637000)
        with patch.object(source,'Image',return_value=source.Image(raw,image.base)):
            p=exporter.contracting_lightning_program(effect,list(range(len(effect['pieces']))))
        self.assertEqual([v[0] for v in p['emitter']['fixed_positions']],[151*4096]*3+[150*4096]*3)




if __name__=='__main__':unittest.main()
