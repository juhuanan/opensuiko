"""Actor packing preserves every sampled RGBA byte and all non-rectangle metadata."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
import battle_actor_atlas as packing


def pose(x, y, w, h, anchor=0):
    return dict(rect=dict(x=x, y=y, w=w, h=h), anchor_x=anchor, anchor_y=-3)


def assert_preserved(case, before, source, after, packed):
    count=0
    def compare(a,b):
        nonlocal count
        case.assertEqual(type(a),type(b))
        if isinstance(a,dict):
            case.assertEqual(a.keys(),b.keys())
            if {'rect','anchor_x','anchor_y'}<=a.keys():
                case.assertEqual({k:v for k,v in a.items() if k!='rect'},{k:v for k,v in b.items() if k!='rect'})
                case.assertEqual((a['rect']['w'],a['rect']['h']),(b['rect']['w'],b['rect']['h']))
                def sample(image,p):
                    r=p['rect'];return image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes()
                case.assertEqual(sample(source,a),sample(packed,b));count+=1;return
            for key in a:compare(a[key],b[key])
        elif isinstance(a,list):
            for x,y in zip(a,b,strict=True):compare(x,y)
        else:case.assertEqual(a,b)
    compare(before,after)
    return count


class ActorAtlas(unittest.TestCase):
    def test_nested_poses_deduplicate_pixels_without_changing_anchors_or_rules(self):
        image=Image.new('RGBA',(16,32))
        pixels=Image.new('RGBA',(3,2))
        pixels.putdata([(1,2,3,0),(2,3,4,255),(5,6,7,128),(8,9,10,255),(11,12,13,1),(14,15,16,255)])
        image.paste(pixels,(0,4));image.paste(pixels,(8,19))
        content=dict(atlas='actors.png', party=[dict(sprite=pose(0,4,3,2),attack=[dict(pose=pose(8,19,3,2,7),ticks=12)])],
            unite_graphics=[dict(id='actor',poses=[dict(sprite=pose(0,4,3,2),pieces=[pose(8,19,3,2,-9)])])],
            ground=dict(rect=dict(x=0,y=0,w=100,h=100)), rules=dict(damage=17))
        before=copy.deepcopy(content);raw=image.tobytes()
        result,packed,proof=packing.repack(content,image)
        self.assertEqual(content,before);self.assertEqual(image.tobytes(),raw)
        self.assertEqual((proof['pose_references'],proof['source_rectangles'],proof['unique_bitmaps']),(4,2,1))
        self.assertEqual(packed.size,(16,2))
        self.assertEqual(assert_preserved(self,content,image,result,packed),4)
        again,second,no_change=packing.repack(result,packed)
        self.assertEqual(again,result);self.assertEqual(second.tobytes(),packed.tobytes());self.assertIsNone(no_change)

    def test_invalid_rectangles_refuse_and_overlapping_storage_can_keep_original_layout(self):
        image=Image.new('RGBA',(2,4096))
        content=dict(sprites=[pose(0,0,2,4096),pose(0,0,2,4095)])
        result,packed,proof=packing.repack(content,image)
        self.assertEqual(result,content);self.assertEqual(packed.tobytes(),image.tobytes());self.assertIsNone(proof)
        for rect in (dict(x=-1,y=0,w=1,h=1),dict(x=0,y=0,w=3,h=1),dict(x=0,y=0,w=1,h=0),dict(x=True,y=0,w=1,h=1)):
            bad=pose(0,0,1,1);bad['rect']=rect
            with self.assertRaisesRegex(ValueError,'actor pose rectangle'):packing.repack(dict(sprite=bad),image)

    def test_package_provenance_idempotence_and_accepted_guard(self):
        with tempfile.TemporaryDirectory(prefix='battle-packing-') as temporary:
            folder=Path(temporary)
            Image.new('RGBA',(8,32),(1,2,3,255)).save(folder/'actors.png')
            (folder/'trial.json').write_text(json.dumps(dict(atlas='actors.png',sprite=pose(0,4,2,3))))
            (folder/'provenance.json').write_text(json.dumps(dict(source='retained')))
            proof=packing.compact_package(folder,'test')
            self.assertEqual(proof['stage'],'test')
            self.assertEqual(json.loads((folder/'provenance.json').read_text())['source'],'retained')
            before={p.name:p.read_bytes() for p in folder.iterdir()}
            self.assertIsNone(packing.compact_package(folder,'test'))
            self.assertEqual(before,{p.name:p.read_bytes() for p in folder.iterdir()})
            (folder/'actors.png').rename(folder/'retained.png')
            (folder/'actors.png').symlink_to(folder/'retained.png')
            with self.assertRaisesRegex(ValueError,'symlink'):
                packing.compact_package(folder,'test')
            with patch.object(packing,'ROOT',folder):
                with self.assertRaisesRegex(ValueError,'accepted staging'):
                    packing.compact_package(folder/'kit/work/accepted','test')


if __name__=='__main__':unittest.main()
