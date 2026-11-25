#!/usr/bin/env python3
"""Find two complete character-lookup idioms in all344 overlays.

The result is an exact-body census of this idiom, not a claim that every record
pointer producer or caller has this shape. No code-region heuristic is used.
"""
import json
import struct

import data_overlays as D

LOOKUP = (0x308400FF, 0x34030294, 0x00C02821, 0x8CA20294,
          0, 0x10440006, 0x00661021, 0x24630050, 0x28621AF4,
          0x1440FFF9, 0x24A50050, 0x00001021, 0x03E00008, 0)
UNMASKED = (0x34030294, 0x00C02821, 0x8CA20294,
            0, 0x10820006, 0x00661021, 0x24630050, 0x28621AF4,
            0x1440FFF9, 0x24A50050, 0x00001021, 0x03E00008, 0)


def census():
    rows = []
    for source in D.population():
        data = D.read(source['path'])
        if len(data) < 4:
            continue
        entry = struct.unpack_from('<I', data)[0]
        base = 0x80080000 if 0x80080000 <= entry < 0x800C0000 else 0x80010000
        for masked, words in ((True, LOOKUP), (False, UNMASKED)):
            pattern = struct.pack('<%dI' % len(words), *words)
            start = data.find(pattern)
            while start >= 0:
                off = start - 8
                if off >= 0 and off % 4 == 0:
                    high, load = struct.unpack_from('<II', data, off)
                    if high & 0xFFFF0000 == 0x3C060000 and load & 0xFFFF0000 == 0x8CC60000:
                        low = load & 65535
                        gs_cell = ((high & 65535) << 16) + (low - 65536 if low & 32768 else low)
                        address = base + off
                        callers = []
                        for i in range(0, len(data) - 3, 4):
                            w = struct.unpack_from('<I', data, i)[0]
                            if w >> 26 in (2, 3) and (0x80000000 | ((w & 0x3FFFFFF) << 2)) == address:
                                callers.append(base + i)
                        rows.append(dict(path=source['path'], lba=source['lba'], size=source['size'],
                                         offset=off, address=address, base=base, masked=masked,
                                         gs_cell=gs_cell, callers=callers))
                start = data.find(pattern, start + 1)
    return rows


if __name__ == '__main__':
    print(json.dumps(census(), indent=2))
