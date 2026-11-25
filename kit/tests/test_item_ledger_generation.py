#!/usr/bin/env python3
"""Item identity generation, stable enum order and explicit admission boundaries."""
import copy
import json
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import generate_item_ledger as generator


class ItemGenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.admission_bytes = (ROOT / generator.ADMISSION).read_bytes()
        cls.admission = json.loads(cls.admission_bytes)
        cls.items_source = (ROOT / generator.ITEMS).read_text()
        cls.catalogue_source = (ROOT / generator.CATALOGUE).read_text()

    def outputs(self, admission=None):
        raw = self.admission_bytes if admission is None else generator.json_bytes(admission)
        return generator.build_outputs(raw, self.items_source, self.catalogue_source)

    def test_disc_identities_match_reviewed_fingerprint_and_native_outputs(self):
        first = self.outputs()
        self.assertEqual(first, self.outputs())
        for path, data in first.items():
            self.assertEqual((ROOT / path).read_bytes(), data, path)
        packet = json.loads(first[generator.LEDGER])
        self.assertEqual(len(packet['items']), 179)
        self.assertEqual(generator.metadata_digest(packet['items']), self.admission['identity_metadata_sha256'])
        self.assertEqual(generator.identity_digest(packet), packet['source']['identity_digest'])
        self.assertEqual(packet['bindings']['items_enum_bound'], len(self.admission['runtime_source_ids']))
        self.assertIn(f"{packet['bindings']['unbound']} reviewed source identities", packet['blockers'][0]['detail'])

    def test_new_admission_updates_all_outputs_without_reordering_or_merging_labels(self):
        packet = json.loads((ROOT / generator.LEDGER).read_bytes())
        # These two distinct source records share one label; admission is by ID.
        source_ids = next(group['source_item_ids'] for group in packet['identities']['duplicate_label_groups'])
        baseline_admission = copy.deepcopy(self.admission)
        baseline_admission['runtime_source_ids'] = [sid for sid in baseline_admission['runtime_source_ids'] if sid not in source_ids]
        _, derived_items = generator.derive_items(baseline_admission)
        baseline_enum = generator.enum_source([derived_items[i - 1] for i in baseline_admission['runtime_source_ids']])
        start = self.items_source.index(generator.BEGIN)
        end = self.items_source.index(generator.END, start) + len(generator.END)
        baseline_items_source = self.items_source[:start] + baseline_enum + self.items_source[end:]
        admission = copy.deepcopy(baseline_admission)
        admission['runtime_source_ids'].append(source_ids[0])
        outputs = generator.build_outputs(generator.json_bytes(admission), baseline_items_source, self.catalogue_source)
        updated = json.loads(outputs[generator.LEDGER])
        current_tags = generator.enum_tags(baseline_items_source)
        new_tags = generator.enum_tags(outputs[generator.ITEMS].decode())
        self.assertEqual(new_tags[:-1], current_tags)
        item = updated['items'][source_ids[0] - 1]
        self.assertEqual(item['controller'], {'kind': 'items_enum', 'tag': new_tags[-1]})
        self.assertNotEqual(item['id'], updated['items'][source_ids[1] - 1]['id'])
        self.assertEqual(updated['items'][source_ids[1] - 1]['controller']['kind'], 'unbound')
        self.assertEqual(updated['bindings']['items_enum_bound'], len(current_tags) + 1)
        self.assertEqual(generator.metadata_digest(updated['items']), self.admission['identity_metadata_sha256'])
        pin = re.search(r'pub const expected_asset_sha256 = "([a-f0-9]+)";', outputs[generator.CATALOGUE].decode()).group(1)
        self.assertEqual(pin, generator.sha256(outputs[generator.LEDGER]))
        report = json.loads(outputs[generator.REPORT])
        self.assertEqual(report['bound'], len(new_tags))
        self.assertEqual(report['enum_order'], new_tags)
        menu = json.loads(outputs[generator.MENU])
        self.assertEqual(menu['capacities']['admitted_items'], len(new_tags))
        self.assertEqual(menu['items'][-1]['id'], new_tags[-1])
        self.assertEqual(menu['items'][-1]['source_records'], [source_ids[0]])
        self.assertEqual(menu['source']['items_source']['sha256'], generator.sha256(outputs[generator.ITEMS]))
        self.assertIn(f'pub const admitted_items: u16 = {len(new_tags)};', outputs[generator.VOCABULARY].decode())
        chapter = json.loads(outputs[generator.PROGRESSION])
        self.assertEqual(chapter['item_source']['sha256'], pin)
        chapter_pin = re.search(r'pub const item_progression = struct \{.*?asset_sha256 = "([a-f0-9]+)"',
                                outputs[generator.MIDDLE_ASSETS].decode(), re.S).group(1)
        self.assertEqual(chapter_pin, generator.sha256(outputs[generator.PROGRESSION]))
        for path, digest in report['output_sha256'].items():
            self.assertEqual(digest, generator.sha256(outputs[path]))

    def test_invalid_admission_and_changed_reviewed_knowledge_fail_before_writes(self):
        for ids in (self.admission['runtime_source_ids'][1:],
                    list(reversed(self.admission['runtime_source_ids'])),
                    self.admission['runtime_source_ids'] + [0],
                    self.admission['runtime_source_ids'] + [180],
                    self.admission['runtime_source_ids'] + self.admission['runtime_source_ids'][:1]):
            admission = copy.deepcopy(self.admission)
            admission['runtime_source_ids'] = ids
            with self.assertRaises(ValueError):
                self.outputs(admission)
        admission = copy.deepcopy(self.admission)
        admission['weapon_fragments'][0]['source_item_id'] = 62
        with self.assertRaisesRegex(ValueError, 'reviewed metadata fingerprint'):
            self.outputs(admission)


if __name__ == '__main__':
    unittest.main(verbosity=2)
