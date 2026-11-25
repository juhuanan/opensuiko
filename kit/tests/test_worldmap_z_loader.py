#!/usr/bin/env python3
"""Static field exits, region writers and world-map loader selection."""
import hashlib
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import maindec as M
from area_entity_probe import room_records
from event_script_decode import decode_stream
from event_script_reachability import build
from export_first_room import source
from export_scene_population import decode_predicate
from mipsdec import sx16
from test_canonical_start import assert_main_words

BASE = 0x80010000


def check_consumers():
    image = M.body()
    for start, end, digest in [
        (0x8013BF94, 0x8013C238, '7c9ed7db1200fcf16d26eb6a171ad536f0e52c5cfa2916ba9deef0f4c97ce7d9'),
        (0x8013CBBC, 0x8013CC04, '29453528401894bd0ba9a2c2743485d68ed277966daa4a66768670c256552861'),
        (0x801325A4, 0x801326B0, 'b2511881bc201cf9ba53617e4fb5ab67e0f255192fdc92ffe9c66573eefdfb75'),
        (0x80132790, 0x801328B0, '8304697a39bf717975c290c565e543f559e144ac4533ba2ab5509d4c2e7adec9'),
        (0x80132938, 0x801329D0, 'a5c53ef1e910d08f0c8cc8fdb5a2376c292de1d95743b8616bf658cc11f3c25e'),
        (0x80132B6C, 0x80132CE0, '36fdce89add443579bee8ba28e9d50c9b0519b7e6d2506791bfe9d37830a77f0'),
        (0x80131E0C, 0x80132044, '27e997aeb780eb9243dd9a041fe75bc0ecc949b9977d366898f25a1007f60ba6'),
        (0x801279E8, 0x80127AF0, 'c5b72e84e80c4a7367b4f73947edf9fa2efba966348968acd5ff180470d2e09d'),
    ]:
        assert hashlib.sha256(image[start - M.MBASE:end - M.MBASE]).hexdigest() == digest, hex(start)

    assert_main_words({
        # Opcode 03 first consumes the tag, then selects its argument group.
        0x8013BFA0: (0x24820001, 0x3C018018, 0xAC22AF84, 0x90850000),
        0x8013BFB0: (0x340200FF, 0x30A300FF, 0x14620003, 0x340200FE, 0x0804F08C, 0x34020001),
        0x8013BFC8: (0x1462000D, 0x340200FD, 0x24820002, 0x3C018018, 0xAC22AF84, 0x90830001,
                     0x24820003, 0x3C018018, 0xAC22AF84, 0x3C018017, 0xA423F298),
        0x8013C000: (0x14620021, 0x340200FC, 0x3C038018, 0x8C63C164, 0x34020001, 0xA0620002),
        0x8013C05C: (0x308200FF, 0x3C018017, 0x242116D8, 0x00220821, 0x90220000),
        0x8013C088: (0x14620009, 0x340200FB, 0x24820002, 0x3C018018, 0xAC22AF84,
                     0x3C038018, 0x8C63C164, 0x90820001, 0x0804F073, 0xA0620000),
        0x8013C0B0: (0x1462001E, 0x24820002, 0x3C018018, 0xAC22AF84, 0x3C038018,
                     0x8C63C164, 0x90820001, 0, 0xA0620002),
        0x8013C0EC: (0x90640000, 0x24620002, 0x3C018018, 0xAC22AF84, 0x3C018017, 0xA424F298, 0x90650001),
        0x8013C120: (0xA425F29A, 0x0804F08C, 0x34020001, 0x340200FA, 0x10620014),
        0x8013C144: (0xA0450001,),
        0x8013C174: (0xA4A40004, 0x90630001, 0x0804F08B, 0x34020002),
        0x8013C1A0: (0xA0620002,),
        0x8013C1C8: (0xA0620000,),
        0x8013C1F0: (0xA0620001,),
        0x8013C204: (0x24620001, 0x3C018018, 0xAC22AF84, 0x90640000, 0x24620002, 0x3C018018,
                     0xAC22AF84, 0xA4A40004, 0x90630001, 0x34020003, 0xA4A30006),
        # Opcode 09 and predicate 08 use the same indexed bank.
        0x8013D70C: (0x90430190,),
        0x8013CC00: (0xA0820190,),
        # Install the ordinary field selector, then the event driver when it selects an entry.
        0x801325BC: (0x2C420011, 0x10400015),
        0x801325E0: (0x3C038013, 0x24632938, 0x3C018018, 0x2421DA94, 0x00220821, 0xAC230000,
                     0x3C038013, 0x24632790, 0x3C018018, 0x2421DA90, 0x00220821, 0xAC230000),
        0x8013297C: (0x0C04FC6F, 0x00002021, 0x304200FF, 0x1040000C, 0x00101080),
        0x80132990: (0x3C038013, 0x24632B6C, 0x3C018018, 0x2421DA90, 0x00220821, 0xAC230000,
                     0x34020001, 0x3C018017, 0xA0221C28),
        0x80132B98: (0x0C04FC44, 0, 0x304200FF, 0x10400002, 0, 0x00408021),
        # Return 1 sets context+35 to 1. The installed transition callback raises +34.
        0x801327C4: (0x34020001, 0x10620009, 0x28620002),
        0x801327F8: (0x0804CA02, 0x34020001),
        0x8013280C: (0xA0620035,),
        0x8013286C: (0x3C028013, 0x24422898, 0x3C018018, 0x2421DA90, 0x00230821, 0xAC220000),
        0x801328A0: (0x34020001, 0xA0620034, 0x03E00008, 0x2402FFFF),
        # Field cleanup writes mode 1 for the world return. The mode switch
        # reads GS+1BBC and installs 801279E8 for that value.
        0x80131FA0: (0x90820035, 0, 0x30420001, 0x1040001D),
        0x8013201C: (0x0804C80C, 0x34030001),
        0x80132030: (0xAC831BBC,),
        0x800C9A34: (0x8C431BBC,),
        0x800C9A9C: (0x3C028012, 0x244279E8),
        # Ready disc and cached music allow the uncached region byte to
        # select a descriptor. The call passes the destination in its delay slot.
        0x80127A78: (0x90440002,),
        0x80127AA0: (0x10460006, 0x00C02821),
        0x80127ABC: (0x8462001E, 0, 0x1082000A, 0x00041080, 0xA464001E, 0x3C018017,
                     0x2421F3B4, 0x00220821, 0x8C240000, 0x0C030BBE, 0x3C058008),
    })
    assert M.mword(0x80171718 + 9 * 4) == 0x8013CBBC


