"""Exercise the replay reporter with changed and malformed checkpoint data."""

from contextlib import redirect_stderr
from copy import deepcopy
from io import StringIO
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from check_simulation_replay import DIAGNOSTIC_SCHEMA, TRACE_SCHEMA, compare, read_trace


def trace() -> dict:
    return {
        "schema": TRACE_SCHEMA,
        "id": "synthetic",
        "checkpoints": [
            {"id": "initial", "tick": 0},
            {"id": "arrived", "tick": 4, "party": [{"hp": 80}], "flags": {"door": False}},
        ],
    }


class ReplayReportTest(unittest.TestCase):
    def test_semantic_comparison_ignores_json_format(self):
        before = read_trace(json.dumps(trace(), sort_keys=True))
        after = read_trace(json.dumps(trace(), indent=2))
        self.assertTrue(compare(before, after, "synthetic"))

    def test_regressions_name_checkpoint_tick_and_values(self):
        before = trace()
        after = deepcopy(before)
        after["checkpoints"][1]["party"][0]["hp"] = 71
        after["checkpoints"][1]["flags"]["door"] = 0
        output = StringIO()
        with redirect_stderr(output):
            self.assertFalse(compare(before, after, "synthetic"))
        self.assertIn("arrived (tick 4)", output.getvalue())
        self.assertIn("/party/0/hp: expected 80, got 71", output.getvalue())
        self.assertIn("/flags/door: expected false, got 0", output.getvalue())

    def test_missing_checkpoint_and_duplicate_ids_fail(self):
        before = trace()
        after = deepcopy(before)
        after["checkpoints"].pop()
        output = StringIO()
        with redirect_stderr(output):
            self.assertFalse(compare(before, after, "synthetic"))
        self.assertIn("checkpoint missing", output.getvalue())
        before["checkpoints"].append({"id": "arrived", "tick": 5})
        with self.assertRaisesRegex(ValueError, "unique names"):
            read_trace(json.dumps(before))

    def test_diagnostic_trace_reports_first_divergent_tick(self):
        before = diagnostic_trace()
        after = deepcopy(before)
        after["checkpoints"][1]["battle_resolution"]["action"]["target"] = "second_enemy"
        after["checkpoints"][2]["hp"] = 12
        output = StringIO()
        with redirect_stderr(output):
            self.assertFalse(compare(before, after, "diagnostic"))
        self.assertIn("first divergence at tick 1", output.getvalue())
        self.assertIn('/battle_resolution/action/target: expected "first_enemy", got "second_enemy"', output.getvalue())
        self.assertNotIn("/hp", output.getvalue())

    def test_diagnostic_trace_requires_identical_inputs_and_contiguous_ticks(self):
        before = diagnostic_trace()
        after = deepcopy(before)
        after["inputs"]["seed"] += 1
        after["checkpoints"][2]["hp"] = 12
        output = StringIO()
        with redirect_stderr(output):
            self.assertFalse(compare(before, after, "diagnostic"))
        self.assertIn("/inputs/seed: expected 7, got 8", output.getvalue())
        self.assertNotIn("/hp", output.getvalue())
        after["checkpoints"].pop(1)
        with self.assertRaisesRegex(ValueError, "every tick"):
            read_trace(json.dumps(after))


def diagnostic_trace() -> dict:
    return read_trace(json.dumps({
        "schema": DIAGNOSTIC_SCHEMA,
        "id": "diagnostic",
        "inputs": {"seed": 7, "world_sha256": "a" * 64, "replay_sha256": "b" * 64},
        "checkpoints": [
            {"id": "initial", "tick": 0},
            {"id": "tick_1", "tick": 1, "battle_resolution": {"action": {"target": "first_enemy"}}},
            {"id": "hit", "tick": 2, "hp": 15},
        ],
    }))


if __name__ == "__main__":
    unittest.main()
