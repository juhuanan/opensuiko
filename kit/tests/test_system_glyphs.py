#!/usr/bin/env python3
"""Independent SLUS spans, upload instructions, MAIN sampling and 4bpp pixels."""
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from disc import extract
from system_glyphs import sources, replay
from psx_vram import texpage_encode, clut_encode, rgb555_to_rgb888


def check():
    exe = extract(18346, 593920)
    assert exe[:8] == b'PS-X EXE'
    base = struct.unpack_from('<I', exe, 0x18)[0]

    def word(pc):
        return struct.unpack_from('<I', exe, pc - base + 2048)[0]

    anchors = {
        0x8001146C: 0x0C004532, 0x800114DC: 0x340203C0,
        0x800114E4: 0xA7A00012, 0x800114E8: 0x34110020,
        0x800114F0: 0x34100080, 0x80011500: 0x0C009746,
        0x80011508: 0x341203E0, 0x8001150C: 0xA7B20010,
        0x80011510: 0xA7A00012, 0x80011514: 0xA7B10014,
        0x80011518: 0xA7B00016, 0x80011524: 0x0C009746,
        0x8001152C: 0xA7B20010, 0x80011530: 0xA7B00012,
        0x80011534: 0xA7B10014, 0x80011538: 0xA7B00016,
        0x80011544: 0x0C009746, 0x8001154C: 0x340203F0,
        0x80011554: 0x340201F8, 0x8001155C: 0x34020010,
        0x80011564: 0x34020008, 0x80011574: 0x0C009746,
        0x80019150: 0x3C028001, 0x80019154: 0x24421460,
    }
    for pc, expected in anchors.items():
        assert word(pc) == expected, hex(pc)
    expected = [
        (0x66FA8, (960, 0, 32, 128), 8192),
        (0x68FA8, (992, 0, 32, 128), 8192),
        (0x6AFA8, (992, 128, 32, 128), 8192),
        (0x76FA8, (1008, 504, 16, 8), 256),
    ]
    for source, (offset, rect, size) in zip(sources(), expected):
        assert source['file_offset'] == offset and source['rect'] == rect
        assert source['payload'] == exe[offset:offset + size]
    vram = replay()
    page, clut = texpage_encode(960, 0, 0), clut_encode(1008, 504)
    # Direct byte/nibble extraction does not use the producer's pointer parsing
    # or the VRAM model's word addressing.
    raw = exe[0x68FA8:0x6CFA8]
    palette = struct.unpack_from('<16H', exe, 0x76FA8)
    for y in range(256):
        for x in range(128):
            index = (raw[y * 64 + x // 2] >> ((x & 1) * 4)) & 15
            assert vram.sample_texel(page, x + 128, y) == index
            assert vram.sample_color(page, clut, x + 128, y) == rgb555_to_rgb888(palette[index])
    main = extract(17976, 757760)[2048:]
    for pc, expected in {
        0x80144F8C: 0x340403F0, 0x80144F94: 0x340501F8,
        0x80144FA4: 0x340603C0, 0x80146284: 0x340603C0,
        0x80146180: 0x340203F0, 0x80146188: 0x340201F8,
        0x80146790: 0x34440080,
    }.items():
        assert struct.unpack_from('<I', main, pc - 0x800C0800)[0] == expected, hex(pc)
    print('PASS: SLUS uploader/callback and MAIN draw anchors; four independent '
          'file spans; 32768 glyph texels and traced RGB555 palette samples')


if __name__ == '__main__':
    check()
