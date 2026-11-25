"""Independent static Whip Wolf scripts and complete relocated order consumers."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_first_room import source
from test_physical_rune_export import independent_stream
import export_enemy_whip_wolf as exporter


class WhipWolfSource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.packet=exporter.build();cls.raw,cls.origin=source('/E_DATA.BIN')

    def test_all_streams_frames_and_flags_agree_with_independent_readers(self):
        self.assertEqual(len(self.packet['programs']['programs']),6)
        main,_=source('MAIN.EXE')
        for row in self.packet['provenance']['programs']:
            span=row['spans'][0];raw=main if span['source']['file']=='MAIN.EXE' else self.raw
            self.assertEqual(row['operations'],independent_stream(raw,span['source_offset'],0x1ecbc if raw is self.raw else None,exporter.BASE if raw is self.raw else 0))
            for span in row['spans']:
                self.assertEqual(hashlib.sha256(raw[span['source_offset']:span['source_offset']+span['byte_length']]).hexdigest(),span['sha256'])
        raw=self.raw;p=lambda off:int.from_bytes(raw[off:off+4],'little')-exporter.BASE
        section=p(0x1ec7c+44);frames,poses=p(section+20),p(section+16)
        for clip in self.packet['animations']['resources'][0]['clips']:
            cursor=p(frames+4*clip['id']);expected=[]
            for i in range(max(1,raw[cursor])):
                pose,updates=raw[cursor+4+2*i:cursor+6+2*i];entry=p(poses+4*pose)
                expected.append(dict(pose=pose,updates=updates or 256,attachment=[raw[entry+6]-raw[entry+4],raw[entry+7]-raw[entry+5]]))
            self.assertEqual(clip['frames'],expected)
            for key,mask in (('advances',1),('loop',2),('semitransparent',4)):self.assertEqual(clip[key],bool(raw[cursor+1]&mask))

    def test_whole_order_strike_and_return_match_beast_commander_after_relocation(self):
        original,_=source('/B_DATA.BIN')
        for left,right,size,patches in ((0x11b0,0x338,0x1c4,{0x174:0x244204fc}),
                (0x1374,0x4fc,0xe8,{0xbc:0x246305e4}),(0x145c,0x5e4,0x98,{})):
            for off in range(0,size,4):
                a=struct.unpack_from('<I',original,left+off)[0];b=struct.unpack_from('<I',self.raw,right+off)[0]
                if off in patches:
                    self.assertEqual(a,{0x11b0:0x24421374,0x1374:0x2463145c}[left])
                    self.assertEqual(b,patches[off]);continue
                if a>>26 in (2,3):
                    self.assertEqual(a>>26,b>>26)
                    a=(((exporter.BASE+left+off+4)&0xf0000000)|((a&0x3ffffff)<<2))-(exporter.BASE+left)
                    b=(((exporter.BASE+right+off+4)&0xf0000000)|((b&0x3ffffff)<<2))-(exporter.BASE+right)
                self.assertEqual(a,b,(hex(right),hex(off)))

    def test_selector_and_order_boundaries_have_independent_raw_operands(self):
        word=lambda off:struct.unpack_from('<I',self.raw,off)[0]
        for off,value in {0x1dc:0x90420044,0x1e4:0x2c420004,0x1e8:0x1440000f,
                0x1fc:0x3c06800a,0x200:0x24c6ed74,0x210:0x24420338,
                0x240:0x92420005,0x250:0x92620045,0x290:0x0062001a,0x2b8:0x00001812,
                0x2c0:0x28630033,0x2f0:0xae35125c,0x30c:0x2402ffff,
                0x380:0x30420002,0x3c0:0x90420046,0x3e4:0x90420005,
                0x428:0x90620044,0x430:0x16220002,0x4c8:0x3402003c}.items():self.assertEqual(word(off),value,hex(off))
        # Both skipped guards advance before the next read; acceptance uses division, not remainder.
        self.assertEqual([draw*100//32767>=51 for draw in (51,16711,16712,32767)],[False,False,True,True])
        self.assertEqual(self.packet['timing'],dict(order_flag_update=21,launch_update=22,owner_duration=168))
        order=next(row for row in self.packet['provenance']['programs'] if row['id'].endswith('/order'))
        self.assertEqual([r['args'] for r in order['operations'] if r['op']==26],[[0,2]])
        self.assertIn(dict(op=9,args=[0]),order['operations'])

    def test_changed_source_and_conflicting_merge_refuse_and_fixture_reproduces(self):
        self.assertEqual(self.packet,json.loads((ROOT/'game/tests/fixtures/enemy_whip_wolf_source.json').read_text()))
        actors=json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text());before=copy.deepcopy(actors)
        combined=exporter.combine(actors,self.packet)
        self.assertEqual(before,actors);self.assertEqual(exporter.combine(combined,self.packet),combined)
        self.assertEqual(combined['unites'],before['unites']);self.assertEqual(combined['commander'],before['commander'])
        changed=copy.deepcopy(self.packet);changed['order']['selection_delay']=61
        with self.assertRaisesRegex(ValueError,'Conflicting Whip Wolf'):exporter.combine(combined,changed)
        real=exporter.source
        for off in (0x1e4,0x2b8,0x430,0x578,0x61c,0x1ec7c+38):
            raw=bytearray(self.raw);raw[off]^=1
            with patch.object(exporter,'source',side_effect=lambda name:(bytes(raw),self.origin) if name=='/E_DATA.BIN' else real(name)):
                with self.assertRaises(ValueError):exporter.build()

    def test_normal_admission_retains_source_profile_complete_e_rosters_and_independent_pixels(self):
        from PIL import Image
        from export_first_room import Atlas
        from test_export_unite_review import vram_pose
        from battle_placement import area_encounters
        import preparation
        import item_tables
        battle=json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text())
        actors=json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        battle['enemies']=[e for e in battle['enemies'] if e['id']!='whip_wolf']
        battle['encounters']=[e for e in battle['encounters'] if e['id']!='area_e_1']
        battle['unite_graphics']=[g for g in battle['unite_graphics'] if g['id']!='whip_wolf']
        atlas=Atlas();atlas.image=Image.new('RGBA',(4096,4096));atlas.y=4
        atlas.image.paste((17,31,49,255),(0,0,4096,3))
        proof=exporter.append_content(battle,actors,atlas)
        preparation.bind_weapon_elements(battle)
        self.assertEqual((battle['schema'],actors['schema']),('suikoden-battle-trial/43','suikoden-unite-actors/40'))
        self.assertEqual(atlas.image.getpixel((4095,2)),(17,31,49,255))
        self.assertEqual([r['id'] for r in proof['catalogue']['formations']],['area_e_1'])
        raw=self.raw;record=0x1ec7c;profile=battle['enemies'][-1]
        self.assertEqual((profile['action_policy'],profile['target_policy']),('source_whip_wolf','any_row'))
        self.assertEqual(profile['level'],raw[record+16])
        self.assertEqual(profile['max_hp'],struct.unpack_from('<H',raw,record+18)[0])
        self.assertEqual(profile['stats'],dict(zip(('attack','skill','defense','speed','magic','luck'),struct.unpack_from('<6H',raw,record+20))))
        self.assertEqual(profile['effect_offset'],list(struct.unpack_from('<2h',raw,record+60)))
        encoded=struct.unpack_from('<h',raw,record+52)[0]
        self.assertEqual(profile['money'],int(encoded/10)*100 if encoded&1 else encoded)
        self.assertEqual(profile['knockout_ticks'],94)
        table=struct.unpack_from('<I',raw,record+40)[0]-exporter.BASE
        ko=independent_stream(raw,struct.unpack_from('<I',raw,table+28)[0]-exporter.BASE,table,exporter.BASE)
        self.assertEqual([r['args'] for r in ko if r['op']==3],[[1],[90],[1]])
        self.assertEqual([r['args'] for r in ko if r['op']==30],[[0],[99]])
        for i,element in enumerate(('fire','water','earth','lightning','wind')):
            self.assertEqual(profile['affinities'][element],('neutral','weak','resistant','immune')[raw[record+32+i]])
        self.assertEqual(profile['other_affinity'],('neutral','weak','resistant','immune')[raw[record+37]])
        self.assertTrue(profile['dodges_attacks'])
        self.assertFalse(profile['death_immune'] or profile['airborne'] or profile['unavoidable_attack'])
        items={row['id']:row for row in item_tables.items()}
        for drop,item,rate in zip(profile['drops'],raw[record+54:record+60:2],raw[record+55:record+60:2],strict=True):
            self.assertEqual(drop['rate'],rate)
            self.assertEqual(drop['item'],preparation.stable_id(items[item]['name']) if item else None)
        native={1:'whip_wolf',2:'sorcerer',3:'hell_hound',4:'grave_master'};expected=set()
        for row in area_encounters(raw)['encounters']:
            if set(row['roster'])-{0}-set(native):continue
            identifier=f'area_e_{row["index"]}';expected.add(identifier)
            encounter=next(e for e in battle['encounters'] if e['id']==identifier)
            self.assertEqual(encounter['enemies'],[native[n] for n in row['roster'] if n])
            self.assertEqual(encounter['source_slots'],[s['slot'] for s in row['slots']])
        self.assertEqual({e['id'] for e in battle['encounters'] if e['id'].startswith('area_e_')},expected)
        graphic=next(g for g in battle['unite_graphics'] if g['id']=='whip_wolf')
        self.assertEqual(len(graphic['poses']),8)
        for pose in graphic['poses']:
            image,ax,ay=vram_pose(raw,0x1f044,pose['id'],packet=True,base=exporter.BASE)
            sprite=pose['sprite'];r=sprite['rect'];actual=atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
            self.assertEqual((actual.size,sprite['anchor_x'],sprite['anchor_y']),(image.size,ax,ay))
            self.assertEqual(actual.tobytes(),image.tobytes())
        with self.assertRaisesRegex(ValueError,'already present'):exporter.append_content(battle,actors,atlas)

    def test_weapon_element_binding_raises_older_schemas_and_preserves_newer_versions(self):
        import preparation
        for before,after in ((None,33),(32,33),(33,33),(40,40),(41,41)):
            content=dict(party=[])
            if before is not None:content['schema']=f'suikoden-battle-trial/{before}'
            preparation.bind_weapon_elements(content)
            self.assertEqual(content['schema'],f'suikoden-battle-trial/{after}')
        for value in ('unknown/40','suikoden-battle-trial/invalid',None):
            with self.assertRaises(ValueError):preparation.bind_weapon_elements(dict(party=[],schema=value))


if __name__=='__main__':unittest.main()
