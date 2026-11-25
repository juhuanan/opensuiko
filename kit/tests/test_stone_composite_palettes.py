#!/usr/bin/env python3
"""STONE palette bytes, upload writers, quad selection and independent sampling."""
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from disc import extract
from lzss import decode_strict
from q_stone import page_records, sampled_vram, rect_table
from stone_composite import sources, replay, palette_row
from shiro_pixel_tail import record
from psx_vram import texpage_encode, clut_encode, rgb555_to_rgb888


def check():
    overlay = extract(81394, 141092)
    assert len(overlay) == 0x22724
    assert 0x21F24 + 4 * 512 == len(overlay)
    anchors = {
        0x800804D0: 0x340201E0, 0x800804D8: 0xA7B40014,
        0x800803DC: 0x34140100, 0x80080434: 0xA7B30016,
        0x80080430: 0x34130001,
        0x800804EC: 0x3C05800A, 0x800804F0: 0x24A51F24,
        0x800804F4: 0x0040F809, 0x80080504: 0x340201E1,
        0x80080518: 0x3C05800A, 0x8008051C: 0x24A52124,
        0x80080520: 0x0040F809, 0x80080530: 0x340201E2,
        0x80080544: 0x3C05800A, 0x80080548: 0x24A52324,
        0x8008054C: 0x0040F809, 0x80080588: 0x24A52524,
        0x80081414: 0x28620002, 0x80081440: 0x340501E0,
        0x80081448: 0xA602000E, 0x8008144C: 0x2862000E,
        0x80081454: 0x2862000C, 0x80081480: 0x340501E2,
        0x80081488: 0xA602000E, 0x800814AC: 0x340501E1,
        0x800814B0: 0xA602000E, 0x800815C8: 0x26520014,
    }
    for pc, expected in anchors.items():
        assert struct.unpack_from('<I', overlay, pc - 0x80080000)[0] == expected, hex(pc)
    _, pages, palettes = sources()
    _, vram, _, _ = replay()
    assert [palette_row(i) for i in range(14)] == [480] * 2 + [481] * 10 + [482] * 2
    for i, p in enumerate(palettes):
        assert p['payload'] == overlay[0x21F24 + i * 512:0x22124 + i * 512]
        assert p['rect'] == (0, 480 + i, 256, 1)
        assert len(set(struct.unpack('<256H', p['payload']))) == 256

    # Derive the palette selected for each uploaded page from sampled coverage.
    selected = [set() for _ in pages]
    for draw in page_records(overlay):
        x0, x1, y0, y1 = sampled_vram(draw)
        for i, (x, y, w, h) in enumerate(rect_table(overlay)):
            if x0 < x + w and x1 >= x and y0 < y + h and y1 >= y:
                selected[i].add(palette_row(draw['index']))
    assert selected == [{480}] * 6 + [{481}] * 6 + [{482}] * 6

    for i, page in enumerate(pages):
        info = record(f'DATA/03_SHIRO/DATA/STONE_{i:02X}.BIN')
        blob = extract(info['lba'], info['size'])
        assert struct.unpack_from('<I', blob)[0] == len(blob) - 4
        independent = decode_strict(blob[4:])
        assert independent == page['payload'] and len(independent) == 16384
        x, y, _, _ = page['rect']
        band = 256 if y >= 256 else 0
        tp = texpage_encode(x, band, 1)
        cy = next(iter(selected[i]))
        palette = struct.unpack_from('<256H', overlay, 0x21F24 + (cy - 480) * 512)
        for row in range(128):
            for col in range(128):
                index = independent[row * 128 + col]
                assert vram.sample_texel(tp, col, y - band + row) == index
                assert vram.sample_color(tp, clut_encode(0, cy), col, y - band + row) == rgb555_to_rgb888(palette[index])
    print(f'PASS: {len(anchors)} upload/sampler anchors, embedded palette bounds, '
          '14 quad selections, 18 independent decodes and294912 texel/colour checks')


if __name__ == '__main__':
    check()
