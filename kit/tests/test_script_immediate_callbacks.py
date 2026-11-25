#!/usr/bin/env python3
"""Static instruction contracts for immediate callbacks and their dispatch."""
import hashlib
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
from disc import extract
import event_script_reachability as R
import maindec as M
from mipsdec import sx16

BASE = 0x80010000
SOURCES = [
    ('VD1.BIN', 2, 0x314, 0x4AC9C, 'currency', 0x8007EE00),
    ('VE3.BIN', 2, 0x3A0, 0x5C5D0, 'currency', 0x800A108C),
    ('VD2.BIN', 1, 0x270, 0x45F15, 'party', 0x80071FE0),
    ('VD4.BIN', 1, 0x270, 0x41218, 'party', 0x8005DF2C),
    ('VD5.BIN', 1, 0x2A8, 0x4AB4F, 'party', 0x800788C8),
    ('VD3.BIN', 27, 0x2158, 0x44C48, 'palette', 0x800756DC),
    ('VE3.BIN', 27, 0x21E4, 0x5BD80, 'palette', 0x800A108C),
    ('VE6.BIN', 27, 0x2158, 0x42D29, 'palette', 0x80068850),
    ('VE3.BIN', 22, 0x1FFC, 0x5BDDE, 'flags', 0x800A108C),
    ('VE4.BIN', 26, 0x2190, 0x2BD04, 'recruit', 0x80052054),
]

# Complete instruction sequences with only the context scratch cell and absolute
# epilogue jumps normalized. This also covers stores and return delay slots.
BODIES = {
    # One cursor increment. Signed gold < ((operand * 25) << 2) gives result 2.
    'currency': '''
        8c830004 3c010000 ac240000 8c620000 00000000 90440000 24420001 ac620000
        3c03801c 8c63801c 308400ff 00041040 00441021 000210c0 00441021 00021080
        0062182a 14600007 00000000 3c020000 8c420000 00000000 8c430008 08000000
        34020001 3c020000 8c420000 00000000 8c430008 34020002 03e00008 a0620000
    ''',
    # Operand 5 takes the six-member check. The other arm stores count - operand modulo 256.
    'party': '''
        8c830004 3c010000 ac240000 8c620000 00000000 90440000 24420001 ac620000
        34020005 308300ff 14620014 34020006 3c03801c 90638003 00000000 14620008
        00000000 3c020000 8c420000 00000000 8c430008 34020001 08000000 a0620000
        3c020000 8c420000 00000000 8c430008 34020002 08000000 a0620000 3c020000
        8c420000 3c03801c 90638003 8c420008 00641823 24630100 a0430000 03e00008
        00000000
    ''',
    # Two cursor increments. Vtable slot 0x64 receives RECT, zero, and source + 480.
    'palette': '''
        27bdffe0 afbf0018 8c830004 3c010000 ac240000 8c620000 00000000 90460000
        24420001 ac620000 3c020000 8c420000 00000000 8c430004 00000000 8c620000
        00000000 90450000 24420001 ac620000 3c03801c 8c639bc4 27a40010 a7a00010
        34020100 a7a20014 34020001 a7a20016 24a501e0 a7a50012 8c620064 24c601e0
        0040f809 00002821 8fbf0018 00000000 03e00008 27bd0020
    ''',
    # Read GS[0x190 + index] & mask, then store 1 for nonzero or 2 for zero.
    'flags': '''
        8c850004 3c010000 ac240000 8ca20000 00000000 90430000 24420001 aca20000
        3c020000 8c420000 00000000 8c440004 00000000 8c820000 3c05801b 90460000
        34a58000 00651825 24420001 ac820000 90620190 00000000 00461024 10400007
        00000000 3c020000 8c420000 00000000 8c430008 08000000 34020001 3c020000
        8c420000 00000000 8c430008 34020002 03e00008 a0620000
    ''',
    # Read GS[0x1af4 + index] & 2, with the same result convention.
    'recruit': '''
        8c850004 3c010000 ac240000 8ca20000 00000000 90430000 3c04801b 34848000
        24420001 aca20000 00641825 90621af4 00000000 30420002 10400007 00000000
        3c020000 8c420000 00000000 8c430008 08000000 34020001 3c020000 8c420000
        00000000 8c430008 34020002 03e00008 a0620000
    ''',
}
SCRATCH_REFERENCES = {
    'currency': [0x04, 0x4C, 0x64],
    'party': [0x04, 0x44, 0x60, 0x7C],
    'palette': [0x0C, 0x28],
    'flags': [0x04, 0x20, 0x64, 0x7C],
    'recruit': [0x04, 0x40, 0x58],
}
RETURN_JUMPS = {
    'currency': [0x5C], 'party': [0x58, 0x74], 'palette': [],
    'flags': [0x74], 'recruit': [0x50],
}


