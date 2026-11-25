#!/usr/bin/env python3
"""Independent original-caller and contract checks for offline scene dispatch."""
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

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
sys.path.insert(0, str(ROOT / "kit/tests"))

import area_scene
import compile_event_programs as compiler
import export_scene_dispatch as exporter
import maindec
from export_first_room import source
from test_entity_predicates import assert_words
from test_field_initializers import check_consumers
ROUTE_REPAIR_PATHS = (
    "kit/tools/export_route_transitions.py",
    "kit/tests/test_route_transitions.py",
    "kit/data/reports/route_transitions.json",
    "kit/data/registry/extract_route_transitions.jsonl",
    "game/src/route_transitions.zig",
    "game/tests/route_transitions.zig",
    "game/assets/routes/region_b_vb6_c.json",
    "game/tests/fixtures/route_transitions.json",
)


class SceneDispatch(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.exported = exporter.build()
        cls.packet = cls.exported["packet"]
        cls.scenes = {scene["id"]: scene for scene in cls.packet["scenes"]}
        cls.inputs = cls.exported["inputs"]
        cls.frozen_paths = [ROOT / name for name in exporter.FROZEN]
        cls.frozen_paths += [ROOT / "kit/tools" / name for name in exporter.HELPERS]
        cls.frozen_paths += [ROOT / name for name in exporter.ZIG_DEPENDENCIES + ROUTE_REPAIR_PATHS]
        cls.before_hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in cls.frozen_paths}

    def tearDown(self):
        current = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in self.frozen_paths}
        self.assertEqual(current, self.before_hashes, "frozen/read-only dependency changed")

    def reidentified(self, packet):
        return exporter.identified({key: value for key, value in packet.items() if key != "content_sha256"})

    def test_source_order_guards_and_qualified_references(self):
        self.assertEqual(len(self.packet["scenes"]), 2)
        self.assertEqual(sum(scene["initialization_count"] for scene in self.packet["scenes"]), 5)
        self.assertEqual(sum(len(scene["entries"]) for scene in self.packet["scenes"]), 7)
        for scene_id, suffix, room in exporter.SCENES:
            scene = self.scenes[scene_id]
            pop = self.inputs[f"game/assets/scenes/population/{scene_id}.json"]
            bundle = self.inputs[f"game/assets/scenes/events/{scene_id}.json"]
            self.assertEqual(scene["population"]["content_sha256"], pop["content_sha256"])
            self.assertEqual(scene["bundle"]["content_sha256"], bundle["content_sha256"])
            data, _ = source(suffix)
            originals = area_scene.entities(data, area_scene.room_record(data, room))
            self.assertEqual(len(originals), len(pop["entities"]))
            for entry in scene["entries"]:
                index = entry["source_order"]
                original = originals[index]
                guard, _proof = exporter.population.decode_predicate(data, original["stream_offsets"][1], "event")
                self.assertEqual(guard, pop["entities"][index]["event_selection"])
                self.assertEqual(entry["source_entity_id"], pop["entities"][index]["id"])
                if entry["status"] == "executable":
                    self.assertEqual(entry["program"]["entry"], entry["phase"])
                    self.assertEqual(entry["program"], bundle["entries"][index]["program"] | {"entry": entry["phase"]})
                else:
                    self.assertEqual(bundle["entries"][index]["status"], "blocked_unsupported")
                    self.assertIsNone(entry["program"])
        vb6, _ = source("/VB6.BIN")
        self.assertEqual(vb6[0x350BC:0x350C3], bytes.fromhex("08 0f 40 07 0f 20 06"))
        self.assertEqual(vb6[0x35161], 0xFD)
        self.assertEqual(vb6[0x35184:0x35188], bytes.fromhex("03 06 1b 19"))

    def test_original_selector_is_first_match_in_declared_source_order(self):
        check_consumers()
        assert_words({
            # Accept jumps to the return path. Only a failed predicate advances by 24 bytes.
            0x8013F244: (0x10400005, 0x26100001, 0x0C04F85F, 0x26310001, 0x0804FCA2),
            0x8013F268: (0x24420018, 0x3C018018, 0xAC22A120, 0x320200FF, 0x0052102B, 0x1440FFEE),
            0x8013297C: (0x0C04FC6F,),
            0x80132994: (0x24632B6C,),
            0x801329B0: (0xA0221C28,),
        })
        selector = (word for _, word, _ in maindec.dis(0x8013F1BC, (0x8013F2A4 - 0x8013F1BC) // 4))
        self.assertNotIn(0x0C04F80A, selector)

    def test_original_initialization_pumps_once_without_waiting(self):
        check_consumers()
        for suffix, room, story, expected in (
            ("/VAA.BIN", 2, {0: 0x40}, [23, 24]),
            ("/VB6.BIN", 6, {15: 0x40, 16: 0}, [6, 8]),
            ("/VB6.BIN", 6, {15: 0x40, 16: 0, 17: 4}, [6, 8, 28]),
            ("/VB6.BIN", 6, {15: 0, 16: 1, 17: 4}, [6, 28]),
        ):
            data, _ = source(suffix)
            entities = area_scene.entities(data, area_scene.room_record(data, room))
            selected = []
            for entry in entities:
                if not entry["flags"] & 0x10:
                    continue
                cursor = entry["stream_offsets"][1]
                accepted = True
                while data[cursor] != 6:
                    opcode, byte, mask = data[cursor:cursor + 3]
                    self.assertIn(opcode, (7, 8))
                    accepted &= bool(story.get(byte, 0) & mask) == (opcode == 7)
                    cursor += 3
                if accepted:
                    selected.append(entry["index"])
            self.assertEqual(selected, expected)

    def test_original_e5_completion_rearms_free_before_e7_not_same_tick(self):
        data, _ = source("/VB6.BIN")
        self.assertEqual(data[0x3515E:0x35162], bytes((9, 15, 0x20, 0xFD)))
        assert_words({
            # Inline FD clears the owner flag and raises the completion word before returning.
            0x8013E118: (0xA0201C28,),
            0x8013E124: (0x34020001, 0x3C018018, 0xAC22DC4C),
            0x80132B98: (0x0C04FC44,),
            0x8013F12C: (0x0C04F80A,),
            0x80132C98: (0x24422938, 0x3C018018, 0x2421DA90, 0x00230821, 0xAC220000),
        })
        dispatch = [word for _, word, _ in maindec.dis(0x80132B6C, (0x80132D04 - 0x80132B6C) // 4)]
        self.assertNotIn(0x0C04FC6F, dispatch)

    def test_completed_vm_waits_for_original_area_callback_completion(self):
        assert_words({
            # Clear completion before calling the area callback. Recheck its pointer on return.
            0x80132C28: (0x8C820498, 0, 0x1040000E),
            0x80132C3C: (0xAC20DC4C, 0x0040F809, 0),
            0x80132C54: (0x8C420498, 0, 0x14400003, 0x34020001, 0x3C018018, 0xAC22DC4C),
            # Rearm free selection only after completion is set and the stream is inactive.
            0x80132C70: (0x8C63DC4C, 0x34020001, 0x1462001D),
            0x80132C84: (0x90421C28, 0, 0x14400018),
        })

    def test_original_e7_guard_eligibility_is_distinct_from_admission(self):
        data, _ = source("/VB6.BIN")
        entities = area_scene.entities(data, area_scene.room_record(data, 6))
        predicate = entities[7]["stream_offsets"][1]
        clear, clear_byte, clear_mask, required, required_byte, required_mask, end = data[predicate:predicate + 7]
        self.assertEqual((clear, clear_byte, required, required_byte, end), (8, 15, 7, 15, 6))
        for value, eligible in ((0x28, True), (0x20, True), (0x08, False), (0x68, False), (0x60, False)):
            self.assertEqual(not value & clear_mask and bool(value & required_mask), eligible, hex(value))
        entry = next(row for row in self.scenes["vb6_room6"]["entries"] if row["source_order"] == 7)
        self.assertEqual(entry["status"], "blocked_unsupported")
        self.assertIsNone(entry["program"])

    def test_stale_mismatched_and_source_only_reference_promotion_fail(self):
        exporter.validate_packet(self.packet, self.inputs)
        changed = copy.deepcopy(self.packet)
        changed["scenes"][1]["population"]["content_sha256"] = "0" * 64
        with self.assertRaises(exporter.DispatchError):
            exporter.validate_packet(self.reidentified(changed), self.inputs)
        changed = copy.deepcopy(self.packet)
        changed["scenes"][1]["entries"][3]["program"]["content_sha256"] = "0" * 64
        with self.assertRaises(exporter.DispatchError):
            exporter.validate_packet(self.reidentified(changed), self.inputs)
        changed = copy.deepcopy(self.packet)
        changed["scenes"][1]["entries"][1]["program"]["entry"] = "ordinary"
        with self.assertRaises(exporter.DispatchError):
            exporter.validate_packet(self.reidentified(changed), self.inputs)
        changed = copy.deepcopy(self.packet)
        promoted = copy.deepcopy(changed["scenes"][1]["entries"][1])
        promoted["source_order"] = 8
        promoted["source_entity_id"] = "vb6_room6_entity_08"
        promoted["phase"] = "initialization"
        changed["scenes"][1]["entries"].append(promoted)
        with self.assertRaises(exporter.DispatchError):
            exporter.validate_packet(self.reidentified(changed), self.inputs)
        changed = copy.deepcopy(self.packet)
        changed["scenes"][1]["entries"][2]["program"] = copy.deepcopy(changed["scenes"][1]["entries"][3]["program"])
        with self.assertRaises(exporter.DispatchError):
            exporter.validate_packet(self.reidentified(changed), self.inputs)

    def test_language_neutral_fixture_generated_outputs_and_hash_identities(self):
        fixture = self.exported["fixtures"]
        self.assertEqual(len(fixture["cases"]), 23)
        self.assertEqual(fixture["packet_content_sha256"], self.packet["content_sha256"])
        self.assertEqual(json.loads((ROOT / "game/tests/fixtures/scene_dispatch.json").read_text()), fixture)
        self.assertEqual(json.loads((ROOT / "game/assets/scenes/dispatch/vaa_vb6.json").read_text()), self.packet)
        expected = exporter.output_bytes(self.exported)
        self.assertEqual(set(expected), set(exporter.OUTPUTS))
        for relative, data in expected.items():
            self.assertEqual((ROOT / relative).read_bytes(), data, relative)
        identities = self.exported["report"]["generated_identities"]
        self.assertEqual(identities["packet_content_sha256"], self.packet["content_sha256"])
        self.assertEqual(identities["fixture_content_sha256"], fixture["content_sha256"])
        registry = expected["kit/data/registry/extract_scene_dispatch.jsonl"]
        self.assertEqual(identities["registry_sha256"], hashlib.sha256(registry).hexdigest())

    def test_deterministic_generation_check_stale_missing_and_input_mutation(self):
        with tempfile.TemporaryDirectory(prefix="scene-dispatch-test-") as temporary:
            root = Path(temporary)
            first, second = root / "first", root / "second"
            for output in (first, second):
                completed = self.run_cli(output)
                self.assertEqual(completed.returncode, 0, completed.stderr)
            for relative in exporter.OUTPUTS:
                self.assertEqual((first / relative).read_bytes(), (second / relative).read_bytes(), relative)
                self.assertEqual((first / relative).read_bytes(), (ROOT / relative).read_bytes(), relative)
            checked = self.run_cli(first, check=True)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            target = first / exporter.OUTPUTS[0]
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
            for relative in list(exporter.FROZEN) + list(exporter.ZIG_DEPENDENCIES):
                path = inputs / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / relative, path)
            changed = inputs / "game/assets/scenes/events/vb6_room6.json"
            changed.write_bytes(changed.read_bytes() + b"\n")
            rejected = self.run_cli(root / "mutated-output", input_root=inputs)
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("frozen input changed", rejected.stderr)
            self.assertFalse((root / "mutated-output").exists())

    def run_cli(self, output_root, check=False, input_root=ROOT):
        command = [sys.executable, "-B", str(ROOT / "kit/tools/export_scene_dispatch.py"),
                   "--input-root", str(input_root), "--output-root", str(output_root)]
        if check:
            command.append("--check")
        return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False,
                              env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))


if __name__ == "__main__":
    unittest.main()
