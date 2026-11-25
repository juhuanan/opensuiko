"""Independent static Ninja Master streams, animation records and HP callback."""
import hashlib
import copy
import json
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
from export_first_room import source
import export_enemy_ninja as exporter
from test_physical_rune_export import independent_stream


class NinjaSource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packet = exporter.build()
        cls.raw, cls.origin = source('/Z_DATA.BIN')

    def test_every_root_and_child_agrees_with_independent_stream_reader(self):
        main, _ = source('MAIN.EXE')
        self.assertEqual(len(self.packet['programs']['programs']), 10)
        for program in self.packet['provenance']['programs']:
            span = program['spans'][0]
            raw = main if span['source']['file'] == 'MAIN.EXE' else self.raw
            self.assertEqual(program['operations'], independent_stream(
                raw, span['source_offset'], 0x207c8 if raw is self.raw else None,
                0x80080000 if raw is self.raw else 0))
            for span in program['spans']:
                body = raw[span['source_offset']:span['source_offset']+span['byte_length']]
                self.assertEqual(hashlib.sha256(body).hexdigest(), span['sha256'])
        ids = {p['id'] for p in self.packet['programs']['programs']}
        for family in ('ordinary', 'special'):
            for key, value in self.packet[family].items():
                if key.endswith('_program'):
                    self.assertIn(value, ids)
        spawns = [i['command']['child'] for p in self.packet['programs']['programs']
                  for i in p['instructions'] if 'child' in i.get('command', {})]
        self.assertEqual({s['resource'] for s in spawns}, {'ninja_master', 'shared_impacts'})
        for spawn in spawns:
            self.assertIn(spawn['program'], ids)

    def test_animation_flags_frames_durations_and_attachments_match_raw_tables(self):
        raw = self.raw
        pointer = lambda offset: int.from_bytes(raw[offset:offset+4], 'little') - 0x80080000
        section = pointer(0x20788+44)
        frames, poses = pointer(section+20), pointer(section+16)
        resource = self.packet['animations']['resources'][0]
        self.assertEqual(resource['id'], 'ninja_master')
        self.assertEqual(resource['pose_count'], int.from_bytes(raw[section:section+2], 'little'))
        self.assertEqual([c['id'] for c in resource['clips']],
                         [0, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17])
        for clip in resource['clips']:
            cursor = pointer(frames + 4*clip['id']); expected = []
            for i in range(max(1, raw[cursor])):
                pose, duration = raw[cursor+4+2*i:cursor+6+2*i]
                entry = pointer(poses+4*pose)
                expected.append(dict(pose=pose, updates=duration or 256,
                    attachment=[raw[entry+6]-raw[entry+4], raw[entry+7]-raw[entry+5]]))
            self.assertEqual(clip['frames'], expected)
            for key, bit in (('advances', 1), ('loop', 2), ('semitransparent', 4)):
                self.assertEqual(clip[key], bool(raw[cursor+1] & bit))

    def test_contact_and_return_signals_gate_three_halves_damage_and_cleanup(self):
        word = lambda offset: struct.unpack_from('<I', self.raw, offset)[0]
        for offset, expected in {
            0x49c:0x96620040, 0x4a4:0x30420002, 0x4a8:0x1040001b,
            0x4b8:0x8c42000c, 0x4c0:0x0040f809,
            0x4c8:0x00022840, 0x4cc:0x00a22821,
            0x4d8:0x000517c2, 0x4dc:0x8c630010, 0x4e0:0x00a22821,
            0x4e4:0x0060f809, 0x4e8:0x00052843,
            0x4f8:0x3c06800a, 0x4fc:0x24c608d4,
            0x510:0x3042fffd, 0x514:0xa6620040,
            0x520:0x30420004, 0x524:0x14400003,
            0x540:0x3c06800a, 0x544:0x24c60a9c,
        }.items():
            self.assertEqual(word(offset), expected, hex(offset))
        self.assertEqual(self.packet['impact'], dict(damage_numerator=3, damage_denominator=2,
                                                    contact_signal=2, return_signal=4))
        proof = next(p for p in self.packet['provenance']['programs'] if p['id'].endswith('/special/owner'))
        self.assertEqual([o['args'] for o in proof['operations'] if o['op'] == 26], [[0, 2], [0, 4]])
        self.assertIn(dict(op=35, args=[0, 4]), proof['operations'])
        recipient = next(p for p in self.packet['provenance']['programs'] if p['id'].endswith('/special/recipient'))
        self.assertIn(dict(op=40, args=[6, 30]), recipient['operations'])
        compiled = next(p for p in self.packet['programs']['programs'] if p['id'] == recipient['id'])
        self.assertIn(dict(command=dict(status=dict(kind='rune_blocked', threshold_percent=30))), compiled['instructions'])

    def test_changed_source_is_refused_and_build_is_repeatable(self):
        self.assertEqual(self.packet, exporter.build())
        self.assertEqual(self.packet, json.loads((ROOT/'game/tests/fixtures/enemy_ninja_source.json').read_text()))
        real_source = exporter.source
        for offset in (0x1a8, 0x2fc, 0x4e8, 0x20788+38, 0x20788+48):
            changed = bytearray(self.raw); changed[offset] ^= 1
            def altered(name):
                return (bytes(changed), self.origin) if name == '/Z_DATA.BIN' else real_source(name)
            with patch.object(exporter, 'source', side_effect=altered):
                with self.assertRaises(ValueError):
                    exporter.build()

    def test_merge_preserves_the_library_and_refuses_conflicting_bindings(self):
        original = json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        before = copy.deepcopy(original)
        combined = exporter.combine(original, self.packet)
        self.assertEqual(original, before)
        self.assertEqual(combined['schema'], original['schema'])
        self.assertEqual(exporter.combine(combined, self.packet), combined)
        self.assertEqual(combined['unites'], original['unites'])
        changed = copy.deepcopy(self.packet)
        changed['melee']['special']['damage_denominator'] = 1
        with self.assertRaisesRegex(ValueError, 'Conflicting Ninja'):
            exporter.combine(combined, changed)

    def test_normal_admission_uses_raw_profile_whole_z_rosters_and_independent_pixels(self):
        from PIL import Image
        from export_first_room import Atlas
        from test_export_unite_review import vram_pose
        from battle_placement import area_encounters
        import preparation
        battle=json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text())
        actors=json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        added={f'area_z_{n}' for n in (1,2,3,4,11,12,13)}
        battle['enemies']=[e for e in battle['enemies'] if e['id']!='ninja_master']
        battle['encounters']=[e for e in battle['encounters'] if e['id'] not in added]
        battle['unite_graphics']=[g for g in battle['unite_graphics'] if g['id']!='ninja_master']
        atlas=Atlas();atlas.image=Image.new('RGBA',(4096,4096));atlas.y=4
        atlas.image.paste((17,31,49,255),(0,0,4096,3))
        proof=exporter.append_content(battle,actors,atlas)
        preparation.bind_weapon_elements(battle)
        self.assertEqual(battle['schema'],'suikoden-battle-trial/43')
        self.assertEqual(actors['schema'],'suikoden-unite-actors/40')
        self.assertEqual(atlas.image.getpixel((4095,2)),(17,31,49,255))
        self.assertEqual({r['id'] for r in proof['catalogue']['formations']},added)
        raw=self.raw;record=0x20788
        profile=battle['enemies'][-1]
        self.assertEqual(profile['action_policy'],'source_ninja')
        self.assertEqual(profile['level'],raw[record+16])
        self.assertEqual(profile['max_hp'],struct.unpack_from('<H',raw,record+18)[0])
        self.assertEqual(profile['stats'],dict(zip(('attack','skill','defense','speed','magic','luck'),struct.unpack_from('<6H',raw,record+20))))
        self.assertEqual(profile['effect_offset'],list(struct.unpack_from('<2h',raw,record+60)))
        self.assertEqual(profile['knockout_ticks'],94)
        encoded=struct.unpack_from('<h',raw,record+52)[0]
        self.assertEqual(profile['money'],int(encoded/10)*100 if encoded&1 else encoded)
        table=struct.unpack_from('<I',raw,record+40)[0]-exporter.BASE
        ko=independent_stream(raw,struct.unpack_from('<I',raw,table+28)[0]-exporter.BASE,table,exporter.BASE)
        self.assertEqual([op['args'] for op in ko if op['op']==3],[[1],[90],[1]])
        self.assertEqual([op['args'] for op in ko if op['op']==30],[[0],[99]])
        self.assertIn(dict(op=4,args=[3]),ko)
        for index,element in enumerate(('fire','water','earth','lightning','wind')):
            self.assertEqual(profile['affinities'][element],('neutral','weak','resistant','immune')[raw[record+32+index]])
        self.assertEqual(profile['other_affinity'],('neutral','weak','resistant','immune')[raw[record+37]])
        self.assertFalse(profile['death_immune'] or profile['airborne'] or profile['dodges_attacks'] or profile['unavoidable_attack'])
        self.assertEqual([drop['rate'] for drop in profile['drops']],list(raw[record+55:record+60:2]))
        import item_tables
        from preparation import stable_id
        native_drop=next(item for item in item_tables.items() if item['id']==raw[record+54])
        self.assertEqual(profile['drops'][0]['item'],stable_id(native_drop['name']))
        self.assertEqual(profile['drops'][0]['identified'],not bool(item_tables.half(native_drop['addr']+28)&0x7000))
        native={1:'ninja_master',2:'simurgh',3:'orc'}
        for entry in area_encounters(raw)['encounters']:
            encounter=next(e for e in battle['encounters'] if e['id']==f'area_z_{entry["index"]}')
            self.assertEqual(encounter['enemies'],[native[n] for n in entry['roster'] if n])
            self.assertEqual(encounter['source_slots'],[s['slot'] for s in entry['slots']])
        graphic=next(g for g in battle['unite_graphics'] if g['id']=='ninja_master')
        trails=pieces=0
        def pixels(sprite):
            r=sprite['rect'];return atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
        for pose in graphic['poses']:
            image,ax,ay=vram_pose(raw,0x20d20,pose['id'],packet=True,base=exporter.BASE)
            self.assertEqual((pixels(pose['sprite']).size,pose['sprite']['anchor_x'],pose['sprite']['anchor_y']),(image.size,ax,ay))
            self.assertEqual(pixels(pose['sprite']).tobytes(),image.tobytes())
            for ordinal,piece in enumerate(pose.get('pieces',[])):
                expected,px,py=vram_pose(raw,0x20d20,pose['id'],base=exporter.BASE,piece_index=ordinal)
                self.assertEqual((pixels(piece).size,piece['anchor_x'],piece['anchor_y']),(expected.size,px,py))
                self.assertEqual(pixels(piece).tobytes(),expected.tobytes());pieces+=1
            for age,frozen in enumerate(pose.get('trail',[])):
                factors=[255*(7-age)//7]*2+[255];expected=image.copy()
                expected.putdata([(*[min(31,(p[a]>>3)*factors[a]//128)*8+min(31,(p[a]>>3)*factors[a]//128)//4 for a in range(3)],p[3]) for p in image.get_flattened_data()])
                self.assertEqual(pixels(frozen).tobytes(),expected.tobytes());trails+=1
        self.assertEqual(trails,8)
        self.assertGreater(pieces,0)
        with self.assertRaisesRegex(ValueError,'already present'):exporter.append_content(battle,actors,atlas)


if __name__ == '__main__':
    unittest.main()
