"""Keep plan identities, states and dependencies valid without aggregate totals."""
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
import check_port_plan


class PlanChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="suikoden-plan-gate-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "game").mkdir()
        for name in ("ROADMAP.md", "IMPLEMENTATION.md"):
            shutil.copyfile(ROOT / "game" / name, self.root / "game" / name)

    def mutate(self, name, before, after):
        path = self.root / "game" / name
        text = path.read_text()
        self.assertIn(before, text)
        path.write_text(text.replace(before, after, 1))

    def test_current_rows_states_and_subset_graph_agree(self):
        self.assertGreater(check_port_plan.check(self.root), 0)

    def test_unknown_states_are_rejected(self):
        self.mutate("ROADMAP.md", "| 51 | Planned |", "| 51 | INVALID_STATE |")
        with self.assertRaisesRegex(ValueError, "invalid state"):
            check_port_plan.check(self.root)

    def test_duplicates_omissions_and_extra_ids_are_rejected(self):
        path = self.root / "game/ROADMAP.md"
        original = path.read_text()
        for changed in (original.replace("| 51 |", "| 52 |", 1),
                        "\n".join(line for line in original.splitlines() if not line.startswith("| 51 |")),
                        original + "\n| 101 | Planned | 51 | Invalid extra row |\n"):
            path.write_text(changed)
            with self.assertRaisesRegex(ValueError, "preserve IDs"):
                check_port_plan.check(self.root)

    def test_aggregate_state_counts_are_rejected(self):
        for name in ("ROADMAP.md", "IMPLEMENTATION.md"):
            path = self.root / "game" / name
            original = path.read_text()
            path.write_text(original + "\nOriginal1–50:1 Implemented,2 Active\n")
            with self.assertRaisesRegex(ValueError, "aggregate state count"):
                check_port_plan.check(self.root)
            path.write_text(original)

    def test_invalid_qualifier_and_dependency_cycle_are_rejected(self):
        path = self.root / "game/ROADMAP.md"
        original = path.read_text()
        path.write_text(original.replace("51[core]", "51[unknown]", 1))
        with self.assertRaisesRegex(ValueError, "range/qualifier"):
            check_port_plan.check(self.root)
        path.write_text(original.replace("| 51 | Planned | 11 |", "| 51 | Planned | 51 |", 1))
        with self.assertRaisesRegex(ValueError, "dependency cycle"):
            check_port_plan.check(self.root)


if __name__ == "__main__":
    unittest.main()
