#!/usr/bin/env python3
import json
from pathlib import Path
import sys
import tempfile
import struct
import hashlib
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import export_unite_programs as exporter
import maindec
import disc

class ProgramExportTests(unittest.TestCase):
    def test_martial_exports_borrowed_strikes_and_source_finishing_clock(self):
        import unite_martial_controller
        with tempfile.TemporaryDirectory() as temporary:
            _, proof = exporter.export(temporary, include_flash=True, include_master=True,
                                       include_couple=True, include_warriors=True, include_martial=True)
            bundle = json.loads((Path(temporary)/'unites.json').read_text())
        self.assertEqual(bundle, json.loads((ROOT/'game/tests/fixtures/martial_actor_library.json').read_text()))
        self.assertEqual(bundle['schema'], 'suikoden-unite-actors/27')
        baseline = json.loads((ROOT/'game/tests/fixtures/warriors_actor_library.json').read_text())
        self.assertEqual(bundle['unites'][:29] + bundle['unites'][30:], baseline['unites'][:29] + baseline['unites'][30:])
        binding = bundle['unites'][29]
        self.assertEqual(binding['target_queue'], dict(recipient_return=80, damage=140, cleanup=200))
        self.assertEqual((binding['dispatch_after'], binding['return_program'], binding['damage_reaction']), (1,'common/unite_return',False))
        martial = unite_martial_controller.actor_programs()
        native = {p['id']:p for p in bundle['programs']['programs']}
        expected = {p['id']:p for p in martial['programs']['programs']}
        for member, source in zip(binding['members'], martial['bindings'], strict=True):
            self.assertEqual(member['entry_program'], source['setup'])
            self.assertEqual(member['loop_program'], source['strike'])
            for name in member['programs']:
                self.assertEqual(native[name], expected[name])
            strike = next(row for row in proof['programs'] if row['id'] == source['strike'])
            self.assertEqual(strike['sha256'], martial['borrowed_strike']['sha256'])
            self.assertEqual(strike['source']['file'], 'DATA/04_PLAY/EIK.BIN')
        self.assertEqual(proof['martial_controller'], unite_martial_controller.build())

    def test_warriors_exports_controller_and_source_sine_samples(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, proof = exporter.export(Path(temporary), include_flash=True, include_master=True,
                                       include_couple=True, include_warriors=True)
            bundle = json.loads((Path(temporary) / 'unites.json').read_text())
        self.assertEqual(bundle, json.loads((ROOT/'game/tests/fixtures/warriors_actor_library.json').read_text()))
        self.assertEqual(bundle['schema'], 'suikoden-unite-actors/26')
        binding = bundle['unites'][15]
        spec = binding['controller']
        self.assertEqual((binding['dispatch_after'], binding['return_program'], binding['damage_reaction']),
                         (1, 'common/unite_return', False))
        self.assertEqual((spec['recipient_at'], spec['damage_at'], spec['cleanup_at']), (81, 128, 129))
        self.assertEqual(spec['orbit']['sounds'], [dict(at=1,id=0x81f), dict(at=65,id=0x524), dict(at=81,id=0x521)])
        table = 0x801765bc - maindec.MBASE
        expected = [40 * struct.unpack_from('<h', maindec.body(), table + 2*min(age*64,2048-age*64))[0]
                    for age in range(32)]
        self.assertEqual(spec['orbit']['heights_q12'], expected)
        self.assertEqual([row['record'] for row in proof['pending_linked_controllers']], [])

    def test_linked_controller_research_is_exported_without_admitting_scenes(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, proof = exporter.export(Path(temporary), include_flash=True, include_master=True)
            bundle = json.loads((Path(temporary) / 'unites.json').read_text())
        pending = proof['pending_linked_controllers']
        self.assertEqual([row['record'] for row in pending], [15, 16])
        self.assertTrue(all(row['admission'] == 'source_research_only' for row in pending))
        self.assertTrue(all('dispatch_after' not in bundle['unites'][index] for index in (15, 16)))
        self.assertEqual(pending[0]['impact_art']['animations'][0], pending[1]['impact_art']['animations'][0])
        with tempfile.TemporaryDirectory() as temporary:
            _, proof = exporter.export(Path(temporary), include_flash=True, include_master=True, include_couple=True)
            bundle = json.loads((Path(temporary) / 'unites.json').read_text())
        self.assertEqual([row['record'] for row in proof['pending_linked_controllers']], [15])
        self.assertEqual(bundle['schema'], 'suikoden-unite-actors/24')
        couple = bundle['unites'][16]
        self.assertEqual((couple['dispatch_after'], couple['damage_member'], couple['impact_effect']), (1, 1, 6))
        self.assertEqual(couple['transition'], dict(trigger_member=0, signal=16, dispatches=[dict(member=1, program='lepant/unite_10')]))

    def test_master_pupil_exports_independent_setup_and_loop_programs(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, proof = exporter.export(Path(temporary), include_master=True)
            bundle = json.loads((Path(temporary) / 'unites.json').read_text())
        self.assertEqual(bundle['schema'], 'suikoden-unite-actors/23')
        binding = bundle['unites'][31]
        self.assertEqual(binding['dispatch_after'], 1)
        self.assertEqual(binding['return_program'], 'common/unite_return')
        self.assertEqual([(m['id'], m['entry_program'], m['loop_program']) for m in binding['members']],
                         [('hero', 'hero/unite_10', 'hero/unite_11'), ('kai', 'kai/unite_10', 'kai/unite_11')])
        self.assertEqual(proof['master_pupil_controller']['finish_delay'], 40)
        with tempfile.TemporaryDirectory() as temporary:
            exporter.export(Path(temporary), include_master=True, include_flash=True)
            combined = json.loads((Path(temporary) / 'unites.json').read_text())
        self.assertEqual(combined['schema'], 'suikoden-unite-actors/23')
        self.assertEqual(combined['unites'][10]['controller']['vfx'], 'flash')
        self.assertEqual(combined['unites'][31], binding)

    def test_lepant_family_binds_three_recipient_programs_and_target_signal(self):
        import battle_unite_camera
        with tempfile.TemporaryDirectory() as temporary:
            _,proof=exporter.export(Path(temporary))
            binding=proof['unites'][30]
            self.assertEqual(binding['dispatch_after'],1)
            self.assertEqual(binding['return_program'],'common/unite_return')
            self.assertFalse(binding['damage_reaction'])
            self.assertEqual(binding['damage_target_signal'],16)
            self.assertEqual([(m['id'],m['reaction_variant']) for m in binding['members']],[('lepant',1),('eileen',2),('sheena',3)])
            self.assertTrue(all(m['reaction_on_hit'] for m in binding['members']))
            self.assertEqual([row['record'] for row in proof['family_controllers']],[30])
        row=battle_unite_camera.report()[30]
        catalogue=__import__('json').loads(battle_unite_camera.CATALOGUE.read_text())['records'][30]
        damaged=bytearray(maindec.body());damaged[0x800FE43C-maindec.MBASE]^=1
        with self.assertRaisesRegex(ValueError,'initializer changed'):
            battle_unite_camera.family_schedule(catalogue,row['member_scripts'],battle_unite_camera.Image(bytes(damaged),maindec.MBASE))
        damaged=bytearray(maindec.body());damaged[0x800FE5F4-maindec.MBASE]^=1
        with self.assertRaisesRegex(ValueError,'callback changed'):
            battle_unite_camera.direct_assists(catalogue,row['member_scripts'],battle_unite_camera.Image(bytes(damaged),maindec.MBASE))

    def test_bandit_phase_joins_and_common_hp_protection_match_independent_source_reads(self):
        import character_table
        from export_first_room import source
        from test_physical_rune_export import independent_stream
        from test_physical_controller import clock
        record=next(r for r in character_table.records() if r['name']=='Varkas')
        raw,_=source('/'+record['sprite_file']);table=struct.unpack_from('<I',raw,32)[0]
        operations=independent_stream(raw,struct.unpack_from('<I',raw,table+9*4)[0],table)
        times=clock(raw,operations)
        self.assertEqual([times['signals'][(0,bit)] for bit in (16,2,4)],[37,49,136])
        self.assertEqual(times['complete'],182)
        for pc,word in {0x800FCE64:0x30420010,0x800FCE98:0x8C460028,
                        0x800FCF10:0x0C03D844,0x800FCF14:0x3405001E,
                        0x800FCFB8:0x8C46003C,0x800FD014:0x30420002,
                        0x800FD020:0x34050002,0x800FD024:0x34060019,
                        0x800FD028:0x0C03E57A,0x800F95A0:0x0C038595,
                        0x800F96B0:0x0C038595,0x800E16E8:0x30428000,
                        0x800E16F4:0x00008021}.items():self.assertEqual(maindec.mword(pc),word,hex(pc))

    def test_pretty_girl_imports_tengaar_phase_and_child_instead_of_unused_camille_script(self):
        with tempfile.TemporaryDirectory() as directory:
            packet,proof=exporter.export(Path(directory))
            phase=next(row for row in proof['phase_controllers'] if row['record']==8)
            binding=proof['unites'][8]
            self.assertEqual([m['entry_program'] for m in binding['members']],['camille/unite_9','tengaar/unite_11','kasumi/unite_10'])
            self.assertEqual(binding['transition'],dict(trigger_member=2,signal=16,dispatches=[dict(member=1,program='tengaar/unite_12')]))
            self.assertEqual(binding['damage_member'],1)
            self.assertTrue(binding['embedded_returns'])
            ids={p['id'] for p in packet['programs']}
            self.assertNotIn('camille/unite_12',ids)
            self.assertIn('tengaar/auxiliary/member_9',ids)
            self.assertEqual(phase['assist']['recipient_binding']['flip'],dict(start=61,stop=117,angles=[0,2048,2048],screen_offset='recipient_current_attachment_y_minus_anchor_y',offset_arithmetic='signed_byte_wrap',reset_offsets=[0,0]))

    def test_wild_arrow_fan_controls_share_the_source_startup_and_group_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            _,proof=exporter.export(Path(temporary))
            self.assertEqual([r['record'] for r in proof['group_controllers']],[2,19,20])
            for record in (2,19,20):
                binding=proof['unites'][record]
                self.assertEqual(binding['damage_member'],1)
                self.assertTrue(binding['members'][0]['reaction_on_hit'])
                self.assertTrue(binding['members'][0]['reaction_group'])
                self.assertFalse(binding['members'][1].get('reaction_on_hit',False))
                self.assertEqual(binding['dispatch_after'],1)
                for member in binding['members']:
                    self.assertEqual(member['fan'],dict(animation=17,rolls=[340,170,0,-170,-340],node_angles=[0,0,400],velocity_q12=-49152,anchor_z=-40,signal=16))
            resources=json.loads((Path(temporary)/'animations.json').read_text())['resources']
            for identifier in ('kirkis','sylvina','rubi','stallion'):
                resource=next(r for r in resources if r['id']==identifier)
                clip=next(c for c in resource['clips'] if c['id']==17)
                self.assertEqual([f['pose'] for f in clip['frames']],[10])

    def test_bumpy_phase_controls_bind_independent_damage_mask(self):
        with tempfile.TemporaryDirectory() as temporary:
            _,proof=exporter.export(Path(temporary))
            phase=next(row for row in proof['phase_controllers'] if row['record']==6)
            row=proof['unites'][6]
            self.assertEqual(row['dispatch_after'],1)
            self.assertEqual((row['damage_member'],row['damage_signal']),(0,16))
            self.assertEqual(row['members'][0]['entry_program'],'krin/unite_10')
            self.assertEqual(row['members'][1]['start_after'],80)
            self.assertTrue(row['members'][0]['reaction_on_hit'])
            self.assertNotIn('reaction_variant',row['members'][0])
            self.assertEqual(row['transition'],dict(trigger_member=1,signal=2,dispatches=[dict(member=0,program='krin/unite_11')]))
            self.assertEqual(phase['admission'],'native_vm_scene_bound_visual_acceptance_pending')

    def test_beauty_controller_inventory_retains_both_variants_with_semantic_schedule(self):
        with tempfile.TemporaryDirectory() as temporary:
            _,proof=exporter.export(Path(temporary))
            controllers=proof['scene_controllers']
            self.assertEqual([r['record'] for r in controllers],[9,25])
            self.assertEqual(controllers[0]['contract'],controllers[1]['contract'])
            for record in (9,25):
                binding=proof['unites'][record]
                self.assertEqual(binding['dispatch_after'],1)
                spec=binding['controller']
                self.assertEqual((spec['trigger_member'],spec['signal'],spec['recipient_at'],spec['damage_at'],spec['cleanup_at']),(0,16,65,224,225))
                self.assertEqual(len(spec['recipient_rolls']),128)
            self.assertEqual(controllers[0]['contract']['damage'],dict(count=3,multiplier=4,divisor=10,targets='ascending enemy slots; shared helper skips inactive target status',reaction='none in shared helper'))
            self.assertEqual(controllers[0]['admission'],'native_vm_scene_bound_visual_acceptance_pending')

    def test_fatal_exports_signal_started_partner_and_normal_dispatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            _,proof=exporter.export(Path(temporary))
            phase=next(row for row in proof['phase_controllers'] if row['record']==13)
            row=proof['unites'][13]
            self.assertEqual(row['dispatch_after'],1)
            self.assertTrue(row['members'][0]['deferred_entry'])
            self.assertNotIn('deferred_entry',row['members'][1])
            self.assertEqual([m['id'] for m in row['members']],['gen','kamandol'])
            self.assertEqual(row['transition'],dict(trigger_member=1,signal=16,dispatches=[dict(member=0,program='gen/unite_9')]))
            self.assertEqual(row['damage_member'],1)
            self.assertEqual(phase['admission'],'native_vm_scene_bound_visual_acceptance_pending')

    def test_auxiliary_writer_rotation_and_corner_extents_have_source_consumers(self):
        proof=exporter.actor_graphics()
        for address,word in {0x800E7078:0x30630004,0x800E7090:0x96420004,
            0x800E70BC:0x34030168,0x800E70DC:0x0C053F2D,0x800E70EC:0x34020400,
            0x800E710C:0x0C053CFB,0x800E71DC:0x92020004,0x800E71E8:0x00431021,
            0x800E7314:0x92020005,0x800E7328:0x00431021,0x800E7398:0x0C053D71}.items():
            self.assertEqual(maindec.mword(address),word,hex(address))
        changed=bytearray(maindec.body());changed[proof['address']-maindec.MBASE+100]^=1
        with patch.object(maindec,'body',return_value=bytes(changed)):
            with self.assertRaises(ValueError):exporter.actor_graphics()

    def test_shared_pool_limit_allocation_and_auxiliary_sweep_match_source(self):
        proof=exporter.actor_pool()
        self.assertEqual(proof['usable_actor_slots'],19)
        # Decode allocator initialization and loop condition independently: 19..1, excluding0.
        words={pc:word for pc,word,_ in maindec.dis(0x800E5E60,31)}
        self.assertEqual(words[0x800E5E68] & 65535,19)
        self.assertEqual(words[0x800E5EC4],0x2484FFFF)
        self.assertEqual(words[0x800E5EC8] >> 26,7)  # bgtz after decrement
        self.assertEqual(0x800E5ECC + struct.unpack('<h',struct.pack('<H',words[0x800E5EC8]&65535))[0]*4,0x800E5E74)
        for address,word in {0x800E0D68:0x8C420024,0x800E0D70:0x24520001,
            0x800E0D74:0x2A420014,0x800E0DC8:0x0C038AA7,0x800E0DD0:0x0C038D63,
            0x800E0DD8:0x0C038209,0x800E0E54:0x26520001,0x800E0E58:0x2A420014}.items():
            self.assertEqual(maindec.mword(address),word,hex(address))
        for block in proof['blocks']:
            changed=bytearray(maindec.body())
            changed[block['address']-maindec.MBASE+12]^=1
            with patch.object(maindec,'body',return_value=bytes(changed)):
                with self.assertRaises(ValueError):exporter.actor_pool()

    def test_ninja_phase_metadata_binds_qualified_recipient_and_embedded_returns(self):
        with tempfile.TemporaryDirectory() as temporary:
            packet,proof=exporter.export(Path(temporary))
            phase=next(row for row in proof['phase_controllers'] if row['record']==28)
            self.assertEqual(phase['record'],28)
            self.assertEqual(phase['assist']['animation_context'],'recipient')
            self.assertEqual(phase['assist']['local_timing']['duration'],134)
            self.assertEqual(phase['assist']['recipient_binding']['flip']['start'],61)
            self.assertEqual(phase['assist']['recipient_binding']['impact'],dict(at=102,animation=0,child=13,offset=[5,5,0],centered=False))
            self.assertEqual(phase['admission'],'native_vm_scene_bound_visual_acceptance_pending')
            row=proof['unites'][28]
            self.assertEqual(row['dispatch_after'],1)
            self.assertTrue(row['members'][0]['reaction_on_hit'])
            self.assertEqual(row['members'][0]['reaction_variant'],1)
            self.assertIsNone(row['return_program'])
            self.assertTrue(row['embedded_returns'])
            self.assertEqual([m['entry_program'] for m in row['members']],['kasumi/unite_13','fuma/unite_10','kage/unite_10'])
            self.assertEqual(row['transition'],dict(trigger_member=0,signal=16,dispatches=[dict(member=1,program='fuma/unite_11'),dict(member=2,program='kage/unite_11')]))

    def test_source_timer_enters_blocked_and_polls_before_actor_motion(self):
        for address, expected in {0x800E394C:0xA4430012,0x800E3994:0x00001021,
                                  0x800E3964:0x94820012,0x800E396C:0x2442FFFF,
                                  0x800E3970:0xA4820012,0x800E3978:0x1C400007,
                                  0x800E0A74:0x0C038AA7,0x800E0A7C:0x0C038D63,
                                  0x800E3748:0xAF050068,0x800E37F4:0x0040F809,
                                  0x800E3EE8:0x14620007,0x800E3EE0:0x90A60004,
                                  0x800E3F18:0x90A30005,0x800E3F28:0xA0A30005,
                                  0x800E3F80:0x14620007,0x800E3FC0:0xA0A20005,
                                  0x800E52A0:0xA4430042,0x800E52CC:0x00001021,
                                  0x800E52BC:0x2402FFFF,0x800E52C8:0xAC64000C,
                                  0x800E4CDC:0x32820001,0x800E4D48:0x32820002,
                                  0x800E4D6C:0x32820004,0x800E4E08:0x32820008,
                                  0x800E4DD4:0xACE20068,0x800E4E00:0xACE20070,
                                  0x800E4E40:0xACE3005C,0x800E4E5C:0x0C038E08,
                                  0x800E5E74:0x90620003,0x800E5EC4:0x2484FFFF,
                                  0x800E4A28:0x8C620070,0x800E4A88:0x8C620064,
                                  0x800E4AC8:0x0049001A,0x800E4B84:0xACE00020,
                                  0x800E4BCC:0xA4E20010,0x800E39EC:0xA0400002,
                                  0x800E3A0C:0xA2000003,0x800E3A34:0x00001021,
                                  0x800E4D00:0x8C84A000,0x800E4D08:0x26B5C208,
                                  0x800E3AF4:0xA0440001,0x800E0B6C:0x92020001,
                                  0x800E0B84:0x34420004,0x800E2994:0x30420004,
                                  0x800E3BA0:0xA0A00002,0x800E3BA8:0xA0A20002,
                                  0x800E0B5C:0x92020002,0x800E0B64:0x10400016,
                                  0x8016BBA4:0x800F3AA0,0x800E5534:0xA4C20044,
                                  0x800F3ADC:0x96120046,0x800F3AE0:0x96130048,
                                  0x800F3B34:0xAE320004,0x800F3B38:0xAE330000,
                                  0x800F3B70:0x2442FFFF,0x800F3B84:0x26430003,
                                  0x800F3B9C:0xAE320004,0x800F3BD0:0x34040120,
                                  0x800F3BD8:0x24A501F0,0x800F3C24:0xACC20008,
                                  0x800F3C38:0xAE000054,
                                  0x800E6BC8:0x9043004C,0x800E6BCC:0x34020019,
                                  0x800E6BD0:0x10620049,0x800E6BD8:0x0C051F8E,
                                  0x800E6C58:0x0052102A,0x800E6C5C:0x10400025,
                                  0x800E6CD8:0x8C6230A0,0x800E6CE0:0x14400005,
                                  0x800E6CEC:0x0C038137,0x800E05C8:0x34030001,
                                  0x800E05CC:0xA043004D}.items():
            self.assertEqual(maindec.mword(address),expected,hex(address))
    def test_projectile_effects_have_bounded_source_consumers_and_named_bindings(self):
        for address, expected in {0x8016BB74:0x800F0B24,0x8016BB78:0x800F0DAC,
            0x800F0BB0:0x90430004,0x800F0BD8:0x8C450024,0x800F0BF4:0x00621825,
            0x800F0C48:0x30420002,0x800F0C88:0x30420010,0x800F0C9C:0xA4C20010,
            0x800F0CB8:0xACC20014,0x800F0D1C:0xACC00054,0x800F0D48:0x00021303,
            0x800F0ED4:0x30420002,0x800F0F14:0x30420010,0x800F0F28:0xA4C20010,
            0x800F0FA8:0xACC00054,0x800F0FFC:0x9483001C,0x800F1004:0x24630200}.items():
            self.assertEqual(maindec.mword(address),expected,hex(address))
        rows=exporter.projectile_callbacks()
        self.assertEqual([r['size'] for r in rows],[648,620])
        for row in rows:
            data=maindec.body()[row['address']-maindec.MBASE:row['address']-maindec.MBASE+row['size']]
            words=struct.unpack('<'+'I'*(len(data)//4),data)
            self.assertFalse(any(w >> 26 == 3 or w >> 26 == 0 and w & 63 == 9 for w in words))
        for row in rows:
            changed=bytearray(maindec.body())
            changed[row['address']-maindec.MBASE+100] ^= 1
            with patch.object(maindec,'body',return_value=bytes(changed)):
                with self.assertRaises(ValueError):exporter.projectile_callbacks()
        for slot,identifier in [(1,'aimed_projectile'),(2,'spinning_projectile')]:
            code,blocked,effects=exporter.compile_operations([dict(op=35,args=[0,slot]),dict(op=0,args=[])])
            self.assertFalse(blocked)
            self.assertEqual(code[0],dict(command=dict(effect=dict(id=identifier,binding='shared'))))
            self.assertEqual(effects,[identifier])

    def test_camera_focus_preserves_raw_q12_xy_and_ignores_relative_z(self):
        for mode,anchor in enumerate(('absolute','self','owner')):
            code,blocked,_=exporter.compile_operations([dict(op=20,args=[mode,20,1,-3,7]),dict(op=0,args=[])])
            self.assertFalse(blocked)
            self.assertEqual(code[0],dict(command=dict(camera=dict(channel='focus',anchor=anchor,updates=20,value_q12=[1,-3,7 if mode==0 else 0]))))
        for opcode,channel in [(17,'angles'),(18,'translation'),(19,'scale')]:
            code,blocked,_=exporter.compile_operations([dict(op=opcode,args=[20,1,-3,7]),dict(op=0,args=[])])
            self.assertFalse(blocked)
            self.assertEqual(code[0],dict(command=dict(camera=dict(channel=channel,updates=20,value_q12=[4096,-12288,28672]))))

    def test_dynamic_waits_have_no_invented_absolute_clocks(self):
        rows = [dict(op=4,args=[5]),dict(op=5,args=[]),dict(op=31,args=[1]),
                dict(op=26,args=[1,2]),dict(op=0,args=[])]
        code, blocked, _ = exporter.compile_operations(rows)
        self.assertFalse(blocked)
        self.assertEqual(code, [dict(command=dict(animation=5)),dict(wait=dict(animation_done={})),
            dict(wait=dict(shared_value=1)),dict(command=dict(signal_set=dict(target='owner',bits=2))),dict(halt={})])
        code, blocked, _ = exporter.compile_operations([dict(op=24,args=[11,17,9,0,0,0]),dict(op=0,args=[])])
        self.assertIsNone(code)
        self.assertEqual(blocked[0]['opcode'],24)
        self.assertIsNone(exporter.compile_operations([dict(op=0,args=[]),dict(op=4,args=[5])])[0])

    def test_highlight_targets_and_byte_masks_are_lowered_without_channels(self):
        code, blocked, _ = exporter.compile_operations([
            dict(op=15,args=[1,0x104]),dict(op=16,args=[0,-1]),
            dict(op=13,args=[0x102]),dict(op=30,args=[7]),dict(op=0,args=[])])
        self.assertFalse(blocked)
        self.assertEqual(code[:4], [
            dict(command=dict(highlight=dict(target='owner',bits=4,set=True))),
            dict(command=dict(highlight=dict(target='self',bits=255,set=False))),
            dict(command=dict(record_flags=dict(bits=2,set=True))),
            dict(command=dict(shared_value=7))])

    def test_children_and_linear_motion_keep_distinct_source_semantics(self):
        code, blocked, _ = exporter.compile_operations([
            dict(op=24,args=[15,17,9,-20,0,-20]),dict(op=33,args=[2,3,1,2,3]),
            dict(op=33,args=[3,0,0,0,0]),dict(op=0,args=[])], 'kirkis')
        self.assertFalse(blocked)
        self.assertEqual(code[0]['command']['child'],dict(program='kirkis/auxiliary/member_9',resource='kirkis',
            animation=17,owner='owner',home='parent_owner',draw_record=True,offset=[-20,0,-20]))
        self.assertEqual(code[1]['command']['motion']['kind'],'linear')
        self.assertEqual(code[2]['command']['motion']['updates'],1)
        self.assertEqual(code[2]['command']['motion']['kind'],'snap')
        shared=exporter.compile_operations([dict(op=24,args=[0,1,0,0,0,0]),dict(op=0,args=[])],'varkas')[0]
        self.assertEqual(shared[0]['command']['child']['resource'],'shared_impacts')
        self.assertEqual(shared[0]['command']['child']['program'],'varkas/auxiliary/shared_0')

    def test_visibility_uses_boolean_operand_and_translucency_uses_stored_byte(self):
        code, blocked, _ = exporter.compile_operations([
            dict(op=6,args=[256]),dict(op=8,args=[256]),dict(op=6,args=[-1]),
            dict(op=8,args=[0]),dict(op=0,args=[])])
        self.assertFalse(blocked)
        self.assertEqual(code[:4],[dict(command=dict(translucent=False)),dict(command=dict(visible=True)),
            dict(command=dict(translucent=True)),dict(command=dict(visible=False))])

    def test_shared_resource_rejects_rebased_tables_outside_its_source(self):
        raw, origin=exporter.source.field.source('BATTLE.BIN')
        base=exporter.battle_bin.LOAD_BASE
        section=struct.unpack_from('<I',raw,0)[0]-base
        for pointer in (base-1,base+len(raw)):
            changed=bytearray(raw)
            struct.pack_into('<I',changed,section+20,pointer)
            with self.assertRaises(ValueError):
                exporter.source.animation_frames(changed,section=section,base=base)
        changed=bytearray(raw)
        struct.pack_into('<I',changed,section+16,base-1)
        with self.assertRaises(ValueError):
            exporter.animation_resource('shared_impacts',changed,origin,{1},section=section,base=base)

    def test_callback_parameters_lower_only_for_the_palette_cycle_consumer(self):
        callback=maindec.body()[0x800F3AA0-maindec.MBASE:0x800F3C5C-maindec.MBASE]
        self.assertEqual(hashlib.sha256(callback).hexdigest(),'ed2719f0f623331bbf04fec3f5124298bd7c548cb7d40ee63df9fd1e917b4d85')
        calls={(0x80000000|((word&0x3ffffff)<<2)) for (word,) in struct.iter_unpack('<I',callback) if word>>26==3}
        self.assertEqual(calls,{0x800C2D30,0x800C2DC0,0x8014ABD4})
        rows=[dict(op=42,args=[3,0,1,4]),dict(op=30,args=[0]),dict(op=35,args=[0,13]),dict(op=0,args=[])]
        code,blocked,effects=exporter.compile_operations(rows)
        self.assertFalse(blocked)
        self.assertEqual(code[0],dict(command=dict(palette_cycle=dict(variants=[1,2,3],updates=4))))
        self.assertEqual(code[2],dict(command=dict(effect=dict(id='palette_cycle',binding='shared'))))
        self.assertEqual(effects,['palette_cycle'])
        for parameters,callback in (([3,0,1,0],13),([3,0,5,4],13),([3,0,1,4],1)):
            changed=[dict(op=42,args=parameters),dict(op=35,args=[0,callback]),dict(op=0,args=[])]
            self.assertIsNone(exporter.compile_operations(changed)[0])

    def test_non_duration_status_commands_keep_kind_and_raw_threshold(self):
        for operand,kind in ((0,'poison'),(1,'balloon'),(4,'accuracy_reduced'),(5,'sleep'),(6,'rune_blocked')):
            for threshold in (0,20,100):
                code,blocked,_=exporter.compile_operations([dict(op=40,args=[operand,threshold]),dict(op=0,args=[])])
                self.assertFalse(blocked)
                self.assertEqual(code,[dict(command=dict(status=dict(kind=kind,threshold_percent=threshold))),dict(halt={})])
        for args in ([0,-1],[0,101],[2,20],[3,20]):
            self.assertIsNone(exporter.compile_operations([dict(op=40,args=args),dict(op=0,args=[])])[0])

    def test_program_schema_preserves_legacy_features_and_versions_status_kinds(self):
        for legacy in (7,8):
            self.assertEqual(exporter.program_schema([],legacy),f'suikoden-actor-programs/{legacy}')
        for command,version in ((dict(resume_motion=2),9),
                                (dict(status=dict(kind='poison',threshold_percent=20)),10),
                                (dict(status=dict(kind='balloon',threshold_percent=30)),11),
                                (dict(status=dict(kind='sleep',threshold_percent=10)),11)):
            programs=[dict(instructions=[dict(command=command),dict(halt={})])]
            self.assertEqual(exporter.program_schema(programs),f'suikoden-actor-programs/{version}')

    def test_only_proven_party_recovery_maps_to_round_boundaries(self):
        code,blocked,_=exporter.compile_operations([dict(op=40,args=[7,100]),dict(op=0,args=[])])
        self.assertFalse(blocked)
        self.assertEqual(code,[dict(command=dict(recovery=2)),dict(halt={})])
        for args in ([7,99],[8,100]):
            self.assertIsNone(exporter.compile_operations([dict(op=40,args=args),dict(op=0,args=[])])[0])

    def test_all_records_are_batched_and_unbound_operations_are_retained_as_proof(self):
        with tempfile.TemporaryDirectory(prefix='suikoden-program-test-') as temporary:
            packet, proof = exporter.export(Path(temporary))
            self.assertEqual(len(proof['unites']),32)
            self.assertEqual([r['record'] for r in proof['unites']],list(range(32)))
            self.assertEqual(len(packet['programs']),84)
            self.assertEqual(len(proof['programs']),84)
            ids = {p['id'] for p in packet['programs']}
            self.assertEqual(len(ids),84)
            self.assertIn('common/unite_return',ids)
            self.assertIn('common/fisherman_return',ids)
            self.assertFalse(any(p['unsupported'] for p in proof['programs']))
            for program in proof['programs']:
                self.assertEqual(program['id'] in ids,not bool(program['unsupported']))
                self.assertTrue(program['source']['lba'])
                self.assertTrue(program['sha256'])
            for program in packet['programs']:
                self.assertEqual(program['instructions'][-1],dict(halt={}))
                self.assertNotIn('tick',json.dumps(program))
                self.assertNotIn('source_offset',program)
                self.assertNotIn('operations',program)
            self.assertEqual(json.loads((Path(temporary)/'programs.json').read_text()),packet)
            resources=json.loads((Path(temporary)/'animations.json').read_text())['resources']
            self.assertEqual(len(resources),53)
            bundle=json.loads((Path(temporary)/'unites.json').read_text())
            self.assertEqual(bundle,dict(schema='suikoden-unite-actors/10',programs=packet,animations=json.loads((Path(temporary)/'animations.json').read_text()),unites=proof['unites']))
            self.assertEqual(bundle,json.loads((ROOT/'game/tests/fixtures/unite_actor_library.json').read_text()))
            for unite in bundle['unites']:
                if unite['record'] in (0,1,2,3,4,6,7,8,9,11,12,13,17,18,19,20,25,26,28,30):
                    self.assertEqual(unite['dispatch_after'],1)
                elif unite['record'] in (5,21,22,23,24):
                    self.assertEqual(unite['dispatch_after'],2)
                    self.assertEqual([m.get('start_after',0) for m in unite['members']],[0,45,90,135])
                    self.assertEqual([m.get('reaction_on_hit',False) for m in unite['members']],[True,True,True,False])
                else:self.assertNotIn('dispatch_after',unite)
            import battle_unite_camera
            report = battle_unite_camera.report()
            for index in battle_unite_camera.STARTUP_ONLY_RECORDS:
                self.assertIn('primary_startup', report[index])
                self.assertNotIn('dispatch_after', bundle['unites'][index])
            for resource in resources:
                origin=next(row for row in proof['resources'] if row['id']==resource['id'])
                raw=disc.extract(origin['source']['lba'],origin['source']['size'])
                base=origin['pointer_base']
                section=origin['section_offset']
                if resource['id']=='shared_impacts':
                    self.assertEqual(section,struct.unpack_from('<I',raw,0)[0]-base)
                else:
                    self.assertEqual(section,struct.unpack_from('<I',raw,36)[0])
                self.assertEqual(resource['pose_count'],struct.unpack_from('<H',raw,section)[0])
                entries,animations=[v-base for v in struct.unpack_from('<II',raw,section+16)]
                for clip in resource['clips']:
                    offset=struct.unpack_from('<I',raw,animations+4*clip['id'])[0]-base
                    self.assertEqual(clip['advances'],bool(raw[offset+1]&1))
                    self.assertEqual(clip['loop'],bool(raw[offset+1]&2))
                    self.assertEqual(clip['semitransparent'],bool(raw[offset+1]&4))
                    expected=[]
                    for index in range(raw[offset] or 1):
                        pose,updates=raw[offset+4+2*index:offset+6+2*index]
                        entry=struct.unpack_from('<I',raw,entries+4*pose)[0]-base
                        expected.append(dict(pose=pose,updates=updates or 256,attachment=[raw[entry+6]-raw[entry+4],raw[entry+7]-raw[entry+5]]))
                    self.assertEqual(clip['frames'],expected)
            members={'maas','moose','meese','mace','mose','lepant','pahn','kasumi','tai_ho'}
            selected={'common/unite_return','common/fisherman_return','lepant/unite_10','pahn/unite_10','kasumi/unite_10','tai_ho/unite_9','kirkis/unite_10'} | {f'{m}/unite_9' for m in ('maas','moose','meese','mace','mose')}
            for program in packet['programs']:
                for instruction in program['instructions']:
                    child=instruction.get('command',{}).get('child')
                    if child:
                        selected.update((program['id'],child['program']))
                        members.update((child['resource'],program['id'].split('/')[0]))
                        self.assertIn(child['program'],ids)
                        self.assertNotIn('flags',child)
                        resource=next(r for r in resources if r['id']==child['resource'])
                        self.assertIn(child['animation'],[c['id'] for c in resource['clips']])
            fixture=dict(programs=dict(schema=packet['schema'],programs=[p for p in packet['programs'] if p['id'] in selected]),
                         animations=dict(schema='suikoden-actor-animations/1',resources=[r for r in resources if r['id'] in members]))
            self.assertEqual(json.loads((ROOT/'game/tests/fixtures/unite_actor_vm.json').read_text()),fixture)
        with self.assertRaises(ValueError):exporter.export(ROOT/'kit/work/accepted/programs')

if __name__=='__main__':unittest.main()
