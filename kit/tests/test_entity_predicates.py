#!/usr/bin/env python3
"""Static source checks for entity classification, event selection and graphics state."""
import hashlib
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import maindec as M
from mipsdec import jtarget, sx16

CLASSIFICATION = (
    0x8013DB48, 0x8013D9B8, 0x8013D9B8, 0x8013D9B8, 0x8013D9B8, 0x8013D9B8,
    0x8013D9B8, 0x8013D95C, 0x8013D974, 0x8013D92C, 0x8013D944, 0x8013D9B8,
    0x8013D9B8, 0x8013D9B8, 0x8013D98C, 0x8013D9A0, 0x8013D9C0, 0x8013D9F4,
    0x8013D9B8, 0x8013DA28, 0x8013DA48, 0x8013DA74, 0x8013DAF8, 0x8013D9B8,
    0x8013D9B8, 0x8013DB10,
)
EVENT_SELECTION = (
    0x8013E004, 0x8013DC68, 0x8013DCA4, 0x8013DDE4, 0x8013DD38, 0x8013DD74,
    0x8013DBC8, 0x8013DD84, 0x8013DD9C, 0x8013DDB4, 0x8013DDCC, 0x8013DCE0,
    0x8013DD0C, 0x8013DC28, 0x8013DE04, 0x8013DE18, 0x8013DE38, 0x8013DE6C,
    0x8013DEA0, 0x8013DEC8, 0x8013DEE8, 0x8013DF14, 0x8013DF98, 0x8013DFB0,
    0x8013DFB0, 0x8013DFCC,
)
SPANS = (
    ('classification', 0x8013D8E0, 0x8013DB6C, '50e2ed023ff810a38121677f0a538cd6f36e04370b95e63116b90bfe36aa88a5'),
    ('event selection', 0x8013DB6C, 0x8013E028, 'b2667024a22ee484f4985471906c3e3cb6c3f356a2bf65ddd375f6bdf934a845'),
    ('party membership', 0x8013D330, 0x8013D3CC, 'bd28052c7e78a54a109a4d78944abc00c3a42cf66d031edd883564eed1fbd145'),
    ('interaction', 0x8013D3CC, 0x8013D6CC, '78cdf62854bef99e950417f8157c87949f9181185d6005267365765a4e33fc53'),
    ('flag banks', 0x8013D6CC, 0x8013D758, 'b247d1cd978541a7027cfd714eab137cf1903cc66b3b6757186cbeef971aab31'),
    ('recruit threshold', 0x8013D758, 0x8013D788, 'f13023bb89e5af17b25a69b4cb7cc923d037ac32cff8a0b8b44e0517abb1d968'),
    ('persistent level', 0x8013D788, 0x8013D7E4, '5b6a26400c3325616e6df658da2789b9f9ebc96b99b62851e8c46a3345912546'),
    ('inventory', 0x8013D7E4, 0x8013D8E0, '1eb6dddf59e33ee4b5d4e5337bfcc8ccaf189cd3cfa783e320918847b9b2cbf3'),
    ('recruit count', 0x801395AC, 0x801395FC, '2064c2b8184d4cbca2fe202ae9185bcd97954850581a22e31cc335bfda47e013'),
    ('graphics state', 0x8012EA40, 0x8012EB88, 'f0f2b04ea90e29dc3ed9263172b7094536b90ef2ffb6ff8a69de5b941103540f'),
)


def assert_words(groups):
    for start, words in groups.items():
        assert tuple(M.mword(start + 4 * index) for index in range(len(words))) == words, hex(start)


