#!/usr/bin/env python3
"""Independent static controller, descriptor and VRAM-sampling checks."""
import copy
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import battle_bin
import battle_unite_camera
import disc
import lzss
import maindec
import spell_effect_entries
import unite_linked_controllers as linked
from psx_vram import PsxVram, TP_4BIT, clut_encode, texpage_encode


class LinkedControllers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = battle_unite_camera.report()
        cls.catalogue = json.loads(battle_unite_camera.CATALOGUE.read_text())['records']
        exe = disc.extract(maindec.EXE_LBA, maindec.EXE_SIZE)
        base, size = struct.unpack_from('<II', exe, 24)
        cls.base, cls.image = base, exe[2048:2048 + size]

    def word(self, address):
        return struct.unpack_from('<I', self.image, address - self.base)[0]

    def test_raw_source_controls_signals_and_timing(self):
        expected = {
            0x800FA9DC: 0x0C03E445, 0x800FAA44: 0x3C14800B, 0x800FAA48: 0x8E94A004,
            0x800FAB60: 0x8C460028, 0x800FAB94: 0x8C460024,
            0x800FAC4C: 0x30420010, 0x800FAD3C: 0x24420040, 0x800FAD60: 0x28420040,
            0x800FAE14: 0x34020010, 0x800FAE30: 0xAC62001C, 0x800FAE78: 0x28420020,
            0x800FAEC8: 0x28420020, 0x800FAED8: 0x34050002, 0x800FAEDC: 0x34060014,
            0x800FAEE0: 0x0C03E57A, 0x800FAF98: 0x24420040,
            0x800FB058: 0x0C03E445, 0x800FB0AC: 0x3C14800B, 0x800FB0B0: 0x8E94A004,
            0x800FB0F8: 0x34050006, 0x800FB0FC: 0x34060030,
            0x800FB18C: 0x8CA20040, 0x800FB190: 0x8C66002C, 0x800FB1CC: 0x8C460024,
            0x800FB274: 0x30420010, 0x800FB2A8: 0x8C460028, 0x800FB2DC: 0x3063FFEF,
            0x800FB30C: 0x30420002, 0x800FB31C: 0x34060014, 0x800FB32C: 0x0C03E57A,
            0x800FB330: 0xAC62001C, 0x800FB364: 0x3063FFFD, 0x800FB3C8: 0x0C03E4E4,
        }
        for address, word in expected.items():
            self.assertEqual(self.word(address), word, hex(address))
        warriors = self.rows[15]['controller_research']
        couple = self.rows[16]['controller_research']
        self.assertEqual([phase['updates'] for phase in warriors['phases']], [64, 32, 32])
        self.assertEqual((warriors['phases'][1]['start_impact_at_age'], warriors['damage']['multiplier']), (16, 20))
        self.assertEqual(warriors['motion'], dict(anchor_member=1, base_z_q12=-60*4096,
                                                  divisor=16, sine_step=64, sine_amplitude=40))
        for address, word in {
            0x800FACA0: 0x3C06FFFC, 0x800FAD0C: 0x34C64000,
            0x800FADC4: 0x2442000F, 0x800FADC8: 0x00021103,
            0x800FADF0: 0x0C054204, 0x800FADF4: 0x00042180,
            0x800FADF8: 0x00021880, 0x800FADFC: 0x00621821,
            0x800FAE0C: 0x000318C0,
        }.items():
            self.assertEqual(self.word(address), word, hex(address))
        self.assertEqual(couple['trigger'], dict(member=0, signal=16, clears=True, starts_member=1, script=10))
        self.assertEqual((couple['damage']['member'], couple['damage']['signal'], couple['damage']['multiplier']), (1, 2, 20))
        self.assertTrue(all(row['admission'] == 'source_research_only' for row in (warriors, couple)))

    def test_descriptors_and_pixels_match_independent_vram_sampling(self):
        art = self.rows[15]['controller_research']['impact_art']
        other = self.rows[16]['controller_research']['impact_art']
        self.assertEqual(art['animations'][0], other['animations'][0])
        raw = disc.extract(art['lba'], art['size'])
        pointer = lambda offset: struct.unpack_from('<I', raw, offset)[0] - battle_bin.LOAD_BASE
        section = pointer(4)
        self.assertEqual(section, art['section_offset'])
        ftable, etable, ctable = (pointer(section + n) for n in (20, 16, 8))
        for animation in art['animations']:
            offset = pointer(ftable + 4 * animation['id'])
            self.assertEqual(offset, animation['source_offset'])
            self.assertEqual(raw[offset+1], animation['flags'])
            count = raw[offset]
            frames = [(raw[offset+4+2*i], raw[offset+5+2*i] or 256) for i in range(count)]
            self.assertEqual(frames, [(int(row['piece'].split('_')[1]), row['ticks']) for row in animation['frames']])
        def page(index):
            offset = pointer(ctable + 4*index)
            size = struct.unpack_from('<I', raw, offset)[0]
            return lzss.decode_strict(raw[offset+4:offset+4+size])
        pages = [page(index) for index in range(10)]
        vram = PsxVram()
        for index, data in enumerate(pages):
            vram.upload_rect(640 + 64*(index % 5), 256 + 128*(index // 5), 64, 128, data)
        for piece in art['pieces']:
            pose = int(piece['id'].split('_')[1])
            offset = pointer(etable + 4*pose)
            self.assertEqual(offset, piece['source_offset'])
            self.assertEqual(list(raw[offset:offset+8]), piece['header'])
            self.assertEqual(len(piece['entries']), 1)
            entry = list(raw[offset+8:offset+16])
            self.assertEqual(entry, piece['entries'][0])
            _, _, page_id, tile, wm, hm, palette, flags = entry
            image = spell_effect_entries.entry_image(pages[page_id], pages[9], entry)
            texpage = texpage_encode(640 + 64*(page_id % 5), 256, TP_4BIT)
            clut = clut_encode(928 + 16*(palette & 1), 384 + palette//2)
            u0 = ((tile & 15)*8 - (128 if flags & 128 else 0)) & 255
            v0 = (tile >> 4)*8 + 128*(page_id//5)
            for y in range(hm + 1):
                for x in range(wm + 1):
                    sx = wm-x if flags & 2 else x
                    sy = hm-y if flags & 1 and not flags & 2 else y
                    value = vram.sample_texel(texpage, u0+sx, v0+sy)
                    expected = vram.sample_color(texpage, clut, u0+sx, v0+sy) + (255,) if value else (0, 0, 0, 0)
                    self.assertEqual(image.getpixel((x, y)), expected, (pose, x, y))

    def test_warriors_callback_dispatches_member_recipient_script(self):
        expected_words = {
            0x800FAD10: 0x3404081F, 0x800FAD18: 0x0C030C41,
            0x800FADD0: 0x0C030C41, 0x800FADD4: 0x34040524,
            0x800FAE14: 0x34020010, 0x800FAE18: 0x14820013,
            0x800FAE24: 0x34040521, 0x800FAE30: 0xAC62001C,
            0x800FAE34: 0x8E430058, 0x800FAE54: 0x8C420008,
            0x800FAE58: 0x8E45005C, 0x800FAE5C: 0x8C46003C,
            0x800FAE60: 0x0C038E08, 0x800FAE64: 0x02002021,
        }
        for address, word in expected_words.items():
            self.assertEqual(self.word(address), word, hex(address))
        recipient = self.rows[15]['controller_research']['recipient']
        phases = self.rows[15]['controller_research']['phases']
        self.assertEqual((phases[0]['start_sound'], phases[1]['start_sound'], phases[1]['impact_sound']),
                         (0x81f, 0x524, 0x521))
        self.assertEqual((recipient['member'], recipient['script'], recipient['phase'], recipient['age']), (0, 15, 1, 16))
        raw = disc.extract(recipient['source']['lba'], recipient['source']['size'])
        table = struct.unpack_from('<I', raw, 32)[0]
        cursor = struct.unpack_from('<I', raw, table + 15 * 4)[0]
        self.assertEqual(cursor, recipient['source_offset'])
        expected = [(15, (0, 1)), (15, (0, 8)), (4, (1,)), (3, (3,)), (38, ()),
                    (41, (255, 64, 64)), (24, (0, 2, 0, 0, 0, 0)),
                    (23, (1, 48, 0, 0, 0, -3, 0, 0)), (21, ()), (3, (1,)),
                    (41, (128, 128, 128)), (39, ()), (3, (1,)), (4, (0,)),
                    (22, (1,)), (21, ()), (16, (0, 8)), (16, (0, 255)), (0, ())]
        for op, args in expected:
            values = struct.unpack_from('<' + 'h' * (1 + len(args)), raw, cursor)
            self.assertEqual(values, (op, *args))
            cursor += 2 * len(values)
        self.assertEqual(cursor - recipient['source_offset'], recipient['byte_length'])
        self.assertEqual(recipient['operations'], [dict(op=op, args=list(args)) for op, args in expected])
        self.assertEqual(recipient['local_timing']['duration'], 54)

    def test_warriors_scene_tracks_follow_raw_controller_and_animation(self):
        import unite_scene_warriors
        for address, word in {
            0x800FAD34: 0x8C620034, 0x800FAD3C: 0x24420040,
            0x800FAE94: 0xAC40001C, 0x800FAF90: 0x96020044,
            0x800FAF98: 0x24420040, 0x80123440: 0xA465001C,
            0x800E2AC0: 0x2442FFFF, 0x8012395C: 0xAE20001C,
        }.items():
            self.assertEqual(self.word(address), word, hex(address))
        mapping = list(range(100, 200))
        scene = unite_scene_warriors.program(mapping)
        self.assertEqual((scene['impact'], scene['duration']), (128, 129))
        self.assertEqual(len(scene['objects']), 9)
        for index, obj in enumerate(scene['objects'][:8]):
            self.assertEqual((obj['anchor'], obj['start'], obj['position']), ('caster', 1, [30*4096, 0, 0]))
            track = scene['tracks'][obj['track']]
            self.assertEqual(len(track), 96)
            self.assertIsNone(track[0]['piece'])
            for age in range(1, 96):
                self.assertEqual(track[age], dict(piece=130, angles=[0, 0, 512*index + 64*age],
                                                  scale=[1 + 64*min(age, 64), 4096, 4096]))
        impact = scene['objects'][8]
        self.assertEqual((impact['anchor'], impact['start']), ('target', 81))
        art = self.rows[15]['controller_research']['impact_art']
        raw = disc.extract(art['lba'], art['size'])
        animation = art['animations'][0]['source_offset']
        source = [(raw[animation+4+2*i], raw[animation+5+2*i]) for i in range(raw[animation])]
        frames = [mapping[piece] for piece, ticks in source for _ in range(ticks)]
        self.assertEqual([row['piece'] for row in scene['tracks'][impact['track']]], [None] + frames[1:])

    def test_changed_source_and_bindings_refuse(self):
        for index in (15, 16):
            row = self.rows[index]
            for start, _, _ in linked.SPANS[index]:
                data = bytearray(self.image)
                data[start-self.base] ^= 1
                with self.assertRaisesRegex(ValueError, 'source changed'):
                    linked.research(self.catalogue[index], row['member_scripts'], battle_unite_camera.Image(bytes(data), self.base))
            changed = copy.deepcopy(row['member_scripts'])
            changed[0]['id'] ^= 1
            with self.assertRaisesRegex(ValueError, 'member scripts changed'):
                linked.research(self.catalogue[index], changed, battle_unite_camera.Image(self.image, self.base))

    def test_retained_report_is_reproducible(self):
        self.assertEqual(json.loads(linked.REPORT.read_text()), linked.build())


if __name__ == '__main__':
    unittest.main()
