"""Independent source scripts and shared-VM Commander export witness."""
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from export_first_room import source
import export_enemy_orders
import export_counter_actors
from test_physical_rune_export import independent_stream


def witness():
    packet = export_enemy_orders.build()
    counters, proof = export_counter_actors.build(include_area_a=False, include_later=True)
    defender = next(row for row in counters['defenders'] if row['id'] == 'hero')
    enemy = next(row for row in counters['enemies'] if row['id'] == 'flying_squirrel')
    parry_enemy = next(row for row in counters['enemies'] if row['id'] == 'kobold_type_1')
    parry_attacker = next(row for row in counters['parries']['attackers'] if row['id'] == 'hero')
    parry_defender = next(row for row in counters['parries']['defenders'] if row['id'] == 'kobold_type_1')
    melee = next(row for row in counters['melee']['enemies'] if row['id'] == 'flying_squirrel')
    reaction = next(row for row in counters['melee']['party_reactions'] if row['id'] == 'hero')
    packet['ordered_ally'] = dict(defenders=[defender], enemies=[enemy, parry_enemy],
        parries=dict(attackers=[parry_attacker], defenders=[parry_defender]), melee=dict(enemies=[melee], party_reactions=[reaction]))
    required = {value for row in (defender, enemy, parry_enemy, parry_attacker, parry_defender, melee, reaction)
                for key, value in row.items() if key.endswith('_program') and value is not None}
    programs = {row['id']: row for row in counters['programs']['programs']}
    pending = list(required)
    while pending:
        for instruction in programs[pending.pop()]['instructions']:
            child = instruction.get('command', {}).get('child')
            if child and child['program'] not in required:
                required.add(child['program'])
                pending.append(child['program'])
    selected = [programs[key] for key in sorted(required)]
    packet['programs']['programs'].extend(selected)
    resources = {'hero', 'flying_squirrel', 'kobold_type_1'}
    for program in selected:
        for instruction in program['instructions']:
            child = instruction.get('command', {}).get('child')
            if child:
                resources.add(child['resource'])
    packet['animations']['resources'].extend(row for row in counters['animations']['resources'] if row['id'] in resources)
    packet['provenance']['ordered_programs'] = [row for row in proof['programs'] if row['id'] in required]
    packet['provenance']['ordered_resources'] = [row for row in proof['resources'] if row['id'] in resources]
    return packet


