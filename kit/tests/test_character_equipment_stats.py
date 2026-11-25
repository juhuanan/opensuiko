#!/usr/bin/env python3
"""Static source checks of the eight equipment-stat columns and their UI labels."""
from hashlib import sha256
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import character_table as CT
import item_tables
import maindec as M
from test_canonical_start import assert_main_words
from war_text import decode


def check_stat_consumer():
    start, end = 0x800D4EC0, 0x800D50A4
    body = M.body()[start-M.MBASE:end-M.MBASE]
    assert sha256(body).hexdigest() == '2c4ed45496b0a333c178071281d150de5e3cef14a590453bdbef26725de9b62b'
    assert_main_words({
        # The dispatch skips elements 1/2/4 and adjusts columns 2/1 for 3/5.
        0x800C1004: (0x800D4F84, 0x800D4F84, 0x800D4F54, 0x800D4F84, 0x800D4F70),
        # The copy and signed equipment add loops write six and eight halfwords.
        0x800D4ED8: (0x01441021, 0x90420010, 0x24840001, 0xA4620000, 0x28820006, 0x1440FFFA, 0x24630002),
        0x800D4FB8: (0x9462001C, 0, 0x30420080, 0x10400013, 0, 0x80E20022, 0, 0x1040000F),
        0x800D4FF8: (0x00021600, 0x00021603, 0x00431021, 0xA4A20000, 0x28820008, 0x1440FFF6, 0x24A50002),
        0x800D5094: (0xA502000C, 0x2402FFFF, 0x03E00008, 0x27BD0008),
    })
    # Indexed stores in the two loops are covered above. Remaining stores use
    # fixed output offsets; the persistent input record has no store site.
    stores = [(start + 4 * i, word) for i, (word,) in enumerate(struct.iter_unpack('<I', body))
              if 0x28 <= word >> 26 <= 0x2E]
    assert stores == [
        (0x800D4EE4, 0xA4620000), (0x800D4EF4, 0xA500000C), (0x800D4EF8, 0xA500000E),
        (0x800D4F18, 0xA5020006), (0x800D4F6C, 0xA5030004), (0x800D4F80, 0xA5030002),
        (0x800D5004, 0xA4A20000), (0x800D503C, 0xA502000C), (0x800D5044, 0xA503000E),
        (0x800D5094, 0xA502000C),
    ]


def check_weapon_rows():
    # Cross-check the catalogue against the whole source table. Each of the
    # 78 initial records must resolve through its metadata selector.
    image = M.body()
    rows = [list(row) for row in struct.iter_unpack('<16H', image[0x801659F0-M.MBASE:0x801663D0-M.MBASE])]
    assert len(rows) == 79
    assert [row['levels'] for row in item_tables.sharpen_table()] == rows
    weapon_pointers = struct.unpack_from('<79I', image, 0x80165894-M.MBASE)
    seeds = CT.image()[CT.IMAGE_OFF:CT.IMAGE_OFF + 80 * 78]
    assert len(seeds) == 80 * 78
    for offset in range(0, len(seeds), 80):
        weapon, level = seeds[offset + 0x44:offset + 0x46]
        assert 1 <= weapon <= len(weapon_pointers) and 1 <= level <= 16
        curve = image[weapon_pointers[weapon - 1] - M.MBASE + 0x54]
        assert 1 <= curve <= len(rows)


def check_status_labels():
    start, end = 0x800CF930, 0x800CFA04
    assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == (
        '48bca61e8a351cd93db7f6897dc1edfe8348a9e98a862e0f32233ebf28bf0fc3')
    assert_main_words({
        # Both three-column loops read unsigned halfwords from the same vector.
        0x800CF924: (0x00008021, 0x3C128017, 0x2652A984, 0x0C0353B0, 0x24A500D0),
        0x800CF98C: (0x946500D0, 0x34060003, 0x0C051BFA, 0x26100001, 0x2A020003, 0x1440FFED),
        0x800CF9A8: (0x00008021, 0x3C128017, 0x2652A990),
        0x800CF9E8: (0x944500D6, 0x34060003, 0x0C051BFA, 0x26100001, 0x2A020003, 0x1440FFED),
    })
    pointers = struct.unpack_from('<6I', M.body(), 0x8016A984 - M.MBASE)
    names = [decode(M.body()[p-M.MBASE:p-M.MBASE+8].split(b'\0')[0])[0].strip() for p in pointers]
    assert names == ['PWR', 'SKL', 'DEF', 'SPD', 'MGC', 'LUK']


def check():
    check_stat_consumer()
    check_weapon_rows()
    check_status_labels()
    print('PASS: static equipment stat helper, 79 weapon power rows, 78 character bindings and six UI labels')


if __name__ == '__main__':
    check()
