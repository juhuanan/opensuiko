#!/usr/bin/env python3
"""Couple export against source packets and independent VRAM samples."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import disc
import export_unite_review
from test_export_unite_review import vram_pose


class CoupleReview(unittest.TestCase):
    def test_source_scenes_actor_palettes_and_fixture(self):
        with tempfile.TemporaryDirectory(prefix='couple-review-') as temporary:
            root = Path(temporary)
            proof = export_unite_review.export(root, include_flash=True, include_master=True,
                                                include_couple=True, scenario_records=(10, 16, 31))
            directory = root / 'record_16'
            self.assertEqual(next(row['members'] for row in proof['scenarios'] if row['record'] == 16), ['eileen', 'lepant'])
            for produced, fixture in (('trial.json', 'couple_battle.json'), ('unites.json', 'couple_actor_library.json')):
                self.assertEqual(json.loads((directory / produced).read_text()), json.loads((ROOT / 'game/tests/fixtures' / fixture).read_text()))
            content = json.loads((directory / 'trial.json').read_text())
            spells = json.loads((directory / 'spells.json').read_text())
            self.assertEqual([row['ticks'] for row in next(row for row in spells['unite_impacts'] if row['id'] == 6)['frames']], [6, 6, 8, 10])
            with Image.open(directory / 'actors.png') as atlas:
                for identifier in ('eileen', 'lepant'):
                    origin = next(row['source'] for row in proof['members'] if row['id'] == identifier)
                    raw = disc.extract(origin['lba'], origin['size'])
                    section = struct.unpack_from('<I', raw, 36)[0]
                    graphic = next(row for row in content['unite_graphics'] if row['id'] == identifier)
                    for pose in graphic['poses']:
                        variants = [(pose['sprite'], None)]
                        variants += list(zip(pose.get('flash', []), (1, 2, 3)))
                        if identifier == 'lepant':
                            self.assertEqual(len(variants), 4)
                        for sprite, palette_row in variants:
                            expected, ax, ay = vram_pose(raw, section, pose['id'], palette_row=palette_row)
                            rect = sprite['rect']
                            actual = atlas.crop((rect['x'], rect['y'], rect['x'] + rect['w'], rect['y'] + rect['h']))
                            self.assertEqual(actual.tobytes(), expected.tobytes(), (identifier, pose['id'], palette_row))
                            self.assertEqual((sprite['anchor_x'], sprite['anchor_y']), (ax, ay))


if __name__ == '__main__':
    unittest.main()
