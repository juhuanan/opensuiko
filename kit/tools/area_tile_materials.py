"""Disc-backed base tiles: MAIN.EXE 800C3704 -> 800C42F0 -> 800C4514.

Header +08 is the ordered atlas table, +0c the CLUT table, +10 the
per-atlas table of 64 palette bytes, and +14 the u16 tilemap. The base
tile consumer at 8014D2BC..8014D310 uses the resulting 8-byte descriptors.
No appearance scoring or room-specific overrides.
"""
import struct

import lzss
from PIL import Image
from psx_vram import rgb555_to_rgb888

RAM_BASE = 0x80010000


def load_room_materials(data, header, cache=None):
    """Return (ordered blobs, palette per tile code, provenance metadata).

    Only referenced atlases/palettes need decoding. Unused atlas slots stay
    None; a referenced null pointer, bad selector or partial decode fails.
    cache is scoped to this source file, keyed by compressed-stream offset.
    """
    def span(off, size):
        if off < 0 or size > len(data) - off:
            raise ValueError('area material span outside file: %#x + %d' % (off, size))
        return off

    def pointer(off, size):
        span(off, 4)
        return span(struct.unpack_from('<I', data, off)[0] - RAM_BASE, size)

    span(header, 0x18)
    w, h = struct.unpack_from('<HH', data, header)
    count, pal_count = data[header + 4:header + 6]
    ctab = pointer(header + 8, count * 4)
    dtab = pointer(header + 12, pal_count * 4)
    etab = pointer(header + 16, count * 4)
    tm = pointer(header + 20, w * h * 2)
    if tm % 2:
        raise ValueError('tilemap pointer not halfword-aligned')
    # Check even unused local streams: a map inside compressed bytes is invalid.
    for bi in range(count):
        raw_pointer = struct.unpack_from('<I', data, ctab + bi * 4)[0]
        if raw_pointer == 0:
            continue
        bo = span(raw_pointer - RAM_BASE, 4)
        clen = struct.unpack_from('<I', data, bo)[0]
        span(bo + 4, clen)
        if tm < bo + 4 + clen and bo < tm + w * h * 2:
            raise ValueError('tilemap span overlaps compressed blob at %#x' % bo)
    codes = set(struct.unpack_from('<%dH' % (w * h), data, tm))
    if not codes or max(codes) >= count * 64:
        raise ValueError('tile code exceeds room atlas table (%d slots)' % count)
    cache = {} if cache is None else cache
    blobs = [(None, None)] * count
    tile_palettes = {}
    palette_cache = {}
    selector_offsets = {}
    selectors = {}
    for bi in sorted({code // 64 for code in codes}):
        bo = pointer(ctab + bi * 4, 4)
        clen = struct.unpack_from('<I', data, bo)[0]
        span(bo + 4, clen)
        if bo not in cache:
            raw = lzss.decode_strict(data[bo + 4:bo + 4 + clen])
            if len(raw) != 16384:
                raise ValueError('atlas %#x decoded to %d bytes, expected 16384' % (bo, len(raw)))
            cache[bo] = raw
        blobs[bi] = (bo, cache[bo])
        eo = pointer(etab + bi * 4, 64)
        selector_offsets[str(bi)] = eo
        selectors[str(bi)] = list(data[eo:eo + 64])
        for code in sorted(c for c in codes if c // 64 == bi):
            pi = data[eo + code % 64]
            if pi >= pal_count:
                raise ValueError('tile %d selects palette %d, only %d declared' % (code, pi, pal_count))
            if pi not in palette_cache:
                po = pointer(dtab + pi * 4, 512)
                palette_cache[pi] = (po, [rgb555_to_rgb888(v) for v in struct.unpack_from('<256H', data, po)])
            tile_palettes[code] = palette_cache[pi][1]
    metadata = {
        'method': 'tile_palette_table', 'heuristic': False,
        'selector': 'header[+0x10][code//64][code%64] -> header[+0x0c][palette]',
        'header_offset': header, 'tilemap_offset': tm,
        'atlas_table_offset': ctab, 'palette_table_offset': dtab,
        'selector_table_offset': etab, 'selector_offsets': selector_offsets,
        'selectors': selectors,
        'atlas_offsets': {str(i): off for i, (off, _) in enumerate(blobs) if off is not None},
        'palette_offsets': {str(i): p[0] for i, p in palette_cache.items()},
        'decoder': 'lzss.py ' + lzss.__version__,
    }
    return blobs, tile_palettes, metadata


def render_tilemap(data, blobs, palette, w, h, tm, tile_palettes=None):
    """Render a base layer; palette is the legacy single-palette probe input."""
    codes = struct.unpack_from('<%dH' % (w * h), data, tm)
    if max(codes) // 64 >= len(blobs):
        raise IndexError('tile index references blob %d but only %d decoded' % (max(codes) // 64, len(blobs)))
    image = Image.new('RGB', (w * 16, h * 16))
    tiles = {}
    for j, code in enumerate(codes):
        if code not in tiles:
            bi, si = divmod(code, 64)
            raw = blobs[bi][1]
            pal = tile_palettes[code] if tile_palettes is not None else palette
            sx, sy = si % 8 * 16, si // 8 * 16
            tile = Image.new('RGB', (16, 16))
            tile.putdata([pal[raw[(sy + y) * 128 + sx + x]] for y in range(16) for x in range(16)])
            tiles[code] = tile
        image.paste(tiles[code], (j % w * 16, j // w * 16))
    return image