def check_inline_formats():
    formats = {
        0xFF: (0xFF,), 0xFE: (0xFE, 20, 30), 0xFD: (0xFD, 0, 2, 20, 30),
        0xFC: (0xFC, 7, 2, 20, 30), 0xFB: (0xFB, 11, 20, 30), 0xFA: (0xFA, 11, 7, 2, 20, 30),
    }
    for tag in range(256):
        args = formats.get(tag, (tag, 20, 30))
        decoded = decode_stream(bytes((3, *args, 0xFD)), max_insns=2)
        assert decoded[0][2] == bytes(args) and decoded[1][:2] == (1 + len(args), 0xFD)
        if len(args) > 1:
            assert 'TRUNCATED' in decode_stream(bytes((3, *args[:-1])), max_insns=1)[0][3]


def file_descriptor(record, origin):
    assert (M.mword(record), M.mword(record + 4)) == (origin['size'], origin['lba'])


def predicate_matches(terms, x, y, flags):
    for term in terms:
        if term['kind'] == 'story_mask_clear':
            assert term['flag'] == {'id': 'scenario_0033', 'mask': 64}
            if flags & term['flag']['mask']:
                return False
        else:
            assert term['kind'] == 'coordinate_range'
            coord = term['coordinate']
            value = x if coord['axis'] == 'x' else y
            if not coord['first'] <= value <= coord['last']:
                return False
    return True


