#!/usr/bin/env python3
"""Independent table walker checks location-dependent sound command export."""
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import battle_sound_context as context
import maindec
import world_map_render


class ContextTests(unittest.TestCase):
    def test_all_regions_and_points_against_existing_independent_reader(self):
        packet = context.build()
        regions = world_map_render.region_tables(maindec.body())
        self.assertEqual(len(packet['regions']), 12)
        self.assertEqual([len(r['points']) for r in packet['regions']],
                         [12, 49, 9, 9, 6, 5, 4, 3, 2, 50, 3, 13])
        self.assertEqual([r['default']['command'] for r in packet['regions']],
                         [0x28, 0x33, 0x36, 0x3b, 0x3f, 0x4f, 0x44, 0x46, 0, 0, 0, 0x2c])
        for region in packet['regions']:
            records = regions[region['region']]['records']
            self.assertEqual(len(region['points']), len(records))
            for point, record in zip(region['points'], records):
                raw = bytes.fromhex(record['raw'])
                self.assertEqual(point['command'], struct.unpack_from('<h', raw, 10)[0])
                self.assertEqual(point['source_address'], regions[region['region']]['offset']+14*record['record']+10)
                if point['bank']:
                    address = 0x80164834+32*(point['command']-0x21)
                    words = [maindec.mword(address+4*i) for i in range(8)]
                    self.assertEqual((point['bank']['va_size'], point['bank']['va_lba'],
                                      point['bank']['vb_size'], point['bank']['vb_lba']),
                                     (words[2], words[3], words[6], words[7]))

    def test_non_bank_command_is_not_an_empty_bank_selection(self):
        regions = context.build()['regions']
        self.assertIsNone(regions[8]['default']['bank'])
        self.assertEqual(regions[0]['points'][0]['bank']['id'], 'field_bank_31')
        self.assertNotEqual(regions[0]['default']['bank'], regions[0]['points'][0]['bank'])
        self.assertIsNone(regions[0]['points'][4]['bank'])

    def test_source_mutation_and_bad_pointer_fail_closed(self):
        for address in (0x80131250, 0x80170064, 0x800c748c, 0x800c76b0,
                        0x800c7878, 0x800c7908, 0x800c0b70, 0x80127a4c,
                        0x80127ab4, 0x800c50fc):
            image = bytearray(maindec.body())
            offset = address-maindec.MBASE
            image[offset:offset+4] = bytes(4)
            with patch.object(maindec, 'body', return_value=bytes(image)):
                with self.assertRaises(ValueError):
                    context.build()

    def test_bank_loader_admission_slot_arguments_and_completion(self):
        packet = context.build()
        self.assertEqual(packet['schema'], 'suikoden-battle-sound-context/2')
        loader = packet['loader']
        # Derive each address from the LUI and load/store operand, including signed lows.
        def address(high, low):
            word = maindec.mword(low)
            return ((maindec.mword(high) & 65535) << 16) + struct.unpack('<h', struct.pack('<H', word & 65535))[0]
        self.assertEqual(loader['busy_flags'], [address(a, b) for a, b in
                         ((0x800c7438, 0x800c743c), (0x800c7458, 0x800c745c),
                          (0x800c746c, 0x800c7470))])
        self.assertEqual(loader['pending_command'], address(0x800c748c, 0x800c7490))
        self.assertEqual(loader['state'], address(0x800c78b0, 0x800c78b4))
        self.assertEqual(loader['descriptor'], address(0x800c75ac, 0x800c75b0))
        self.assertEqual((loader['first_command'], loader['end_command'], loader['descriptor_stride']), (33,80,32))
        self.assertEqual([row['id'] for row in loader['states']], list(range(9)))
        self.assertEqual([row['entry'] for row in loader['states']],
                         [0x800c74ec, 0x800c7500, 0x800c7510, 0x800c7520,
                          0x800c7530, 0x800c7540, 0x800c7550, 0x800c7560, 0x800c7570])
        for pc, word in {0x800c539c:0x2c42002f, 0x800c53a8:0x0c031d0e,
                         0x800c7450:0x14400012, 0x800c7464:0x1440000d,
                         0x800c747c:0x14400007, 0x800c7498:0xa2220000,
                         0x800c76b0:0x90450001, 0x800c76cc:0x0c056b2e,
                         0x800c7878:0x90460001, 0x800c787c:0x0c0552c7,
                         0x800c789c:0x90460001, 0x800c78a4:0x0c0552c7,
                         0x800c78d0:0x0c0577cc, 0x800c78e4:0x14430014,
                         0x800c7908:0xa0209c00, 0x800c7934:0xa0229c00}.items():
            self.assertEqual(maindec.mword(pc), word, hex(pc))
        self.assertEqual(loader['chunk_bytes'], ((maindec.mword(0x800c784c)&65535)<<16) |
                         (maindec.mword(0x800c7858)&65535))

    def test_ordinary_world_entry_waits_for_audio_idle_before_default_dispatch(self):
        for pc, word in {0x80127a4c:0x0c030c39, 0x80127a54:0x14400078,
                         0x80127a5c:0x0c030be9, 0x80127a64:0x1c400074,
                         0x80127aa0:0x10460006, 0x80127aac:0x0c030c41,
                         0x80127ab4:0x08049f0e, 0x80127ab8:0x2402ffff,
                         0x800c30ec:0x0c031439,
                         0x800c50e8:0x90429beb, 0x800c50fc:0x90429c00,
                         0x800c5110:0x90429bf3}.items():
            self.assertEqual(maindec.mword(pc), word, hex(pc))


if __name__ == '__main__':
    unittest.main()