def check_dispatch():
    for table, expected, loop, guard, bound in [
        (0x800C1998, CLASSIFICATION, 0x8013DB48, 0x8013D900, 0x8013DB54),
        (0x800C1A00, EVENT_SELECTION, 0x8013E004, 0x8013DBFC, 0x8013E010),
    ]:
        maximum = sx16(M.mword(bound))
        assert len(expected) == maximum + 1 == 26
        assert tuple(M.mword(table + 4 * opcode) for opcode in range(maximum + 1)) == expected
        # Opcode zero jumps straight back to the opcode read at the same cursor.
        # Terminator 06 bypasses the switch. The switch rejects unsigned opcodes above 19.
        assert expected[0] == loop
        assert M.mword(loop) == 0x92030000
        assert M.mword(loop + 4) == 0x34020006
        assert loop + 12 + 4 * sx16(M.mword(loop + 8)) == guard
        assert M.mword(guard) == 0x0043102B
    unsupported = (1, 2, 3, 4, 5, 0xB, 0xC, 0xD, 0x12, 0x17, 0x18)
    reject = CLASSIFICATION[1]
    assert tuple(op for op in range(26) if CLASSIFICATION[op] == reject and op != 6) == unsupported
    assert_words({
        # Classification returns 1 for a null input, 2 for rejection and 0 for 06.
        0x8013D8EC: (0x00808021, 0x16000095, 0x34020001, 0x0804F6D7, 0),
        0x8013D900: (0x0043102B, 0x14400095, 0x34020002),
        0x8013D9B8: (0x0804F6D7, 0x34020002),
        0x8013DB48: (0x92030000, 0x34020006, 0x1462FF6B, 0x34020019, 0x00001021),
        # Entry flag 08 increments the halfword at 8017BE28 before either mode branch.
        0x8013DB80: (0x94620004, 0, 0x30420008, 0x10400007, 0, 0x3C028018, 0x9442BE28,
                     0, 0x24420001, 0x3C018018, 0xA422BE28),
        # Nonzero mode requires flag 10 set. Zero mode requires it clear.
        0x8013DBAC: (0x10800008, 0, 0x94620004, 0, 0x30420010, 0x14400008, 0,
                     0x0804F806, 0x00001021, 0x94620004, 0, 0x30420010, 0x1440010E, 0x00001021),
        0x8013DBFC: (0x0043102B, 0x14400105, 0x00001021),
        0x8013E004: (0x92030000, 0x34020006, 0x1462FEFB, 0x34020019, 0x34020001),
        # Both builder passes read entry+0C through their respective base offsets.
        0x8012EDD0: (0x26900004,),
        0x8012EDE8: (0x8E040008, 0x0C04F638, 0, 0x304300FF, 0x1460000E, 0x34020002,
                     0x96020000, 0, 0x30420080, 0x1040000B),
        0x8012EE34: (0x14620021, 0, 0x96020000),
        0x8012EF38: (0x26900008,),
        0x8012EF54: (0x8E040004, 0x0C04F638),
        # The event predicate reads +10. The distinct tick setup publishes +14.
        0x8013DBF0: (0x8C500010, 0x0804F801, 0),
        0x8013E1EC: (0x3C028018, 0x8C42A120, 0, 0x8C420014, 0, 0x3C018018, 0xAC22AF84),
        0x801397F4: (0xA06204E0,),
    })


