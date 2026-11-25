#!/usr/bin/env python3
"""MAIN text layout: controls, cursor bounds, pacing, widths and speaker images."""
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from disc import extract


def check():
    exe = extract(17976, 757760)
    base = struct.unpack_from('<I', exe, 0x18)[0]

    def word(pc):
        return struct.unpack_from('<I', exe, pc - base + 2048)[0]

    def block(pc, n):
        return exe[pc - base + 2048:pc - base + 2048 + n]

    table = struct.unpack('<16I', block(0x800C1C20, 64))
    assert table == (0x80146A90, 0x80146AE4, 0x80146A90,
                     *([0x80146B0C] * 11), 0x80146AD4, 0x80146AF8)
    assert list(block(0x80171F58, 4)) == [2, 4, 11, 0]
    assert list(block(0x80171884, 12)) == [0, 1, 1, 1, 1, 3, 5, 1, 2, 5, 9, 2]
    assert list(block(0x80171F5C, 26)) == [1, 2, 1, 2, 2, 2, 1, 2, 5, 3, 2, 4,
                                         0, 2, 2, 2, 2, 2, 2, 3, 1, 1, 0, 1, 1, 1]
    anchors = {
        0x80146A9C: 0xA0C2000B, 0x80146AB0: 0xA0C0000A,
        0x80146AC0: 0x244200FF, 0x80146AC4: 0x0C051632,
        0x80146AEC: 0x34630040,
        0x80146B74: 0xA0C2000A, 0x80146B9C: 0xA0C3000A,
        0x80146DFC: 0x27BDFFD0, 0x80146E38: 0x34060010,
        0x80146E68: 0xA4460000, 0x80146EB8: 0xA200000A,
        0x80146EBC: 0xA200000B, 0x80146974: 0x30420840,
        0x80146988: 0x30620200, 0x80146990: 0x30620020,
        0x801469E4: 0x92030004, 0x801469EC: 0xA2030003,
        0x80146C4C: 0xA2630003, 0x80146C48: 0x08051B5A,
        0x80146740: 0x2C62001A, 0x80146750: 0x24211F5C,
        0x80146764: 0x01021023, 0x8014676C: 0xA7A20018,
        0x801468C4: 0x02821021, 0x801468C8: 0x0040A021,
        0x80146208: 0x02770018,
        0x8013AF70: 0x0C04FED6, 0x8013FB7C: 0x10A20007,
        0x8013FB84: 0x2CA2007D, 0x8013FB94: 0x0C04FE90,
        0x8013FBA4: 0x0C04FD61, 0x8013FA9C: 0x24210588,
        0x8013FB00: 0x34020003, 0x8013FB3C: 0x0C051A4D,
        0x8013F718: 0x30420065, 0x8013F72C: 0x0C051BE7,
        0x8013F780: 0x2C42001F, 0x80146FC0: 0x0C051B7F,
    }
    for pc, expected in anchors.items():
        assert word(pc) == expected, hex(pc)
    calls = []
    for pc in range(0x801465B0, 0x80146934, 4):
        w = word(pc)
        assert not (w >> 26 == 0 and w & 63 == 9)
        if w >> 26 == 3:
            calls.append((pc & 0xF0000000) | ((w & 0x3FFFFFF) << 2))
    assert calls == [0x80145F44, 0x8014AB0C, 0x8014BDF4]
    # The name lookup starts at rank1; its effective table base's word0 is
    # not a pointer. Check a real rank instead of assuming a dense table.
    assert word(0x8017058C) == 0x8017010C
    assert block(0x8017010C, 7) == bytes.fromhex('31 22 15 1d 19 1f 00')
    print(f'PASS: 16 control targets,26 glyph trims, four pacing values, '
          f'{len(anchors)} layout/speaker/frame anchors and complete proportional-builder call set')


if __name__ == '__main__':
    check()
