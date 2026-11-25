"""Static warehouse deposit and withdrawal source contracts."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import maindec as main
from export_first_room import source
from menu_flow import warehouse_deposit_allowed
from mipsdec import sx16

BASE = 0x80080000
ITEMS = (1, 7, 25, 26, 71, 72, 106, 114, 115, 120, 170)


class Warehouse(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image, origin = source('/AZUKARI.BIN')
        assert (origin['lba'], origin['size']) == (63261, 111552)
        assert struct.unpack_from('<I', cls.image)[0] == BASE + 0xA0

    def word(self, address):
        return struct.unpack_from('<I', self.image, address - BASE)[0]

    def assert_words(self, groups):
        for address, words in groups.items():
            self.assertEqual(struct.unpack_from(f'<{len(words)}I', self.image, address - BASE), words, hex(address))

    def assert_span(self, start, end, digest):
        self.assertEqual(hashlib.sha256(self.image[start - BASE:end - BASE]).hexdigest(), digest, hex(start))

    def test_capacity_and_equipped_predicate(self):
        self.assert_span(0x80084FE8, 0x80085074, '0f763ad9f8549db4b957c3bfbef42585ac6bb7dee0b6117bcf8f4e3431e247f9')
        self.assert_span(0x800843AC, 0x80084404, 'e4d9da091ad5afbda594fd1165f82712f6c8929068571c09d099a8cb7812cddd')
        self.assert_words({
            0x8008030C: (0x8C6314B4, 0x8C420048, 0x3C018009, 0xAC236B50),
            # Item ID indexes the stored quantity. This unsigned comparison
            # rejects full storage before reading the item's descriptor.
            0x80084FF8: (0x00451021, 0x90420090, 0, 0x2C4200FE, 0x14400003),
            0x80085030: (0x9442001C, 0, 0x30427000, 0x10400007),
            # Both arms sign-load the same byte. An inverted signed -1 is
            # zero, while an inverted sign bit admits all nonnegative values.
            0x80085044: (0x80820002, 0, 0x00021027, 0x2C420001, 0x0802141B, 0x00021023),
            0x8008505C: (0x80820002, 0, 0x000217C3, 0x00021027, 0x03E00008, 0),
            # Deposit skips a rejected item. On acceptance it increments the
            # quantity and passes the index to the inventory-removal slot.
            0x800843AC: (0x0C0213FA, 0, 0x10400012),
            0x800843CC: (0x90620090, 0, 0x24420001, 0xA0620090),
            0x800843F0: (0x8C420220, 0x02602021, 0x0040F809, 0x02002821),
        })
        self.assertEqual(main.mword(0x80165608 + 0x220), 0x800CA42C)
        ceiling = sx16(self.word(0x80085004))
        mask = self.word(0x80085038) & 0xFFFF
        for item in ITEMS:
            descriptor = main.mword(0x80167658 + item * 4)
            flags, = struct.unpack_from('<H', main.body(), descriptor + 0x1C - main.MBASE)
            for quantity in (0, 253, 254, 255):
                for byte in range(256):
                    signed = byte if byte < 128 else byte - 256
                    if flags & mask:
                        accepted = ((~signed) & 0xFFFFFFFF) < 1
                    else:
                        accepted = ~(signed >> 31) == -1
                    self.assertEqual(warehouse_deposit_allowed(quantity, flags, byte),
                                     quantity < ceiling and accepted, (item, quantity, byte))

    def test_withdraw_reconstructs_maximum_uses_and_selected_status(self):
        self.assert_span(0x80082F94, 0x80083038, '104efb7cad5d7aecec8900297d81b1d5324959b9b90fbcb44369811f3ac411bc')
        self.assert_words({
            # Create a four-byte entry on the stack. Consumables load source
            # uses. Other records receive zero uses and a category-based status.
            0x80082F94: (0x3C028009, 0x8C426B50, 0xA7B00018, 0xA3A0001A),
            0x80082FB4: (0x9464001C, 0, 0x3082000C, 0x10400004, 0x30827000, 0x9062001E,
                         0x08020BF9, 0xA3A2001B, 0x10400002, 0x2402FFFF, 0xA3A2001A, 0xA3A0001B),
            # Pass the entry to the insertion slot, then decrement storage.
            0x80083004: (0x8C440050, 0x8C620174, 0, 0x0040F809, 0x27A50018),
            0x80083024: (0x00701821, 0x90620090, 0, 0x2442FFFF, 0xA0620090),
        })
        self.assertEqual(main.mword(0x80165608 + 0x174), 0x800CA38C)
        uses_mask = self.word(0x80082FBC) & 0xFFFF
        status_mask = self.word(0x80082FC4) & 0xFFFF
        entry_flags_offset = sx16(self.word(0x80082FB4))
        entry_uses_offset = sx16(self.word(0x80082FC8))
        restored = []
        for item in ITEMS:
            descriptor = main.mword(0x80167658 + item * 4) - main.MBASE
            flags, = struct.unpack_from('<H', main.body(), descriptor + entry_flags_offset)
            uses = main.body()[descriptor + entry_uses_offset] if flags & uses_mask else 0
            status = 0xFF if flags & status_mask and not flags & uses_mask else 0
            restored.append((status, uses))
        self.assertEqual(restored, [
            (0, 0), (0, 0), (0, 6), (0, 4), (0, 4), (0, 3), (0, 0),
            (255, 0), (255, 0), (255, 0), (255, 0),
        ])


if __name__ == '__main__':
    unittest.main()
