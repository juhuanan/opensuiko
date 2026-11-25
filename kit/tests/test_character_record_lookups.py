#!/usr/bin/env python3
"""Static instruction and source-ID checks for character-record lookup copies."""
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import character_record_lookups as L
import character_table as CT
import data_overlays as D
import maindec as M
from mipsdec import jtarget, sx16


def main_lookup_layout():
    words = tuple(M.mword(pc) for pc in range(0x8013875C, 0x8013879C, 4))
    assert words == (
        0x3C028018, 0x8C42DB24, 0x00002821, 0x308400FF,
        0x24430294, 0x8C620000, 0, 0x10440006, 0x00601021, 0x24A50001,
        0x28A2004E, 0x1440FFF9, 0x24630050, 0x00001021, 0x03E00008, 0,
    )
    first, stride = sx16(words[4]), sx16(words[12])
    return first, first + sx16(words[10]) * stride, stride, words[3] & 0xFFFF


def overlay_layout(data, offset, masked, gs_cell):
    high, low = struct.unpack_from('<II', data, offset)
    assert high >> 16 == 0x3C06 and low >> 16 == 0x8CC6
    assert ((high & 0xFFFF) << 16) + sx16(low) == gs_cell
    body_start = offset + 8
    if masked:
        assert struct.unpack_from('<I', data, body_start)[0] == 0x308400FF
        body_start += 4
    words = struct.unpack_from('<13I', data, body_start)
    # Read one ID word at a time. The equality branch keeps the record
    # pointer in its delay slot. The back edge advances by one record.
    equality = 0x10440006 if masked else 0x10820006
    assert words == (
        0x34030294, 0x00C02821, 0x8CA20294, 0, equality, 0x00661021, 0x24630050,
        0x28621AF4, 0x1440FFF9, 0x24A50050, 0x00001021, 0x03E00008, 0,
    )
    assert sx16(words[0]) == sx16(words[2])
    assert sx16(words[6]) == sx16(words[9])
    return sx16(words[0]), sx16(words[7]), sx16(words[6]), 0xFF if masked else 0xFFFFFFFF


def check():
    rows = L.census()
    known = {'VB4': 0x3514, 'VB5A2': 0x40D4, 'VB5B3': 0xB6C,
             'VB5B4': 0xB4C, 'VB5C3': 0x1A4, 'VB5C4': 0x394C,
             'VD6': 0x3554, 'VE4': 0x4008, 'VS1': 0x2FB8,
             'VS2': 0x3514, 'VAC': 0x694, 'AZUKARI': 0x4FAC}
    assert {Path(r['path']).stem: r['offset'] for r in rows} == known
    assert [Path(r['path']).stem for r in rows if not r['masked']] == ['AZUKARI']
    layouts = [main_lookup_layout()]
    caller_count = 0
    for row in rows:
        data = D.read(row['path'])
        layouts.append(overlay_layout(data, row['offset'], row['masked'], row['gs_cell']))
        assert row['address'] == row['base'] + row['offset']
        callers = []
        for i, (word,) in enumerate(struct.iter_unpack('<I', data[:len(data) - len(data) % 4])):
            pc = row['base'] + 4 * i
            if word >> 26 in (2, 3) and jtarget(pc, word) == row['address']:
                callers.append(pc)
        assert callers == row['callers']
        assert len(callers) == (2 if row['masked'] else 3)
        caller_count += len(callers)
    assert caller_count == 25

    image = CT.image()
    records = image[0x33274:0x33274 + 78 * 80]
    ids = [struct.unpack_from('<I', records, 80 * i)[0] for i in range(78)]
    assert len(set(ids)) == 78
    by_id = {ident: 0x294 + 80 * i for i, ident in enumerate(ids)}
    cases = 0
    for first, end, stride, mask in layouts:
        assert (first, end, stride) == (0x294, 0x1AF4, 0x50)
        for prefix in (0, 0x12340000):
            for ident in range(256):
                code = (prefix | ident) & mask
                actual = next((address for address in range(first, end, stride)
                               if struct.unpack_from('<I', records, address - first)[0] == code), 0)
                assert actual == by_id.get(code, 0), (code, actual)
                cases += 1
    assert cases == 6656
    print('PASS: 6,656 static lookup cases, 12 overlay copies plus MAIN, 25 direct caller sites')


if __name__ == '__main__':
    check()
