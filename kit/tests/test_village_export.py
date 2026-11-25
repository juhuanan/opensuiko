#!/usr/bin/env python3
"""Village conversations and persistent exit versus static disc evidence."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
import export_first_room as export
import maindec
from lzss import decode_strict
from test_entity_predicates import assert_words, check_dispatch, check_helpers
from war_text import decode


BASE = 0x80010000


class VillageExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data, _ = export.source("/VB6.BIN")
        cls.npcs, cls.event, cls.proof = export.village_content(cls.data)

    def pointer(self, offset):
        return struct.unpack_from("<I", self.data, offset)[0] - BASE

    def assert_handler(self, opcode, start, end, digest):
        self.assertEqual(maindec.mword(0x80171718 + opcode * 4), start)
        base = maindec.MBASE
        code = maindec.body()[start - base:end - base]
        self.assertEqual(hashlib.sha256(code).hexdigest(), digest)

    def test_unconditional_npcs_and_room_local_dialogue_consumers(self):
        check_dispatch()
        # Opcode 04 reads the style and index, loads the table at room+0C,
        # then passes table[index] and the style to 8013B7A0.
        self.assert_handler(4, 0x8013B830, 0x8013B8CC,
                            "58ae73a7405b0945e029d0756239d471dfa444265f0b7e1dc1749c659fce124e")
        data = self.data
        entries, text_table = self.pointer(0x3473C), self.pointer(0x34748)
        self.assertEqual((entries, text_table), (0x3495C, 0x3641C))
        for npc, index, expected_script, expected_text in zip(self.npcs, (8, 9),
                (0x3494C, 0x34954), (0x36278, 0x362BC), strict=True):
            entry = entries + index * 24
            classification, predicate, script = (self.pointer(entry + k) for k in (12, 16, 20))
            self.assertEqual((classification, predicate, script), (0x34830, 0x34838, expected_script))
            self.assertEqual(data[classification], 6)
            self.assertEqual(data[predicate:predicate + 2], b"\x05\x06")
            self.assertEqual((npc["x"], npc["y"]), tuple(v * 8 for v in struct.unpack_from("<HH", data, entry)))
            opcode, style, text_index = data[script + 2:script + 5]
            self.assertEqual((opcode, style, text_index), (4, 0, index - 8))
            text_offset = self.pointer(text_table + text_index * 4)
            self.assertEqual(text_offset, expected_text)
            self.assertEqual(npc["pages"], [decode(data, text_offset)[0].strip()])
        self.assertTrue(self.npcs[0]["pages"][0].startswith("It's true!"))
        self.assertTrue(self.npcs[1]["pages"][0].startswith("Up ahead is the Great Forest."))

    def test_south_exit_bounds_and_persistent_or_against_source(self):
        check_dispatch()
        check_helpers()
        assert_words({
            0x8013DBC8: (0x0804F806, 0x00001021),
            0x8013DCEC: (0x9063BD74,),
            0x8013DD18: (0x9063BD75,),
            0x8013DF04: (0x1040003F, 0x26100001, 0x0804F806, 0x00001021),
        })
        entry = self.pointer(0x3473C) + 24
        self.assertEqual(entry, 0x34974)
        self.assertEqual(struct.unpack_from("<H", self.data, entry + 4)[0] & 0x10, 0)
        predicate, stream = self.pointer(entry + 16), self.pointer(entry + 20)
        self.assertEqual((predicate, stream), (0x34860, 0x348B0))
        x_test, min_x, max_x, y_test, min_y, max_y, end = self.data[predicate:predicate + 7]
        self.assertEqual((x_test, y_test, end), (0x0B, 0x0C, 6))
        self.assertEqual((min_x, max_x, min_y, max_y), (28, 37, 45, 45))
        event = self.event
        self.assertEqual(event["flag"], "village_south_exit_reached")
        for y in range(42, 49):
            for x in range(24, 42):
                exported = (event["x"] <= x * 8 < event["x"] + event["w"]
                            and event["y"] <= y * 8 < event["y"] + event["h"])
                self.assertEqual(exported, min_x <= x <= max_x and min_y <= y <= max_y, (x, y))
        opcode, index, mask = self.data[stream:stream + 3]
        self.assertEqual((opcode, index, mask), (9, 0x27, 0x10))
        self.assertEqual(self.data[stream + 3:stream + 9], bytes.fromhex("03 fb 01 56 55 fd"))
        # Opcode 09 advances two operand bytes, then ORs the mask into the
        # indexed game-state byte. The store is in the return delay slot.
        self.assert_handler(opcode, 0x8013CBBC, 0x8013CC04,
                            "29453528401894bd0ba9a2c2743485d68ed277966daa4a66768670c256552861")
        self.assertEqual(self.proof["event"]["persistent_write"],
                         dict(opcode=opcode, index=index, mask=mask, consumer="0x8013CBBC"))

    def test_exported_npc_pixels_against_direct_atlas_and_palette_extraction(self):
        from PIL import Image
        output = Path(self.enterContext(tempfile.TemporaryDirectory()))
        village = export.export(output)["rooms"][1]
        self.assertEqual(village["npcs"], self.npcs)
        self.assertEqual(village["events"], [self.event])
        proof = json.loads((output / "provenance.json").read_text())
        meta = proof["rooms"][1]["composition"]["npc"]
        self.assertEqual(meta["excluded_entities"], [7])
        self.assertEqual(meta["primitives"], 2)
        data = self.data
        ptr = self.pointer
        # Section0's counted character-id records select context[j+1].
        section = ptr(ptr(ptr(0) + 4))
        ids, contexts = ptr(section + 0x34), ptr(section + 0x20)
        with Image.open(output / "atlas.png") as atlas:
            for index, entry in enumerate((0x34A1C, 0x34A34)):
                cid = struct.unpack_from("<H", data, entry + 6)[0] & 255
                match = next(j for j in range(2) if struct.unpack_from("<I", data, ptr(ids + j * 4))[0] == cid)
                ctx = ptr(contexts + (match + 1) * 4)
                desc = ptr(ptr(ctx + 20))
                sheet = ptr(ptr(ctx + 16) + data[desc + 6] * 4)
                vx, vy, cell, uv, w, h, _, flags = data[sheet + 8:sheet + 16]
                blob = ptr(ptr(ctx + 8) + cell * 4)
                size = struct.unpack_from("<I", data, blob)[0]
                raw = decode_strict(data[blob + 4:blob + 4 + size])
                self.assertEqual(len(raw), 16384)
                palette = struct.unpack_from("<32H", data, ptr(ptr(ctx + 12)))
                npc = village["npcs"][index]
                x, y = npc["x"] + vx - data[sheet + 4], npc["y"] + vy - data[sheet + 5]
                draw, = [d for d in village["draws"] if (d["x"], d["y"], d["rect"]["w"], d["rect"]["h"]) == (x, y, w, h)]
                r = draw["rect"]
                got = atlas.crop((r["x"], r["y"], r["x"] + w, r["y"] + h)).tobytes()
                expected = []
                for dy in range(h):
                    for dx in range(w):
                        sx = (uv & 15) * 8 + (w - 1 - dx if flags & 2 else dx)
                        sy = (uv >> 4) * 8 + (h - 1 - dy if flags & 1 else dy)
                        word = palette[raw[sy * 128 + sx]]
                        expected.append(tuple(((word >> shift) & 31) * 255 // 31 for shift in (0, 5, 10)) + (0 if word == 0 else 255,))
                self.assertEqual(got, bytes(channel for pixel in expected for channel in pixel))

    def test_changed_source_contracts_are_rejected(self):
        for offset in (0x34830, 0x3494F, 0x348B2):
            bad = bytearray(self.data)
            bad[offset] ^= 1
            with self.assertRaises(ValueError):
                export.village_content(bad)


if __name__ == "__main__":
    unittest.main()
