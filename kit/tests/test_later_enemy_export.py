"""Independent later-enemy records, actors, source art and repeatable export."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_first_room import source
import export_journey
import export_counter_actors
from export_unite_programs import animation_resource
from export_battle_trial import section_art
from test_export_unite_review import vram_pose
from test_physical_rune_export import independent_stream
from war_text import decode

CASES=(('B',2,'flying_squirrel'),('B',4,'roc'),('D',2,'mad_ivy'),('F',1,'ivy'),('E',3,'hell_hound'),('E',4,'grave_master'),('G',2,'grizzly_bear'),
       ('H',1,'rabbit_bird'),('Z',2,'simurgh'),('Z',3,'orc'))

class LaterEnemyExport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='later-enemy-')
        cls.out=Path(cls.temp.name)/'one'
        import battle_actor_atlas
        from test_battle_actor_atlas import assert_preserved
        compact=battle_actor_atlas.compact_package
        cls.packing_checks=[]
        def checked(folder,stage):
            before=json.loads((folder/'trial.json').read_text())
            with Image.open(folder/'actors.png') as raw:source=raw.convert('RGBA')
            result=compact(folder,stage)
            after=json.loads((folder/'trial.json').read_text())
            with Image.open(folder/'actors.png') as raw:packed=raw.convert('RGBA')
            cls.packing_checks.append((stage,assert_preserved(unittest.TestCase(),before,source,after,packed)))
            return result
        with patch.object(battle_actor_atlas,'compact_package',side_effect=checked):
            _,_,cls.content=export_journey.export(cls.out)
        cls.actors=json.loads((cls.out/'battle/unites.json').read_text())
        cls.spells=json.loads((cls.out/'battle/spells.json').read_text())
        cls.proof=json.loads((cls.out/'battle/provenance.json').read_text())
        cls.packet,cls.actor_proof=export_counter_actors.build(include_later=True)

    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def record(self,region,native):
        raw,origin=source('/'+region+'_DATA.BIN')
        pointer=lambda off:struct.unpack_from('<I',raw,off)[0]-0x80080000
        directory=pointer(pointer(pointer(0)+12));table=pointer(directory+12)
        return raw,origin,pointer(table+native*4),pointer

    def test_all_packing_passes_preserve_every_sampled_byte_and_gameplay_field(self):
        self.assertEqual([stage for stage,count in self.packing_checks],['before_later_enemies','complete_journey'])
        self.assertTrue(all(count>0 for stage,count in self.packing_checks))

    def test_all_ten_profiles_preserve_raw_stats_affinities_flags_and_drops(self):
        self.assertEqual((len(self.content['party']),len(self.content['enemies']),len(self.content['encounters'])),(53,32,96))
        self.assertEqual(len(self.actors['unites']),32)
        self.assertEqual(self.actors['programs']['schema'],'suikoden-actor-programs/13')
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        pointer=lambda address:struct.unpack_from('<I',main,2048+address-base)[0]
        for region,native,identifier in CASES:
            raw,_,record,_=self.record(region,native)
            data=raw[record:record+64]
            profile=next(e for e in self.content['enemies'] if e['id']==identifier)
            self.assertEqual(profile['name'],decode(data,length=16)[0])
            self.assertEqual(profile['level'],data[16])
            self.assertEqual(profile['max_hp'],struct.unpack_from('<H',data,18)[0])
            self.assertEqual(profile['stats'],dict(zip(('attack','skill','defense','speed','magic','luck'),struct.unpack_from('<6H',data,20))))
            for i,element in enumerate(('fire','water','earth','lightning','wind')):
                self.assertEqual(profile['affinities'][element],('neutral','weak','resistant','immune')[data[32+i]])
            flags=struct.unpack_from('<H',data,38)[0]
            for key,mask in (('airborne',32),('death_immune',0x4000),('dodges_attacks',4),('unavoidable_attack',8)):
                self.assertEqual(profile[key],bool(flags&mask))
            self.assertEqual(profile['action_policy'],'source_melee')
            self.assertEqual(profile.get('effect_offset',[0,0]),list(struct.unpack_from('<2h',data,60)))
            for drop,item,rate in zip(profile['drops'],data[54:60:2],data[55:60:2],strict=True):
                self.assertEqual(drop['rate'],rate)
                if item:
                    offset=2048+pointer(0x80167658+4*item)-base
                    name=decode(main,offset,length=24)[0].lower()
                    import re
                    self.assertEqual(drop['item'],re.sub('[^a-z0-9]+','_',name).strip('_'))
                else:self.assertIsNone(drop['item'])
                self.assertEqual(drop['uses'],0)
                self.assertEqual(drop['identified'],not bool(item and struct.unpack_from('<H',main,2048+pointer(0x80167658+4*item)-base+28)[0]&0x7000))
        orc=next(e for e in self.content['enemies'] if e['id']=='orc')
        self.assertEqual([d['item'] for d in orc['drops']],['graffiti','lover_s_garden','beauties_of_nature'])

    def test_forty_four_whole_formations_preserve_rosters_holes_positions_and_rows(self):
        total=0
        for region in sorted({r for r,_,_ in CASES}):
            raw,_,_,p=self.record(region,next(n for r,n,_ in CASES if r==region))
            directory=p(p(p(0)+12));selectors=p(directory+8);enemies=p(directory+12)
            count=struct.unpack_from('<I',raw,selectors)[0]
            ids={native:name for r,native,name in CASES if r==region}
            if region=='B':ids.update({1:'killer_rabbit',3:'beast_commander'})
            if region=='Z':ids[1]='ninja_master'
            if region=='G':ids.update({1:'dagon',3:'siren'})
            if region=='E':ids.update({1:'whip_wolf',2:'sorcerer'})
            if region=='D':ids.update({1:'holly_fairy',3:'creeper'})
            if region=='F':ids.update({2:'shadow_man',3:'mirage_f'})
            if region=='H':ids.update({2:'mirage_h',3:'earth_golem'})
            actual={e['id']:e for e in self.content['encounters'] if e['id'].startswith('area_'+region.lower()+'_')}
            expected=set()
            for i in range(1,count+1):
                record=p(selectors+4*i);slots=[(slot,native) for slot,native in enumerate(raw[record+4:record+10]) if native]
                if any(native not in ids for _,native in slots):continue
                name=f'area_{region.lower()}_{i}';expected.add(name);entry=actual[name]
                self.assertEqual(entry['enemies'],[ids[n] for _,n in slots])
                self.assertEqual(entry['source_slots'],[slot for slot,_ in slots])
                self.assertEqual(entry['enemy_rows'],['front' if slot<3 else 'back' for slot,_ in slots])
                table=p(p(record+20));positions=[]
                for slot,native in slots:
                    x,y,z=struct.unpack_from('<3h',raw,table+slot*6)
                    flag=struct.unpack_from('<H',raw,p(enemies+4*native)+38)[0]
                    positions.append(dict(x=x-128,y=y,z=z-(10 if flag&32 else 0)))
                self.assertEqual(entry['positions'],positions)
                total+=1
            self.assertEqual(set(actual),expected)
        self.assertEqual(total,73)

    def test_actor_streams_and_body_white_art_agree_with_independent_consumers(self):
        proofs={p['id']:p for p in self.actor_proof['programs']}
        programs={p['id']:p for p in self.packet['programs']['programs']}
        for region,native,name in CASES:
            raw,_,record,p=self.record(region,native);table=p(record+40)
            binding=next(e for e in self.packet['melee']['enemies'] if e['id']==name)
            for role,slot in (('attack',1),('hurt',2),('return',4)):
                identifier=binding[role+'_program']
                self.assertEqual(proofs[identifier]['operations'],independent_stream(raw,p(table+slot*4),table,0x80080000))
                self.assertIn(identifier,programs)
            flags=struct.unpack_from('<H',raw,record+38)[0]
            roles=[]
            if flags&1:
                counter=next(e for e in self.packet['enemies'] if e['id']==name)
                roles.extend((counter[role+'_program'],slot) for role,slot in (('attack',1),('return',4)))
            if flags&2:
                parry=next(e for e in self.packet['parries']['defenders'] if e['id']==name)
                roles.extend((parry[role+'_program'],slot) for role,slot in (('response',3),('strike',5),('hurt',2)))
            for identifier,slot in roles:
                self.assertEqual(proofs[identifier]['operations'],independent_stream(raw,p(table+slot*4),table,0x80080000))
            graphic=next(g for g in self.content['unite_graphics'] if g['id']==name)
            with Image.open(self.out/'battle/actors.png') as atlas:
                for pose in graphic['poses']:
                    for key,white in (('sprite',False),('white',True)):
                        if key not in pose:continue
                        expected,ax,ay=vram_pose(raw,p(record+44),pose['id'],packet=not (name in ('ivy','mad_ivy') and pose['id'] in (6,7,8)),white=white,base=0x80080000)
                        r=pose[key]['rect'];image=atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
                        self.assertEqual((image.size,pose[key]['anchor_x'],pose[key]['anchor_y']),(expected.size,ax,ay))
                        self.assertEqual(image.tobytes(),expected.tobytes())
            hurt=next(row for row in self.spells['hurt_poses'] if row['id']==name)
            ft=p(p(record+44)+20)
            with Image.open(self.out/'battle/spell_effects.png') as atlas:
                for animation,index,white in ((1,hurt['entry'],False),(1,hurt['white_entry'],True),(3,hurt['knockout']['entry'],False)):
                    pose=raw[p(ft+4*animation)+4]
                    expected,ax,ay=vram_pose(raw,p(record+44),pose,white=white,base=0x80080000)
                    entry=self.spells['entries'][index]
                    image=atlas.crop((entry['x'],entry['y'],entry['x']+entry['w'],entry['y']+entry['h']))
                    self.assertEqual((image.size,entry['dx'],entry['dy']),(expected.size,-ax,-ay))
                    self.assertEqual(image.tobytes(),expected.tobytes())
        self.assertEqual(self.actor_proof['melee_refusals'],[])
        self.assertEqual((len(programs),len(self.packet['animations']['resources'])),(476,98))

    def test_holly_hurt_white_idle_and_ko_art_matches_independent_vram_sampling(self):
        raw,_,record,p=self.record('D',1)
        section=p(record+44);frames=p(section+20)
        hurt=next(row for row in self.spells['hurt_poses'] if row['id']=='holly_fairy')
        with Image.open(self.out/'battle/spell_effects.png') as atlas:
            for animation,index,white in ((0,hurt['idle_flash']['frames'][0]['normal'],False),(1,hurt['entry'],False),
                    (1,hurt['white_entry'],True),(3,hurt['knockout']['entry'],False)):
                pose=raw[p(frames+4*animation)+4]
                expected,ax,ay=vram_pose(raw,section,pose,white=white,base=0x80080000)
                entry=self.spells['entries'][index]
                image=atlas.crop((entry['x'],entry['y'],entry['x']+entry['w'],entry['y']+entry['h']))
                self.assertEqual((image.size,entry['dx'],entry['dy']),(expected.size,-ax,-ay))
                self.assertEqual(image.tobytes(),expected.tobytes())

    def test_painting_goods_match_source_records_without_changing_medicine(self):
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        data=json.loads((ROOT/'game/assets/items.json').read_text())
        for native,identifier in ((130,'graffiti'),(132,'lover_s_garden'),(134,'beauties_of_nature')):
            pointer=struct.unpack_from('<I',main,2048+0x80167658+4*native-base)[0]
            offset=2048+pointer-base
            good=next(g for g in data['goods'] if g['id']==identifier)
            self.assertEqual(good['name'],decode(main,offset,length=24)[0])
            self.assertEqual(good['price'],struct.unpack_from('<I',main,offset+24)[0])
            self.assertEqual(struct.unpack_from('<H',main,offset+28)[0]&0x7000,0x4000)
            self.assertEqual(good['uses'],0)
            self.assertNotIn(identifier,data['stock'])
            appraisal=next(a for a in data['appraisals'] if a['id']==identifier)
            self.assertEqual((appraisal['name'],appraisal['price'],appraisal['fee']),(good['name'],good['price'],500))
        self.assertEqual(data['medicine']['name'],'Medicine')
        for start,end,digest in (
            (0x800e9b10,0x800e9b70,'36b6a3c95543184245da6a538d6eb2aa2d744646e32e142c9959153041a6234c'),
            (0x800e92b0,0x800e9350,'a5aa5abd5d4e620828eab620c6432e06b9dcf780280c162b5cc5fc753dfac7d7')):
            self.assertEqual(hashlib.sha256(main[2048+start-base:2048+end-base]).hexdigest(),digest)
        self.assertEqual(decode(main,2048+0x8016bc7c-base)[0],'? painting')

    def test_rabbit_bird_has_a_proven_fourteenth_animation_and_source_setter(self):
        raw,origin,record,p=self.record('H',1);section=p(record+44);ft=p(section+20);end=p(section+8)
        self.assertEqual(struct.unpack_from('<H',raw,section+2)[0],13)
        self.assertEqual(end-ft,14*4)
        offset=p(ft+13*4)
        self.assertEqual(raw[offset:offset+8],bytes.fromhex('02010100030f000a'))
        with self.assertRaisesRegex(ValueError,'Unbound animation'):
            animation_resource('rabbit_bird',raw,origin,{13},section,0x80080000)
        resource,proof=animation_resource('rabbit_bird',raw,origin,{13},section,0x80080000,animation_table_end=end)
        self.assertEqual([(f['pose'],f['updates']) for f in resource['clips'][0]['frames']],[(3,15),(0,10)])
        _,animations,_=section_art(raw,section,0x80080000,animation_indices=[13],animation_table_end=end)
        self.assertEqual(animations[13],[(3,15),(0,10)])
        for bad in (end-8,end+1,len(raw)+4,False):
            with self.assertRaisesRegex(ValueError,'animation table extent'):
                animation_resource('rabbit_bird',raw,origin,{13},section,0x80080000,animation_table_end=bad)
        main,_=source('MAIN.EXE');base,size=struct.unpack_from('<II',main,24);main=main[2048:2048+size]
        self.assertEqual(hashlib.sha256(main[0x800e2044-base:0x800e211c-base]).hexdigest(),'b5d45cf5bbdddf7394886a9f1037d041b70cbed421d50f97ef9b42e272174cf3')
        for address,word in {0x800e2054:0x8c420014,0x800e2058:0x00052880,0x800e205c:0x00a21021,0x800e2060:0x8c420000}.items():
            self.assertEqual(struct.unpack_from('<I',main,address-base)[0],word)

    def test_later_selector_mutation_is_refused_before_admission(self):
        original=export_counter_actors.source
        def changed(path):
            raw,origin=original(path)
            if path=='/E_DATA.BIN':
                raw=bytearray(raw);raw[0x20+0x60]^=1;raw=bytes(raw)
            return raw,origin
        with patch.object(export_counter_actors,'source',side_effect=changed):
            with self.assertRaisesRegex(ValueError,'ordinary selector changed'):
                export_counter_actors.build(include_later=True)

    def test_existing_region_b_resources_are_not_exported_twice(self):
        from export_physical_runes import recipient_resources
        legacy=recipient_resources()
        expanded=recipient_resources(include_later=True)
        ids=[resource['id'] for resource,_ in expanded]
        self.assertEqual(len(ids),len(set(ids)))
        self.assertTrue({resource['id'] for resource,_ in legacy}<=set(ids))
        self.assertEqual([resource['id'] for resource,proof in expanded if proof['source']['file'].endswith('B_DATA.BIN')],
                         ['killer_rabbit','flying_squirrel','beast_commander','roc'])

    def test_full_export_repeats_and_matches_native_catalogue_fixtures(self):
        second=Path(self.temp.name)/'two';export_journey.export(second)
        files=json.loads((self.out/'manifest.json').read_text())['files']
        for name,digest in files.items():
            a=(self.out/name).read_bytes();self.assertEqual(hashlib.sha256(a).hexdigest(),digest,name)
            self.assertEqual(a,(second/name).read_bytes(),name)
        self.assertEqual(self.content,json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text()))
        self.assertEqual(self.actors,json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text()))

if __name__=='__main__':unittest.main()
