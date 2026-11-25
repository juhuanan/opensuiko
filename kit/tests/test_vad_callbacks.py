#!/usr/bin/env python3
"""Static source contracts for VAD castle setup, MAGIC93 and KEKKAI."""
import hashlib
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
from disc import extract
import maindec as M

V = 0x80165608
B = 0x8016B680
SPANS = [
    (0x032C, 0x04CC, '3b4b83e0470faa8d8c301a998857d548ddc6971ed318c934b260da437000ace8'),
    (0x04CC, 0x052C, 'da3a455e739333fa8c62524748cd0b8c846e5a21bd6c446a2d7299f3bf72935a'),
    (0x2BFC, 0x2DBC, '652ba248b40c9e3a6fa288a530bb37be8f7b4d6416fff28af3266e2bbf4a93a2'),
    (0x2DBC, 0x331C, '2ea2e1e71a07fb66547dbe80a7a0d093fe3dcebab2a383f9d2295e1645d466fc'),
    (0xCF34, 0xE5A0, '2710d6b11d01bb654bff2ef81daccf9023ca87a2ef7d7e592e2fbf25c1317f29'),
]


def assert_words(data, slices):
    for off, words in slices.items():
        assert struct.unpack_from(f'<{len(words)}I', data, off) == words, hex(off)


def check_castle(data, rows):
    assert_words(data, {
        # Delegate via object+0x494, or allocate through MAIN+0x48 twice.
        0x034C: (0x8E020494, 0x3C12801B, 0x10400005, 0x3652A000,
                 0x0040F809, 0x26040494, 0x0800412D, 0x2402FFFF),
        0x0378: (0x8C420048, 0, 0x0040F809, 0x34046720),
        0x0394: (0xAC22A034, 0x8C620048, 0, 0x0040F809, 0x34046720),
        0x03B4: (0xAC22A038,),
        # Derive the two nonzero table indices. Every other branch retains zero.
        0x03F4: (0x00002021, 0x3C03801C, 0x90638034, 0x34020001, 0x10620006, 0x00002821,
                 0x34020002, 0x1062000A, 0x3402001B, 0x08004116, 0x308200FF,
                 0x92230000, 0x34020022, 0x1462000B, 0x308200FF, 0x34040001, 0x08004115,
                 0x34050001, 0x92230000, 0, 0x14620004, 0x308200FF, 0x34040001, 0x34050002),
        # Resolve the directory entry and call slot 0x10 at destination 0x80080000.
        0x0454: (0x308200FF, 0x10400012, 0x34020001, 0x8E4214B8, 0, 0x8C43003C,
                 0x00051080, 0x8E251BC4, 0x00431021, 0x8C440000, 0x8CA20010, 0,
                 0x0040F809, 0x3C058008),
        0x048C: (0x2402FFFF, 0xA642001E, 0x3C028001, 0x244204CC, 0x0800412C, 0xAE020498,
                 0xA2020034, 0xA2000035, 0xAE000498, 0x2402FFFF),
        # Only a zero result from slot 0x0C publishes completion.
        0x04E0: (0x8C42000C, 0x00808021, 0x0040F809, 0x00002021, 0x00401821, 0x2402FFFF,
                 0x10620008, 0, 0x14600006, 0, 0x34020001, 0xA2020034, 0xA2000035,
                 0xAE000498, 0x2402FFFF),
    })
    group = M.mword(0x8016B358 + 15 * 4)
    assert group == 0x8016B670
    for index, name in [(1, 'VB5A21.BIN'), (2, 'VB5B31.BIN')]:
        row = next(r for r in rows if r['path'].endswith('/' + name))
        record = M.mword(group + index * 4)
        assert (M.mword(record), M.mword(record + 4)) == (row['size'], row['lba'])


