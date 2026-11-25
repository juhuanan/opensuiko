#!/usr/bin/env python3
"""Decode DATA/03_SHIRO/DATA/STONE_*.BIN tile files.

Container (verified 2026-10-01 from STONE.BIN overlay disassembly):
  [u32 little-endian compressed length][LZSS payload]
  Decoder = text_decode_stream (vtable+0x84), bit-exact vs kit/tools/text_lzss.py
  (MAIN.EXE @0x800C3144).

Game pipeline (STONE.BIN overlay, base 0x80080000):
  stone_lookup_step @0x80080f54: CdRead (vtable+0x10) selected STONE_*.BIN
      to 0x8008DA44 using (size,LBA) table @0x800A1EFC, indexed via byte
      table @0x80084BC0 <- state byte 0x2d
  text_decode_stream (vtable+0x84): 0x8008DA44 -> 0x80091A44
  stone_loadimage_wrap_a @0x80083d98: LoadImage (vtable+0x70) RECT
      {x=$a1, y=$a2, w=0x40, h=0x80} = 64x128 16-bit words = 16384 bytes
      from 0x80091A44. Called as (0x80091A44, 0x240, 0x100).

VRAM (from overlay):
  Tile RECTs: table @0x80084CDC, 16 entries of (x,y,w,h) u16, all 64x128.
  Palettes: 12x 256-color. 4 in BSS @0x800A1F24/0x800A2124/0x800A2324/0x800A2524
      (filled by MAIN.EXE at runtime; no writer in overlay) -> VRAM y=0x1e0,0x1e1,0x1e2,0x1e8.
      8 in overlay @0x80089A0C+i*0x200 -> VRAM y=0x1ea..0x1f1.
      Plus one 16-color @0x8008DA0C -> VRAM (0x10,0x180).

PIXEL VERDICT (2026-10-01): UNPROVEN. The 16384-byte payload does not form a
coherent 2D image under 20+ layout/palette combinations (16-bit 64x128, 8-bit
128x128/64x128, 4-bit, 8x8/16x16 blocked, column-major, row-deinterleaved,
false-color, grayscale, histogram-equalized). 2D autocorrelation: horizontal
0.78 at dx=1 decaying with distance, vertical ~0.10 for all dy>0 -- the data
is 128 independent 1D signals, not a 2D image. No PNG shipped (noise rule).
"""
import sys, struct
sys.path.insert(0, __import__('os').path.dirname(__file__))
from text_lzss import decompress

TILE_BYTES = 16384  # 64x128 16-bit words uploaded via LoadImage

def decode_file(path):
    with open(path, 'rb') as fh:
        raw = fh.read()
    clen = struct.unpack_from('<I', raw, 0)[0]
    assert clen == len(raw) - 4, f"length prefix {clen} != file size {len(raw)}"
    dec = decompress(raw[4:])
    assert len(dec) >= TILE_BYTES, f"decoded {len(dec)} < {TILE_BYTES}"
    return dec

if __name__ == '__main__':
    for p in sys.argv[1:]:
        dec = decode_file(p)
        print(f"{p}: decoded {len(dec)} bytes, tile {TILE_BYTES}")
