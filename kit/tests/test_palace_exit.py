#!/usr/bin/env python3
"""Static source checks for the two ordinary palace room exits."""
import hashlib
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import maindec as M
from area_entity_probe import room_records
from event_script_decode import decode_stream
from export_first_room import source
from export_scene_population import decode_predicate
from mipsdec import jtarget, sx16
from test_canonical_start import assert_main_words, boot_seed
from test_entity_predicates import check_dispatch, check_helpers

BASE = 0x80010000


def check_consumers():
    check_dispatch()
    check_helpers()
    image = M.body()
    spans = [
        (0x8013F1BC, 0x8013F2A4, '4db7aede2434499dc42779af0e3646a822c5b88a69da97f48bfdd93e5e8cb007'),
        (0x8013E17C, 0x8013E210, 'e573cc4f67de4e18af4380c3eedac315e1340817c56738de8e6b2b29eb21dbc7'),
        (0x8013E028, 0x8013E17C, 'de21a37e1a6a09ebe58814d58dac4e65135ed9414df9dbef4146e5f361387477'),
        (0x8013BF94, 0x8013C238, '7c9ed7db1200fcf16d26eb6a171ad536f0e52c5cfa2916ba9deef0f4c97ce7d9'),
        (0x80132044, 0x801320C8, 'a092bf7c44a80d1475ddc7633f62a4c12c03a8dfa88a03845bd5967831d800c2'),
        (0x8013ED6C, 0x8013F060, 'f0e7ab3d7a15faae4c250d254b420b4920732278df777315136605f98925861f'),
        (0x8013F0C0, 0x8013F110, 'a9382e450a3e44eacbfe7b78cf42f42a7dc07104913fe80eb5014dfd4767780c'),
        (0x8013F110, 0x8013F1BC, '71c3da06f74e7412d7be12b5917dd714746475abb245cfb204fcb170981b0dcc'),
    ]
    for start, end, digest in spans:
        assert hashlib.sha256(image[start - M.MBASE:end - M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        # Scan in source order. Rejected entries advance by 24, accepted
        # entries initialize the stream from the selected entry+14.
        0x8013F238: (0x0C04F6DB, 0x02602021, 0x304200FF, 0x10400005, 0x26100001, 0x0C04F85F),
        0x8013F268: (0x24420018, 0x3C018018, 0xAC22A120, 0x320200FF, 0x0052102B, 0x1440FFEE),
        0x8013E1F8: (0x8C420014, 0, 0x3C018018, 0xAC22AF84),
        # The ordinary three-argument branch stores room and the two
        # coordinate halfwords. In the tick, 03 falls into FD when unblocked.
        0x8013E0D0: (0x0C04EFE5, 0, 0x00408021),
        0x8013E114: (0x3C018017, 0xA0201C28, 0x3C018017, 0xA0221C29),
        0x8013C144: (0xA0450001,),
        0x8013C174: (0xA4A40004, 0x90630001, 0x0804F08B, 0x34020002),
        0x8013C22C: (0xA4A30006, 0x03E00008, 0),
        # Builder uses new room for the entry array and section table.
        0x80132078: (0x90420001, 0, 0x00021100, 0x00431021, 0x8C430000, 0x3C018018, 0xAC22BFC0,
                     0x3C018018, 0xAC23BF98, 0x90420005, 0x8C830004, 0x00021080, 0x00431021, 0x8C430000),
        0x801320C4: (0xAC23AAE4,),
        # Opcode 41 reads a halfword indexed by one unsigned byte.
        0x80139954: (0x90700000, 0x3C118018, 0x8E31DB24, 0x3C028017, 0x24421C2C, 0x00108040,
                     0x02028021, 0x86040000, 0x0C050910),
        0x80142460: (0x10830015, 0x02002821),
        0x80142484: (0x0C030C41, 0),
        # Opcode 24 sets fade-out and initializes brightness. Opcode 0A
        # sets the countdown flag and stores the one-byte operand times five.
        0x80139BFC: (0x34420010, 0x3C018018, 0xA422C028, 0xA06004DC),
        0x8013CCC8: (0x90630000, 0x34420020, 0x3C018018, 0xA422C028, 0x00031080, 0x00431021,
                     0x3C018018, 0xA422A138, 0x03E00008, 0),
        # The frame pump skips the tick while blocked and still runs the updater.
        0x8013F11C: (0x0C04FC30, 0x00008021, 0x14400004, 0, 0x0C04F80A),
        0x8013F148: (0x0C04FB5B,),
        0x8013F0F0: (0x9442C028, 0, 0x3042FFFC, 0x0002102B),
        0x8013EE18: (0x2462FFFF, 0x3C018018, 0xA422A138, 0x00021400, 0x14400007),
        0x8013EE3C: (0x38420020, 0x3C018018, 0xA422C028),
        0x8013EE6C: (0x90820039, 0x908304DC, 0x00021040, 0x00621821, 0xA08304DC),
        0x8013EE8C: (0x90A30039, 0x340200FF, 0x90A404DC, 0x00031840, 0x00431023, 0x0044102A, 0x1040006C),
        0x8013EEB8: (0x38420010, 0x3C018018, 0xA422C028, 0x340200FF, 0xA0A204DC),
    })
    assert {op: M.mword(0x80171718 + 4 * op) for op in (0x0A, 0x24, 0x41)} == {
        0x0A: 0x8013CCA8, 0x24: 0x80139BEC, 0x41: 0x80139930,
    }
    assert jtarget(0x8013F148, M.mword(0x8013F148)) == 0x8013ED6C


