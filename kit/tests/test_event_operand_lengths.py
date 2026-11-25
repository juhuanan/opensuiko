#!/usr/bin/env python3
"""Handler-derived instruction boundaries and independent disc switch witnesses."""
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import disc
import event_script_decode as D
import build_script_corpus as C


def check():
    # Each trailing FE must remain a standalone instruction, never an operand.
    cases = {
        0x00: ['0001020304'], 0x04: ['0001', '00ff02'],
        0x06: ['00', '01010203', '02010203040506'],
        0x07: ['000001', '000101', '000201', '000301', '0004010203', '0005', '0006'],
        0x0B: ['00'], 0x0D: ['00', '0101', '020102'],
        0x0F: ['01', 'ff01'], 0x15: ['01', '030102'],
        0x17: ['00'], 0x1F: ['01', 'ff01'],
        0x20: ['ff', 'fd', 'fc01', 'fe01', '01', '1e'],
        0x22: ['00', '01', '0201', '03'], 0x2E: ['fc'],
        0x2F: ['81', '82fc', '03fcfb'],
        0x32: ['0005', '00010205', '00010505'],
        0x34: ['ff', '00', '0101020304', '020102030405060708'],
        0x35: ['00'], 0x3B: ['00', '020102'],
        0x40: ['00', 'ff', 'fd01', 'fe010203'],
        0x49: ['ff', 'fe', 'fd01', '01', '19', '4f', '50'],
        0x4B: ['000102', '010102', '020102', '0301', '0401'],
        0x4C: ['000002', '0001', '0101', '0201', '03010203', '04'],
    }
    for op, variants in cases.items():
        for hexargs in variants:
            args = bytes.fromhex(hexargs)
            data = bytes([op]) + args + b'\xfe'
            rows = D.decode_stream(data)
            assert [(p, o, a) for p, o, a, _ in rows] == [
                (0, op, args), (1 + len(args), 0xFE, b'')], (op, hexargs, rows)
            assert C._clean_ahead(data, 0, len(data), set(), n=2)
            for end in range(1, 1 + len(args)):
                assert not C._clean_ahead(data, 0, end, set(), n=1), (op, end)
    assert not C._clean_ahead(b'\x3d\x01\xfe', 0, 3, set(), n=1)
    assert 'CALLBACK' in D.decode_stream(b'\x3d\x01')[0][3]
    assert not C._clean_ahead(b'\x27\xfe\xfe', 0, 3, set())
    assert not C._clean_ahead(b'\x32\x00\x01\x05', 0, 4, set(), n=1)
    assert D.decode_stream(b'\x03\xfc')[0][3].endswith('[TRUNCATED]')
    assert [(p, op, args) for p, op, args, _ in D.decode_stream(bytes.fromhex('495049fe020c'))] == [
        (0, 0x49, b'\x50'), (2, 0x49, b'\xfe'), (4, 2, b''), (5, 12, b'')]

    # Read the disc independently of the semantic scanner's cached image.
    image = disc.extract(17976, 757760)[2048:]
    anchors = {
        0x8013B97C: 0x24820001, 0x8013B988: 0x90900000,
        0x8013B998: 0x304200FF, 0x8013B99C: 0x2C420002,
        0x8013B9A0: 0x1040006E, 0x8013BB64: 0x14620030,
        0x8013BB6C: 0x24820002, 0x8013BC44: 0xA4500474,
        0x8013BC8C: 0x0C0328BC,
        0x8013A200: 0x24620001, 0x8013A20C: 0x90710000,
        0x8013A210: 0x340200FF, 0x8013A214: 0x12220003,
        0x8013A218: 0x340200FD, 0x8013A21C: 0x16220005,
        0x8013A220: 0x340200FC, 0x8013A234: 0x12220003,
        0x8013A238: 0x340200FE, 0x8013A23C: 0x16220006,
        0x8013A244: 0x24620002, 0x8013A250: 0x90730001,
        0x8013A4B0: 0x2462FFFF,  # loop bound count-1
        0x8013A4CC: 0x00661823,  # count-i
        0x8013A4D0: 0x00832021,  # (table+i)+(count-i) = table+count
        0x8013A524: 0x24E2FFFF,  # count-1
        0x8013A528: 0x00431821,  # add to cursor already at table
        0x8013A520: 0xAFA00000,  # default displacement zero
        0x8013A550: 0x8C420000, 0x8013A570: 0x8C42FFFC,
        0x8013AD40: 0xAC22AF84,  # one stream byte per 0D entry
        0x8013ADF0: 0x1440FFCE,  # next 0D entry starts at AD2C
        0x8013CAF8: 0xAC22AF84, 0x8013CB1C: 0xAC22AF84,
        0x8013AA6C: 0xAC22AF84, 0x8013AAB8: 0xAC22AF84,
        0x80139348: 0xAC22AF84, 0x80139380: 0xAC23AF84,
    }
    for va, expected in anchors.items():
        assert struct.unpack_from('<I', image, va - 0x800C0800)[0] == expected, hex(va)
    files = json.loads((KIT / 'extracted/iso_files.json').read_text())
    witnesses = [
        ('VA1.BIN', 0x3C1F0, {0: 0x3C1F4, 1: 0x3C20C, 2: 0x3C225}),
        ('VAA.BIN', 0x502C2, {0: 0x502C6, 1: 0x502CC, 2: 0x502D3}),
        ('VB4.BIN', 0x1AC12, {1: 0x1AC15, 2: 0x1AC17}),
        ('VE6.BIN', 0x426BB, {1: 0x426C0, 2: 0x426D2, 3: 0x426EA, 4: 0x42707}),
    ]
    for name, pc, expected in witnesses:
        rec = next(r for r in files if r['path'].endswith('/' + name))
        data = disc.extract(rec['lba'], rec['size'])
        assert D.switch_2f_targets(data, pc) == expected, name
        # Independent literal equality walk: compare bytes after the default's
        # first byte, with the exact instruction-derived displacement arithmetic.
        table = pc + 2
        count = data[pc + 1] & 63
        base = table + count - 1
        displacements = [0]
        for i in range(count - 1):
            p, distance = table + count, 1
            while data[p] != data[table + i]:
                p += 1
                distance += 1
            displacements.append(distance)
        bias = 0 if data[pc + 1] & 128 else 1
        assert {i + bias: base + d for i, d in enumerate(displacements)} == expected
    assert D.switch_2f_targets(bytes.fromhex('2f 83 fc fc fe fc'), 0) == {0: 4, 1: 5, 2: 5}
    for data in (b'', b'\x2f', b'\x2f\x80', b'\x2f\x82\xfc'):
        try:
            D.switch_2f_targets(data, 0)
        except ValueError:
            pass
        else:
            raise AssertionError('truncated switch accepted')
    print(f'PASS: operand boundaries, resync/truncation guards, {len(anchors)} raw instruction anchors and 4 independent disc switches')


if __name__ == '__main__':
    check()
