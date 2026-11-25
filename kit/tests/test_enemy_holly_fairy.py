"""Independent static Holly Fairy scripts, frames and delegated-wave consumers."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
from export_first_room import source
from test_physical_rune_export import independent_stream
import export_enemy_holly_fairy as exporter


class HollyFairySource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packet = exporter.build()
        cls.raw, cls.origin = source('/D_DATA.BIN')
        cls.main, _ = source('MAIN.EXE')

    def word(self, offset):
        return struct.unpack_from('<I', self.raw, offset)[0]

    def test_independent_streams_and_animation_frames(self):
        self.assertEqual(len(self.packet['programs']['programs']), 8)
        for row in self.packet['provenance']['programs']:
            span = row['spans'][0]
            raw = self.main if span['source']['file'] == 'MAIN.EXE' else self.raw
            self.assertEqual(row['operations'], independent_stream(raw, span['source_offset'],
                0x20820 if raw is self.raw else None, exporter.BASE if raw is self.raw else 0))
            for span in row['spans']:
                self.assertEqual(hashlib.sha256(raw[span['source_offset']:span['source_offset']+span['byte_length']]).hexdigest(), span['sha256'])
        p = lambda off: self.word(off)-exporter.BASE
        section = p(0x207e0+44)
        frames, poses = p(section+20), p(section+16)
        clips = self.packet['animations']['resources'][0]['clips']
        self.assertEqual(len(clips), 14)
        for clip in clips:
            cursor = p(frames+4*clip['id'])
            expected = []
            for i in range(max(1, self.raw[cursor])):
                pose, updates = self.raw[cursor+4+2*i:cursor+6+2*i]
                entry = p(poses+4*pose)
                expected.append(dict(pose=pose, updates=updates or 256,
                    attachment=[self.raw[entry+6]-self.raw[entry+4], self.raw[entry+7]-self.raw[entry+5]]))
            self.assertEqual(clip['frames'], expected)
            for key, mask in (('advances', 1), ('loop', 2), ('semitransparent', 4)):
                self.assertEqual(clip[key], bool(self.raw[cursor+1]&mask))

    def test_front_scan_consumes_failed_turn_and_uses_remainder(self):
        for offset, value in {
            0x1f4:0x90420044, 0x1fc:0x2c420004, 0x214:0x3c06800a,
            0x218:0x24c60938, 0x228:0x24420358, 0x22c:0xae42000c,
            0x258:0x92620005, 0x268:0x92020045, 0x278:0x92020044,
            0x280:0x2c420004, 0x2a8:0x0043001a, 0x2d0:0x00001810,
            0x2d8:0x28630033, 0x2f8:0xae55125c, 0x318:0xa0750049,
            0x320:0xa0620046, 0x328:0x00001021, 0x32c:0x2402ffff,
        }.items():
            self.assertEqual(self.word(offset), value, hex(offset))
        # The target test's delay slot stores even the -1 sentinel before marking acted.
        word = self.word(0x314)
        self.assertEqual(word >> 26, 7)
        self.assertEqual(0x314+4+4*(word&65535), 0x32c)
        self.assertEqual(self.packet['decision'], dict(front_target_policy='front_only',
            front_draw_kind='modulo_100', front_threshold=51,
            failed_front_scan='consume_turn', rear_row='delegated_enemy_wave'))
        self.assertEqual([n % 100 >= 51 for n in (50, 51, 99, 100, 32767)], [False, True, True, False, True])

    def test_wave_guards_dispatch_result_and_owner_restoration(self):
        for offset, value in {
            0x3a4:0x96050042, 0x3bc:0x96030042, 0x3c0:0x34040001,
            0x3d4:0x34020063, 0x3dc:0x3402001e, 0x420:0x90820046,
            0x444:0x90620005, 0x454:0x90820045, 0x46c:0xae300008,
            0x480:0x8c420030, 0x488:0x0040f809, 0x48c:0x02202021,
            0x4c8:0x24420358, 0x4d0:0xae22000c, 0x4dc:0x8c420044,
            0x4e4:0x0040f809, 0x4e8:0x02002021, 0x4ec:0x00101080,
            0x504:0xa0560046, 0x524:0xa4400040, 0x540:0xae350008,
            0x544:0xae240030, 0x548:0xae221264,
        }.items():
            self.assertEqual(self.word(offset), value, hex(offset))
        for offset, destination in ((0x494, 0x4c4), (0x4a4, 0x4d4), (0x4b4, 0x4f0)):
            word = self.word(offset)
            self.assertEqual(word >> 26, 4)
            self.assertEqual(offset+4+4*(word&65535), destination)
        # Successful dispatch exits the loop rather than immediately starting every ally.
        self.assertEqual((self.word(0x520)&0x3ffffff)<<2, 0x8053c)
        self.assertEqual(self.packet['wave']['maximum_started_per_update'], 1)
        self.assertEqual(self.packet['wave']['ordinary_resolver_result'], 'ignored')
        self.assertTrue(self.packet['wave']['restore_owner'])

    def test_owner_mailboxes_and_balloon_recipient_are_not_commander_signals(self):
        rows = {row['id'].split('/')[-1]: row['operations'] for row in self.packet['provenance']['programs']}
        self.assertEqual(rows['wave_owner'], [dict(op=op, args=args) for op, args in (
            (30, [0]), (21, []), (4, [12]), (5, []), (4, [13]), (5, []),
            (30, [1]), (3, [120]), (4, [14]), (5, []), (30, [99]), (0, []))])
        self.assertEqual([r['args'] for r in rows['hurt'] if r['op']==40], [[1, 30]])
        self.assertFalse(any(r['op'] in (9, 26) for r in rows['wave_owner']))
        self.assertEqual(self.packet['wave']['selection_delay'], 30)
        self.assertEqual(self.packet['wave']['active_delay'], 120)

    def test_main_dispatch_import_and_completion_consumer(self):
        base = struct.unpack_from('<I', self.main, 24)[0]
        word = lambda address: struct.unpack_from('<I', self.main, 2048+address-base)[0]
        for address, value in {
            0x8016b6c4:0x800f4e64, 0x800f4034:0x8c830030,
            0x8016b688:0x80147d78, 0x80147d78:0x240a00a0,
            0x80147d7c:0x01400008, 0x80147d80:0x2409003f,
            0x800f425c:0xa2220046, 0x800f4268:0xa6600040,
            0x800f426c:0x8c42000c, 0x800f4280:0x244245c8,
            0x800f45e0:0x8c82000c, 0x800f45e8:0x0040f809,
            0x800f4600:0x24423e98,
        }.items():
            self.assertEqual(word(address), value, hex(address))
        for span in self.packet['provenance']['consumers']:
            self.assertEqual(hashlib.sha256(self.main[span['source_offset']:span['source_offset']+span['byte_length']]).hexdigest(), span['sha256'])

    def test_deterministic_and_changed_controller_record_or_import_refuses(self):
        self.assertEqual(exporter.build(), copy.deepcopy(self.packet))
        self.assertEqual(self.packet, json.loads((ROOT/'game/tests/fixtures/enemy_holly_fairy_source.json').read_text()))
        self.assertEqual(self.packet['timing'], dict(initial_motion_updates=0, active_mailbox_write=30, first_delegate_update=31,
            complete_mailbox_write=152, completion_update=153, owner_program_duration=153))
        real = exporter.source
        main_base = struct.unpack_from('<I', self.main, 24)[0]
        for name, offset in (('/D_DATA.BIN', 0x2d0), ('/D_DATA.BIN', 0x504),
                             ('/D_DATA.BIN', 0x207e0+38),
                             ('/D_DATA.BIN', 0x20848),
                             ('MAIN.EXE', 2048+0x800e0cb4-main_base),
                             ('MAIN.EXE', 2048+0x800f45e8-main_base),
                             ('MAIN.EXE', 2048+0x8016b6c4-main_base)):
            original = self.raw if name.startswith('/') else self.main
            changed = bytearray(original)
            changed[offset] ^= 1
            with patch.object(exporter, 'source', side_effect=lambda filename: (bytes(changed), self.origin) if filename==name else real(filename)):
                with self.assertRaises(ValueError):
                    exporter.build()

    def test_complete_library_merge_is_immutable_idempotent_and_rejects_conflicts(self):
        actors = json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        actors['schema'] = 'suikoden-unite-actors/37'
        actors.pop('enemy_wave', None)
        actors['programs']['programs'] = [p for p in actors['programs']['programs'] if not p['id'].startswith('melee/holly_fairy/')]
        actors['animations']['resources'] = [r for r in actors['animations']['resources'] if r['id']!='holly_fairy']
        for rows in (actors['counter']['enemies'], actors['counter']['melee']['enemies'], actors['counter']['parries']['defenders']):
            rows[:] = [r for r in rows if r['id']!='holly_fairy']
        before = copy.deepcopy(actors)
        result = exporter.combine(actors, self.packet)
        self.assertEqual(actors, before)
        self.assertEqual(result['schema'], 'suikoden-unite-actors/38')
        self.assertEqual(result['enemy_wave'], dict(id='holly_fairy', owner_program='melee/holly_fairy/wave_owner'))
        self.assertEqual(exporter.combine(result, self.packet), result)
        self.assertEqual(result['unites'], before['unites'])
        self.assertEqual(result['commander'], before['commander'])
        self.assertEqual(result['group_orders'], before['group_orders'])
        self.assertEqual(result['enemy_magic'], before['enemy_magic'])
        import export_enemy_orders
        import export_enemy_rabbit
        import export_enemy_ninja
        import export_enemy_dagon
        import export_enemy_whip_wolf
        for component in (export_enemy_orders, export_enemy_rabbit, export_enemy_ninja, export_enemy_dagon, export_enemy_whip_wolf):
            retained = component.combine(result)
            self.assertEqual(retained['schema'], result['schema'])
            self.assertEqual(retained['enemy_wave'], result['enemy_wave'])
            self.assertEqual(retained['unites'], result['unites'])
        self.assertEqual(next(r for r in result['counter']['enemies'] if r['id']=='holly_fairy')['counterable'], True)
        for field in ('enemies',):
            self.assertEqual([r for r in result['counter'][field] if r['id']!='holly_fairy'], before['counter'][field])
        invalid = copy.deepcopy(result)
        invalid['enemy_wave']['owner_program'] = 'wrong'
        with self.assertRaisesRegex(ValueError, 'Conflicting Holly Fairy'):
            exporter.combine(invalid, self.packet)
        invalid = copy.deepcopy(result)
        next(r for r in invalid['counter']['melee']['enemies'] if r['id']=='holly_fairy')['attack_program'] = 'wrong'
        with self.assertRaisesRegex(ValueError, 'Conflicting Holly Fairy'):
            exporter.combine(invalid, self.packet)
        actors['schema'] = 'suikoden-unite-actors/36'
        with self.assertRaises(ValueError):
            exporter.combine(actors, self.packet)

    def test_normal_admission_retains_raw_profile_formations_and_independent_pixels(self):
        from PIL import Image
        from export_first_room import Atlas
        from test_export_unite_review import vram_pose
        from battle_placement import area_encounters
        import item_tables
        import preparation
        battle = json.loads((ROOT/'game/tests/fixtures/journey_unites_battle.json').read_text())
        actors = json.loads((ROOT/'game/tests/fixtures/journey_unites_actor_library.json').read_text())
        battle['enemies'] = [r for r in battle['enemies'] if r['id']!='holly_fairy']
        battle['encounters'] = [r for r in battle['encounters'] if 'holly_fairy' not in r['enemies']]
        battle['unite_graphics'] = [r for r in battle['unite_graphics'] if r['id']!='holly_fairy']
        atlas = Atlas(); atlas.image = Image.new('RGBA', (4096,4096)); atlas.y = 4
        atlas.image.paste((17,31,49,255), (0,0,4096,3))
        proof = exporter.append_content(battle, actors, atlas)
        self.assertEqual((battle['schema'], actors['schema']), ('suikoden-battle-trial/43','suikoden-unite-actors/40'))
        self.assertEqual(atlas.image.getpixel((4095,2)), (17,31,49,255))
        self.assertEqual([r['id'] for r in proof['catalogue']['formations']], ['area_d_1','area_d_2','area_d_3','area_d_10','area_d_11'])
        profile = battle['enemies'][-1]; record = 0x207e0; raw = self.raw
        self.assertEqual((profile['action_policy'],profile['target_policy']), ('source_holly_fairy','front_first'))
        self.assertEqual(profile['level'], raw[record+16])
        self.assertEqual(profile['max_hp'], struct.unpack_from('<H',raw,record+18)[0])
        self.assertEqual(profile['stats'],dict(zip(('attack','skill','defense','speed','magic','luck'),struct.unpack_from('<6H',raw,record+20))))
        self.assertEqual(profile['money'],struct.unpack_from('<h',raw,record+52)[0])
        self.assertEqual(profile['effect_offset'],list(struct.unpack_from('<2h',raw,record+60)))
        self.assertTrue(profile['airborne'])
        self.assertFalse(profile['death_immune'] or profile['dodges_attacks'] or profile['unavoidable_attack'])
        self.assertEqual(profile['knockout_ticks'],94)
        for i,element in enumerate(('fire','water','earth','lightning','wind')):
            self.assertEqual(profile['affinities'][element],('neutral','weak','resistant','immune')[raw[record+32+i]])
        items={row['id']:row for row in item_tables.items()}
        for drop,item,rate in zip(profile['drops'],raw[record+54:record+60:2],raw[record+55:record+60:2],strict=True):
            self.assertEqual(drop['item'],preparation.stable_id(items[item]['name']) if item else None)
            self.assertEqual(drop['rate'],rate)
        graphic=next(r for r in battle['unite_graphics'] if r['id']=='holly_fairy')
        self.assertEqual(len(graphic['poses']),8)
        for pose in graphic['poses']:
            for key,white in (('sprite',False),('white',True)):
                if key not in pose:continue
                expected,ax,ay=vram_pose(raw,0x20b28,pose['id'],packet=True,white=white,base=exporter.BASE)
                sprite=pose[key];r=sprite['rect']
                actual=atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
                self.assertEqual((actual.size,sprite['anchor_x'],sprite['anchor_y']),(expected.size,ax,ay))
                self.assertEqual(actual.tobytes(),expected.tobytes())
        ids={1:'holly_fairy',2:'mad_ivy',3:'creeper'};expected_ids=set()
        for row in area_encounters(raw)['encounters']:
            if set(row['roster'])-{0}-set(ids):continue
            identifier=f'area_d_{row["index"]}';expected_ids.add(identifier)
            entry=next(r for r in battle['encounters'] if r['id']==identifier)
            self.assertEqual(entry['enemies'],[ids[n] for n in row['roster'] if n])
            self.assertEqual(entry['source_slots'],[slot['slot'] for slot in row['slots']])
            self.assertEqual(entry['enemy_rows'],['front' if slot['slot']<3 else 'back' for slot in row['slots']])
        self.assertEqual(expected_ids,{r['id'] for r in battle['encounters'] if r['id'].startswith('area_d_')})
        with self.assertRaisesRegex(ValueError,'profile already present'):
            exporter.append_content(battle,actors,atlas)

    def test_nameless_urn_drop_is_a_named_zero_flag_item_not_an_appraisal_record(self):
        from war_text import decode
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        pointer=struct.unpack_from('<I',main,2048+0x80167658+154*4-base)[0]
        record=2048+pointer-base
        self.assertEqual(decode(main,record,length=24)[0],'Nameless urn')
        self.assertEqual(struct.unpack_from('<IHBBI',main,record+24),(0,0,0,0,0))
        self.assertEqual(list(self.raw[0x207e0+54:0x207e0+56]),[154,13])

    def test_idle_reset_dispatch_wait_and_motion_consumers_have_independent_operands(self):
        main=self.main;base=struct.unpack_from('<I',main,24)[0]
        word=lambda address:struct.unpack_from('<I',main,2048+address-base)[0]
        for address,expected in {
            0x800de734:0xa4c00006, 0x800de740:0xa4c00010,
            0x800de770:0x1440ffef, 0x800de774:0x24c6008c,
            0x800df0b0:0xae020008, 0x800e0c64:0x0c038d63,
            0x800e0c6c:0x92620045, 0x800e0c7c:0x86620012,
            0x800e0cac:0x96020006, 0x800e0cb4:0x14400006,
            0x800e0cbc:0x8e020008, 0x800e0cc4:0x8c460000,
            0x800e0cc8:0x0c038e08, 0x800e0ccc:0x02402821,
            0x800e35dc:0x12000079, 0x800e3668:0xa4500006,
            0x800e3684:0x87020010, 0x800e3778:0xa7020010,
            0x800e3794:0x8f040014, 0x800e37b0:0xaf060070,
            0x800e386c:0xa0450004, 0x800e3870:0xac46000c,
            0x800e38c8:0xa4510006, 0x800e38f0:0x03e00008,
            0x800e38f4:0x00001021, 0x800e45e4:0x84820010,
            0x800e45ec:0x1c400005, 0x800e4a28:0x8c620070,
            0x800e4b4c:0x00042300,
            0x800e4ab0:0xa4e90010, 0x800e4b58:0x0049001a,
            0x800e4b80:0x00001012, 0x800e4b90:0xace20034,
            0x800e4c38:0x2463000c,
        }.items():self.assertEqual(word(address),expected,hex(address))
        # The complete dispatcher writes owner/PC/opcode, preserving the motion countdown and vectors.
        dispatch=[word(pc) for pc in range(0x800e3820,0x800e38f0,4)]
        stores=[w for w in dispatch if w>>26 in (40,41,43) and (w>>21)&31!=29]
        self.assertEqual([(w>>26,w&65535) for w in stores],[(40,4),(43,12),(41,6)])
        for span in self.packet['provenance']['idle_consumers']:
            self.assertEqual(hashlib.sha256(main[span['source_offset']:span['source_offset']+span['byte_length']]).hexdigest(),span['sha256'])
        idle=self.packet['idle']
        self.assertEqual((idle['first_dispatch_update'],idle['first_motion_update'],idle['downward_snap_update'],
                          idle['return_motion_update'],idle['return_snap_update'],idle['restart_update'],idle['period']),
                         (1,2,31,32,61,62,61))
        self.assertTrue(idle['preserves_pending_motion'])
        self.assertEqual(idle['wave_delay_per_pending_motion_update'],1)
        self.assertEqual(idle['attack_prepare_updates'],13)


if __name__ == '__main__':
    unittest.main()
