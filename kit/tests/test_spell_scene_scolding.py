#!/usr/bin/env python3
"""Independent source operands and incremental Scolding quad reference equations."""
from pathlib import Path
import json
import hashlib
import struct
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from disc import extract
import spell_scene_scolding as scolding
import spell_scene_source as source
import battle_bin
import system_glyphs


class Scolding(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        exe=extract(17976,757760)
        cls.base,size=struct.unpack_from('<II',exe,24)
        cls.image=exe[2048:2048+size]

    def word(self,pc):return struct.unpack_from('<I',self.image,pc-self.base)[0]

    def test_raw_packet_and_copy_operands(self):
        anchors={0x80102E14:0x340432D8, 0x80102EDC:0x34050001,
                 0x80102EE8:0x340603C0, 0x80102EF0:0x34070100,
                 0x80102EF8:0x340403F0, 0x80102F00:0x340501F8,
                 0x80102F10:0xA2170014, 0x80102F20:0xA2170024,
                 0x80102F94:0x2694000C, 0x80102F98:0x2673000C,
                 0x80102FA4:0x26310090, 0x80103474:0x34093180,
                 0x80103478:0x26473210, 0x80103490:0xACE2006C,
                 0x80103500:0x2529FF70, 0x8010350C:0x24E7FF70,
                 0x8010354C:0x27C3FFFF, 0x80103550:0x10430092,
                 0x801033D4:0x34020046, 0x801033E0:0x34050005,
                 0x801033E8:0x0C0496CA, 0x801033F4:0x0C038595,
                 0x8014AEA4:0x3402002C, 0x8014AE20:0x34420001}
        for pc,expected in anchors.items():self.assertEqual(self.word(pc),expected,hex(pc))
        p=scolding.profile()
        self.assertEqual((p['phases'],p['impact'],p['release'],p['reaction']),([64,64,32,96],256,257,160))
        self.assertEqual(p['drawn_indices'],list(range(0,90,2)))
        self.assertEqual(p['texture']['uv'][42],[[0,248],[12,248],[0,4],[12,4]])
        self.assertFalse(p['texture']['semitransparent'])
        self.assertTrue(p['texture']['raw'])

    def test_all_updates_agree_with_separate_reverse_copy_integrator(self):
        def div0(n,d):return abs(n)//d*(-1 if n<0 else 1)
        positions=[(tuple(v*4096 for v in a),tuple(v*4096 for v in b)) for a,b in
                   [((120,50,0),(-128,-40,0)),((119,-51,7),(-127,39,45)),((-300,200,-31),(230,-110,10))]]
        positions.append(((491521,-208897,32769),(-520193,159745,184319)))
        for caster,target in positions:
            for height in (0,33,64,255):
                nodes=[dict(active=False,position=[0,204800,-131072],scale=[1,1,4096],angles=[0,0,0],width=24576) for _ in range(90)]
                velocity=None
                for update in range(258):
                    head=nodes[0]
                    if 65<=update<=128:
                        head['active']=True
                        head['scale'][0]+=64;head['scale'][1]+=64;head['angles'][2]+=64
                    if update==129:
                        target_words=list(target);target_words[2]-=height<<11
                        velocity=[div0(t-c-v,32) for t,c,v in zip(target_words,caster,head['position'])]
                    if 129<=update<=160:
                        head['position']=[a+b for a,b in zip(head['position'],velocity)];head['width']+=0xA00
                    if update==160:head['active']=False
                    if 0<update<256:
                        for i in range(89,0,-1):
                            nodes[i]['active']=nodes[i-1]['active']
                            if nodes[i]['active']:
                                for key in ('position','scale','angles'):nodes[i][key]=nodes[i-1][key].copy()
                                nodes[i]['width']=nodes[i-1]['width']
                    expected=[]
                    if update<256:
                        for i,node in enumerate(nodes):
                            if not node['active']:continue
                            width=node['width']>>12;half=div0(width,2)
                            expected.append(dict(index=i,drawn=not i%2,position=node['position'].copy(),scale=node['scale'].copy(),angles=node['angles'].copy(),width=width,
                                                 corners=[[half,half,0],[half,-half,0],[-half,half,0],[-half,-half,0]]))
                    self.assertEqual(scolding.trail_states(update,caster,target,height),expected,(update,caster,target,height))
        self.assertEqual([n['index'] for n in scolding.trail_states(65,(0,0,0),(1,1,1),33)],[0,1])
        self.assertTrue(scolding.trail_states(247,(0,0,0),(1,1,1),33))
        self.assertFalse(scolding.trail_states(249,(0,0,0),(1,1,1),33))

    def test_known_upload_witnesses_do_not_cover_quad_pixels(self):
        sections,_,errors,_=battle_bin.parse();self.assertFalse(errors)
        rects=[(640+64*(i%5),256+128*(i//5),64,128) for i in range(len(sections[2]['atlas_offsets']))]
        rects.extend(s['rect'] for s in system_glyphs.sources())
        p=scolding.profile();bx,by=p['texture']['page']
        for index in p['drawn_indices']:
            uv=p['texture']['uv'][index]
            for v in range(min(uv[0][1],uv[2][1]),max(uv[0][1],uv[2][1])+1):
                for x in range(bx,bx+4):
                    self.assertFalse(any(rx<=x<rx+w and ry<=by+v<ry+h for rx,ry,w,h in rects))
        # This checks only these upload witnesses, not absence of another producer.
        self.assertIsNone(p['texture']['pixel_source']);self.assertFalse(p['original_texture_ready'])
        self.assertTrue(p['workaround']['runtime_ready'])
        self.assertEqual(p['workaround']['donor'],dict(section=2,animation=4,piece=1))
        self.assertEqual(p['workaround']['visual_acceptance'],'user_accepted_2026-11-12')
        self.assertEqual(len(p['workaround']['accepted_preview_sha256']),64)

    def test_grid_upload_candidates_cover_two_distinct_page_halves(self):
        candidates=scolding.profile()['address_compatible_grid_uploads']
        self.assertEqual([(c['uploader'],c['counter']) for c in candidates],
                         [(0x800C3A44,50),(0x800C3A44,55),(0x800C3B54,50),(0x800C3B54,55)])
        # Independent queue packing: groups of twenty use five columns and four rows.
        for c in candidates:
            bank,within=divmod(c['counter'],20);row,column=divmod(within,5)
            width=64 if c['uploader']==0x800C3A44 else 32
            self.assertEqual(c['rect'],[320+(bank*5+column)*64,row*128,width,128])
            self.assertIsNone(c['queued_source'])
        for uploader in (0x800C3A44,0x800C3B54):
            pair=[c for c in candidates if c['uploader']==uploader]
            for v in range(256):
                owners=[c for c in pair if c['rect'][1]<=256+v<c['rect'][1]+c['rect'][3]]
                self.assertEqual(len(owners),1)
                self.assertEqual(owners[0]['counter'],50 if v<128 else 55)
        # Keeping this unknown prevents address compatibility from becoming an asset claim.
        self.assertIsNone(scolding.profile()['texture']['pixel_source'])
        for pc in (0x800C3AEC,0x800C3B90,0x800C3C28):
            raw=bytearray(self.image);struct.pack_into('<I',raw,pc-self.base,0)
            with self.assertRaises(ValueError):scolding.profile(source.Image(raw,self.base))

    def test_header_restore_routes_reuse_recorded_texture_origin(self):
        # Both restore routes read a section's assigned origin before clearing/rebuilding the queue.
        expected={0x8012D190:0x8C50001C,0x8012D194:0x8C420020,
                  0x8012D198:0x2610FFFE,0x8012D19C:0x00108080,
                  0x8012D1A0:0x02021021,0x8012D1A4:0x8C510000,
                  0x8012D1B8:0x92240006,0x8012D1BC:0x0C030E81,
                  0x8012D1C4:0x0C030DA9,0x8012D1E4:0x8C440000,
                  0x8012D1E8:0x0C030D40,0x8012D208:0x8E040004,
                  0x8012D20C:0x0C030D40,0x8012D214:0x0C030DB5,
                  0x8012D298:0x8C50000C,0x8012D2B8:0x92040006,
                  0x8012D2BC:0x0C030E81,0x8012D2C4:0x0C030DA9,
                  0x8012D2CC:0x0C030D40,0x8012D2D0:0x02002021,
                  0x8012D2D4:0x0C030DB5,
                  0x800C3A08:0xA0249030,0x800C3A18:0x80429030,
                  0x800C36B0:0xAC209028,0x800C36B4:0x0C030E85,
                  0x800C36C0:0xAC228F70,
                  0x800C3504:0x90428F70,0x800C350C:0x90639028,
                  0x800C352C:0x00431021,0x800C3530:0xA2220006}
        for pc,word in expected.items():self.assertEqual(self.word(pc),word,hex(pc))
        # Check the whole queue-reset helper: it cannot silently retain an earlier queue length.
        reset=[self.word(pc) for pc in range(0x800C36A4,0x800C36D4,4)]
        self.assertEqual([w for w in reset if w>>26==3],[0x0C030E85])
        stores=[w for w in reset if w>>26 in (40,41,43) and w>>21&31==1]
        self.assertEqual(stores,[0xAC209028,0xAC228F70])

    def test_screen_and_damage_number_vram_copies_end_before_sampled_strip(self):
        expected={0x800CA234:0x341000C0,0x800CA238:0xA7B00014,
                  0x800CA23C:0x341100F0,0x800CA240:0xA7B10016,
                  0x800CA250:0x34050280,0x800CA254:0x34060100,
                  0x800CA264:0x0C052196,0x800CA26C:0xA7B00010,
                  0x800CA270:0x34020080,0x800CA274:0xA7A20014,
                  0x800CA278:0xA7B10016,0x800CA288:0x34050340,
                  0x800CA28C:0x34060100,0x800CA29C:0x0C052196,
                  0x800E163C:0x28620014,0x800E1644:0x24840090,
                  0x800E16B4:0x0C038586,0x800E16BC:0x0040F021,
                  0x800E16C0:0x07C00017,0x800E1728:0x001E1100,
                  0x800E172C:0x24420280,0x800E1810:0x34120003,
                  0x800E1818:0x3415000A,0x800E1830:0x2453000C,
                  0x800E191C:0x34020004,0x800E1924:0xA7B50016,
                  0x800E192C:0x02602821,0x800E1930:0x0C052196,
                  0x800E1934:0x340601F0,0x800E1940:0x2652FFFF,
                  0x800E1944:0x0641FFBB,0x800E1948:0x2673FFFC}
        for pc,word in expected.items():self.assertEqual(self.word(pc),word,hex(pc))
        copies=[(640,256,192,240),(832,256,128,240)]
        # Enumerate all reserved number slots and four right-to-left digit positions.
        copies.extend((640+16*slot+4*digit,496,4,10) for slot in range(20) for digit in range(4))
        sampled={(960+x,256+y) for x in range(4) for y in range(256)}
        for x,y,w,h in copies:
            self.assertLessEqual(x+w,960)
            self.assertFalse(any((xx,yy) in sampled for xx in range(x,x+w) for yy in range(y,y+h)))
        self.assertEqual(max(x+w for x,y,w,h in copies),960)

    def test_packet_vertices_against_independent_table_and_projection(self):
        table=struct.unpack_from('<8192h',self.image,0x801725BC-self.base)
        def trig(angle):
            i=(abs(angle)&4095)*2
            return table[i]*(-1 if angle<0 else 1),table[i+1]
        def short(v):return (v+32768)%65536-32768
        cameras=[(0,0,0,-768,0,608,0,0,1024,4096,4096,4096),
                 (80,0,0,-768,0,608,0,0,1024,4864,4864,4864),
                 (-80,0,0,-768,0,608,0,0,1024,4864,4864,4864),
                 (12,-7,3,-512,0,-97,17,-19,500,3000,4200,3900)]
        for camera in cameras:
            sx,cx=trig(camera[3]);sz,cz=trig(camera[5])
            matrix=[[cz,-sz,0],[(sz*cx)>>12,(cz*cx)>>12,-sx],
                    [(sz*sx)>>12,(cz*sx)>>12,cx]]
            matrix=[[v*camera[9+j]>>12 for j,v in enumerate(row)] for row in matrix]
            def project(point):
                view=[((camera[6+i]<<12)+sum(v*p for v,p in zip(row,point)))>>12 for i,row in enumerate(matrix)]
                return [max(-1024,min(1023,v*1024//max(512,view[2]))) for v in view[:2]]+[view[2]]
            zero=project((0,0,0));focus=project(camera[:3]);bias=[160+zero[0]-focus[0],120+zero[1]-focus[1]]
            for caster,target,height in [((491521,-208897,32769),(-520193,159745,184319),33),
                                         ((-134213632,819200,-126976),(942080,-450560,40960),255)]:
                for update in range(258):
                    expected=[]
                    for node in scolding.trail_states(update,caster,target,height):
                        if node['index']%2:continue
                        s,c=trig(node['angles'][2]);scale=node['scale']
                        local=[short(v>>12) for v in node['position']]
                        # Original Z rotation, column scaling, then integer caster translation.
                        r=[[c*scale[0]>>12,-s*scale[1]>>12,0],
                           [s*scale[0]>>12,c*scale[1]>>12,0],[0,0,scale[2]]]
                        world=[short((caster[i]>>12)+(sum(v*p for v,p in zip(row,local))>>12)) for i,row in enumerate(r)]
                        center=project(world);half=node['width']//2;vertices=[]
                        for corner in ((half,half,0),(half,-half,0),(-half,half,0),(-half,-half,0)):
                            offset=project(corner)
                            vertices.append([short(center[i]+bias[i]+offset[i]) for i in range(2)])
                        index=node['index']
                        expected.append(dict(index=index,vertices=vertices,depth=max(0,min(65535,center[2]))//4,
                                             uv=[[0,12*index%256],[12,12*index%256],
                                                 [0,12*(index+1)%256],[12,12*(index+1)%256]]))
                    self.assertEqual(scolding.quad_geometry(update,caster,target,height,camera),expected,(camera,update))

    def test_replacement_glow_preserves_every_source_trail_boundary(self):
        from PIL import Image
        from spell_scene_player import Player
        import spell_effect_sweep
        effect=next(e for e in spell_effect_sweep.build()['effects'] if e['name']=='Scolding')
        program=scolding.program(effect,[0,1])
        self.assertEqual((program['impact'],program['duration']),(256,257))
        self.assertEqual([o['start'] for o in program['objects'][1:]],list(range(0,90,2)))
        self.assertEqual([(c['at'],c['updates']) for c in program['cameras']],[(1,60),(97,60)])
        packet=dict(entries=[dict(x=0,y=0,w=64,h=64,dx=-32,dy=-32)]*2,pieces=[[0],[1]],
                    spells=[dict(id='spell_5',name='Scolding',program=program)])
        for caster,target,height in [((120,50,0),(-128,-40,0),33),((-300,200,-31),(230,-110,10),255)]:
            player=Player(packet,'spell_5',Image.new('RGBA',(64,64)))
            for update in range(258):
                frame=player.frame(update,caster,target,target_height=height)
                trail=[c for c in frame['commands'] if c.get('texture')==1]
                expected=scolding.quad_geometry(update,[v*4096 for v in caster],[v*4096 for v in target],height,frame['camera'])
                self.assertEqual([c['vertices'] for c in trail],[c['vertices'] for c in expected],(caster,update))
                self.assertEqual([c['depth'] for c in trail],[c['depth'] for c in expected],(caster,update))
                self.assertTrue(all(c['blend']=='additive' for c in trail))
                self.assertEqual(player.draw_count,0)
                self.assertEqual(frame['wash'],[max(0,(5461*min(update,64)-3413*min(max(update-160,0),96))>>12)]*2+
                    [max(0,(4369*min(update,64)-2730*min(max(update-160,0),96))>>12)] if update<256 else [0]*3)

    def test_projection_calls_restore_scene_matrix_before_all_four_offsets(self):
        expected={0x80103580:0x0C053A94,0x8010358C:0x0C053F2D,0x80103598:0x0C053CFB,
                  0x801035D0:0xA7A20018,0x801035E0:0xA7A2001A,0x801035F8:0xA7A2001C,
                  0x801035A4:0x0C053CF2,0x801035F4:0x0C053D91,0x80103610:0x0C053ABC,
                  0x80103624:0x0C053D71,0x8010367C:0x0C053D71,0x801036C4:0x0C053D71,
                  0x801036FC:0x0C053D71,0x80103734:0x0C053D71,
                  0x8010375C:0x00139880,0x8014F5EC:0x00021083}
        for pc,value in expected.items():self.assertEqual(self.word(pc),value,hex(pc))
        for camera in ([],[0]*11,[0]*11+[32768],[0]*11+[1.5]):
            with self.assertRaises(ValueError):scolding.quad_geometry(65,(0,0,0),(1,1,1),33,camera)

    def test_changed_source_and_invalid_inputs_fail(self):
        for pc in (0x80102EE8,0x801032B4,0x80103550,0x8014AE20):
            raw=bytearray(self.image);struct.pack_into('<I',raw,pc-self.base,0)
            with self.assertRaises(ValueError):scolding.profile(source.Image(raw,self.base))
        for args in [(-1,(0,0,0),(0,0,0),64),(258,(0,0,0),(0,0,0),64),(0,(0,0,0),(0,0,0),256),(0,(40000*4096,0,0),(0,0,0),1),(0,(0,0,0),(0,0,0),3.5)]:
            with self.assertRaises(ValueError):scolding.trail_states(*args)

    def test_loading_and_menu_upload_domains_do_not_cover_sampled_strip(self):
        loading=extract(18743,114116)
        def word(pc):return struct.unpack_from('<I',loading,pc-0x80010000)[0]
        # RECT stores and both indirect LoadImage calls, independently read off disc.
        for pc,value in {0x8001043C:0x34020380,0x80010440:0xA7A20010,
                         0x80010444:0x34030080,0x80010448:0xA7A30012,
                         0x8001044C:0x34020040,0x80010450:0xA7A20014,
                         0x80010454:0xA7A30016,0x80010460:0x8C420070,
                         0x8001046C:0x0040F809,0x8001047C:0xA7A00010,
                         0x80010480:0x340201FF,0x80010488:0x34020100,
                         0x80010490:0x34020001,0x800104A4:0x8C420070,
                         0x800104B0:0x0040F809}.items():self.assertEqual(word(pc),value,hex(pc))
        self.assertEqual(self.word(0x80165608+0x70),0x80148590)
        report=scolding.profile()['checked_upload_domains']
        # The source divides the monotonically increasing index by3, masks the
        # quotient's shifted low byte, and masks the remainder's shifted bits.
        rects=set()
        for index in range(256*3):
            quotient,remainder=divmod(index,3)
            rects.add((832+((remainder*32)&96),128+((quotient*64)&255),32,64))
        self.assertEqual(rects,{tuple(r) for r in report[0]['rectangles']})
        self.assertEqual(report[1]['rectangles'],[[896,128,64,128]])
        self.assertEqual(report[2]['rectangles'],[[0,511,256,1]])
        for route in report:
            self.assertFalse(route['sampled_strip_overlap'])
            for x,y,w,h in route['rectangles']:
                self.assertFalse(x<964 and x+w>960 and y<512 and y+h>256)
        for offset in (0x43C,0x460,0x4A4):
            changed=bytearray(loading);changed[offset]^=1
            with self.assertRaises(ValueError):scolding.other_upload_witnesses(source.Image(self.image,self.base),changed)

    def test_standard_entry_budget_matches_independent_pointer_queue(self):
        budget=scolding.profile()['battle_entry_texture_budget']
        files=json.loads((ROOT/'kit/extracted/iso_files.json').read_text())
        players=[r for r in files if r['path'].startswith('DATA/04_PLAY/') and r['path'].endswith('.BIN')]
        self.assertEqual(len(players),78)
        self.assertEqual({r['path'] for r in players},{r['file'] for r in budget['players']})
        party_pages=[]
        for rec in players:
            data=extract(rec['lba'],rec['size']);off=struct.unpack_from('<I',data,0x24)[0]
            row=next(r for r in budget['players'] if r['file']==rec['path'])
            self.assertEqual((off,data[off+4]),(row['section_offset'],row['pages']))
            self.assertEqual(row['sha256'],hashlib.sha256(data).hexdigest())
            self.assertEqual(row['pages'],2);party_pages.append(data[off+4])
        shared=extract(budget['shared']['lba'],budget['shared']['size'])
        section=struct.unpack_from('<I',shared)[0]-0x800AA000
        self.assertEqual(shared[section+4],3)
        self.assertEqual(budget['shared']['sha256'],hashlib.sha256(shared).hexdigest())
        total=0;maximum=0;nulls=[]
        for row in budget['areas']:
            data=extract(row['lba'],row['size']);base=0x80080000
            self.assertEqual(row['sha256'],hashlib.sha256(data).hexdigest())
            def word(address):return struct.unpack_from('<I',data,address-base)[0]
            def enqueue(queue,header):
                if not header:return
                table=word(header+8)
                for i in range(data[header-base+4]):queue.append(word(table+4*i))
            root=word(base);resources=word(root+12);directory=word(resources) if resources else 0
            if not directory:
                self.assertEqual(row['status'],'null_battle_directory');nulls.append(row['file']);continue
            selectors=word(directory+8);enemy_table=word(directory+12)
            self.assertEqual(word(selectors),len(row['formations']))
            for form in row['formations']:
                queue=[];enqueue(queue,word(directory))
                # Six arbitrary playable actors each upload their two pages.
                for actor in range(6):queue.extend([None]*party_pages[actor])
                record=word(selectors+4*(form['index']+1));seen=[]
                for identifier in data[record-base+4:record-base+10]:
                    if identifier and identifier not in seen:
                        seen.append(identifier);enqueue(queue,word(word(enemy_table+4*identifier)+44))
                queue.extend([None]*shared[section+4]);enqueue(queue,word(directory+4))
                self.assertEqual(len(queue),form['pages_upper'])
                for counter in range(len(queue)):
                    x=320+64*(5*(counter//20)+counter%5);y=128*((counter%20)//5)
                    self.assertFalse(x<964 and x+64>960 and y<512 and y+128>256)
                total+=1;maximum=max(maximum,len(queue))
        self.assertEqual((total,maximum,budget['counter_range']),(90,24,[0,23]))
        self.assertEqual({Path(f).name for f in nulls},{'J_DATA.BIN','K_DATA.BIN'})
        for pc,value in {0x800DE670:0x0C030E81,0x800DE674:0x00002021,
                         0x800DECA4:0x0C030D40,0x800DEF80:0x1046000B,
                         0x800DEFA4:0x0C030D40,0x800DF188:0x0C030D40,
                         0x800DF254:0x0C030D40,0x800E7A44:0x0C030D9C,
                         0x800C3418:0x0C030E91,0x800C3458:0x0C030E91,
                         0x800C346C:0x24420001}.items():self.assertEqual(self.word(pc),value,hex(pc))
        first=players[0]
        def malformed(lba,size,*args,**kwargs):
            data=extract(lba,size,*args,**kwargs)
            if lba==first['lba']:
                data=bytearray(data);struct.pack_into('<I',data,0x24,len(data)-23)
            return data
        with patch('disc.extract',side_effect=malformed):
            with self.assertRaises(ValueError):scolding.battle_entry_texture_budget()

    def test_field_candidate_queue_bound_keeps_script_aliases_explicit(self):
        import area_scene
        import section_records
        files=json.loads((ROOT/'kit/extracted/iso_files.json').read_text())
        players=[r for r in files if r['path'].startswith('DATA/04_PLAY/') and r['path'].endswith('.BIN')]
        for rec in players:
            data=extract(rec['lba'],rec['size']);field=struct.unpack_from('<I',data,0x28)[0]
            self.assertEqual(data[field+4],1,rec['path'])
        self.assertEqual(len(players),78)
        rooms=0;checked=0;files_with_rooms=0;maximum=0;probe_aliases=[]
        for rec in section_records.population():
            if not rec['path'].split('/')[-1].startswith('V') or '/04_PLAY/' in rec['path']:continue
            data=extract(rec['lba'],rec['size']);validated=area_scene.room_records(data)
            if not validated:continue
            files_with_rooms+=1
            def rd(offset):return struct.unpack_from('<I',data,offset)[0]
            def ptr(offset):return rd(offset)-0x80010000
            root=ptr(0);sections=ptr(root+4);room_table=ptr(root+8)
            for room in validated:
                rooms+=1
                section=ptr(sections+4*data[room_table+16*room['index']+5])
                count=rd(section+28);context_table=ptr(section+32)
                headers=[section]+[ptr(context_table+4*i) for i in range(count)]
                owned=[(data,h,0x80010000) for h in headers]
                address=rd(root+12)
                if address:
                    if 0x80010000<=address<0x80010000+len(data):owned.append((data,address-0x80010000,0x80010000))
                    else:
                        # Load-group15 supplies VC6's shared context from VC61.
                        self.assertEqual(rec['path'],'DATA/06_AREA.C/VC6.BIN')
                        companion=next(r for r in files if r['path']=='DATA/06_AREA.C/VC61.BIN')
                        blob=extract(companion['lba'],companion['size'])
                        self.assertEqual(address,0x80086894)
                        self.assertEqual(blob[address-0x80080000+4],1)
                        owned.append((blob,address-0x80080000,0x80080000))
                total=sum(blob[h+4] for blob,h,_ in owned)
                queue=[];unknown=False
                for blob,header,base in owned:
                    table=struct.unpack_from('<I',blob,header+8)[0]-base
                    if blob[header+4] and not 0<=table<=len(blob)-4*blob[header+4]:
                        probe_aliases.append((rec['path'],room['index'],header));unknown=True;break
                    for page in range(blob[header+4]):queue.append(struct.unpack_from('<I',blob,table+4*page)[0])
                if unknown:continue
                self.assertEqual(total,len(queue),(rec['path'],room['index']))
                self.assertLessEqual(total,31,(rec['path'],room['index']))
                checked+=1;maximum=max(maximum,total)
        self.assertEqual((files_with_rooms,rooms,checked,maximum),(86,1177,1175,31))
        self.assertEqual(probe_aliases,[('DATA/11_AREA.H/VH1.BIN',46,0xB5C8),('DATA/11_AREA.H/VH1.BIN',59,0x5314)])
        # These two party loaders reset to30 and queue the field section at+28.
        for pc,value in {0x80128BB4:0x0C030E81,0x80128BB8:0x3404001E,
                         0x80128BF0:0x8C440028,0x80128BF4:0x0C030D40,
                         0x80132428:0x0C030E81,0x8013242C:0x3404001E,
                         0x80132470:0x8C440028,0x80132474:0x0C030D40,
                         0x80132164:0x0C030E81,0x80132168:0x00002021,
                         0x8013218C:0x0C030DC1,0x800C3724:0x0C030E85,
                         0x800C3730:0xA2220006,0x800C3778:0xAC620000,
                         0x8013231C:0x0C030D40,0x80132360:0x0C030D40}.items():
            self.assertEqual(self.word(pc),value,hex(pc))
        self.assertLess(30+6,50)

    def test_vh1_probe_aliases_overlap_scripts_and_select_secondary_headers(self):
        import area_scene
        import event_script_reachability as graph
        files=json.loads((ROOT/'kit/extracted/iso_files.json').read_text())
        rec=next(r for r in files if r['path']=='DATA/11_AREA.H/VH1.BIN')
        data=extract(rec['lba'],rec['size']);base=0x80010000
        def word(offset):return struct.unpack_from('<I',data,offset)[0]
        root=word(0)-base;sections=word(root+4)-base;rooms=word(root+8)-base
        entities=word(rooms)-base
        roots=[word(entities+24*i+20)-base for i in (5,7)]
        self.assertEqual(roots,[0x495B0,0x4967C])
        decoded=graph.walk(data,roots)
        self.assertFalse(decoded['frontier'])
        self.assertEqual((rooms+46*16,rooms+59*16),(0x495B0,0x49680))
        for offset,opcode,end in ((0x495B0,0x10,0x495B3),(0x495B5,0x1C,0x495B9),
                                  (0x4967F,0x0B,0x49681),(0x49681,0x1C,0x49685),
                                  (0x49687,0x32,0x49696)):
            node=next(n for n in decoded['nodes'] if n['offset']==offset)
            self.assertEqual((node['opcode'],node['end']),(opcode,end))
        for probe,owner,secondary,expected in ((46,15,28,0xB5C8),(59,1,2,0x5314)):
            self.assertEqual(data[rooms+probe*16+5],secondary)
            self.assertEqual(data[rooms+owner*16+9],secondary)
            self.assertEqual(data[rooms+owner*16+8]&1,1)
            primary=word(sections+4*data[rooms+owner*16+5])-base
            header=word(sections+4*secondary)-base
            self.assertEqual(header,expected)
            self.assertNotEqual(word(primary+8),0)
            self.assertEqual(word(header+8),0)
        # Secondary construction keeps primary materials and replaces map/dimensions.
        for pc,value in {0x801321D0:0x90420009,0x801321F8:0x8C84AAE4,
                         0x801321FC:0x8C660008,0x80132208:0x0C031145,
                         0x80132220:0x8C420018,0x80132228:0xAC62000C,
                         0x8013222C:0x96020000,0x80132234:0xA4620002,
                         0x80132238:0x96020002,0x80132240:0xA4620004}.items():
            self.assertEqual(self.word(pc),value,hex(pc))
        self.assertEqual(self.word(0x800C4530),0xACA60008)
        helper=[self.word(pc) for pc in range(0x800C4514,0x800C45A0,4)]
        self.assertFalse(any(w>>26 in (2,3) for w in helper))
        self.assertEqual([w for w in helper if w>>26==0 and w&63 in (8,9)],[0x03E00008])
        self.assertEqual({(w>>21&31,w&65535) for w in helper if w>>26 in (32,33,35,36,37)},
                         {(4,0),(4,2),(4,20)})
        # These are positive ownership witnesses, not a complete selectable-room proof.
        self.assertTrue(any(r['index']==46 for r in area_scene.room_records(data)))

    def test_report_is_current(self):
        self.assertEqual(json.loads((ROOT/'kit/data/reports/spell_scolding_quads.json').read_text()),scolding.profile())
        self.assertEqual(json.loads((ROOT/'game/tests/fixtures/scolding_projection.json').read_text()),scolding.geometry_fixture())


if __name__=='__main__':unittest.main()
