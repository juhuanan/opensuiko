#!/usr/bin/env python3
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))
import export_war_content as content
import maindec
import vab_tones
import vag_extract
import war_map
import war_text


class WarContentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.exported = content.export()
        cls.manifest = cls.exported["manifest"]

    def test_source_map_composition(self):
        raw = war_text.load("WAR_KITA.BIN")
        descriptor = next(row for row in war_map.descriptors(raw)
                          if row["kind"] == "map" and (row["w"], row["h"]) == (23, 15))
        cells_pointer = struct.unpack_from("<I", raw, descriptor["off"] + 20)[0] - war_text.OVERLAY_BASE
        cells = struct.unpack_from("<23H", raw, cells_pointer)
        scene = self.manifest["scenarios"][6]
        battlefield = next(row for row in scene["maps"] if (row["width"], row["height"]) == (23, 15))
        self.assertEqual(battlefield["cells"][:23], list(cells))
        self.assertEqual(battlefield["composition"]["page"], "code >> 6")
        self.assertEqual(battlefield["composition"]["tile"], "code & 63")
        self.assertEqual(battlefield["composition"]["source_tile_width"], 16)
        self.assertEqual(battlefield["composition"]["tile_width"], 32)
        code = cells[0]
        self.assertLess(code >> 6, len(descriptor["blocks"]))
        source_pixels = descriptor["blocks"][code >> 6][1]
        tile = code & 63
        self.assertEqual(len(source_pixels), 128 * 128)
        self.assertLess((tile // 8) * 16 + 15, 128)
        self.assertLess((tile % 8) * 16 + 15, 128)

    def test_sprite_pose_script_contract(self):
        # The row-end handler stores the clamped row, supplying extent 8 to
        # 801458C8. The extent writer stores it in both descriptor fields.
        self.assertEqual([maindec.mword(address) for address in range(0x80146ABC, 0x80146ACC, 4)],
                         [0x34050008, 0x244200FF, 0x0C051632, 0xA082000B])
        self.assertEqual([maindec.mword(0x8014585C), maindec.mword(0x80145860)],
                         [0xA1070006, 0xA1070005])
        for scene in self.manifest["scenarios"]:
            self.assertTrue(all(atlas["poses"] for atlas in scene["atlases"][:2]))
        poses = self.manifest["scenarios"][0]["atlases"][0]["poses"]
        self.assertEqual(poses[0], {"script_offset": 116672, "frame": 0, "width": 8, "height": 8,
                                    "secondary": 3, "flags": 255})
        self.assertEqual(poses[1]["script_offset"], 116696)
        self.assertEqual(poses[1]["secondary"], 3)

    def test_vab_and_resource_references(self):
        va = war_text.load("WAR.VA")
        vb = war_text.load("WAR.VB")
        programs, tones, samples = vab_tones.parse_header(va)
        self.assertEqual((programs, tones, samples),
                         (self.manifest["audio"]["program_count"], self.manifest["audio"]["tone_count"],
                          self.manifest["audio"]["sample_count"]))
        self.assertEqual(len(vag_extract.split_vb(va, vb)), samples)
        self.assertEqual(self.manifest["audio"]["xa2"]["channels"],
                         [{"index": index, "path": f"xa/xa2_ch{index}.wav"} for index in range(3)])
        resources = {row["id"]: row for row in self.manifest["resources"]}
        self.assertEqual(len(resources), len(self.manifest["resources"]))
        for scene in self.manifest["scenarios"]:
            self.assertEqual(len(scene["maps"]), 2)
            self.assertEqual(len(scene["atlases"]), 6)
            self.assertGreaterEqual(len(scene["portraits"]), 111)
            for map_row in scene["maps"]:
                for resource in map_row["pages"]:
                    self.assertIn(resource, resources)

    def test_repeat_generation_missing_and_stale_check(self):
        first = content.output_bytes(self.exported)
        self.assertEqual(first, content.output_bytes(content.export()))
        for relative, data in first.items():
            self.assertEqual((ROOT / relative).read_bytes(), data, relative)
        with tempfile.TemporaryDirectory(prefix="war-content-") as temporary:
            root = Path(temporary)
            for relative, data in first.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            self.assertEqual(content.main(["--check", "--output-root", str(root)]), 0)
            for rel in ("game/assets/war/content_manifest.json", "game/assets/war/resources.bin", "game/assets/war/resources.zig"):
                stale = root / rel
                original = stale.read_bytes()
                stale.write_bytes(original + b" ")
                self.assertEqual(content.main(["--check", "--output-root", str(root)]), 1)
                stale.unlink()
                self.assertEqual(content.main(["--check", "--output-root", str(root)]), 1)
                stale.write_bytes(original)


if __name__ == "__main__":
    unittest.main()
