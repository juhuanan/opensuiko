#!/usr/bin/env python3
"""Replay SLUS's embedded UI/font uploads; candidate only, never staging."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from disc import extract
from psx_vram import PsxVram, texpage_encode, clut_encode

LBA, SIZE = 18346, 593920


def sources():
    exe = extract(LBA, SIZE)
    assert exe[:8] == b'PS-X EXE'
    base, size = struct.unpack_from('<II', exe, 0x18)
    image = exe[2048:2048 + size]
    assert base == 0x80010000 and len(image) == size

    def pointer(hi, lo):
        upper = struct.unpack_from('<I', image, hi - base)[0] & 65535
        lower = struct.unpack_from('<I', image, lo - base)[0] & 65535
        return (upper << 16) + (lower - 65536 if lower & 32768 else lower)

    result = []
    for hi, lo, rect, role in (
        (0x800114F8, 0x800114FC, (960, 0, 32, 128), 'ui'),
        (0x8001151C, 0x80011520, (992, 0, 32, 128), 'glyph_top'),
        (0x8001153C, 0x80011540, (992, 128, 32, 128), 'glyph_bottom'),
        (0x8001156C, 0x80011570, (1008, 504, 16, 8), 'palettes'),
    ):
        va = pointer(hi, lo)
        count = rect[2] * rect[3] * 2
        payload = image[va - base:va - base + count]
        assert len(payload) == count
        result.append(dict(role=role, va=va, file_offset=va - base + 2048,
                           rect=rect, size=count, payload=payload,
                           sha256=hashlib.sha256(payload).hexdigest()))
    return result


def replay():
    vram = PsxVram()
    for source in sources():
        vram.upload_rect(*source['rect'], source['payload'])
    return vram


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--render', type=Path, required=True)
    args = ap.parse_args()
    from PIL import Image, ImageDraw
    vram = replay()
    page = texpage_encode(960, 0, 0)
    palette = clut_encode(1008, 504)
    pixels = [vram.sample_color(page, palette, x, y)
              for y in range(256) for x in range(128, 256)]
    im = Image.new('RGB', (128, 256))
    im.putdata(pixels)
    sheet = Image.new('RGB', (416, 810), (30, 30, 30))
    ImageDraw.Draw(sheet).text((16, 10), 'SLUS embedded glyphs / traced palette row504', fill='white')
    sheet.paste(im.resize((384, 768), Image.Resampling.NEAREST), (16, 34))
    args.render.mkdir(parents=True, exist_ok=True)
    sheet.save(args.render / 'glyphs.png')
    metadata = [dict((k, v) for k, v in s.items() if k != 'payload') for s in sources()]
    (args.render / 'provenance.json').write_text(json.dumps(dict(
        file='SLUS_002.92', lba=LBA, size=SIZE,
        decoder='raw4bpp; psx_vram.py low-nibble-first',
        image_gate='pending', sources=metadata), indent=2) + '\n')
    print(args.render / 'glyphs.png')


if __name__ == '__main__':
    main()
