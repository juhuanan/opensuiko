#!/usr/bin/env python3
"""Static encounter and duel archive selection, checked against disc directories."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import area_encounter_tables as area
from export_first_room import source
import ikki_sky_bt_clut as duel
import maindec as main


class BattleResourceSource(unittest.TestCase):
    def pins(self, expected):
        for pc, word in expected.items():
            self.assertEqual(main.mword(pc), word, hex(pc))

    def test_initializer_bounds_selection_and_publishes_scene(self):
        start, end = 0x800DDF98, 0x800DE0B0
        block = main.body()[start - main.MBASE:end - main.MBASE]
        self.assertEqual(hashlib.sha256(block).hexdigest(),
                         '31f1b61d770ae5cea940e3656a83480bef15757c27a9ecb3b55a7a1b0e7871a7')
        self.pins({
            0x80128600: 0x8E22000C, 0x80128608: 0x8C440000, 0x80128614: 0xAC641BB4,
            0x800DDFCC: 0x8C831BB4, 0x800DDFD0: 0x8C851BC0, 0x800DDFE0: 0xAC23C100,
            # Signed selector <= 0 or >= count + 1 writes fallback 1.
            0x800DDFE4: 0x18A00009, 0x800DDFEC: 0x8C620008, 0x800DDFF4: 0x8C420000,
            0x800DDFFC: 0x24420001, 0x800DE000: 0x00A2102A, 0x800DE004: 0x14400002,
            0x800DDFC4: 0x34060001, 0x800DE00C: 0xAC861BC0, 0x800DE020: 0x8C421BC0,
            0x800DE024: 0x8C830008, 0x800DE028: 0x00021080, 0x800DE038: 0x8C420000,
            0x800DE040: 0xAC621340, 0x800DE044: 0x8C82000C, 0x800DE04C: 0xAC621344,
            0x800DE054: 0x2442E61C, 0x800DE05C: 0x2421DA90, 0x800DE064: 0xAC220000,
            # Only bit 30 of the encounter flag chooses the command.
            0x800DE068: 0x8C621340, 0x800DE070: 0x8C42000C, 0x800DE074: 0x3C034000,
            0x800DE078: 0x00431024, 0x800DE07C: 0x10400005,
            0x800DE084: 0x0C030C41, 0x800DE088: 0x34040071,
            0x800DE094: 0x0C030C41, 0x800DE098: 0x34040070,
        })

    def test_command_dispatch_and_pending_index_writer(self):
        self.pins({
            # High command byte indexes the family table. Family 0 uses command - 1.
            0x800C310C: 0x0C0313F8, 0x800C4FE4: 0x00041202, 0x800C4FE8: 0x304300FF,
            0x800C5004: 0x24210800, 0x800C5014: 0x00400008,
            0x800C0800: 0x800C501C, 0x800C5020: 0x0C03144B,
            0x800C513C: 0x2484FFFF, 0x800C5160: 0x24210888, 0x800C5170: 0x00400008,
            0x800C52BC: 0x0C031BC1, 0x800C52C0: 0x34040001,
            0x800C52CC: 0x0C031BC1, 0x800C52D0: 0x34040002,
            0x800C6F24: 0x12020005, 0x800C6F2C: 0x12020007,
            0x800C6F3C: 0x0C0313F8, 0x800C6F40: 0x3404041D,
            0x800C6F4C: 0x0C0313F8, 0x800C6F50: 0x3404041E,
            # Family 4 passes the command through. The byte store keeps its low byte.
            0x800C0810: 0x800C5058, 0x800C5058: 0x00042400, 0x800C505C: 0x0C031E52,
            0x800C5060: 0x00042403, 0x800C7954: 0x00808021, 0x800C7958: 0x3C028018,
            0x800C795C: 0x24429BF4, 0x800C7960: 0xA0500000, 0x800C79A4: 0x3403041D,
            0x800C79A8: 0x10430004, 0x800C79BC: 0x0C0321F9, 0x800C87F0: 0x10400006,
            0x800C87F8: 0x34020001, 0x800C8800: 0xA0229C05,
        })
        self.assertEqual([main.mword(0x800C0888 + 4 * (command - 1))
                          for command in (0x70, 0x71)], [0x800C52BC, 0x800C52CC])

    def test_area_directories_agree_with_independent_pointer_walk(self):
        counts = {}
        for record in area.area_data_files():
            data = area.load(record)
            try:
                _, _, directory, selectors = area.chain(data)
                count, pointers = area.selectors_table(data, selectors)
            except ValueError:
                continue

            def word(address):
                offset = address - 0x80080000
                self.assertTrue(0 <= offset <= len(data) - 4, hex(address))
                return struct.unpack_from('<I', data, offset)[0]

            raw_directory = word(word(word(0x80080000) + 12))
            raw_selectors = word(raw_directory + 8)
            self.assertEqual((raw_directory, raw_selectors, word(raw_selectors)),
                             (directory, selectors, count))
            self.assertEqual([word(raw_selectors + 4 * index) for index in range(1, count + 1)], pointers)
            self.assertEqual([word(pointer + 12) for pointer in pointers], [100] * count)
            counts[Path(record['path']).stem] = count
        self.assertEqual(set(counts), {f'{letter}_DATA' for letter in 'ABCDEFGHZ'})
        self.assertEqual(sum(counts.values()), 90)

    def test_duel_imports_and_resource_rows(self):
        self.assertEqual(main.mword(0x80165608 + 0xAC), 0x800C3104)
        for name, gs_load in zip(duel.OVERLAYS, (0x8C422338, 0x8C421D64, 0x8C421DC8), strict=True):
            with self.subTest(overlay=name):
                data = duel.source.overlay(name)
                self.assertEqual(struct.unpack_from('<13I', data, 0x80081C7C - duel.B), (
                    0x3C02800A, gs_load, 0, 0x8C421BC4, 0, 0x8C4200AC, 0, 0x0040F809,
                    0x34040420, 0x3C028008, 0x24421CD0, 0xAE820000, 0x2402FFFF,
                ))

        for index, name, lba, size in (
            (29, 'BATTLE1.8', 87267, 3473408),
            (30, 'BATTLE2.8', 88963, 3407872),
            (32, 'BATTLE3.8', 157647, 3801088),
        ):
            with self.subTest(resource=index):
                offset = 0x80164E68 - main.MBASE + 12 * index
                lba_bytes, sectors = struct.unpack_from('<3s5xH', main.body(), offset)
                self.assertEqual((int.from_bytes(lba_bytes, 'little'), sectors * 2048), (lba, size))
                _, entry = source(name)
                self.assertEqual((entry['lba'], entry['size']), (lba, size))


if __name__ == '__main__':
    unittest.main()