def check_va6():
    data, origin = source('/VA6.BIN')
    assert (origin['lba'], origin['size']) == (51377, 107284)
    file_descriptor(M.mword(M.mword(0x8016F67C) + 5 * 4), origin)
    root = struct.unpack_from('<I', data)[0] - BASE
    table = struct.unpack_from('<I', data, root + 8)[0] - BASE
    entries, count = struct.unpack_from('<IB', data, table + 16)
    entries -= BASE
    assert (root, table, entries, count) == (4, 0xF9AC, 0xFEB4, 8)
    assert room_records(data)[1]['ent_off'] == entries

    offsets = (0xFD3C, 0xFD44, 0xFD4C, 0xFD5C, 0xFD60, 0xFD64)
    coords = ((0x0C, 6), (0x0B, 1), (0x0B, 45))
    raw_streams = {0xFD70: bytes.fromhex('03 fb 00 32 65 fd'),
                   0xFD80: bytes.fromhex('09 2b 04 03 fb 0b 32 65 fd')}
    for start, expected in raw_streams.items():
        assert data[start:start + len(expected)] == expected
    terms, streams = [], []
    for index, offset in enumerate(offsets):
        entry = entries + 24 * index
        predicate, stream = struct.unpack_from('<II', data, entry + 16)
        assert predicate - BASE == offset
        assert struct.unpack_from('<H', data, entry + 4)[0] == 0
        op, coord = coords[index % 3]
        prefix = bytes((8, 0x21, 0x40)) if index < 3 else b''
        encoded = prefix + bytes((op, coord, coord, 6))
        assert data[offset:offset + len(encoded)] == encoded
        decoded, proof = decode_predicate(data, offset, 'event', coordinate_ranges=True)
        assert proof['size'] == len(encoded)
        terms.append(decoded['terms'])
        streams.append(stream - BASE)
    assert streams == [0xFD70] * 3 + [0xFD80] * 3

    for flags in range(256):
        for x, y, index in [(10, 6, 0), (1, 20, 1), (45, 20, 2), (45, 6, 0)]:
            selected = next(i for i, predicate in enumerate(terms) if predicate_matches(predicate, x, y, flags))
            expect_z = bool(flags & 0x40)
            assert selected == index + 3 * expect_z
            stream = raw_streams[streams[selected]]
            assert tuple(stream[-4:-1]) == (11 if expect_z else 0, 50, 101)
            if expect_z:
                bank = sx16(M.mword(0x8013CC00))
                assert (bank + stream[1], stream[2]) == (0x1BB, 4)


def check_vb6_and_vaad():
    data, origin = source('/VB6.BIN')
    assert (origin['lba'], origin['size']) == (62561, 458655)
    root = struct.unpack_from('<I', data)[0] - BASE
    table = struct.unpack_from('<I', data, root + 8)[0] - BASE
    entries = struct.unpack_from('<I', data, table + 6 * 16)[0] - BASE
    room = room_records(data)[6]
    assert room['ent_off'] == entries
    entry = entries + 24
    assert entry == 0x35744
    assert struct.unpack_from('<H', data, entry + 4)[0] == 0
    assert struct.unpack_from('<II', data, entry + 16) == (BASE + 0x3508C, BASE + 0x350FC)
    assert data[0x3508C:0x35090] == bytes.fromhex('0b 2d 2d 06')
    assert data[0x350FC:0x35102] == bytes.fromhex('03 fb 02 3b 26 fd')
    vc6, origin = source('/VC6.BIN')
    assert len(vc6) == origin['size']
    file_descriptor(M.mword(M.mword(0x8016F67C + 8) + 5 * 4), origin)

    story, origin = source('/VAAD.BIN')
    file_descriptor(M.mword(M.mword(0x8016F67C) + 11 * 4), origin)
    report = build(['VAAD.BIN'])['overlays'][0]
    nodes = {n['offset']: n for n in report['nodes']}
    for index, stream, tail in [(5, 0x85C8, 0x8607), (6, 0x8614, 0x8639)]:
        row = next(e for e in report['entries'] if e['room'] == 1 and e['entry'] == index)
        assert row['offset'] == stream and row['flags'] == 0
        predicate = 0x8468 if index == 5 else 0x8474
        assert struct.unpack_from('<II', story, row['record'] + 16) == (BASE + predicate, BASE + stream)
        chain = set()
        pc = stream
        while pc != tail:
            assert pc not in chain and len(nodes[pc]['next']) == 1
            chain.add(pc)
            pc = nodes[pc]['next'][0]
        assert story[tail:tail + 10] == bytes.fromhex('09 21 40 03 fa 0b 00 00 65 82')
        assert sx16(M.mword(0x8013CC00)) + story[tail + 1] == 0x1B1
    assert story[0x8474:0x847B] == bytes.fromhex('07 21 20 08 21 40 06')


def check():
    check_consumers()
    check_inline_formats()
    for index, name, lba, size in [
        (0, 'A_DATA.BIN', 27369, 166534), (2, 'C_DATA.BIN', 96338, 170146), (11, 'Z_DATA.BIN', 180665, 165974),
    ]:
        _, origin = source('/' + name)
        assert (origin['lba'], origin['size']) == (lba, size), name
        record = M.mword(0x8016F3B4 + index * 4)
        file_descriptor(record, origin)
        if index == 11:
            assert record == 0x801647C4
    check_va6()
    check_vb6_and_vaad()
    print('PASS: 256 inline formats, 1,024 VA6 selection cases, VB6 and VAAD producers, A/C/Z loader descriptors')


if __name__ == '__main__':
    check()