class EnemyOrders(unittest.TestCase):
    def test_bundle_merge_preserves_existing_programs_resources_and_input(self):
        original = json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        original['schema']='suikoden-unite-actors/31'
        original.pop('commander',None)
        original.pop('group_orders',None)
        original.pop('enemy_wave',None)
        original['counter']['melee']['enemies']=[row for row in original['counter']['melee']['enemies'] if row['id'] not in ('killer_rabbit','ninja_master','dagon')]
        combined = export_enemy_orders.combine(original)
        self.assertEqual(original['schema'], 'suikoden-unite-actors/31')
        self.assertNotIn('commander', original)
        self.assertEqual(combined['schema'], 'suikoden-unite-actors/32')
        programs = {row['id']: row for row in combined['programs']['programs']}
        for row in original['programs']['programs']:
            self.assertEqual(row, programs[row['id']])
        self.assertEqual(export_enemy_orders.combine(combined), combined)
        commander = next(r for r in combined['animations']['resources'] if r['id'] == 'beast_commander')
        self.assertIn(11, [clip['id'] for clip in commander['clips']])
        self.assertIn(19, [clip['id'] for clip in commander['clips']])
    def test_source_profile_formation_and_all_body_pixels_use_the_shared_pipeline(self):
        from PIL import Image
        from export_first_room import Atlas
        from test_export_unite_review import vram_pose
        battle=json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text())
        actors=json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        battle['enemies']=[row for row in battle['enemies'] if row['id']!='beast_commander']
        battle['encounters']=[row for row in battle['encounters'] if row['id']!='area_b_1']
        battle['unite_graphics']=[row for row in battle['unite_graphics'] if row['id']!='beast_commander']
        atlas=Atlas();atlas.image=Image.new('RGBA',(4096,4096),(0,0,0,0))
        atlas.image.paste((19,31,47,255),(0,0,4096,3));atlas.y=4
        proof=export_enemy_orders.append_content(battle,actors,atlas)
        self.assertEqual(battle['schema'],'suikoden-battle-trial/43')
        self.assertEqual(proof['formations'],['area_b_1'])
        self.assertEqual(atlas.image.getpixel((4095,2)),(19,31,47,255))
        raw,_=source('/B_DATA.BIN');record=0x22208;section=struct.unpack_from('<I',raw,record+44)[0]-0x80080000
        profile=battle['enemies'][-1]
        self.assertEqual(profile['action_policy'],'source_commander')
        self.assertNotIn('commander',profile)
        self.assertNotIn('commander_order',profile)
        self.assertEqual(profile['knockout_ticks'],94)
        self.assertEqual(profile['max_hp'],struct.unpack_from('<H',raw,record+18)[0])
        self.assertEqual(profile['stats'],dict(zip(('attack','skill','defense','speed','magic','luck'),struct.unpack_from('<6H',raw,record+20))))
        graphic=next(row for row in battle['unite_graphics'] if row['id']=='beast_commander')
        self.assertEqual({row['id'] for row in graphic['poses']},set(range(9)))
        for row in graphic['poses']:
            image,ax,ay=vram_pose(raw,section,row['id'],packet=True,base=0x80080000)
            pose=row['sprite'];r=pose['rect']
            actual=atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
            self.assertEqual((actual.size,pose['anchor_x'],pose['anchor_y']),(image.size,ax,ay))
            self.assertEqual(actual.tobytes(),image.tobytes())
        formation=battle['encounters'][-1]
        self.assertEqual(formation['source_slots'],[0,1,2,3])
        self.assertEqual(formation['enemies'],['flying_squirrel']*3+['beast_commander'])
        with self.assertRaisesRegex(ValueError,'already present'):
            export_enemy_orders.append_content(battle,actors,atlas)

    def test_raw_primary_and_child_streams_independently_agree(self):
        packet = export_enemy_orders.build()
        raw, _ = source('/B_DATA.BIN')
        self.assertEqual(packet['programs']['schema'], 'suikoden-actor-programs/12')
        self.assertEqual(len(packet['programs']['programs']), 4)
        for program in packet['provenance']['programs']:
            self.assertEqual(len(program['spans']), 1)
            start = program['spans'][0]['source_offset']
            self.assertEqual(program['operations'], independent_stream(raw, start, 0x22248, 0x80080000))
        self.assertEqual(packet['binding']['selection_delay'], 60)

    def test_child_uses_commander_art_and_target_home_without_copying_parent_color(self):
        packet = export_enemy_orders.build()
        owner = next(p for p in packet['programs']['programs'] if p['id'].endswith('/solo'))
        child = next(i['command']['child'] for i in owner['instructions'] if 'child' in i.get('command', {}))
        self.assertEqual(child, dict(program='commander/beast_commander/auxiliary/member_5', resource='beast_commander', animation=19, owner='self', home='parent_owner', draw_record=False, offset=[5, 0, -30]))
        self.assertEqual([c['id'] for c in packet['animations']['resources'][0]['clips']], [0, 1, 3, 7, 8, 9, 16, 17, 18, 19])

    def test_export_is_repeatable_and_native_fixture_is_current(self):
        self.assertEqual(export_enemy_orders.build(), export_enemy_orders.build())
        self.assertEqual(witness(), json.loads((ROOT/'game/tests/fixtures/enemy_order_source.json').read_text()))

    def test_raw_frame_pairs_and_attachments_agree_for_every_selected_animation(self):
        packet = export_enemy_orders.build()
        raw, _ = source('/B_DATA.BIN')
        pointer = lambda offset: struct.unpack_from('<I', raw, offset)[0] - 0x80080000
        section = pointer(0x22208 + 44)
        frames, poses = pointer(section + 20), pointer(section + 16)
        resource = packet['animations']['resources'][0]
        self.assertEqual(resource['pose_count'], struct.unpack_from('<H', raw, section)[0])
        for clip in resource['clips']:
            start = pointer(frames + 4 * clip['id'])
            expected = []
            for index in range(raw[start]):
                pose, updates = raw[start + 4 + 2*index:start + 6 + 2*index]
                entry = pointer(poses + 4 * pose)
                expected.append(dict(pose=pose, updates=updates or 256,
                    attachment=[raw[entry+6]-raw[entry+4], raw[entry+7]-raw[entry+5]]))
            self.assertEqual(clip['frames'], expected)
            for flag, bit in (('advances', 1), ('loop', 2), ('semitransparent', 4)):
                self.assertEqual(clip[flag], bool(raw[start+1] & bit))


if __name__ == '__main__':
    if '--write-fixture' in sys.argv:
        (ROOT/'game/tests/fixtures/enemy_order_source.json').write_text(json.dumps(witness(), separators=(',', ':'))+'\n')
        sys.argv.remove('--write-fixture')
    unittest.main()
