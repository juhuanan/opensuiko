#!/usr/bin/env python3
"""Focused source/consumer checks for pure field actor binding resolution."""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
sys.path.insert(0, str(ROOT / "kit/tests"))

import area_scene as scene
import export_field_actor_bindings as binder
from export_first_room import source
import maindec
from test_canonical_start import assert_main_words
from test_entity_predicates import check_dispatch, check_helpers
from test_field_party_queue import check_source_paths


def temporary_characters(party, count):
    # The constructor loops over count minus one descriptors and starts after Hero.
    first = (maindec.mword(0x8013A884) & 0xFFFF) - 0x89
    return party[first:first + count - 1]


class FieldActorBindings(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.exported = binder.build()
        cls.packet = cls.exported["packet"]
        cls.fixtures = cls.exported["fixtures"]
        cls.input_paths = [ROOT / name for name in binder.FROZEN]
        cls.input_paths += [ROOT / "kit/tools" / name for name in binder.HELPERS]
        cls.input_paths += [ROOT / "kit/tools/compile_event_programs.py",
                            ROOT / "kit/tests/test_event_program_compiler.py",
                            ROOT / "kit/data/reports/event_program_compiler.json",
                            ROOT / "kit/data/registry/extract_event_program_compiler.jsonl",
                            ROOT / "kit/data/reports/event_program_compiler_handoff.md"]
        cls.before_hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in cls.input_paths}

    def tearDown(self):
        current = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in self.input_paths}
        self.assertEqual(current, self.before_hashes, "read-only/frozen input changed")

    def resolve(self, scene_id, program, selector, state):
        return binder.resolve(self.packet, scene_id, program, selector, state)

    def test_complete_inventory_and_source_locations(self):
        rows = self.packet["selector_occurrences"]
        self.assertEqual(len(rows), 61)
        self.assertEqual(sum(row["scene_id"] == "vaa_room2" for row in rows), 51)
        self.assertEqual(sum(row["scene_id"] == "vb6_room6" for row in rows), 10)
        self.assertEqual(sum(row["diagnostic_only"] for row in rows), 8)
        self.assertEqual(sum(not row["diagnostic_only"] for row in rows), 53)
        self.assertTrue(all(row["coverage"] == "resolved_rule" for row in rows))
        by_program = {}
        for row in rows:
            by_program.setdefault(row["program_id"], []).append(row)
        expected_counts = {
            "vaa_room2_audience": 44, "vaa_room2_init_23": 0,
            "vaa_room2_init_24": 7, "vb6_r06_first_arrival": 2,
            "vb6_r06_entity07_followon": 4, "vb6_r06_entity09_followon": 4,
        }
        self.assertEqual({key: len(by_program.get(key, [])) for key in expected_counts}, expected_counts)
        selected = {(row["source_offset"], row["selector"]) for row in rows}
        self.assertIn((0x50D83, 0x80), selected)
        self.assertIn((0x50EB7, 0x40), selected)
        self.assertIn((0x3513E, 0x40), selected)
        self.assertIn((0x35164, 0), selected)
        self.assertIn((0x351AE, 0), selected)
        self.assertIn((0x351D2, 0), selected)
        self.assertNotIn((0x35184, 0x1B), selected, "room transition is not actor binding")
        self.assertFalse(any(row["opcode"] in (0x0B, 0x17) for row in rows),
                         "dialogue layout operand is not an actor selector")
        data, _ = source("/VB6.BIN")
        self.assertEqual(data[0x351AE:0x351B3], bytes.fromhex("32 00 03 19 05"))
        self.assertEqual(data[0x351D2:0x351D4], bytes.fromhex("3A 00"))

    def test_vaa_compaction_and_independent_classifier(self):
        state = {"story": {"scenario_0000": 0},
                 "scene": {"phase": "active", "released_selectors": [],
                           "construction_story": {"scenario_0000": 0}}}
        result = self.resolve("vaa_room2", "vaa_room2_audience", 12, state)
        self.assertEqual((result["status"], result["actor_id"], result["source_entity_id"]),
                         ("resolved", "scene_actor_12", "vaa_room2_entity_22"))
        shifted = self.resolve("vaa_room2", "vaa_room2_audience", 5, state)
        self.assertEqual((shifted["actor_id"], shifted["source_entity_id"]),
                         ("scene_actor_5", "vaa_room2_entity_08"))
        old_slot = self.resolve("vaa_room2", "vaa_room2_audience", 11, state)
        self.assertEqual(old_slot["source_entity_id"], "vaa_room2_entity_16")
        retained = self.resolve("vaa_room2", "vaa_room2_audience", 12,
                                state | {"story": {"scenario_0000": 0x40}})
        self.assertEqual((retained["status"], retained["source_entity_id"], retained["compact_index"]),
                         ("resolved", "vaa_room2_entity_22", 12))
        following = self.resolve("vaa_room2", "vaa_room2_audience", 13,
                                 state | {"story": {"scenario_0000": 0x40}})
        self.assertEqual(following["source_entity_id"], "vaa_room2_entity_25")

        constructed_inactive = state | {"scene": {"phase": "active", "released_selectors": [],
                                                  "construction_story": {"scenario_0000": 0x40}}}
        still_absent = self.resolve("vaa_room2", "vaa_room2_audience", 12, constructed_inactive)
        self.assertEqual((still_absent["status"], still_absent["reason"]),
                         ("missing", "classification_rejected_inactive_slot"))
        reconstructed_inactive = constructed_inactive | {
            "story": {"scenario_0000": 0x40},
            "scene": {"phase": "recreated", "released_selectors": [],
                      "construction_story": {"scenario_0000": 0x40}}}
        self.assertEqual(self.resolve("vaa_room2", "vaa_room2_audience", 12,
                                      reconstructed_inactive)["status"], "missing")
        reconstructed_active = reconstructed_inactive | {
            "story": {"scenario_0000": 0},
            "scene": {"phase": "recreated", "released_selectors": [],
                      "construction_story": {"scenario_0000": 0}}}
        self.assertEqual(self.resolve("vaa_room2", "vaa_room2_audience", 12,
                                      reconstructed_active)["status"], "resolved")

        data, _ = source("/VAA.BIN")
        entries = scene.entities(data, scene.room_record(data, 2))
        predicate = entries[16]["stream_offsets"][0]
        self.assertEqual(data[predicate:predicate + 4], bytes.fromhex("08 00 20 06"))
        audience_predicate = entries[22]["stream_offsets"][0]
        self.assertEqual(data[audience_predicate:audience_predicate + 4], bytes.fromhex("08 00 40 06"))
        check_dispatch()
        check_helpers()
        opcode, index, mask, end = data[predicate:predicate + 4]
        self.assertEqual((opcode, index, end), (8, 0, 6))
        self.assertEqual(maindec.mword(0x8013D9BC), 0x34020002)
        for value, expected in ((0, 0), (0x20, 2), (0x40, 0)):
            self.assertEqual(2 if value & mask else 0, expected)
        self.assertEqual(maindec.mword(0x8012F278), 0xA2620000)
        self.assertEqual(maindec.mword(0x8012F310), 0xA2150000)

    def test_original_temporary_party_constructor_counts_3_and_6(self):
        check_source_paths()
        assert_main_words({
            0x8013A884: (0x9050008A,),
            # Three graphics from the same source character occupy distinct descriptor fields.
            0x8013A934: (0x0C04E9DC, 0x02002021, 0xAE22FFF4,
                         0x0C04E9DC, 0x02002021, 0xAE22FFF8,
                         0x0C04E9DC, 0x02002021, 0xAE22FFFC),
            0x8013A998: (0x26310018, 0x0262102A, 0x1440FFB3),
        })
        source_party = [8, 2, 4, 6, 35, 38]
        for count, expected in ((3, [2, 4]), (6, [2, 4, 6, 35, 38])):
            self.assertEqual(temporary_characters(source_party, count), expected)
            party = source_party[:count]
            state = {"story": {}, "scene": {"phase": "active", "released_selectors": [], "construction_story": {}},
                     "temporary": {"phase": "active"}, "active_party_count": count,
                     "temporary_party": party, "ordinary_party": [8, 70, 70, 70, 70, 70][:count]}
            for selector, slot in ((0x40, 1), (0x41, 2)):
                resolved = self.resolve("vb6_room6", "vb6_r06_first_arrival", selector, state)
                self.assertEqual((resolved["status"], resolved["party_slot"], resolved["source_character_id"]),
                                 ("resolved", slot, party[slot]))
                self.assertEqual(resolved["domain"], "temporary_party_slot")
            hero = self.resolve("vb6_room6", "vb6_r06_first_arrival", 0x80, state)
            self.assertEqual((hero["domain"], hero["source_character_id"]), ("hero", 8))
            self.assertEqual(state["ordinary_party"][1], 70, "ordinary party must not supply temporary slots")

    def test_party_slot_boundaries_and_release_recreation(self):
        for count in (1, 3, 6):
            party = [8, 2, 4, 13, 12, 11][:count]
            state = {"story": {}, "scene": {"phase": "active", "released_selectors": [], "construction_story": {}},
                     "temporary": {"phase": "active"}, "active_party_count": count,
                     "temporary_party": party}
            for selector in (0x40, 0x41, 0x42, 0x43, 0x44, 0x45):
                result = self.resolve("vb6_room6", "vb6_r06_first_arrival", selector, state)
                index = selector - 0x40
                if index < count - 1:
                    self.assertEqual(result["source_character_id"], party[index + 1])
                else:
                    self.assertEqual(result["status"], "missing")
        state = {"story": {}, "scene": {"phase": "active", "released_selectors": [], "construction_story": {}},
                 "temporary": {"phase": "released"}, "active_party_count": 3,
                 "temporary_party": [8, 2, 4]}
        released = self.resolve("vb6_room6", "vb6_r06_first_arrival", 0x40, state)
        self.assertEqual((released["status"], released["source_character_id"]), ("released", 2))
        recreated = self.resolve("vb6_room6", "vb6_r06_first_arrival", 0x40,
                                 state | {"temporary": {"phase": "active"}})
        self.assertEqual((recreated["status"], recreated["party_slot"], recreated["source_character_id"]),
                         ("resolved", 1, 2))

        assert_main_words({
            0x80171718 + 4 * 0x3A: (0x8013C82C,),
            # Release checks object presence before writing the marker. A drained table is freed.
            0x8013C8A4: (0x8C620008, 0, 0x1040000B),
            0x8013C8D4: (0x340200FE, 0xA0620001),
            0x8013C718: (0x14600009, 0, 0x0C04EAFD),
            0x8013AC90: (0xAC20BF7C,),
        })
        self.assertEqual(temporary_characters(state["temporary_party"], 3), [2, 4])

    def test_dynamic_double_and_scene_lifetimes(self):
        base = {"story": {"scenario_0000": 0},
                "scene": {"phase": "active", "released_selectors": [],
                          "construction_story": {"scenario_0000": 0}}}
        data, _ = source("/VAA.BIN")
        self.assertEqual(data[0x50EA9:0x50EAF], bytes.fromhex("34 01 08 00 17 2D"))
        for phase, status in (("not_created", "missing"), ("active", "resolved"), ("released", "released")):
            result = self.resolve("vaa_room2", "vaa_room2_audience", 0x40,
                                  base | {"dynamic": {"phase": phase}})
            self.assertEqual(result["status"], status)
            if status != "missing":
                self.assertEqual((result["actor_id"], result["source_character_id"]),
                                 ("audience_double", 8))
                self.assertEqual(result["domain"], "dynamic_scene_actor")
        self.assertEqual(self.resolve("vaa_room2", "vaa_room2_audience", 0x41,
                                      base | {"dynamic": {"phase": "active"}})["reason"],
                         "dynamic_index_not_constructed")
        self.assertEqual(self.resolve("vaa_room2", "vaa_room2_audience", 12,
                                      base | {"scene": {"phase": "pre_creation", "released_selectors": []}})["status"],
                         "missing")
        released = self.resolve("vaa_room2", "vaa_room2_audience", 12,
                                base | {"scene": {"phase": "active", "released_selectors": [12],
                                                  "construction_story": {"scenario_0000": 0}}})
        recreated = self.resolve("vaa_room2", "vaa_room2_audience", 12,
                                 base | {"scene": {"phase": "recreated", "released_selectors": [],
                                                   "construction_story": {"scenario_0000": 0}}})
        self.assertEqual(released["status"], "released")
        self.assertEqual(recreated["source_entity_id"], released["source_entity_id"])
        self.assertEqual(recreated["actor_id"], released["actor_id"])

    def test_language_neutral_fixture_cases(self):
        disk = json.loads((ROOT / "game/tests/fixtures/field_actor_bindings.json").read_text())
        self.assertEqual(disk, self.fixtures)
        self.assertEqual(disk["packet_content_sha256"], self.packet["content_sha256"])
        for row in disk["cases"]:
            actual = self.resolve(row["scene_id"], row["program_id"], row["selector"], row["state"])
            for key, expected in row["expected"].items():
                self.assertEqual(actual.get(key), expected, row["id"])

    def test_invalid_truncated_unsupported_and_ambiguous_inputs(self):
        base = {"story": {"scenario_0000": 0},
                "scene": {"phase": "active", "released_selectors": [],
                          "construction_story": {"scenario_0000": 0}}}
        for packet in (None, {}, {"schema": "other"}, copy.deepcopy(self.packet)):
            if isinstance(packet, dict) and packet.get("schema") == binder.SCHEMA:
                packet["scenes"] = packet["scenes"][:1]
            self.assertEqual(binder.resolve(packet, "vaa_room2", "vaa_room2_audience", 0, base)["status"], "invalid")
        duplicate = copy.deepcopy(self.packet)
        duplicate["scenes"][0]["scene_actors"][1]["stable_actor_id"] = duplicate["scenes"][0]["scene_actors"][0]["stable_actor_id"]
        duplicate = binder.identified({key: value for key, value in duplicate.items() if key != "content_sha256"})
        self.assertEqual(binder.resolve(duplicate, "vaa_room2", "vaa_room2_audience", 0, base)["status"], "invalid")
        unsupported = copy.deepcopy(self.packet)
        unsupported["scenes"][0]["scene_actors"][0]["classification"]["terms"] = [{"kind": "future_predicate"}]
        unsupported = binder.identified({key: value for key, value in unsupported.items() if key != "content_sha256"})
        self.assertEqual(self.resolve("vaa_room2", "vaa_room2_audience", 0, base)["status"], "resolved")
        self.assertEqual(binder.resolve(unsupported, "vaa_room2", "vaa_room2_audience", 0, base)["status"], "unsupported")
        missing_construction = base | {"scene": {"phase": "active", "released_selectors": [],
                                                 "construction_story": {}}}
        self.assertEqual(self.resolve("vaa_room2", "vaa_room2_audience", 11,
                                      missing_construction)["status"], "ambiguous")
        self.assertEqual(self.resolve("vaa_room2", "vaa_room2_audience", 11,
                                      base | {"story": {}})["status"], "resolved")
        self.assertEqual(self.resolve("vaa_room2", "not_a_program", 0, base)["status"], "unsupported")
        self.assertEqual(self.resolve("vaa_room2", "vaa_room2_audience", 0x81, base)["status"], "unsupported")
        self.assertEqual(self.resolve("vaa_room2", "vaa_room2_audience", -1, base)["status"], "invalid")
        for count, party in ((0, []), (7, [8] * 7), (3, [8, 2]), (3, [8, 2, 255]), (3, [2, 2, 4])):
            state = {"story": {}, "scene": {"phase": "active", "released_selectors": [], "construction_story": {}},
                     "temporary": {"phase": "active"}, "active_party_count": count, "temporary_party": party}
            self.assertEqual(self.resolve("vb6_room6", "vb6_r06_first_arrival", 0x40, state)["status"], "invalid")

    def test_null_scene_record_is_controlled_invalid_packet(self):
        malformed = copy.deepcopy(self.packet)
        malformed["scenes"][0] = None
        malformed = binder.identified({key: value for key, value in malformed.items() if key != "content_sha256"})
        state = {"story": {}, "scene": {"phase": "pre_creation", "released_selectors": []}}
        result = binder.resolve(malformed, "vaa_room2", "vaa_room2_audience", 0, state)
        self.assertEqual((result["status"], result["reason"]),
                         ("invalid", "binding packet scenes must be object records"))

    def test_null_actor_record_is_controlled_invalid_packet(self):
        malformed = copy.deepcopy(self.packet)
        malformed["scenes"][0]["scene_actors"][0] = None
        malformed = binder.identified({key: value for key, value in malformed.items() if key != "content_sha256"})
        state = {"story": {}, "scene": {"phase": "pre_creation", "released_selectors": []}}
        result = binder.resolve(malformed, "vaa_room2", "vaa_room2_audience", 0, state)
        self.assertEqual((result["status"], result["reason"]),
                         ("invalid", "scene actors must be object records"))

    def test_original_source_mutation_detection(self):
        real_source = binder.source
        def mutated_source(suffix):
            data, proof = real_source(suffix)
            if suffix == "/VAA.BIN":
                changed = bytearray(data)
                changed[0x50D83] = 0x81
                data = bytes(changed)
            return data, proof
        with mock.patch.object(binder, "source", side_effect=mutated_source):
            with self.assertRaisesRegex(binder.BindingError, "original source identity changed"):
                binder.build()

    def test_project_outputs_match_generation(self):
        expected = binder.output_bytes(self.exported)
        self.assertEqual(set(expected), set(binder.OUTPUTS))
        for relative, data in expected.items():
            self.assertEqual((ROOT / relative).read_bytes(), data, relative)

    def test_determinism_check_stale_missing_and_mutation_detection(self):
        with tempfile.TemporaryDirectory(prefix="field-bindings-test-") as temporary:
            root = Path(temporary)
            first, second = root / "first", root / "second"
            for output in (first, second):
                completed = self.run_cli(output)
                self.assertEqual(completed.returncode, 0, completed.stderr)
            for relative in binder.OUTPUTS:
                self.assertEqual((first / relative).read_bytes(), (second / relative).read_bytes(), relative)
            checked = self.run_cli(first, check=True)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            target = first / binder.OUTPUTS[0]
            original = target.read_bytes()
            target.write_bytes(original + b"\n")
            stale = self.run_cli(first, check=True)
            self.assertEqual(stale.returncode, 1)
            self.assertIn("stale", stale.stderr)
            target.write_bytes(original)
            target.unlink()
            missing = self.run_cli(first, check=True)
            self.assertEqual(missing.returncode, 1)
            self.assertFalse(target.exists(), "--check repaired a missing output")

            inputs = root / "inputs"
            for relative in binder.FROZEN:
                path = inputs / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / relative, path)
            event = inputs / "game/assets/events/vaa_audience_choice.json"
            mutated = json.loads(event.read_text())
            mutated["actors"][0]["id"] = "untrusted_actor"
            event.write_text(json.dumps(mutated))
            rejected = self.run_cli(root / "mutated-output", input_root=inputs)
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("accepted input changed", rejected.stderr)
            self.assertFalse((root / "mutated-output").exists())

    def run_cli(self, output_root, check=False, input_root=ROOT):
        command = [sys.executable, "-B", str(ROOT / "kit/tools/export_field_actor_bindings.py"),
                   "--input-root", str(input_root), "--output-root", str(output_root)]
        if check:
            command.append("--check")
        return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False,
                              env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))


if __name__ == "__main__":
    unittest.main()
