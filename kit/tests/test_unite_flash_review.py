#!/usr/bin/env python3
"""Flash's source-derived candidate bundle and review package stay reproducible."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import struct
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import export_spell_scenes
import assemble_battle_review
import character_table
import export_first_room
import export_unite_review
import preparation
import unite_scene_flash
import disc
from test_export_unite_review import vram_pose


class FlashReview(unittest.TestCase):
    def test_member_attack_frames_match_independent_source_sampler(self):
        expected = {'liukan': (18, 62, 128), 'fukien': (36, 83, 251), 'kai': (28, 80, 150)}
        records = {preparation.stable_id(row['name']): row for row in character_table.records()}
        for identifier, (count, impact, duration) in expected.items():
            with self.subTest(identifier=identifier):
                atlas = export_first_room.Atlas()
                frames, motion, origin = assemble_battle_review.flash_attack(identifier, atlas)
                self.assertEqual((len(frames), motion['impact_tick'], motion['duration']), (count, impact, duration))
                raw = disc.extract(origin['lba'], origin['size'])
                section = struct.unpack_from('<I', raw, 36)[0]
                self.assertEqual(origin['file'].split('/')[-1], records[identifier]['sprite_file'])
                for frame in frames:
                    image, ax, ay = vram_pose(raw, section, frame['source_pose'])
                    pose = frame['pose']
                    rect = pose['rect']
                    actual = atlas.image.crop((rect['x'], rect['y'], rect['x'] + rect['w'], rect['y'] + rect['h']))
                    self.assertEqual(actual.tobytes(), image.tobytes())
                    self.assertEqual((pose['anchor_x'], pose['anchor_y']), (ax, ay))

    def test_source_review_bundle_and_retained_fixtures(self):
        with tempfile.TemporaryDirectory(prefix='flash-review-') as temporary:
            root = Path(temporary)
            proof = export_unite_review.export(root, include_flash=True)
            self.assertEqual(len(proof['scenarios']), 26)
            scenario = next(row for row in proof['scenarios'] if row['record'] == 10)
            self.assertEqual(scenario['members'], ['liukan', 'fukien', 'kai'])
            directory = root / scenario['directory']
            for produced, fixture in (('trial.json', 'flash_battle.json'), ('unites.json', 'flash_actor_library.json')):
                self.assertEqual(json.loads((directory / produced).read_text()),
                                 json.loads((ROOT / 'game/tests/fixtures' / fixture).read_text()))
            trial = json.loads((directory / 'trial.json').read_text())
            with Image.open(directory / 'actors.png') as atlas:
                for graphic in trial['unite_graphics']:
                    for pose in graphic['poses']:
                        for sprite in [pose['sprite'], *pose.get('trail', []), *([pose['white']] if pose.get('white') else [])]:
                            rect = sprite['rect']
                            self.assertGreaterEqual(min(rect['x'], rect['y']), 0)
                            self.assertLessEqual(rect['x'] + rect['w'], atlas.width)
                            self.assertLessEqual(rect['y'] + rect['h'], atlas.height)
                for identifier in scenario['members']:
                    origin = next(member['source'] for member in proof['members'] if member['id'] == identifier)
                    raw = disc.extract(origin['lba'], origin['size'])
                    section = struct.unpack_from('<I', raw, 36)[0]
                    graphic = next(value for value in trial['unite_graphics'] if value['id'] == identifier)
                    for pose in graphic['poses']:
                        expected, ax, ay = vram_pose(raw, section, pose['id'], packet=identifier == 'kai')
                        sprite = pose['sprite']
                        rect = sprite['rect']
                        actual = atlas.crop((rect['x'], rect['y'], rect['x'] + rect['w'], rect['y'] + rect['h']))
                        self.assertEqual(actual.tobytes(), expected.tobytes())
                        self.assertEqual((sprite['anchor_x'], sprite['anchor_y']), (ax, ay))
            spells = json.loads((directory / 'spells.json').read_text())
            self.assertEqual(spells['schema'], 'suikoden-spell-scenes/47')
            with Image.open(directory / 'spell_effects.png') as atlas:
                for entry in spells['entries']:
                    self.assertGreaterEqual(min(entry['x'], entry['y']), 0)
                    self.assertLessEqual(entry['x'] + entry['w'], atlas.width)
                    self.assertLessEqual(entry['y'] + entry['h'], atlas.height)
            scene = next(value for value in spells['unite_scenes'] if value['id'] == 'flash')
            standalone = dict(spells=[], unite_scenes=[dict(id='flash', name='Flash Attack',
                              program=unite_scene_flash.program(), blocker=None)])
            self.assertEqual(scene, export_spell_scenes.compact_tracks(standalone)['unite_scenes'][0])
            for name, digest in scenario['files'].items():
                self.assertEqual(hashlib.sha256((directory / name).read_bytes()).hexdigest(), digest)


if __name__ == '__main__':
    unittest.main()
