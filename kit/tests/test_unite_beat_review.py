"""Regenerable Beat'em up package and independent VRAM body/trail checks."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from PIL import Image

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import export_unite_review as exporter
import unite_beat_controller
import journey_battle
from test_export_unite_review import vram_pose


class BeatReview(unittest.TestCase):
    def test_source_art_package_and_constructor_trail_pose(self):
        with tempfile.TemporaryDirectory(prefix='unite-beat-review-') as temporary:
            directory=Path(temporary)
            proof=exporter.export(directory,include_flash=True,include_master=True,include_couple=True,include_warriors=True,include_martial=True,include_beat=True,scenario_records={27})
            scenario=directory/'record_27'
            trial=json.loads((scenario/'trial.json').read_text())
            actors=json.loads((scenario/'unites.json').read_text())
            effects=json.loads((scenario/'spells.json').read_text())
            self.assertEqual(trial,json.loads((ROOT/'game/tests/fixtures/beat_battle.json').read_text()))
            self.assertEqual(actors,json.loads((ROOT/'game/tests/fixtures/beat_actor_library.json').read_text()))
            attachments=[dict(id=p['id'],offset=p['source_attachment']) for p in effects['hurt_poses']]
            self.assertEqual(attachments,json.loads((ROOT/'game/tests/fixtures/beat_attachments.json').read_text()))
            self.assertEqual([s['record'] for s in proof['scenarios']],[27])
            self.assertEqual(trial['initial_party'][:2],['pahn','ronnie'])
            with Image.open(scenario/'actors.png') as atlas:
                for identifier in ('pahn','ronnie'):
                    source=next(r for r in proof['members'] if r['id']==identifier)
                    raw,_=exporter.field.source('/'+source['source']['file'].split('/')[-1])
                    section=struct.unpack_from('<I',raw,36)[0]
                    graphic=next(g for g in trial['unite_graphics'] if g['id']==identifier)
                    resource=next(r for r in actors['animations']['resources'] if r['id']==identifier)
                    for pose_id in {f['pose'] for c in resource['clips'] for f in c['frames']}:
                        exported=next(p for p in graphic['poses'] if p['id']==pose_id)['sprite']
                        expected,ax,ay=vram_pose(raw,section,pose_id)
                        rect=exported['rect']
                        actual=atlas.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h']))
                        self.assertEqual((actual.size,actual.tobytes()),(expected.size,expected.tobytes()))
                        self.assertEqual((exported['anchor_x'],exported['anchor_y']),(ax,ay))
                    if identifier=='ronnie':
                        animation=next(c for c in resource['clips'] if c['id']==18)
                        frozen=animation['frames'][0]['pose']
                        stream=unite_beat_controller.build()['child']['script']['operations']
                        raw_animations,_,_=exporter.battle_unite_camera.animation_frames(raw)
                        bindings=journey_battle.trail_bindings(raw_animations,[(o['op'],tuple(o['args'])) for o in stream],initial_animation=18)
                        self.assertEqual(bindings,[dict(start=2,animation=18,pose=frozen,stop=90)])
                        selected=next(p for p in graphic['poses'] if p['id']==frozen)
                        self.assertEqual(len(selected['trail']),8)
                        expected,ax,ay=vram_pose(raw,section,frozen)
                        factors=exporter.battle_unite_camera.blacksmith_trail(exporter.battle_unite_camera.Image())['full_ring_rgb_newest_first']
                        for sprite,weights in zip(selected['trail'],factors,strict=True):
                            image=expected.copy()
                            image.putdata([tuple(((min(31,(v>>3)*weight//128)<<3)|(min(31,(v>>3)*weight//128)>>2)) for v,weight in zip(pixel[:3],weights,strict=True))+(pixel[3],) for pixel in [expected.getpixel((x,y)) for y in range(expected.height) for x in range(expected.width)]])
                            r=sprite['rect'];actual=atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
                            self.assertEqual((actual.size,actual.tobytes()),(image.size,image.tobytes()))
                            self.assertEqual((sprite['anchor_x'],sprite['anchor_y']),(ax,ay))


if __name__=='__main__':unittest.main()
