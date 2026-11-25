"""Independent static callback and recipient-table witnesses for Martial arts."""
import json
from pathlib import Path
import struct
import sys
import unittest
import copy

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
import unite_martial_controller as producer
import battle_unite_camera
import disc


class MartialController(unittest.TestCase):
    def test_shared_strike_compiles_for_distinct_member_animations(self):
        packet=producer.actor_programs()
        self.assertEqual([row['id'] for row in packet['bindings']],['eikei','pahn','morgan'])
        self.assertEqual(len(packet['programs']['programs']),9)
        programs={row['id']:row['instructions'] for row in packet['programs']['programs']}
        self.assertEqual(programs['eikei/martial_strike'],programs['pahn/martial_strike'])
        self.assertEqual(programs['eikei/martial_strike'],programs['morgan/martial_strike'])
        clips=[next(clip for clip in row['clips'] if clip['id']==16) for row in packet['animations']['resources']]
        self.assertNotEqual(clips[0]['frames'],clips[1]['frames'])
        self.assertNotEqual(clips[1]['frames'],clips[2]['frames'])
        self.assertEqual(packet,json.loads(producer.ACTOR_REPORT.read_text()))
        self.assertEqual(packet,json.loads((ROOT/'game/tests/fixtures/martial_actors.json').read_text()))

    def test_paired_recipient_lowering_retains_lock_palette_and_sound_order(self):
        import unite_reaction_assets
        packet = producer.recipient_programs()
        first, second = packet['programs']
        self.assertTrue(first['retain_lock'])
        self.assertNotIn('locks_target', second)
        self.assertNotIn('retain_lock', second)
        self.assertEqual((first['duration'],second['duration']),(230,106))
        self.assertEqual(len(first['impacts']),17)
        self.assertEqual(first['motions'],[dict(at=170,updates=60,home=True,linear=False,
                                              offset_q12=[0,0,-400*4096],velocity_q12=[0,0,-32768])])
        self.assertEqual(first['sounds'][-2:],[dict(at=170,id=0x51a),dict(at=170,id=0x519)])
        self.assertEqual(second['white'],[dict(at=0,enabled=True),dict(at=105,enabled=False)])
        self.assertEqual(second['poses'],[dict(at=0,animation=1),dict(at=105,animation=0)])
        self.assertEqual([motion['at'] for motion in second['motions']],[0,60,90])
        rows=[dict(index=29,variant=i+1,target_reaction=row) for i,row in enumerate(packet['source'])]
        with self.assertRaisesRegex(ValueError,'Unreleased recipient lock'):
            unite_reaction_assets.reactions(rows[:1],lock_handoffs=((29,1,2),))
        changed=copy.deepcopy(rows)
        recipient=changed[1]['target_reaction']
        pairs=[(op,tick) for op,tick in zip(recipient['operations'],recipient['local_timing']['operation_ticks'],strict=True) if op['op']!=16]
        recipient['operations']=[op for op,_ in pairs]
        recipient['local_timing']['operation_ticks']=[tick for _,tick in pairs]
        with self.assertRaisesRegex(ValueError,'Unreleased recipient lock'):
            unite_reaction_assets.reactions(changed,lock_handoffs=((29,1,2),))
        self.assertEqual(packet,json.loads(producer.RECIPIENT_REPORT.read_text()))
        self.assertEqual(packet,json.loads((ROOT/'game/tests/fixtures/martial_recipients.json').read_text()))

    def test_raw_callback_stages_and_dispatches(self):
        image = battle_unite_camera.Image()
        expected = {0x800FE080:0x30420010, 0x800FE0D4:0x8C460028,
                    0x800FE170:0x3042FFEF, 0x800FE17C:0x2AC2000C,
                    0x800FE1B8:0x30420002, 0x800FE200:0x8C46002C,
                    0x800FE234:0x3063FFFD, 0x800FE23C:0x2A020003,
                    0x800FE250:0x34050003, 0x800FE264:0x34020050,
                    0x800FE2D8:0x8C460030, 0x800FE2E0:0x0C038E08,
                    0x800FE26C:0x3402008C, 0x800FE320:0x34050003,
                    0x800FE324:0x34060005, 0x800FE328:0x0C03E57A,
                    0x800FE348:0x286200C8, 0x800FE350:0x24620001}
        for address, word in expected.items():
            self.assertEqual(image.word(address), word, hex(address))
        result = producer.build(image)
        self.assertEqual([result['finish'][key] for key in ('recipient_return_counter','damage_counter','cleanup_counter')], [80,140,200])
        timing=json.loads((ROOT/'game/tests/fixtures/martial_queue_timing.json').read_text())
        self.assertEqual(timing,dict(recipient_return=result['finish']['recipient_return_counter'],
                                     damage=result['finish']['damage_counter'],cleanup=result['finish']['cleanup_counter']))
        self.assertEqual([row['script'] for row in result['recipients']], [11,12])
        for row in result['recipients']:
            origin = row['source']
            raw = disc.extract(origin['lba'],origin['size'])
            table = struct.unpack_from('<I',raw,32)[0]
            start = struct.unpack_from('<I',raw,table+4*row['script'])[0]
            cursor = start
            self.assertEqual(start,row['source_offset'])
            for op in row['operations']:
                expected = (op['op'],*op['args'])
                self.assertEqual(struct.unpack_from('<'+'h'*len(expected),raw,cursor),expected)
                cursor += 2*len(expected)
            self.assertEqual(cursor-start,row['byte_length'])
        self.assertEqual(json.loads(producer.REPORT.read_text()),result)

    def test_changed_controller_refuses(self):
        image = battle_unite_camera.Image()
        for start, _, _ in producer.SPANS:
            data = bytearray(image.data)
            data[start-image.base] ^= 1
            with self.assertRaisesRegex(ValueError,'controller changed'):
                producer.build(battle_unite_camera.Image(bytes(data),image.base))


if __name__ == '__main__':
    unittest.main()
