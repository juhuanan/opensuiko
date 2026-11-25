#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "game/tests/fixtures/war_sessions.json"
RULES = ROOT / "game/assets/war/scenarios.json"


class WarSessionFixtureTests(unittest.TestCase):
    def test_fixture_identity_and_scenario_references(self):
        fixture = json.loads(FIXTURES.read_text())
        packet = json.loads(RULES.read_text())
        self.assertEqual(fixture["schema"], "suikoden-war-session-fixtures/1")
        self.assertEqual(fixture["packet_content_sha256"], packet["content_sha256"])
        identity = dict(fixture, content_sha256="")
        encoded = (json.dumps(identity, sort_keys=True, separators=(",", ":")) + "\n").encode()
        self.assertEqual(hashlib.sha256(encoded).hexdigest(), fixture["content_sha256"])
        for case in fixture["cases"]:
            selector = case["scenario_selector"]
            self.assertEqual(packet["scenarios"][selector]["selector"], selector)
            self.assertNotEqual(packet["scenarios"][selector]["initial"]["sides"][0]["total_records"], 0)

    def test_source_lcg_boundaries(self):
        fixture = json.loads(FIXTURES.read_text())
        expected = {
            1: ([16838, 5758, 10113, 17515, 31051, 5627, 23010, 7419], 2633739833),
            19: ([25016, 17901, 12377, 224, 2722, 31609, 17314, 14997], 982867595),
            0xFFFFFFFF: ([15929, 4409, 9862, 26718, 8713, 28226, 9080, 32063], 4248825847),
        }
        self.assertEqual(len(fixture["cases"]), 3)
        for case in fixture["cases"]:
            draws, final = expected[case["initial_rng_state"]]
            self.assertEqual(case["expected_draws"], draws)
            self.assertEqual(case["expected_final_rng_state"], final)
            state = case["initial_rng_state"]
            for draw in draws:
                state = (state * 1103515245 + 12345) & 0xFFFFFFFF
                self.assertEqual((state >> 16) & 0x7FFF, draw)
            self.assertEqual(state, final)


if __name__ == "__main__":
    unittest.main()
