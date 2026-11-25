#!/usr/bin/env python3
"""Static source checks for enemy records and their battle consumers."""
from hashlib import sha256
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import area_encounter_tables as areas
import battle_formulas
import enemy_sprites
from export_first_room import source
import maindec
from war_text import decode


def check_consumers():
    main = maindec.body()
    for start, end, digest in (
        (0x800DEE44, 0x800DF144, '7d631e8df5dafb59a6aa5c354d981e3a6b41dad3c6ce079fa2958787e8a9637b'),
        (0x800F40FC, 0x800F43E0, '136cbda65bf431f3f8939114a8b8f1910ad1fc2975675587e1b0dc27d89999ff'),
        (0x800F777C, 0x800F78B0, '3b8ccac74c759ceb29bef8255b87c5b24a81a537e35aaa5225b2819bffeafea7'),
        (0x800E56EC, 0x800E5808, 'dd06e62abbd431239365dd88d8df52f8a155ad49eb93c40a49aebf35434ebb0b'),
        (0x80125B28, 0x80125C94, 'e6f9d7fe36ede9ef681cfef158fda258378879f2ad34c970220f0a15026a5063'),
        (0x800F491C, 0x800F4D5C, '4cc14fed993b896003f4dc8f5f6388439bcb104636bbe210eed07778692523a9'),
        (0x800F4E64, 0x800F5024, 'da1b24e81a60b251dd3d680046c46b9608a38cbea055c3774461347a561e5fc5'),
        (0x800F78E4, 0x800F79F0, '1fa4de4fb56bbc4bbf856caa6887a4fb79cf4f539976f8d1c2b01a9a70672e2c'),
        (0x80116088, 0x80116128, 'a6ad05bf1f414892bc3597233acbfdd81c7189991b323190528a632f1dfbb379'),
    ):
        assert sha256(main[start - maindec.MBASE:end - maindec.MBASE]).hexdigest() == digest, hex(start)

    for pc, word in {
        # Spawn skips empty roster slots and initializes the compact working records.
        0x800DEF00: 0x80460004, 0x800DEF08: 0x10C0007F,
        0x800DEF30: 0x92220010, 0x800DEF3C: 0xACA2126C, 0x800DEF40: 0x86220034,
        0x800DEF50: 0xACA21260, 0x800DEFA0: 0x8E24002C, 0x800DEFBC: 0x8E24002C,
        0x800DF000: 0xAE020068, 0x800DF004: 0xAE02005C, 0x800DF030: 0x96220026,
        0x800DF038: 0x30420020, 0x800DF054: 0x3C03FFFF, 0x800DF058: 0x34636000,
        0x800DF05C: 0x00021300, 0x800DF064: 0x00431021, 0x800DF080: 0xAE020070,
        0x800DF088: 0x9622003C, 0x800DF090: 0xA6020074,
        0x800DF094: 0x9622003E, 0x800DF09C: 0xA6020076, 0x800DF0A0: 0x8E220028,
        0x800DF0AC: 0x0C051F66, 0x800DF0B4: 0x96220012, 0x800DF0BC: 0xA6420010,
        0x800DF0CC: 0xA6420012, 0x800DF0D0: 0x94A20014, 0x800DF0DC: 0xA4620014,
        0x800DF0E0: 0x28820006, 0x800DF0F8: 0xA2420044, 0x800DF100: 0x2610008C,
        0x800DF104: 0x26730001, 0x800DF108: 0x26B50001,
        # The decision callback takes the scene. It is separate from actor script dispatch.
        0x800F41E4: 0x8C820030, 0x800F41EC: 0x0040F809, 0x800F41F0: 0x00A02021,
        # Footprint clearing, disabled/edge cells, width clipping and seven-cell output.
        0x800F7784: 0x34050006, 0x800F7794: 0xA0600000, 0x800F779C: 0x04A1FFFD,
        0x800F77FC: 0x91050044, 0x800F7808: 0x91030045, 0x800F7810: 0x1460001D,
        0x800F7818: 0x10A20019, 0x800F7820: 0x10A20017, 0x800F7828: 0x90E30011,
        0x800F7850: 0x28620004, 0x800F785C: 0x28420007, 0x800F7868: 0xA0460002,
        0x800F7870: 0x28420007, 0x800F787C: 0xA0460001, 0x800F7884: 0xA0460000,
        0x800F6840: 0x92420011, 0x800F6848: 0x0102102A, 0x800F68C0: 0x96420026,
        0x800F68C8: 0x30420020, 0x800F68E4: 0x34636000,
        # Opcode 43 reads either actor's signed offsets and keeps fractional position bits.
        0x8016BABC + 43 * 4: 0x800E56EC,
        0x800E5754: 0x84A20074, 0x800E5758: 0x84A30076, 0x800E5780: 0x84430074,
        0x800E5784: 0x84420076, 0x800E57AC: 0x00072300, 0x800E57B4: 0x30630FFF,
        0x800E57C0: 0x30A50FFF, 0x800E57C8: 0x00081B00, 0x800E57D4: 0x24840008,
        0x800E57D8: 0xAC44000C,
        # Working MGC/2, bypass index 7, coefficient load and signed arithmetic.
        0x80125B84: 0x94630B6C, 0x80125B90: 0x00031842, 0x80125B94: 0x02238821,
        0x80125BDC: 0x34020007, 0x80125BE0: 0x16820003, 0x80125BEC: 0x02201021,
        0x80125C14: 0x90430020, 0x80125C44: 0x001117C2, 0x80125C48: 0x34020003,
        0x80125C60: 0x00111040, 0x80125C6C: 0x00111043, 0x80125C70: 0x00001021,
        # Feature readers in ordinary attacks, the eligibility predicate, and death.
        0x800F4AD8: 0x30428000, 0x800F4AE4: 0x0C03DF57, 0x800F4AFC: 0x30420002,
        0x800F4B3C: 0x0C038E08, 0x800F4B60: 0x24635DB4, 0x800F4B74: 0x30420004,
        0x800F4BA4: 0x0C038E08, 0x800F4BC8: 0x24635C1C, 0x800F4F70: 0x30420008,
        0x800F4F7C: 0x0C03D357, 0x800F7950: 0x94420026, 0x800F7958: 0x30420001,
        0x800F796C: 0x30420001, 0x800F798C: 0x80430047, 0x800F79A4: 0x9043004C,
        0x800F79A8: 0x34020010, 0x800F79BC: 0x0C051F8E, 0x800F79C8: 0x30420001,
        0x801160A8: 0x94420026, 0x801160B0: 0x30424000, 0x801160B4: 0x1440001C,
        0x801160C8: 0xAC82002C, 0x801160D0: 0xA0400052, 0x801160E4: 0xA0550B85,
        0x801160F8: 0xA0550B86, 0x80116124: 0xAC350000,
    }.items():
        assert maindec.mword(pc) == word, hex(pc)


