#!/usr/bin/env python3
"""Static source C actor-package checks; no original CPU or native windows."""
import copy
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
import export_journey
import export_world_battle as exporter
from export_first_room import source
from area_encounter_tables import chain,BASE
from test_export_unite_review import vram_pose


class CActorExport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='world-c-actors-')
        cls.journey=Path(cls.temp.name)/'journey';cls.output=Path(cls.temp.name)/'world'
        export_journey.export(cls.journey)
        cls.overlay,cls.proof=exporter.export_c_actors(cls.journey,cls.output)

    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def test_source_formations_stats_and_native_fixture_agree(self):
        content=self.overlay['actor_content']
        self.assertEqual(self.overlay['schema'],'suikoden-world-battle/31')
        self.assertEqual(content['schema'],'suikoden-battle-trial/43')
        self.assertEqual(len(content['party']),53)
        self.assertEqual([e['id'] for e in content['encounters']],[f'world_c_encounter_{index}' for index in range(1,9)])
        encounter=next(row for row in content['encounters'] if row['id']=='world_c_encounter_2')
        self.assertEqual(encounter['enemies'],['kobold_type_1']*3)
        self.assertEqual(encounter['source_slots'],[0,1,2])
        self.assertEqual(encounter['positions'],[dict(x=-128,y=y,z=0) for y in (0,-50,50)])
        self.assertEqual(self.overlay,json.loads((ROOT/'game/tests/fixtures/world_c_unites_actor_library.json').read_text()))
        raw,_=source('/C_DATA.BIN');enemy=next(row for row in content['enemies'] if row['id']=='kobold_type_1')
        hp,attack,skill,defense,speed,magic,luck=struct.unpack_from('<7H',raw,0x21414+18)
        self.assertEqual(enemy['max_hp'],hp)
        self.assertEqual(enemy['stats'],dict(attack=attack,skill=skill,defense=defense,speed=speed,magic=magic,luck=luck))
        self.assertEqual(struct.unpack_from('<H',raw,0x21414+38)[0],3)
        self.assertEqual(struct.unpack_from('<I',raw,0x21414+48)[0],0x80080018)
        self.assertEqual(enemy['action_policy'],'source_melee')
        archer=next(row for row in content['enemies'] if row['id']=='kobold_type_2')
        self.assertEqual((archer['action_policy'],archer['front_projectile']),('source_projectile',None))
        self.assertEqual(self.overlay['unsupported_enemies'],[])

    def test_holly_wave_bundle_and_battle_versions_survive_c_attachment(self):
        import export_enemy_holly_fairy
        trial_path=self.journey/'battle/trial.json';actors_path=self.journey/'battle/unites.json'
        original_trial=trial_path.read_bytes();original_actors=actors_path.read_bytes()
        try:
            trial=json.loads(original_trial);trial['schema']='suikoden-battle-trial/43'
            actors=export_enemy_holly_fairy.combine(json.loads(original_actors))
            trial_path.write_text(json.dumps(trial));actors_path.write_text(json.dumps(actors))
            overlay,_=exporter.export_c_actors(self.journey,Path(self.temp.name)/'world-wave-versions')
            self.assertEqual(overlay['actor_content']['schema'],'suikoden-battle-trial/43')
            retained=json.loads((Path(self.temp.name)/'world-wave-versions/unites.json').read_text())
            self.assertEqual(retained['schema'],'suikoden-unite-actors/40')
            self.assertEqual(retained['enemy_wave'],actors['enemy_wave'])
        finally:
            trial_path.write_bytes(original_trial);actors_path.write_bytes(original_actors)

    def test_appended_scenery_preserves_every_base_pixel_and_party_profile(self):
        base=Image.open(self.journey/'battle/actors.png').convert('RGBA')
        actual=Image.open(self.output/'actors.png').convert('RGBA')
        self.assertEqual(actual.crop((0,0,base.width,base.height)).tobytes(),base.tobytes())
        self.assertEqual(hashlib.sha256(base.tobytes()).hexdigest(),self.proof['atlas_prefix']['rgba_sha256'])
        original=json.loads((self.journey/'battle/trial.json').read_text())
        self.assertEqual(original['party'],self.overlay['actor_content']['party'])
        self.assertEqual(original['unite_graphics'],self.overlay['actor_content']['unite_graphics'])
        self.assertEqual(original['systems'],self.overlay['actor_content']['systems'])
        self.assertEqual(original['initial_party'],self.overlay['actor_content']['initial_party'])
        for entry in self.overlay['actor_content']['scenery']:
            self.assertGreater(entry['sprite']['rect']['y'],base.height)

    def test_source_scenery_rectangles_and_positions_match_independent_vram_sampling(self):
        raw,_=source('/C_DATA.BIN');_,_,directory,_=chain(raw)
        word=lambda offset:struct.unpack_from('<I',raw,offset)[0]-BASE
        section=word(directory-BASE+4);ft=word(section+20);records=word(directory-BASE+20)
        count=struct.unpack_from('<h',raw,records)[0]
        content=self.overlay['actor_content'];self.assertEqual(len(content['scenery']),count)
        atlas=Image.open(self.output/'actors.png').convert('RGBA')
        for index,entry in enumerate(content['scenery']):
            animation,x,y,z=struct.unpack_from('<4h',raw,records+8+index*8)
            frame=word(ft+4*animation);pose=raw[frame+4]
            expected,ax,ay=vram_pose(raw,section,pose,base=BASE)
            sprite=entry['sprite'];r=sprite['rect']
            actual=atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
            self.assertEqual((actual.size,sprite['anchor_x'],sprite['anchor_y']),(expected.size,ax,ay))
            self.assertEqual(actual.tobytes(),expected.tobytes())
            self.assertEqual(entry['position'],dict(x=x,y=y,z=z))

    def test_shared_assets_manifest_and_repeated_export_agree(self):
        for name in ('unites.json','spells.json','spell_effects.png'):
            self.assertEqual((self.output/name).read_bytes(),(self.journey/'battle'/name).read_bytes())
        manifest=json.loads((self.output/'manifest.json').read_text());self.assertEqual(len(manifest['files']),9)
        other=Path(self.temp.name)/'again';exporter.export_c_actors(self.journey,other)
        for name,digest in manifest['files'].items():
            self.assertEqual(hashlib.sha256((self.output/name).read_bytes()).hexdigest(),digest)
            self.assertEqual((self.output/name).read_bytes(),(other/name).read_bytes())
        self.assertFalse(self.proof['native_launched'] or self.proof['promoted'] or self.proof['media_accepted'])

    def test_existing_archer_tracks_and_pixels_survive_atlas_relocation(self):
        original=json.loads((self.output/'archer_source/scene.json').read_text())
        relocated=copy.deepcopy(self.overlay['presentation'])
        source_atlas=Image.open(self.output/'archer_source/actors.png').convert('RGBA')
        combined=Image.open(self.output/'actors.png').convert('RGBA')
        def restore(actual,expected):
            def crop(image,pose):
                r=pose['rect'];return image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
            self.assertEqual(crop(combined,actual).tobytes(),crop(source_atlas,expected).tobytes())
            actual['rect']=copy.deepcopy(expected['rect'])
            self.assertEqual(actual,expected)
        for new_actor,old_actor in zip(relocated['actors'],original['actors'],strict=True):
            for new_pose,old_pose in zip(new_actor['poses'],old_actor['poses'],strict=True):restore(new_pose,old_pose)
        for new_entry,old_entry in zip(relocated['scenery'],original['scenery'],strict=True):restore(new_entry['sprite'],old_entry['sprite'])
        relocated['atlas_width']=original['atlas_width'];relocated['atlas_height']=original['atlas_height']
        self.assertEqual(relocated,original)
        self.assertEqual(self.overlay['presentation'],json.loads((ROOT/'game/tests/fixtures/world_c_unites_actor_library.json').read_text())['presentation'])

    def test_missing_actor_bindings_and_accepted_destinations_refuse(self):
        with self.assertRaisesRegex(ValueError,'accepted staging'):
            exporter.export_c_actors(self.journey,ROOT/'kit/work/accepted/world-c-actors-forbidden')
        bad=Path(self.temp.name)/'bad';(bad/'battle').mkdir(parents=True)
        for name in ('trial.json','unites.json'):
            (bad/'battle'/name).write_bytes((self.journey/'battle'/name).read_bytes())
        library=json.loads((bad/'battle/unites.json').read_text())
        library['counter']['melee']['enemies']=[]
        (bad/'battle/unites.json').write_text(json.dumps(library))
        with self.assertRaisesRegex(ValueError,'no source C formations'):
            exporter.export_c_actors(bad,Path(self.temp.name)/'refused')


if __name__=='__main__':unittest.main()
