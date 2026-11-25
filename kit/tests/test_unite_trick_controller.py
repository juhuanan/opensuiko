"""Independent raw descriptors, constructor words, sine table and VRAM art checks."""
import json
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import actor_script
import unite_trick_controller as producer
from test_export_unite_review import vram_pose


class TrickController(unittest.TestCase):
    def test_source_words_and_constructor_coordinates(self):
        image=producer.source.Image()
        pins={0x800FB45C:0x24550050,0x800FB478:0x8E440040,0x800FB4A0:0x8C6200D4,
              0x800FB4AC:0x8C540030,0x800FB4C0:0x34050013,0x800FB4C4:0x00113040,
              0x800FB4C8:0x0C048CED,0x800E1E7C:0xAE700030,0x800E1E84:0x8E030014,
              0x800FB69C:0x30420010,0x800FB744:0x0803EE10,0x800FB748:0x28420040,
              0x800FB754:0x3042000F,0x800FB764:0x3404081B,0x800FB770:0x000421C0,
              0x800FB798:0x24630FFF,0x800FB7A0:0x00031B03,0x800FB7A8:0x2442FFF8,
              0x800FB7D0:0x8E620068,0x800FB7D8:0x00021303,0x800FB7DC:0x0062182A,
              0x800FB7FC:0x14400007,0x800FB804:0x34050002,0x800FB808:0x3406000A,
              0x800FB80C:0x0C03E57A,0x800FB818:0xAE020074,0x800FB83C:0x28420032,
              0x800FB864:0x2442FFFB,0x800FB874:0x28630040,0x800FB898:0x0C038E08,
              0x800FB8A0:0xAE130058,0x800FB8D8:0x3042FFEF,0x800FB91C:0x18400004,
              0x800FB928:0x2402FFFF,0x800FB950:0x0C048DC8,0x800FB96C:0x0C03E5C6,
              0x800FB99C:0x0C048D34,
              0x80123794:0x0C053A94,0x801237DC:0x00021303,
              0x801237F0:0x00021303,0x80123804:0x00021303,
              0x80123808:0x0C053D91,0x80123824:0x0C053ABC,
              0x80123838:0x0C053D71,0x8012389C:0x0C048D41}
        for address,word in pins.items():self.assertEqual(image.word(address),word,hex(address))
        report=producer.build()
        self.assertEqual(report['objects']['initial_y_q12'],[409600,292572,175543,58515,-58514,-175542,-292571,-409600])
        self.assertEqual(report['objects']['delays'],[0,2,4,6,8,10,12,14])
        self.assertEqual([p['updates'] for p in report['phases']],[64,50,64])
        serialized=json.loads(json.dumps(report))
        self.assertEqual(serialized,json.loads(producer.REPORT.read_text()))
        self.assertEqual(serialized,json.loads((ROOT/'game/tests/fixtures/trick_controller.json').read_text()))

    def test_descriptors_and_animation_come_from_the_member_resource(self):
        report=producer.build()
        for stream in [m['entry'] for m in report['members']]+[report['damage']['recipient']]:
            origin=stream['source'];raw=producer.source.field.source('/'+origin['file'].split('/')[-1])[0]
            table=struct.unpack_from('<I',raw,32)[0]
            start=struct.unpack_from('<I',raw,table+4*stream['script'])[0]
            cursor=start;ops=[]
            while True:
                op=struct.unpack_from('<h',raw,cursor)[0]
                words=actor_script.OP_LEN_HW[op]
                self.assertIsNotNone(words)
                words=max(1,words)
                args=list(struct.unpack_from('<'+'h'*(words-1),raw,cursor+2))
                ops.append(dict(op=op,args=args));cursor+=words*2
                if op in (0,1,2):break
            self.assertEqual((start,cursor-start),(stream['source_offset'],stream['byte_length']))
            self.assertEqual(ops,stream['operations'])
        self.assertEqual(report['art']['source']['file'],'DATA/04_PLAY/JUP.BIN')
        self.assertEqual(report['art']['section_offset'],2004)
        self.assertEqual(report['art']['animation_offset'],1868)
        self.assertEqual(report['art']['frames'],[dict(pose=12,updates=10),dict(pose=13,updates=1)])
        raw=producer.source.field.source('/JUP.BIN')[0]
        import export_battle_trial
        poses,_,_=export_battle_trial.section_art(raw,2004,animation_indices=[19],selected_poses_only=True)
        for pose in report['art']['poses']:
            offset=struct.unpack_from('<I',raw,struct.unpack_from('<I',raw,2004+16)[0]+4*pose['id'])[0]
            self.assertEqual(offset,pose['source_offset'])
            expected,ax,ay=vram_pose(raw,2004,pose['id'])
            actual,x,y=poses[pose['id']]
            self.assertEqual((actual.size,actual.tobytes(),x,y),(expected.size,expected.tobytes(),ax,ay))

    def test_heights_read_the_original_quarter_sine_table_with_truncation(self):
        image=producer.source.Image()
        table=struct.unpack_from('<1025h',image.data,0x801765BC-image.base)
        self.assertEqual((table[0],table[1024]),(0,4096))
        heights=[]
        for age in range(50):
            angle=age*128%2048
            value=table[min(angle,2048-angle)]
            heights.append(-(value*30//4096))
        self.assertEqual(heights,producer.build()['phases'][1]['heights'])
        self.assertEqual(heights[:17],[0,-5,-11,-16,-21,-24,-27,-29,-30,-29,-27,-24,-21,-16,-11,-5,0])

    def test_changed_controller_descriptor_or_wave_animation_refuses(self):
        image=producer.source.Image()
        for start,_,_ in producer.SPANS:
            raw=bytearray(image.data);raw[start-image.base]^=1
            with self.assertRaisesRegex(ValueError,'Trick controller changed'):
                producer.build(producer.source.Image(bytes(raw),image.base))
        changed=bytearray(image.data);changed[0x801765BC-image.base+2]^=1
        with self.assertRaisesRegex(ValueError,'Trick sine table changed'):
            producer.build(producer.source.Image(bytes(changed),image.base))
        original=producer.source.field.source
        raw,origin=original('/MEG.BIN');changed=bytearray(raw);changed[118]^=1
        with patch.object(producer.source.field,'source',return_value=(bytes(changed),origin)):
            with self.assertRaisesRegex(ValueError,'Trick descriptor changed'):producer.descriptor('/MEG.BIN',11)
        raw,origin=original('/JUP.BIN');changed=bytearray(raw);changed[1873]^=1
        def read(name):return (bytes(changed),origin) if name.endswith('/JUP.BIN') else original(name)
        with patch.object(producer.source.field,'source',side_effect=read):
            with self.assertRaisesRegex(ValueError,'Trick wave animation changed'):producer.build()


if __name__=='__main__':unittest.main()
