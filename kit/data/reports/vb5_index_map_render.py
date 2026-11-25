#!/usr/bin/env python3
"""Test render of VB5.BIN tilemap using discovered index->blob lookup tables.
- indices 0-3  -> 15-entry table @0x31190[0..3] -> blobs #15-18 (VRAM oracle tiles)
- index 5      -> 15-entry table[5] -> zeros (render black; unresolved)
- indices 90-97-> 98-entry table @0x1ca98[90..97] -> blobs #7-14
- indices 51,52,57,68,69,72,73 -> 98-entry table descriptors (objects; magenta)
"""
import struct, json, sys
sys.path.insert(0, '/home/hatch/workspace/suikoden/kit/tools')
from lzss import decode_strict
from PIL import Image

BASE = '/home/hatch/workspace/suikoden/kit'
d = open(f'{BASE}/extracted/bin_overlays/DATA/02_AREA.B/VB5.BIN', 'rb').read()

# CLUT: 512B RGB555 at file offset 9492
clut_off = 9492
pal = struct.unpack('<256H', d[clut_off:clut_off + 512])
def rgb555(c):
    return ((c & 31) * 255 // 31, ((c >> 5) & 31) * 255 // 31, ((c >> 10) & 31) * 255 // 31)
PAL = [rgb555(c) for c in pal]

def decode_blob(fo):
    ln = struct.unpack('<H', d[fo:fo + 2])[0]
    return decode_strict(d[fo + 4:fo + 4 + ln])

def tile_img(blob_bytes):
    im = Image.new('RGB', (128, 128))
    px = im.load()
    for y in range(128):
        for x in range(128):
            px[x, y] = PAL[blob_bytes[y * 128 + x]]
    return im

# 15-entry table @0x31190
t15 = [struct.unpack('<I', d[0x31190 + i * 4:0x31190 + i * 4 + 4])[0] - 0x80010000 for i in range(15)]
# 98-entry table @0x1ca98
t98 = [struct.unpack('<I', d[0x1ca98 + i * 4:0x1ca98 + i * 4 + 4])[0] - 0x80010000 for i in range(98)]

tiles = {}
# indices 0-3 via 15-entry table
for idx in range(4):
    tiles[idx] = tile_img(decode_blob(t15[idx]))
# index 5 -> table[5] = zeros -> black tile
tiles[5] = Image.new('RGB', (128, 128), (0, 0, 0))
# indices 90-97 via 98-entry table -> blobs #7-14
for idx in range(90, 98):
    tiles[idx] = tile_img(decode_blob(t98[idx]))
# object indices -> magenta
for idx in [51, 52, 57, 68, 69, 72, 73]:
    tiles[idx] = Image.new('RGB', (128, 128), (255, 0, 255))

# tilemap @0x31208, 24x16 u16
tm = struct.unpack('<384H', d[0x31208:0x31208 + 768])
W, H, T = 24, 16, 128
canvas = Image.new('RGB', (W * T, H * T), (0, 0, 0))
for r in range(H):
    for c in range(W):
        v = tm[r * W + c]
        t = tiles.get(v)
        if t is None:
            t = Image.new('RGB', (T, T), (0, 255, 255))  # cyan = unmapped
        canvas.paste(t, (c * T, r * T))
canvas.save(f'{BASE}/work/area_tiles/vb5_indexmap_test.png')
# 4x nearest for viewing
canvas.resize((W * T // 32, H * T // 32), Image.NEAREST).save(f'{BASE}/work/area_tiles/vb5_indexmap_test_small.png')
print('saved vb5_indexmap_test.png', canvas.size)
# also save the 8 object tiles (90-97) as contact sheet
sheet = Image.new('RGB', (128 * 8, 128))
for i, idx in enumerate(range(90, 98)):
    sheet.paste(tiles[idx], (i * 128, 0))
sheet.save(f'{BASE}/work/area_tiles/vb5_tiles_90_97.png')
print('saved vb5_tiles_90_97.png')
