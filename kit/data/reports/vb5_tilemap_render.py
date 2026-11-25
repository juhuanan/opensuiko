#!/usr/bin/env python3
"""Render VB5.BIN tilemap candidates with candidate index->blob mappings."""
import struct, json, sys
sys.path.insert(0, '/home/hatch/workspace/suikoden/kit/tools')
from lzss import decode_strict
from PIL import Image

VB = '/home/hatch/workspace/suikoden/kit/extracted/bin_overlays/DATA/02_AREA.B/VB5.BIN'
D = open(VB, 'rb').read()

def u16(off): return struct.unpack_from('<H', D, off)[0]
def u32(off): return struct.unpack_from('<I', D, off)[0]

# --- CLUT ---
cl = json.load(open('/home/hatch/workspace/suikoden/kit/work/area_atlas/area_cluts.json'))
rgb555_hex = cl['entries'][0]['rgb555']  # VB5.BIN
PAL = []
for h in rgb555_hex:
    c = int(h, 16)
    r = (c & 0x1f); g = ((c >> 5) & 0x1f); b = ((c >> 10) & 0x1f)
    PAL.append(((r * 255) // 31, (g * 255) // 31, (b * 255) // 31))

# --- decode 4 cave blobs ---
CAVE_OFFS = [0x36794, 0x39a94, 0x3c104, 0x3ea60]
TILES = []
for off in CAVE_OFFS:
    clen = u16(off)
    out = decode_strict(D[off + 4:off + 4 + clen])
    assert len(out) == 16384
    TILES.append(out)  # 128x128 8-bit

def tile_rgb(idx):
    """Render one 128x128 tile as RGB PIL image."""
    px = TILES[idx]
    im = Image.new('RGB', (128, 128))
    dp = im.load()
    for y in range(128):
        for x in range(128):
            dp[x, y] = PAL[px[y * 128 + x]]
    return im

def render_tilemap(tm_off, w, h, mapping, out_path, scale=1):
    """mapping: tilemap u16 value -> tile index (0-3) or None for black."""
    vals = struct.unpack_from('<%dH' % (w * h), D, tm_off)
    im = Image.new('RGB', (w * 128, h * 128), (0, 0, 0))
    unmapped = set()
    for j in range(h):
        for i in range(w):
            v = vals[j * w + i]
            t = mapping(v)
            if t is None:
                unmapped.add(v)
                continue
            im.paste(tile_rgb(t), (i * 128, j * 128))
    if scale != 1:
        im = im.resize((w * 128 // scale, h * 128 // scale), Image.NEAREST)
    im.save(out_path)
    return unmapped

if __name__ == '__main__':
    # quick sanity: save the 4 tiles
    for i in range(4):
        tile_rgb(i).save('/tmp/vb5_cavetile_%d.png' % i)
    print('tiles saved')
