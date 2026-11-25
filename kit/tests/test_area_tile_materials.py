"""Base-tile palette regression, including independent disc -> VRAM sampling."""
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import area_tile_materials as materials
import disc
import fix_palettes
import lzss
import render_area_batch
from psx_vram import PsxVram, texpage_encode, clut_encode, TP_8BIT


def fixture():
    data = bytearray(0x900)
    struct.pack_into('<HHBB', data, 0x100, 2, 1, 2, 2)
    for field, off in [(8, 0x200), (12, 0x210), (16, 0x220), (20, 0x230)]:
        struct.pack_into('<I', data, 0x100 + field, materials.RAM_BASE + off)
    for table, offsets in [(0x200, [0x300, 0x280]), (0x210, [0x400, 0x600]), (0x220, [0x240, 0x340])]:
        struct.pack_into('<2I', data, table, *(materials.RAM_BASE + off for off in offsets))
    struct.pack_into('<2H', data, 0x230, 0, 65)
    data[0x341] = 1
    struct.pack_into('<H', data, 0x402, 31)
    struct.pack_into('<H', data, 0x602, 31 << 10)
    return data, {0x300: bytes([1]) * 16384, 0x280: bytes([1]) * 16384}


class AreaMaterialsTests(unittest.TestCase):
    def test_order_and_palette_are_data_driven(self):
        data, cache = fixture()
        blobs, palettes, meta = materials.load_room_materials(data, 0x100, cache)
        image = materials.render_tilemap(data, blobs, None, 2, 1, 0x230, palettes)
        self.assertEqual([off for off, _ in blobs], [0x300, 0x280])
        self.assertEqual(image.getpixel((0, 0)), (255, 0, 0))
        self.assertEqual(image.getpixel((16, 0)), (0, 0, 255))
        self.assertFalse(meta['heuristic'])

    def test_palette_change_inside_one_atlas(self):
        data, cache = fixture()
        struct.pack_into('<2H', data, 0x230, 0, 1)
        data[0x241] = 1
        blobs, palettes, _ = materials.load_room_materials(data, 0x100, cache)
        image = materials.render_tilemap(data, blobs, None, 2, 1, 0x230, palettes)
        self.assertNotEqual(image.getpixel((0, 0)), image.getpixel((16, 0)))

    def test_invalid_materials_fail_without_guessing(self):
        for offset, value in [(0x341, 2), (0x104, 1)]:
            data, cache = fixture()
            data[offset] = value
            with self.assertRaises(ValueError):
                materials.load_room_materials(data, 0x100, cache)
        data, cache = fixture()
        struct.pack_into('<I', data, 0x220, 0)
        with self.assertRaises(ValueError):
            materials.load_room_materials(data, 0x100, cache)

    def test_unreferenced_null_slot_does_not_invent_pixels(self):
        data, cache = fixture()
        struct.pack_into('<2H', data, 0x230, 0, 0)
        struct.pack_into('<I', data, 0x204, 0)
        blobs, _, _ = materials.load_room_materials(data, 0x100, cache)
        self.assertEqual(blobs[1], (None, None))
        struct.pack_into('<H', data, 0x230, 64)
        with self.assertRaises(ValueError):
            materials.load_room_materials(data, 0x100, cache)

    def test_map_cannot_overlap_an_unused_compressed_stream(self):
        data, cache = fixture()
        struct.pack_into('<2H', data, 0x230, 0, 0)
        struct.pack_into('<I', data, 0x204, materials.RAM_BASE + 0x22c)
        struct.pack_into('<I', data, 0x22c, 4)
        with self.assertRaisesRegex(ValueError, 'overlaps compressed blob'):
            materials.load_room_materials(data, 0x100, cache)

    def source(self, lba, size):
        try:
            return disc.extract(lba, size)
        except disc.DiscNotFound as ex:
            self.skipTest(str(ex))

    def test_real_rooms_agree_with_independent_vram_descriptor_sampling(self):
        # This extraction does not call load_room_materials or render_tilemap.
        # Build GPU descriptors as 800C42F0 does, then sample their pages/CLUTs.
        for lba, size, header in [(58402, 272148, 0x9150), (58535, 453044, 0x3d94)]:
            data = self.source(lba, size)
            ptr = lambda off: struct.unpack_from('<I', data, off)[0] - 0x80010000
            vram = PsxVram()
            for pi in range(data[header + 5]):
                po = ptr(ptr(header + 12) + 4 * pi)
                vram.upload_rect(0, 480 + pi, 256, 1, data[po:po + 512])
            descriptors = []
            for bi in range(data[header + 4]):
                bo = ptr(ptr(header + 8) + 4 * bi)
                length = struct.unpack_from('<I', data, bo)[0]
                raw = lzss.decode_strict(data[bo + 4:bo + 4 + length])
                x, y = 320 + 64 * (5 * (bi // 20) + bi % 5), 128 * ((bi % 20) // 5)
                vram.upload_rect(x, y, 64, 128, raw)
                eo = ptr(ptr(header + 16) + 4 * bi)
                for si in range(64):
                    descriptors.append((texpage_encode(x, y // 256 * 256, TP_8BIT),
                                        clut_encode(0, 480 + data[eo + si]),
                                        si % 8 * 16, y % 256 + si // 8 * 16))
            blobs, palettes, meta = materials.load_room_materials(data, header)
            w, h = struct.unpack_from('<HH', data, header)
            image = materials.render_tilemap(data, blobs, None, w, h, ptr(header + 20), palettes)
            samples = {}
            for j, code in enumerate(struct.unpack_from('<%dH' % (w * h), data, ptr(header + 20))):
                if code not in samples:
                    tp, clut, u, v = descriptors[code]
                    samples[code] = vram.sample_piece(tp, clut, u, v, 16, 16)
                for row in range(16):
                    actual = [image.getpixel((j % w * 16 + col, j // w * 16 + row)) for col in range(16)]
                    self.assertEqual(actual, samples[code][row])
            if header == 0x3d94:
                self.assertEqual(meta['palette_offsets']['1'], 0x2714)
                self.assertEqual(meta['selectors']['2'][42:], [1] * 22)
                self.assertEqual(meta['selectors']['3'][:26], [1] * 26)

    def test_partial_decode_rejected(self):
        data = bytearray(self.source(58535, 453044))
        bo = 0x3dd0
        length = struct.unpack_from('<I', data, bo)[0]
        struct.pack_into('<I', data, bo, length + 1)
        with self.assertRaises((ValueError, lzss.LZSSError)):
            materials.load_room_materials(data, 0x3d94)

    def test_both_producers_use_same_materials_and_record_them(self):
        data = bytearray(self.source(58535, 453044))
        root = struct.unpack_from('<I', data, 0)[0] - materials.RAM_BASE
        table = struct.unpack_from('<I', data, root + 4)[0] - materials.RAM_BASE
        replacement = len(data)
        data.extend(data[table:table + 4] + bytes(252))  # isolate h0 without touching its root
        struct.pack_into('<I', data, root + 4, materials.RAM_BASE + replacement)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'VB5.BIN'
            path.write_bytes(data)
            records = [[], []]
            fix_palettes.process_file(path, Path(tmp) / 'fix', io.StringIO(), records=records[0])
            render_area_batch.process_file(path, Path(tmp) / 'batch', records=records[1])
            self.assertEqual((Path(tmp) / 'fix/VB5_h0.png').read_bytes(), (Path(tmp) / 'batch/VB5_h0.png').read_bytes())
            for items in records:
                rec = next(r for r in items if r['status'] == 'rendered')
                self.assertEqual(rec['palette']['method'], 'tile_palette_table')
                self.assertEqual(rec['palette']['selector_offsets']['3'], 0x112b0)


if __name__ == '__main__':
    unittest.main()
