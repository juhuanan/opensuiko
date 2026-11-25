#!/usr/bin/env python3
"""Master–Pupil candidate bindings and source pixels, independently checked."""
import hashlib
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
from export_first_room import source
from test_export_unite_review import vram_pose


class MasterPupilReview(unittest.TestCase):
    def test_hero_packet_and_inclusive_footprints_are_distinct(self):
        raw, _ = source('/SHU.BIN')
        section = struct.unpack_from('<I', raw, 36)[0]
        for pose, packet_size, inclusive_size in ((1, (32, 55), (32, 56)), (7, (47, 64), (48, 64)), (8, (47, 64), (48, 64))):
            packet, _, _ = vram_pose(raw, section, pose, packet=True)
            inclusive, _, _ = vram_pose(raw, section, pose)
            self.assertEqual(packet.size, packet_size)
            self.assertEqual(inclusive.size, inclusive_size)

    def test_candidate_and_retained_fixtures_match_source(self):
        with tempfile.TemporaryDirectory(prefix='master-review-') as temporary:
            root = Path(temporary)
            proof = export_unite_review.export(root, include_master=True)
            scenario = next(row for row in proof['scenarios'] if row['record'] == 31)
            self.assertEqual(scenario['members'], ['hero', 'kai'])
            self.assertEqual(len(proof['scenarios']), 26)
            directory = root / scenario['directory']
            for produced, fixture in (('trial.json', 'master_pupil_battle.json'), ('unites.json', 'master_pupil_actor_library.json')):
                self.assertEqual(json.loads((directory / produced).read_text()), json.loads((ROOT / 'game/tests/fixtures' / fixture).read_text()))
            trial = json.loads((directory / 'trial.json').read_text())
            checked = 0
            with Image.open(directory / 'actors.png') as atlas:
                for identifier in scenario['members']:
                    origin = next(row['source'] for row in proof['members'] if row['id'] == identifier)
                    raw = disc.extract(origin['lba'], origin['size'])
                    section = struct.unpack_from('<I', raw, 36)[0]
                    graphic = next(row for row in trial['unite_graphics'] if row['id'] == identifier)
                    for pose in graphic['poses']:
                        for key, white in (('sprite', False), ('white', True)):
                            expected, ax, ay = vram_pose(raw, section, pose['id'], white=white, packet=True)
                            sprite = pose[key]
                            rect = sprite['rect']
                            actual = atlas.crop((rect['x'], rect['y'], rect['x'] + rect['w'], rect['y'] + rect['h']))
                            self.assertEqual(actual.tobytes(), expected.tobytes())
                            self.assertEqual((sprite['anchor_x'], sprite['anchor_y']), (ax, ay))
                        checked += 1
            self.assertEqual(checked, 21)
            for name, digest in scenario['files'].items():
                self.assertEqual(hashlib.sha256((directory / name).read_bytes()).hexdigest(), digest)


if __name__ == '__main__':
    unittest.main()