def check_dispatch():
    # Constructor and dispatch are pinned through their return delay slots.
    for start, end, digest in [
            (0x80142C38, 0x80142D48, '83def50cb38cb5177db7002355b970e297b8a600163455a18c3d924349d0bb77'),
            (0x80144048, 0x80144104, 'ce4e87c4d0358c493533d6fcf1d54e4519138b6deae9c41361ee42cc311e2d95')]:
        assert hashlib.sha256(M.body()[start - M.MBASE:end - M.MBASE]).hexdigest() == digest
        for pc in range(start, end, 4):
            word = M.mword(pc)
            if word >> 26 not in (0x28, 0x2B):
                continue
            base_register = (word >> 21) & 31
            if base_register == 29:  # Stack spills.
                continue
            lui = M.mword(pc - 4)
            assert base_register == 1 and lui >> 16 == 0x3C01, hex(pc)
            address = ((lui & 0xFFFF) << 16) + sx16(word)
            assert not 0x8017DA90 <= address < 0x8017DAA0, hex(pc)
    for start, words in {
        # Construct context+4 (cursor cell) and context+8 (byte result cell).
        0x80142C78: (0x3C028018, 0x2442AF84, 0x3C018018, 0xAC22DA44,
                     0x3C028018, 0x2442BD6C, 0x3C018018, 0xAC22DA48),
        # Consume the unsigned selector, call the constructor, then index the
        # area import table by selector+10 and invoke it with the context.
        0x8014409C: (0x8C63AF84, 0, 0x24620001, 0x3C018018, 0xAC22AF84,
                     0x90700000, 0x0C050B0E, 0x2610000A),
        0x801440C8: (0x8C420010, 0x321000FF, 0x00108080, 0x02028021, 0x8E020000,
                     0x3C048018, 0x2484DA40, 0x3C018018, 0xAC22A240, 0x0040F809),
    }.items():
        assert tuple(M.mword(start + 4*i) for i in range(len(words))) == words, hex(start)


def check_vad_continuations(data):
    # Selector 18 allocates 0x48 bytes, loads the count once, then widens each
    # payload byte into a halfword and advances the cursor in the same loop.
    # Selector 19 caches the previous context before publishing the new one.
    assert hashlib.sha256(data[0x57A0:0x5934]).hexdigest() == (
        '0e33a63dba4ba4e645a4f9e1175989c404819841b8850f7248306319297369a8')
    for start, words in {
        0x57DC: (0x8C420048, 0, 0x0040F809, 0x34040048),
        0x57EC: (0x3C038009, 0x8C630F4C, 0x00408021, 0xAC620048, 0xA2000000),
        0x5834: (0x8C620004, 0, 0x8C420000, 0, 0x90420000, 0, 0xA0620002),
        0x5884: (0x8C430004, 0, 0x8C620000, 0, 0x24420001, 0xAC620000),
        0x58A8: (0x8C430004, 0, 0x8C620000, 0, 0x90440000, 0x00002821,
                 0x24420001, 0x308600FF, 0x10C00016, 0xAC620000),
        0x58D0: (0x3C048009, 0x8C840F4C, 0, 0x8C820004, 0, 0x8C430000, 0x30A200FF,
                 0x90630000, 0x00021040, 0x00501021, 0xA4430002, 0x8C830004, 0,
                 0x8C620000, 0x24A50001, 0x24420001, 0xAC620000, 0x30A200FF,
                 0x0046102B, 0x1440FFEC, 0, 0x8FBF0014, 0x8FB00010, 0x03E00008, 0x27BD0018),
        0x5934: (0x3C038009, 0x8C630F4C, 0x8C820004, 0x3C018009, 0xAC240F4C,
                 0x8C420000, 0x8C630048, 0x90420000, 0, 0xA0620001, 0x3C028009,
                 0x8C420F4C, 0, 0x8C430004, 0, 0x8C620000, 0, 0x24420001,
                 0x03E00008, 0xAC620000),
    }.items():
        assert struct.unpack_from(f'<{len(words)}I', data, start) == words, hex(start)

    root = struct.unpack_from('<I', data)[0] - BASE
    table = struct.unpack_from('<I', data, root + 0x10)[0] - BASE
    mutations = 0
    for selector, site, start, end, size in [
            (18, 0x4CD13, 0x57A0, 0x5934, 6), (19, 0x4CDED, 0x5934, 0x5984, 1)]:
        target = BASE + start
        assert struct.unpack_from('<I', data, table + 4 * (10 + selector))[0] == target
        assert data[site:site + 2] == bytes([0x3D, selector])
        assert R.callback_cursor(data, site) == {'target': target, 'operands': size, 'retry': False}
        altered = bytearray(data)
        for offset in range(start, end, 4):
            altered[offset] ^= 1
            assert R.callback_cursor(altered, site) is None, hex(offset)
            altered[offset] ^= 1
            mutations += 1

    for value in range(256):
        site = len(data)
        script = data + bytes([0x3D, 19, value, 0xFD])
        graph = R.walk(script, [site])
        assert graph['frontier'] == []
        assert [node['offset'] for node in graph['nodes']] == [site, site + 3]
        assert graph['nodes'][0]['next'] == [site + 3]
    assert mutations == 121


