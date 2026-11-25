#!/usr/bin/env python3
"""Build per-entry atlases and metadata from the swept spell tables."""
import json
import hashlib
from pathlib import Path

import numpy as np
from PIL import Image

import battle_bin

ROOT = Path(__file__).resolve().parents[2]
SWEEP = ROOT / 'kit/data/reports/spell_effect_sweep.json'
OUT = ROOT / 'kit/work/build/battle_review/entries'


def rgb(word):
    return ((word & 31) * 255 // 31, ((word >> 5) & 31) * 255 // 31, ((word >> 10) & 31) * 255 // 31)


def palette(atlas, slot):
    off = 128 * (slot // 2) + 64 + 32 * (slot % 2)
    return [rgb(int(w)) for w in np.frombuffer(atlas[off:off + 32], dtype='<u2')]


def entry_image(raw, palette_blob, entry):
    if len(raw) != 16384 or len(entry) != 8:
        raise ValueError('invalid effect page or entry')
    u = ((entry[3] & 15) * 8 - (128 if entry[7] & 128 else 0)) & 255
    v = (entry[3] >> 4) * 8
    w, h = entry[4] + 1, entry[5] + 1
    if u + w > 256 or v + h > 128:
        raise ValueError('effect crop crosses its resident page')
    colors = palette(palette_blob, entry[6])
    image = Image.new('RGBA', (w, h))
    for y in range(h):
        for x in range(w):
            # 800E2338/2390 gives horizontal reversal priority over vertical.
            sx = u + (w - 1 - x if entry[7] & 2 else x)
            sy = v + (h - 1 - y if entry[7] & 1 and not entry[7] & 2 else y)
            byte = raw[sy * 128 + sx // 2]
            index = (byte >> 4) if sx & 1 else (byte & 15)
            if index:
                image.putpixel((x, y), colors[index] + (255,))
    return image


def main():
    sections, atlases, errors, data = battle_bin.parse()
    if errors:
        raise SystemExit(errors)
    blobs = {a['offset']: a['atlas'] for a in atlases}
    sweep = json.loads(SWEEP.read_text())
    if sweep['source']['sha256'] != hashlib.sha256(data).hexdigest():
        raise ValueError('spell sweep does not match BATTLE.BIN')
    lba, size = battle_bin.battle_bin_lba()
    source = dict(sweep['source'], lba=lba, size=size)
    palette_blob = blobs[sweep['effects'][0]['palette_source']['blob_offset']]
    OUT.mkdir(parents=True, exist_ok=True)
    for index, effect in enumerate(sweep['effects']):
        pieces_meta, entries_meta = [], []
        crops = []
        for piece_index, piece in enumerate(effect['pieces']):
            ids = []
            if data[piece['source_offset']:piece['source_offset'] + 8] != bytes(piece['header']) or len(piece['entries']) != piece['header'][0]:
                raise ValueError('spell piece header does not match source bytes')
            for entry_index, entry in enumerate(piece['entries']):
                entry_offset = piece['source_offset'] + 8 + 8*entry_index
                if data[entry_offset:entry_offset + 8] != bytes(entry):
                    raise ValueError('spell entry does not match source bytes')
                offset = sections[effect['section']]['atlas_offsets'][entry[2]]
                raw = blobs[offset]
                image = entry_image(raw, palette_blob, entry)
                w, h = image.size
                ids.append(len(entries_meta))
                entries_meta.append(dict(atlas=None, x=0, y=0, w=w, h=h,
                                         dx=entry[0] - piece['header'][4],
                                         dy=entry[1] - piece['header'][5],
                                         source_blob_offset=offset,
                                         source_entry_offset=entry_offset,
                                         decoded_sha256=hashlib.sha256(raw).hexdigest(),
                                         source_entry=entry))
                crops.append(image)
            pieces_meta.append(ids)
        width = 1024
        x = y = row = 0
        for item, image in zip(entries_meta, crops):
            if x + image.width > width:
                x, y, row = 0, y + row + 1, 0
            item['x'], item['y'] = x, y
            x += image.width + 1
            row = max(row, image.height)
        height = y + row + 1
        atlas = Image.new('RGBA', (width, max(height, 1)), (0, 0, 0, 0))
        for item, image in zip(entries_meta, crops):
            atlas.alpha_composite(image, (item['x'], item['y']))
            item['atlas'] = f'{index}_atlas.png'
        atlas.save(OUT / f'{index}_atlas.png')
        meta_text = json.dumps(dict(schema='suikoden-effect-entry-review/2',
                                   ready_for_runtime=False, name=effect['name'],
                                   source=source, palette_source=effect['palette_source'],
                                   entries=entries_meta, pieces=pieces_meta,
                                   animations=effect['animations'],
                                   candidate_animation_indices=effect['phase_animations']), indent=2) + '\n'
        (OUT / f'{index}.json').write_text(meta_text)
    print(f'{len(sweep["effects"])} entry atlases')


if __name__ == '__main__':
    main()
