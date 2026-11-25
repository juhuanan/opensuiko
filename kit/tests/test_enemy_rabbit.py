"""Independent Rabbit script/frame readers and static return-hop equations."""
import json
import copy
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_first_room import source
import export_enemy_rabbit as exporter
from test_physical_rune_export import independent_stream
from test_physical_callbacks import signed, quotient


def witness():
    packet=exporter.build()
    cases=[]
    for first,home in (([-819200,81920,-20480],[-524288,0,0]),
                       ([-12345,76543,-640123],[25003,-54321,123]),
                       ([520195,-190403,1007],[-252115,28490,-11111]),
                       ([-2147483600,2147483500,-2147483000],[127,-211,-350])):
        position=first.copy();delta=[quotient(signed(h-p),3) for h,p in zip(home,first)]
        hops=[];levels=(0,0,20,-20,0)
        for hop in range(1,4):
            destination=[signed(p+d) for p,d in zip(position,delta)]
            destination[1]=signed(destination[1]+(levels[hop+1]-levels[hop])*4096)
            velocity=[0,0,-12288]
            acceleration=[quotient(signed(signed(d-p)-v*10),45) for d,p,v in zip(destination,position,velocity)]
            row=dict(start=position.copy(),destination=destination.copy(),velocity=velocity.copy(),acceleration=acceleration,samples=[])
            for update in range(1,11):
                position=[signed(p+v) for p,v in zip(position,velocity)]
                velocity=[signed(v+a) for v,a in zip(velocity,acceleration)]
                if update==10:position=destination.copy()
                row['samples'].append(dict(position=position.copy(),velocity=velocity.copy()))
            hops.append(row)
        cases.append(dict(first=first,home=home,delta=delta,hops=hops))
    return dict(packet,return_cases=cases)