def check_records():
    expected_counts = dict(zip('ABCDEFGHZ', (5, 4, 4, 3, 4, 3, 3, 3, 3)))
    root = KIT.parent / 'game'
    policy = json.loads((root / 'assets/campaign_policies/enemy_policy.json').read_text())
    records = {row['id']: row for area in policy['areas'] for row in area['records']}
    trial = json.loads((root / 'tests/fixtures/journey_unites_battle.json').read_text())
    profiles = {row['id']: row for row in trial['enemies']}
    area_a_ids = ('bonbon', 'mosquito', 'crow', 'wild_boar', 'red_soldier_ant')
    element_names = ('fire', 'water', 'earth', 'lightning', 'wind')
    affinity = ('neutral', 'weak', 'resistant', 'immune')
    stat_names = ('attack', 'skill', 'defense', 'speed', 'magic', 'luck')

    counts, actual, bound = {}, [], set()
    for entry in areas.area_data_files():
        name = Path(entry['path']).name
        letter = name[0]
        if name != f'{letter}_DATA.BIN' or letter not in expected_counts:
            continue
        assert letter not in counts, name
        data = areas.load(entry)
        word = lambda address: struct.unpack_from('<I', data, address - areas.BASE)[0]
        descriptor = word(areas.BASE)
        resources = word(descriptor + 12)
        directory = word(resources)
        table = word(directory + 12)
        counts[letter] = word(table)
        assert counts[letter] == expected_counts[letter], name
        if letter == 'A':
            check_area_a_formations(data, word(directory + 8), table, area_a_ids, trial['encounters'])
        for index in range(1, counts[letter] + 1):
            address = word(table + 4 * index)
            offset = address - areas.BASE
            assert 0 <= offset <= len(data) - 64, (name, index)
            raw = data[offset:offset + 64]
            actual.append((address, raw))
            hp, = struct.unpack_from('<H', raw, 0x12)
            record_id = f'area_{letter.lower()}.enemy.{index:02}'
            if letter != 'Z':
                record = records[record_id]
                bound.add(record_id)
                assert (decode(raw, length=16)[0], raw[0x10], hp) == (
                    record['name'], record['level'], record['hp']), record_id
            if letter == 'A':
                profile = profiles[area_a_ids[index - 1]]
                assert (profile['level'], profile['max_hp']) == (raw[0x10], hp), record_id
                assert profile['stats'] == dict(zip(stat_names, struct.unpack_from('<6H', raw, 0x14))), record_id
                assert profile['affinities'] == dict(zip(element_names, (affinity[n] for n in raw[0x20:0x25]))), record_id
                assert profile['other_affinity'] == affinity[raw[0x25]], record_id
                flags, = struct.unpack_from('<H', raw, 0x26)
                for field, mask in (('death_immune', 0x4000), ('airborne', 0x20),
                                    ('dodges_attacks', 4), ('unavoidable_attack', 8)):
                    assert profile[field] == bool(flags & mask), (record_id, field)
    assert counts == expected_counts and bound == set(records) and len(bound) == 29

    # Follow room 4, entity 15, and its actual battle opcode through the section base.
    data, _ = source('/VB5A2.BIN')
    base = 0x80010000
    word = lambda address: struct.unpack_from('<I', data, address - base)[0]
    header = word(base)
    room = word(header + 8) + 4 * 16
    entry = word(room) + 15 * 24
    script = word(entry + 20)
    assert script == 0x80050870
    request = script - base + 0x29
    assert data[request:request + 3] == bytes((0x47, 0, 0xFD))
    section_id = data[room - base + 5]
    assert section_id == 8
    section = word(word(header + 4) + section_id * 4)
    index = word(section + 28) + data[request + 1]
    directory = word(word(section + 32) + index * 4)
    table = word(directory + 12)
    address = word(table + 4)
    assert (index, directory, address) == (12, 0x8007DA34, 0x800812D4)
    raw = data[address - base:address - base + 64]
    assert len(raw) == 64 and decode(raw, length=16)[0] == 'Assassin'
    assert struct.unpack_from('<BBH', raw, 0x10) == (18, 0, 2000)
    assert struct.unpack_from('<HIII', raw, 0x26) == (0x400E, 0x80081554, 0x80081ACC, 0x8001789C)
    actual.append((address, raw))
    assert len(actual) == 33 and all(0 in row[:16] for _, row in actual)
    assert sum(struct.unpack_from('<I', row, 0x28)[0] == addr + 64 for addr, row in actual) == 25