def check_helpers():
    assert_words({
        # Strict lower/upper bounds for 01/02, inclusive ones for 0B/0C.
        0x8013DC7C: (0x0043102B, 0x1040FFD1, 0x26100001, 0x92020000, 0,
                     0x0062102B, 0x144000DB, 0x26100001),
        0x8013DCB8: (0x0043102B, 0x1040FFC2, 0x26100001, 0x92020000, 0,
                     0x0062102B, 0x144000CC, 0x26100001),
        0x8013DCF4: (0x0062102B, 0x1440FFB3, 0x26100001, 0x92020000, 0x0804F7C1, 0x0043102B),
        0x8013DD20: (0x0062102B, 0x1440FFA8, 0x26100001, 0x92020000, 0x0804F7C1, 0x0043102B),
        # Currency compares a signed word with 100 times the unsigned operand.
        0x8013DC38: (0x308400FF, 0x00041040, 0x00441021, 0x000210C0, 0x8C63001C,
                     0x00441021, 0x00021080, 0x0062182A),
        # Both opcode 15 arms divide 32767 by n+1, then divide the random
        # sample by that quotient. MFLO selects the quotient each time.
        **{start: (0x92040000, 0x34037FFF, 0x24840001, 0x0064001A)
           for start in (0x8013DA7C, 0x8013DF1C)},
        **{start: (0x00001812, 0, 0x0043001A) for start in (0x8013DAB0, 0x8013DF50)},
        0x8013DAE0: (0x00001012, 0x26100001, 0x10400017),
        0x8013DF80: (0x00001012, 0x26100001, 0x1040001E),
        # Level lookup is by ID, with 78 records. Party membership and
        # inventory walks reject order slots >=6 before following the pointer.
        0x8013D79C: (0x8C620294, 0, 0x14440008, 0, 0x906202A1, 0, 0x0045102B),
        0x8013D7C8: (0x24C60005, 0x28C20186, 0x1440FFF2, 0x24630050),
        0x8013D378: (0x2C620006, 0x1040000A, 0x00031080, 0x004B1021, 0x8C421B9C),
        0x8013D824: (0x2C620006, 0x10400025, 0x00031080, 0x004E1021, 0x8C421B9C, 0, 0x8C47001C),
        0x8013D874: (0x108D0018, 0x34020001, 0x8D420000, 0, 0x9442001C, 0, 0x30420080,
                     0x10400007, 0, 0x80620022),
        # Recruit count uses the 108 indexed bytes, requiring bit 0 set and bit 1 clear.
        0x801395C4: (0x90431AF4, 0, 0x30620001, 0x10400005, 0x24840001, 0x30620002, 0x14400003,
                     0x2882006C, 0x24A50001, 0x2882006C, 0x1440FFF3),
        0x8013D3E0: (0x30420041, 0x14400005),
    })
    for call, target in {
        0x8013DA74: 0x80147E38, 0x8013DF14: 0x80147E38,
        0x8013D764: 0x801395AC, 0x8013DFBC: 0x8013D7E4,
        0x8013DD74: 0x8013D3CC, 0x8013D5BC: 0x8013CCF0,
        0x8013D680: 0x80137304, 0x8013D6A4: 0x801373D4,
    }.items():
        word = M.mword(call)
        assert (word >> 26, jtarget(call, word)) == (3, target), hex(call)
    image = M.body()
    for table, expected in [
        (0x801716E4, (0, 0, -1, 2)), (0x801716EC, (2, -1, 0, 0)),
        (0x801716F4, (0, 0, -2, 2)), (0x801716FC, (2, -1, 0, 0)),
    ]:
        assert struct.unpack_from('<4h', image, table - M.MBASE) == expected
    assert image[0x80171704 - M.MBASE:0x80171708 - M.MBASE] == bytes((1, 0, 3, 2))
    assert tuple(M.mword(0x80171708 + 4 * i) for i in range(4)) == (0x1000, 0x2000, 0x4000, 0x8000)
    for item in (7, 8):
        descriptor = M.mword(0x80167658 + 4 * item)
        flags, = struct.unpack_from('<H', image, descriptor + 0x1C - M.MBASE)
        assert flags & 0x80


def check_graphics_state():
    assert_words({
        0x8012EA40: (0x8C820008, 0, 0xA0450000, 0x8C82000C, 0, 0xA0450000,
                     0x8C820010, 0, 0xA0450000),
        # Clear the byte on entry. State 1 writes 1 and state 3 writes 2.
        0x8012EA64: (0x30A500FF, 0x34020001, 0x10A2000E, 0xA0800004),
        0x8012EA90: (0x10A30007, 0x34020003, 0x10A20007, 0x00061400),
        0x8012EAA8: (0x0804BAAF, 0xA0850004, 0x0804BAAF, 0xA0800004, 0xA0830004),
        # The FF selector takes the context path. A fallback stores -entity[1].
        0x8012EAC4: (0x340300FF, 0x10430019, 0),
        0x8012EB70: (0x90820001, 0, 0x00021023, 0xA0820016),
    })
    for call in (0x8012F25C, 0x8013A978, 0x8013ABA4):
        word = M.mword(call)
        assert (word >> 26, jtarget(call, word)) == (3, 0x8012EA40), hex(call)


def check():
    image = M.body()
    for label, start, end, digest in SPANS:
        assert hashlib.sha256(image[start - M.MBASE:end - M.MBASE]).hexdigest() == digest, label
    check_dispatch()
    check_helpers()
    check_graphics_state()
    print('PASS: two 26-entry source tables, ten instruction spans, entry/mode gates and graphics-state writers')


if __name__ == '__main__':
    check()