class RabbitSource(unittest.TestCase):
    def test_normal_batch_merge_is_closed_idempotent_and_preserves_input(self):
        original=json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        before=copy.deepcopy(original)
        result=exporter.combine(original)
        self.assertEqual(original,before)
        self.assertEqual(exporter.combine(result),result)
        self.assertEqual(result['schema'],original['schema'])
        self.assertEqual(next(e for e in result['counter']['melee']['enemies'] if e['id']=='killer_rabbit'),exporter.build()['ordinary'])
        programs={p['id']:p for p in result['programs']['programs']}
        for p in original['programs']['programs']:self.assertEqual(p,programs[p['id']])
        changed=copy.deepcopy(exporter.build());changed['ordinary']['projectile']['position_z_q12']+=1
        with self.assertRaisesRegex(ValueError,'Conflicting Rabbit'):exporter.combine(result,changed)

    def test_normal_profile_art_and_three_whole_formations_preserve_source_data(self):
        from PIL import Image
        from export_first_room import Atlas
        from test_export_unite_review import vram_pose
        battle=json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text())
        actors=json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        battle['enemies']=[row for row in battle['enemies'] if row['id']!='killer_rabbit']
        battle['encounters']=[row for row in battle['encounters'] if row['id'] not in ('area_b_5','area_b_7','area_b_8')]
        battle['unite_graphics']=[row for row in battle['unite_graphics'] if row['id']!='killer_rabbit']
        atlas=Atlas();atlas.image=Image.new('RGBA',(4096,4096),(0,0,0,0))
        atlas.image.paste((19,31,47,255),(0,0,4096,3));atlas.y=4
        proof=exporter.append_content(battle,actors,atlas)
        import preparation
        preparation.bind_weapon_elements(battle)
        self.assertEqual(battle['schema'],'suikoden-battle-trial/43')
        self.assertEqual(proof['formations'],['area_b_5','area_b_7','area_b_8'])
        self.assertEqual(atlas.image.getpixel((4095,2)),(19,31,47,255))
        raw,_=source('/B_DATA.BIN');record=0x1f748
        profile=battle['enemies'][-1]
        self.assertEqual(profile['action_policy'],'source_rabbit')
        self.assertNotIn('projectile',profile);self.assertNotIn('ordinary_timing',profile)
        self.assertEqual(profile['knockout_ticks'],94)
        self.assertEqual(profile['max_hp'],struct.unpack_from('<H',raw,record+18)[0])
        self.assertEqual(profile['stats'],dict(zip(('attack','skill','defense','speed','magic','luck'),struct.unpack_from('<6H',raw,record+20))))
        self.assertEqual(profile['effect_offset'],list(struct.unpack_from('<2h',raw,record+60)))
        self.assertEqual([row['source_slots'] for row in battle['encounters'][-3:]],[[0,1,2,3,4,5],[0,1,2,3],[0,1,2,3,4,5]])
        self.assertEqual(battle['encounters'][-3]['enemies'],['killer_rabbit']*6)
        graphic=next(g for g in battle['unite_graphics'] if g['id']=='killer_rabbit')
        self.assertEqual({p['id'] for p in graphic['poses']},set(range(9)))
        section=struct.unpack_from('<I',raw,record+44)[0]-exporter.BASE
        for pose in graphic['poses']:
            image,ax,ay=vram_pose(raw,section,pose['id'],packet=True,base=exporter.BASE)
            r=pose['sprite']['rect']
            self.assertEqual((image.size,ax,ay),((r['w'],r['h']),pose['sprite']['anchor_x'],pose['sprite']['anchor_y']))
            self.assertEqual(atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes(),image.tobytes())
        self.assertTrue(next(p for p in graphic['poses'] if p['id']==8)['pieces'])
        with self.assertRaisesRegex(ValueError,'already present'):exporter.append_content(battle,actors,atlas)

    def test_all_body_and_rotated_projectile_pixels_use_the_shared_batch_exporter(self):
        from export_first_room import Atlas
        from export_physical_runes import graphics,merge_libraries
        from test_export_unite_review import vram_pose
        packet=json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        component=exporter.build();merge_libraries(packet,component)
        packet['counter']['melee']['enemies'].append(component['ordinary'])
        atlas=Atlas()
        roots=[('killer_rabbit',row['id']) for row in component['programs']['programs'] if '/auxiliary/' not in row['id']]
        art,proof=graphics(packet,dict(resources=[component['provenance']['resource']]),atlas,{'killer_rabbit'},roots)
        self.assertEqual(len(art),1)
        self.assertEqual([pose['id'] for pose in art[0]['poses']],list(range(9)))
        raw,_=source('/B_DATA.BIN');section=component['provenance']['resource']['section_offset']
        for pose in art[0]['poses']:
            image,ax,ay=vram_pose(raw,section,pose['id'],packet=True,base=0x80080000)
            sprite=pose['sprite'];r=sprite['rect']
            self.assertEqual((image.size,ax,ay),((r['w'],r['h']),sprite['anchor_x'],sprite['anchor_y']))
            self.assertEqual(atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes(),image.tobytes())
            if pose['id']!=8:
                self.assertNotIn('pieces',pose)
                continue
            self.assertTrue(pose['pieces'])
            for index,piece in enumerate(pose['pieces']):
                image,ax,ay=vram_pose(raw,section,pose['id'],piece_index=index,base=0x80080000)
                r=piece['rect']
                self.assertEqual((image.size,ax,ay),((r['w'],r['h']),piece['anchor_x'],piece['anchor_y']))
                self.assertEqual(atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes(),image.tobytes())
        self.assertEqual([row['id'] for row in proof[0]['poses'] if row['mode']=='ordinary_and_secondary_pieces'],[8])

    def test_launch_camera_copies_all_twelve_q12_fields_before_the_actor_sweep(self):
        packet=exporter.build();raw,_=source('/B_DATA.BIN')
        words=list(struct.unpack_from('<12i',raw,0x1f8c0))
        request=packet['ordinary']['projectile']['camera']
        self.assertEqual(request['updates'],20)
        self.assertEqual([n for key in ('position','angles','c','d') for n in request['target'][key]],words)
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        word=lambda address:struct.unpack_from('<I',main,2048+address-base)[0]
        # Primary callback then camera integrator then actor update, all in the same root update.
        for address,value in {0x800de0e0:0x0040f809,0x800de1c8:0x0c03800d,
            0x800e003c:0x0c0383a8,0x800e0044:0x0c03826f,
            0x800f6118:0x8c820000,0x800f6120:0xac6212c4,
            0x800f619c:0x8c82002c,0x800f61a8:0xa4c5132a,
            0x800f61ac:0xa4c51328,0x800f61b0:0xa4c51326,
            0x800f61b4:0xa4c51324,0x800f61b8:0xacc212f0,
            0x800f61c8:0x00441023,0x800f61cc:0x0043001a}.items():
            self.assertEqual(word(address),value,hex(address))
        for offset,value in {0x7b8:0x8c420028,0x7c0:0x2484f8c0,0x7c8:0x34050014}.items():
            self.assertEqual(struct.unpack_from('<I',raw,offset)[0],value)

    def test_projectile_contact_uses_physical_damage_then_hp_then_hurt_once(self):
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        for slot,target in ((4,0x800e3820),(12,0x800f7e90),(16,0x800e1654)):
            self.assertEqual(struct.unpack_from('<I',main,2048+0x8016b680+slot-base)[0],target)
        raw,_=source('/B_DATA.BIN');word=lambda offset:struct.unpack_from('<I',raw,offset)[0]
        for offset,value in {
            0xb80:0x94620040,0xb88:0x30420002,0xb8c:0x1040001b,
            0xb98:0x90700004,0xb9c:0x8c42000c,0xba4:0x0040f809,
            0xba8:0x02002821,0xbb4:0x8c630010,0xbb8:0x02002021,
            0xbbc:0x0060f809,0xbc0:0x00402821,0xbcc:0x8c420004,
            0xbd4:0x24c6efbc,0xbd8:0x0040f809,0xbdc:0x02202821,
            0xbf8:0xac400050,
        }.items():self.assertEqual(word(offset),value,hex(offset))
        packet=exporter.build()
        self.assertEqual(packet['ordinary']['hurt_program'],'melee/killer_rabbit/hurt')
        self.assertEqual(packet['ordinary']['projectile'],{key:packet['projectile'][key]
            for key in ('owner_program','child_program','animation','position_z_q12','camera')})

    def test_projectile_initializer_and_spin_are_independent_of_shared_aiming(self):
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        for slot,target in ((0x1c,0x800e5e60),(0x20,0x800e1e3c),(0x24,0x800e7468)):
            self.assertEqual(struct.unpack_from('<I',main,2048+0x8016b680+slot-base)[0],target)
        raw,_=source('/B_DATA.BIN');word=lambda offset:struct.unpack_from('<I',raw,offset)[0]
        for offset,value in {
            0x7a0:0x0c020262,0x7a8:0x1040001e,0x7f0:0x24630b44,
            0x7f4:0xac430050,0x808:0x24c6f8f0,0x810:0x02402821,
            0x9bc:0x8c42001c,0x9d0:0x0660003d,0x9f4:0x8c440030,
            0x9f8:0x8c620020,0xa04:0x34050010,0xa20:0xae020084,
            0xa2c:0x8c630024,0xa3c:0xae020088,0xa60:0x8c43005c,
            0xa68:0xae03005c,0xa6c:0x8c430060,0xa74:0xae030060,
            0xa78:0x8c420064,0xa80:0xae020064,0xa84:0x8e220068,
            0xa8c:0xae020068,0xa90:0x8e23006c,0xa94:0x3c02fffe,
            0xa98:0x3442c000,0xa9c:0xae020070,0xaa0:0xae03006c,
            0xab4:0x24c6f92c,0xabc:0x02c02821,0xac8:0x00001021,
            0xb18:0x9482001c,0xb20:0x24420200,0xb24:0xa482001c,
            0xb2c:0x8c630088,0xb38:0xa4620006,0xb40:0x2402ffff,
        }.items():self.assertEqual(word(offset),value,hex(offset))
        packet=exporter.build();binding=packet['projectile']
        self.assertEqual(binding,dict(owner_program='melee/killer_rabbit/projectile_owner',
            child_program='melee/killer_rabbit/projectile_child',resource='killer_rabbit',
            animation=16,home='target_home',position_xy='owner_current',position_z_q12=-81920,spin_step=512,camera=dict(updates=20,target=dict(position=[196608,0,0],angles=[-3276800,0,2752512],c=[0,0,4194304],d=[20971520]*3))))
        child=next(row for row in packet['provenance']['programs'] if row['id']==binding['child_program'])
        self.assertEqual([op['args'] for op in child['operations'] if op['op']==23],
            [[3,30,0,0,-24,-9,-9,-9],[2,30,0,0,0,9,9,0]])
        self.assertEqual([op['args'] for op in child['operations'] if op['op']==26],[[1,1],[1,2],[1,4]])

    def test_all_primary_streams_agree_with_independent_reader(self):
        packet=exporter.build();raw,_=source('/B_DATA.BIN')
        self.assertEqual(packet['programs']['schema'],'suikoden-actor-programs/7')
        self.assertEqual(len(packet['programs']['programs']),6)
        for program in packet['provenance']['programs']:
            self.assertEqual(program['operations'],independent_stream(raw,program['spans'][0]['source_offset'],0x1f788,0x80080000))
        retreat=next(row for row in packet['provenance']['programs'] if row['id'].endswith('/return'))
        self.assertEqual([op['args'] for op in retreat['operations'] if op['op']==35],[[1,8]])
        self.assertEqual([op['args'] for op in retreat['operations'] if op['op']==30],[[1],[3],[3],[3],[4]])
        main,_=source('MAIN.EXE')
        self.assertEqual(len(packet['provenance']['children']),1)
        child=packet['provenance']['children'][0]
        self.assertEqual(child['operations'],independent_stream(main,child['source_offset'],0,0))
        programs={p['id'] for p in packet['programs']['programs']}
        resources={r['id']:r for r in packet['animations']['resources']}
        self.assertEqual(set(resources),{'killer_rabbit','shared_impacts'})
        for program in packet['programs']['programs']:
            for instruction in program['instructions']:
                if 'child' in instruction.get('command',{}):
                    spawn=instruction['command']['child']
                    self.assertIn(spawn['program'],programs)
                    self.assertIn(spawn['animation'],[c['id'] for c in resources[spawn['resource']]['clips']])

    def test_raw_callback_writers_and_dispatch_consumers_define_the_motion(self):
        raw,_=source('/B_DATA.BIN');word=lambda offset:struct.unpack_from('<I',raw,offset)[0]
        for offset,value in {
            0x3e0:0x94430042,0x448:0x8c65005c,0x44c:0x8c640068,
            0x450:0x34060003,0x454:0x00a42823,0x458:0x00a6001a,
            0x488:0x00403821,0x48c:0xace50000,0x514:0xace4000c,
            0x548:0x3402000a,0x54c:0xa6020010,0x550:0xae00002c,
            0x554:0xae000030,0x558:0x2402d000,0x55c:0xae020034,
            0x580:0x3c01800a,0x584:0x2421f8ac,0x59c:0x2421f8b0,
            0x5fc:0x24420001,0x600:0x0c020078,0x604:0xace2000c,
            0x608:0x34020002,0x610:0xa6020042,0x644:0xac400058,0x648:0xac400054,
            0x2ac:0x00c33023,0x2b0:0x00c8001a,0x384:0xac460020,
        }.items():self.assertEqual(word(offset),value,hex(offset))
        motion=exporter.build()['return_motion']
        self.assertEqual(motion,dict(steps=3,hop_updates=10,y_levels_q12=[0,81920,-81920,0],initial_velocity_q12=[0,0,-12288]))

    def test_every_selected_frame_pair_and_flag_agrees_with_raw_resource(self):
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        for address,word in {0x800e2104:0x0c038847,0x800e2168:0x24630004,
                             0x800e2178:0x90440000,0x800e217c:0x90420001}.items():
            self.assertEqual(struct.unpack_from('<I',main,2048+address-base)[0],word)
        raw,_=source('/B_DATA.BIN');pointer=lambda offset:struct.unpack_from('<I',raw,offset)[0]-0x80080000
        section=pointer(0x1f748+44);frames=pointer(section+20);poses=pointer(section+16)
        resource=exporter.build()['animations']['resources'][0]
        self.assertEqual(resource['pose_count'],struct.unpack_from('<H',raw,section)[0])
        self.assertEqual([r['id'] for r in resource['clips']],[0,1,3,7,8,9,11,16,17,18,19,20])
        for clip in resource['clips']:
            cursor=pointer(frames+4*clip['id']);expected=[]
            # The setter selects pair zero even when the frame count is zero.
            for index in range(max(1,raw[cursor])):
                pose,updates=raw[cursor+4+2*index:cursor+6+2*index];entry=pointer(poses+4*pose)
                expected.append(dict(pose=pose,updates=updates or 256,attachment=[raw[entry+6]-raw[entry+4],raw[entry+7]-raw[entry+5]]))
            self.assertEqual(clip['frames'],expected)
            for name,bit in (('advances',1),('loop',2),('semitransparent',4)):
                self.assertEqual(clip[name],bool(raw[cursor+1]&bit))
        packet=exporter.build();proof=packet['provenance']['shared_resource']
        raw,origin=source('BATTLE.BIN');self.assertEqual(origin,proof['source'])
        pointer=lambda offset:struct.unpack_from('<I',raw,offset)[0]-proof['pointer_base']
        section=proof['section_offset'];cursor=pointer(pointer(section+20))
        clip=packet['animations']['resources'][1]['clips'][0]
        self.assertEqual(clip['id'],0)
        self.assertEqual([(f['pose'],f['updates']) for f in clip['frames']],
            [(raw[cursor+4+2*i],raw[cursor+5+2*i] or 256) for i in range(max(1,raw[cursor]))])

    def test_callback_table_data_and_helper_mutations_refuse(self):
        raw,origin=source('/B_DATA.BIN')
        for offset in (0x1f788+32,0x1f788+24,0x450,0x548,0x2b0,4,0x1f8b4,0x808,0xa68,0xa9c,0xb20,0xb9c,0xbd4,0xbf8,0x1f8c0):
            changed=bytearray(raw);changed[offset]^=1
            with patch.object(exporter,'source',return_value=(bytes(changed),origin)):
                with self.assertRaisesRegex(ValueError,'Rabbit'):exporter.build()

    def test_repeatable_fixture_retains_fractional_residuals(self):
        data=witness();self.assertEqual(data,witness())
        self.assertEqual(data,json.loads((ROOT/'game/tests/fixtures/enemy_rabbit_source.json').read_text()))
        for row in data['return_cases']:
            self.assertEqual(len(row['hops']),3)
            for index,hop in enumerate(row['hops']):
                self.assertEqual(len(hop['samples']),10)
                self.assertEqual(hop['samples'][-1]['position'],hop['destination'])
                if index:self.assertEqual(hop['start'],row['hops'][index-1]['destination'])
            self.assertTrue(all(abs(signed(h-p))<=2 for h,p in zip(row['home'],row['hops'][-1]['destination'])))


if __name__=='__main__':
    if '--write-fixture' in sys.argv:
        (ROOT/'game/tests/fixtures/enemy_rabbit_source.json').write_text(json.dumps(witness(),separators=(',',':'))+'\n')
        sys.argv.remove('--write-fixture')
    unittest.main()
