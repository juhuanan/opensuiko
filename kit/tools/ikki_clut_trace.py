#!/usr/bin/env python3
"""Disc-derived IC CLUT chain; normal-colour renders accepted by the user 2026-10-07."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import ikki_palettes as source
import maindec
from psx_vram import PsxVram, clut_encode, texpage_encode, TP_8BIT, rgb555_to_rgb888

# Pointer runs used by fighter construction, not the embedded HUD upload loop.
PAIRS = {'PAN_TEO.BIN': (9, 0x9B58),
         'SHU_KWA.BIN': (11, 0x9B3C),
         'SHU_TEO.BIN': (13, 0x9B3C)}


def trace():
    records = []
    files = {(r['size'], r['lba']): r['path'] for r in source._iso() if not r.get('dir')}
    for name, (group, pair_offset) in PAIRS.items():
        data = source.overlay(name)
        word = lambda off: struct.unpack_from('<I', data, off)[0]
        directory = maindec.mword(0x8016B358 + group * 4)
        families = []
        cursor = directory
        while maindec.mword(cursor):
            entry = maindec.mword(cursor)
            path = files[(maindec.mword(entry), maindec.mword(entry + 4))]
            if Path(path).name.startswith('IC_'):
                family = Path(path).name.split('_')[1]
                if family not in families:
                    families.append(family)
            cursor += 4
        assert len(families) == 2
        for slot, family in enumerate(families):
            context = word(pair_offset + slot * 4) - source.OVERLAY_BASE
            assert data[context + 4:context + 6] == bytes((7, 0x81))
            table = word(context + 12) - source.OVERLAY_BASE
            palette = word(table) - source.OVERLAY_BASE
            raw = data[palette:palette + 64]
            assert len(raw) == 64
            records.append({'family': family, 'overlay': source.OVERLAY_DIR + name,
                            'overlay_lba': source._rec(source.OVERLAY_DIR + name)['lba'],
                            'group': group, 'group_directory': hex(directory),
                            'pair_offset': hex(pair_offset), 'slot': slot,
                            'context_offset': hex(context), 'palette_table_offset': hex(table),
                            'palette_offset': hex(palette), 'palette_bytes': 64,
                            'palette_sha256': hashlib.sha256(raw).hexdigest(),
                            'upload': '(0x100, 0x1E0 + context[7], 32, 1)',
                            'draw_clut': 'GetClut(0x100, 0x1E0 + context[7])',
                            'image_gate': 'accepted by user 2026-10-07 (ikki_ic_draw_clut.md)', '_palette': raw})
    return records


def normal_page_images():
    from PIL import Image

    records = trace()
    palettes = {}
    for r in records:
        if r['family'] in palettes:
            assert palettes[r['family']] == r['_palette']
        palettes[r['family']] = r['_palette']
    pages = source.pages('IC_')
    images = {}
    for page in pages:
        family = page['name'].split('_')[1]
        raw = palettes[family]
        words = struct.unpack('<32H', raw)
        assert max(page['page']) < 32
        vram = PsxVram()
        vram.upload_rect(320, 0, 64, 128, page['page'])
        vram.upload_rect(256, 480, 32, 1, raw)
        tp, clut = texpage_encode(320, 0, TP_8BIT), clut_encode(256, 480)
        # Independent addressing: GPU-style VRAM sampling agrees with direct indices.
        pixels = []
        for y in range(128):
            for x in range(128):
                index = vram.sample_texel(tp, x, y)
                word = vram.get_word(256 + index, 480)
                assert index == page['page'][y * 128 + x]
                assert word == words[index]
                assert vram.sample_color(tp, clut, x, y) == rgb555_to_rgb888(words[index])
                pixels.append((*rgb555_to_rgb888(word), 255 if index else 0))
        image = Image.new('RGBA', (128, 128))
        image.putdata(pixels)
        images[page['name']] = image
    report = [{k: v for k, v in r.items() if not k.startswith('_')} for r in records]
    provenance = {'decoder': 'lzss.py v2.0.0; full consumption', 'palettes': report,
                  'pages': [{k: v for k, v in p.items() if k != 'page'} for p in pages]}
    return images, provenance


def render(out):
    from PIL import Image, ImageDraw

    images, provenance = normal_page_images()
    out.mkdir(parents=True, exist_ok=True)
    sheet = Image.new('RGB', (4 * 384, 7 * 408), (36, 36, 36))
    labels = ImageDraw.Draw(sheet)
    for name, image in images.items():
        stem = Path(name).stem
        image.save(out / (stem + '.png'))
        _, family, page = stem.split('_')
        x = ('KWA', 'PAN', 'SHU', 'TEO').index(family) * 384
        y = int(page) * 408
        labels.text((x + 8, y + 4), name + ' — candidate', fill='white')
        enlarged = image.resize((384, 384), Image.Resampling.NEAREST)
        sheet.paste(enlarged, (x, y + 24), enlarged)
    sheet.save(out / 'ic_engine_clut_candidates.png')
    sheet.crop((0, 0, sheet.width, 408)).save(out / 'ic_first_pages_candidate.png')
    (out / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.out:
        render(args.out)
    else:
        print(json.dumps([{k: v for k, v in r.items() if not k.startswith('_')} for r in trace()], indent=2))
