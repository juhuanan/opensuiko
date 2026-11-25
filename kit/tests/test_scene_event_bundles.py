#!/usr/bin/env python3
"""Focused source and contract checks for offline scene-event bundle linking."""
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
import compile_event_programs as compiler
import export_field_actor_bindings as binder
import export_scene_event_bundles as linker
from export_first_room import source
import war_text
from test_entity_predicates import check_dispatch


class SceneEventBundles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.exported = linker.build()
        cls.bundles = cls.exported["bundles"]
        cls.e9 = cls.exported["e9"]
        cls.external = [cls.exported["inputs"]["game/assets/events/vb6_room6_field_host.json"]]
        cls.frozen_paths = [ROOT / name for name in linker.FROZEN]
        cls.frozen_paths += [ROOT / "kit/tools" / name for name in linker.HELPER_HASHES]
        cls.frozen_paths += [ROOT / name for name in (
            "kit/tools/compile_event_programs.py", "kit/tests/test_event_program_compiler.py",
            "kit/data/reports/event_program_compiler.json", "kit/data/registry/extract_event_program_compiler.jsonl",
            "kit/data/reports/event_program_compiler_handoff.md", "game/src/event_runtime.zig",
            "game/src/scene_population.zig")]
        cls.before_hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in cls.frozen_paths}

    def tearDown(self):
        current = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in self.frozen_paths}
        self.assertEqual(current, self.before_hashes, "frozen/read-only input changed")

    def reidentified(self, bundle):
        return linker.identified({key: value for key, value in bundle.items() if key != "content_sha256"})

    def assertInvalid(self, bundle, external=None):
        with self.assertRaises(linker.BundleError):
            linker.validate_bundle(bundle, self.external if external is None else external)

    def test_substantive_source_order_and_accepted_program_integrity(self):
        self.assertEqual([len(self.bundles[key]["entries"]) for key in ("vaa_room2", "vb6_room6")], [26, 36])
        self.assertEqual([self.bundles["vaa_room2"]["coverage"][key] for key in ("executable_entries", "source_only_entries", "blocked_entries")], [3, 23, 0])
        self.assertEqual([self.bundles["vb6_room6"]["coverage"][key] for key in ("executable_entries", "source_only_entries", "blocked_entries")], [3, 32, 1])
        for scene_id, suffix, room in linker.SCENES:
            data, _ = source(suffix)
            original = scene.entities(data, scene.room_record(data, room))
            entries = self.bundles[scene_id]["entries"]
            self.assertEqual([row["source_order"] for row in entries], [row["index"] for row in original])
            bundle = self.bundles[scene_id]
            packet = self.exported["inputs"][f"game/assets/scenes/population/{scene_id}.json"]
            self.assertEqual([row["guard"] for row in bundle["entries"]], [row["event_selection"] for row in packet["entities"]])
            self.assertEqual(bundle["population"]["content_sha256"], packet["content_sha256"])
        expected = {"vaa_room2_audience": 201, "vaa_room2_init_23": 2,
                    "vaa_room2_init_24": 10, "vb6_r06_first_arrival": 28}
        for bundle in self.bundles.values():
            for record in bundle["contents"]:
                program_id = record["reference"]["program_id"]
                if program_id not in expected:
                    continue
                original = self.exported["inputs"]["game/assets/events/vaa_audience_choice.json" if program_id.startswith("vaa") else "game/assets/events/vb6_room6_arrival.json"]
                self.assertEqual(record["content"], original)
                self.assertEqual(record["command_count"], expected[program_id])
        linker.validate_bundle(self.bundles["vaa_room2"], self.external)
        linker.validate_bundle(self.bundles["vb6_room6"], self.external)

    def test_initialization_order_and_conditional_source_only_entries(self):
        vaa = self.bundles["vaa_room2"]["entries"]
        self.assertEqual([vaa[index]["initialization_order"] for index in (23, 24)], [0, 1])
        self.assertEqual([vaa[index]["program"]["program_id"] for index in (23, 24)],
                         [compiler.INIT_23, compiler.INIT_24])
        vb6 = self.bundles["vb6_room6"]["entries"]
        self.assertEqual(vb6[6]["status"], "executable_required_external")
        self.assertEqual(vb6[6]["program"]["content_sha256"], self.external[0]["content_sha256"])
        self.assertNotEqual(vb6[5]["program"]["content_sha256"], vb6[6]["program"]["content_sha256"])
        for index, order in ((8, 1), (28, 2)):
            self.assertEqual(vb6[index]["status"], "source_only")
            self.assertEqual(vb6[index]["initialization_order"], order)
            self.assertIsNone(vb6[index]["program"])
        self.assertEqual(vb6[8]["guard"]["terms"], [
            {"kind": "story_mask_clear", "flag": {"id": "scenario_0016", "mask": 1}},
            {"kind": "story_mask_set", "flag": {"id": "scenario_0015", "mask": 64}}])
        self.assertEqual(vb6[28]["guard"]["terms"], [
            {"kind": "story_mask_clear", "flag": {"id": "scenario_0017", "mask": 16}},
            {"kind": "story_mask_set", "flag": {"id": "scenario_0017", "mask": 4}}])

    def test_original_e9_guard_track_text_and_terminal_consumers(self):
        data, _ = source("/VB6.BIN")
        self.assertEqual(data[0x351AE:0x351B3], bytes.fromhex("32 00 03 19 05"))
        self.assertEqual(data[0x351B3:0x351B6], bytes.fromhex("11 40 00"))
        self.assertEqual(data[0x351C2:0x351C5], bytes.fromhex("11 41 02"))
        self.assertEqual(data[0x351D2:0x351D9], bytes.fromhex("3A 00 37 38 09 10 01"))
        self.assertEqual(data[0x351D9], 0xFD)
        commands = self.e9["programs"][0]["commands"]
        self.assertEqual(len(commands), 29)
        self.assertEqual(commands[8], {"kind": "queue_track", "track": "vb6_r06_entity09_track_00"})
        self.assertEqual(commands[9]["parameter"], 1)
        self.assertEqual(commands[9]["mask"], 1)
        self.assertEqual(commands[16]["parameter"], 0)
        self.assertEqual(commands[16]["mask"], 2)
        self.assertEqual(commands[24], {"kind": "release_actor", "actor": "vb6_r06_e07_char_014"})
        self.assertEqual(commands[27]["flag"], {"id": "scenario_0016", "mask": 1})
        self.assertEqual(self.e9["tracks"][0]["commands"],
                         [{"kind": "move", "direction": "left", "cells": 25}, {"kind": "finish"}])
        table = scene.ptr_at(data, scene.ptr_at(data, scene.root(data) + 20))
        for index in (7, 8, 9):
            pointer = scene.ptr_at(data, table + index * 4)
            decoded, _ = war_text.decode(data, pointer)
            text = next(row for row in self.e9["texts"] if row["id"] == f"vb6_e09_text_0_{index}")
            self.assertEqual([token["text"] for token in text["tokens"]],
                             [page.strip() for page in decoded.split("[---]")])
        entries = scene.entities(data, scene.room_record(data, 6))
        predicate = entries[9]["stream_offsets"][1]
        self.assertEqual(data[predicate:predicate + 7], bytes((8, 16, 1, 7, 15, 0x40, 6)))
        check_dispatch()
        self.assertEqual(self.bundles["vb6_room6"]["entries"][9]["guard"]["terms"], [
            {"kind": "story_mask_clear", "flag": {"id": "scenario_0016", "mask": 1}},
            {"kind": "story_mask_set", "flag": {"id": "scenario_0015", "mask": 0x40}},
        ])

    def test_e7_gap_has_no_transition_fallback_or_e9_chain(self):
        entries = self.bundles["vb6_room6"]["entries"]
        self.assertEqual(entries[7]["status"], "blocked_unsupported")
        self.assertIsNone(entries[7]["program"])
        self.assertEqual(entries[7]["gap"]["unsupported"], {
            "source_offset": 0x35184, "source_address": 0x80035184, "opcode": 3,
            "operands_hex": "061b19", "kind": "room_coordinate_transition", "room": 6,
            "x_half_cell": 27, "y_half_cell": 25,
            "reason": "Frozen IR has no typed room/coordinate transition"})
        self.assertEqual(entries[9]["status"], "executable_embedded")
        self.assertNotEqual(entries[9]["program"], entries[7]["program"])

    def test_complete_e9_or_full_typed_gap_never_partial(self):
        self.assertEqual(self.e9["schema"], compiler.SCHEMA)
        self.assertEqual(self.e9["programs"][0]["commands"][-1]["kind"], "end_stream")
        self.assertIsNone(self.exported["report"]["e9"]["gap"])
        with mock.patch.object(linker.compiler.FrozenLowering, "command",
                               side_effect=compiler.CompilationError("witness unsupported")):
            content, _proof, gap = linker.compile_e9(self.exported["inputs"]["game/assets/scenes/bindings/field_actor_bindings.json"])
        self.assertIsNone(content)
        self.assertEqual(gap["schema"], "suikoden-event-compilation-gap/1")
        self.assertTrue(gap["complete_program_suppressed"])
        self.assertFalse(gap["partial_commands_emitted"])
        self.assertNotIn("commands", gap)
        self.assertEqual(gap["decoded_instruction_count"], 29)
        self.assertEqual(gap["source_actions_translated_before_failure"], 29)
        self.assertIn("witness unsupported", gap["unsupported"]["reason"])

    def test_construction_lifetime_binding_and_resource_domains(self):
        for case in self.exported["fixtures"]["construction_lifetime_cases"]:
            result = binder.resolve(self.exported["inputs"]["game/assets/scenes/bindings/field_actor_bindings.json"],
                                    "vaa_room2", compiler.AUDIENCE, case["selector"], case["state"])
            for key, value in case["expected"].items():
                self.assertEqual(result.get(key), value, case["id"])
        for scene_id in ("vaa_room2", "vb6_room6"):
            resources = self.bundles[scene_id]["resources"]
            self.assertFalse(any(row["binding_status"] == "unsupported_actor" for row in resources))
            for row in resources:
                if row["binding_status"] == "bound":
                    self.assertIsInstance(row["actor_id"], str)
                    self.assertIn(row["resource_domain"], ("area_character_context", "active_party_character"))
        nulls = [row for row in self.bundles["vaa_room2"]["resources"]
                 if row["binding_status"] == "not_constructed_null_classification"]
        self.assertTrue(nulls)
        self.assertTrue(all(row["actor_id"] is None for row in nulls))
        unsupported = binder.resolve(self.exported["inputs"]["game/assets/scenes/bindings/field_actor_bindings.json"],
                                     "vb6_room6", compiler.ARRIVAL, 0x81,
                                     {"story": {}, "scene": {"phase": "active", "released_selectors": [], "construction_story": {}}})
        self.assertEqual(unsupported["status"], "unsupported")

    def test_qualified_hash_collision_missing_program_and_dangling_reference(self):
        original = self.bundles["vb6_room6"]
        wrong_hash = copy.deepcopy(original)
        wrong_hash["contents"][0]["reference"]["content_sha256"] = "0" * 64
        self.assertInvalid(self.reidentified(wrong_hash))
        missing = copy.deepcopy(original)
        missing["contents"][0]["reference"]["program_id"] = "not_a_program"
        self.assertInvalid(self.reidentified(missing))
        dangling = copy.deepcopy(original)
        dangling["entries"][9]["program"]["content_sha256"] = "f" * 64
        self.assertInvalid(self.reidentified(dangling))
        duplicate = copy.deepcopy(original)
        duplicate["contents"].append(copy.deepcopy(duplicate["contents"][0]))
        self.assertInvalid(self.reidentified(duplicate))
        fallback = copy.deepcopy(original)
        fallback["entries"][7]["program"] = copy.deepcopy(fallback["entries"][9]["program"])
        self.assertInvalid(self.reidentified(fallback))
        arrival_record = original["contents"][0]["reference"]
        init6_record = original["contents"][1]["reference"]
        self.assertEqual(arrival_record["content_id"], init6_record["content_id"])
        self.assertNotEqual(arrival_record["content_sha256"], init6_record["content_sha256"])

    def test_required_external_init6_missing_or_wrong_hash_fails_closed(self):
        self.assertInvalid(self.bundles["vb6_room6"], [])
        wrong = copy.deepcopy(self.external[0])
        wrong["content_sha256"] = "0" * 64
        self.assertInvalid(self.bundles["vb6_room6"], [wrong])
        changed = copy.deepcopy(self.bundles["vb6_room6"])
        changed["contents"][1]["reference"]["content_sha256"] = self.bundles["vb6_room6"]["contents"][0]["reference"]["content_sha256"]
        self.assertInvalid(self.reidentified(changed))

    def test_external_init6_payload_cannot_reuse_stale_declared_hash(self):
        changed = copy.deepcopy(self.external[0])
        init6 = next(row for row in changed["programs"] if row["id"] == "vb6_room6_init_06")
        effect = next(row for row in init6["commands"] if row["kind"] == "story_or")
        self.assertEqual(effect["flag"]["mask"], 2)
        effect["flag"]["mask"] = 4
        self.assertEqual(changed["content_sha256"], self.external[0]["content_sha256"])
        self.assertInvalid(self.bundles["vb6_room6"], [changed])

    def test_source_only_init8_cannot_execute_a_valid_e9_reference(self):
        changed = copy.deepcopy(self.bundles["vb6_room6"])
        changed["entries"][8]["status"] = changed["entries"][9]["status"]
        changed["entries"][8]["program"] = copy.deepcopy(changed["entries"][9]["program"])
        self.assertInvalid(self.reidentified(changed))

    def test_language_neutral_fixture_and_generated_outputs(self):
        disk = json.loads((ROOT / "game/tests/fixtures/scene_event_bundles.json").read_text())
        self.assertEqual(disk, self.exported["fixtures"])
        self.assertEqual(disk["bundle_content_sha256"],
                         {key: value["content_sha256"] for key, value in self.bundles.items()})
        self.assertEqual(disk["e9_source_expectation"]["command_count"], 29)
        expected = linker.output_bytes(self.exported)
        self.assertEqual(set(expected), set(linker.OUTPUTS))
        for relative, data in expected.items():
            self.assertEqual((ROOT / relative).read_bytes(), data, relative)

    def test_deterministic_generation_check_stale_missing_and_input_mutation(self):
        with tempfile.TemporaryDirectory(prefix="scene-event-test-") as temporary:
            root = Path(temporary)
            first, second = root / "first", root / "second"
            for output in (first, second):
                completed = self.run_cli(output)
                self.assertEqual(completed.returncode, 0, completed.stderr)
            for relative in linker.OUTPUTS:
                self.assertEqual((first / relative).read_bytes(), (second / relative).read_bytes(), relative)
            checked = self.run_cli(first, check=True)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            target = first / linker.OUTPUTS[0]
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
            for relative in linker.FROZEN:
                path = inputs / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / relative, path)
            host = inputs / "game/assets/events/vb6_room6_field_host.json"
            host.write_bytes(host.read_bytes() + b"\n")
            rejected = self.run_cli(root / "mutated-output", input_root=inputs)
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("frozen input changed", rejected.stderr)
            self.assertFalse((root / "mutated-output").exists())

    def run_cli(self, output_root, check=False, input_root=ROOT):
        command = [sys.executable, "-B", str(ROOT / "kit/tools/export_scene_event_bundles.py"),
                   "--input-root", str(input_root), "--output-root", str(output_root)]
        if check:
            command.append("--check")
        return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False,
                              env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))


if __name__ == "__main__":
    unittest.main()
