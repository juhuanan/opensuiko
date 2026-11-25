#!/usr/bin/env python3
"""Independent source selectors, palettes, raster footprints and body attachments."""
import json
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import battle_status_art as exporter
import battle_bin
import maindec
from export_first_room import source
from lzss import decode_strict


class StatusArt(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packet, cls.images, cls.proof = exporter.build()
        cls.raw, _ = source('/BATTLE.BIN')

    def test_all_eight_party_selectors_and_mask_only_branches(self):
        expected = [12, 4, 6, 8, 10, 15, 22, 21]
        self.assertEqual([row['animation'] for row in self.proof['selectors']], expected)
        self.assertEqual([row['status'] for row in self.packet['icons']], list(exporter.NAMES))
        for pc, word in {0x800E0500: 0x0046102A, 0x800E0504: 0x10400008,
                         0x800E0520: 0x0803817F, 0x800C11D4: 0x800E05DC,
                         0x800E05F4: 0x34020002, 0x800E05F8: 0xA062004C,
                         0x800E061C: 0x080381DA, 0x800E0748: 0x0C03878F,
                         0x800E04A0: 0x8C42001C, 0x800E0488: 0x2A620008,
                         0x800E0E6C: 0x0C0380B3, 0x800E03AC: 0x0C038AA7,
                         0x800E2AC0: 0x2442FFFF, 0x800E2AF4: 0x30620001}.items():
            self.assertEqual(maindec.mword(pc), word, hex(pc))
        raw = self.raw; base = battle_bin.LOAD_BASE
        section = struct.unpack_from('<I', raw)[0] - base
        table = struct.unpack_from('<I', raw, section + 20)[0] - base
        pose_to_entry = {row['pose']: i for i, row in enumerate(self.proof['entries'])}
        for icon, animation in zip(self.packet['icons'], expected, strict=True):
            offset = struct.unpack_from('<I', raw, table + 4*animation)[0] - base
            count, flags = raw[offset:offset+2]
            self.assertEqual(flags, 3)
            frames = [dict(entry=pose_to_entry[pose], ticks=ticks or 256)
                      for pose, ticks in struct.iter_unpack('BB', raw[offset+4:offset+4+2*count])]
            self.assertEqual(icon['frames'], frames)

    def test_all_31_rasters_agree_with_independent_indexed_sampling_and_packet_footprints(self):
        raw = self.raw; base = battle_bin.LOAD_BASE
        section = struct.unpack_from('<I', raw)[0] - base
        ct, dt = [struct.unpack_from('<I', raw, section+i)[0] - base for i in (8, 12)]
        planes = []
        for index in range(raw[section+4]):
            off = struct.unpack_from('<I', raw, ct+4*index)[0] - base
            length = struct.unpack_from('<I', raw, off)[0]
            plane = decode_strict(raw[off+4:off+4+length])
            self.assertEqual(len(plane), 16384)
            planes.append(np.frombuffer(plane, dtype=np.uint8).reshape((128, 128)))
        self.assertEqual(len(self.images), 31)
        for entry, image in zip(self.proof['entries'], self.images, strict=True):
            off = entry['source_offset']
            count, _, width, height, ax, ay = raw[off:off+6]
            self.assertEqual(count, 1)
            x, y, page, tile, wm, hm, palette, flip = raw[off+8:off+16]
            self.assertEqual(flip, 0)
            self.assertEqual((entry['dx'], entry['dy']), (-ax, -ay))
            palette_offset = struct.unpack_from('<I', raw, dt+4*palette)[0] - base
            colors = []
            for (value,) in struct.iter_unpack('<H', raw[palette_offset:palette_offset+64]):
                colors.append([((value >> shift) & 31)*255//31 for shift in (0, 5, 10)] + [255 if value else 0])
            # Axis-aligned packet corners use wm/hm, leaving header padding transparent.
            rgba = np.zeros((max(height, y+hm), max(width, x+wm), 4), dtype=np.uint8)
            u, v = (tile & 15)*8, (tile >> 4)*8
            rgba[y:y+hm, x:x+wm] = np.array(colors, dtype=np.uint8)[planes[page][v:v+hm, u:u+wm]]
            self.assertEqual(image.tobytes(), rgba.tobytes())
            self.assertGreater(np.count_nonzero(rgba[:, :, 3]), 0)

    def test_every_pose_attachment_for_all_78_characters_and_native_metadata(self):
        self.assertEqual(len(self.packet['anchors']), 78)
        for anchor, proof in zip(self.packet['anchors'], self.proof['actors'], strict=True):
            raw, origin = source('/' + proof['source']['file'].split('/')[-1])
            self.assertEqual(origin, proof['source'])
            section = struct.unpack_from('<I', raw, 36)[0]
            count = struct.unpack_from('<H', raw, section)[0]
            et, ft = struct.unpack_from('<II', raw, section+16)
            expected = []
            for pose in range(count):
                off = struct.unpack_from('<I', raw, et+4*pose)[0]
                expected.append([raw[off+6]-raw[off+4], raw[off+7]-raw[off+5]])
            self.assertEqual(anchor['offsets'], expected)
            for key, animation in (('idle_pose', 0), ('hurt_pose', 1)):
                record = struct.unpack_from('<I', raw, ft+4*animation)[0]
                self.assertEqual(anchor[key], raw[record+4])
        native = json.loads((ROOT/'game/tests/fixtures/spell_scene_library.json').read_text())
        self.assertEqual(native['schema'], 'suikoden-spell-scenes/45')
        self.assertEqual(native['status_anchors'], self.packet['anchors'])
        first = min(frame['entry'] for icon in native['status_icons'] for frame in icon['frames'])
        self.assertEqual(native['status_icons'], [dict(icon, frames=[dict(f, entry=f['entry']+first)
            for f in icon['frames']]) for icon in self.packet['icons']])
        self.assertEqual(native['needle_burst'],[dict(f,entry=f['entry']+first) for f in self.packet['needle_burst']])

    def test_cures_transfer_existing_status_nodes_and_preserve_animation_order(self):
        for pc, word in {0x800F28AC:0x8E2330AC,0x800F28B0:0xAE2030A4,
                         0x800F28B4:0xAE430168,0x800F28C0:0x34420004,
                         0x800F2B50:0x0C038AA7,0x800F2B60:0xA622000C,
                         0x800F2B88:0x00431023,0x800F2BE0:0x00431023,
                         0x800F2DDC:0x8E2230DC,0x800F2DF8:0x34020003,
                         0x800F2E14:0x8E2230CC,0x800F2E30:0x34020002,
                         0x800F2E4C:0x8E2330BC,0x800F2E68:0xAC86016C,
                         0x800F2F14:0x0C038811,0x800F2F18:0x34050005,
                         0x800F2F84:0x0C038AA7,0x800F2F44:0x14400007}.items():
            self.assertEqual(maindec.mword(pc),word,hex(pc))
        self.assertEqual(self.proof['needle_burst']['flags'],1)
        self.assertEqual([(self.proof['entries'][f['entry']]['pose'],f['ticks'])
            for f in self.packet['needle_burst']],[(29,4),(30,6)])
        raw=self.raw;base=battle_bin.LOAD_BASE
        section=struct.unpack_from('<I',raw)[0]-base
        dt=struct.unpack_from('<I',raw,section+12)[0]-base
        clut=struct.unpack_from('<I',raw,dt+4)[0]-base
        self.assertTrue(all(value&32768 for value in struct.unpack_from('<31H',raw,clut+2)))

    def test_repeated_batch_agrees_and_changed_setters_refuse(self):
        packet, images, proof = exporter.build()
        self.assertEqual((packet, proof), (self.packet, self.proof))
        self.assertEqual([image.tobytes() for image in images], [image.tobytes() for image in self.images])
        original = maindec.mword
        with patch.object(maindec, 'mword', side_effect=lambda pc: 0 if pc == 0x800C11D4 else original(pc)):
            with self.assertRaisesRegex(ValueError, 'Copper Flesh'):
                exporter.build()


if __name__ == '__main__':
    unittest.main()
