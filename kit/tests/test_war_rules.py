#!/usr/bin/env python3
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
import export_war_rules as rules
import war_text


class WarRuleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.exported = rules.build()
        cls.packet = cls.exported["packet"]

    def test_selector_inventory_and_source_initialization(self):
        self.assertEqual(war_text.SELECTOR_ORDER, [
            "WAR_KUWA.BIN", "WAR_GARA.BIN", "WAR_SCA1.BIN", "WAR_SCA2.BIN",
            "WAR_TEO1.BIN", "WAR_TEO2.BIN", "WAR_KITA.BIN", "WAR_SHAS.BIN", "WAR_LAST.BIN",
        ])
        self.assertNotIn("WAR1.BIN", war_text.SELECTOR_ORDER)
        self.assertEqual([row["initial"]["scenario_parameter"] for row in self.packet["scenarios"]],
                         [9000, 6000, 12000, 12000, 14000, 14000, 3700, 17000, 20000])
        self.assertEqual([[side["total_records"] for side in row["initial"]["sides"]]
                          for row in self.packet["scenarios"]],
                         [[63, 31], [63, 21], [0, 0], [47, 31], [0, 0], [0, 0], [42, 9], [38, 35], [32, 34]])
        for name in war_text.SELECTOR_ORDER:
            raw = war_text.load(name)
            self.assertEqual(struct.unpack_from("<I", raw, 0x53C)[0], 0x27BDFFD0)
            self.assertEqual(struct.unpack_from("<I", raw, 0x990)[0], 0x27BDFFD8)

    def test_record_loss_divisors_match_both_sides_in_each_overlay(self):
        sites = (0x839C, 0x839C, 0x83B0, 0x839C, 0x83B0, 0x8498, 0x839C, 0x839C, 0x839C)
        costs = (300, 300, 400, 400, 450, 450, 450, 500, 600)
        self.assertEqual(self.packet["troops_per_record"], list(costs))
        for name, offset, cost in zip(war_text.SELECTOR_ORDER, sites, costs, strict=True):
            with self.subTest(overlay=name):
                raw = war_text.load(name)
                encoded = struct.pack("<I", 0x34020000 | cost)
                self.assertEqual(raw[offset + 8:offset + 12], encoded)
                self.assertEqual(raw[offset + 0x5c:offset + 0x60], encoded)

    def test_scripted_phase_tables_and_timings(self):
        entries = {2: 0x80025808, 4: 0x80025878, 5: 0x80025A58}
        expected_ticks = [(0, 1, 2), (2, 128, 3), (3, 248, 4), (4, 41, 5), (5, 198, 6),
                          (6, 128, 7), (7, 1, 8), (8, 62, 13), (10, 81, 13), (11, 61, 7)]
        for selector, scenario in enumerate(self.packet["scenarios"]):
            lifecycle = scenario["lifecycle"]
            raw = war_text.load(war_text.SELECTOR_ORDER[selector])
            call = struct.unpack_from("<I", raw, 0x4A8)[0]
            self.assertEqual(lifecycle["phase_entry"], 0x80000000 | ((call & 0x03FFFFFF) << 2))
            self.assertEqual(lifecycle["phase_table"], list(struct.unpack_from("<17I", raw, 0x2FC)))
            if selector not in entries:
                self.assertEqual(lifecycle["kind"], "unit_battle")
                self.assertEqual(lifecycle["confirmation_count"], 4)
                self.assertEqual([(row["phase"], row["ticks"], row["next"])
                                  for row in lifecycle["transitions"][:-1]], expected_ticks)
                continue
            self.assertEqual(lifecycle["phase_entry"], entries[selector])
            self.assertEqual(lifecycle["kind"], "scripted")
            self.assertEqual([(row["phase"], row["ticks"], row["next"])
                              for row in lifecycle["transitions"][:-1]], expected_ticks)
            self.assertEqual(lifecycle["transitions"][-1],
                             {"phase": 14, "ticks": 1, "next": 14, "terminal": True})
            self.assertEqual(lifecycle["wait_phase"], 9)
            self.assertEqual(lifecycle["second_confirmation_phase"], 14)

    def test_independent_combatant_bytes_and_packet_identity(self):
        raw = war_text.load("WAR_GARA.BIN")
        for index in (0, 1, 35, 107):
            offset = 0x16F18 + index * 6
            expected = dict(zip(("troops", "flags", "unit_class", "attack_class", "variant"),
                                (struct.unpack_from("<H", raw, offset + 4)[0], *raw[offset:offset + 4])))
            actual = self.packet["leader_contract"]["leaders"][index]
            self.assertEqual({key: actual[key] for key in expected}, expected)
        identified = dict(self.packet, content_sha256="")
        canonical = (json.dumps(identified, sort_keys=True, separators=(",", ":")) + "\n").encode()
        self.assertEqual(hashlib.sha256(canonical).hexdigest(), self.packet["content_sha256"])
        malformed = copy.deepcopy(self.packet)
        malformed["scenarios"][0]["initial"]["sides"][0]["remaining_records"] += 1
        with self.assertRaises(rules.RuleError):
            rules.validate(malformed)

    def test_enemy_special_and_shifted_combatant_contracts(self):
        self.assertEqual(self.packet["ordinary_contract"]["action_map"], [2, 0, 1, 1, 2, 0, 0, 1, 2])
        self.assertEqual(self.packet["special_contract"]["teams"],
                         {"24": "thieves", "32": "strategists", "33": "ninja", "34": "dragon_knights", "35": "merchants"})
        for scenario in self.packet["scenarios"]:
            if scenario["lifecycle"]["kind"] == "scripted":
                self.assertIsNone(scenario["enemy_policy"])
                continue
            policy = scenario["enemy_policy"]
            self.assertEqual(policy["action_map"], [2, 0, 1, 1, 2, 0, 0, 1, 2])
            self.assertEqual(len(policy["ranges"]), 5)
            for start, end in policy["ranges"]:
                self.assertLessEqual(start, end)
                self.assertLess(end, len(scenario["attacks"]))
        last = self.packet["scenarios"][8]
        self.assertEqual(last["leaders"][0]["record_offset"], 0x16F14)
        self.assertEqual(last["leaders"][0]["member_ids"], [0, 2, 1])
        self.assertEqual(last["leaders"][0]["flags"], 0)
        self.assertEqual(last["leaders"][0]["unit_class"], 14)

    def test_repeat_generation_and_read_only_check(self):
        first = rules.output_bytes(self.exported)
        second = rules.output_bytes(rules.build())
        self.assertEqual(first, second)
        for relative, data in first.items():
            self.assertEqual((ROOT / relative).read_bytes(), data, relative)
        with tempfile.TemporaryDirectory(prefix="war-rules-") as temporary:
            root = Path(temporary)
            for relative, data in first.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            self.assertEqual(rules.main(["--check", "--output-root", str(root)]), 0)
            stale = root / "game/assets/war/scenarios.json"
            original = stale.read_bytes()
            stale.write_bytes(original + b" ")
            self.assertEqual(rules.main(["--check", "--output-root", str(root)]), 1)
            self.assertEqual(stale.read_bytes(), original + b" ")
            stale.unlink()
            self.assertEqual(rules.main(["--check", "--output-root", str(root)]), 1)


if __name__ == "__main__":
    unittest.main()
