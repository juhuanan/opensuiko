#!/usr/bin/env python3
"""Static pitch instruction algebra and independent table extraction checks."""
import hashlib
import math
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
from disc import extract


def check():
    main = extract(17976, 757760)[2048:]
    def word(va):
        return struct.unpack_from('<I', main, va - 0x800C0800)[0]
    anchors = {
        0x80158A1C: 0xA424C15C, 0x80158A84: 0x00042403,
        0x80158A98: 0x0C055323, 0x80158AB8: 0x3C018018,
        0x80158A10: 0x94440016, 0x80158A90: 0x10800009,
        0x80158A40: 0x90430004, 0x80158A4C: 0xA023C154,
        0x80158A50: 0x90430005, 0x80158A5C: 0xA023C155,
        0x8015D748: 0xA2020004, 0x8015D764: 0xA2020005,
        0x80155C88: 0x3C052AAA, 0x80155C8C: 0x34A5AAAB,
        0x80155C94: 0x9042C146, 0x80155C9C: 0x9063C154,
        0x80155CA0: 0x2442003C, 0x80155CA4: 0x00431023,
        0x80155CB0: 0x00850018, 0x80155CB8: 0x9063C155,
        0x80155CC0: 0x000330C2, 0x80155CEC: 0x3406000F,
        0x80155CF0: 0x00021303, 0x80155D08: 0x94230000,
        0x80155D0C: 0x24A2FFFB, 0x80155D24: 0x00431804,
        0x80155D38: 0x00431807, 0x80155D40: 0x3062FFFF,
        0x80155D6C: 0x90620005, 0x80155D74: 0x00A21021,
        0x80155D84: 0x000228C3, 0x80155D98: 0x34060001,
        0x80155D9C: 0x24A7FFF0, 0x80155DA8: 0x90630004,
        0x80155DB4: 0x00C21021, 0x80155E14: 0x94230000,
        0x80155E38: 0x00431807, 0x80155E40: 0x3062FFFF,
        0x80157B70: 0x0C055722, 0x80158BB8: 0x0C055751,
        0x80158BC4: 0x0C0553C2, 0x80158BC8: 0x3045FFFF,
        0x80157210: 0x0C055751, 0x80157228: 0xA4220000,
    }
    for va, expected in anchors.items():
        assert word(va) == expected, hex(va)
    offset = 0x80178424 - 0x800C0800
    raw = main[offset:offset + 384]
    assert hashlib.sha256(raw).hexdigest() == 'ec8b6f74419c647d94e99240f0ec6aa6f66ee45689b548eb26d1f779de2674b9'
    table = struct.unpack('<192H', raw)
    assert table == tuple(math.floor(4096 * 2 ** (i / 192)) for i in range(192))
    # Signed multiply-high sequence independently agrees with truncating /12.
    for n in range(-32768, 32768):
        hi = (n * 0x2AAAAAAB) >> 32
        quotient = (hi >> 1) - (n >> 31)
        assert quotient == (abs(n) // 12) * (-1 if n < 0 else 1)
    # Ordinary and fine-adjustment paths: compare instruction-stage arithmetic
    # with the direct octave/table-index formula, for in-table note differences.
    cases = 0
    for difference in range(128):
        for shift in range(256):
            for adjusted in (False, True):
                fraction = shift >> 3
                n = difference + 60
                if adjusted:
                    n += int(fraction >= 16)
                    fraction -= 16 * int(fraction >= 16)
                else:
                    fraction = min(fraction, 15)
                q = (((n * 0x2AAAAAAB) >> 32) >> 1) - (n >> 31)
                index = ((n - q * 12) << 4) + fraction
                value = table[index]
                result = ((value << (q - 5)) if q > 5 else (value >> (5 - q))) & 65535
                semitones = difference + (shift // 128 if adjusted else 0)
                expected_index = (semitones % 12) * 16 + (shift // 8 % 16 if adjusted else min(shift // 8, 15))
                expected = (table[expected_index] << (semitones // 12)) & 65535
                assert result == expected
                cases += 1
    assert table[0] == 4096 and table[15] > table[0]
    print(f'PASS: {len(anchors)} raw pitch anchors, 192 independently derived table entries, '
          f'65,536 signed division cases and {cases} pitch cases')


if __name__ == '__main__':
    check()
