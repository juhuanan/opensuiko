#!/usr/bin/env python3
"""Static source checks for equipment permissions, weapon levels and the VB6 smith."""
from hashlib import sha256
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import area_scene as scene
import character_table
import item_tables
import maindec as main
import preparation
from export_first_room import source
from test_canonical_start import assert_main_words
from war_text import decode

FIXTURES = ROOT / 'game/tests/fixtures'
PARTY = (8, 2, 6, 35, 38, 32, 70)


def permission_inputs():
    image = main.body()
    check = image[0x800D47AC-main.MBASE:0x800D48C4-main.MBASE]
    assert sha256(check).hexdigest() == 'edbb773aa3530fd571df41734a5acae3e0123a28d7aa482f043c65620a9b6c84'
    slot_masks = struct.unpack_from('<5H', image, 0x8016AF06-main.MBASE)
    assert slot_masks == (3, 60, 64, 0, 128)
    type_bits = tuple(main.mword(pc) & 0xFFFF for pc in (0x800D4870, 0x800D489C, 0x800D48A0, 0x800D488C))
    assert type_bits == (0x100, 0x200, 0x800, 0x400)
    return slot_masks, type_bits


def permitted(header, flags, kind, type_bits):
    # Unknown types bypass the class restriction and still require a matching kind.
    allowed_types = {index for index, bit in enumerate(type_bits) if bit & flags}
    return bool(header[11] & kind) and (not allowed_types or header[10] in allowed_types or header[10] >= 4)