def check():
    check_consumers()
    data, origin = source('/VAA.BIN')
    assert (origin['lba'], origin['size']) == (51822, 447732)
    seed = boot_seed()
    assert seed[:8] == bytes((9, 2, 0, 1, 64, 0, 73, 0))
    table = M.mword(0x8016F67C + 4 * seed[2])
    descriptor = M.mword(table + 4 * seed[0])
    assert (M.mword(descriptor), M.mword(descriptor + 4)) == (origin['size'], origin['lba'])
    root = struct.unpack_from('<I', data)[0] - BASE
    room_table = struct.unpack_from('<I', data, root + 8)[0] - BASE
    text_root = struct.unpack_from('<I', data, root + 20)[0] - BASE
    assert (root, room_table, text_root) == (4, 0x4F870, 0x4F920)
    rooms = room_records(data)
    assert len(rooms) == (text_root - room_table) // 16 == 11
    sections = struct.unpack_from('<I', data, root + 4)[0] - BASE

    cases = 0
    routes = [
        (2, 0, 0x51010, 0x50CD4, 0x50D30, (56, 62, 26, 26), (1, 5, 16),
         [(0x41, b'\x75'), (3, b'\x01\x05\x10'), (0xFD, b'')], [0x508], 0x5076C, 0x80015674),
        (1, 1, 0x50784, 0x500C4, 0x50194, (32, 38, 104, 104), (0, 39, 13),
         [(0x24, b''), (0x41, b'\xae'), (0x0A, b'\x0a'), (0x41, b'\x10'), (3, b'\x00\x27\x0d'), (0xFD, b'')],
         [0x547, 0x80], 0x4FE0C, 0x8001419C),
    ]
    for room, index, entry, predicate, stream, bounds, destination, script, commands, target_entries, target_section in routes:
        pointer, count = struct.unpack_from('<IB', data, room_table + 16 * room)
        assert pointer - BASE + 24 * index == entry and count == rooms[room]['count']
        assert struct.unpack_from('<H', data, entry + 4)[0] == 0
        assert struct.unpack_from('<II', data, entry + 16) == (BASE + predicate, BASE + stream)
        x0, x1, y0, y1 = bounds
        assert data[predicate:predicate + 7] == bytes((11, x0, x1, 12, y0, y1, 6))
        decoded, _ = decode_predicate(data, predicate, 'event', coordinate_ranges=True)
        ranges = [term['coordinate'] for term in decoded['terms']]
        assert [coordinate['axis'] for coordinate in ranges] == ['x', 'y']
        for axis in ('x', 'y'):
            for position in range(256):
                point = {'x': position if axis == 'x' else (x0 + x1) // 2,
                         'y': position if axis == 'y' else y0}
                matches = all(c['first'] <= point[c['axis']] <= c['last'] for c in ranges)
                assert matches == (x0 <= point['x'] <= x1 and y0 <= point['y'] <= y1)
                cases += 1
        # Room 1's first entry returns to room 2. Its Y range excludes
        # every coordinate admitted by the second (outward) entry.
        if index == 1:
            earlier = struct.unpack_from('<I', data, pointer - BASE + 16)[0] - BASE
            assert data[earlier:earlier + 7] == bytes((11, 2, 8, 12, 10, 12, 6))
            assert data[earlier + 5] < y0
        cursor = stream
        for opcode, args in script:
            encoded = bytes((opcode,)) + args
            assert data[cursor:cursor + len(encoded)] == encoded
            cursor += len(encoded)
        decoded_script = decode_stream(data, stream, len(script))
        assert [(op, args) for _, op, args, _ in decoded_script] == script
        assert next(tuple(args) for op, args in script if op == 3) == destination
        assert [struct.unpack_from('<H', M.body(), 0x80171C2C - M.MBASE + 2 * args[0])[0]
                for op, args in script if op == 0x41] == commands
        target = destination[0]
        target_pointer, _, section = struct.unpack_from('<IBB', data, room_table + 16 * target)
        assert target_pointer == BASE + target_entries == BASE + rooms[target]['ent_off']
        assert section == rooms[target]['section']
        assert struct.unpack_from('<I', data, sections + 4 * section)[0] == target_section

    assert cases == 1024
    # With the retained fade step of one, +2 reaches the source's finish
    # threshold of 254. The 10*5 countdown also drains one unit per update.
    fade_delta = 1 << ((M.mword(0x8013EE74) >> 6) & 31)
    full = sx16(M.mword(0x8013EE90))
    assert (full - fade_delta) // fade_delta + 1 == 127
    assert 10 * ((1 << ((M.mword(0x8013CCD8) >> 6) & 31)) + 1) == 50
    print('PASS: two palace exit streams and destination sections, 1,024 coordinate cases, static wait paths')


if __name__ == '__main__':
    check()
