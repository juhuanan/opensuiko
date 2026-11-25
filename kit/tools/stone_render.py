#!/usr/bin/env python3
"""
stone_render.py — Decode STONE.BIN tile pixels from consumer code analysis.

Derived from static analysis of STONE.BIN (overlay base 0x80080000):

1. stone_texpage_grid @0x80081D74 builds custom 20-byte packets:
   +0x03: tag=4, +0x04..0x06: RGB=(0x80,0x80,0x80), +0x07: 0x64,
   +0x08: x (u16), +0x0A: y (u16), +0x0C: u (u8), +0x0D: v (u8),
   +0x0E: clut (u16), +0x10: w=8 (u16), +0x12: h=12 (u16).
   Each tile-map byte becomes one 8x12 textured quad.

2. Tile-byte -> (u,v) helper @0x800824a0 (fully reversed):
   for a0 in [0x11,0x4E]: v1=a0+0x2D; u=((v1%16)*8-0x80)&0xFF; v=(v1//16)*12
   for a0 in [0x4F,0xEF]: v1=a0+9;    u=((v1%16)*8-0x80)&0xFF; v=((v1//16)*12-0x80)&0xFF
   else: u=(a0*8-0x60)&0xFF; v=0x18

3. CLUT word builder @0x8014ABD4 (MAIN.EXE): (a1<<6)|((a0>>4)&0x3F).
   Grid calls with (0x140,0x180) -> 0x6014 = CLUT at VRAM (0x140,0x180)=(320,384).
   This is the 16-color CLUT uploaded from overlay 0x8008DA0C by
   stone_resource_init @0x8008044c (RECT x=0x140,y=0x180,w=0x10,h=0x1).

4. Font textures (4-bit, 128x128, low-nibble-first):
   0x80085A0C -> VRAM (0x380,0x180) [32x128 words]
   0x80087A0C -> VRAM (0x3A0,0x180) [32x128 words]
   Both decode to kanji glyph pages with the 16-color CLUT.

Usage:
  stone_render.py font --out <png>     # render both font pages
  stone_render.py clut --out <png>     # render 16-color CLUT swatch
"""

import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))
from psx_vram import rgb555  # noqa: E402

OVERLAY = Path(__file__).parent.parent / "extracted/bin_overlays/DATA/03_SHIRO/STONE.BIN"
BASE = 0x80080000

FONT_A = 0x80085A0C
FONT_B = 0x80087A0C
FONT_SIZE = 8192  # bytes = 128x128 4-bit
CLUT_ADDR = 0x8008DA0C


def load_clut(raw):
    clut = struct.unpack('<16H', raw[CLUT_ADDR - BASE:CLUT_ADDR - BASE + 32])
    return np.array([rgb555(c) for c in clut], dtype=np.uint8)


def decode_4bit(data, width=128, height=128):
    """4-bit low-nibble-first, row-major. Returns (h,w) index array."""
    b = np.frombuffer(data, dtype=np.uint8)
    px = np.empty(width * height, dtype=np.uint8)
    px[0::2] = b & 0xF
    px[1::2] = b >> 4
    return px.reshape(height, width)


def main():
    if len(sys.argv) < 4 or sys.argv[2] != "--out":
        print(__doc__)
        sys.exit(1)
    cmd, out = sys.argv[1], Path(sys.argv[3])
    raw = OVERLAY.read_bytes()
    pal = load_clut(raw)

    if cmd == "font":
        for name, addr in (("a", FONT_A), ("b", FONT_B)):
            idx = decode_4bit(raw[addr - BASE:addr - BASE + FONT_SIZE])
            img = Image.fromarray(pal[idx])
            img.save(out.parent / f"{out.stem}_{name}{out.suffix}")
            print(f"wrote {out.parent / f'{out.stem}_{name}{out.suffix}'}")
    elif cmd == "clut":
        sw = np.zeros((16, 16, 3), dtype=np.uint8)
        for i, c in enumerate(pal):
            sw[i, :] = c
        Image.fromarray(sw).resize((256, 256), Image.NEAREST).save(out)
        print(f"wrote {out}")
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
