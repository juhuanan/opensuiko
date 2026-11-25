#!/usr/bin/env python3
"""Connected export reproducibility, source doorway consumers, loot identities and actor pixels."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import export_journey as export
import maindec as main
from event_script_decode import decode_stream
from export_first_room import source
from test_character_equipment_stats import check_stat_consumer
from test_entity_predicates import assert_words
from test_palace_exit import check_consumers as check_transition_consumers
from war_text import decode
from PIL import Image

class FieldEventBindingTests(unittest.TestCase):
    def test_source_party_id_mapping_is_current_and_separate_from_portraits(self):
        actual=export.field_event_bindings()
        self.assertEqual(actual,json.loads((ROOT/'game/assets/field_event_party.json').read_text()))
        records={row['id']:row['source_character'] for row in actual['records']}
        self.assertEqual(records,dict(hero=8,gremio=2,pahn=6,viktor=35,yam_koo=38,tai_ho=32,maas=70))
        self.assertNotEqual(records['viktor'],4)

class JourneyExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='suikoden-journey-gate-')
        cls.output=Path(cls.temp.name)/'one'
        cls.package,cls.config,cls.battle=export.export(cls.output)
        cls.raw,_=source('/VB6.BIN')
        cls.proof=json.loads((cls.output/'provenance.json').read_text())
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def test_bonbon_source_actor_replaces_legacy_motion(self):
        profile = next(e for e in self.battle['enemies'] if e['id'] == 'bonbon')
        self.assertEqual(profile['action_policy'], 'source_melee')
        motion = profile['motion']
        self.assertEqual((motion['impact_tick'], motion['ready_tick'], motion['return_start'], motion['duration']), (12, 13, 13, 43))
        library = json.loads((self.output / 'battle/unites.json').read_text())
        self.assertTrue(any(row['id'] == 'bonbon' for row in library['counter']['melee']['enemies']))
        self.assertTrue(any(row['id'] == 'red_soldier_ant' for row in library['counter']['melee']['enemies']))

    def test_wild_boar_source_actor_and_dust_dependency_match_native_fixture(self):
        profile = next(e for e in self.battle['enemies'] if e['id']=='wild_boar')
        self.assertEqual(profile['action_policy'],'source_melee')
        library = json.loads((self.output/'battle/unites.json').read_text())
        self.assertEqual(library['programs']['schema'],'suikoden-actor-programs/13')
        self.assertTrue(any(r['id']=='wild_boar' for r in library['counter']['melee']['enemies']))
        spells = json.loads((self.output/'battle/spells.json').read_text())
        self.assertEqual(spells['schema'],'suikoden-spell-scenes/52')
        dust = next(c for c in spells['unite_impacts'] if c['id']==13)
        indices = [f['entry'] for f in dust['frames']]
        mapping = {value:index for index,value in enumerate(indices)}
        proof = json.loads((self.output/'battle/spells.provenance.json').read_text())['ordinary_dust']
        expected = dict(entries=[spells['entries'][i] for i in indices],
            frames=[dict(entry=mapping[f['entry']],ticks=f['ticks']) for f in dust['frames']],source=proof)
        self.assertEqual(expected,json.loads((ROOT/'game/tests/fixtures/ordinary_dust.json').read_text()))

    def test_regional_reaction_bindings_match_independent_vram_pixels(self):
        from area_encounter_tables import BASE
        from test_export_unite_review import vram_pose
        scenes=json.loads((self.output/'battle/spells.json').read_text())
        reactions={row['id']:row for row in scenes['hurt_poses']}
        cases=(('D',0x24344,'creeper'),('F',0x22898,'shadow_man'),
               ('F',0x24B4C,'mirage_f'),('H',0x21658,'mirage_h'))
        with Image.open(self.output/'battle/spell_effects.png') as atlas:
            for region,record,identifier in cases:
                with self.subTest(enemy=identifier):
                    raw,_=source(f'/{region}_DATA.BIN')
                    def pointer(offset):
                        return struct.unpack_from('<I',raw,offset)[0]-BASE
                    section=pointer(record+44)
                    animations=pointer(section+20)
                    poses=pointer(section+16)
                    reaction=reactions[identifier]
                    self.assertEqual(reaction['knockout']['duration'],94)
                    for clip,entry,white in ((1,reaction['entry'],False),
                                             (1,reaction['white_entry'],True),
                                             (3,reaction['knockout']['entry'],False)):
                        pose=raw[pointer(animations+4*clip)+4]
                        expected,x,y=vram_pose(raw,section,pose,base=BASE,white=white)
                        rect=scenes['entries'][entry]
                        left,top,width,height=(rect[key] for key in ('x','y','w','h'))
                        self.assertEqual((-rect['dx'],-rect['dy'],width,height),(x,y,*expected.size))
                        self.assertEqual(atlas.crop((left,top,left+width,top+height)).tobytes(),expected.tobytes())
                        if clip==1:
                            descriptor=pointer(poses+4*pose)
                            offsets=[((raw[descriptor+6+i]-raw[descriptor+4+i]+128)%256)-128 for i in range(2)]
                            self.assertEqual(reaction['impact_offset'],offsets)

    def test_crow_source_actor_retains_its_all_row_target_scan(self):
        profile = next(e for e in self.battle['enemies'] if e['id']=='crow')
        self.assertEqual((profile['action_policy'],profile['target_policy']),('source_melee','any_row'))
        library = json.loads((self.output/'battle/unites.json').read_text())
        binding = next(row for row in library['counter']['melee']['enemies'] if row['id']=='crow')
        attack = next(row for row in library['programs']['programs'] if row['id']==binding['attack_program'])
        self.assertIn(dict(command=dict(effect=dict(id='crow_dive',binding='self'))),attack['instructions'])

    def test_physical_owner_profiles_preserve_source_templates_and_independent_pixels(self):
        import character_table
        import export_battle_sprite_sections as reference
        import journey_battle
        import export_first_room
        proof=json.loads((self.output/'battle/provenance.json').read_text())['physical_member_profiles']
        self.assertEqual({row['id'] for row in proof},{'kasumi','valeria'})
        self.assertEqual(self.battle['initial_party'],['hero','gremio','pahn','viktor','yam_koo','tai_ho'])
        raw_templates=character_table.image()
        library=json.loads((self.output/'battle/unites.json').read_text())
        required={member for technique in library['physical'] if technique['id']!='clone' for member in technique['members']}
        profiles={row['id']:row for row in self.battle['party']}
        self.assertTrue(required <= profiles.keys())
        with Image.open(self.output/'battle/actors.png') as image:
            atlas=image.convert('RGBA')
        for entry in proof:
            profile=profiles[entry['id']]
            native=23 if entry['id']=='kasumi' else 36
            records=[raw_templates[0x33274+80*i:0x33274+80*(i+1)] for i in range(78)]
            seed=next(row for row in records if struct.unpack_from('<I',row)[0]==native)
            self.assertEqual(entry['native_id'],native)
            self.assertEqual(entry['template_file_offset'],entry['template_image_offset']+2048)
            self.assertEqual((profile['level'],profile['max_hp'],profile['growth']),
                (seed[13],struct.unpack_from('<H',seed,4)[0],list(seed[24:30])))
            pointer=main.mword(0x80165890+4*seed[68])
            curve=main.body()[pointer-main.MBASE+0x54]
            weapon=struct.unpack_from('<H',main.body(),0x801659D0-main.MBASE+32*curve+2*(seed[69]-1))[0]
            expected=list(seed[16:22]);expected[0]+=weapon
            self.assertEqual([profile['stats'][key] for key in ('attack','skill','defense','speed','magic','luck')],expected)
            self.assertEqual((profile['rune'],profile['rune_locked'],entry['initial_rune_byte']),
                ('shrike' if native==23 else 'falcon',bool(seed[77]),seed[76]))
            raw,origin=source('/KAS.BIN' if native==23 else '/VRE.BIN')
            self.assertEqual(entry['source'],origin)
            decoded=reference.decode_section(raw,struct.unpack_from('<I',raw,36)[0],character_id=entry['id'])
            for frame in profile['cast']+profile['attack']:
                rect=frame['pose']['rect'];pose=decoded.poses[frame['source_pose']]
                self.assertEqual(atlas.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h'])).tobytes(),pose.image.tobytes())
                self.assertEqual((frame['pose']['anchor_x'],frame['pose']['anchor_y']),(pose.anchor_x,pose.anchor_y))
            self.assertEqual(set(profile['item_art']),{'idle','prepare','hold','recover'})
            self.assertTrue(any(row['id']==entry['id'] for row in self.battle['medicine_timings']))
        unchanged=json.dumps(self.battle,sort_keys=True)
        atlas=export_first_room.Atlas()
        self.assertEqual(journey_battle.append_physical_profiles(self.battle,atlas,{'techniques':library['physical']}),[])
        self.assertEqual(json.dumps(self.battle,sort_keys=True),unchanged)
        self.assertEqual((atlas.x,atlas.y,atlas.row_height),(0,0,0))

    def test_complete_unite_member_batch_preserves_source_rosters_stats_and_pixels(self):
        import copy
        import character_table
        import preparation
        import assemble_battle_review
        from test_export_unite_review import vram_pose
        actors=json.loads((self.output/'battle/unites.json').read_text())
        proof=json.loads((self.output/'battle/provenance.json').read_text())['unite_member_profiles']
        profiles={p['id']:p for p in self.battle['party']}
        required={m['id'] for row in actors['unites'] for m in row['members']}
        self.assertTrue(required <= profiles.keys())
        self.assertEqual(len(profiles),53)
        self.assertEqual(len(proof['added_members']),32)
        self.assertEqual(self.battle['initial_party'],['hero','gremio','pahn','viktor','yam_koo','tai_ho'])
        seeds={preparation.stable_id(r['name']):r for r in character_table.records()}
        source_rows={row['id']:row for row in proof['members']}
        templates=character_table.image()
        with Image.open(self.output/'battle/actors.png') as image: atlas=image.convert('RGBA')
        cache={}
        def verify(identifier,pose,index,packet,white=False):
            key=(identifier,index,packet,white)
            if key not in cache:
                raw,_=source('/'+seeds[identifier]['sprite_file'])
                cache[key]=vram_pose(raw,struct.unpack_from('<I',raw,36)[0],index,packet=packet,white=white)
            expected,x,y=cache[key];rect=pose['rect']
            self.assertEqual((pose['anchor_x'],pose['anchor_y']),(x,y))
            actual=atlas.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h']))
            self.assertEqual((actual.size,actual.tobytes()),(expected.size,expected.tobytes()),(identifier,index,packet))
        names={r['addr']:r['name'] for r in __import__('item_tables').runes()}
        for identifier in proof['added_members']:
            profile=profiles[identifier];entry=source_rows[identifier]
            seed=templates[entry['template_image_offset']:entry['template_image_offset']+80]
            self.assertEqual(struct.unpack_from('<I',seed)[0],seeds[identifier]['id'])
            expected_rune=names[main.mword(0x8016A0E0+4*seed[76])] if seed[76] else None
            actual_rune=next(r['name'] for r in self.battle['systems']['runes'] if r['id']==profile['rune']) if profile['rune'] else None
            self.assertEqual((actual_rune,profile['rune_locked']),(expected_rune,bool(seed[77])))
            pointer=main.mword(0x80165890+4*seed[68]);curve=main.body()[pointer-main.MBASE+0x54]
            attack=struct.unpack_from('<H',main.body(),0x801659D0-main.MBASE+32*curve+2*(seed[69]-1))[0]
            expected=list(seed[16:22]);expected[0]+=attack
            self.assertEqual([profile['stats'][k] for k in ('attack','skill','defense','speed','magic','luck')],expected)
            self.assertEqual((profile['max_hp'],profile['level']),(struct.unpack_from('<H',seed,4)[0],seed[13]))
            cast_packet=entry['art'].get('sampling')=='axis_aligned_packet'
            for frame in profile['cast']: verify(identifier,frame['pose'],frame['source_pose'],cast_packet)
            for frame in profile['attack']: verify(identifier,frame['pose'],frame['source_pose'],identifier in ('humphrey','sonya'))
            for clips in (profile['item_art'],profile['revival_art']):
                for clip in clips.values():
                    for frame in clip['frames']: verify(identifier,frame['pose'],frame['source_pose'],True)
        for graphic in self.battle['unite_graphics']:
            if graphic.get('record') not in proof['records']: continue
            identifier=graphic['id'];packet=source_rows[identifier]['art'].get('sampling')=='axis_aligned_packet'
            for pose in graphic['poses']: verify(identifier,pose['sprite'],pose['id'],packet)
        ordinary={g['id']:g for g in self.battle['unite_graphics'] if g.get('record') is None}
        selected_members={member['id'] for row in actors['unites'] if row['record'] in proof['records'] for member in row['members']}
        self.assertEqual(selected_members,{row['id'] for row in proof['ordinary_graphics']})
        for row in proof['ordinary_graphics']:
            for pose in row['poses']:
                sprite=next(p for p in ordinary[row['id']]['poses'] if p['id']==pose['id'])
                verify(row['id'],sprite.get('ordinary',sprite['sprite']),pose['id'],True)
                if pose.get('white'): verify(row['id'],sprite['white'],pose['id'],True,white=True)
        before={name:hashlib.sha256((self.output/'battle'/name).read_bytes()).hexdigest() for name in ('trial.json','actors.png')}
        self.assertEqual(assemble_battle_review.add_unite_member_assets(self.output,Path('unused-review'),{}),dict(records=[],members=[],atlas_rectangles=0))
        self.assertEqual(before,{name:hashlib.sha256((self.output/'battle'/name).read_bytes()).hexdigest() for name in before})
        base=json.loads((ROOT/'game/tests/fixtures/spell_scene_library.json').read_text())
        patch=json.loads((ROOT/'game/tests/fixtures/journey_unite_scenes_patch.json').read_text())
        composed=copy.deepcopy(base);composed.update(patch)
        self.assertEqual(composed,json.loads((self.output/'battle/spells.json').read_text()))

    def test_reproducibility_and_checked_in_semantic_fixtures(self):
        two=Path(self.temp.name)/'two';export.export(two)
        for path in self.output.rglob('*'):
            if path.is_file():self.assertEqual(hashlib.sha256(path.read_bytes()).digest(),hashlib.sha256((two/path.relative_to(self.output)).read_bytes()).digest(),str(path))
        room_fixture=json.loads((ROOT/'game/tests/fixtures/journey_room.json').read_text())
        self.assertEqual([room['id'] for room in room_fixture['rooms'] if room['id']=='world_a'],['world_a'])
        self.assertEqual({**room_fixture,'rooms':[room for room in room_fixture['rooms'] if room['id']!='world_a']},self.package)
        config_fixture=json.loads((ROOT/'game/tests/fixtures/journey.json').read_text())
        self.assertEqual([item['id'] for item in config_fixture['encounters'] if item['id']=='world_patrol'],['world_patrol'])
        self.assertEqual({**config_fixture,'encounters':[item for item in config_fixture['encounters'] if item['id']!='world_patrol']},self.config)
        self.assertEqual(json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text()),self.battle)
        manifest=json.loads((self.output/'manifest.json').read_text())
        self.assertEqual(manifest['status'],'candidate')
        self.assertTrue({'battle/spells.json','battle/spell_effects.png','battle/spells.provenance.json'}.issubset(manifest['files']))
        spells=json.loads((self.output/'battle/spells.json').read_text())['spells']
        self.assertEqual(len(spells),33)
        self.assertTrue(all(spell.get('program') is not None for spell in spells))
        for name,digest in manifest['files'].items():self.assertEqual(hashlib.sha256((self.output/name).read_bytes()).hexdigest(),digest)
        with self.assertRaises(ValueError):export.export(ROOT/'kit/work/accepted/journey')

    def test_pair_trails_use_allocation_pose_and_independently_decoded_rgb555_pixels(self):
        import character_table
        import export_battle_sprite_sections as reference
        seeds={r['id']:r for r in character_table.records()}
        with Image.open(self.output/'battle/actors.png') as image:
            atlas=image.convert('RGBA')
        for identifier,native_id,start,stop,frozen in (
            ('gremio',2,17,45,4),('pahn',6,17,45,1),
            ('yam_koo',38,14,90,4),('tai_ho',32,14,90,4)):
            raw,_=source('/'+seeds[native_id]['sprite_file'])
            section=struct.unpack_from('<I',raw,36)[0]
            decoded=reference.decode_section(raw,section,character_id=identifier)
            table=struct.unpack_from('<I',raw,section+20)[0]
            animation=struct.unpack_from('<I',raw,table+5*4)[0]
            self.assertEqual(raw[animation+4],frozen)
            original=decoded.poses[frozen]
            profile=next(p for p in self.battle['party'] if p['id']==identifier)
            trail=profile['unite_scenes'][0]['track']['trail']
            self.assertEqual((trail['start'],trail['stop']),(start,stop))
            self.assertEqual(len(trail['poses']),8)
            for age,pose in enumerate(trail['poses']):
                rect=pose['rect'];actual=atlas.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h']))
                self.assertEqual(actual.size,original.image.size)
                self.assertEqual((pose['anchor_x'],pose['anchor_y']),(original.anchor_x,original.anchor_y))
                for y in range(actual.height):
                    for x in range(actual.width):
                        pixel=original.image.getpixel((x,y))
                        factors=[255*(7-age)//7]*2+[255]
                        rgb=[min(31,pixel[i]//8*factors[i]//128) for i in range(3)]
                        self.assertEqual(actual.getpixel((x,y)),(*[v*8+v//4 for v in rgb],pixel[3]))

    def test_live_unite_library_is_in_the_production_manifest_and_provenance(self):
        self.assertEqual(json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text()),self.battle)
        manifest=json.loads((self.output/'manifest.json').read_text())
        library=json.loads((self.output/'battle/unites.json').read_text())
        self.assertEqual(library,json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text()))
        self.assertIn('battle/unites.json',manifest['files'])
        self.assertIn('battle/ground.png',manifest['files'])
        self.assertEqual(len(library['unites']),32)
        self.assertEqual(library['schema'],'suikoden-unite-actors/40')
        legacy=json.loads((ROOT/'game/tests/fixtures/cover_actor_library.json').read_text())
        programs={row['id']:row for row in library['programs']['programs']}
        for row in legacy['programs']['programs']:self.assertEqual(programs[row['id']],row)
        resources={row['id']:row for row in library['animations']['resources']}
        for row in legacy['animations']['resources']:
            actual=resources[row['id']]
            if row['id']=='shared_impacts':
                self.assertEqual((row['pose_count'],actual['pose_count']),(82,98))
            else:self.assertEqual(actual['pose_count'],row['pose_count'])
            clips={clip['id']:clip for clip in actual['clips']}
            for clip in row['clips']:self.assertEqual(clips[clip['id']],clip)
        for row in legacy['unites']:
            if row['record'] not in (10,14,15,16,27,29,30,31):self.assertEqual(library['unites'][row['record']],row)
        family=library['unites'][30]
        self.assertEqual([(member['id'],member['programs']) for member in family['members']],
                         [(member['id'],member['programs']) for member in legacy['unites'][30]['members']])
        self.assertEqual([member['reaction_variant'] for member in family['members']],[1,2,3])
        self.assertEqual([library['unites'][record]['dispatch_after'] for record in (10,15,16,29,31)],[1,1,1,1,1])
        self.assertEqual(library['unites'][15]['controller']['mode'],'orbit')
        self.assertEqual(library['unites'][16]['impact_effect'],6)
        self.assertIn('ranged',library['counter'])
        spells=json.loads((self.output/'battle/spells.json').read_text())
        self.assertEqual(spells['schema'],'suikoden-spell-scenes/52')
        self.assertTrue(any(row.get('sounds') for row in spells['unite_reactions']))
        self.assertEqual(sum(row['id']=='flash' for row in spells['unite_scenes']),1)
        self.assertEqual(sum(row['id']=='warriors' for row in spells['unite_scenes']),1)
        self.assertTrue({'liukan','fukien','kai','eileen','lepant','tengaar','hix'} <= {row['id'] for row in self.battle['party']})
        from test_export_unite_review import vram_pose
        raw,_=source('/AIL.BIN');section=struct.unpack_from('<I',raw,36)[0]
        graphic=next(row for row in self.battle['unite_graphics'] if row['id']=='eileen')
        with Image.open(self.output/'battle/actors.png') as atlas:
            for pose in graphic['poses']:
                if 'ordinary' not in pose:continue
                sprite=pose['ordinary'];expected,ax,ay=vram_pose(raw,section,pose['id'],packet=True)
                rect=sprite['rect'];actual=atlas.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h']))
                self.assertEqual((actual.tobytes(),sprite['anchor_x'],sprite['anchor_y']),(expected.tobytes(),ax,ay))
            projectile=next(row for row in graphic['poses'] if row['id']==13)['pieces'][0]
            expected,ax,ay=vram_pose(raw,section,13,piece_index=0)
            rect=projectile['rect'];actual=atlas.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h']))
            self.assertEqual((actual.tobytes(),projectile['anchor_x'],projectile['anchor_y']),(expected.tobytes(),ax,ay))
            for identifier,filename in (('tengaar','TEN.BIN'),('hix','HIC.BIN')):
                raw,_=source('/'+filename);section=struct.unpack_from('<I',raw,36)[0]
                graphic=next(row for row in self.battle['unite_graphics'] if row['id']==identifier)
                sprite=next(row for row in graphic['poses'] if row['id']==0)['sprite']
                rect=sprite['rect'];actual=atlas.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h']))
                expected,ax,ay=vram_pose(raw,section,0)
                self.assertEqual((actual.tobytes(),sprite['anchor_x'],sprite['anchor_y']),(expected.tobytes(),ax,ay))
                if identifier=='tengaar':
                    pose=next(row for row in graphic['poses'] if 'ordinary' in row)
                    sprite=pose['ordinary'];rect=sprite['rect']
                    actual=atlas.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h']))
                    expected,ax,ay=vram_pose(raw,section,pose['id'],packet=True)
                    self.assertEqual((actual.tobytes(),sprite['anchor_x'],sprite['anchor_y']),(expected.tobytes(),ax,ay))
        self.assertEqual((len(library['counter']['defenders']),len(library['counter']['enemies'])),(58,32))
        self.assertEqual(len(library['physical']),6)
        proof=json.loads((self.output/'battle/provenance.json').read_text())
        self.assertEqual(len(proof['unite_actor_programs']['programs']),84)
        self.assertEqual(len(proof['physical_actor_programs']['programs']),21)
        self.assertEqual(len(proof['counter_actor_programs']['programs']),476)
        self.assertEqual(len(proof['physical_graphics']),30)
        trails={r['id']:r['trail'] for r in proof['connected_episode']['tracks'] if 'trail' in r}
        self.assertEqual(set(trails),{'gremio','pahn','yam_koo','tai_ho'})
        self.assertEqual(trails['pahn']['allocation_pose'],1)

    def test_trick_merge_preserves_wave_and_existing_battle_content(self):
        import unite_trick_controller
        from test_export_unite_review import vram_pose
        library=json.loads((self.output/'battle/unites.json').read_text())
        spells=json.loads((self.output/'battle/spells.json').read_text())
        clip=next(c for c in spells['unite_impacts'] if c['id']==3)
        entries=[spells['entries'][f['entry']] for f in clip['frames']]
        clip=dict(clip,frames=[dict(f,entry=i) for i,f in enumerate(clip['frames'])])
        self.assertEqual(dict(clip=clip,entries=entries),json.loads((ROOT/'game/tests/fixtures/trick_ranged_impact.json').read_text()))
        binding=library['unites'][14]
        self.assertEqual(binding['wave_heights'],unite_trick_controller.build()['phases'][1]['heights'])
        self.assertEqual([m['id'] for m in binding['members']],['meg','juppo'])
        self.assertEqual(sum('dispatch_after' in r for r in library['unites']),32)
        self.assertEqual(self.battle['initial_party'],['hero','gremio','pahn','viktor','yam_koo','tai_ho'])
        self.assertTrue({'meg','juppo'} <= {p['id'] for p in self.battle['party']})
        with Image.open(self.output/'battle/actors.png') as atlas:
            for identifier,filename in (('meg','/MEG.BIN'),('juppo','/JUP.BIN')):
                raw,_=source(filename);section=struct.unpack_from('<I',raw,36)[0]
                original=json.loads((ROOT/'game/tests/fixtures/trick_actor_library.json').read_text())
                resource=next(r for r in original['animations']['resources'] if r['id']==identifier)
                graphic=next(g for g in self.battle['unite_graphics'] if g['id']==identifier and g.get('record')==14)
                for pose_id in {f['pose'] for c in resource['clips'] for f in c['frames']}:
                    pose=next(p for p in graphic['poses'] if p['id']==pose_id)
                    sprite=pose['sprite'];r=sprite['rect'];expected,ax,ay=vram_pose(raw,section,pose_id)
                    self.assertEqual((atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes(),sprite['anchor_x'],sprite['anchor_y']),(expected.tobytes(),ax,ay))
        proof=json.loads((self.output/'battle/provenance.json').read_text())
        self.assertEqual({r['id'] for r in proof['trick']['members']},{'meg','juppo'})

    def test_beat_merge_preserves_scoped_art_and_full_target_attachments(self):
        import unite_beat_controller
        from test_export_unite_review import vram_pose
        library=json.loads((self.output/'battle/unites.json').read_text())
        expected=unite_beat_controller.actor_programs()
        self.assertEqual(library['unites'][27]['beat_child'],expected['child'])
        self.assertEqual(self.battle['initial_party'],['hero','gremio','pahn','viktor','yam_koo','tai_ho'])
        self.assertEqual(sum(p['id']=='ronnie' for p in self.battle['party']),1)
        keys=[(g['id'],g.get('record')) for g in self.battle['unite_graphics']]
        self.assertEqual(len(keys),len(set(keys)))
        self.assertEqual(sum(g['id']=='pahn' and g.get('record')==29 for g in self.battle['unite_graphics']),1)
        with Image.open(self.output/'battle/actors.png') as atlas:
            for resource,filename in zip(expected['animations']['resources'],('/PAN.BIN','/BEL.BIN'),strict=True):
                raw,_=source(filename);section=struct.unpack_from('<I',raw,36)[0]
                graphic=next(g for g in self.battle['unite_graphics'] if g['id']==resource['id'] and g.get('record')==27)
                for pose_id in {f['pose'] for c in resource['clips'] for f in c['frames']}:
                    sprite=next(p for p in graphic['poses'] if p['id']==pose_id)['sprite']
                    image,ax,ay=vram_pose(raw,section,pose_id);r=sprite['rect']
                    actual=atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
                    self.assertEqual((actual.size,actual.tobytes(),sprite['anchor_x'],sprite['anchor_y']),(image.size,image.tobytes(),ax,ay))
            resource=next(r for r in library['animations']['resources'] if r['id']=='ronnie')
            graphic=next(g for g in self.battle['unite_graphics'] if g['id']=='ronnie' and g.get('record') is None)
            raw,_=source('/BEL.BIN');section=struct.unpack_from('<I',raw,36)[0]
            hurt=next(c for c in resource['clips'] if c['id']==1)['frames'][0]['pose']
            sprite=next(p for p in graphic['poses'] if p['id']==hurt)['sprite'];r=sprite['rect']
            image,ax,ay=vram_pose(raw,section,hurt,packet=True)
            self.assertEqual((atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes(),sprite['anchor_x'],sprite['anchor_y']),(image.tobytes(),ax,ay))
        spells=json.loads((self.output/'battle/spells.json').read_text())
        self.assertEqual([r for r in spells['unite_reactions'] if r['record']==27],unite_beat_controller.recipient_programs()['programs'])
        for pose in spells['hurt_poses']:
            self.assertEqual([((v+128)%256)-128 for v in pose['source_attachment']],pose['impact_offset'])
        proof=json.loads((self.output/'battle/provenance.json').read_text())
        self.assertEqual([p['id'] for p in proof['beat_em_up']['ordinary_graphics']],['ronnie'])
        sounds=json.loads((self.output/'battle/spells.provenance.json').read_text())['recipient_sounds']
        prefix=next(r for r in sounds if (r['record'],r['variant'])==(27,1))
        self.assertEqual(len(prefix['events']),17)
        self.assertEqual(prefix['source'],unite_beat_controller.recipient_programs()['source'][0])

    def test_martial_merge_keeps_record_art_and_ordinary_reactions_separate(self):
        self.assertEqual(self.battle['schema'],'suikoden-battle-trial/43')
        library=json.loads((self.output/'battle/unites.json').read_text())
        binding=library['unites'][29]
        self.assertEqual(binding['target_queue'],dict(recipient_return=80,damage=140,cleanup=200))
        self.assertEqual(sum('dispatch_after' in row for row in library['unites']),32)
        from test_export_unite_review import vram_pose
        import character_table
        seeds={row['id']:row for row in character_table.records()}
        with Image.open(self.output/'battle/actors.png') as atlas:
            def pixels(sprite):
                r=sprite['rect']
                return atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes()
            for identifier,native in (('eikei',66),('pahn',6),('morgan',52)):
                raw,_=source('/'+seeds[native]['sprite_file'])
                section=struct.unpack_from('<I',raw,36)[0]
                resource=next(r for r in library['animations']['resources'] if r['id']==identifier)
                default=next(g for g in self.battle['unite_graphics'] if g['id']==identifier and 'record' not in g)
                scoped=next(g for g in self.battle['unite_graphics'] if g['id']==identifier and g.get('record')==29)
                hurt=next(c for c in resource['clips'] if c['id']==1)['frames'][0]['pose']
                entry=next(p for p in default['poses'] if p['id']==hurt)
                expected,ax,ay=vram_pose(raw,section,hurt,packet=True)
                self.assertEqual((pixels(entry['sprite']),entry['sprite']['anchor_x'],entry['sprite']['anchor_y']),(expected.tobytes(),ax,ay))
                if 'white' in entry:
                    expected,ax,ay=vram_pose(raw,section,hurt,packet=True,white=True)
                    self.assertEqual((pixels(entry['white']),entry['white']['anchor_x'],entry['white']['anchor_y']),(expected.tobytes(),ax,ay))
                clip=next(c for c in resource['clips'] if c['id']==16)
                for pose in {f['pose'] for f in clip['frames']}:
                    sprite=next(p for p in scoped['poses'] if p['id']==pose)['sprite']
                    expected,ax,ay=vram_pose(raw,section,pose)
                    self.assertEqual((pixels(sprite),sprite['anchor_x'],sprite['anchor_y']),(expected.tobytes(),ax,ay))
        spells=json.loads((self.output/'battle/spells.json').read_text())
        stages=[r for r in spells['unite_reactions'] if r['record']==29]
        self.assertEqual([r['variant'] for r in stages],[1,2])
        self.assertEqual(len(stages[0]['sounds']),17)
        proof=json.loads((self.output/'battle/provenance.json').read_text())
        self.assertIn('martial_arts',proof)
        self.assertEqual({r['id'] for r in proof['martial_arts']['ordinary_graphics']},{'eikei','morgan'})

    def test_reserve_catalogue_is_not_recruitment_and_matches_source_stats_and_pixels(self):
        import character_table
        from test_battle_trial_export import source_pose
        self.assertEqual(self.battle['schema'],'suikoden-battle-trial/43')
        self.assertEqual(self.battle['initial_party'],['hero','gremio','pahn','viktor','yam_koo','tai_ho'])
        profile=next(p for p in self.battle['party'] if p['id']=='maas')
        # Follow the zero-equipped-items branch of the source stat consumer.
        check_stat_consumer()
        assert_words({
            0x800D4F84: (0x9142001F, 0, 0x18400026, 0x00004821),
            0x800D5048: (0x91420044, 0, 0x00021080, 0x3C018016, 0x24215890, 0x00220821,
                         0x8C220000, 0x91430045, 0x90420054, 0x3C048016, 0x248459D0,
                         0x00031840, 0x00021140, 0x00441021, 0x00621821, 0x9502000C, 0x9463FFFE),
        })
        raw=character_table.image()[0x33274+65*80:0x33274+66*80]
        self.assertEqual(struct.unpack_from('<I',raw)[0],70)
        self.assertEqual((raw[0x46], raw[0x4C]), (0, 0))  # No element or rune stat modifier.
        weapon, level = raw[0x44:0x46]
        metadata = main.mword(0x80165890 + 4 * weapon)
        curve = main.body()[metadata - main.MBASE + 0x54]
        power, = struct.unpack_from('<H', main.body(), 0x801659D0 - main.MBASE + 32 * curve + 2 * (level - 1))
        expected = list(raw[0x10:0x16])
        expected[0] += power
        self.assertEqual([profile['stats'][k] for k in ('attack','skill','defense','speed','magic','luck')],expected)
        self.assertEqual((profile['level'],profile['max_hp'],profile['weapon']['initial_level']),(raw[13],struct.unpack_from('<H',raw,4)[0],raw[69]))
        actor,_=source('/MAA.BIN');section=struct.unpack_from('<I',actor,36)[0]
        pixels,ax,ay=source_pose(actor,section,0,0,0)
        with Image.open(self.output/'battle/actors.png') as atlas:
            pose=profile['sprite'];r=pose['rect']
            self.assertEqual(atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes(),pixels.tobytes())
        self.assertEqual((pose['anchor_x'],pose['anchor_y']),(ax,ay))
        proof=json.loads((self.output/'battle/provenance.json').read_text())['reserve_catalogue']
        self.assertFalse(proof['initially_owned'])
        self.assertEqual((proof['native_id'],proof['record_image_offset']),(70,0x33274+65*80))

    def test_kobold_destination_and_unexported_population_are_explicit(self):
        room=next(r for r in self.package['rooms'] if r['id']=='vb6_kobold_village')
        self.assertEqual((room['width'],room['height']),(384,384))
        self.assertEqual(room['npcs'],[])
        proof=next(r for r in self.proof['journey']['rooms'] if r['room']==6)
        self.assertTrue({33,34,35}.issubset(proof['omitted_entities']))
        self.assertEqual(len(proof['omitted_entities']),26)
        self.assertEqual(self.proof['journey']['kobold_exit']['world_coordinates'],[59,38])
        self.assertEqual(self.raw[0x350FC:0x35102],bytes.fromhex('03 fb 02 3b 26 fd'))
        self.assertTrue(all(e['room'] in ('vb6_forest_clearing',) for e in room['exits']))

    def test_source_doorway_predicates_and_actual_transition_opcode(self):
        check_transition_consumers()
        assert_words({
            0x8013DCEC: (0x9063BD74,),
            0x8013DD18: (0x9063BD75,),
            0x8013DD44: (0x8C63BDCC, 0x00021080, 0x3C018017, 0x24211708,
                         0x00220821, 0x8C220000, 0, 0x00621824, 0x146000A7),
            0x8013DF04: (0x1040003F, 0x26100001, 0x0804F806, 0x00001021),
        })
        data = self.raw

        def pointer(offset):
            return struct.unpack_from('<I', data, offset)[0] - 0x80010000

        room_table = pointer(pointer(0) + 8)
        room_links = self.proof['journey']['room_links']
        expected_links = {(room, index) for room, count in ((1, 2), (2, 4), (3, 6), (4, 4), (5, 2), (6, 1), (10, 1))
                          for index in range(count)} | {(0, 0), (0, 5)}
        self.assertEqual(len(room_links), len(expected_links))
        self.assertEqual({(link['room'], link['entity']) for link in room_links}, expected_links)
        for link in room_links:
            number, index = link['room'], link['entity']
            room = next(room for room in self.package['rooms'] if room['id'] == export.ROOMS[number])
            entry = pointer(room_table + number * 16) + index * 24
            self.assertEqual(struct.unpack_from('<H', data, entry + 4)[0] & 0x10, 0)
            predicate, stream = pointer(entry + 16), pointer(entry + 20)
            self.assertEqual((predicate, stream), (link['predicate'], link['stream']))

            x_opcode, x0, x1 = data[predicate:predicate + 3]
            self.assertEqual(x_opcode, 0x0B)
            cursor = predicate + 3
            # For X-only guards the episode uses room height, capped at 48 cells.
            y0, y1 = 0, min(room['height'] // 8, 48) - 1
            if data[cursor] == 0x0C:
                y0, y1 = data[cursor + 1:cursor + 3]
                cursor += 3
            requires_up = data[cursor] == 4
            if requires_up:
                self.assertEqual(data[cursor + 1], 0)
                cursor += 2
            self.assertEqual(data[cursor], 6)

            prefix = bytes.fromhex(link['prefix'])
            transition = stream + len(prefix)
            self.assertEqual(data[stream:transition], prefix)
            opcode, target, x, y, end = data[transition:transition + 5]
            self.assertEqual((opcode, end), (3, 0xFD))
            script = decode_stream(data[stream:transition + 5])
            self.assertEqual([row[:3] for row in script[-2:]],
                             [(len(prefix), 3, bytes((target, x, y))), (len(prefix) + 4, 0xFD, b'')])

            door, = [door for door in room['exits'] if (door['room'], door['spawn_x'], door['spawn_y'])
                     == (export.ROOMS[target], x * 8, y * 8)]
            self.assertEqual((door['x'], door['y'], door['w'], door['h']),
                             (x0 * 8, y0 * 8, (x1 - x0 + 1) * 8, (y1 - y0 + 1) * 8), (number, index))
            self.assertEqual(door.get('direction'), 'up' if requires_up else None, (number, index))

    def test_treasure_identity_flag_and_dialogue_tables_are_not_guessed(self):
        d=self.raw
        ptr=lambda p:struct.unpack_from('<I',d,p)[0]-0x80010000
        room_table=ptr(ptr(0)+8);entities=ptr(room_table+32)
        for treasure,entity,item,flag_byte in zip(self.config['treasures'],[4,5],[71,58],[16,32],strict=True):
            entry=entities+24*entity;classification=ptr(entry+12);predicate=ptr(entry+16);stream=ptr(entry+20)
            self.assertEqual(d[classification:classification+4],bytes([8,174,flag_byte,6]))
            self.assertEqual(d[predicate:predicate+5],bytes([8,174,flag_byte,5,6]))
            self.assertEqual(d[stream:stream+8],bytes([9,174,flag_byte,65,116,73,item,73]))
            name=decode(main.body(),main.mword(0x80167658+4*item)-0x800C0800)[0]
            self.assertEqual(name,{'needle':'Needle','water_rune_piece':'Water rune piece'}[treasure['item']])
            npc=next(n for r in self.package['rooms'] for n in r['npcs'] if n['id']==treasure['npc'])
            self.assertEqual((npc['x'],npc['y']),tuple(v*8 for v in struct.unpack_from('<HH',d,entry)))
            self.assertEqual(npc['hidden_by'],treasure['flag']);self.assertEqual(npc['marker'],'treasure')
        event=next(e for r in self.package['rooms'] for e in r.get('events',[]) if e['id']=='elf_sighting')
        table=ptr(ptr(ptr(0)+20));pages=[]
        for index in [1,2]:pages.extend(p.strip() for p in decode(d,ptr(table+4*index))[0].split('[---]'))
        self.assertEqual(event['pages'],pages)
        self.assertEqual(event['requires'],'heard_forest_warning') # Explicit port prerequisite, not the original chapter flags.

    def test_enemy_drop_records_and_elemental_coefficients(self):
        area,_=source('/A_DATA.BIN')
        import maindec
        for enemy,address in zip(self.battle['enemies'][:5],[0x8009F3FC,0x800A33DC,0x800A1A5C,0x800A5348,0x800A0E34],strict=True):
            raw=area[address-0x80080000:address-0x80080000+64]
            self.assertEqual(enemy['fire_affinity'],['neutral','weak','resistant','immune'][raw[32]])
            flags=struct.unpack_from('<H',raw,38)[0]
            self.assertEqual(enemy['other_affinity'], ['neutral','weak','resistant','immune'][raw[0x25]])
            self.assertEqual(enemy['death_immune'], bool(flags & 0x4000))
            self.assertEqual(enemy['dodges_attacks'], bool(flags&4))
            self.assertEqual(enemy['unavoidable_attack'], bool(flags&8))
            for drop,(native_id,rate) in zip(enemy['drops'],zip(raw[54:60:2],raw[55:60:2]),strict=True):
                self.assertEqual(drop['rate'],rate)
                if native_id:
                    p=maindec.mword(0x80167658+4*native_id)
                    self.assertEqual(decode(maindec.body(),p-maindec.MBASE)[0].lower().replace(' ','_'),drop['item'])
                else:self.assertIsNone(drop['item'])

    def test_added_enemy_pixels_stats_callbacks_and_rosters_have_independent_witnesses(self):
        from test_export_unite_review import vram_pose
        area,_=source('/A_DATA.BIN')
        with Image.open(self.output/'battle/actors.png') as atlas:
            for profile,address,callback in zip(self.battle['enemies'][2:5],[0x800A1A5C,0x800A5348,0x800A0E34],[0x80080604,0x80080ADC,0x80080004],strict=True):
                raw=area[address-0x80080000:address-0x80080000+64]
                self.assertEqual(struct.unpack_from('<I',raw,48)[0],callback)
                self.assertEqual(decode(raw,length=16)[0],profile['name'])
                self.assertEqual(struct.unpack_from('<H',raw,18)[0],profile['max_hp'])
                self.assertEqual(list(struct.unpack_from('<6H',raw,20)),
                                 [profile['stats'][key] for key in ('attack','skill','defense','speed','magic','luck')])
                section=struct.unpack_from('<I',raw,44)[0]-0x80080000
                frame_table=struct.unpack_from('<I',area,section+20)[0]-0x80080000
                frame=struct.unpack_from('<I',area,frame_table)[0]-0x80080000
                expected, anchor_x, anchor_y=vram_pose(area,section,area[frame+4],base=0x80080000)
                rect=profile['sprite']['rect']
                actual=atlas.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h']))
                self.assertEqual(actual.tobytes(),expected.tobytes())
                self.assertEqual((profile['sprite']['anchor_x'], profile['sprite']['anchor_y']),
                                 (anchor_x, anchor_y))
        self.assertEqual([next(e['enemies'] for e in self.battle['encounters'] if e['id']==f'area_a_{number}') for number in (4,6,9)],
                         [['crow','crow'],['red_soldier_ant'],['wild_boar','crow','crow']])
        self.assertEqual([e['encounter'] for e in self.config['encounters']],
                         ['area_a_2','area_a_4','area_a_6'])

    def test_all_new_actor_track_pixels_match_independent_vram_sampling(self):
        from test_battle_trial_export import source_pose
        import export_battle_trial as producer
        sources=['/SHU.BIN','/GRE.BIN','/PAN.BIN','/VIC.BIN','/YAM.BIN','/TAI.BIN','/MAA.BIN']
        with Image.open(self.output/'battle/actors.png') as atlas:
            for profile,suffix in zip(self.battle['party'][:len(sources)],sources,strict=True):
                raw,_=source(suffix);section=struct.unpack_from('<I',raw,36)[0]
                poses,animations,_=producer.section_art(raw,section)
                native={};checked=set()
                for frame in profile['cast']+[frame for scene in profile.get('unite_scenes',[]) for frame in scene['track']['attack']]:
                    pose=frame['pose'];r=pose['rect'];image=atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
                    self.assertLess(frame['source_pose'],len(poses))
                    self.assertEqual(poses[frame['source_pose']][0].tobytes(),image.tobytes())
                    self.assertEqual(poses[frame['source_pose']][1:],(pose['anchor_x'],pose['anchor_y']))
                    identity=(r['x'],r['y'],r['w'],r['h'])
                    if identity in checked:continue
                    checked.add(identity)
                    match=next(( (a,k) for a,pairs in enumerate(animations) for k,(e,_) in enumerate(pairs) if poses[e][0].size==image.size and poses[e][0].tobytes()==image.tobytes()),None)
                    self.assertIsNotNone(match)
                    if match not in native:native[match]=source_pose(raw,section,0,*match)
                    expected,ax,ay=native[match]
                    self.assertEqual((ax,ay),(pose['anchor_x'],pose['anchor_y']))
                    self.assertEqual(expected.tobytes(),image.tobytes())
                self.assertGreater(len(checked),1)

    def test_exported_actor_tracks_and_fixed_camera_bounds(self):
        content=self.battle;camera=content['camera']
        xyz=lambda p:[p[k] for k in 'xyz']
        def project(point):
            transformed=[sum(row[j]*point[j] for j in range(3))+row[3] for row in camera['transform']]
            return (camera['center_x']+camera['focal_length']*transformed[0]/transformed[2],camera['center_y']+camera['focal_length']*transformed[1]/transformed[2],transformed[2])
        def leap(start,end,movement,tick):
            duration=movement['ticks']
            if tick>=duration:return end
            factor=tick*(tick-1)/(duration*(duration-1))
            velocity=xyz(movement['velocity'])
            return [start[j]+velocity[j]*tick+(end[j]-start[j]-velocity[j]*duration)*factor for j in range(3)]
        def position(home,target,movement,tick):
            if tick<movement['approach_start']:return home
            previous=home
            for stage in movement.get('stages',[dict(start=movement['approach_start'],leap=movement['approach'])]):
                end=[target[j]+xyz(stage['leap']['offset'])[j] for j in range(3)]
                if tick<stage['start']:return previous
                if tick<stage['start']+stage['leap']['ticks']:return leap(previous,end,stage['leap'],tick-stage['start'])
                previous=end
            return previous if tick<movement['return_start'] else leap(previous,home,movement['retreat'],tick-movement['return_start'])
        targets={tuple(xyz(p)) for encounter in content['encounters'] for p in encounter['positions']}
        cache={};samples=0
        with Image.open(self.output/'battle/actors.png') as atlas:
            for actor in content['party']:
                tracks=[('attack',actor['attack'],actor['motion']),('cast',actor['cast'],None)]+[(f"unite_{s['record']}",s['track']['attack'],s['track']['motion']) for s in actor.get('unite_scenes',[])]
                for frames_key,frames,movement in tracks:
                    if not frames:
                        continue
                    duration=sum(frame['ticks'] for frame in frames)
                    for source_home in content['formation_slots']:
                        home=xyz(source_home)
                        for target in (targets if movement else [home]):
                            for tick in range(duration+1):
                                elapsed=tick;pose=frames[-1]['pose']
                                for frame in frames:
                                    if elapsed<frame['ticks']:pose=frame['pose'];break
                                    elapsed-=frame['ticks']
                                rect=pose['rect'];identity=tuple(rect[k] for k in ['x','y','w','h'])
                                if identity not in cache:cache[identity]=atlas.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h'])).getchannel('A').getbbox()
                                box=cache[identity];self.assertIsNotNone(box)
                                x,y,depth=project(position(home,target,movement,tick) if movement else home)
                                self.assertGreater(depth,0,(actor['id'],frames_key,tick))
                                # Unite clips use the live round camera and can leave the frame mid-action.
                                if frames_key in ('attack', 'cast'):
                                    scale=max(.25,min(4,content['sprite_scale']*project(home)[2]/depth))
                                    bounds=[x+(box[0]-pose['anchor_x'])*scale,y+(box[1]-pose['anchor_y'])*scale,x+(box[2]-pose['anchor_x'])*scale,y+(box[3]-pose['anchor_y'])*scale]
                                    witness=(actor['id'],frames_key,source_home,target,tick,bounds)
                                    self.assertGreaterEqual(bounds[0],8,witness);self.assertGreaterEqual(bounds[1],40,witness)
                                    self.assertLessEqual(bounds[2],632,witness);self.assertLessEqual(bounds[3],336,witness)
                                samples+=1
        self.assertGreater(samples,30000)

if __name__=='__main__':unittest.main()