class PreparationTests(unittest.TestCase):
    def test_flik_weapon_suffixes_preserve_unknown_glyphs_as_text(self):
        content = json.loads((FIXTURES / 'journey_battle.json').read_text())
        content['party'] = content['party'][:1]
        preparation.export(content, (17,))
        names = content['party'][0]['weapon']['names']
        self.assertEqual(names, ['Odessa'] * 6 + [r'Odessa\x5b'] * 6 + [r'Odessa\x5b\x5b'] * 4)

    def test_every_character_and_equipment_combination(self):
        slot_masks, type_bits = permission_inputs()
        equipment = [r for r in item_tables.items() if r['class'] & 128]
        records = character_table.records()
        self.assertEqual((len(records), len(equipment)), (78, 58))
        for item in equipment:
            flags, kind = struct.unpack_from('<HB', main.body(), item['addr'] - main.MBASE + 28)
            slot = next(i for i, mask in enumerate(slot_masks, 1) if mask & kind)
            self.assertEqual(slot, {0x80: 1, 0xA0: 2, 0xC0: 3, 0xE0: 5}[flags & 0xE0])
        for character in records:
            header = source('/' + character['sprite_file'])[0][:32]
            for item in equipment:
                flags, kind = struct.unpack_from('<HB', main.body(), item['addr'] - main.MBASE + 28)
                self.assertEqual(preparation.compatible(header, flags, kind),
                                 permitted(header, flags, kind, type_bits), (character['id'], item['name']))

        # A matching low-seven-bit slot with the lock bit set returns zero before
        # either permission test. Nonmatching slots continue the inventory scan.
        assert_main_words({0x800D480C: (0x3062007F, 0x14470004, 0x24C60001, 0x30620080, 0x14400027, 0x00001021)})

    def test_export_contains_only_named_runtime_data_and_real_permissions(self):
        content = json.loads((FIXTURES / 'journey_battle.json').read_text())
        records = {r['id']: r for r in character_table.records()}
        originals = {preparation.stable_id(r['name']): r for r in item_tables.items()}
        proof = preparation.export(content, PARTY)
        self.assertEqual(len(proof['characters']), 7)
        self.assertEqual(len(content['systems']['equipment']), 58)
        _, type_bits = permission_inputs()
        headers = [source('/' + records[i]['sprite_file'])[0][:32] for i in PARTY]
        for gear in content['systems']['equipment']:
            self.assertEqual(set(gear), {'id', 'name', 'category', 'bonuses', 'allowed_members'})
            offset = originals[gear['id']]['addr'] - main.MBASE
            flags, kind = struct.unpack_from('<HB', main.body(), offset + 28)
            self.assertEqual(gear['bonuses'], list(struct.unpack_from('<8b', main.body(), offset + 32)))
            for profile, header in zip(content['party'], headers, strict=True):
                self.assertEqual(profile['id'] in gear['allowed_members'], permitted(header, flags, kind, type_bits))

    def test_weapon_names_and_power_from_source_tables(self):
        assert_main_words({
            # Both strict tier thresholds and the 28-byte name stride.
            0x800CFBAC: (0x90820015, 0x90970054, 0x0222102A, 0x10400003, 0x00C0A821,
                         0x08033EF8, 0x00008021),
            0x800CFBC8: (0x90820031, 0, 0x0222102A, 0x10400002, 0x34100002, 0x34100001),
            0x800CFBF0: (0x001028C0, 0x00B02823, 0x02402021, 0x00131080, 0x3C018016,
                         0x24215890, 0x00220821, 0x8C220000, 0x34060014, 0x00052880, 0x0C051AED, 0x00A22821),
            # Level is one-based, row is 32 bytes, and the result is added into attack.
            0x800D5048: (0x91420044, 0, 0x00021080, 0x3C018016, 0x24215890, 0x00220821, 0x8C220000,
                         0x91430045, 0x90420054, 0x3C048016, 0x248459D0, 0x00031840, 0x00021140,
                         0x00441021, 0x00621821, 0x9502000C, 0x9463FFFE, 0, 0x00431021, 0xA502000C),
        })
        content = json.loads((FIXTURES / 'journey_battle.json').read_text())
        preparation.export(content, PARTY)
        records = {r['id']: r for r in character_table.records()}
        image = main.body()
        for profile, character in zip(content['party'], PARTY, strict=True):
            seed = records[character]
            raw_seed = character_table.image()[seed['off']:seed['off'] + 80]
            pointer = struct.unpack_from('<I', image, 0x80165890-main.MBASE + 4 * raw_seed[0x44])[0]
            offset = pointer - main.MBASE
            thresholds = (image[offset + 21], image[offset + 49])
            names = [item_tables.name_at(pointer + 28 * tier, 28) for tier in range(3)]
            expected = [names[sum(level >= cutoff for cutoff in thresholds)] for level in range(1, 17)]
            curve = image[offset + 84]
            powers = struct.unpack_from('<16H', image, 0x801659D0-main.MBASE + 32 * curve)
            weapon = profile['weapon']
            self.assertEqual(weapon['initial_level'], raw_seed[0x45])
            self.assertEqual(weapon['names'], expected)
            self.assertEqual(weapon['powers'], list(powers))

    def test_blacksmith_rejection_and_commit_use_the_same_price_table(self):
        assert_main_words({
            # Quote the current level's price. Reject insufficient funds, then level >= cap.
            0x800D6264: (0x8C42001C, 0, 0x90450045, 0, 0x00051080, 0x3C018017, 0x2421AF2C,
                         0x00220821, 0x8C230000),
            0x800D6288: (0x8C820040, 0, 0x0043102A, 0x14400031, 0,
                         0x8C820070, 0, 0x00A2102A, 0x10400020, 0),
            # Commit subtracts that same price and increments the selected record's level.
            0x800D66B8: (0x00051880, 0xAC800088, 0x8C820040, 0x3C018017, 0x2421AF2C, 0x00230821,
                         0x8C230000, 0, 0x00431023, 0xAC820040, 0x8CE3001C, 0, 0x90620045,
                         0, 0x24420001, 0xA0620045),
        })
        prices = struct.unpack_from('<16I', main.body(), 0x8016AF2C-main.MBASE)
        self.assertEqual(prices, (0, 300, 600, 1500, 2700, 3500, 4500, 7000,
                                  11000, 18000, 27000, 35000, 43000, 52000, 60000, 70000))
        fixture = json.loads((FIXTURES / 'journey_battle.json').read_text())
        preparation.export(fixture, PARTY)
        for profile in fixture['party']:
            self.assertEqual(profile['weapon']['upgrade_costs'], list(prices))

    def test_blacksmith_context_and_level_cap_from_source_script(self):
        assert_main_words({
            0x801398B4: (0x90620000, 0x8C830010, 0x00021080, 0x00431021,
                         0x8C42000C, 0, 0xACA20494),
            0x800D58A8: (0x90420000, 0x34041770, 0xAC600000, 0xAC600080, 0x0C030B4C, 0xAC620070),
        })
        data, _ = source('/VB6.BIN')
        base = 0x80010000
        root = struct.unpack_from('<I', data)[0] - base
        entity = scene.entities(data, scene.room_record(data, 10))[6]
        stream = entity['stream_offsets'][2]
        self.assertEqual(data[stream:stream + 4], b'\x43\x03\x02\xfd')
        args = struct.unpack_from('<I', data, root + 16)[0] - base
        context = struct.unpack_from('<I', data, args + 12 + 4 * data[stream + 2])[0] - base
        self.assertEqual(context, 0x34654)
        config, greeting = struct.unpack_from('<II', data, context)
        self.assertEqual(data[config-base], 5)
        self.assertEqual(decode(data, greeting-base)[0], 'Welcome.')

        fixture = json.loads((FIXTURES / 'journey_room.json').read_text())
        room = next(room for room in fixture['rooms'] if room['id'] == 'vb6_blacksmith')
        npc = next(npc for npc in room['npcs'] if npc['id'] == 'forest_blacksmith')
        self.assertEqual((npc['x'], npc['y'], npc['weapon_limit']),
                         (8 * entity['x_half'], 8 * entity['y_half'], data[config-base]))


if __name__ == '__main__':
    unittest.main()
