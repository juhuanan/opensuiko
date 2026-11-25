#!/usr/bin/env python3
"""Static rune-piece selection, persistent counters and battle consumers."""
from hashlib import sha256
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import battle_formulas as formulas
import character_table as characters
import maindec as main
from war_text import decode


def check():
    labels = ['Fire rune piece', 'Water rune piece', 'Wind rune piece', 'Thunder rune piece', 'Earth rune piece']
    for table, first in ((0x8016AA14, 1), (0x80167658, 57)):
        pointers = [main.mword(table + 4 * i) for i in range(first, first + 5)]
        assert [decode(main.body(), address - main.MBASE)[0] for address in pointers] == labels

    for start, end, digest in (
        (0x800D6C48, 0x800D7014, '8e0e0f721e4f580b7146ecb22c730f5a4682ab6afbd02dec6b2d26bb699b1063'),
        (0x800D7014, 0x800D7678, '474c80bbaf301d11b711937130c0751e96a26c6c392174a3ce62acf8d0803b69'),
        (0x800CA408, 0x800CA50C, '80b0dc579003fc770c4cd42ab54bb34c63f3575c8be8177e428e143810a73f56'),
    ):
        assert sha256(main.body()[start-main.MBASE:end-main.MBASE]).hexdigest() == digest, hex(start)

    for kind in range(1, 6):
        address = main.mword(0x800C1080 + 4 * (kind - 1))
        assert address == 0x800D6E30 + 16 * (kind - 1)
        assert main.mword(address + (12 if kind < 5 else 8)) == 0x34020000 + kind
    assert [main.mword(0x800C1098 + 4 * state) for state in (1, 10, 20, 21)] == [
        0x800D70F8, 0x800D7380, 0x800D74E0, 0x800D75F4,
    ]
    assert [main.mword(0x800C1004 + 4 * i) for i in range(5)] == [
        0x800D4F84, 0x800D4F84, 0x800D4F54, 0x800D4F84, 0x800D4F70,
    ]

    for pc, word in {
        # Inventory ID maps to a type. Owner, inventory index and target have separate slots.
        0x800D6DB4: 0x8E83001C, 0x800D6DB8: 0x00021080, 0x800D6DC0: 0x94700020,
        0x800D6DE4: 0x2603FFC7, 0x800D6E18: 0x24211080, 0x800D6E28: 0x00400008,
        0x800D6E7C: 0xAC620078, 0x800D6E98: 0x8C650060, 0x800D6EA4: 0xAC620074,
        0x800D6F24: 0x24427014, 0x800D707C: 0x24211098, 0x800D708C: 0x00400008,
        # Active type mismatch opens confirmation. Empty or matching type requires count < 9.
        0x800D7180: 0xAC62007C, 0x800D718C: 0x8C500048, 0x800D7198: 0x8E04001C,
        0x800D71A0: 0x90830046, 0x800D71A8: 0x10600008, 0x800D71C4: 0x14430015,
        0x800D71E4: 0x90420046, 0x800D71EC: 0x2C420009, 0x800D71F0: 0x144000A9,
        0x800D71F4: 0x34020014, 0x800D7210: 0xAC400000, 0x800D7294: 0x3402000A,
        0x800D72A0: 0xAC620000, 0x800D749C: 0xAC620000,
        # Commit increments the chosen byte, zeros other counts, then removes from the source.
        0x800D74EC: 0x8C62007C, 0x800D7500: 0x8C500048, 0x800D7518: 0x10820006,
        0x800D7530: 0xA0400046, 0x800D753C: 0xA0440046, 0x800D754C: 0x90620046,
        0x800D7554: 0x24420001, 0x800D7558: 0xA0620046, 0x800D7560: 0x28820006,
        0x800D7590: 0x8C620060, 0x800D7594: 0x8C650074, 0x800D75A4: 0x0C032902,
        0x800D75C0: 0x24420001, 0x800D75C8: 0xAC620000,
        # The remover compacts full entries, preserves FF flags and returns the inactive tail.
        0x800CA410: 0x8C84001C, 0x800CA414: 0x0C03290B, 0x800CA470: 0x2442FFFF,
        0x800CA474: 0xA102001F, 0x800CA490: 0x88C20027, 0x800CA494: 0x98C20024,
        0x800CA49C: 0xA8C20023, 0x800CA4A0: 0xB8C20020, 0x800CA4B0: 0x1440FFF7,
        0x800CA4B8: 0x83A30002, 0x800CA4BC: 0x2402FFFF, 0x800CA4C8: 0xA3A00002,
        0x800CA4E8: 0xA8430023, 0x800CA4EC: 0xB8430020, 0x800CA4FC: 0x24420020,
        0x800CA500: 0x01021021,
        # Display, equipment-stat and physical damage consumers read the selected counters.
        0x800CFCA4: 0x90510046, 0x800CFCB8: 0x90500046, 0x800CFCD0: 0x2421AA14,
        0x800D4F54: 0x90A40005, 0x800D4F60: 0x00441021, 0x800D4F6C: 0xA5030004,
        0x800D4F70: 0x90A20007, 0x800D4F78: 0x00021040, 0x800D4F80: 0xA5030002,
        0x800F80E0: 0x10820003, 0x800F80E4: 0x34020003, 0x800F80E8: 0x14820015,
        0x800F80F0: 0x34020014, 0x800F8124: 0x90630002, 0x800F813C: 0x02028021,
    }.items():
        assert main.mword(pc) == word, hex(pc)

    template = characters.image()
    records = characters.records()
    assert len(records) == 78
    for index, record in enumerate(records):
        offset = characters.IMAGE_OFF + 80 * index
        assert template[offset + 0x46:offset + 0x4C] == bytes(6)
        assert record['element_coefficients'] == list(template[offset + 0x47:offset + 0x4C])

    for kind in range(1, 6):
        for count in range(256):
            for action in (0, 1):
                # Difference 300 and draw 17 yield 326 before fragments. Enemy Defend is ignored.
                want = 326 + 16 * count if kind in (1, 3) else 326
                assert formulas.physical_damage(400, 100, 17, element_type=kind, target_action=action,
                    element_bonus=count, target_is_party=False) == want, (kind, count, action)
    print('PASS: static rune-piece cap, replacement, commit, inventory removal and display/stat consumers')
    print('PASS: 78 character records and 2560 physical modifier cases')


if __name__ == '__main__':
    check()
