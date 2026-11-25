"""Candidate overlay of selected initial-frame section objects, from disc.

Follows 8012E8D4 -> 800C3D38/800C3E9C -> 8012F3D8 -> 800C3EF0.
This is a diagnostic, not full scene composition: no scripts, animation,
entity layer, reflected pieces or semitransparent blending are implemented.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from PIL import Image
from area_tile_materials import load_room_materials, render_tilemap
from disc import extract
from lzss import decode_strict, __version__ as decoder_version
from psx_vram import PsxVram, texpage_encode, TP_8BIT, rgb555_to_rgb888


def probe(source, header_index, objects, out):
    kit = Path(__file__).resolve().parents[1]
    record = next(r for r in json.loads((kit / 'extracted/iso_files.json').read_text()) if r['path'] == source)
    data = extract(record['lba'], record['size'])

    def ptr(off):
        value = struct.unpack_from('<I', data, off)[0] - 0x80010000
        if not 0 <= value < len(data):
            raise ValueError('pointer outside source file at %#x' % off)
        return value

    header = ptr(ptr(ptr(0) + 4) + header_index * 4)
    width, height = struct.unpack_from('<HH', data, header)
    blobs, palettes, base_metadata = load_room_materials(data, header)
    image = render_tilemap(data, blobs, None, width, height, ptr(header + 20), palettes).convert('RGBA')
    ctx = ptr(ptr(header + 32))  # builder 8012E9A8..8012E9B4: first context
    if data[ctx + 5] & 0xc0:
        raise ValueError('32-colour contexts are outside this diagnostic')
    vram = PsxVram()
    atlas_base, palette_base = data[header + 4], data[header + 5]
    upload_source = {'file': source, 'lba': record['lba'], 'decoder': 'lzss.py ' + decoder_version}
    local_atlases, local_palettes = [], []
    for i in range(data[ctx + 4]):
        bo = ptr(ptr(ctx + 8) + 4 * i)
        length = struct.unpack_from('<I', data, bo)[0]
        payload = data[bo + 4:bo + 4 + length]
        if len(payload) != length:
            raise ValueError('short compressed atlas at %#x' % bo)
        raw = decode_strict(payload)
        if len(raw) != 16384:
            raise ValueError('atlas is not 16384 bytes')
        local_atlases.append(raw)
        c = atlas_base + i
        vram.upload_rect(320 + 64 * (5 * (c // 20) + c % 5), 128 * ((c % 20) // 5), 64, 128,
                         raw, provenance={**upload_source, 'offset': bo, 'compressed_bytes': length})
    for i in range(data[ctx + 5]):
        po = ptr(ptr(ctx + 12) + 4 * i)
        raw = data[po:po + 512]
        local_palettes.append(struct.unpack('<256H', raw))
        vram.upload_rect(0, 480 + palette_base + i, 256, 1, raw,
                         provenance={**upload_source, 'offset': po, 'kind': 'palette'})
    count = struct.unpack_from('<H', data, header + 36)[0]
    reports = []
    for i in objects:
        if not 0 <= i < count:
            raise ValueError('object index outside section')
        source_offset = ptr(header + 40) + i * 5
        X, Y, kind, _, _ = data[source_offset:source_offset + 5]
        descriptor = ptr(ptr(ctx + 20) + kind * 4)
        sheet = ptr(ptr(ctx + 16) + data[descriptor + 4] * 4)
        anchor_x, anchor_y = X * 8 - data[sheet + 4], Y * 8 - data[sheet + 5]
        pieces = []
        # Builder emits vertices backwards; retain that order for this probe.
        for j in reversed(range(data[sheet])):
            vertex_offset = sheet + 8 + j * 8
            x, y, cell, uv, w, h, palette, flags = data[vertex_offset:vertex_offset + 8]
            if flags:
                raise ValueError('reflected/flagged vertex outside this diagnostic')
            c = atlas_base + cell
            tp = texpage_encode(320 + 64 * (5 * (c // 20) + c % 5), 256 * ((c % 20) // 10), TP_8BIT)
            u, v = (uv & 15) * 8, 128 * (((c % 20) // 5) % 2) + (uv >> 4) * 8
            pixels = []
            for dy in range(h):
                for dx in range(w):
                    index = vram.sample_texel(tp, (u + dx) & 255, (v + dy) & 255)
                    word = vram.get_word(index, 480 + palette_base + palette)
                    # Independent extraction: direct local atlas + CLUT.
                    # The target's pieces all fit their own 128x128 atlas.
                    if (uv & 15) * 8 + w > 128 or (uv >> 4) * 8 + h > 128:
                        raise ValueError('cross-atlas piece outside independent check')
                    direct = local_atlases[cell][((uv >> 4) * 8 + dy) * 128 + (uv & 15) * 8 + dx]
                    if word != local_palettes[palette][direct]:
                        raise ValueError('VRAM and direct extraction disagree')
                    pixels.append((*rgb555_to_rgb888(word), 255 if word else 0))
            tile = Image.new('RGBA', (w, h))
            tile.putdata(pixels)
            image.alpha_composite(tile, (anchor_x + x, anchor_y + y))
            pieces.append({'vertex_offset': vertex_offset, 'bounds': [anchor_x + x, anchor_y + y, w, h],
                           'texpage': tp, 'uv': [u, v], 'clut_row': 480 + palette_base + palette})
        reports.append({'object': i, 'type': kind, 'source_offset': source_offset,
                        'descriptor_offset': descriptor, 'sheet_offset': sheet, 'pieces': pieces})
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    image.save(out / 'objects_candidate.png')
    metadata = {'source': upload_source, 'source_size': len(data), 'source_sha256': hashlib.sha256(data).hexdigest(),
                'header_offset': header, 'context_offset': ctx, 'base': base_metadata,
                'objects': reports, 'uploads': vram.uploads, 'independent_sampling': 'all sampled RGB555 words agree',
                'scope': 'Selected section objects, initial frame only; candidate, not full scene'}
    (out / 'probe.json').write_text(json.dumps(metadata, indent=2) + '\n')
    return image


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--file', default='DATA/02_AREA.B/VB6.BIN')
    parser.add_argument('--header', type=int, default=0)
    parser.add_argument('--objects', type=int, nargs='+', default=[0, 1, 2, 3])
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    probe(args.file, args.header, args.objects, args.out)
