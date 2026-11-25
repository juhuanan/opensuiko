#!/usr/bin/env python3
"""Static rune permissions, crystal identities and inventory commit checks."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import character_table
import item_tables
import maindec as main
import preparation
from export_first_room import source
from mipsdec import sx16
from test_canonical_start import assert_main_words


def assert_span(start, end, digest):
    data = main.body()[start - main.MBASE:end - main.MBASE]
    assert hashlib.sha256(data).hexdigest() == digest, hex(start)


class RunePreparationTests(unittest.TestCase):
    def test_shop_mapping_prices_and_every_character_permission(self):
        assert_span(0x800D8E00, 0x800D8EB0, '0e55b63de7a1109736cf4b9624e7d2431ab39c00525da2dbbadd79f4c7817680')
        assert_main_words({
            # An occupied rune slot goes to rejection before the restriction test.
            0x800D8E38: (0x84240000, 0x9063004C, 0, 0x14600018, 0x00041080),
            # Rune descriptor bit 0x8000 selects the character-header scan.
            0x800D8E50: (0x2421A0E0, 0x00220821, 0x8C220000, 0, 0x94420016, 0, 0x30428000,
                         0x1040000B, 0x00001821),
            0x800D8E74: (0x00C31021, 0x9042000C, 0, 0x10440093, 0x24630001, 0x28620008,
                         0x1440FFFA, 0x00C31021, 0x080363AA, 0),
        })
        header_start = sx16(main.mword(0x800D8E78))
        header_count = sx16(main.mword(0x800D8E88))
        restriction = main.mword(0x800D8E68) & 0xFFFF
        headers = {ch['id']: source('/' + ch['sprite_file'])[0][:32] for ch in character_table.records()}
        self.assertEqual(len(headers), 78)
        catalogue = json.loads((ROOT / 'game/assets/magic_actions/catalogue.json').read_text())
        by_crystal = {row['crystal_id']: row for row in catalogue['runes']}
        rows = preparation.rune_bindings()
        self.assertEqual(len(rows), 29)
        self.assertEqual(len({r['id'] for r in rows}), 29)
        for row_index, binding in enumerate(rows, 1):
            rune, crystal = struct.unpack_from('<HH', main.body(), 0x8016B080 - main.MBASE + 4 * row_index)
            self.assertEqual((rune, crystal), (binding['rune'], binding['crystal']))
            pointer = main.mword(0x80167658 + crystal * 4)
            self.assertEqual((binding['name'], binding['price']),
                             (item_tables.name_at(pointer, 24), main.mword(pointer + 24)))
            descriptor = main.mword(0x8016A0E0 + rune * 4)
            flags, = struct.unpack_from('<H', main.body(), descriptor + 0x16 - main.MBASE)
            restricted = bool(flags & restriction)
            self.assertEqual(binding['restricted'], restricted)
            allowed = [ident for ident, header in headers.items()
                       if not restricted or rune in header[header_start:header_start + header_count]]
            self.assertEqual(by_crystal[crystal]['allowed_members'], allowed, (rune, crystal))

    def test_attach_uses_owner_slot_and_detach_returns_the_mapped_crystal(self):
        for start, end, digest in [
            (0x800D8FA0, 0x800D900C, '7aa614ed803524272a1613cc296154183118888f64ec638e7be9583b0c351646'),
            (0x800D953C, 0x800D95D0, '6093a39347e9776da76fa959577b87cd116c5cc6f064a39a549db18a3fa6df07'),
            (0x800CA38C, 0x800CA42C, '40830a5b7d9e9fbf663f78d72e88a2bb71ce6fdeebbde3c7a49bdaec11e75271'),
            (0x800CA42C, 0x800CA50C, '8d11d608cdda163606449bcdd8e1041af6a635596c746edf8c995a73ce5558c5'),
        ]:
            assert_span(start, end, digest)
        assert_main_words({
            # Target selection uses UI+04; the crystal owner comes from UI+5C.
            # The remove wrapper receives the selected owner's inventory slot.
            0x800D8FAC: (0x8C620004, 0xAC600098, 0x00021080, 0x00431021, 0x8C420044),
            0x800D8FC4: (0x8C44001C, 0x00031880, 0x3C018017, 0x2421B080, 0x00230821,
                         0x90220000, 0, 0xA082004C),
            0x800D8FF0: (0x8C62005C, 0x8C650064, 0x00021080, 0x00431021, 0x8C440044, 0x0C032902),
            0x800CA410: (0x8C84001C, 0x0C03290B, 0),
            # Removal decrements the count and moves full four-byte entries.
            0x800CA470: (0x2442FFFF, 0xA102001F),
            0x800CA490: (0x88C20027, 0x98C20024, 0, 0xA8C20023, 0xB8C20020),
            # Detach uses one handle for the cleared rune and inventory insert.
            # Pair +2 is the crystal ID, with both incoming status bytes zero.
            0x800D9584: (0x8CA2001C, 0, 0xA040004C),
            0x800D95A4: (0x00021080, 0x3C018017, 0x2421B082, 0x00220821, 0x94220000, 0x00A02021,
                         0x27A50010, 0xA3A00012, 0xA3A00013, 0x0C0328E3, 0xA7A20010),
            0x800CA398: (0x9062001F, 0, 0x2C420009),
            0x800CA3B4: (0x24420001, 0xA062001F),
            0x800CA3CC: (0x00021080, 0x00621821, 0x89020003, 0x99020000, 0, 0xA862001F, 0xB862001C),
        })
        # The commit slices store only the UI scratch word and the rune byte.
        # The inventory helpers above reach the count and item entries.
        for start, end, expected in [
            (0x800D8FA0, 0x800D900C, [(0x2B, 0x98), (0x28, 0x4C)]),
            (0x800D953C, 0x800D95D0, [(0x2B, 0x98), (0x28, 0x4C)]),
        ]:
            stores = [(word >> 26, sx16(word)) for pc in range(start, end, 4)
                      if (word := main.mword(pc)) >> 26 in (0x28, 0x29, 0x2B) and (word >> 21) & 31 != 29]
            self.assertEqual(stores, expected)

if __name__ == '__main__':
    unittest.main()
