#!/usr/bin/env python3
"""BATH bathhouse texture renderer — from static analysis of BATH.BIN.

CONFIRMED FROM CODE (see kit/docs/decode_bath_pixels.md):
- Per-bank 256-color CLUTs in BATH.BIN overlay at 0x8008d114 + bank*0x200.
  Uploaded by bath_sound_load @0x80081298 (case 0) to VRAM (0, 0x1e0)
  via RECT (x=0, y=0x1e0, w=0x100, h=1).
- Renderer (e.g. @0x800820d0) computes CLUT word via vtable+0x8c with
  (a0=0, a1=0x1e0) -> 0x7800, confirming 8-bit indexed textures.
- BATH_*.BIN decoded blobs uploaded (16384 bytes each) to 64x128-word
  VRAM rects from table @0x80085884.

NOT SOLVED: the texture pixel layout. The 16384-byte uploads do not
decode as linear 8-bit, 4-bit, 16-bit, column-major, tiled, XORed, or
bit-unpacked rasters. The pixel transform remains unknown.

Usage:
  bath_render.py clut --out DIR     # extract 4 bank CLUTs as PNG swatches
  bath_render.py attempt --out DIR  # best-effort texture attempts (do NOT ship)
"""
import struct, sys, os
from PIL import Image

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)
from psx_vram import rgb555  # noqa: E402


BASE = 0x80080000
OVERLAY = os.path.join(_KIT, "extracted/bin_overlays/DATA/03_SHIRO/BATH.BIN")
DECODED = os.path.join(_KIT, "work/assets_zig/data/shiro/decoded")
# bank CLUT addresses in overlay (from bath_sound_load case 0: [0x80085874 + bank*4])
CLUT_ADDR = [0x8008d114 + b * 0x200 for b in range(4)]
# VRAM upload rects (from table @0x80085884, 8-byte entries: x,y,w,h u16)
RECTS = [(0x2c0,0x0,0x40,0x80),(0x300,0x0,0x40,0x80),(0x340,0x0,0x40,0x80),
         (0x2c0,0x80,0x40,0x80),(0x300,0x80,0x40,0x80),(0x340,0x80,0x40,0x80)]

def load_clut(bank):
    with open(OVERLAY, 'rb') as fh:
        d = fh.read()
    return struct.unpack_from('<256H', d, CLUT_ADDR[bank] - BASE)

def cmd_clut(out):
    os.makedirs(out, exist_ok=True)
    for b in range(4):
        pal = load_clut(b)
        img = Image.new('RGB', (256, 16))
        img.putdata([rgb555(w) for w in pal])
        img = img.resize((512, 32), Image.NEAREST)
        p = os.path.join(out, f"bath_bank{b}_clut256.png")
        img.save(p)
        print(f"wrote {p}")

def cmd_attempt(out):
    """Best-effort texture renders. NONE verified — do not ship as assets."""
    os.makedirs(out, exist_ok=True)
    files = sorted(f for f in os.listdir(DECODED) if f.startswith("BATH_") and f.endswith(".dec"))
    for fn in files:
        bank = int(fn[5])  # BATH_<bank><idx>
        pal = load_clut(bank)
        with open(os.path.join(DECODED, fn), 'rb') as fh:
            raw = fh.read()
        px = raw[:16384]
        # Attempt 1: 128x128 8-bit linear (matches 64x128-word VRAM rect)
        img = Image.new('RGB', (128, 128))
        img.putdata([rgb555(pal[b]) for b in px])
        img = img.resize((512, 512), Image.NEAREST)
        p = os.path.join(out, fn.replace(".dec", "_8bpp128_attempt.png"))
        img.save(p)
        print(f"wrote {p} (UNVERIFIED)")

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("clut", "attempt"):
        print(__doc__)
        sys.exit(1)
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else "/tmp/bath_out"
    {"clut": cmd_clut, "attempt": cmd_attempt}[sys.argv[1]](out)
