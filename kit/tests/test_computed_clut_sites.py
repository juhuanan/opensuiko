#!/usr/bin/env python3
"""Check CLUT argument builders and call delay slots from MAIN disc bytes."""
from pathlib import Path
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from disc import extract
from psx_vram import clut_encode


def check():
    exe = extract(17976, 757760)
    base, size = struct.unpack_from('<II', exe, 0x18)
    data = exe[2048:2048 + size]

    def word(pc):
        return struct.unpack_from('<I', data, pc - base)[0]

    anchors={
        0x800C431C:0x0080B021,0x800C4400:0x8EC30010,
        0x800C4408:0x00151080,0x800C4410:0x8C510000,
        0x800C444C:0x02209821,0x800C4498:0x92620000,
        0x800C44A0:0x92C50007,0x800C44B8:0xA622FFFE,
        0x800E7A18:0x0080A821,0x800E7A1C:0x0C030E8D,
        0x800E7A28:0xA2A20007,0x800E7B64:0x8EA30014,
        0x800E7B70:0x94470000,0x800E7B7C:0x00078102,
        0x800E7C18:0x30F2000F,0x800E7C3C:0x8EA30010,
        0x800E7C48:0x8E030000,0x800E7C58:0x90630000,
        0x80103AB4:0x8E620004,0x80103ABC:0x8C420018,
        0x80103AC4:0x8C420024,0x80103AD0:0x9054000E,
        0x801046B4:0x8E620004,0x801046BC:0x8C420018,
        0x801046C8:0x8C420024,0x801046D4:0x9054000E,
        0x80122BDC:0x8E620000,0x80122BE4:0x8C420024,
        0x80122BF0:0x905E000E,0x80122C14:0x8E621410,
        0x80122C1C:0x10400002,0x80122C24:0x0040F021,
        0x80123534:0x8E720018,0x8012355C:0x8E430024,
        0x80123578:0x34160008,0x80123584:0x02C34821,
        0x8012362C:0x91300006,
        0x801425FC:0x0C038AA7,0x80142600:0x00809021,
        0x80142604:0x8E450024,0x80142628:0x000440C0,
        0x80142630:0x25080008,0x80142634:0x01054021,
        0x801426E4:0x91100006,
        0x8014B388:0x27BDFFD8,0x8014B394:0x00A08021,
        0x8014B39C:0x00C08821,0x8014B3B8:0xA7B00010,
        0x8014B3BC:0xA7B10012,0x8014B3C0:0x0C052164,
        0x8014B3C8:0x02002021,0x8014B3CC:0x0C052AF5,
        0x8014B3D0:0x02202821,
    }
    for pc, expected in anchors.items():
        assert word(pc) == expected, hex(pc)

    # The byte builders compute quotient and parity, then OR 384 into the
    # quotient in the GetClut delay slot. The signed override corrects negative
    # quotients before shifting and adds 384 to the result.
    byte_s4 = (0x00142842, 0x00052040, 0x02842023, 0x00042100, 0x248403A0, 0x0C052AF5, 0x34A50180)
    byte_s0 = (0x00102842, 0x00051040, 0x02028023, 0x00108100, 0x260403A0, 0x0C052AF5, 0x34A50180)
    signed_s8 = (0x001E2FC2, 0x03C52821, 0x00052843, 0x00052040, 0x03C42023,
                 0x00042100, 0x248403A0, 0x0C052AF5, 0x24A50180)
    # The material builders set x to zero and load both offsets as bytes.
    # They add 480 to the base before the call and add the selector in its delay slot.
    field_material = (0x00002021, 0x92620000, 0x26940008, 0x92C50007, 0x26730001,
                      0x26100001, 0x24A501E0, 0x0C052AF5, 0x00452821)
    battle_material = (0x00002021, 0x92A50007, 0x00721821, 0x90630000, 0x0040F021,
                       0x24A501E0, 0x0C052AF5, 0x00652821)
    builders = {
        0x80103B00: byte_s4, 0x80104704: byte_s4,
        0x8012366C: byte_s0, 0x80142724: byte_s0, 0x80122D4C: signed_s8,
        0x800C4494: field_material, 0x800E7C4C: battle_material,
    }
    for start, words in builders.items():
        assert tuple(word(start + 4*i) for i in range(len(words))) == words, hex(start)

    for selector in range(256):
        row, column = divmod(selector, 2)
        assert clut_encode(928 + 16*column, 384 + row) == (384 << 6) + 58 + 64*row + column
    for index in (-2147483648, -257, -3, -1, 0, 1, 257, 2147483647):
        quotient = (index + (index < 0)) >> 1
        magnitude, column = divmod(abs(index), 2)
        if index < 0:
            magnitude, column = -magnitude, -column
        assert quotient == magnitude and index - 2*quotient == column
    print(f'PASS: {len(anchors)} source/wrapper words, {len(builders)} static CLUT builders, '
          '256 packed slots and signed quotient boundaries')


if __name__=='__main__':check()
