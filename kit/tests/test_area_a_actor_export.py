"""Disc-backed A catalogue/positions/art/drop checks; no original execution."""
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
from export_first_room import source
import export_journey
from test_export_unite_review import vram_pose
from war_text import decode


class AreaAActors(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='area-a-actors-')
        cls.out=Path(cls.temp.name)/'one'
        _,_,cls.battle=export_journey.export(cls.out)
        cls.raw,cls.origin=source('/A_DATA.BIN')
        cls.actors=json.loads((cls.out/'battle/unites.json').read_text())
        cls.spells=json.loads((cls.out/'battle/spells.json').read_text())

    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def test_all_source_formations_have_independently_read_rosters_positions_and_flags(self):
        raw=self.raw;base=0x80080000
        word=lambda off:struct.unpack_from('<I',raw,off)[0]
        pointer=lambda off:word(off)-base
        descriptor=pointer(0);resources=pointer(descriptor+12);directory=pointer(resources)
        selectors=pointer(directory+8);enemies=pointer(directory+12)
        count=word(selectors);self.assertEqual(count,9)
        ids={1:'bonbon',2:'mosquito',3:'crow',4:'wild_boar',5:'red_soldier_ant'}
        actual={e['id']:e for e in self.battle['encounters'] if e['id'].startswith('area_a_')}
        self.assertEqual(set(actual),{f'area_a_{i}' for i in range(1,count+1)})
        for index in range(1,count+1):
            record=pointer(selectors+index*4);positions=pointer(pointer(record+20))
            slots=[(slot,native) for slot,native in enumerate(raw[record+4:record+10]) if native]
            self.assertEqual(word(record),len(slots))
            expected=[]
            for slot,native in slots:
                x,y,z=struct.unpack_from('<3h',raw,positions+6*slot)
                enemy=pointer(enemies+4*native);flags=struct.unpack_from('<H',raw,enemy+38)[0]
                expected.append(dict(x=x-128,y=y,z=z-(10 if flags&32 else 0)))
            encounter=actual[f'area_a_{index}']
            self.assertEqual(encounter['enemies'],[ids[n] for _,n in slots])
            self.assertEqual(encounter['source_slots'],[slot for slot,_ in slots])
            self.assertEqual(encounter['positions'],expected)
            self.assertEqual(encounter['enemy_rows'],['front' if slot<3 else 'back' for slot,_ in slots])
        self.assertEqual(self.battle,json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text()))

    def test_mosquito_stats_drops_and_consumable_uses_match_independent_record_reads(self):
        profile=next(e for e in self.battle['enemies'] if e['id']=='mosquito')
        raw=self.raw[0x20e34:0x20e34+64]
        self.assertEqual(profile['name'],decode(raw,length=16)[0])
        self.assertEqual(profile['max_hp'],struct.unpack_from('<H',raw,18)[0])
        self.assertEqual(profile['stats'],dict(zip(('attack','skill','defense','speed','magic','luck'),struct.unpack_from('<6H',raw,20))))
        self.assertEqual((profile['action_policy'],profile['airborne'],profile['dodges_attacks'],profile['unavoidable_attack']),('source_melee',True,True,True))
        self.assertEqual(list(raw[54:60]),[25,5,148,5,0,0])
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        ptr=lambda address:struct.unpack_from('<I',main,2048+address-base)[0]
        for drop,native,rate in zip(profile['drops'],raw[54:60:2],raw[55:60:2],strict=True):
            self.assertEqual(drop['rate'],rate)
            if not native:
                self.assertIsNone(drop['item']);continue
            offset=2048+ptr(0x80167658+4*native)-base
            name=decode(main,offset)[0].lower().replace(' ','_')
            self.assertEqual(drop['item'],name)
            self.assertEqual(drop['uses'],main[offset+30] if native==25 else 0)
        self.assertEqual(len(self.actors['unites']),32)
        self.assertEqual(self.actors,json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text()))

    def test_mosquito_body_white_hurt_and_knockout_pixels_match_independent_vram(self):
        section=struct.unpack_from('<I',self.raw,0x20e34+44)[0]-0x80080000
        graphics=next(row for row in self.battle['unite_graphics'] if row['id']=='mosquito')
        with Image.open(self.out/'battle/actors.png') as atlas:
            for pose in graphics['poses']:
                for key,white in (('sprite',False),('white',True)):
                    if key not in pose:continue
                    expected,ax,ay=vram_pose(self.raw,section,pose['id'],packet=True,white=white,base=0x80080000)
                    actual=pose[key];r=actual['rect']
                    crop=atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
                    self.assertEqual((crop.size,actual['anchor_x'],actual['anchor_y']),(expected.size,ax,ay))
                    self.assertEqual(crop.tobytes(),expected.tobytes())
        hurt=next(row for row in self.spells['hurt_poses'] if row['id']=='mosquito')
        frame_table=struct.unpack_from('<I',self.raw,section+20)[0]-0x80080000
        with Image.open(self.out/'battle/spell_effects.png') as atlas:
            for animation,entry,white in ((1,hurt['entry'],False),(1,hurt['white_entry'],True),(3,hurt['knockout']['entry'],False)):
                frame=struct.unpack_from('<I',self.raw,frame_table+4*animation)[0]-0x80080000
                expected,ax,ay=vram_pose(self.raw,section,self.raw[frame+4],white=white,base=0x80080000)
                r=self.spells['entries'][entry]
                crop=atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
                self.assertEqual((crop.size,r['dx'],r['dy']),(expected.size,-ax,-ay))
                self.assertEqual(crop.tobytes(),expected.tobytes())

    def test_candidates_repeat_byte_for_byte_and_preserve_starting_roster(self):
        second=Path(self.temp.name)/'two';export_journey.export(second)
        manifest=json.loads((self.out/'manifest.json').read_text())
        for path,digest in manifest['files'].items():
            a=(self.out/path).read_bytes();b=(second/path).read_bytes()
            self.assertEqual(hashlib.sha256(a).hexdigest(),digest,path)
            self.assertEqual(a,b,path)
        self.assertEqual(self.battle['initial_party'],['hero','gremio','pahn','viktor','yam_koo','tai_ho'])
        self.assertEqual(len(self.battle['party']),53)
        base=json.loads((ROOT/'game/tests/fixtures/spell_scene_library.json').read_text())
        base.update(json.loads((ROOT/'game/tests/fixtures/journey_unite_scenes_patch.json').read_text()))
        self.assertEqual(base,self.spells)


if __name__=='__main__':unittest.main()
