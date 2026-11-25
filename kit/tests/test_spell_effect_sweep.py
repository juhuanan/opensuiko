import json
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import spell_effect_sweep

class SpellEffectSweepTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = json.loads((spell_effect_sweep.OUT).read_text())

    def test_every_named_initializer_is_inventoried(self):
        names = [e['name'] for e in self.report['effects']]
        self.assertEqual(len(names), 33)
        self.assertEqual(len(set(names)), 33)
        self.assertIn('Flaming Arrows', names)
        self.assertIn('Drops of Kindness', names)
        self.assertIn('Judgment', names)

    def test_sections_are_derived_from_initializer_master_loads(self):
        by_name = {e['name']: e for e in self.report['effects']}
        self.assertEqual(by_name['Flaming Arrows']['section'], 1)
        self.assertEqual(by_name['Drops of Kindness']['section'], 3)
        self.assertEqual(by_name['Flaming Arrows']['phase_animations'], [0, 8, 7])
        self.assertEqual(by_name['Drops of Kindness']['phase_animations'], [0, 3])
        self.assertEqual({e['section'] for e in self.report['effects']}, set(range(1, 8)))

    def test_repeated_sections_share_effect_tables(self):
        by_section = {}
        for effect in self.report['effects']:
            key = (len(effect['pieces']), len(effect['animations']))
            by_section.setdefault(effect['section'], set()).add(key)
        for section, keys in by_section.items():
            self.assertEqual(len(keys), 1, section)

if __name__ == '__main__':
    unittest.main()