def check_magic(data):
    assert tuple(M.mword(pc) for pc in (0x800DDFB8, 0x800DDFBC, 0x800DDFC0)) == (
        0x3C038017, 0x2463B680, 0xAC431258)
    assert tuple(M.mword(B + slot) for slot in (4, 0x158, 0x10)) == (
        0x800E3820, 0x800F8174, 0x800E1654)
    assert_words(data, {
        # State and pointer array allocations, Q12 origin, sixteen child constructors.
        0x2C40: (0x8E150058, 0x8C620014, 0, 0x0040F809, 0x34040028, 0xAEA20000),
        0x2C60: (0x00031B03, 0x24630052, 0xAE230004, 0x8E02006C, 0, 0x00021303,
                 0xAE220008, 0x8E020070, 0, 0x00021303, 0x2442FFE7, 0xAE22000C),
        0x2C94: (0x34130040, 0x3412007F, 0x8C420014, 0x34040040, 0x0040F809, 0x00008021,
                 0xAE220000),
        0x2CB8: (0x8C4200BC, 0, 0x0040F809, 0x3404000A),
        0x2CF4: (0x3C020005, 0xACE20044, 0xACE60048, 0xACE5004C, 0x34020800,
                 0x18600016, 0xA4E20078),
        0x2D2C: (0xA0400004, 0xA0530005, 0xA0520006, 0xA040000C, 0xA053000D, 0xA052000E,
                 0x28820002, 0x1440FFF5, 0x24630004),
        0x2D64: (0x26100001, 0x2A020010, 0x1440FFD0, 0x34020001, 0xAE200014, 0xAE200018,
                 0xAE22001C, 0xAE200020, 0xAE200024, 0x3C028001, 0x24422DBC, 0xAEA20004),
        # Actor handle, signed target byte and phase dispatch.
        0x2E14: (0x8C560058, 0x00031880, 0x02631821, 0x8E621258, 0x80740B89, 0x8ED20000),
        0x2E40: (0x8E510018, 0x34020001, 0x1222003D, 0x2A220002, 0x10400005, 0,
                 0x12200008, 0, 0x08004C54, 0, 0x34020002, 0x1222008B),
        # Setup latch, initial cue, child range shrink, origin and phase counters.
        0x2E84: (0x10400012, 0x00008821, 0x34040001),
        0x2EA0: (0x26310001, 0xAC440070, 0x2A220010, 0x1440FFF8),
        0x2EBC: (0x8C420150, 0, 0x0040F809, 0x34040814, 0xAE40001C),
        0x2EE8: (0x8C620048, 0x26310001, 0x2442E800, 0xAC620048, 0x2A220010, 0x1440FFF5),
        0x2F04: (0x8E420004, 0x8E430014, 0x2442FFFF, 0xAE420004, 0x24630001, 0xAE430014,
                 0x28630020, 0x1460008B, 0x34020001, 0x8E430018, 0xAE400014, 0xAE42001C,
                 0x24630001, 0x08004C54, 0xAE430018),
        # Replace the integer portions of the head deltas and preserve both low 12-bit fields.
        0x2F74: (0x00021303, 0x8CC4002C, 0x00451023, 0x00021300, 0x30840FFF, 0x00822025,
                 0xACC4002C),
        0x2FA4: (0x00021303, 0x8CA40030, 0x00431023, 0x00021300, 0x30840FFF, 0x00822025,
                 0xACA40030, 0xAE40001C),
        0x2FC4: (0x8E430014, 0x34020020, 0x1462000A),
        0x2FDC: (0x8C420150, 0, 0x0040F809, 0x34040526, 0xAE510020),
        # Frame 40 passes actor and target through the effect, damage and HP-apply imports.
        0x2FF0: (0x8E430014, 0x34020028, 0x14620014, 0x02802021, 0x8E621258, 0,
                 0x8C420004, 0x3C068008, 0x24C62D5C, 0x0040F809, 0x02002821,
                 0x8E621258, 0x02002021, 0x8C420158, 0x02802821, 0x0040F809, 0x34060005,
                 0x8E631258, 0, 0x8C630010, 0x02802021, 0x0060F809, 0x00402821),
        0x304C: (0x8E420014, 0x3403004E, 0x24420001, 0x14430006, 0xAE420014),
        0x3070: (0xAC400070, 0x8E420014, 0, 0x28420050, 0x14400033, 0,
                 0x8E420018, 0, 0x24420001, 0x08004C54, 0xAE420018),
        # Free three allocations per child, then the array and state. Bypass drawing.
        0x30B0: (0x8C440000, 0x8C620018, 0, 0x0040F809, 0x26310001),
        0x30D8: (0x8C440004, 0x8C620018, 0, 0x0040F809),
        0x30F8: (0x8E040000, 0x8C620018, 0, 0x0040F809, 0, 0x2A220010, 0x1440FFE2),
        0x3118: (0x8E621258, 0x8E440000, 0x8C420018, 0, 0x0040F809),
        0x3138: (0x8C420018, 0, 0x0040F809, 0x02402021, 0x08004CBC, 0xAEC00004),
        # Signed division toward zero, sine phase from age, and age-24 cutoff.
        0x3180: (0x8E420024, 0x8E03002C, 0x24420001, 0x00430018, 0x00001012),
        0x319C: (0x04410002, 0, 0x24420007, 0x000210C3, 0xAE020020),
        0x31CC: (0x04410002, 0, 0x24420007, 0x000210C3, 0xAE020024),
        0x31E8: (0x8C420080, 0, 0x0040F809, 0x000421C0, 0x00021840, 0x00621821,
                 0x00031880, 0xAE030028),
        0x3210: (0x24420001, 0xAE420024, 0x28420018, 0x14400002, 0, 0xAE000070),
        # Draw the head, then copy positions and activity in descending child order.
        0x3240: (0x8C6200C0, 0, 0x0040F809, 0x02002021, 0x3411000F),
        0x3260: (0x8C430000, 0x8C42FFFC, 0, 0x8C440020, 0x8C450024, 0x8C460028,
                 0xAC640020, 0xAC650024, 0xAC660028, 0x8C420070, 0x2631FFFF, 0x1E20FFF1,
                 0xAC620070),
    })


