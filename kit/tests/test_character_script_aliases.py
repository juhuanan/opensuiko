#!/usr/bin/env python3
"""Static writer, predicate and source-census checks for indexed GS aliases."""
import hashlib
from pathlib import Path
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import character_script_aliases as A
import data_overlays as D
import event_script_reachability as R
import maindec as M
from mipsdec import sx16

ALIASES = {0x2B: (0, 0x17), 0x32: (0, 0x1E),
           0x62: (0, 0x4E), 0x63: (0, 0x4F),
           0x7B: (1, 0x17), 0x82: (1, 0x1E),
           0xB2: (1, 0x4E), 0xB3: (1, 0x4F),
           0xCB: (2, 0x17), 0xD2: (2, 0x1E)}


def check_consumers():
    assert M.mword(0x80171718 + 4 * 0x16) == 0x8013CC04
    assert [M.mword(0x800C1A00 + 4 * opcode) for opcode in (7, 8, 9, 10)] == [
        0x8013DD84, 0x8013DD9C, 0x8013DDB4, 0x8013DDCC,
    ]
    image = M.body()
    for start, end, expected in [
        (0x8013E028, 0x8013E17C, 'de21a37e1a6a09ebe58814d58dac4e65135ed9414df9dbef4146e5f361387477'),
        (0x8013DB6C, 0x8013E028, 'b2667024a22ee484f4985471906c3e3cb6c3f356a2bf65ddd375f6bdf934a845'),
    ]:
        assert hashlib.sha256(image[start - M.MBASE:end - M.MBASE]).hexdigest() == expected, hex(start)

    spans = {
        # Read two unsigned operands, advance the persistent cursor by two,
        # and write the OR in the return delay slot. This is the whole writer.
        0x8013CC04: (0x3C038018, 0x8C63AF84, 0x3C048018, 0x8C84DB24, 0x24620001, 0x3C018018,
                     0xAC22AF84, 0x90650000, 0x24620002, 0x3C018018, 0xAC22AF84, 0x90630001,
                     0x00852021, 0x90820280, 0, 0x00431025, 0x03E00008, 0xA0820280),
        # Whole predicate helper. A2 chooses the bank. A1 chooses which
        # mask result returns the advanced pointer. The other result is zero.
        0x8013D6CC: (0x30C600FF, 0x14C00009, 0x24840001, 0x3C028018, 0x8C42DB24, 0x90830000,
                     0, 0x00431021, 0x90430280, 0x0804F5C4, 0x24840001, 0x90830000, 0x3C028018,
                     0x8C42DB24, 0x24840001, 0x00431021, 0x90430190, 0x30A200FF, 0x10400008, 0,
                     0x90820000, 0, 0x00621024, 0x10400008, 0x24840001, 0x0804F5D4, 0x00801021,
                     0x90820000, 0, 0x00621024, 0x1040FFFA, 0x24840001, 0x00001021, 0x03E00008, 0),
        # The tick consumes the opcode before dispatch. Its ordinary route
        # indexes the handler table by opcode alone, then loops when enabled.
        0x8013E034: (0x3C048018, 0x8C84AF84, 0, 0x24820001, 0x3C018018, 0xAC22AF84, 0x90850000),
        0x8013E084: (0x0804F84E, 0x00051080, 0x340200FD, 0x10620012),
        0x8013E0DC: (0x3C028018, 0x9442C028, 0, 0x30420003, 0x10400009, 0x34020001),
        0x8013E114: (0x3C018017, 0xA0201C28, 0x3C018017, 0xA0221C29, 0x34020001, 0x3C018018,
                     0xAC22DC4C, 0x0804F85B, 0x320200FF),
        0x8013E130: (0x0804F85B, 0x320200FF, 0x3C018017, 0x24211718, 0x00220821, 0x8C220000,
                     0, 0x0040F809, 0, 0x3C028018, 0x9042A180, 0, 0x1440FFB4, 0),
        # The entity predicate uses a distinct table and stream. Verify its
        # entry, selector, both bank/mask pairs and the continuations.
        0x8013DBE4: (0x3C028018, 0x8C42A120, 0, 0x8C500010, 0x0804F801, 0, 0x0043102B,
                     0x14400105, 0x00001021, 0x00031080, 0x3C01800C, 0x24211A00, 0x00220821,
                     0x8C220000, 0, 0x00400008, 0),
        0x8013DD84: (0x02002021, 0x34050001, 0x0C04F5B3, 0x34060001, 0x0804F78A, 0x00408021,
                     0x02002021, 0x00002821, 0x0C04F5B3, 0x34060001, 0x0804F78A, 0x00408021,
                     0x02002021, 0x34050001, 0x0C04F5B3, 0x00003021, 0x0804F78A, 0x00408021,
                     0x02002021, 0x00002821, 0x0C04F5B3, 0x00003021, 0x0804F78A, 0x00408021),
        0x8013DE28: (0x16000076, 0x00001021, 0x0804F806, 0),
        0x8013E004: (0x92030000, 0x34020006, 0x1462FEFB, 0x34020019, 0x34020001),
    }
    for start, expected in spans.items():
        assert tuple(M.mword(start + 4 * i) for i in range(len(expected))) == expected, hex(start)


def check():
    check_consumers()
    bank = sx16(M.mword(0x8013CC48))
    assert bank == sx16(M.mword(0x8013CC38)) == sx16(M.mword(0x8013D6EC)) == 0x280
    assert sx16(M.mword(0x8013D70C)) == 0x190
    # Invert the address calculation for each possible operand. Compare to
    # the producer, which searches named fields across all roster records.
    actual = {}
    for ident in range(256):
        stream = bytes((0x16, ident, 0xFF, 0xFD))
        graph = R.walk(stream, [0])
        assert not graph['frontier']
        writer, stop = graph['nodes']
        assert (writer['offset'], writer['end'], writer['next']) == (0, 3, [3])
        assert (stop['offset'], stop['opcode'], stop['next']) == (3, 0xFD, [])
        delta = bank + ident - 0x294
        if 0 <= delta < 78 * 80:
            row, offset = divmod(delta, 80)
            if offset in (0x17, 0x1E, 0x4E, 0x4F):
                actual[ident] = (row, offset)
    assert actual == ALIASES
    assert {r['id']: (r['row'], r['offset']) for r in A.aliases()} == actual

    census = A.source_census()
    expected = [('VA1.BIN', p, 5, bits) for p, bits in
                [(0x3DD7B, 1), (0x3DD87, 1), (0x3DD93, 1), (0x3DD9F, 1), (0x3E2BE, 2)]]
    expected += [('VC6.BIN', 0x3DD44, 0, 1), ('VC6.BIN', 0x3DD48, 0, 2)]
    rows = census['opcode16_sites']
    assert [(Path(r['file']).name, r['offset'], r['id'], r['bits']) for r in rows] == expected
    for row in rows:
        start = row['offset']
        assert D.read(row['file'])[start:start + 3] == bytes((0x16, row['id'], row['bits']))
    assert census['sources'] == 89
    assert census['graph_frontiers'] and census['source_frontiers']
    print('PASS: static opcode 0x16 writer and both predicate banks, 256 IDs, 10 record aliases')
    print(f"PASS: 89-source graph, seven opcode 0x16 sites with IDs 0/5, "
          f"{len(census['graph_frontiers'])} open graph frontiers")


if __name__ == '__main__':
    check()
