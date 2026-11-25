"""Checkpoint coverage for the shared actor-owned constructor compiler."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
import enemy_area_magic_constructors as compiler


class ConstructorCheckpoint(unittest.TestCase):
    def test_batch_retains_metadata_only_scope_and_constructor_counts(self):
        report = compiler.build()
        self.assertEqual(report['admission'], 'constructor_metadata_only')
        expected = {'sorcerer': (33, 0, 20), 'siren': (16, 4, 0), 'earth_golem': (12, 0, 0)}
        for row in report['effects']:
            groups = [(row['sprites'], 'objects'), (row['columns'], 'columns'), (row['gradients'], 'objects')]
            self.assertEqual(tuple(len(group[key]) for group, key in groups), expected[row['id']])
            self.assertTrue(all(not group['blocked'] for group, _ in groups))
        siren = next(row for row in report['effects'] if row['id'] == 'siren')
        self.assertTrue(all(row['setter'] is None for row in siren['columns']['columns']))
        self.assertEqual(siren['columns']['columns'][0]['lower'],
                         dict(radius=180, height=-300, color=[100, 144, 0]))

    def test_shadow_column_constructor_with_proven_single_pass_guard(self):
        image = compiler.ActorImage('F', actor_index=2)
        facts = dict(initializer=0x80081f28, preparation=[],
                     state_root=compiler.analysis.member(compiler.SCENE, 0xa8 + 2 * 140))
        result = compiler.columns.constructors(facts, image)
        self.assertEqual(result['blocked'], [])
        self.assertEqual(len(result['columns']), 1)
        column = result['columns'][0]
        self.assertEqual((column['site'], column['slot'], column['segments'], column['blend']),
                         (0x80082054, 0, 32, 'additive'))
        self.assertEqual(column['lower'], dict(radius=120, height=-5, color=[0, 0, 0]))
        self.assertEqual(column['upper'], dict(radius=120, height=0, color=[128, 128, 128]))


if __name__ == '__main__':
    unittest.main()