def check():
    check_dispatch()
    files = json.loads((KIT / 'extracted/iso_files.json').read_text())
    mutations = operands = 0
    for name, selector, start, site, kind, scratch in SOURCES:
        target = BASE + start
        row = next(r for r in files if r['path'].endswith('/' + name))
        data = extract(row['lba'], row['size'])
        word = lambda offset: struct.unpack_from('<I', data, offset)[0]
        root = word(0) - BASE
        table = word(root + 0x10) - BASE
        assert word(table + 4*(10 + selector)) == target
        assert data[site:site + 2] == bytes([0x3D, selector])
        count = 2 if kind in ('palette', 'flags') else 1
        contract = {'target': target, 'operands': count, 'retry': False}
        assert R.callback_cursor(data, site) == contract
        expected = [int(token, 16) for token in BODIES[kind].split()]
        size = 4 * len(expected)
        for offset in SCRATCH_REFERENCES[kind]:
            expected[offset // 4] |= (scratch + 0x8000) >> 16
            expected[offset // 4 + 1] |= scratch & 0xFFFF
        for offset in RETURN_JUMPS[kind]:
            expected[offset // 4] |= ((target + size - 8) >> 2) & 0x03FFFFFF
        actual = [word(start + off) for off in range(0, size, 4)]
        assert actual == expected, name
        assert BASE <= scratch < 0x8017AF84
        if kind in ('flags', 'recruit'):
            # Unsigned index is ORed with an aligned GS base before the byte read.
            load = actual[(0x50 if kind == 'flags' else 0x2C) // 4]
            assert (load & 0xFFFF) + 255 < 0x1D60

        altered = bytearray(data)
        for offset in range(start, start + size, 4):
            altered[offset] ^= 1
            assert R.callback_cursor(altered, site) is None
            altered[offset] ^= 1
            mutations += 1
        graph = R.walk(data, [site])
        assert next(n for n in graph['nodes'] if n['offset'] == site)['next'] == [site + 2 + count]
        for offset in range(site + 2, site + 2 + count):
            for value in range(256):
                altered[offset] = value
                assert R.callback_cursor(altered, site) == contract
                operands += 1
            altered[offset] = data[offset]
    assert (mutations, operands) == (368, 3584)
    vad = next(r for r in files if r['path'].endswith('/VAD.BIN'))
    check_vad_continuations(extract(vad['lba'], vad['size']))
    print(f'PASS: 12 static callback bodies, MAIN dispatch/constructor, '
          f'{mutations + 121} body mutations and {operands + 256} cursor operand cases')


if __name__ == '__main__':
    check()
