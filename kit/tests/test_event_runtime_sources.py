#!/usr/bin/env python3
"""Static source and export checks for the bounded event execution module."""
from pathlib import Path
import hashlib
import json
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
for parent in Path(__file__).resolve().parents:
    if (parent / "kit/tools/event_vm_semantics.py").is_file():
        REPO = parent
        break
else:
    raise RuntimeError("cannot locate source test helpers")
sys.path.insert(0, str(ROOT / "kit/tools"))
sys.path.insert(0, str(REPO / "kit/tools"))

import event_vm_semantics
import export_events
import maindec
import vb6_arrival
from export_first_room import source


class EventRuntimeSources(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vaa, cls.vb6, cls.report = export_events.export()

    def assert_main_words(self, expected):
        for address, word in expected.items():
            self.assertEqual(maindec.mword(address), word, f"MAIN.EXE {address:#010x}")

    def test_versioned_export_identity_and_current_files(self):
        for content, count in ((self.vaa, 3), (self.vb6, 1)):
            self.assertEqual(content["schema"], "suikoden-event-ir/1")
            self.assertEqual(len(content["programs"]), count)
            recorded = content["content_sha256"]
            content["content_sha256"] = ""
            self.assertEqual(recorded, hashlib.sha256(export_events.canonical(content)).hexdigest())
            content["content_sha256"] = recorded
            self.assertEqual(content, json.loads((ROOT / f"game/assets/events/{content['id']}.json").read_text()))
        catalog = json.loads((ROOT / "game/assets/events/catalog.json").read_text())
        self.assertEqual(catalog["schema"], "suikoden-event-catalog/1")
        self.assertEqual([row["id"] for row in catalog["programs"]], ["vaa_audience_choice", "vb6_room6_arrival"])
        self.assertEqual(json.loads((ROOT / "kit/data/reports/event_runtime.json").read_text()), self.report)

    def test_vaa_reuses_complete_source_slice_and_exact_entry(self):
        original, proof = export_events.opening_audience.export()
        program = self.vaa["programs"][0]
        self.assertEqual(program["id"], "vaa_room2_audience")
        self.assertEqual(program["entity"], 22)
        self.assertEqual(program["trigger"], "interaction")
        self.assertEqual(program["conditions"], [{"kind": "story_mask_clear", "flag": {"id": "scenario_0000", "mask": 64}}])
        self.assertEqual(len(program["commands"]), 201)
        self.assertEqual(len(self.vaa["tracks"]), 19)
        self.assertEqual(len(self.vaa["texts"]), 22)
        self.assertEqual([export_events.convert_vaa_command(row) for row in original["commands"]], program["commands"])
        self.assertEqual(self.report["vaa"]["entry"]["stream_offset"], 0x50D80)
        self.assertEqual(proof["source"]["sha256"], self.report["vaa"]["source"]["sha256"])
        initializers, _ = export_events.opening_events.export()
        self.assertEqual([p["id"] for p in self.vaa["programs"][1:]], initializers["initialization_order"])
        self.assertEqual(self.vaa["programs"][2]["conditions"], [{"kind": "story_mask_set", "flag": {"id": "scenario_0000", "mask": 64}}])

    def test_original_vaa_choice_and_story_write_consumers(self):
        data, _ = source("/VAA.BIN")
        handlers = event_vm_semantics.handler_table()
        self.assertEqual(handlers[0x05], 0x8013BCDC)
        self.assertEqual(handlers[0x09], 0x8013CBBC)
        self.assertEqual(data[0x50EE0:0x50EE4], bytes.fromhex("05 00 02 01"))
        # Direction wraps the index and rewinds the cursor. Confirm publishes the
        # selected byte, resets the choice latch and advances the cursor.
        self.assert_main_words({
            0x8013BDDC: 0x00822821, 0x8013BDE0: 0x30635041,
            0x8013BDE4: 0x34021000, 0x8013BDE8: 0x1062000F,
            0x8013BE00: 0x2C620040, 0x8013BE10: 0x34110001,
            0x8013BE14: 0x34024000, 0x8013BE18: 0x1062000E,
            0x8013BE40: 0x24A2FFFF, 0x8013BE50: 0x2442FFFF,
            0x8013BE60: 0x10620005, 0x8013BE64: 0x00801021,
            0x8013BE74: 0x24420001, 0x8013BE7C: 0xA022C018,
            0x8013BF04: 0x14400009, 0x8013BF08: 0x340200FF,
            0x8013BF18: 0x2442FFFD, 0x8013BF20: 0xAC22AF84,
            0x8013BF38: 0x90A5C018, 0x8013BF48: 0xA022C018,
            0x8013BF4C: 0x24630001, 0x8013BF54: 0xAC23AF84,
            0x8013BF5C: 0xA025BD6C,
        })
        evidence = self.report["vaa"]["audience"]["instructions"]
        completion = next(row for row in evidence if row.get("opcode") == 9 and row.get("operands") == "0040")
        offset = completion["offset"]
        self.assertEqual(data[offset:offset + 3], bytes.fromhex("09 00 40"))
        self.assert_main_words({
            0x8013CBD8: 0x90650000, 0x8013CBDC: 0x24620002,
            0x8013CBE4: 0xAC22AF84, 0x8013CBE8: 0x90630001,
            0x8013CBEC: 0x00852021, 0x8013CBF0: 0x90820190,
            0x8013CBF8: 0x00431025, 0x8013CC00: 0xA0820190,
        })

    def test_vb6_corrected_packet_is_complete_dependency(self):
        packet = vb6_arrival.export()
        self.assertEqual(len(packet["entities"]), 26)
        self.assertTrue(all(row["event_stream"] == "inventory_only" for row in packet["entities"]))
        self.assertNotIn(5, vb6_arrival.CHARACTER_INDICES)
        arrival = packet["first_arrival"]
        self.assertEqual(len(arrival["ordered_actions"]), 28)
        self.assertEqual(arrival["ordered_actions"][1]["requested_prefix"], [8, 2, 4])
        self.assertTrue(arrival["state_writes"][0]["preserves_unlisted_existing_members"])
        self.assertEqual(arrival["state_writes"][0]["active_count_source"], "MAIN:*(0x8017C164)+3")
        self.assertEqual(arrival["state_writes"][0]["backfill_bound"], "logical_active_count")
        self.assertEqual(arrival["state_writes"][0]["unused_slot_sentinel"], 255)
        self.assertEqual(arrival["ordered_actions"][10]["parameter"], 2)
        self.assertEqual(arrival["ordered_actions"][17]["parameter"], 3)
        self.assertEqual(self.vb6["programs"][0]["conditions"], [
            {"kind": "story_mask_clear", "flag": {"id": "scenario_0015", "mask": 32}},
            {"kind": "story_mask_set", "flag": {"id": "scenario_0015", "mask": 8}},
        ])
        self.assertEqual([export_events.convert_vb6_action(row) for row in arrival["ordered_actions"]],
                         self.vb6["programs"][0]["commands"])

    def test_vb6_actor_coordinates_use_eight_pixel_source_units(self):
        actors = {actor["id"]: actor for actor in self.vb6["actors"]}
        placed = {
            "vb6_r06_e33_char_154": (216, 144),
            "vb6_r06_e34_char_154": (272, 232),
            "vb6_r06_e35_char_153": (64, 192),
        }
        for actor_id, coordinates in placed.items():
            self.assertEqual((actors[actor_id]["x"], actors[actor_id]["y"]), coordinates)
        staged = [actor for actor_id, actor in actors.items() if actor_id not in placed]
        self.assertEqual(len(staged), 23)
        for actor in staged:
            self.assertEqual((actor["x"], actor["y"]), (2032, 2032), actor["id"])

    def test_original_vb6_gate_party_descriptor_wait_and_story_consumers(self):
        data, _ = source("/VB6.BIN")
        entries = export_events.scene.entities(data, export_events.scene.room_record(data, 6))
        _, gate, ordinary = entries[5]["stream_offsets"]
        self.assertEqual(data[gate:gate + 8], bytes.fromhex("08 0f 20 07 0f 08 06 00"))
        self.assertEqual(data[ordinary + 3:ordinary + 8], bytes.fromhex("3b 03 08 02 04"))
        self.assertEqual(data[0x3513D:0x35141], bytes.fromhex("46 11 40 03"))
        self.assertEqual(data[0x3514D:0x35150], bytes.fromhex("11 41 01"))
        self.assertEqual(data[0x3515E:0x35161], bytes.fromhex("09 0f 20"))
        handlers = event_vm_semantics.handler_table()
        self.assertEqual([handlers[op] for op in (0x3B, 0x46, 0x11, 0x09)],
                         [0x80139CAC, 0x80139798, 0x8013CE08, 0x8013CBBC])
        # The selector short-circuits on a failed story mask before the accept marker.
        self.assert_main_words({
            0x8013DBF0: 0x8C500010, 0x800C1A1C: 0x8013DD84,
            0x800C1A20: 0x8013DD9C, 0x8013DD88: 0x34050001,
            0x8013DD8C: 0x0C04F5B3, 0x8013DD90: 0x34060001,
            0x8013DDA0: 0x00002821, 0x8013DDA4: 0x0C04F5B3,
            0x8013DDA8: 0x34060001, 0x8013D70C: 0x90430190,
            0x8013D724: 0x00621024, 0x8013D728: 0x10400008,
            0x8013D740: 0x00621024, 0x8013D744: 0x1040FFFA,
            0x8013DE28: 0x16000076, 0x8013E008: 0x34020006,
            0x8013E014: 0x34020001,
        })
        # Slot clearing spans six entries. Prefix and backfill use the saved
        # active count, and only unlisted IDs are copied back.
        self.assert_main_words({
            0x80139CE4: 0x90420089, 0x80139CEC: 0xA0820000,
            0x80139D00: 0xA0450089, 0x80139D08: 0x28E20006,
            0x80139D18: 0x8C42C164, 0x80139D20: 0x90420003,
            0x80139DB8: 0xA0430089, 0x80139DBC: 0x340200FF,
            0x80139DD4: 0x1448FFF4, 0x80139DF4: 0x90420003,
            0x80139DFC: 0x00E2102A,
        })
        # Low two flag bits keep the cursor on 0x46. The descriptor table
        # selects AND 1 or OR 2 on the descriptor's flag byte.
        self.assert_main_words({
            0x8013979C: 0x9442C028, 0x801397A4: 0x30420003,
            0x801397A8: 0x10400007, 0x801397BC: 0x2442FFFF,
            0x801397C4: 0xAC22AF84, 0x8013CE44: 0x24211B98,
            0x8013CE4C: 0x8C250000, 0x8013CE50: 0x0C04F33C,
            0x80171B9C: 3, 0x80171BA4: 2,
            0x8013CDDC: 0x30420001, 0x8013CDE8: 0x34420002,
            0x8013CDEC: 0xA0820004, 0x8013CBF8: 0x00431025,
            0x8013CC00: 0xA0820190,
        })

    def test_source_helper_hashes_and_address_conversion_are_separate(self):
        for name, recorded in self.report["helpers_sha256"].items():
            self.assertEqual(recorded, hashlib.sha256((REPO / "kit/tools" / name).read_bytes()).hexdigest(), name)
        self.assertEqual(self.report["vaa"]["source"]["sha256"], hashlib.sha256(source("/VAA.BIN")[0]).hexdigest())
        self.assertEqual(self.report["vb6"]["packet"]["source"]["sha256"], hashlib.sha256(source("/VB6.BIN")[0]).hexdigest())
        self.assertIn("0x80010000", self.report["address_conversion"]["VAA/VB6"])
        self.assertIn("2048", self.report["address_conversion"]["MAIN.EXE"])
        for content in (self.vaa, self.vb6):
            serialized = json.dumps(content)
            self.assertNotIn("operands", serialized)
            self.assertNotIn("stream_offset", serialized)
            self.assertNotIn("helpers_sha256", serialized)


if __name__ == "__main__":
    unittest.main()
