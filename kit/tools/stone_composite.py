#!/usr/bin/env python3
"""Disc-only STONE composite candidate with the sampler's three embedded palettes."""
import argparse
import hashlib
import json
from pathlib import Path

from q_stone import STONE, raw, rect_table, page_records
from shiro_pixel_tail import decode_page, record
from psx_vram import PsxVram, texpage_encode, clut_encode


def palette_row(index):
    assert 0 <= index < 14
    return 480 if index < 2 else 482 if index >= 12 else 481


def sources():
    overlay = raw(STONE)
    pages = []
    for i, rect in enumerate(rect_table(overlay)):
        path = f'DATA/03_SHIRO/DATA/STONE_{i:02X}.BIN'
        payload = decode_page(path)
        info = record(path)
        pages.append(dict(path=path, lba=info['lba'], file_size=info['size'],
                          rect=rect, payload=payload,
                          sha256=hashlib.sha256(payload).hexdigest()))
    palettes = []
    for i in range(3):
        offset = 0x21F24 + i * 512
        payload = overlay[offset:offset + 512]
        assert len(payload) == 512
        palettes.append(dict(offset=offset, rect=(0, 480 + i, 256, 1),
                             payload=payload, sha256=hashlib.sha256(payload).hexdigest()))
    return overlay, pages, palettes


def replay():
    overlay, pages, palettes = sources()
    vram = PsxVram()
    for source in pages + palettes:
        vram.upload_rect(*source['rect'], source['payload'])
    return overlay, vram, pages, palettes


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--render', type=Path, required=True)
    args = ap.parse_args()
    from PIL import Image
    overlay, vram, pages, palettes = replay()
    canvas = Image.new('RGB', (320, 1680))
    draws = page_records(overlay)
    for draw in draws:
        x0, y0, x1, y1 = draw['src']
        u0, v0, u1, v1 = draw['uv']
        page = texpage_encode(*draw['tpage'], 1)
        clut = clut_encode(0, palette_row(draw['index']))
        for y in range(y0, y1):
            v = v0 + (y - y0) * (v1 - v0) // (y1 - y0)
            for x in range(x0, x1):
                u = u0 + (x - x0) * (u1 - u0) // (x1 - x0)
                canvas.putpixel((x, y), vram.sample_color(page, clut, u, v))
        draw['clut'] = (0, palette_row(draw['index']))
    args.render.mkdir(parents=True, exist_ok=True)
    canvas.save(args.render / 'composite.png')
    # Top, one repeated middle band and bottom, side by side for review.
    contact = Image.new('RGB', (960, 240))
    for i, y in enumerate((0, 240, 1440)):
        contact.paste(canvas.crop((0, y, 320, y + 240)), (i * 320, 0))
    contact.save(args.render / 'contact.png')
    strip = lambda source: {k: v for k, v in source.items() if k != 'payload'}
    info = record(STONE)
    (args.render / 'provenance.json').write_text(json.dumps(dict(
        overlay=dict(path=STONE, lba=info['lba'], size=info['size']),
        decoder='lzss.py v2.0.0; full consumption; psx_vram.py 8bpp',
        image_gate='pending', raster='affine nearest sample; no blending or tablet text',
        pages=[strip(p) for p in pages], palettes=[strip(p) for p in palettes],
        draws=draws), indent=2) + '\n')
    print(args.render / 'contact.png')


if __name__ == '__main__':
    main()
