#!/usr/bin/env python3
"""Static checks of the VB6 shop, purchase path and retained Medicine fixture."""
from hashlib import sha256
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import area_scene as scene
import export_shop
import maindec as main
from export_first_room import doorway, source
from test_canonical_start import assert_main_words
from test_consumables import check_field_sources
from war_text import decode

FIXTURE = ROOT / 'game/tests/fixtures/medicine.json'


def medicine_cases():
    heals, _, _ = check_field_sources()
    rows = []
    for hp, maximum in [(0, 100), (1, 100), (35, 100), (99, 100), (100, 100), (1, 300), (150, 300), (299, 300)]:
        for uses in (1, 2, 6):
            hp_after = min(hp + heals['medicine'], maximum)
            uses_after = uses - int(hp_after != hp)
            rows.append(dict(hp_before=hp, max_hp=maximum, uses_before=uses,
                             hp_after=hp_after, uses_after=uses_after, slots_after=int(uses_after > 0)))
    return rows


class ShopTests(unittest.TestCase):
    def test_semantic_metadata_current_and_protected(self):
        export_shop.write(ROOT / 'game/assets', verify=True)
        with self.assertRaisesRegex(ValueError, 'accepted tree'):
            export_shop.write(ROOT / 'kit/work/accepted/items')

    def test_shop_context_and_stock_walk(self):
        assert_main_words({
            # Opcode 43 reads its selector and index from consecutive script bytes.
            0x801397EC: (0x90820000, 0, 0xA06204E0),
            0x80139858: (0x1462000F, 0),
            0x801398B4: (0x90620000, 0x8C830010, 0x00021080, 0x00431021,
                         0x8C42000C, 0, 0xACA20494),
            0x800D1C0C: (0xAC700078, 0x8E020000, 0x3C018018, 0xAC239E68,
                         0x90440000, 0, 0x1080001E, 0x00008021),
            # Stock count advances by one byte and stops on the first zero.
            0x800D1C7C: (0x8CC20078, 0, 0x8C420000, 0x26100001, 0x00501021,
                         0x90440000, 0, 0x1480FFE8, 0),
            0x800D1CA8: (0x00102080, 0x0C030B4C, 0xAC50007C),
        })
        data, _ = source('/VB6.BIN')
        base = 0x80010000
        root = struct.unpack_from('<I', data)[0] - base
        counter = scene.entities(data, scene.room_record(data, 9))[2]
        script = counter['stream_offsets'][2]
        self.assertEqual(data[script:script + 4], b'\x43\x02\x00\xfd')
        args = struct.unpack_from('<I', data, root + 0x10)[0] - base
        context = struct.unpack_from('<I', data, args + 0x0C + 4 * data[script + 2])[0]
        self.assertEqual(context, 0x80044410)
        stock = struct.unpack_from('<I', data, context - base)[0] - base
        self.assertEqual(stock, 0x342EC)
        self.assertEqual(list(data[stock:data.index(0, stock) + 1]), [25, 72, 71, 143, 0])

    def test_purchase_price_uses_and_inventory_capacity(self):
        # Pin insertion including its full-record copy and full-inventory exit.
        insert = main.body()[0x800CA38C-main.MBASE:0x800CA408-main.MBASE]
        self.assertEqual(sha256(insert).hexdigest(), '6e130f849639cfef23dac79cfc99bcbabe54fc5f5692e61007ae4f3baa85a599')
        assert_main_words({
            # Signed balance < descriptor price refuses; equal funds proceed.
            0x800D2CDC: (0x8C430018, 0x8C820050, 0, 0x0043102A, 0x1040000F, 0),
            0x800D3308: (0x8C500018,),
            # The selected stock byte is the descriptor ID and the new record ID.
            0x800D3370: (0x8C820078, 0x8C830048, 0x8C420000, 0, 0x00431021,
                         0x90420000, 0, 0xA7A20010, 0x97A20010, 0xA3A00012,
                         0x00021080, 0x3C018016, 0x24217658, 0x00220821, 0x8C230000),
            0x800D33B0: (0x9462001C, 0, 0x3042000C, 0x10400004, 0, 0x9062001E,
                         0x08034CF5, 0xA3A20013, 0xA3A00013),
            0x800D33F0: (0x8C44005C, 0x0C0328E3, 0x27A50010),
            0x800D3408: (0x8C820050, 0x8C830008, 0x00501023, 0xAC820050),
            0x800CA398: (0x9062001F, 0, 0x2C420009, 0x10400015),
        })
        medicine = main.mword(0x80167658 + 25 * 4)
        self.assertEqual(medicine, 0x801686CC)
        self.assertEqual(struct.unpack_from('<IHBB', main.body(), medicine-main.MBASE + 24), (100, 14, 6, 1))
        self.assertEqual(main.mword(0x80167928 + 4), 0x800D0B74)

    def test_source_effect_and_use_counter_fixture(self):
        self.assertEqual(medicine_cases(), json.loads(FIXTURE.read_text()))

    def test_shop_room_source_section_and_both_doors(self):
        data, _ = source('/VB6.BIN')
        shop = scene.room_record(data, 9)
        self.assertEqual(shop['section'], 10)
        merchant = scene.entities(data, shop)[1]
        self.assertEqual(data[merchant['stream_offsets'][0]], 6)
        door_in, _ = doorway(data, 0, 4, bytes.fromhex('11 80 00 0e 0a 02'))
        door_out, _ = doorway(data, 9, 0, b'')
        self.assertEqual(door_in, dict(x=232, y=144, w=24, h=8, room='vb6_shop',
                                       spawn_x=184, spawn_y=208, direction='up'))
        self.assertEqual(door_out, dict(x=176, y=240, w=24, h=8, room='vb6_village',
                                        spawn_x=240, spawn_y=152, direction=None))
        context = 0x34410
        greeting = struct.unpack_from('<I', data, context + 4)[0] - 0x80010000
        text, _ = decode(data, greeting)
        self.assertEqual(text, 'Welcome.')

        fixture = json.loads((ROOT / 'game/tests/fixtures/journey_room.json').read_text())
        rooms = {room['id']: room for room in fixture['rooms']}
        self.assertIn(door_in, rooms['vb6_village']['exits'])
        self.assertIn(door_out, rooms['vb6_shop']['exits'])
        counter = scene.entities(data, shop)[2]
        npc = next(npc for npc in rooms['vb6_shop']['npcs'] if npc['id'] == 'shopkeeper')
        self.assertEqual((npc['x'], npc['y'], npc['pages']), (counter['x_half'] * 8, counter['y_half'] * 8, [text]))


if __name__ == '__main__':
    if '--write-fixture' in sys.argv:
        rows = medicine_cases()
        FIXTURE.write_text(json.dumps(rows, indent=2) + '\n')
        print(f'Wrote {len(rows)} source-checked Medicine vectors')
    else:
        unittest.main()
