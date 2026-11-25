#!/usr/bin/env python3
"""Independent raw-table/raster checks for the batch Unite impact export."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import disc
import export_battle_trial
import maindec
import unite_reaction_assets as assets
from lzss import decode_strict


class Impacts(unittest.TestCase):
    def test_packet_tint_writer_updates_both_buffers_with_source_rgb_bytes(self):
        body=maindec.body()
        block=body[0x800e5a08-maindec.MBASE:0x800e5afc-maindec.MBASE]
        self.assertEqual(hashlib.sha256(block).hexdigest(),
            '7671362ad5439615e722e7fd34f9a4d09f3e7f28894bf1474b6c7e64666db825')
        for address,word in {
            0x8016bb60:0x800e5a08, # opcode41 handler slot
            0x800e5a34:0x90690002, 0x800e5a38:0x90680004,
            0x800e5a3c:0x90670006, # low bytes of the three halfword operands
            0x800e5a30:0x8c450084, 0x800e5a40:0x8ca20004,
            0x800e5a54:0x8ca20028, 0x800e5a84:0x8ca2002c,
            0x800e5ac4:0x24630028, # primitive stride40
            0x800e5ae8:0x24630008, # advance four halfwords
        }.items():self.assertEqual(maindec.mword(address),word,hex(address))
        stores=[word for (word,) in struct.iter_unpack('<I',block) if word>>26 in (40,41,43)]
        self.assertEqual(stores,[0xa0490004,0xa0480005,0xa0470006,
                                 0xa0490004,0xa0480005,0xa0470006,0xac43000c])

    def test_sound_export_preserves_existing_reactions_and_descriptor_order(self):
        import battle_unite_camera
        rows=battle_unite_camera.report()
        old=assets.reactions(rows)
        actual=assets.reactions(rows,include_sounds=True)
        self.assertEqual([{k:v for k,v in row.items() if k!='sounds'} for row in actual],old)
        by_id={(row['record'],row.get('variant',0)):row for row in actual}
        count=0
        for row in assets.reaction_rows(rows):
            source=row['target_reaction']
            if 'operations' not in source:continue
            expected=[dict(at=max(0,tick-1),id=op['args'][0]) for op,tick in zip(source['operations'],source['local_timing']['operation_ticks'],strict=True) if op['op']==34]
            self.assertEqual(by_id[(row['index'],row.get('variant',0))].get('sounds',[]),expected)
            count+=len(expected)
        self.assertEqual(count,43)

    @classmethod
    def setUpClass(cls):
        cls.packet, cls.images = assets.build()
        src = cls.packet['source']
        cls.raw = disc.extract(src['lba'], src['size'])

    def test_source_selection_and_all_spawn_sites(self):
        # VM arg1 is passed to the constructor, which indexes the F table.
        for pc, word in {0x800E4CD4: 0x84450004, 0x800E4CFC: 0x3C04800B,
                         0x800E4D00: 0x8C84A000, 0x800E4D0C: 0x0C03878F,
                         0x800E1E6C: 0xAFA50010, 0x800E1E80: 0x8FAC0010,
                         0x800E1E84: 0x8E030014, 0x800E1E88: 0x000C1080,
                         0x800E1E8C: 0x00431021, 0x800E1E90: 0x8C420000}.items():
            self.assertEqual(maindec.mword(pc), word, hex(pc))
        rows = json.loads((ROOT / 'kit/data/reports/battle_unite_camera.json').read_text())
        expected = []
        for row in assets.reaction_rows(rows):
            reaction = row['target_reaction']
            for i, op in enumerate(reaction.get('operations', [])):
                if op['op'] == 24:
                    f, a, child, *xyz = op['args']
                    self.assertEqual(f & 1, 0)
                    self.assertIn(child,(0,13) if reaction.get('recipient_binding') else (0,))
                    expected.append(dict(record=row['index'], operation=i,
                                         local_tick=reaction['local_timing']['operation_ticks'][i],
                                         animation=a, offset=xyz, flags=f))
                    if row.get('variant'):expected[-1]['variant']=row['variant']
                    if child==13:expected[-1]['child']=13
        self.assertEqual(self.packet['spawns'], expected)
        self.assertEqual(len(expected), 77)
        self.assertEqual(len({s['record'] for s in expected}), 28)

    def test_independent_animation_tables(self):
        raw = self.raw
        base = 0x800AA000
        section = struct.unpack_from('<I', raw)[0] - base
        table = struct.unpack_from('<I', raw, section + 20)[0] - base
        pairs = [((10,3),(11,4),(12,2),(13,4),(14,2),(15,2),(16,2),(17,2)),
                 ((10,3),(18,4),(19,2),(20,2),(21,2),(22,2),(23,2),(24,2)),
                 ((10,3),(25,5),(52,3),(53,3),(54,2),(55,2)),
                 ((10,3),(56,5),(57,3),(58,3),(59,2),(60,2),(61,2)),
                 ((82,3),(90,4),(91,2),(92,2),(93,2),(94,2),(95,2),(96,2)),
                 ((82,3),(97,5),(52,3),(53,3),(54,2),(55,2))]
        self.assertEqual([c['id'] for c in self.packet['animations']],[0,1,2,3,18,19])
        self.assertEqual(self.packet['ranged_critical_animations'],[3,19])
        self.assertEqual(len(self.packet['ranged_critical_sources']),18)
        for clip, expected, duration, allocation in zip(self.packet['animations'], pairs, (21,19,18,20,19,18), (2,2,2,3,2,2), strict=True):
            offset = struct.unpack_from('<I', raw, table + 4*clip['id'])[0] - base
            self.assertEqual(raw[offset:offset+4], bytes((len(expected),1,allocation,0)))
            self.assertEqual(tuple(struct.iter_unpack('BB', raw[offset+4:offset+4+2*len(expected)])), expected)
            self.assertEqual(clip['frames'], [dict(entry=e, ticks=t) for e,t in expected])
            self.assertEqual(clip['duration'], duration)

    def test_reaction_lowering_and_original_motion_consumers(self):
        for pc,word in {0x800E4774:0x00035B00,0x800E478C:0x0004C2C0,
                         0x800E47CC:0x01203821,0x800E47E8:0x8C430068,
                         0x800E47EC:0x8C42006C,0x800E4800:0x8CC2005C,
                         0x800E4874:0x00C7001A,0x800E3748:0xAF050068,
                         0x800E3760:0xAF08002C,0x800E37A8:0xAF040068,
                         0x800E4F54:0x90C20006,0x800E4F58:0x90C30004,
                         0x800E4F64:0xA0A20078,0x800E4F78:0xA0A20079,
                         0x800E0BC8:0x26730054,0x800E0BD8:0x1040FF9D,
                         0x800E5E68:0x34040013,0x800E5E84:0xA0650003,
                         0x800E5E88:0xA0650002,0x800E5EC4:0x2484FFFF,
                         0x800E39EC:0xA0400002,0x800E2AC0:0x2442FFFF,
                         0x800E2B10:0xAC820008,0x800E3C14:0x14400005,
                         0x800E585C:0x34040120,0x800E5864:0x340501F0,
                         0x800DEA4C:0x34020120,0x800DEA54:0x340201F0,
                         0x800DEA5C:0x34020020,0x800DEA64:0x34020007,
                         0x800DEA6C:0x3C058017,0x800DEA70:0x24A5B8A8,
                         0x800DEA74:0x0C052164,0x800E1F50:0x0C038811,
                         0x800E0BF4:0x24720001,0x800E0C5C:0x0C038AA7,
                         0x800E0C64:0x0C038D63,0x800E0D70:0x24520001,
                         0x800E0D74:0x2A420014,0x800E0DC8:0x0C038AA7,
                         0x800E0DD0:0x0C038D63,0x800E0DE8:0x2442FFFF,
                         0x800E0DF8:0x10400016,0x800E0E58:0x2A420014}.items():
            self.assertEqual(maindec.mword(pc),word,hex(pc))
        programs=self.packet['reactions']
        self.assertEqual(len(programs),39)
        self.assertEqual([p['record'] for p in programs if p['blocker']],[])
        for p in programs:
            if p['blocker']:
                self.assertFalse(any(p[k] for k in ('poses','white','offsets','motions','impacts')))
        for p,duration,jump in zip(programs[:2],(37,21),(32,16),strict=True):
            self.assertEqual(p['duration'],duration)
            self.assertEqual(p['white'],[dict(at=2,enabled=True),dict(at=duration-2,enabled=False)])
            self.assertEqual(p['poses'],[dict(at=0,animation=1),dict(at=duration-1,animation=0)])
            self.assertEqual(p['motions'],[
                dict(at=2,updates=jump,home=False,linear=False,offset_q12=[0]*3,velocity_q12=[-6144,0,0]),
                dict(at=duration-1,updates=1,home=True,linear=True,offset_q12=[0]*3,velocity_q12=[0]*3)])

    def test_warriors_callback_reaction_uses_shared_recipient_player(self):
        reaction = next(p for p in self.packet['reactions'] if p['record'] == 15)
        self.assertEqual((reaction['variant'], reaction['duration'], reaction['blocker']), (1, 53, None))
        self.assertEqual(reaction['poses'], [dict(at=0, animation=1), dict(at=52, animation=0)])
        self.assertEqual(reaction['white'], [dict(at=2, enabled=True), dict(at=51, enabled=False)])
        self.assertEqual(reaction['colors'], [dict(at=2, rgb=[255, 64, 64]), dict(at=51, rgb=[128]*3)])
        self.assertEqual(reaction['impacts'], [dict(at=2, animation=2, offset=[0, 0, 0])])
        self.assertEqual(reaction['motions'], [
            dict(at=2, updates=48, home=False, linear=False, offset_q12=[0]*3, velocity_q12=[-6144, 0, 0]),
            dict(at=52, updates=1, home=True, linear=True, offset_q12=[0]*3, velocity_q12=[0]*3)])

    def test_couple_palette_cycle_uses_original_descriptor_and_callback(self):
        import battle_unite_camera
        import export_unite_programs
        row = next(r for r in battle_unite_camera.report() if r['index'] == 16)
        source = row['target_reaction']
        operations = source['operations']
        self.assertEqual([(o['op'],o['args']) for o in operations if o['op'] in (30,35,42)],
                         [(42,[3,0,1,4]),(30,[0]),(35,[0,13]),(30,[99])])
        for address,word in {0x800F3ADC:0x96120046,0x800F3AE0:0x96130048,
                             0x800F3BD4:0x0C052AF5,0x800F3C18:0x8CC20008}.items():
            self.assertEqual(maindec.mword(address),word,hex(address))
        instructions,blocked,effects = export_unite_programs.compile_operations(operations)
        self.assertFalse(blocked)
        self.assertEqual(effects,['palette_cycle'])
        expected = dict(schema='suikoden-actor-programs/7',programs=[dict(id='couple/recipient',instructions=instructions)])
        self.assertEqual(expected,json.loads((ROOT/'game/tests/fixtures/couple_recipient_program.json').read_text()))
        reaction = next(p for p in self.packet['reactions'] if p['record']==16)
        self.assertIsNone(reaction['blocker'])
        self.assertEqual(reaction['palette_cycle'],dict(start=0,stop=32,period=4,row=1))
        missing_stop = copy.deepcopy(source)
        index = next(i for i,o in enumerate(missing_stop['operations']) if o == dict(op=30,args=[99]))
        missing_stop['operations'][index]['args'] = [1]
        with self.assertRaisesRegex(ValueError,'Unterminated recipient palette cycle'):
            assets.reactions([dict(index=16,target_reaction=missing_stop)])
        unsupported_row = copy.deepcopy(source)
        next(o for o in unsupported_row['operations'] if o['op']==42)['args'][2] = 2
        self.assertIsNotNone(assets.reactions([dict(index=16,target_reaction=unsupported_row)])[0]['blocker'])

    def test_nonpositive_linear_motion_waits_for_the_source_one_update_snap(self):
        import battle_unite_camera
        import journey_battle
        for address,word in {0x800E4BC8:0x34020001,0x800E4BCC:0xA4E20010,
                             0x800E45E4:0x84820010,0x800E45EC:0x1C400005}.items():
            self.assertEqual(maindec.mword(address),word,hex(address))
        for duration in (0,-1):
            result=journey_battle.script_events([],[(33,(3,duration,0,0,-400)),(21,()),(3,(16,)),(0,())],initial_movement_wait=True)
            self.assertEqual(result['operation_ticks'],[0,0,2,18])
            self.assertEqual(result['duration'],18)
        reaction=next(r for r in battle_unite_camera.report() if r['index']==27)['target_reaction']
        self.assertEqual(reaction['local_timing']['duration'],110)
        import export_unite_programs
        main,blocked,effects=export_unite_programs.compile_operations(reaction['operations'],'beat_recipient')
        self.assertFalse(blocked);self.assertEqual(effects,['palette_cycle'])
        child,blocked,effects=export_unite_programs.compile_operations(reaction['auxiliary_scripts'][0]['operations'])
        self.assertFalse(blocked);self.assertFalse(effects)
        expected=dict(schema='suikoden-actor-programs/7',programs=[dict(id='beat_recipient',instructions=main),dict(id='beat_recipient/auxiliary/shared_0',instructions=child)])
        self.assertEqual(expected,json.loads((ROOT/'game/tests/fixtures/beat_em_up_recipient_program.json').read_text()))
        lowered=next(p for p in self.packet['reactions'] if p['record']==27)
        self.assertIsNone(lowered['blocker'])
        self.assertEqual(lowered['duration'],109)
        self.assertEqual(lowered['motions'],[
            dict(at=0,updates=60,home=True,linear=True,offset_q12=[-1638400,0,0],velocity_q12=[0]*3,linear_offset=True),
            dict(at=60,updates=1,home=True,linear=True,offset_q12=[0,0,-1638400],velocity_q12=[0]*3,linear_offset=True),
            dict(at=77,updates=30,home=True,linear=True,offset_q12=[0]*3,velocity_q12=[0]*3,linear_offset=True)])
        self.assertEqual(lowered['palette_cycle'],dict(start=0,stop=107,period=4,row=1))
        self.assertEqual([(p['at'],p['animation']) for p in lowered['poses']],[(0,1),(60,0)])
        self.assertEqual([p['at'] for p in lowered['impacts']],list(range(0,33,4)))

    def test_lepant_family_recipient_scripts_and_controller_are_independently_pinned(self):
        import battle_unite_camera
        import export_unite_programs
        import export_first_room
        from test_physical_rune_export import independent_stream
        from test_physical_controller import clock
        row=next(r for r in battle_unite_camera.report() if r['index']==30)
        for pc,word in {0x800FE43C:0x8C66002C,0x800FE488:0x8C460030,
                        0x800FE4BC:0x8C460024,0x800FE578:0x30420002,
                        0x800FE58C:0x8C46003C,0x800FE590:0x0C038E08,
                        0x800FE5C0:0x3063FFFD,0x800FE5F4:0x30420010,
                        0x800FE600:0x34050003,0x800FE604:0x34060014,
                        0x800FE608:0x0C03E57A,0x800FE618:0x3042FFEF}.items():
            self.assertEqual(maindec.mword(pc),word,hex(pc))
        self.assertEqual([a['variant'] for a in row['direct_assists']['assists']],[1,2,3])
        for member,script,hit,ready in zip(row['member_scripts'],(11,12,9),(142,219,109),(238,284,244),strict=True):
            origin=member['source'];raw=disc.extract(origin['lba'],origin['size']);table=struct.unpack_from('<I',raw,32)[0]
            operations=independent_stream(raw,struct.unpack_from('<I',raw,table+4*script)[0],table)
            times=clock(raw,operations)
            self.assertEqual((times['signals'][(0,2)],times['signals'][(0,4)]),(hit,ready))
        expected=[];_,main=export_first_room.source('MAIN.EXE')
        for assist in row['direct_assists']['assists']:
            reaction=assist['reaction'];variant=assist['variant'];prefix=f'family/recipient{variant}'
            source=reaction['source'];raw=disc.extract(source['lba'],source['size'])
            table=struct.unpack_from('<I',raw,32)[0];offset=struct.unpack_from('<I',raw,table+15*4)[0]
            operations=independent_stream(raw,offset,table)
            self.assertEqual(operations,reaction['operations'])
            if variant==2:
                self.assertEqual([o for o in operations if o['op']==42],[dict(op=42,args=[3,0,1,4])])
                self.assertFalse(any(o['op']==35 for o in operations))
                operations=[o for o in operations if o['op']!=42]
            code,blocked,_=export_unite_programs.compile_operations(operations,prefix)
            self.assertFalse(blocked);expected.append(dict(id=prefix,instructions=code))
            _,children=battle_unite_camera.auxiliary_scripts(raw,source,[dict(script=15,operations=reaction['operations'])],main)
            for child in children:
                code,blocked,_=export_unite_programs.compile_operations(child['operations'])
                self.assertFalse(blocked);expected.append(dict(id=prefix+'/auxiliary/'+child['id'].replace(':','_'),instructions=code))
        fixture=json.loads((ROOT/'game/tests/fixtures/lepant_family_recipient_programs.json').read_text())
        self.assertEqual(fixture,dict(schema='suikoden-actor-programs/7',programs=expected))
        reactions=[p for p in self.packet['reactions'] if p['record']==30]
        self.assertEqual([p['variant'] for p in reactions],[1,2,3])
        self.assertTrue(all(p['blocker'] is None for p in reactions))
        self.assertEqual(reactions[1]['signals'],[dict(at=39,bits=16,set=True)])

    def test_pirate_recipient_initial_motion_is_verified_against_the_raw_stream(self):
        import battle_unite_camera
        import export_unite_programs
        from test_physical_rune_export import independent_stream
        reaction=next(r for r in battle_unite_camera.report() if r['index']==4)['target_reaction']
        source=reaction['source'];raw=disc.extract(source['lba'],source['size'])
        table=struct.unpack_from('<I',raw,32)[0];offset=struct.unpack_from('<I',raw,table+15*4)[0]
        operations=independent_stream(raw,offset,table)
        self.assertEqual(operations,reaction['operations'])
        code,blocked,_=export_unite_programs.compile_operations(operations,'pirate/recipient')
        self.assertFalse(blocked);expected=[dict(id='pirate/recipient',instructions=code)]
        for child in reaction['auxiliary_scripts']:
            code,blocked,_=export_unite_programs.compile_operations(child['operations'])
            self.assertFalse(blocked);expected.append(dict(id='pirate/recipient/auxiliary/'+child['id'].replace(':','_'),instructions=code))
        self.assertEqual(json.loads((ROOT/'game/tests/fixtures/pirate_recipient_program.json').read_text()),dict(schema='suikoden-actor-programs/7',programs=expected))
        self.assertEqual(reaction['local_timing']['duration'],36)

    def test_recipient_signals_match_original_writers_and_raw_clocks(self):
        for pc,word in {0x8016BB24:0x800E4FD8,0x8016BB28:0x800E5070,
                        0x800E5004:0x94480004,0x800E5014:0x14620007,
                        0x800E5044:0x94A30040,0x800E5050:0x01031825,
                        0x800E5054:0xA4A30040,0x800E509C:0x94480004,
                        0x800E50AC:0x14620007,0x800E50D8:0x00082027,
                        0x800E50DC:0x94A20040,0x800E50E8:0x00441024,
                        0x800E50EC:0xA4A20040}.items():
            self.assertEqual(maindec.mword(pc),word,hex(pc))
        expected={(8,1):[dict(at=101,bits=2,set=True)],
                  (28,1):[dict(at=101,bits=2,set=True)],
                  (10,0):[dict(at=0,bits=4,set=False),dict(at=34,bits=4,set=True)],
                  (17,2):[dict(at=14,bits=2,set=True),dict(at=22,bits=4,set=True)],
                  (31,0):[dict(at=0,bits=4,set=False),dict(at=34,bits=4,set=True)],
                  (30,2):[dict(at=39,bits=16,set=True)]}
        actual={(p['record'],p.get('variant',0)):p['signals'] for p in self.packet['reactions'] if p.get('signals')}
        self.assertEqual(actual,expected)
        for op,args in ((26,[1,2]),(27,[0,0]),(26,[0,65536])):
            source=dict(local_timing=dict(duration=2,operation_ticks=[0,1]),
                        operations=[dict(op=4,args=[1]),dict(op=op,args=args)])
            with self.assertRaisesRegex(ValueError,'recipient signal'):
                assets.reactions([dict(index=17,target_reaction=source)])
        source=dict(local_timing=dict(duration=2,operation_ticks=[0,1]),
                    operations=[dict(op=4,args=[1]),dict(op=27,args=[0,-1])])
        self.assertEqual(assets.reactions([dict(index=17,target_reaction=source)])[0]['signals'],
                         [dict(at=0,bits=65535,set=False)])
        source=dict(local_timing=dict(duration=2,operation_ticks=[0,1,2]),
                    operations=[dict(op=4,args=[1]),dict(op=26,args=[0,2]),dict(op=35,args=[0,99])])
        self.assertNotIn('signals',assets.reactions([dict(index=17,target_reaction=source)])[0])

    def test_beauty_recipient_tint_and_sleep_follow_raw_descriptor_clocks(self):
        for record in (9,25):
            program=next(p for p in self.packet['reactions'] if p['record']==record and p.get('variant')==1)
            self.assertIsNone(program['blocker'])
            self.assertEqual(program['duration'],132)
            self.assertEqual(program['colors'],[dict(at=2,rgb=[192,64,64]),dict(at=130,rgb=[128,128,128])])
            self.assertEqual(program['white'],[dict(at=2,enabled=True),dict(at=130,enabled=False)])
            self.assertEqual(program['status_attempts'],[dict(at=132,kind='enemy_sleep',failure_percent=30)])
            self.assertTrue(program.get('locks_target',True))
        source=dict(local_timing=dict(duration=2,operation_ticks=[0,1]),operations=[dict(op=4,args=[1]),dict(op=40,args=[4,30])])
        with self.assertRaises(ValueError):assets.reactions([dict(index=9,target_reaction=source)])
        source['operations'][1]=dict(op=41,args=[256,0,0])
        with self.assertRaises(ValueError):assets.reactions([dict(index=9,target_reaction=source)])

    def test_ninja_recipient_uses_qualified_callback_path_and_shared13(self):
        program=next(p for p in self.packet['reactions'] if p['record']==28 and p.get('variant')==1)
        self.assertIsNone(program['blocker'])
        self.assertFalse(program['locks_target'])
        self.assertEqual({(p['record'],p.get('variant',0)) for p in self.packet['reactions'] if not p.get('locks_target',True)},{(8,1),(28,1),(30,2)})
        self.assertEqual(program['duration'],133)
        self.assertEqual(program['flip'],dict(start=60,stop=116))
        self.assertEqual(program['focus_z_pulses'],[dict(at=100,delta_q12=20480),dict(at=102,delta_q12=-20480)])
        self.assertEqual(program['impacts'],[dict(at=101,animation=0,offset=[5,5,0],centered=False)])
        self.assertEqual(program['motions'],[
            dict(at=9,updates=20,home=False,linear=False,absolute=True,offset_q12=[0,0,-1638400],velocity_q12=[0,0,-16384]),
            dict(at=60,updates=40,home=False,linear=False,absolute=True,offset_q12=[0,0,0],velocity_q12=[0,0,0])])

    def test_lock_lowering_refuses_delayed_acquisition_and_unreleased_lock(self):
        source=dict(operations=[dict(op=3,args=[3]),dict(op=15,args=[0,8]),dict(op=3,args=[4]),dict(op=16,args=[0,8]),dict(op=0,args=[])],
                    local_timing=dict(duration=7,operation_ticks=[0,3,3,7,7]))
        with self.assertRaisesRegex(ValueError,'lock interval'):
            assets.reactions([dict(index=0,target_reaction=source)])
        source=dict(operations=[dict(op=15,args=[0,8]),dict(op=3,args=[3]),dict(op=0,args=[])],
                    local_timing=dict(duration=3,operation_ticks=[0,0,3]))
        with self.assertRaisesRegex(ValueError,'Unreleased'):
            assets.reactions([dict(index=0,target_reaction=source)])

    def test_independent_raster_all_selected_pixels(self):
        raw, base = self.raw, 0x800AA000
        def pointer(o):
            return struct.unpack_from('<I', raw, o)[0] - base
        section = pointer(0)
        ct, dt, et = [pointer(section + i) for i in (8,12,16)]
        planes = []
        for i in range(3):
            blob = pointer(ct + i*4)
            length = struct.unpack_from('<I', raw, blob)[0]
            planes.append(np.frombuffer(decode_strict(raw[blob+4:blob+4+length]), dtype=np.uint8).reshape(128,128))
        palettes = [np.frombuffer(raw[pointer(dt+4*i):pointer(dt+4*i)+64], dtype='<u2') for i in range(3)]
        for entry, image in zip(self.packet['entries'], self.images, strict=True):
            off = pointer(et + 4*entry['id'])
            n, _, width, height, ax, ay = raw[off:off+6]
            pieces = list(struct.iter_unpack('8B', raw[off+8:off+8+n*8]))
            width = max([width] + [p[0]+p[4]+1 for p in pieces])
            height = max([height] + [p[1]+p[5]+1 for p in pieces])
            canvas = np.zeros((height,width,4),dtype=np.uint8)
            for x,y,page,tile,wm,hm,pal,flip in pieces:
                u,v = (tile % 16)*8, (tile // 16)*8
                indices = planes[page][v:v+hm+1,u:u+wm+1]
                words = palettes[pal][indices].astype(np.uint32)
                rgba = np.stack([((words >> shift)&31)*255//31 for shift in (0,5,10)] + [(words!=0)*255],axis=-1).astype(np.uint8)
                if flip & 1: rgba = rgba[::-1]
                if flip & 2: rgba = rgba[:,::-1]
                destination = canvas[y:y+hm+1,x:x+wm+1]
                destination[rgba[:,:,3]!=0] = rgba[rgba[:,:,3]!=0]
            self.assertEqual((entry['dx'],entry['dy']),(-ax,-ay))
            self.assertEqual(image.tobytes(),canvas.tobytes(),entry['id'])
            self.assertEqual(entry['rgba_sha256'],hashlib.sha256(canvas.tobytes()).hexdigest())
        self.assertEqual(len(self.images),35)

    def test_declared_bounds_require_a_proven_extent_for_critical_records(self):
        section = self.packet['source']['section']
        with self.assertRaisesRegex(ValueError,'missing pose'):
            export_battle_trial.section_art(self.raw,section,0x800AA000)
        for selected in ((-1,), (23,), (False,), (0,False), ('0',)):
            with self.assertRaisesRegex(ValueError,'selection outside'):
                export_battle_trial.section_art(self.raw,section,0x800AA000,animation_indices=selected)
        damaged = bytearray(self.raw)
        damaged[self.packet['animations'][0]['source_offset']+4] = 255
        with self.assertRaisesRegex(ValueError,'missing pose'):
            export_battle_trial.section_art(damaged,section,0x800AA000,animation_indices=(0,1,2))

    def test_export_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            packet = assets.export(output)
            self.assertEqual(packet,json.loads((output/'impacts.json').read_text()))
            self.assertEqual(packet['atlas_sha256'],hashlib.sha256((output/'impacts.png').read_bytes()).hexdigest())
            with Image.open(output/'impacts.png') as atlas:
                for entry,image in zip(packet['entries'],self.images,strict=True):
                    rect=entry['rect'];x,y,w,h=[rect[k] for k in ('x','y','w','h')]
                    self.assertEqual(atlas.crop((x,y,x+w,y+h)).tobytes(),image.tobytes())

    def test_bandit_lock_handoff_and_duration_bounds(self):
        paired = [p for p in self.packet['reactions'] if p['record'] == 17]
        self.assertEqual([(p.get('variant'), p['duration'], p.get('locks_target', True)) for p in paired],
                         [(1, 32, True), (2, 74, True)])
        self.assertTrue(paired[0]['retain_lock'])
        self.assertNotIn('retain_lock',paired[1])
        row17 = copy.deepcopy(next(r for r in assets.battle_unite_camera.report() if r['index'] == 17))
        only_v1 = copy.deepcopy(row17)
        only_v1['direct_assists']['variants'] = [only_v1['direct_assists']['variants'][0]]
        with self.assertRaisesRegex(ValueError, 'Unreleased recipient lock'):
            assets.reactions([only_v1])
        non17 = dict(index=0, variant=1, target_reaction=only_v1['direct_assists']['variants'][0]['reaction'])
        with self.assertRaisesRegex(ValueError, 'Unreleased recipient lock'):
            assets.reactions([non17])


if __name__ == '__main__':
    unittest.main()
