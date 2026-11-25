#!/usr/bin/env python3
"""
gpu_stream_render.py — Suikoden portrait rasterizer (static, no emulator).

VERIFIED PATH (0x80140A28, MAIN.EXE): dialogue portraits are v1-LZSS
(0x800C3144) compressed blobs from the AREA OVERLAY's {id,blob,param} table,
decoding to 0x1000 bytes = 64x64 8bpp pixels, plus a 256-entry CLUT at
blob+0x30 (512 bytes, uncompressed). Both are uploaded via LoadImage
(0x80148590): pixels to VRAM (0x380,0x180) as a 32x64-word rect, CLUT to
VRAM (0,0x1FE) as a 256x1-word rect.

The v2/FACE-LZSS (face_decompress.py) blob format is UNKNOWN — it is NOT a
PS1 GPU command stream (flat command-byte distribution refutes this) and
does not render as pixels in any tested layout. This tool renders the
verified v1 portrait path only. See kit/docs/gpu_stream_format.md.

Usage:
  gpu_stream_render.py <area_overlay_blob.bin> <out.png>
The blob file must be the raw {id,blob,param} entry bytes: v1-compressed
pixel data at offset 0, CLUT at offset 0x30 of the ORIGINAL entry (the
decoder input a0 points at the compressed data; CLUT is read from
s1+0x30 which is entry+0x30 in the file layout used by the overlay).
"""
import struct, sys
sys.path.insert(0, __import__('os').path.dirname(__file__))
from text_lzss import decompress as v1_decompress
from PIL import Image

def render_portrait(blob_path, out_path):
    with open(blob_path, 'rb') as fh:
        data = fh.read()
    # v1 stream starts at blob+0 (a0), decoder reads u32 len at a0 then data at a0+4
    px = v1_decompress(data[4:], ) if len(data) > 4 else b''
    # 0x80140A28 allocates 0x1000; real portraits decode to exactly 4096 bytes
    if len(px) < 4096:
        raise SystemExit('v1 decode gave %d bytes, expected >= 4096' % len(px))
    px = px[:4096]
    # CLUT: 256 x 16-bit 5-5-5 words at blob+0x30
    clut_off = 0x30
    clut_words = struct.unpack('<256H', data[clut_off:clut_off + 512])
    pal = []
    for w in clut_words:
        r = (w & 0x1F) * 255 // 31
        g = ((w >> 5) & 0x1F) * 255 // 31
        b = ((w >> 10) & 0x1F) * 255 // 31
        pal += (r, g, b)
    img = Image.frombytes('P', (64, 64), px)
    img.putpalette(pal)
    img.save(out_path)
    print('wrote %s (64x64 8bpp + 256-color CLUT)' % out_path)

if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('usage: gpu_stream_render.py <blob.bin> <out.png>')
    render_portrait(sys.argv[1], sys.argv[2])
