#!/usr/bin/env python3
"""
play04_render.py — 04_PLAY character-sprite pixel decoder.

Implements the EXACT transforms from MAIN.EXE disassembly (load base 0x800C0800).
Static analysis only. No format guessing.

Pipeline (verified from code):
  tex_bitplane_unpack_2bit @0x800C3958:
    - Calls text_decode_stream(compressed_len, src, dst)  [LZSS, MSB-first]
    - Then expands [dst, dst+0x1000) -> [dst, dst+0x4000) IN PLACE, backward:
        for i in 0xFFF down to 0:
            B = src[i]
            out[4*i+0] = (B >> 6) & 3
            out[4*i+1] = (B >> 4) & 3
            out[4*i+2] = (B >> 2) & 3
            out[4*i+3] = B & 3
      (4 pixels per byte, high bits first; processed end-to-start so the
       in-place expansion doesn't clobber unread input.)
  tile_grid_blit @0x800C3A44:
    - Uploads the 0x4000-byte buffer RAW as 64x128 16-bit words via LoadImage.
    - NO pixel reordering. VRAM position from counter @0x80179030:
        x = (((cnt//100)*5 + (cnt%5)) * 64) + 0x140
        y = (((cnt//5)%20)//5) * 128
  vram_upload_strip_a @0x800C3C5C:
    - Uploads 256x1 16-bit words from the params pointer to VRAM (0, 0x1E0+counter).
    - This is the 256-color CLUT for the 8-bit texture.

Render interpretation (the only one consistent with the code):
  - 0x4000 bytes = 16384 2-bit values (0-3), each a separate 8-bit texel.
  - 128x128 8-bit texture + 256-color CLUT.
  - Values 0-3 index CLUT entries 0-3.

USAGE:
  play04_render.py <packed_0x1000.bin> <clut_512.bin> <out.png>
    packed_0x1000.bin: 4096 bytes of packed 2-bit texture data
                       (the *compressed* input to text_decode_stream,
                        i.e. AFTER LZSS decompression, BEFORE the 2-bit unpack)
    clut_512.bin: 256 little-endian RGB555 colors (512 bytes)
    out.png: 128x128 (scaled 4x) PNG

  play04_render.py --from-file <04play.BIN> <out.png>
    Attempts to locate the texture using the S1 header. NOTE: the S1.f/g
    pointers undergo a load-time relocation that is NOT visible statically,
    so this mode is best-effort and currently produces noise. See the
    decode report for details.

STATUS (2026-10-01): The transforms are bit-exact from disassembly, but the
correct 0x1000-byte texture input cannot be located statically. The on-disc
S1.c/d/e/f values are not valid file offsets (their [len][data] units overlap
the S1 header), and no 0x1000 window of any staged decoded payload produces
sprite-like structure. Do NOT ship noise as artwork.
"""

import struct
import sys
import os

_TOOLS = os.path.dirname(os.path.abspath(__file__))
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)
from psx_vram import rgb555_to_rgb888  # noqa: E402

def tex_bitplane_unpack_2bit(packed):
    """
    Bit-exact replica of tex_bitplane_unpack_2bit @0x800C3958 (post-LZSS stage).
    Input:  0x1000 bytes (packed, 4 2-bit pixels per byte, high bits first).
    Output: 0x4000 bytes, each holding one 2-bit value (0-3).
    """
    if len(packed) < 0x1000:
        raise ValueError("packed input must be >= 0x1000 bytes, got %d" % len(packed))
    src = packed[:0x1000]
    dst = bytearray(0x4000)
    # Replicates the backward in-place expansion:
    #   a0 = 0xFFF down to 0 (source index)
    #   v1 = 0x3FFF down to 0 (dest index)
    a0 = 0xFFF
    v1 = 0x3FFF
    while True:
        b = src[a0]
        dst[v1] = b & 3; v1 -= 1
        dst[v1] = (b >> 2) & 3; v1 -= 1
        dst[v1] = (b >> 4) & 3; v1 -= 1
        a0 -= 1
        dst[v1] = (b >> 6) & 3
        if a0 < 0:
            break
        v1 -= 1
    return bytes(dst)

def render_128x128(unpacked, clut):
    """
    Render the 0x4000-byte unpacked buffer as 128x128 8-bit with CLUT.
    unpacked: 16384 bytes, values 0-3.
    clut: list of 256 (r,g,b) tuples.
    Returns a PIL Image (128x128).
    """
    from PIL import Image
    if len(unpacked) < 0x4000:
        raise ValueError("unpacked must be >= 0x4000 bytes")
    img = Image.new('RGB', (128, 128))
    px = img.load()
    for y in range(128):
        row = y * 128
        for x in range(128):
            v = unpacked[row + x]
            px[x, y] = clut[v] if v < len(clut) else (255, 0, 255)
    return img

def load_clut(path):
    with open(path, 'rb') as fh:
        data = fh.read()
    if len(data) < 512:
        raise ValueError("CLUT file must be >= 512 bytes")
    words = struct.unpack('<256H', data[:512])
    return [rgb555_to_rgb888(w) for w in words]

def main():
    if len(sys.argv) == 4 and not sys.argv[1].startswith('-'):
        with open(sys.argv[1], 'rb') as fh:
            packed = fh.read()
        clut = load_clut(sys.argv[2])
        out = sys.argv[3]
        unpacked = tex_bitplane_unpack_2bit(packed)
        img = render_128x128(unpacked, clut)
        img = img.resize((512, 512), 0)  # NEAREST
        img.save(out)
        print("wrote %s" % out)
    elif len(sys.argv) == 3 and sys.argv[1] == '--from-file':
        print("ERROR: --from-file is not implemented: the S1.f/g texture pointer")
        print("undergoes a load-time relocation invisible to static analysis.")
        print("See kit/docs/decode_04play_pixels.md for the full analysis.")
        sys.exit(2)
    else:
        print(__doc__)
        sys.exit(1)

if __name__ == '__main__':
    main()
