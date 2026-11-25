"""Independent source scripts, callback consumers and appended impact pixels."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from PIL import Image

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import battle_bin
import character_table
import export_party_ranged_actors as exporter
import export_spell_scenes
from export_first_room import source
from test_physical_rune_export import independent_stream
from test_export_unite_review import vram_pose
import preparation


class PartyMeleeExport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.packet,cls.proof=exporter.build(melee=True,include_later=True)

    def test_all_59_body_attack_identities_and_four_script_roles_match_raw_sources(self):
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        word=lambda address:struct.unpack_from('<I',main,2048+address-base)[0]
        records={preparation.stable_id(r['name']):r for r in character_table.records()}
        expected={id for id,r in records.items() if main[2048+word(0x80165890+4*r['weapon_id'])-base+0x56]&1}
        self.assertEqual(len(expected),58)
        self.assertEqual({r['id'] for r in self.packet['bindings']},expected|{'kasumi'})
        self.assertEqual([r['id'] for r in self.proof['excluded']],['clive'])
        ranged,_=exporter.build()
        current=json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text())
        self.assertTrue({r['id'] for r in current['party']}<={r['id'] for r in self.packet['bindings']+ranged['bindings']})
        for row in self.proof['characters']:
            raw,origin=source('/'+records[row['id']]['sprite_file']);table=struct.unpack_from('<I',raw,32)[0]
            self.assertEqual(row['resource']['source'],origin)
            for role,slot in (('attack',1),('return',4),('hurt',2),('critical_hurt',8)):
                p=next(p for p in row['programs'] if p['id'].endswith('/'+role))
                self.assertEqual(p['operations'],independent_stream(raw,struct.unpack_from('<I',raw,table+4*slot)[0],table))
                for span in p['spans']:
                    self.assertEqual(hashlib.sha256(raw[span['source_offset']:span['source_offset']+span['byte_length']]).hexdigest(),span['sha256'])

    def test_complete_callback_windows_and_attacker_owned_recipient_slots(self):
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        for block in self.proof['ordinary_callbacks']:
            self.assertEqual(hashlib.sha256(main[block['source_offset']:block['source_offset']+block['byte_length']]).hexdigest(),block['sha256'])
        for address,word in ((0x800f48f0,0x8c460004),(0x800f5a64,0x8c460008),
                             (0x800f5bc4,0x8c460020),(0x800f5c88,0x8c46000c),(0x800f5d68,0x8c460010)):
            self.assertEqual(struct.unpack_from('<I',main,2048+address-base)[0],word)
        self.assertEqual(len(self.proof['ordinary_callbacks']),5)

    def test_queued_dispatch_retargets_before_readiness_without_repeating_menu_range(self):
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        word=lambda address:struct.unpack_from('<I',main,2048+address-base)[0]
        for first,last,digest in (
            (0x800f491c,0x800f4d5c,'4cc14fed993b896003f4dc8f5f6388439bcb104636bbe210eed07778692523a9'),
            (0x800f8604,0x800f8680,'5289d8bb85b4d7b09dd9f97c1384823bbd537929ec055690cd411b05539cfa04'),
            (0x800f8680,0x800f86f0,'e21307f7a85d15f6ed8643e759aea9352c7d82fe0d292a26308d5c587d1458fb'),
            (0x800eec20,0x800eedd0,'31f6218e1decccea11aa98a204888b5563247575daa900cc9b54804095ec9a50')):
            self.assertEqual(hashlib.sha256(main[2048+first-base:2048+last-base]).hexdigest(),digest)
        for address,expected in {
            0x800f49b8:0x0c03e1a0, # validate the queued recipient
            0x800f49c0:0x1040001c, # valid -> readiness
            0x800f49e4:0x8c83001c, # invalid -> party count +1
            0x800f49ec:0x24700001,
            0x800f49fc:0x0c03e1a0, # same validator for every enemy slot
            0x800f4a04:0x104000c3, # first valid survivor -> replacement store
            0x800f4d28:0xa0500049,
            0x800f4d2c:0x00001021, # retry without consuming the action
            0x800f4a40:0x0c03e181, # valid but locked -> wait
            0x800f8628:0x90430055, # lock byte
            0x800f8630:0x14600011,
            0x800f86bc:0x90620045, # committed down marker
            0x800f86cc:0x84620012, # HP minus pending damage
            0x800f86d0:0x8463004e,
            0x800f86dc:0x04410002,
            0x800eecd8:0x28820004, # reach belongs to command preparation
            0x800eed7c:0x28420004,
        }.items():self.assertEqual(word(address),expected,hex(address))

    def test_known_contact_clocks_match_the_independent_source_timing_walker(self):
        from export_world_travel import party_attack_sequence
        for id,impact,returned,released in (('hero',73,97,129),('gremio',65,89,121),('pahn',57,96,128),('yam_koo',74,100,135),('tai_ho',74,100,135)):
            clock=party_attack_sequence(id)
            self.assertEqual((clock['impact_tick'],clock['return_tick'],clock['release_tick']),(impact,returned,released))

    def test_all_15_dodges_and_grave_master_child_retain_source_spans(self):
        self.assertEqual(len(self.packet['dodges']),15)
        for row in self.proof['targets']:
            raw,_=source('/'+row['resource']['source']['file'].split('/')[-1]);record=row['capability_source_offset']-38
            self.assertTrue(struct.unpack_from('<H',raw,record+38)[0]&4)
            table=struct.unpack_from('<I',raw,record+40)[0]-0x80080000
            start=struct.unpack_from('<I',raw,table+12)[0]-0x80080000
            self.assertEqual(row['operations'],independent_stream(raw,start,table,0x80080000))
            for child in row['children']:
                file=child['source']['file'];data,_=source(file if file=='MAIN.EXE' else '/'+file.split('/')[-1])
                self.assertEqual(hashlib.sha256(data[child['source_offset']:child['source_offset']+child['byte_length']]).hexdigest(),child['sha256'])
        grave=next(r for r in self.proof['targets'] if r['id']=='grave_master')
        self.assertEqual([c['operations'] for c in grave['children']],[[dict(op=25,args=[2,0,0]),dict(op=5,args=[]),dict(op=2,args=[])]])

    def test_normal_C_catalogue_preserves_all_source_profiles_and_policies(self):
        raw,_=source('/C_DATA.BIN');main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        content=json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text())
        ids={1:'kobold_type_1',2:'kobold_type_2',3:'kobold_type_3',4:'strong_arm'}
        pointer=lambda offset:struct.unpack_from('<I',raw,offset)[0]-0x80080000
        directory=pointer(pointer(pointer(0)+12));table=pointer(directory+12)
        expected={1:'source_melee',2:'source_projectile',3:'source_magic',4:'source_melee'}
        for local,id in ids.items():
            record=pointer(table+4*local);data=raw[record:record+64]
            profile=next(p for p in content['enemies'] if p['id']==id)
            self.assertEqual(profile['action_policy'],expected[local])
            self.assertEqual(profile['level'],data[16])
            self.assertEqual(profile['max_hp'],struct.unpack_from('<H',data,18)[0])
            self.assertEqual(profile['stats'],dict(zip(('attack','skill','defense','speed','magic','luck'),struct.unpack_from('<6H',data,20))))
            flags=struct.unpack_from('<H',data,38)[0]
            for key,mask in (('airborne',32),('death_immune',0x4000),('dodges_attacks',4),('unavoidable_attack',8)):
                self.assertEqual(profile[key],bool(flags&mask))
            for drop,item,rate in zip(profile['drops'],data[54:60:2],data[55:60:2],strict=True):
                self.assertEqual(drop['rate'],rate)
                if item:
                    offset=2048+struct.unpack_from('<I',main,2048+0x80167658+4*item-base)[0]-base
                    self.assertEqual(drop['uses'],main[offset+30] if item==25 else 0)
        self.assertEqual([e['id'] for e in content['encounters'] if e['id'].startswith('world_c_encounter_')],[f'world_c_encounter_{i}' for i in range(1,9)])

    def test_missing_shared_impacts_append_without_moving_existing_pixels(self):
        with tempfile.TemporaryDirectory(prefix='party-melee-impact-') as temporary:
            folder=Path(temporary)
            original=Image.new('RGBA',(4096,3),(19,23,29,255));original.save(folder/'spell_effects.png')
            packet=dict(schema='suikoden-spell-scenes/51',entries=[],unite_impacts=[])
            (folder/'spells.json').write_text(json.dumps(packet))
            proof=export_spell_scenes.append_shared_impacts(folder,(14,17,20))
            actual=json.loads((folder/'spells.json').read_text())
            _,_,errors,raw=battle_bin.parse(need_atlases=False);self.assertFalse(errors)
            with Image.open(folder/'spell_effects.png') as atlas:
                self.assertEqual(atlas.crop((0,0,4096,3)).tobytes(),original.tobytes())
                for row in proof:
                    for p in row['poses']:
                        expected,ax,ay=vram_pose(raw,row['source']['section'],p['pose'],base=battle_bin.LOAD_BASE)
                        entry=actual['entries'][p['entry']]
                        self.assertEqual((entry['dx'],entry['dy']),(-ax,-ay))
                        self.assertEqual(atlas.crop((entry['x'],entry['y'],entry['x']+entry['w'],entry['y']+entry['h'])).tobytes(),expected.tobytes())
            before=(folder/'spells.json').read_bytes(),(folder/'spell_effects.png').read_bytes()
            self.assertEqual(export_spell_scenes.append_shared_impacts(folder,(14,17,20)),[])
            self.assertEqual(before,((folder/'spells.json').read_bytes(),(folder/'spell_effects.png').read_bytes()))

    def test_unqualified_impact_requests_refuse_without_mutating_the_package(self):
        with tempfile.TemporaryDirectory(prefix='party-melee-invalid-impact-') as temporary:
            folder=Path(temporary);Image.new('RGBA',(4096,1)).save(folder/'spell_effects.png')
            (folder/'spells.json').write_text(json.dumps(dict(schema='suikoden-spell-scenes/52',entries=[],unite_impacts=[])))
            before=(folder/'spells.json').read_bytes(),(folder/'spell_effects.png').read_bytes()
            for request in ((True,),(-1,),(5,),(999,)):
                with self.assertRaisesRegex(ValueError,'unqualified shared impact'):export_spell_scenes.append_shared_impacts(folder,request)
                self.assertEqual(before,((folder/'spells.json').read_bytes(),(folder/'spell_effects.png').read_bytes()))

    def test_dust_append_preserves_the_existing_source_fixture_contract(self):
        with tempfile.TemporaryDirectory(prefix='party-melee-dust-') as temporary:
            folder=Path(temporary);Image.new('RGBA',(4096,1)).save(folder/'spell_effects.png')
            (folder/'spells.json').write_text(json.dumps(dict(schema='suikoden-spell-scenes/50',entries=[],unite_impacts=[])))
            actual=export_spell_scenes.add_ordinary_dust(folder)
            expected=json.loads((ROOT/'game/tests/fixtures/ordinary_dust.json').read_text())['source']
            self.assertEqual(actual['source'],expected['source'])
            self.assertEqual(actual['frames'],[tuple(v) for v in expected['frames']])
            self.assertEqual([p['rgba_sha256'] for p in actual['poses']],[p['rgba_sha256'] for p in expected['poses']])

if __name__=='__main__':unittest.main()
