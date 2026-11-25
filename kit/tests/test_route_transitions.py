#!/usr/bin/env python3
"""Focused original-consumer and contract checks for offline route transitions."""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
sys.path.insert(0, str(ROOT / "kit/tests"))

import export_route_transitions as exporter
import maindec
import test_worldmap_points as world_points
from export_first_room import source
from test_entity_predicates import assert_words, check_dispatch, check_helpers

BASE = 0x80010000


class RouteTransitions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.exported = exporter.build()
        cls.packet = cls.exported["packet"]
        cls.routes = {route["id"]: route for route in cls.packet["routes"]}
        cls.data, cls.source_proof = source("/VB6.BIN")
        cls.frozen_paths = [ROOT / "kit/tools" / name for name in exporter.HELPERS]
        cls.frozen_paths += [ROOT / name for name in (
            "game/src/event_runtime.zig", "game/src/scene_population.zig",
            "game/assets/scenes/bindings/field_actor_bindings.json",
            "game/assets/events/vb6_room6_arrival.json",
            "kit/tools/export_scene_event_bundles.py",
            "kit/tests/test_scene_event_bundles.py",
        )]
        cls.before_hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in cls.frozen_paths}

    def tearDown(self):
        current = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in self.frozen_paths}
        self.assertEqual(current, self.before_hashes, "frozen/read-only dependency changed")

    def reidentified(self, packet):
        return exporter.identified({key: value for key, value in packet.items() if key != "content_sha256"})

    def test_all_25_routes_and_direct_room_table_walk(self):
        self.assertEqual(len(self.packet["routes"]), 25)
        self.assertEqual(self.packet["coverage"], {
            "proven": 25, "unresolved": 0, "field_doorways": 20,
            "world_entries_and_returns": 4, "same_room_reconstructions": 1,
        })
        ptr = lambda offset: struct.unpack_from("<I", self.data, offset)[0] - BASE
        seen = set()
        for room, specs in exporter.ROOM_SPECS:
            room_table = ptr(ptr(0) + 8)
            record = room_table + room * 16
            entities = ptr(record)
            for index, prefix in specs:
                route = next(route for route in self.packet["routes"]
                             if route["provenance"].get("room") == room and route["provenance"].get("entity") == index
                             and route["destination"]["spawn"]["domain"] == "field_pixel")
                seen.add(route["id"])
                entry = entities + index * 24
                predicate, stream = ptr(entry + 16), ptr(entry + 20)
                self.assertEqual(route["source_order"], index)
                self.assertEqual(route["provenance"]["entry_offset"], entry)
                self.assertEqual(route["provenance"]["predicate_offset"], predicate)
                self.assertEqual(route["provenance"]["stream_offset"], stream)
                cursor = stream + len(prefix)
                self.assertEqual(self.data[cursor], 3)
                target, x, y, terminal = self.data[cursor + 1:cursor + 5]
                self.assertEqual(terminal, 0xFD)
                self.assertEqual(route["destination"]["location_id"], exporter.journey.ROOMS[target])
                self.assertEqual(route["destination"]["source_spawn"], {"domain": "half_cell", "x": x, "y": y})
                self.assertEqual(route["destination"]["spawn"], {"domain": "field_pixel", "x": x * 8, "y": y * 8})
        self.assertEqual(len(seen), 20)
        self.assertEqual(len({route["id"] for route in self.packet["routes"]}), 25)
        for route_id in ("vb6_r02_e01_to_forest_crossing", "vb6_r02_e02_to_forest_crossing", "vb6_r02_e03_to_forest_crossing"):
            self.assertIn(route_id, self.routes)
        self.assertEqual([self.routes[f"vb6_r02_e{index:02d}_to_forest_crossing"]["destination"]["spawn"]["y"] for index in (1, 2, 3)], [64, 176, 320])
        self.assertEqual([self.routes[f"vb6_r03_e{index:02d}_to_forest_paths"]["destination"]["spawn"]["y"] for index in (0, 1, 2)], [64, 160, 288])

    def test_original_door_predicates_and_transition_consumers(self):
        check_dispatch()
        check_helpers()
        assert_words({
            0x8013E070: (0x34020003, 0x1062000C),
            0x8013E0D0: (0x0C04EFE5,),
            0x8013C144: (0xA0450001,),
            0x8013C174: (0xA4A40004, 0x90630001, 0x0804F08B, 0x34020002),
            0x8013C22C: (0xA4A30006,),
        })
        ptr = lambda offset: struct.unpack_from("<I", self.data, offset)[0] - BASE
        for room, specs in exporter.ROOM_SPECS:
            entities = ptr(ptr(ptr(0) + 8) + room * 16)
            for index, _ in specs:
                route = next(route for route in self.packet["routes"]
                             if route["provenance"].get("room") == room and route["provenance"].get("entity") == index
                             and route["destination"]["spawn"]["domain"] == "field_pixel")
                entry = entities + index * 24
                self.assert_unrestricted_rectangle(route, ptr(entry + 16))

    def assert_unrestricted_rectangle(self, route, predicate):
        x_test, x_min, x_max, y_test, y_min, y_max, end = self.data[predicate:predicate + 7]
        self.assertEqual(x_test, 0x0B)
        self.assertIn(y_test, (0x0C, 6))
        if y_test == 6:
            y_min, y_max = 0, 47
        else:
            self.assertEqual(end, 6)
        trigger = route["origin"]["trigger"]
        self.assertIsNone(trigger.get("direction"))
        self.assertEqual(trigger["rectangle"], {
            "domain": "field_pixel", "x": 8 * x_min, "y": 8 * y_min,
            "w": 8 * (x_max - x_min + 1), "h": 8 * (y_max - y_min + 1),
        })

    def test_unrestricted_world_exit_ignores_direction_in_original(self):
        route = self.routes["vb6_r00_e01_to_region_b"]
        ptr = lambda offset: struct.unpack_from("<I", self.data, offset)[0] - BASE
        entity = ptr(ptr(ptr(0) + 8)) + 24
        self.assert_unrestricted_rectangle(route, ptr(entity + 16))

    def test_world_points_returns_and_independent_main_records(self):
        self.assertEqual(len(world_points.kobold_connection_cases()), 4)
        for region, region_index, point_index, expected in (
            ("region_b", 1, 5, (86, 83, 264, 344, "vb6_village")),
            ("region_c", 2, 6, (59, 36, 352, 216, "vb6_kobold_village")),
        ):
            table = maindec.mword(0x80170064 + 4 * region_index)
            raw = maindec.body()[table - maindec.MBASE + point_index * 14:table - maindec.MBASE + (point_index + 1) * 14]
            x, y = struct.unpack_from("<2H", raw, 2)
            self.assertEqual((x, y, raw[6] * 8, raw[7] * 8), expected[:4])
            route = self.routes[f"{region}_point_{point_index:02d}_to_" + expected[4].removeprefix("vb6_")]
            self.assertEqual(route["origin"]["trigger"]["point"], {"domain": "world_cell", "x": x, "y": y})
            self.assertEqual(route["destination"]["spawn"], {"domain": "field_pixel", "x": raw[6] * 8, "y": raw[7] * 8})
            self.assertEqual(route["provenance"]["world_table"], hex(table))
            self.assertEqual(route["provenance"]["record_stride"], 14)
            self.assertEqual(maindec.mword(0x8016F37C + 4 * raw[0]), 0x80128730)
        b = self.routes["vb6_r00_e01_to_region_b"]
        c = self.routes["vb6_r06_e01_to_region_c"]
        self.assertEqual(self.data[0x348B0:0x348B9], bytes.fromhex("09 27 10 03 fb 01 56 55 fd"))
        self.assertEqual(self.data[0x350FC:0x35102], bytes.fromhex("03 fb 02 3b 26 fd"))
        self.assertEqual(b["destination"]["spawn"], {"domain": "world_cell", "x": 86, "y": 85})
        self.assertEqual(c["destination"]["spawn"], {"domain": "world_cell", "x": 59, "y": 38})
        self.assertEqual(b["origin"]["trigger"]["rectangle"], {"domain": "field_pixel", "x": 224, "y": 360, "w": 80, "h": 8})
        self.assertEqual(c["origin"]["trigger"]["rectangle"], {"domain": "field_pixel", "x": 360, "y": 0, "w": 8, "h": 384})
        ptr = lambda offset: struct.unpack_from("<I", self.data, offset)[0] - BASE
        for route, room, region_index in ((b, 0, 1), (c, 6, 2)):
            entity = ptr(ptr(ptr(0) + 8) + room * 16) + 24
            self.assert_unrestricted_rectangle(route, ptr(entity + 16))
            transition = route["provenance"]["transition_offset"]
            spawn = route["destination"]["spawn"]
            self.assertEqual(self.data[transition:transition + 6],
                             bytes((3, 0xFB, region_index, spawn["x"], spawn["y"], 0xFD)))

    def test_prefix_and_e7_original_consumers(self):
        for selector, expected in ((0x6C, 0x445), (0x33, 0x40C)):
            address = 0x80171C2C + 2 * selector
            self.assertEqual(struct.unpack_from("<H", maindec.body(), address - maindec.MBASE)[0], expected)
        self.assertEqual(self.routes["vb6_r00_e00_to_forest_edge"]["effects"][0]["area_index"], 0x445)
        self.assertEqual(self.routes["vb6_r01_e00_to_village"]["effects"][0]["area_index"], 0x40C)
        self.assertEqual(self.data[0x348B0:0x348B3], bytes((9, 39, 0x10)))
        assert_words({
            0x80171718 + 4 * 9: (0x8013CBBC,),
            0x8013CBF8: (0x00431025, 0x03E00008, 0xA0820190),
        })
        self.assertEqual(self.routes["vb6_r00_e01_to_region_b"]["effects"][0]["flag"],
                         {"id": "scenario_0039", "mask": 0x10})

        e7 = self.routes["vb6_r06_e07_same_room_reconstruction"]
        self.assertEqual(len(e7["effects"]), 12)
        self.assertEqual([row["kind"] for row in e7["effects"]], [
            "glyph_descriptor_display", "glyph_descriptor_display", "queue_track",
            "wait_text_queue_empty", "descriptor_state_transition", "open_dialogue_box",
            "start_or_wait_dialogue", "dialogue", "wait_for_accept", "close_dialogue_box",
            "wait_event_flags_low2_clear", "story_or",
        ])
        self.assertEqual(e7["effects"][2]["track"]["commands"],
                         [{"kind": "move", "direction": "right", "cells": 22}, {"kind": "finish"}])
        self.assertEqual(e7["effects"][-1]["source_offset"], 0x35181)
        self.assertEqual(e7["provenance"]["transition_offset"], 0x35184)
        self.assertEqual(e7["destination"]["source_spawn"], {"domain": "half_cell", "x": 27, "y": 25})
        self.assertTrue(e7["reconstruction"]["same_room"])
        self.assertEqual(e7["reconstruction"]["construction_story"], "current_after_prefix_effects")
        self.assertEqual(e7["continuation"], {"kind": "ordinary_source_selection", "automatic_program_id": None})
        ptr = lambda offset: struct.unpack_from("<I", self.data, offset)[0] - BASE
        room_record = ptr(ptr(0) + 8) + 6 * 16
        entity = ptr(room_record) + 7 * 24
        self.assertEqual(entity, e7["provenance"]["entry_offset"])
        predicate = ptr(entity + 16)
        self.assertEqual(self.data[predicate:predicate + 7], bytes((8, 15, 0x40, 7, 15, 0x20, 6)))
        self.assertEqual(self.data[0x35181:0x35189], bytes((9, 15, 0x40, 3, 6, 27, 25, 0xFD)))

    def test_language_neutral_fixture_and_generated_outputs(self):
        fixture = self.exported["fixtures"]
        self.assertEqual(fixture["packet_content_sha256"], self.packet["content_sha256"])
        self.assertEqual(len(fixture["cases"]), 14)
        disk = json.loads((ROOT / "game/tests/fixtures/route_transitions.json").read_text())
        self.assertEqual(disk, fixture)
        self.assertEqual(json.loads((ROOT / "game/assets/routes/region_b_vb6_c.json").read_text()), self.packet)
        expected = exporter.output_bytes(self.exported)
        self.assertEqual(set(expected), set(exporter.OUTPUTS))
        for relative, data in expected.items():
            self.assertEqual((ROOT / relative).read_bytes(), data, relative)
        exporter.validate_packet(self.packet)

    def test_malformed_references_predicates_and_coordinates_fail_closed(self):
        changed = copy.deepcopy(self.packet)
        changed["routes"][0]["destination"]["location_id"] = "missing"
        with self.assertRaises(exporter.RouteError):
            exporter.validate_packet(self.reidentified(changed))
        changed = copy.deepcopy(self.packet)
        changed["routes"][1]["destination"]["spawn"]["x"] += 8
        with self.assertRaises(exporter.RouteError):
            exporter.validate_packet(self.reidentified(changed))
        changed = copy.deepcopy(self.packet)
        changed["routes"][1]["id"] = changed["routes"][0]["id"]
        with self.assertRaises(exporter.RouteError):
            exporter.validate_packet(self.reidentified(changed))
        changed = copy.deepcopy(self.packet)
        changed["routes"][24]["conditions"][0]["flag"]["id"] = "scenario_0016"
        with self.assertRaises(exporter.RouteError):
            exporter.validate_packet(self.reidentified(changed))
        changed = copy.deepcopy(self.packet)
        changed["routes"][24]["continuation"]["automatic_program_id"] = "vb6_r06_entity09_followon"
        with self.assertRaises(exporter.RouteError):
            exporter.validate_packet(self.reidentified(changed))
        changed = copy.deepcopy(self.packet)
        changed["content_sha256"] = "0" * 64
        with self.assertRaises(exporter.RouteError):
            exporter.validate_packet(changed)

    def test_deterministic_generation_check_and_stale_missing_rejection(self):
        with tempfile.TemporaryDirectory(prefix="route-transition-test-") as temporary:
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

    def run_cli(self, output_root, check=False):
        command = [sys.executable, "-B", str(ROOT / "kit/tools/export_route_transitions.py"),
                   "--output-root", str(output_root)]
        if check:
            command.append("--check")
        return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False,
                              env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))


if __name__ == "__main__":
    unittest.main()
