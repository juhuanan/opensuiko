#!/usr/bin/env python3
"""The copied04 byte reaches the object interpreter and its pacing consumer."""
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

    targets = [word(0x800C1C60 + i * 4) for i in range(5)]
    assert targets == [0x80146C2C, 0x80146C3C, 0x80146C50,
                       0x80146C90, 0x80146CD4]
    anchors = {
        0x8013B7E0: 0xA0620000, 0x8013B7CC: 0x2CC20010,
        0x8013B818: 0x0C04FE6C, 0x8013FA10: 0xAC24A188,
        0x8013F8CC: 0x0C05177A, 0x8013F8D8: 0x0C051A4D,
        0x80146938: 0xAC850054, 0x80146944: 0xA4820020,
        0x80145C74: 0x0C051A57,
        0x801469D8: 0x8E050054, 0x801469DC: 0x0C051AED,
        0x801469E0: 0x34060001, 0x801469E4: 0x92030004,
        0x801469E8: 0xAE020054, 0x801469EC: 0xA2030003,
        0x801469BC: 0x92020003, 0x801469C4: 0x2442FFFF,
        0x801469C8: 0xA2020003, 0x801469D0: 0x14430007,
        0x80146BFC: 0x34020004, 0x80146C00: 0x2683FFFC,
        0x80146C04: 0x0043102B, 0x80146C14: 0x24211C60,
        0x80146C2C: 0x26520001, 0x80146C30: 0x92420000,
        0x80146C38: 0xA2620004, 0x80146CE4: 0x26520001,
        0x80145DEC: 0xA0850004,
    }
    for pc, expected in anchors.items():
        assert word(pc) == expected, hex(pc)
    # The handler has exactly one store, to the same byte loaded when the
    # frame consumer resets its countdown. It consumes the following byte.
    stores = [word(pc) for pc in range(targets[0], targets[1], 4)
              if word(pc) >> 26 in (40, 41, 43)]
    assert stores == [0xA2620004]
    assert (word(0x801469E4) & 65535) == (stores[0] & 65535) == 4
    print(f'PASS: five control dispatch targets, {len(anchors)} copy/staging/'
          'frame/interpreter anchors;04 consumes one byte and sets pacing interval')


if __name__ == '__main__':
    check()
