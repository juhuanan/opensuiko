#!/usr/bin/env python3
"""Text-box object: allocation, animation fields, GPU constructors and OT writes."""
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from disc import extract


def check():
    exe = extract(17976, 757760)
    base, size = struct.unpack_from('<II', exe, 0x18)
    data = exe[2048:2048 + size]

    def word(pc):
        return struct.unpack_from('<I', data, pc - base)[0]

    anchors = {
        0x801451CC: 0x34040058, 0x801452A4: 0x0C051787,
        0x801452B0: 0x0C0513A3, 0x801452B4: 0x34050009,
        0x800C4DD4: 0x0C030C41, 0x800C4DD8: 0x34040501,
        0x800C4DE4: 0x0C031359, 0x800C4D9C: 0x0C051557,
        0x80145584: 0xA485002C, 0x80145588: 0xA486002E,
        0x8014558C: 0xA4870030, 0x80145590: 0xA4890032,
        0x801455A0: 0xA0880002, 0x801455A4: 0xA0880001,
        0x801455A8: 0x34420002, 0x80145A74: 0x0C051D5A,
        0x80147580: 0x8603002C, 0x80147594: 0x8605003C,
        0x80144F1C: 0x000420C0, 0x80144F20: 0xAEC20024,
        0x80144F44: 0x0C052BA7, 0x80144F98: 0xA602000E,
        0x80144FB0: 0xA6020016, 0x80145104: 0x26940028,
        0x80145108: 0x26F70004, 0x8014510C: 0x2AE20008,
        0x80145CB8: 0x0C05180C, 0x80145CD0: 0x0C05196C,
        0x80145CE8: 0x0C051316, 0x80144D88: 0xA5040008,
        0x80144DA0: 0xA503000A, 0x80144E3C: 0x25EF0028,
        0x801464FC: 0x0C052F7D, 0x801468B0: 0x0C052F7D,
        0x80145D54: 0xAC830000, 0x80145D8C: 0xAC830000,
        0x80145DA0: 0x24A50028,
        0x8014AE9C: 0x34020009, 0x8014AEA4: 0x3402002C,
        0x8014AF00: 0x34020004, 0x8014AF08: 0x34020064,
        0x8014BEC0: 0x3C046400, 0x8014BF4C: 0x3C040500,
        0x8014BF58: 0x24E70018, 0x8014BF64: 0xAC27BD18,
    }
    for pc, expected in anchors.items():
        assert word(pc) == expected, hex(pc)

    # Independently enumerate the emitter's output stores. Five GPU words
    # comprise E1 draw mode followed by the four-word SPRT payload.
    stores = [(pc, word(pc) & 65535) for pc in range(0x8014BDF4, 0x8014BF70, 4)
              if word(pc) >> 26 == 43 and (word(pc) >> 21) & 31 == 7]
    assert [offset for _, offset in stores] == [4, 12, 8, 16, 20, 0]
    assert (word(0x8014AF08) & 255) == (word(0x8014BEC0) & 65535) >> 8 == 0x64
    assert (word(0x8014BF4C) & 65535) >> 8 == 5
    assert word(0x8014BF58) & 65535 == (5 + 1) * 4
    print(f'PASS: {len(anchors)} producer/animation/consumer anchors, independent SPRT '
          'constructor agreement, six emitter stores and 24-byte OT packet')


if __name__ == '__main__':
    check()
