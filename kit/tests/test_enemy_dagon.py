"""Independent static Dagon special, spin and return-camera evidence."""
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
import export_enemy_dagon as exporter
from test_physical_rune_export import independent_stream


class DagonSource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.packet=exporter.build();cls.raw,cls.origin=source('/G_DATA.BIN')

    def test_all_streams_and_frames_agree_with_independent_readers(self):
        main,_=source('MAIN.EXE')
        self.assertEqual(len(self.packet['programs']['programs']),7)
        for proof in self.packet['provenance']['programs']:
            span=proof['spans'][0];raw=main if span['source']['file']=='MAIN.EXE' else self.raw
            self.assertEqual(proof['operations'],independent_stream(raw,span['source_offset'],0x1e460 if raw is self.raw else None,0x80080000 if raw is self.raw else 0))
            for span in proof['spans']:
                self.assertEqual(hashlib.sha256(raw[span['source_offset']:span['source_offset']+span['byte_length']]).hexdigest(),span['sha256'])
        raw=self.raw;p=lambda off:int.from_bytes(raw[off:off+4],'little')-0x80080000
        resource=self.packet['animations']['resources'][0];section=p(0x1e420+44)
        frames,poses=p(section+20),p(section+16)
        for clip in resource['clips']:
            cursor=p(frames+4*clip['id']);expected=[]
            for i in range(max(1,raw[cursor])):
                pose,updates=raw[cursor+4+2*i:cursor+6+2*i];entry=p(poses+4*pose)
                expected.append(dict(pose=pose,updates=updates or 256,attachment=[raw[entry+6]-raw[entry+4],raw[entry+7]-raw[entry+5]]))
            self.assertEqual(clip['frames'],expected)

    def test_source_half_damage_poison_and_modulo_threshold_are_explicit(self):
        word=lambda off:struct.unpack_from('<I',self.raw,off)[0]
        for off,value in {0x298:0x30420002,0x2ac:0x8c42000c,0x2c4:0x00022fc2,
                0x2c8:0x8c630010,0x2cc:0x00a22821,0x2d0:0x0060f809,0x2d4:0x00052843,
                0x4cc:0x2863004c,0x4d0:0x1460000d,0x4fc:0xae020050}.items():self.assertEqual(word(off),value,hex(off))
        recipient=next(p for p in self.packet['provenance']['programs'] if p['id'].endswith('/special/recipient'))
        self.assertIn(dict(op=40,args=[0,30]),recipient['operations'])
        self.assertIn(dict(op=35,args=[2,5]),recipient['operations'])
        owner=next(p for p in self.packet['provenance']['programs'] if p['id'].endswith('/special/owner'))
        self.assertEqual([p['args'] for p in owner['operations'] if p['op']==26],[[0,2],[0,4]])
        self.assertEqual([self.packet['melee']['special'][k] for k in ('damage_numerator','damage_denominator','clear_contact_signal')],[1,2,False])
        self.assertEqual(self.packet['timing'],dict(contact_flag_update=79,contact_update=80,poison_update=80,return_flag_update=117,return_update=118))

    def test_complete_spin_is_a_relocated_wild_boar_callback(self):
        original,_=source('/A_DATA.BIN')
        for off in range(0,0x7c,4):
            a=struct.unpack_from('<I',original,0x8d4+off)[0];b=struct.unpack_from('<I',self.raw,0x530+off)[0]
            if a>>26 in (2,3):
                self.assertEqual(b>>26,a>>26)
                a=((a&0x3ffffff)<<2)-0x800808d4
                b=((b&0x3ffffff)<<2)-0x80080530
            self.assertEqual(a,b,hex(off))

    def test_return_camera_pointer_units_duration_and_consumer_match_raw_source(self):
        raw=self.raw;word=lambda off:struct.unpack_from('<I',raw,off)[0]
        self.assertEqual((word(0x1e8),word(0x1ec),word(0x1f4)),(0x3c04800a,0x2484e60c,0x3405000a))
        camera=self.packet['melee']['special']['return_camera']
        self.assertEqual(camera['updates'],10)
        self.assertEqual([x for key in ('position','angles','c','d') for x in camera['target'][key]],list(struct.unpack_from('<12i',raw,0x1e60c)))
        proof=self.packet['provenance']['return_camera']['setter'];main,_=source('MAIN.EXE')
        self.assertEqual(hashlib.sha256(main[proof['source_offset']:proof['source_offset']+proof['byte_length']]).hexdigest(),proof['sha256'])
        base=struct.unpack_from('<I',main,24)[0];word=lambda pc:struct.unpack_from('<I',main,2048+pc-base)[0]
        for pc,value in {0x800f7330:0x24720b40,0x800f7380:0x26510054,
                0x800f7384:0x8e220050,0x800f7394:0x0040f809,
                0x800de0e0:0x0040f809,0x800de1c8:0x0c03800d,
                0x800e003c:0x0c0383a8,0x800e0044:0x0c03826f}.items():self.assertEqual(word(pc),value,hex(pc))
        for proof in self.packet['provenance']['root_phase']:
            self.assertEqual(hashlib.sha256(main[proof['source_offset']:proof['source_offset']+proof['byte_length']]).hexdigest(),proof['sha256'])

    def test_repeatable_fixture_and_merge_refuse_changed_source_and_conflicts(self):
        self.assertEqual(self.packet,json.loads((ROOT/'game/tests/fixtures/enemy_dagon_source.json').read_text()))
        actors=json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text());before=copy.deepcopy(actors)
        combined=exporter.combine(actors,self.packet)
        self.assertEqual(actors,before);self.assertEqual(combined,exporter.combine(combined,self.packet))
        self.assertEqual(combined['unites'],before['unites'])
        changed=copy.deepcopy(self.packet);changed['melee']['special']['damage_numerator']=2
        with self.assertRaisesRegex(ValueError,'Conflicting Dagon'):exporter.combine(combined,changed)
        real=exporter.source
        for off in (0x2d4,0x4cc,0x1e60c,0x1e420+38):
            raw=bytearray(self.raw);raw[off]^=1
            with patch.object(exporter,'source',side_effect=lambda name:(bytes(raw),self.origin) if name=='/G_DATA.BIN' else real(name)):
                with self.assertRaises(ValueError):exporter.build()

    def test_normal_admission_retains_source_profile_rosters_and_independent_pixels(self):
        from PIL import Image
        from export_first_room import Atlas
        from test_export_unite_review import vram_pose
        from battle_placement import area_encounters
        import preparation
        import item_tables
        battle=json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text())
        actors=json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        added={f'area_g_{n}' for n in (1,2,3,6)}
        battle['enemies']=[e for e in battle['enemies'] if e['id']!='dagon']
        battle['encounters']=[e for e in battle['encounters'] if e['id'] not in added]
        battle['unite_graphics']=[g for g in battle['unite_graphics'] if g['id']!='dagon']
        atlas=Atlas();atlas.image=Image.new('RGBA',(4096,4096));atlas.y=4
        atlas.image.paste((17,31,49,255),(0,0,4096,3))
        proof=exporter.append_content(battle,actors,atlas)
        preparation.bind_weapon_elements(battle)
        self.assertEqual((battle['schema'],actors['schema']),('suikoden-battle-trial/43','suikoden-unite-actors/40'))
        self.assertEqual(atlas.image.getpixel((4095,2)),(17,31,49,255))
        self.assertEqual({r['id'] for r in proof['catalogue']['formations']},added)
        raw=self.raw;record=0x1e420;profile=battle['enemies'][-1]
        self.assertEqual(profile['action_policy'],'source_dagon')
        self.assertEqual(profile['level'],raw[record+16])
        self.assertEqual(profile['max_hp'],struct.unpack_from('<H',raw,record+18)[0])
        self.assertEqual(profile['stats'],dict(zip(('attack','skill','defense','speed','magic','luck'),struct.unpack_from('<6H',raw,record+20))))
        self.assertEqual(profile['effect_offset'],list(struct.unpack_from('<2h',raw,record+60)))
        encoded=struct.unpack_from('<h',raw,record+52)[0]
        self.assertEqual(profile['money'],int(encoded/10)*100 if encoded&1 else encoded)
        self.assertEqual(profile['knockout_ticks'],94)
        table=struct.unpack_from('<I',raw,record+40)[0]-exporter.BASE
        ko=independent_stream(raw,struct.unpack_from('<I',raw,table+28)[0]-exporter.BASE,table,exporter.BASE)
        self.assertEqual([op['args'] for op in ko if op['op']==3],[[1],[90],[1]])
        self.assertEqual([op['args'] for op in ko if op['op']==30],[[0],[99]])
        for i,element in enumerate(('fire','water','earth','lightning','wind')):
            self.assertEqual(profile['affinities'][element],('neutral','weak','resistant','immune')[raw[record+32+i]])
        self.assertEqual(profile['other_affinity'],('neutral','weak','resistant','immune')[raw[record+37]])
        self.assertTrue(profile['dodges_attacks'])
        self.assertFalse(profile['death_immune'] or profile['airborne'] or profile['unavoidable_attack'])
        items={row['id']:row for row in item_tables.items()}
        for drop,item,rate in zip(profile['drops'],raw[record+54:record+60:2],raw[record+55:record+60:2],strict=True):
            self.assertEqual(drop['rate'],rate)
            self.assertEqual(drop['item'],preparation.stable_id(items[item]['name']) if item else None)
            self.assertEqual(drop['identified'],not bool(item and item_tables.half(items[item]['addr']+28)&0x7000))
        native={1:'dagon',2:'grizzly_bear',3:'siren'};expected=set()
        for row in area_encounters(raw)['encounters']:
            if set(row['roster'])-{0}-set(native):continue
            identifier=f'area_g_{row["index"]}';expected.add(identifier)
            encounter=next(e for e in battle['encounters'] if e['id']==identifier)
            self.assertEqual(encounter['enemies'],[native[n] for n in row['roster'] if n])
            self.assertEqual(encounter['source_slots'],[s['slot'] for s in row['slots']])
        self.assertEqual({e['id'] for e in battle['encounters'] if e['id'].startswith('area_g_')},expected)
        graphic=next(g for g in battle['unite_graphics'] if g['id']=='dagon')
        for pose in graphic['poses']:
            image,ax,ay=vram_pose(raw,0x1e91c,pose['id'],packet=True,base=exporter.BASE)
            sprite=pose['sprite'];r=sprite['rect'];actual=atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
            self.assertEqual((actual.size,sprite['anchor_x'],sprite['anchor_y']),(image.size,ax,ay))
            self.assertEqual(actual.tobytes(),image.tobytes())
        with self.assertRaisesRegex(ValueError,'already present'):exporter.append_content(battle,actors,atlas)


if __name__=='__main__':unittest.main()
