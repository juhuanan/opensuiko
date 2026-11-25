#!/usr/bin/env python3
"""
btsky_lzss.py -- thin wrapper over kit/tools/lzss.py (consolidated 2026-10-02).

BT/SKY duel assets use the SAME codec as text_decode_stream @0x800C3144
(LSB-first flags; 2-byte match copies (t0>>2)+3; 1-byte match copies
((t0&0x30)>>4)+2; literal run = (t0&0x3F)+8 fresh bytes). The implementation
lives in lzss.py; see it and docs/lzss_consolidation.md.

Container: [u32 comp_len][LZSS payload] (comp_len excludes the 4-byte header).
Decoded output: 8-bit bytes; for BT/SKY the last 512 bytes are a 256-color
PS1 RGB555 palette and the preceding bytes are 8-bit palette indices.

CORRECTIONS (2026-10-02): the pre-consolidation decoder's literal run copied
(t0&0x3F)+7 bytes where hardware copies (t0&0x3F)+8, desynchronising the
stream at the first run token. (Its LONG/SHORT match loops were already
correct.) Old decode outputs are invalidated. The stale docstring claim that
@0x800C3144 is "MSB-first" was also wrong -- it is LSB-first.

USAGE:
  from btsky_lzss import decompress_file
  pixels, palette = decompress_file('BT1_1S00.BIN')
    # pixels: bytes of 8-bit indices, palette: list of 256 (r,g,b) tuples
"""

import struct

from lzss import (
    decode_strict,
    decode_container,
    decode_container_strict,
    LZSSError,
    TruncationError,
    TrailingBytesError,
)

__version__ = "2.0.0"


def decompress(payload: bytes) -> bytes:
    """Decompress LZSS payload (after the 4-byte comp_len header). Strict."""
    return decode_strict(payload)


def ps1_to_rgb(w: int):
    """PS1 RGB555 (0BBBBBGGGGGRRRRR) to 8-bit RGB tuple."""
    return ((w & 0x1F) << 3, ((w >> 5) & 0x1F) << 3, ((w >> 10) & 0x1F) << 3)


def decompress_file(path: str):
    """
    Decompress a BT/SKY .BIN file.
    Returns (pixels, palette): pixels is bytes of 8-bit indices,
    palette is a list of 256 (r, g, b) tuples.

    Requires FULL input consumption: the container must span the whole file, or
    this is a partial decode and the pixels are wrong (AGENTS.md §3,
    docs/lzss_consolidation.md).
    """
    with open(path, 'rb') as f:
        blob = f.read()
    (comp_len,) = struct.unpack('<I', blob[:4])
    if comp_len != len(blob) - 4:
        raise LZSSError(
            "header comp_len %d != file payload %d" % (comp_len, len(blob) - 4))
    out = decode_container_strict(blob)
    pal_raw = out[-512:]
    palette = [ps1_to_rgb(w) for w in struct.unpack('<256H', pal_raw)]
    return out[:-512], palette


if __name__ == '__main__':
    import sys, glob, os
    d = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     '..', 'extracted', 'bin_overlays', 'DATA', '12_IKKI', 'DATA')
    for fn in sorted(glob.glob(os.path.join(d, 'BT*.BIN')) + glob.glob(os.path.join(d, 'SKY*.BIN'))):
        pixels, pal = decompress_file(fn)
        print('%-14s pixels=%6d palette_colors=%d' % (os.path.basename(fn), len(pixels), len(pal)))