def check_area_a_formations(data, selectors, records, enemy_ids, encounters):
    word = lambda address: struct.unpack_from('<I', data, address - areas.BASE)[0]
    packaged = {row['id']: row for row in encounters if row['id'].startswith('area_a_')}
    assert word(selectors) == len(packaged) == 9
    for index in range(1, word(selectors) + 1):
        encounter = word(selectors + 4 * index)
        roster = data[encounter - areas.BASE + 4:encounter - areas.BASE + 10]
        positions = word(word(encounter + 0x14))
        slots, ids, coordinates = [], [], []
        for slot, enemy in enumerate(roster):
            if not enemy:
                continue
            assert 1 <= enemy <= len(enemy_ids)
            slots.append(slot)
            ids.append(enemy_ids[enemy - 1])
            x, y, z = struct.unpack_from('<3h', data, positions - areas.BASE + 6 * slot)
            record = word(records + enemy * 4)
            if data[record - areas.BASE + 0x26] & 0x20:
                z -= 10
            coordinates.append(dict(x=x - 128, y=y, z=z))
        expected = packaged[f'area_a_{index}']
        assert word(encounter) == len(slots)
        assert (expected['source_slots'], expected['enemies'], expected['positions']) == (slots, ids, coordinates)
        assert expected['enemy_rows'] == ['front' if slot < 3 else 'back' for slot in slots]


def check_layout_and_preview():
    fields = battle_formulas.participant_layout()['enemy_record_fields']
    expected = {
        'name_codes': (0x00, 16), 'level': (0x10, 1), 'formation_footprint': (0x11, 1),
        'hp': (0x12, 2), 'stats': (0x14, 12), 'element_coefficients': (0x20, 6),
        'features': (0x26, 2), 'actor_script_table': (0x28, 4), 'sprite_section': (0x2C, 4),
        'decision_callback': (0x30, 4), 'encoded_money': (0x34, 2), 'item_rate_pairs': (0x36, 6),
        'script_pixel_offsets': (0x3C, 4),
    }
    assert {key: (field['off'], field['size']) for key, field in fields.items()} == expected
    assert sorted(byte for start, width in expected.values() for byte in range(start, start + width)) == list(range(64))

    for footprints in ((1, 0, 3), (0, 2, 0), (3, 3, 3)):
        data = bytearray(192)
        for index, (level, hp, footprint) in enumerate(zip((10, 90, 90), (1000, 600, 500), footprints)):
            struct.pack_into('<BBH', data, 64 * index + 0x10, level, footprint, hp)
        table = dict(record_offsets=[0, 64, 128], section_offsets=[1, 2, 3])
        sections = [dict(header_offset=index, palettes=[[0]], atlases=[dict(atlas=b'x')]) for index in (1, 2, 3)]
        selected = enemy_sprites.strongest_entries(data, [table], sections)
        assert len(selected) == 1 and selected[0]['record'] == 64
        assert selected[0]['formation_footprint'] == footprints[1]


if __name__ == '__main__':
    check_consumers()
    check_records()
    check_layout_and_preview()
    print('PASS: nine static MAIN spans, 33 disc records, 29 policy bindings, five Journey profiles, '
          'nine Region A formations and three preview selections')
