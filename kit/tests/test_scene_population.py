#!/usr/bin/env python3
"""Source and reproducibility gates for the scene-population compiler."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
sys.path.insert(0, str(ROOT / "kit/tests"))

import area_scene as scene
import export_scene_population as compiler
import maindec
from export_first_room import source
from test_canonical_start import assert_main_words
from test_opening_events import assert_span

BASE = 0x80010000


def selected(packet: dict, story: bytes, active_party_count: int = 0) -> list[str]:
    result = []
    for entity in packet["entities"]:
        if not entity["population_candidate"]:
            continue
        classification = entity["classification"]
        if classification["pointer_state"] == "null":
            continue
        eligible = True
        for term in classification["terms"]:
            if term["kind"] == "unsupported":
                raise ValueError(f"unsupported classification for {entity['id']}")
            index = int(term["flag"]["id"][9:])
            present = bool(story[index] & term["flag"]["mask"])
            if present != (term["kind"] == "story_mask_set"):
                eligible = False
                break
        if eligible:
            result.append(entity["id"])
    return result


class ScenePopulationSources(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.exported = compiler.export()
        cls.packets = cls.exported["packets"]
        cls.sources = {}
        cls.records = {}
        cls.entities = {}
        for suffix, room, packet_id in compiler.ROOMS:
            data, proof = source(suffix)
            record = scene.room_record(data, room)
            cls.sources[packet_id] = data
            cls.records[packet_id] = record
            cls.entities[packet_id] = scene.entities(data, record)

    def original_classification(self, packet_id: str, index: int, story: bytes) -> int:
        cursor = self.entities[packet_id][index]['stream_offsets'][0]
        if cursor is None:
            return 1
        return 0 if self.story_predicate(packet_id, cursor, story) else 2

    def story_predicate(self, packet_id: str, cursor: int, story: bytes) -> bool:
        data = self.sources[packet_id]
        for _ in range(64):
            opcode = data[cursor]
            if opcode == 6:
                return True
            self.assertIn(opcode, (7, 8))
            index, mask = data[cursor + 1:cursor + 3]
            if bool(story[index] & mask) != (opcode == 7):
                return False
            cursor += 3
        self.fail(f'Unterminated story predicate for {packet_id}')

    def test_deterministic_reexport_current_outputs_and_content_identities(self):
        repeated = compiler.export()
        for name in ("packets", "report", "registry", "bounds_invalid"):
            self.assertEqual(self.exported[name], repeated[name])
        for packet_id, packet in self.packets.items():
            recorded = packet["content_sha256"]
            packet_copy = dict(packet)
            packet_copy["content_sha256"] = ""
            self.assertEqual(recorded, hashlib.sha256(compiler.canonical(packet_copy)).hexdigest())
            for prefix in ("game/assets/scenes/population", "game/tests/fixtures/scene_population"):
                saved = json.loads((ROOT / prefix / f"{packet_id}.json").read_text())
                self.assertEqual(saved, packet)
        self.assertEqual(json.loads((ROOT / "kit/data/reports/scene_population.json").read_text()), self.exported["report"])
        registry_lines = (ROOT / "kit/data/registry/extract_scene_population.jsonl").read_text().splitlines()
        self.assertEqual([json.loads(line) for line in registry_lines], self.exported["registry"])
        with tempfile.TemporaryDirectory() as tmpdir:
            mirror = Path(tmpdir) / "repro"
            compiler.write_tree(mirror)
            for relative in (
                "game/assets/scenes/population/vaa_room2.json",
                "game/assets/scenes/population/vb6_room6.json",
                "kit/data/reports/scene_population.json",
                "kit/data/registry/extract_scene_population.jsonl",
            ):
                self.assertEqual((mirror / relative).read_bytes(), (ROOT / relative).read_bytes())

    def test_independent_raw_room_walk_preserves_every_record_and_order(self):
        for _suffix, room, packet_id in compiler.ROOMS:
            data = self.sources[packet_id]
            ptr = lambda offset: (lambda value: value - BASE if value else 0)(struct.unpack_from("<I", data, offset)[0])
            room_table = ptr(ptr(0) + 8)
            record_offset = room_table + room * 16
            entity_array = ptr(record_offset)
            count = data[record_offset + 4]
            packet = self.packets[packet_id]
            self.assertEqual(len(packet["entities"]), count)
            self.assertEqual([entity["source_order"] for entity in packet["entities"]], list(range(count)))
            for index, entity in enumerate(packet["entities"]):
                offset = entity_array + index * 24
                x, y, flags, source_id = struct.unpack_from("<HHHH", data, offset)
                pointers = [ptr(offset + field) for field in (12, 16, 20)]
                self.assertEqual((entity["position"]["source_x"], entity["position"]["source_y"]), (x, y))
                self.assertEqual(entity["source_character_id"], source_id or None)
                self.assertEqual(entity["population_candidate"], bool(source_id and flags & 0x101))
                self.assertEqual(entity["record_role"] == "initialization", bool(flags & 0x10))
                self.assertEqual(entity["classification"]["pointer_state"] == "null", pointers[0] == 0)
                self.assertEqual(entity["event_selection"]["pointer_state"] == "null", pointers[1] == 0)
                proof = self.exported["report"]["rooms"][packet_id]["entities"][index]
                self.assertEqual((proof["entry_offset"], proof["event_stream_offset"]), (offset, pointers[2]))
            self.assertEqual(packet["source"]["sha256"], hashlib.sha256(data).hexdigest())

    def test_original_classification_consumers_match_all_population_states(self):
        assert_span(0x8013D8E0, 0x8013DB6C, '50e2ed023ff810a38121677f0a538cd6f36e04370b95e63116b90bfe36aa88a5')
        assert_span(0x8013D6CC, 0x8013D788, '100d180a2e7e89be2b85ae1e8a513a0e1ce570deb4fffcc508a7c41bdbe9ef2c')
        assert_main_words({0x800C19B4: (0x8013D95C, 0x8013D974)})
        cases = {
            "vaa_room2": (0, 32, 64, 96, 255),
            "vb6_room6": (0, 8, 40, 255),
        }
        for packet_id, values in cases.items():
            packet = self.packets[packet_id]
            for value in values:
                story = bytearray(240)
                if packet_id == "vaa_room2":
                    story[0] = value
                else:
                    story[15] = value
                    story[19] = value
                expected = selected(packet, story)
                original = []
                for entity in packet["entities"]:
                    if not entity["population_candidate"]:
                        continue
                    index = entity["source_order"]
                    result = self.original_classification(packet_id, index, story)
                    self.assertIn(result, (0, 1, 2))
                    if result == 0:
                        original.append(entity["id"])
                self.assertEqual(original, expected, (packet_id, value))
        self.assertEqual(len(selected(self.packets["vaa_room2"], bytes(240))), 14)
        story = bytearray(240)
        story[0] = 64
        self.assertEqual(len(selected(self.packets["vaa_room2"], story)), 13)
        story = bytearray(240)
        self.assertEqual(len(selected(self.packets["vb6_room6"], story)), 23)
        story[19] = 8
        self.assertEqual(len(selected(self.packets["vb6_room6"], story)), 26)

    def test_original_resource_lookup_and_party_fallback_domains(self):
        assert_span(0x801346A8, 0x801347CC, '4a96a40443056e6059a3b13f5f3b719f06e8b655936b04a2ae95e91489f6441f')
        for _suffix, _room, packet_id in compiler.ROOMS:
            data = self.sources[packet_id]
            record = self.records[packet_id]
            section = scene.section_off(data, record["section"])
            bindings = scene.character_bindings(data, section)
            def word(offset):
                return struct.unpack_from('<I', data, offset)[0]

            names, contexts = word(section + 0x34) - BASE, word(section + 0x20) - BASE
            original = {}
            for offset in range(0, 4 * scene.MAX_CONTEXTS, 4):
                record_pointer = word(names + offset)
                if record_pointer == 0:
                    break
                original[word(record_pointer - BASE)] = word(contexts + offset + 4) - BASE
            self.assertEqual(original, {cid: binding['context'] for cid, binding in bindings.items()})
            for entity in self.packets[packet_id]["entities"]:
                if entity["source_character_id"] is None:
                    continue
                source_id = entity["source_character_id"]
                if source_id & 0xFF in bindings:
                    self.assertEqual(entity["resource_domain"], "area_character_context")
                    self.assertEqual(entity["resource_id"], f"{packet_id}_character_{source_id & 0xFF:03d}")
                else:
                    self.assertEqual(entity["resource_domain"], "active_party_character")
                    self.assertEqual(entity["resource_id"], f"party_character_{source_id & 0xFF:03d}")
        self.assertEqual(self.packets["vb6_room6"]["entities"][29]["resource_id"], "party_character_008")
        self.assertEqual(self.packets["vb6_room6"]["entities"][32]["resource_id"], "party_character_008")

    def test_original_event_stream_consumers_and_initialization_order(self):
        assert_span(0x8013E17C, 0x8013E210, 'e573cc4f67de4e18af4380c3eedac315e1340817c56738de8e6b2b29eb21dbc7')
        assert_span(0x8013DB6C, 0x8013E028, 'b2667024a22ee484f4985471906c3e3cb6c3f356a2bf65ddd375f6bdf934a845')
        assert_span(0x8013F2A4, 0x8013F37C, '120696f34db1dd4f3a30ac0a2bad05a43beebc8cd46afb71e33780c6a099f673')
        assert_main_words({
            0x800C1A1C: (0x8013DD84, 0x8013DD9C),
            0x8013E1EC: (0x3C028018, 0x8C42A120, 0, 0x8C420014, 0, 0x3C018018, 0xAC22AF84),
        })
        stream_offset = maindec.mword(0x8013E1F8) & 0xFFFF
        for packet_id, packet in self.packets.items():
            data = self.sources[packet_id]
            for entity in packet["entities"]:
                index = entity["source_order"]
                source_entry = self.entities[packet_id][index]
                cursor, = struct.unpack_from('<I', data, source_entry['offset'] + stream_offset)
                self.assertEqual(cursor, BASE + source_entry['stream_offsets'][2])
                if entity["event"]["status"] == "resolved":
                    event_content = json.loads((ROOT / f"game/assets/events/{packet['programs'][0]['content_id']}.json").read_text())
                    self.assertIn(entity["event"]["program_id"], {program["id"] for program in event_content["programs"]})
        initializers = [entity for entity in self.packets["vaa_room2"]["entities"] if entity["record_role"] == "initialization"]
        self.assertEqual([(entity["source_order"], entity["initialization_order"]) for entity in initializers], [(23, 0), (24, 1)])
        for story0, expected in ((0, [23]), (64, [23, 24])):
            selected_programs = []
            for entity in initializers:
                story = bytearray(240)
                story[0] = story0
                source_entry = self.entities['vaa_room2'][entity['source_order']]
                self.assertTrue(source_entry['flags'] & 0x10)
                if self.story_predicate('vaa_room2', source_entry['stream_offsets'][1], story):
                    selected_programs.append(entity["source_order"])
            self.assertEqual(selected_programs, expected)
        self.assertEqual([entity["source_order"] for entity in self.packets["vb6_room6"]["entities"] if entity["record_role"] == "initialization"], [6, 8, 28])

    def test_coordinates_boundaries_placement_and_overflow_are_explicit(self):
        expected_placed = {
            "vb6_room6_entity_33": (216, 144),
            "vb6_room6_entity_34": (272, 232),
            "vb6_room6_entity_35": (64, 192),
        }
        for entity_id, coordinates in expected_placed.items():
            position = next(entity["position"] for entity in self.packets["vb6_room6"]["entities"] if entity["id"] == entity_id)
            self.assertEqual((position["x"], position["y"]), coordinates)
            self.assertEqual(position["placement"], "placed")
        staged = [entity for entity in self.packets["vb6_room6"]["entities"] if entity["position"]["placement"] == "off_map_staging"]
        self.assertEqual(len(staged), 23)
        self.assertTrue(all((entity["position"]["x"], entity["position"]["y"]) == (2032, 2032) for entity in staged))
        for source_xy, expected in ((0, 0), (1, 8), (254, 2032), (255, 2040)):
            self.assertEqual(compiler.convert_position(source_xy, source_xy, 48, 48, True)["x"], expected)
        for invalid in (-1, 256, 65535):
            with self.assertRaises(ValueError):
                compiler.convert_position(invalid, 0, 48, 48, True)
        invalid = self.exported["bounds_invalid"]
        changed = next(entity for entity in invalid["entities"] if entity["position"]["source_x"] == 256)
        self.assertEqual(changed["position"]["x"], 2048)
        self.assertEqual(maindec.mword(0x8012EF88), 0x92840000)
        self.assertEqual(maindec.mword(0x8012EFB4), 0x9204FFFA)
        self.assertEqual(maindec.mword(0x801317D8), 0x000528C0)
        self.assertEqual(maindec.mword(0x801317EC), 0x000420C0)

    def test_party_count_inputs_do_not_change_either_classification(self):
        for packet in self.packets.values():
            for count in (0, 1, 3, 6):
                story = bytearray(240)
                if packet["id"] == "vb6_room6":
                    story[19] = 8
                self.assertEqual(selected(packet, story, count), selected(packet, story, 0))
        data = self.sources["vb6_room6"]
        assert_main_words({0x80171718 + 4 * 0x3B: (0x80139CAC,)})
        assert_span(0x80139CAC, 0x80139E18, '927a93830d4d4082154e8e640dd5532848e95341af1acb0b764b320569afefb3')
        opcode, required_count = data[0x3512B:0x3512D]
        self.assertEqual(opcode, 0x3B)
        required = list(data[0x3512D:0x3512D + required_count])
        present = [13, 12, 11, 4, 2, 8]
        for count, expected in ((3, [8, 2, 4, 255, 255, 255]), (6, [8, 2, 4, 13, 12, 11])):
            ordered = required + [member for member in present if member not in required]
            self.assertEqual(ordered[:count] + [255] * (6 - count), expected)

    def test_unknown_semantics_and_changed_resolved_references_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "unsupported event predicate opcode"):
            compiler.decode_predicate(bytes((0x25, 0x06)), 0, "event")
        with self.assertRaisesRegex(ValueError, "truncated classification predicate"):
            compiler.decode_predicate(bytes((0x07, 0, 1)), 0, "classification")
        key = ("VAA.BIN", 2, 22)
        original = compiler.KNOWN_PROGRAMS[key]
        try:
            program_id, content_id, trigger, _offset = original
            compiler.KNOWN_PROGRAMS[key] = (program_id, content_id, trigger, 0)
            with self.assertRaisesRegex(ValueError, "resolved event reference mismatch.*entity 22"):
                compiler.compile_room("/VAA.BIN", 2, "vaa_room2")
        finally:
            compiler.KNOWN_PROGRAMS[key] = original

    def test_report_registry_and_helper_provenance_are_current(self):
        report = self.exported["report"]
        for name, recorded in report["helpers_sha256"].items():
            self.assertEqual(recorded, hashlib.sha256((ROOT / "kit/tools" / name).read_bytes()).hexdigest(), name)
        for packet_id, packet in self.packets.items():
            self.assertEqual(report["rooms"][packet_id]["packet_content_sha256"], packet["content_sha256"])
            self.assertEqual(report["rooms"][packet_id]["source"]["sha256"], hashlib.sha256(self.sources[packet_id]).hexdigest())
            for proof in report["rooms"][packet_id]["entities"]:
                self.assertLess(proof["entry_offset"], len(self.sources[packet_id]))
                self.assertLess(proof["event_stream_offset"], len(self.sources[packet_id]))
        self.assertEqual([row["id"] for row in self.exported["registry"]], ["SPOP01", "SPOP02", "SPOP03"])
        self.assertTrue(all(row["evidence"] == "proven" for row in self.exported["registry"]))


if __name__ == "__main__":
    unittest.main()
