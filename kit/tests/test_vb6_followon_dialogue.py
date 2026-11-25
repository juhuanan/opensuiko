"""Static VB6 follow-on dialogue source and independent portrait checks."""
from pathlib import Path
import hashlib
import json
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import disc
import face_portraits
import export_vb6_followon_dialogue as exporter
from export_first_room import source


class FollowonDialogue(unittest.TestCase):
    def test_candidate_reproducible_and_original_unchanged(self):
        for path, value in exporter.export().items():
            self.assertEqual(json.loads(path.read_text()), value)
        old = json.loads((ROOT/'game/assets/field_dialogue.json').read_text())
        candidate = json.loads((ROOT/'game/assets/field_dialogue_vb6_e7.json').read_text())
        for key in ('anchors', 'texts', 'prefixes', 'images'):
            self.assertEqual(candidate[key][:len(old[key])], old[key])
        self.assertEqual(candidate['anchors'][-1]['actor'], 'vb6_r06_e07_char_014')
        self.assertEqual(candidate['prefixes'][-1]['command'], 6)

    def test_portrait_agrees_with_separate_face_source(self):
        proof = json.loads((ROOT/'kit/data/reports/vb6_followon_dialogue.json').read_text())
        candidate = json.loads((ROOT/'game/assets/field_dialogue_vb6_e7.json').read_text())
        row = face_portraits.face_records()[12]
        self.assertTrue(row['path'].endswith('FACE_13.BIN'))
        page = face_portraits.decode_page(disc.extract(row['lba'], row['size']))
        self.assertEqual(hashlib.sha256(face_portraits.page_cells(page)[0]).hexdigest(), candidate['images'][-1]['plane_sha256'])
        self.assertEqual(proof['name_lookup']['rank'], 48)
        raw, _ = source('/VB6.BIN')
        self.assertEqual(raw[0x35175:0x3517a], bytes.fromhex('0b 00 12 00 0e'))


if __name__ == '__main__':
    unittest.main()
