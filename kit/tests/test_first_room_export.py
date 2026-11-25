#!/usr/bin/env python3
"""First-room data compared with statically decoded MAIN and source records."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import tempfile
import unittest
import warnings
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
import export_first_room as export
import area_scene as scene
import maindec
from build_script_corpus import load_dialogue
from test_entity_predicates import assert_words, check_dispatch, check_helpers
from test_opening_events import assert_span


BASE = 0x80010000


class FirstRoomTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data, _ = export.source("/VB6.BIN")

    def test_ground_actor_depth_against_instructions_and_bed_overlap(self):
        assert_words({
            # Load actor Y, negate it, store the tag byte, then pass it to the emitter.
            0x8012FE48: (0x92220001, 0, 0x00021023, 0xA2220016, 0x92250016, 0x0C030FBC),
        })
        for y in range(1, 256):
            self.assertEqual(scene.npc_tag(None, None, y), 256 - y)
        with tempfile.TemporaryDirectory() as tmp:
            package = export.export(Path(tmp))
        inn, village = package["rooms"][:2]
        # The native ground rule puts bed tops at tag238 (depth18).
        # Mattress access must preserve that depth, keeping Hero under bedding.
        beds = [d for d in inn["draws"] if d["rect"]["w"] == 32 and d["rect"]["h"] == 48 and d["y"] == 96]
        self.assertEqual(len(beds), 3)
        self.assertTrue(all(d["depth"] == 18 for d in beds))
        self.assertTrue(all(d["depth"] > 112 / 8 for d in beds))
        self.assertTrue(all(d["depth"] <= 144 / 8 for d in beds))
        access = export.mattress_access(self.data, scene.section_off(self.data, 7))
        self.assertEqual(len(access), 6)
        self.assertNotIn("surfaces", inn)
        width, height, original = export.walkable_grid(self.data, scene.section_off(self.data, 7))
        authored = set()
        for surface in access:
            for y in range(surface["y"], surface["y"] + surface["h"], 8):
                for x in range(surface["x"], surface["x"] + surface["w"], 8):
                    index = y // 8 * width + x // 8
                    authored.add(index)
                    self.assertEqual(inn["walkable"][index], "1")
            footboard = (surface["y"] + 32) // 8 * width + surface["x"] // 8 + 1
            self.assertEqual(inn["walkable"][footboard], "0")
        relaxed = {i for i, (before, after) in enumerate(zip(original, inn["walkable"], strict=True)) if before == "0" and after == "1"}
        self.assertTrue(relaxed)
        self.assertLessEqual(relaxed, authored)

    def test_collision_matches_original_ground_queries(self):
        for start, end, digest in (
            (0x8012E308, 0x8012E5A0, 'e9b9a322bea24c2724c1db84ee26646634a639ce714e2ec0d23cb28442d6a829'),
            (0x8012DB9C, 0x8012DC38, '8051a60fa648646667915e050363eaa9eb5847e914c7d22298c56378c37536a3'),
            (0x8012E08C, 0x8012E308, 'c312301765ad7caec40b754b8de746fc996e36b4c2661428ab1cab9877fb1eeb'),
        ):
            assert_span(start, end, digest)
        palace, _ = export.source('/VAA.BIN')
        cases = [(self.data, n) for n in (7, 0, 9, 1, 2, 3, 4, 5)] + [(palace, n) for n in (2, 1)]
        for data, number in cases:
            sec = scene.section_off(data, scene.room_record(data, number)["section"])
            width, height, grid = export.walkable_grid(data, sec)
            def pointer(offset):
                return struct.unpack_from("<I", data, offset)[0] - BASE

            tile_width, tile_height = struct.unpack_from("<HH", data, sec)
            self.assertEqual((width, height), (2 * tile_width, 2 * tile_height))
            tiles, packed = pointer(sec + 0x14), pointer(sec + 0x30)
            count, = struct.unpack_from("<H", data, sec + 0x24)
            masks = []
            if count:
                context = pointer(pointer(sec + 0x20))
                sheets, descriptors = pointer(context + 16), pointer(context + 20)
                records = pointer(sec + 0x28)
                for index in range(count):
                    ox, oy, kind, order, level = data[records + 5 * index:records + 5 * (index + 1)]
                    if order < 2 or level > 1:
                        continue
                    desc = pointer(descriptors + 4 * kind)
                    sheet = pointer(sheets + 4 * data[desc + 4])
                    w, h = (size // 8 for size in data[sheet + 2:sheet + 4])
                    start = sheet + 8 * (1 + data[sheet])
                    masks.append((index + 1, ox, oy, w, h, data[start:start + w * h]))
            objects = export.collision_sources(data, sec)
            for y in range(height - 1):
                for x in range(width - 1):
                    footprint = ((x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1))
                    terrain = 0
                    for bit, (cx, cy) in enumerate(footprint):
                        tile, = struct.unpack_from("<H", data, tiles + 2 * ((cy // 2) * tile_width + cx // 2))
                        shift = 4 * (1 - tile % 2) + 2 * (cy % 2) + cx % 2
                        terrain |= ((data[packed + tile // 2] >> shift) & 1) << bit
                    self.assertEqual(export.terrain_query(data, sec, x, y), terrain)
                    coverage = solid = upper = surface = 0
                    for index, ox, oy, w, h, mask in masks:
                        samples = {bit: mask[(cy - oy) * w + cx - ox]
                                   for bit, (cx, cy) in enumerate(footprint)
                                   if ox <= cx < ox + w and oy <= cy < oy + h}
                        if samples:
                            coverage = sum(1 << bit for bit in samples)
                            solid = sum(1 << bit for bit, value in samples.items() if value & 1)
                            upper = sum(1 << bit for bit, value in samples.items() if value & 2)
                            surface = 0 if solid else index
                            if solid or upper:
                                break
                    query = coverage << 8 | upper << 4 | solid
                    self.assertEqual(export.scenery_query(objects, x, y), (query, surface))
                    blocked = solid | (terrain & ~coverage) if surface and upper & ~solid else (solid & ~upper) | terrain
                    expected = blocked == 0
                    self.assertEqual(grid[y * width + x] == "1", expected, (number, x, y))

    def test_inn_frontage_blocks_only_the_unsupported_raised_strip(self):
        data = self.data
        sec = scene.section_off(data, 0)
        blocked, proof = export.inn_frontage_blockers(data, sec)
        self.assertEqual(blocked, [{"x": x, "y": 248} for x in range(312, 360, 8)])
        # Independently read the actual mask: six raised cells, then a solid wall.
        self.assertEqual(proof["object"], 0x38A9)
        self.assertEqual(data[100012 + 8 + data[100012] * 8 + 11 * 18:][:18], bytes([2] * 6 + [1] * 12))
        with tempfile.TemporaryDirectory() as tmp:
            package = export.export(Path(tmp))
        village = package["rooms"][1]
        width, _, original = export.walkable_grid(data, sec)
        for origin in blocked:
            index = origin["y"] // 8 * width + origin["x"] // 8
            self.assertEqual(original[index], "1")
            self.assertEqual(village["walkable"][index], "0")
        for x in range(304, 416, 8):
            self.assertEqual(village["walkable"][32 * width + x // 8], "1")
        self.assertEqual(village["walkable"][33 * width + 50], "1")
        self.assertEqual(village["walkable"][32 * width + 50], "1")
        # Ground draw order and the inn's existing mattress behavior remain covered
        # by the depth/bed test and the actual-package walkthrough.

    def test_candidate_is_reproducible_and_routes_are_reachable(self):
        with tempfile.TemporaryDirectory() as tmp:
            one, two = Path(tmp) / "one", Path(tmp) / "two"
            package = export.export(one)
            export.export(two)
            for path in one.iterdir():
                self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), hashlib.sha256((two / path.name).read_bytes()).digest(), path.name)
            rooms = {r["id"]: r for r in package["rooms"]}
            inn = rooms["vb6_inn"]
            self.assertEqual([n["id"] for n in inn["npcs"]], ["innkeeper", "patron"])
            self.assertTrue(inn["npcs"][1]["pages"][0].startswith("Can you believe it?"))
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", ResourceWarning)
                self.assertEqual(inn["npcs"][0]["pages"], [load_dialogue()["VB6.BIN", 1, 44][1]])
            self.assertEqual((inn["exits"][0]["room"], inn["exits"][0]["spawn_x"], inn["exits"][0]["spawn_y"]), ("vb6_village", 400, 264))
            for room in rooms.values():
                width = room["width"] // 8
                spawn = {"vb6_inn": (31, 26), "vb6_village": (50, 33), "vb6_shop": (23, 26)}[room["id"]]
                self.assertEqual(room["walkable"][spawn[1] * width + spawn[0]], "1")
                visited, pending = {spawn}, [spawn]
                while pending:
                    x, y = pending.pop()
                    for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                        if (0 <= nx < width and 0 <= ny < room["height"] // 8 and
                                room["walkable"][ny * width + nx] == "1" and (nx, ny) not in visited):
                            visited.add((nx, ny)); pending.append((nx, ny))
                for door in room["exits"]:
                    self.assertTrue(any(door["x"] <= x * 8 < door["x"] + door["w"] and door["y"] <= y * 8 < door["y"] + door["h"] for x, y in visited))
                if room is inn:
                    self.assertIn((36, 15), visited, "innkeeper must be approachable from below")
                    for surface in export.mattress_access(self.data, scene.section_off(self.data, 7)):
                        for y in range(surface["y"], surface["y"] + surface["h"], 8):
                            for x in range(surface["x"], surface["x"] + surface["w"], 8):
                                self.assertIn((x // 8, y // 8), visited, surface["id"])

    def test_doorway_predicates_and_destinations_against_instructions(self):
        check_dispatch()
        check_helpers()
        assert_words({
            0x8013DCEC: (0x9063BD74, 0, 0x0062102B),
            0x8013DD18: (0x9063BD75, 0, 0x0062102B),
            0x8013C144: (0xA0450001,),
            0x8013C174: (0xA4A40004, 0x90630001, 0x0804F08B, 0x34020002),
            0x8013C22C: (0xA4A30006,),
        })
        data = self.data
        for room, index, x, y, keys, destination, prefix in (
                (7, 0, 31, 30, 0, (0, 50, 33), b""),
                (9, 0, 23, 30, 0, (0, 30, 19), b""),
                (0, 4, 30, 18, 0x1000, (9, 23, 26), bytes.fromhex("11 80 00 0e 0a 02")),
                (0, 2, 50, 32, 0x1000, (7, 31, 26), bytes.fromhex("11 80 00 0e 0a 02"))):
            row = scene.room_record(data, room)["record_off"]
            entities, = struct.unpack_from("<I", data, row)
            predicate, stream = struct.unpack_from("<II", data, entities - BASE + 24 * index + 16)
            predicate -= BASE
            stream -= BASE
            x_op, x_min, x_max, y_op, y_min, y_max = data[predicate:predicate + 6]
            self.assertEqual((x_op, y_op), (0x0B, 0x0C))
            self.assertTrue(x_min <= x <= x_max and y_min <= y <= y_max)
            if keys:
                self.assertEqual(data[predicate + 6:predicate + 9], bytes((4, 0, 6)))
                self.assertEqual(maindec.mword(0x80171708), keys)
            else:
                self.assertEqual(data[predicate + 6], 6)
            self.assertEqual(data[stream:stream + len(prefix)], prefix)
            cursor = stream + len(prefix)
            self.assertEqual(data[cursor:cursor + 5], bytes((3, *destination, 0xFD)))
            door, _ = export.doorway(data, room, index, prefix)
            target, spawn_x, spawn_y = destination
            self.assertEqual((door["room"], door["spawn_x"], door["spawn_y"]),
                             (export.ROOM_IDS[target], 8 * spawn_x, 8 * spawn_y))
            self.assertEqual(door["direction"], "up" if keys else None)

    def test_hero_clips_have_independently_extracted_poses_and_timing(self):
        from PIL import Image
        from test_play_sprite_geometry import walk
        from q_art import piece_records
        data, _ = export.source("/SHU.BIN")
        self.assertEqual(data[0], 8)
        section = struct.unpack_from("<I", data, 0x28)[0]
        sheets, animations = struct.unpack_from("<II", data, section + 16)
        count = struct.unpack_from("<h", data, section)[0]
        records = piece_records(data, 0, sheets, count)
        _, _, _, planes = list(walk(data))[1]
        palette_table = struct.unpack_from("<I", data, section + 12)[0]
        palette_offset = struct.unpack_from("<I", data, palette_table)[0]
        palette = struct.unpack_from("<32H", data, palette_offset)
        atlas = export.Atlas()
        clips, _ = export.hero_clips(data, atlas)
        for direction, clip in enumerate(clips):
            anim = struct.unpack_from("<I", data, animations + direction * 4)[0]
            pairs = [data[anim + 4 + i * 2:anim + 6 + i * 2] for i in range(data[anim])]
            self.assertEqual([f["ticks"] for f in clip["frames"]], [p[1] for p in pairs])
            for (pose, _), frame in zip(pairs, clip["frames"]):
                record = records[pose]
                self.assertEqual(record["count"], 1)
                piece, = record["sub_pieces"]
                u = (piece["u"] % 16) * 8
                v = (piece["u"] // 16) * 8
                colors = []
                for py in range(piece["h"] - 1):
                    for px in range(piece["w"] - 1):
                        word = palette[planes[piece["slot_delta"]][(v + py) * 128 + u + px]]
                        colors.append(((word & 31) * 255 // 31, ((word >> 5) & 31) * 255 // 31, ((word >> 10) & 31) * 255 // 31, 255 if word else 0))
                part = Image.new("RGBA", (piece["w"] - 1, piece["h"] - 1))
                part.putdata(colors)
                if int(piece["flags"], 16) & 2:
                    part = part.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
                expected = Image.new("RGBA", (piece["w"], piece["h"]))
                expected.alpha_composite(part)
                rect = frame["rect"]
                actual = atlas.image.crop((rect["x"], rect["y"], rect["x"] + rect["w"], rect["y"] + rect["h"]))
                self.assertEqual(actual.tobytes(), expected.tobytes())

    def test_patron_text_uses_the_room_local_pointer_table(self):
        assert_words({
            0x80171718 + 4 * 4: (0x8013B830,),
            0x8013B84C: (0x90650000,),
            0x8013B85C: (0x90640001,),
            0x8013B878: (0x8C43000C, 0x00041080, 0x00431021, 0x8C440000),
            0x8013B8B4: (0x0C04EDE8,),
        })
        data = self.data
        room = scene.room_record(data, 7)
        entry = scene.entities(data, room)[3]
        stream = entry["stream_offsets"][2]
        opcode, style, text = data[stream + 2:stream + 5]
        table, = struct.unpack_from("<I", data, room["record_off"] + 12)
        text_pointer, = struct.unpack_from("<I", data, table - BASE + 4 * text)
        self.assertEqual((opcode, style, text_pointer), (4, 0, 0x80046318))

    def test_field_sprite_extents_idle_and_command_opacity_against_instructions(self):
        data, _ = export.source("/SHU.BIN")
        section = struct.unpack_from("<I", data, 0x28)[0]
        sheets, animations = struct.unpack_from("<II", data, section + 16)
        assert_words({
            # Frame count one uses frame zero. Every other count starts at one.
            0x801344F8: (0x90C30001, 0x34020001, 0x14620003, 0x34020001,
                         0x0804D145, 0xA0C00002, 0xA0C20002),
            # Map initializer writes opaque flags. The emitter folds flag bit 30 into command bit 25.
            0x800C453C: (0x3C020100, 0xACA20010),
            0x8014C9C4: (0x00111942, 0x3C020200, 0x00621824),
            0x8014C9D8: (0x3C076400, 0x00471025, 0x00621825),
        })
        self.assertEqual([data[off] for off in struct.unpack_from("<4I", data, animations)], [4] * 4)
        for sheet in struct.unpack_from("<13I", data, sheets):
            self.assertEqual(tuple(data[sheet + 2:sheet + 4]), (24, 48))
        clips, _ = export.hero_clips(data, export.Atlas())
        for clip in clips:
            self.assertEqual(len(clip["frames"]), 4)
            for frame in clip["frames"]:
                self.assertEqual((frame["rect"]["w"], frame["rect"]["h"]), (24, 48))

    def test_export_never_writes_accepted_content(self):
        with self.assertRaises(ValueError):
            export.export(ROOT / "kit/work/accepted/first_room")

    def test_restore_requires_reviewed_bytes_and_preserves_existing_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            candidate = root / "candidate"
            candidate.mkdir()
            content = {name: name.encode() for name in ("room.json", "atlas.png", "provenance.json")}
            for name, value in content.items():
                (candidate / name).write_bytes(value)
            receipt = root / "game/assets/first_room_review.json"
            receipt.parent.mkdir(parents=True)
            receipt.write_text(json.dumps({"runtime_files": {n: hashlib.sha256(v).hexdigest() for n, v in content.items()}}))
            with patch.object(export, "ROOT", root):
                accepted = export.restore_reviewed(candidate)
                self.assertEqual(export.restore_reviewed(candidate), accepted)
                (candidate / "atlas.png").write_bytes(b"unreviewed")
                with self.assertRaisesRegex(ValueError, "differs from the reviewed"):
                    export.restore_reviewed(candidate)
                self.assertEqual((accepted / "atlas.png").read_bytes(), content["atlas.png"])
                (candidate / "atlas.png").write_bytes(content["atlas.png"])
                (accepted / "room.json").write_bytes(b"existing accepted data")
                with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
                    export.restore_reviewed(candidate)
                self.assertEqual((accepted / "room.json").read_bytes(), b"existing accepted data")


if __name__ == "__main__":
    unittest.main()
