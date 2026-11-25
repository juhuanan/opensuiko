"""Trick isolated package reproducibility and independent member/wave pixels."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from PIL import Image
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import export_unite_programs
import export_unite_review
import export_battle_sfx
import unite_trick_controller
from test_export_unite_review import vram_pose


class TrickReview(unittest.TestCase):
    def test_binding_preserves_other_unites_and_registers_callback_sounds(self):
        with tempfile.TemporaryDirectory(prefix='trick-actors-') as temporary:
            _,proof=export_unite_programs.export(temporary,include_flash=True,include_master=True,include_couple=True,include_warriors=True,include_martial=True,include_beat=True,include_trick=True)
            actual=json.loads((Path(temporary)/'unites.json').read_text())
        self.assertEqual(actual,json.loads((ROOT/'game/tests/fixtures/trick_actor_library.json').read_text()))
        previous=json.loads((ROOT/'game/tests/fixtures/beat_actor_library.json').read_text())
        self.assertEqual(actual['unites'][:14]+actual['unites'][15:],previous['unites'][:14]+previous['unites'][15:])
        binding=actual['unites'][14]
        self.assertEqual(binding['wave_heights'],unite_trick_controller.build()['phases'][1]['heights'])
        self.assertEqual(binding['return_program'],'common/unite_return')
        self.assertEqual(binding['dispatch_after'],1)
        self.assertEqual(actual['schema'],'suikoden-unite-actors/29')
        self.assertEqual(sum('dispatch_after' in u for u in actual['unites']),32)
        cues=export_battle_sfx.cues(actual)
        self.assertTrue({0x513,0x81B}<=set(cues))
        binding['wave_heights'][0]=1
        with self.assertRaisesRegex(ValueError,'Trick wave sound binding differs'):export_battle_sfx.cues(actual)

    def test_review_package_and_all_member_wave_crops_match_independent_vram(self):
        with tempfile.TemporaryDirectory(prefix='trick-review-') as temporary:
            root=Path(temporary)
            proof=export_unite_review.export(root,include_flash=True,include_master=True,include_couple=True,include_warriors=True,include_martial=True,include_beat=True,include_trick=True,scenario_records={14})
            content=json.loads((root/'record_14/trial.json').read_text())
            actors=json.loads((root/'record_14/unites.json').read_text())
            self.assertEqual(content,json.loads((ROOT/'game/tests/fixtures/trick_battle.json').read_text()))
            self.assertEqual(actors,json.loads((ROOT/'game/tests/fixtures/trick_actor_library.json').read_text()))
            self.assertEqual([s['record'] for s in proof['scenarios']],[14])
            self.assertEqual(content['initial_party'][:2],['meg','juppo'])
            keys=[(g['id'],g.get('record')) for g in content['unite_graphics']]
            self.assertEqual(len(keys),len(set(keys)))
            with Image.open(root/'record_14/actors.png') as atlas:
                for identifier,filename in (('meg','/MEG.BIN'),('juppo','/JUP.BIN')):
                    raw,_=export_unite_review.field.source(filename)
                    section=struct.unpack_from('<I',raw,36)[0]
                    resource=next(r for r in actors['animations']['resources'] if r['id']==identifier)
                    graphic=next(g for g in content['unite_graphics'] if g['id']==identifier and g.get('record') is None)
                    for pose in {f['pose'] for c in resource['clips'] for f in c['frames']}:
                        sprite=next(p for p in graphic['poses'] if p['id']==pose)['sprite'];r=sprite['rect']
                        expected,ax,ay=vram_pose(raw,section,pose)
                        actual=atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
                        self.assertEqual((actual.size,actual.tobytes(),sprite['anchor_x'],sprite['anchor_y']),(expected.size,expected.tobytes(),ax,ay))


if __name__=='__main__':unittest.main()