def check_kekkai(data):
    assert struct.unpack_from('<I', data, 0xE620)[0] == 0x8001CF34
    assert struct.unpack_from('<5I', data, 0x17C) == (
        0x8001D71C, 0x8001DBD0, 0x8001DD8C, 0x8001DFB8, 0x8001E254)
    assert M.mword(V + 0x14) == 0x80142D48
    assert (M.mword(0x80142D5C), M.mword(0x80142D60)) == (0xA020DA40, 0x0C030B70)
    assert_words(data, {
        # Constructor publishes state, converts four operand pairs to corner coordinates,
        # and builds 68-byte records with G4/G2 commands and 20-tick edges.
        0xCFD4: (0x8C420048, 0, 0x0040F809, 0x34040048),
        0xD028: (0x3C05800A, 0x8CA591FC),
        0xD0EC: (0x94630000, 0x94A50000, 0x000210C0, 0x00431023, 0x00451021),
        0xD110: (0x8CC20010, 0x8CC50018, 0x94460000),
        0xD140: (0x000318C0, 0x24420008, 0x3C01800A, 0x24219104, 0x00240821, 0xA4220000,
                 0x00661823, 0x00651821),
        0xD1A4: (0x2463FF60,),
        0xD1C8: (0x26520001, 0x2442FF88),
        0xD1E0: (0x324200FF, 0x2C420004, 0x1440FF8F, 0x34150020, 0x00009021, 0x341400C8),
        0xD244: (0x324200FF, 0x00028900, 0x02228821, 0x00118880, 0x02368021,
                 0x34020008, 0xA2020003, 0x34020038, 0xA2020007),
        0xD270: (0x8C420054, 0x02002021, 0x0040F809, 0x34050001, 0xA2000004, 0xA2150005,
                 0xA2140006),
        0xD2B4: (0x34020004, 0xA2220003, 0x34020050, 0xA2220007),
        0xD304: (0x340A0014,),
        0xD374: (0x00431023, 0x004A001A),
        # Serial edges skip spent countdowns, submit four lines, and start convergence
        # only on the next update with no edge advanced.
        0xD6EC: (0x34020004, 0x0043102B, 0x1440032C),
        0xD758: (0x90220000, 0, 0x10400034, 0x34020001, 0x3C01800A, 0xA42291DC),
        0xD7B0: (0x2442FFFF, 0x3C01800A, 0x2421910C, 0x00270821, 0xA0220000),
        0xD80C: (0x14C0001F, 0, 0x8FC21BC4, 0, 0x8C4200AC, 0, 0x0040F809, 0x34040527),
        0xD894: (0x2C420004, 0x10400006),
        0xD8E4: (0x8C6201C8, 0x3406000A, 0x0040F809),
        0xD904: (0x3C02800A, 0x944291DC, 0, 0x144002A5, 0x00009021),
        0xD920: (0x34040014, 0x34030001, 0xA0430000, 0x3402004F, 0x3C01800A, 0xA02291F4),
        0xD954: (0xA0240000, 0x26520001, 0x324200FF, 0x2C420004, 0x1440FFF5),
        # Convergence adjusts the inner vertices. Phase 2 begins at zero countdown.
        0xDC5C: (0x2442FFFF, 0xA2E20000, 0x006F1821, 0xA6E3FFD8, 0x00902021, 0xA6E4FFE2),
        0xDD08: (0x92E20000, 0, 0x144001A4, 0x34020002),
        # Only an idle colour update can move to the next phase.
        0xDD8C: (0x3C01800A, 0xA42091DC, 0x00009021, 0x340700FE),
        0xDF38: (0x324200FF, 0x2C420004, 0x1440FF9A),
        0xDFA0: (0x14400100, 0x34020003),
        0xDFC4: (0x340700FE,),
        0xE164: (0x324200FF, 0x2C420004, 0x1440FF9A),
        0xE1C4: (0x944291DC, 0, 0x14400076),
        0xE1DC: (0x34020004, 0xA0620000),
        0xE1EC: (0x8C4200AC, 0, 0x0040F809, 0x34040011),
        0xE204: (0x8C4200AC, 0x00009021, 0x0040F809, 0x34040813, 0x34040014),
        0xE234: (0xA0240000, 0x26520001, 0x324200FF, 0x2C420004, 0x1440FFF5),
        # Collapse continues until the countdown expires and publishes outer state 2.
        0xE25C: (0x91020000, 0, 0x2442FFFF, 0xA1020000),
        0xE38C: (0x15000005, 0x34020002, 0x3C03800A, 0x8C6391FC, 0, 0xA0620000),
        # Submit four colour quads to the context's draw destination and use slot 0x14 at finish.
        0xE3C8: (0x8C450040, 0x00042080, 0x00902021, 0x8C6201C8, 0x3406000A, 0x0040F809,
                 0x26520001, 0x324200FF, 0x2C420004, 0x1440FFF1),
        0xE560: (0x8C420014, 0, 0x0040F809),
    })
    # Both phases visit six channels per record. The branch skips the byte write at FE.
    for first, channels in [(0xDDCC, (12, 13, 14, 28, 29, 30)), (0xDFF8, (4, 5, 6, 20, 21, 22))]:
        for i, channel in enumerate(channels):
            branch = first + 0x40 * i
            assert_words(data, {
                branch - 0x10: (0x242190CC + channel, 0x00240821, 0x90220000, 0),
                branch: (0x1047000A,),
                branch + 0x1C: (0x24420001, 0xA0620000 | channel, 0x3C01800A, 0xA42591DC),
            })
    # A shared 80-update counter triggers the same cue from phases 1–3.
    for threshold, call in [(0xDCDC, 0xDCF0), (0xDF68, 0xDF7C), (0xE194, 0xE1A8)]:
        assert_words(data, {
            threshold: (0x34020050, 0x14620009),
            call: (0x8C4200AC, 0, 0x0040F809, 0x34040806, 0x3C01800A, 0xA02091F4),
        })


def check():
    rows = json.loads((KIT / 'extracted/iso_files.json').read_text())
    source = next(row for row in rows if row['path'] == 'DATA/15_AREA.Z/VAD.BIN')
    assert (source['lba'], source['size']) == (179575, 561700)
    data = extract(source['lba'], source['size'])
    for start, end, digest in SPANS:
        assert hashlib.sha256(data[start:end]).hexdigest() == digest, hex(start)
    check_castle(data, rows)
    check_magic(data)
    check_kekkai(data)
    print('PASS: five complete VAD source spans, castle loader, MAGIC93 phases and services, '
          'all five KEKKAI phase contracts')


if __name__ == '__main__':
    check()
