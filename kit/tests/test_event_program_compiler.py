#!/usr/bin/env python3
"""Focused source/consumer checks for the reusable frozen event compiler."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
sys.path.insert(0, str(ROOT / "kit/tests"))

import area_scene as scene
import compile_event_programs as compiler
import maindec
import war_text
from export_first_room import source
from test_entity_predicates import assert_words, check_dispatch


class EventProgramCompiler(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiled = compiler.compile_sources()
        cls.result = compiler.compile_selection()

    def run_cli(self, directory: Path, programs=compiler.POSITIVE_PROGRAMS):
        output = directory / "packets"
        report = directory / "report.json"
        command = [sys.executable, "-B", "kit/tools/compile_event_programs.py",
                   "--output", str(output), "--report", str(report)]
        for program in programs:
            command.extend(("--program", program))
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        completed = subprocess.run(command, cwd=ROOT, env=environment,
                                   text=True, capture_output=True, check=False)
        return completed, output, report

    def test_positive_programs_match_accepted_content_and_identity(self):
        self.assertTrue(self.result["success"], self.result["failures"])
        self.assertEqual(self.result["emit_ids"], [compiler.VAA_CONTENT, compiler.VB6_CONTENT])
        expected_programs = {
            compiler.VAA_CONTENT: [compiler.AUDIENCE, compiler.INIT_23, compiler.INIT_24],
            compiler.VB6_CONTENT: [compiler.ARRIVAL],
        }
        for content_id, program_ids in expected_programs.items():
            content = self.result["contents"][content_id]
            baseline_path = ROOT / f"game/assets/events/{content_id}.json"
            baseline = json.loads(baseline_path.read_text())
            self.assertEqual(content, baseline)
            self.assertEqual([row["id"] for row in content["programs"]], program_ids)
            self.assertTrue(self.result["baseline"][content_id]["exact_complete_content_match"])
            recorded = content["content_sha256"]
            unsigned = dict(content, content_sha256="")
            self.assertEqual(recorded, hashlib.sha256(compiler.canonical(unsigned)).hexdigest())
        audience = self.result["contents"][compiler.VAA_CONTENT]
        self.assertEqual(len(audience["programs"][0]["commands"]), 201)
        self.assertEqual(len(audience["tracks"]), 19)
        self.assertEqual(len(audience["texts"]), 22)
        self.assertEqual(len(self.result["contents"][compiler.VB6_CONTENT]["programs"][0]["commands"]), 28)

    def test_shared_lowerings_cover_every_source_instruction(self):
        for content_id, proof in self.compiled["proofs"].items():
            for program_proof in proof["programs"]:
                program = next(row for row in self.compiled["contents"][content_id]["programs"]
                               if row["id"] == program_proof["id"])
                self.assertEqual(len(program["commands"]), len(program_proof["instructions"]), program["id"])
                self.assertTrue(all(row["offset"] >= 0 and row["opcode"] >= 0
                                    for row in program_proof["instructions"]))
        common = {"align_hero", "open_box", "text", "wait_for_accept", "close_box", "story_or", "end_stream"}
        vaa_kinds = {row["kind"] for row in self.compiled["contents"][compiler.VAA_CONTENT]["programs"][0]["commands"]}
        vb6_kinds = {row["kind"] for row in self.compiled["contents"][compiler.VB6_CONTENT]["programs"][0]["commands"]}
        self.assertTrue(common <= vaa_kinds & vb6_kinds)
        lowering = compiler.FrozenLowering("witness")
        self.assertEqual(lowering.command({"kind": "wait_confirm"}), {"kind": "wait_for_accept"})
        self.assertEqual(lowering.command({"kind": "wait_event_flags_low2_clear"}),
                         {"kind": "wait_event_flags_low2"})
        self.assertEqual(lowering.command({"kind": "select_cue", "cue": 129}), {"kind": "cue", "cue": 129})

    def test_vaa_original_choice_story_and_initializer_consumers(self):
        data, _ = source("/VAA.BIN")
        self.assertEqual(data[0x50D80:0x50D83], bytes.fromhex("10 3e 4e"))
        self.assertEqual(data[0x50EE0:0x50EE5], bytes.fromhex("05 00 02 01 18"))
        assert_words({
            0x80171718 + 4 * 5: (0x8013BCDC,),
            # While waiting, restore the opcode cursor. Confirmation closes the selection.
            0x8013BF18: (0x2442FFFD, 0x3C018018, 0xAC22AF84, 0x0804EFE0),
            0x8013BF48: (0xA022C018, 0x24630001, 0x3C018018, 0xAC23AF84, 0x3C018018, 0xA025BD6C),
        })
        audience, init_23, init_24 = self.compiled["contents"][compiler.VAA_CONTENT]["programs"]
        choice, = [command for command in audience["commands"] if command["kind"] == "choice"]
        self.assertEqual((choice["options"], choice["box"]), tuple(data[0x50EE2:0x50EE4]))

        vaa_proof = self.compiled["proofs"][compiler.VAA_CONTENT]
        audience_proof = next(row for row in vaa_proof["programs"] if row["id"] == compiler.AUDIENCE)
        completion = next(row for row in audience_proof["instructions"]
                          if row["opcode"] == 9 and row["operands"] == "0040")
        offset = completion["offset"]
        self.assertEqual(data[offset:offset + 3], bytes((9, 0, 0x40)))
        write, = [command for command in audience["commands"] if command["kind"] == "story_or"]
        self.assertEqual(write["flag"], {"id": "scenario_0000", "mask": 0x40})

        entries = scene.entities(data, scene.room_record(data, 2))
        check_dispatch()
        self.assertEqual(data[entries[23]["stream_offsets"][1]], 6)
        predicate = entries[24]["stream_offsets"][1]
        self.assertEqual(data[predicate:predicate + 4], bytes((7, 0, 0x40, 6)))
        self.assertEqual(init_23["conditions"], [])
        self.assertEqual(init_24["conditions"], [{"kind": "story_mask_set", "flag": write["flag"]}])

    def test_vb6_original_arrival_followon_guards_and_terminal_writes(self):
        data, _ = source("/VB6.BIN")
        entries = scene.entities(data, scene.room_record(data, 6))
        check_dispatch()
        cases = {
            5: ((8, 0, 1), (0, 0, 0), (0x20, 0, 0), (0x28, 0, 0), (0x88, 0, 1)),
            7: ((0x20, 0, 1), (0x60, 0, 0), (0, 0, 0), (0x40, 0, 0), (0xA0, 0, 1)),
            9: ((0x40, 0, 1), (0x40, 1, 0), (0, 0, 0), (0x60, 0, 1), (0x40, 2, 1)),
        }
        for entity, rows in cases.items():
            predicate = entries[entity]["stream_offsets"][1]
            clear, clear_byte, clear_mask, required, required_byte, required_mask, end = data[predicate:predicate + 7]
            self.assertEqual((clear, required, end), (8, 7, 6))
            for byte15, byte16, accepted in rows:
                story = {15: byte15, 16: byte16}
                self.assertEqual(not story[clear_byte] & clear_mask and bool(story[required_byte] & required_mask),
                                 bool(accepted), (entity, byte15, byte16))
        assert_words({
            0x80171718 + 4 * 9: (0x8013CBBC,),
            # Read the indexed story byte, OR the second operand, and store the result.
            0x8013CBE8: (0x90630001, 0x00852021, 0x90820190, 0, 0x00431025, 0x03E00008, 0xA0820190),
        })
        for offset, index, mask in ((0x3515E, 15, 0x20), (0x35181, 15, 0x40), (0x351D6, 16, 1)):
            self.assertEqual(data[offset:offset + 3], bytes((9, index, mask)))

    def test_inline03_original_consumer_and_descriptor_release(self):
        data, _ = source("/VB6.BIN")
        self.assertEqual(data[0x35184:0x35189], bytes((3, 6, 27, 25, 0xFD)))
        self.assertEqual(data[0x351D2:0x351D4], bytes((0x3A, 0)))
        assert_words({
            0x80171718 + 4 * 3: (0,),
            0x8013E070: (0x34020003, 0x1062000C),
            0x8013E0D0: (0x0C04EFE5,),
            0x8013C144: (0xA0450001,),
            0x8013C174: (0xA4A40004, 0x90630001, 0x0804F08B, 0x34020002),
            0x8013C22C: (0xA4A30006,),
            0x80171718 + 4 * 0x3A: (0x8013C82C,),
            # A loaded ordinary descriptor clears the active byte and puts FE in both indices.
            0x8013C8A4: (0x8C620008, 0, 0x1040000B),
            0x8013C8BC: (0x10620003, 0xA0600005, 0x0804F234, 0x340200FE),
            0x8013C8D0: (0xA0620000, 0x340200FE, 0xA0620001),
        })

    def test_followon_diagnostics_are_precise_and_never_executable(self):
        diagnostics = {row["id"]: row for row in self.compiled["diagnostics"].values()}
        entity7 = diagnostics[compiler.FOLLOWON_7]
        entity9 = diagnostics[compiler.FOLLOWON_9]
        self.assertEqual(entity7["guard"], [
            {"kind": "story_mask_clear", "flag": {"id": "scenario_0015", "mask": 0x40}},
            {"kind": "story_mask_set", "flag": {"id": "scenario_0015", "mask": 0x20}},
        ])
        self.assertEqual(entity9["guard"], [
            {"kind": "story_mask_clear", "flag": {"id": "scenario_0016", "mask": 1}},
            {"kind": "story_mask_set", "flag": {"id": "scenario_0015", "mask": 0x40}},
        ])
        self.assertEqual((entity7["stream_offset"], entity9["stream_offset"]), (0x35164, 0x351A0))
        self.assertEqual(entity7["terminal_story_writes"][0]["flag"], {"id": "scenario_0015", "mask": 0x40})
        self.assertEqual(entity9["terminal_story_writes"][0]["flag"], {"id": "scenario_0016", "mask": 1})
        room_change = next(row for row in entity7["instructions"] if row["opcode"] == 3)
        self.assertEqual(room_change["operands_hex"], "061b19")
        self.assertEqual(room_change["lowering"], "unsupported_frozen_ir")
        self.assertIn("no typed room/coordinate transition", room_change["missing"])
        tracks = [row for row in (*entity7["instructions"], *entity9["instructions"]) if row["opcode"] == 0x32]
        self.assertEqual([row["operands_hex"] for row in tracks], ["00011605", "00031905"])
        self.assertEqual(tracks[0]["track_commands"], [
            {"kind": "move", "direction": "right", "cells": 22}, {"kind": "finish"}])
        self.assertEqual(tracks[1]["track_commands"], [
            {"kind": "move", "direction": "left", "cells": 25}, {"kind": "finish"}])
        release = next(row for row in entity9["instructions"] if row["opcode"] == 0x3A)
        self.assertEqual(release["lowering"], "source_proven_actor_binding_unresolved")
        self.assertEqual(entity9["frontiers"]["frozen_ir"], [])
        for diagnostic in diagnostics.values():
            self.assertTrue(diagnostic["analysis_only"])
            self.assertFalse(diagnostic["executable"])
        selected = compiler.compile_selection(compiler.DIAGNOSTIC_PROGRAMS)
        self.assertFalse(selected["success"])
        self.assertEqual(selected["contents"], {})
        self.assertEqual(selected["emit_ids"], [])

    def test_text_sources_and_helper_provenance(self):
        data, _ = source("/VB6.BIN")
        table = scene.ptr_at(data, scene.ptr_at(data, scene.root(data) + 20))
        pointer = scene.ptr_at(data, table + 3 * 4)
        decoded, _ = war_text.decode(data, pointer)
        self.assertEqual(decoded, "What the...")
        text = next(row for row in self.result["contents"][compiler.VB6_CONTENT]["texts"]
                    if row["id"] == "vb6_text_0_3")
        self.assertEqual(text["tokens"], [{"kind": "glyph", "text": decoded}])
        metadata = compiler.deterministic_metadata(self.result)
        for helper, recorded in metadata["helpers_sha256"].items():
            self.assertEqual(recorded, hashlib.sha256((ROOT / "kit/tools" / helper).read_bytes()).hexdigest())
        self.assertEqual(metadata["source_inputs"][compiler.VB6_CONTENT]["sha256"],
                         hashlib.sha256(data).hexdigest())
        self.assertEqual(maindec.EXE_HEADER, 2048)

    def test_malformed_and_unsupported_inputs_fail_closed(self):
        lowering = compiler.FrozenLowering("witness")
        for actions in ([{"kind": "not_a_source_action"}],
                        [{"kind": "cue", "cue": 129}],
                        [{"kind": "end_stream"}, {"kind": "end_stream"}]):
            with self.assertRaises(compiler.CompilationError):
                lowering.commands(actions, "malformed witness")
        with self.assertRaises(compiler.CompilationError):
            lowering.command({"operands": []})
        with self.assertRaises(compiler.CompilationError):
            compiler.predicate_conditions({"terms": [{"kind": "interaction"}]}, "witness")
        with self.assertRaises(compiler.CompilationError):
            compiler.decode_bounded(b"\x09\x00\x40", 0, "unterminated witness")
        with self.assertRaises(compiler.CompilationError):
            compiler.compile_selection(("not_a_program",))
        with self.assertRaises(compiler.CompilationError):
            compiler.story_value(240)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(compiler.CompilationError):
                compiler.compile_selection(baseline_root=root / "missing-baseline")

    def test_cli_deterministic_regeneration_and_unsupported_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first, first_output, first_report = self.run_cli(root / "one")
            second, second_output, second_report = self.run_cli(root / "two")
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(first_report.read_bytes(), second_report.read_bytes())
            for content_id in (compiler.VAA_CONTENT, compiler.VB6_CONTENT):
                self.assertEqual((first_output / f"{content_id}.json").read_bytes(),
                                 (second_output / f"{content_id}.json").read_bytes())
                self.assertEqual(json.loads((first_output / f"{content_id}.json").read_text()),
                                 json.loads((ROOT / f"game/assets/events/{content_id}.json").read_text()))
            unsupported, unsupported_output, unsupported_report = self.run_cli(
                root / "unsupported", compiler.DIAGNOSTIC_PROGRAMS)
            self.assertEqual(unsupported.returncode, 1, unsupported.stderr)
            self.assertFalse(unsupported_output.exists())
            report = json.loads(unsupported_report.read_text())
            self.assertEqual([row["id"] for row in report["diagnostics"]], list(compiler.DIAGNOSTIC_PROGRAMS))
            self.assertTrue(all(row["analysis_only"] for row in report["diagnostics"]))


if __name__ == "__main__":
    unittest.main()
