#!/usr/bin/env python3
"""Static source checks for selected spell constructors, tables and palette uploads."""
from hashlib import sha256
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from disc import extract
import lzss
import maindec
from psx_vram import clut_base
import spell_effect_sources

BATTLE_BASE = 0x800AA000


class SpellEffectSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = extract(18698, 91451)
        cls.report = spell_effect_sources.write(verify=True)

    def check_words(self, expected):
        for address, word in expected.items():
            self.assertEqual(maindec.mword(address), word, hex(address))

    def check_spans(self, spans):
        image = maindec.body()
        for start, end, digest in spans:
            source = image[start - maindec.MBASE:end - maindec.MBASE]
            self.assertEqual(sha256(source).hexdigest(), digest, hex(start))

    def pointer(self, offset):
        address, = struct.unpack_from('<I', self.data, offset)
        self.assertTrue(BATTLE_BASE <= address < BATTLE_BASE + len(self.data), hex(address))
        return address - BATTLE_BASE

    def test_all_reported_frame_to_piece_links_agree_with_original_animation_consumer(self):
        self.check_spans((
            (0x800E211C, 0x800E21BC, '44e809f43169aacd7bba15a9ffe3fad5cc324d4b82d17f4c8361300f4a28c5ad'),
        ))
        self.check_words({
            0x800E214C: 0x8E830030, 0x800E2150: 0x92820000, 0x800E2154: 0x8C630014,
            0x800E2158: 0x00021080, 0x800E2164: 0x92820002, 0x800E2168: 0x24630004,
            0x800E2170: 0x00021040, 0x800E2178: 0x90440000, 0x800E217C: 0x90420001,
            0x800E2184: 0xA2820003, 0x800E2188: 0x8C620010, 0x800E218C: 0x00042080,
            0x800E2198: 0x8C820000, 0x800E21A4: 0xAE820024,
        })
        for effect, expected_counts in zip(self.report['effects'], ((64, 20, 116), (32, 11, 29)), strict=True):
            section = self.pointer(4 * effect['section'])
            pieces, animations = effect['pieces'], effect['animations']
            piece_count, animation_count = struct.unpack_from('<HH', self.data, section)
            self.assertEqual((piece_count, animation_count), expected_counts[:2])
            self.assertEqual((len(pieces), len(animations)), expected_counts[:2])
            piece_table = self.pointer(section + 0x10)
            frame_table = self.pointer(section + 0x14)
            report_piece_offsets = {piece['id']: piece['source_offset'] for piece in pieces}
            for index, piece in enumerate(pieces):
                address = self.pointer(piece_table + 4 * index)
                count = self.data[address]
                self.assertEqual(piece['id'], f'piece_{index}')
                self.assertEqual(piece['source_offset'], address)
                self.assertEqual(bytes(piece['header']), self.data[address:address + 8])
                self.assertEqual(len(piece['entries']), count)
                self.assertEqual(bytes(value for entry in piece['entries'] for value in entry),
                                 self.data[address + 8:address + 8 + count * 8])
            frame_count = 0
            for index, animation in enumerate(animations):
                address = self.pointer(frame_table + 4 * index)
                count = self.data[address]
                self.assertEqual((animation['id'], animation['source_offset']), (f'animation_{index}', address))
                self.assertEqual(len(animation['frames']), count)
                for step, frame in enumerate(animation['frames']):
                    piece, duration = struct.unpack_from('<BB', self.data, address + 4 + step * 2)
                    self.assertLess(piece, piece_count)
                    self.assertEqual(report_piece_offsets[frame['piece']], self.pointer(piece_table + 4 * piece))
                    self.assertEqual(frame['piece'], f'piece_{piece}')
                    self.assertEqual(frame['ticks'], duration or 256)
                frame_count += count
            self.assertEqual(frame_count, expected_counts[2])

    def test_original_initializers_select_the_named_battle_sections(self):
        self.check_spans((
            (0x800FEAEC, 0x800FEB14, '53e9e8728cef8057acc776b78d716e2465f8a4d4721c468aab530a0cd46b0987'),
            (0x801058AC, 0x801058D4, 'e16ad46b131ea88d574545e22a98460be9167dc3c204bc6ead4ba5bb96f07cb9'),
            (0x800FEB14, 0x800FEBE0, 'd4c5eab49ba8fc3e0a7a0fde017930047e99d7c7a4fcef38a381bcb9b5b03fb0'),
            (0x801058D4, 0x80105994, 'e2e4ec2d801f93fa0c9a36d16be80c1d7d37bf80020f5c33d59712ae93c4e019'),
        ))
        self.check_words({
            0x800FEAF4: 0x3C048010, 0x800FEAF8: 0x2484EB14, 0x800FEAFC: 0x0C04817F,
            0x801058B4: 0x3C048010, 0x801058B8: 0x248458D4, 0x801058BC: 0x0C04817F,
            0x800FEB64: 0x3C13800B, 0x800FEB68: 0x8E73A004,
            0x800FEBCC: 0x02602021, 0x800FEBD0: 0x00002821, 0x800FEBD8: 0x0C048CED,
            0x8010591C: 0x3C16800B, 0x80105920: 0x8ED6A00C,
            0x80105980: 0x02C02021, 0x80105984: 0x00002821, 0x8010598C: 0x0C048CED,
        })
        self.assertEqual([(effect['section'], effect['initializer']) for effect in self.report['effects']],
                         [(1, '0x800FEB14'), (3, '0x801058D4')])
        self.assertNotEqual(self.pointer(4), self.pointer(12))

    def test_selected_renderer_uses_four_bit_textures_and_packed_sixteen_colour_slots(self):
        self.check_spans((
            (0x80123504, 0x80123720, 'e217bf5128cb5662964c3b78319cb94b11e3bbe76f909c19b2738e3d13aafab7'),
            (0x8014ABD4, 0x8014ABEC, '879cc65128f4db04b58c281f0867c888d51875da3e7ff5bbb309a1595a4f2457'),
        ))
        self.check_words({
            # Four-bit mode, palette entry byte and texture-page output.
            0x80123574: 0x34170005, 0x80123588: 0x90430006, 0x8012358C: 0x91220002,
            0x801235C4: 0x34020014, 0x80123624: 0x00002021, 0x80123628: 0x8E650030,
            0x8012362C: 0x91300006, 0x80123654: 0x24C60140, 0x8012365C: 0x00073842,
            0x80123660: 0x0C052AC3, 0x80123668: 0xA6220016,
            # Convert the index's quotient and remainder to physical CLUT coordinates.
            0x8012366C: 0x00102842, 0x80123670: 0x00051040, 0x80123674: 0x02028023,
            0x80123678: 0x00108100, 0x8012367C: 0x260403A0, 0x80123680: 0x0C052AF5,
            0x80123684: 0x34A50180, 0x80123688: 0xA622000E,
            0x8014ABD4: 0x00051180, 0x8014ABD8: 0x00042103,
            0x8014ABDC: 0x3084003F, 0x8014ABE0: 0x00441025,
        })
        for effect in self.report['effects']:
            self.assertEqual(effect['texture_mode'], 'indexed4')
            self.assertEqual(effect['palette_selection'], 'packed_16_colour_slots')

    def test_spell_setup_uploads_the_embedded_palette_with_the_last_texture_page(self):
        self.check_spans((
            (0x801205FC, 0x801206A8, '89facb73344093c9f398056688337ae91c114038141abeb516d34be252d3248e'),
            (0x800C3500, 0x800C36A4, 'ffb94387d7827be955e4eb405bd1c794564e93a1a0a2233049079946c1320904'),
            (0x800C36A4, 0x800C3750, '7a062c5049e2e38700759daf9b271442a1c072de8ab32602424ba6cf96386a4d'),
            (0x800C33A0, 0x800C34CC, 'c8bf5ce17b63607e3f07507683a4a179350cc784a460e306278cdba61774da8f'),
            (0x800C3A44, 0x800C3B54, '48627b516782c98229ba2b1ddb0dfaa3b0ac57d9bfbc68b3c4d542d9cdc87cf7'),
        ))
        self.check_words({
            0x80120608: 0x8E10A004, 0x80120614: 0xAC24A090, 0x80120618: 0x0C030E81,
            0x8012061C: 0x3404001E, 0x80120620: 0x0C030DA9, 0x80120628: 0x0C030D40,
            0x80120630: 0x0C030DB5, 0x80120648: 0x24630660, 0x8012064C: 0xAC830014,
            0x80120668: 0x0C030CE8, 0x8012066C: 0x34040001, 0x80120670: 0x14400009,
            0x8012068C: 0x8C42A090, 0x80120694: 0xAC620014,
            0x800C3530: 0xA2220006, 0x800C3558: 0x8E240008, 0x800C357C: 0xAC620000,
            0x800C3580: 0x92220004, 0x800C3438: 0x0C030C51, 0x800C3458: 0x0C030E91,
            0x800C3A5C: 0x34030005, 0x800C3A8C: 0x34020014, 0x800C3AEC: 0x34020040,
            0x800C3AF4: 0x34020080, 0x800C3B0C: 0x24420140, 0x800C3B1C: 0x000631C0,
            0x800C3B20: 0x0C052164, 0x800C3B3C: 0xA0229030,
        })
        offsets = (0x4644, 0x65E8, 0x802C, 0x9ACC, 0xB730, 0xDAC0, 0xEE34, 0x11540, 0x121DC, 0x1429C)
        for index in range(1, 8):
            section = self.pointer(4 * index)
            self.assertEqual(tuple(self.data[section + 4:section + 7]), (10, 0, 30))
            table = self.pointer(section + 8)
            self.assertEqual(tuple(self.pointer(table + i * 4) for i in range(10)), offsets)

        pages = []
        vram = bytearray(1024 * 512 * 2)
        for counter, offset in enumerate(offsets, 30):
            length, = struct.unpack_from('<I', self.data, offset)
            self.assertLessEqual(offset + 4 + length, len(self.data))
            pixels = lzss.decode_strict(self.data[offset + 4:offset + 4 + length])
            self.assertEqual(len(pixels), 16384)
            pages.append(pixels)
            x, y = 320 + 64 * (5 * (counter // 20) + counter % 5), 128 * ((counter % 20) // 5)
            self.assertEqual((x, y), (640 + 64 * ((counter - 30) % 5), 256 + 128 * ((counter - 30) // 5)))
            for row in range(128):
                start = ((y + row) * 1024 + x) * 2
                vram[start:start + 128] = pixels[row * 128:(row + 1) * 128]
        self.assertEqual(sha256(b''.join(pages)).hexdigest(),
                         'b6718f2388d6722c09ea08c02f289753eab4e16add37fe09eead519332428d55')

        palette = self.report['effects'][0]['palette_source']
        self.assertEqual((palette['texture_slot'], palette['blob_offset'], palette['compressed_size']),
                         (39, offsets[-1], length))
        self.assertEqual(palette['upload_rect_words'], [x, y, 64, 128])
        self.assertEqual(palette['bank_rect_words'], [928, 384, 32, 128])
        self.assertEqual((palette['slot_count'], palette['colours_per_slot']), (256, 16))
        self.assertEqual((palette['decoded_size'], palette['decoded_sha256']),
                         (len(pages[-1]), sha256(pages[-1]).hexdigest()))
        for slot in range(256):
            clut = ((384 | (slot >> 1)) << 6) | (58 + (slot & 1))
            clut_x, clut_y = clut_base(clut)
            physical = 2 * (1024 * clut_y + clut_x)
            decoded = palette['decoded_row_stride_bytes'] * (slot // 2) + palette['decoded_bank_x_bytes'] + 32 * (slot % 2)
            self.assertEqual(vram[physical:physical + 32], pages[-1][decoded:decoded + 32], slot)

    def test_constructed_spell_graphics_reach_the_battle_piece_renderer(self):
        self.check_spans((
            (0x801233B4, 0x80123504, '3ea6fc34f2dcb054470f6f5f173d3f5e15453db0ab37d022427852d9e60bc768'),
            (0x80123720, 0x801238E0, '4dc2c2da15c8ef6b434a85494b643cc7376d609f97ec430262c0dd5adbdc851a'),
        ))
        self.check_words({
            0x800FF210: 0x0C048DC8, 0x80105FE4: 0x0C048DC8,
            0x801233FC: 0x0C03878F, 0x80123404: 0xAE020018, 0x80123490: 0x34030010,
            0x80123494: 0xAC43004C, 0x80123498: 0xAC54001C,
            0x80123888: 0x8E63004C, 0x80123890: 0x34020010, 0x80123894: 0x14620003,
            0x8012389C: 0x0C048D41, 0x801238B8: 0x0C03895B,
            0x80123688: 0xA622000E,
        })
        self.assertEqual(clut_base((435 << 6) | 58), (928, 435))

    def test_report_is_current_and_explicitly_refuses_runtime_media_promotion(self):
        self.assertEqual(self.report['schema'], 'suikoden-spell-effect-source-report/3')
        self.assertFalse(self.report['ready_for_runtime'])
        self.assertEqual([effect['native_spell_id'] for effect in self.report['effects']], [1, 9])
        self.assertTrue(all(effect['palette_source']['texture_slot'] == 39 for effect in self.report['effects']))
        with self.assertRaises(ValueError):
            spell_effect_sources.write(ROOT / 'kit/work/accepted/effects.json')


if __name__ == '__main__':
    unittest.main()
