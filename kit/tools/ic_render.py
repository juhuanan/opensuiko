#!/usr/bin/env python3
"""IC duel-icon renderer — implements EXACTLY what the 12_IKKI overlay code does.

Code-derived pipeline (PAN_TEO.BIN @ 0x80080000, verified in SHU_KWA/SHU_TEO):
  case 0 (0x80081410): vtable+0x10 CdRead file -> 0x80098C08
  case 1/5 (0x80081688): vtable+0x0C sync (wait for CD)
  case 2 (0x80081458): vtable+0x84 decompress (0x80098C0C -> 0x8009CC08)
                       then vtable+0x70 upload RECT(64x128 16-bit) from 0x8009CC08
  **There is NO pixel transform between decompress and upload.**
  The LZSS-decoded blob is passed directly to the vtable+0x70 function.

SHU_KWA/SHU_TEO use the identical parser with different BSS addresses
(decompress dst 0x8009C634, CdRead dst 0x80098634).

FINDING (2026-10-01): The decompressed blobs (14,235-16,178 bytes) do NOT
decode to viewable images under any tested interpretation:
  - 16-bit RGB555 LE/BE at 64x128: noise
  - 8-bit linear at widths 64/128, column-major: noise
  - 8-bit with overlay 256-CLUT @0x80089B94: noise
  - 8-bit with 32-CLUT @0x8008A1B4: noise (CLUT is all-white placeholder)
  - Delta/DPCM (signed/unsigned, 1D and per-row cumsum): 1D structure but no 2D icon
  - Autocorrelation: flat, no row periodicity (lags 1-400)
RESOLVED 2026-10-01 (late): vtable+0x70 IS gpu_loadimage_wrap @0x80148590
  (function_labels.csv: "GPU LoadImage wrapper with debug print; calls
  0x801483D4"). Disassembly shows thin wrapper: debug print, then
  jalr *(*(0x80171FE4)+8) with (a0=*(obj+0x20), a1=RECT*, a2=8, a3=data).
  CONFIRMED PASSTHROUGH — no pixel transform. The earlier "mislabeled
  memmove" suspicion is refuted; the vtable slot genuinely resolves to
  the LoadImage wrapper at runtime.
  Upload RECT (PAN_TEO case 2 @0x80081458, SHU variants identical):
    x = ((c/20)*5 + (c%5))*64 + 320   [c = icon counter 0..6]
    y = (((c%20)/5))*128
    w = 64, h = 128  (16-bit halfwords) = 16,384 bytes
  7 icon slots tile VRAM x=320..766, y=0/128: icons 0-4 at y=0,
  icons 5-6 at y=128. Fits an 8-bit 128x128 texpage region exactly
  (texpage X=320/64=5, Y=0), but the texture MODE (4/8/16-bit) is
  runtime-determined via texpage builder (vtable+0x6c @0x8014AB0C,
  reads mode byte @0x80171FEC) and the overlay BSS palettes
  (0x8009A1B4 32-entry, 0x80099B94 256-entry) are zeros in the file
  and never written by overlay or MAIN.EXE — so the palette source
  is unlocated and the pixel format cannot be fixed statically.

This tool reproduces the code path faithfully. It does NOT ship PNGs
because the output is not verifiable art (no-noise rule).
"""
import struct, sys, os, glob
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from text_lzss import decompress

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)

# Back-compat alias: this tool used to define this from a hardcoded path.
kit = _KIT


def _kit(*parts):
    return os.path.join(_KIT, *parts)


def _root(*parts):
    return os.path.join(_ROOT, *parts)


OVERLAY_BASE = 0x80080000
# PAN_TEO BSS addresses (SHU_KWA/SHU_TEO differ; parser identical)
CDREAD_DST = 0x80098C08
DECOMPRESS_DST = 0x8009CC08
RECT_W, RECT_H = 0x40, 0x80  # 64x128 16-bit words

def load_ic(path):
    """Reproduce the overlay load: container -> decompress -> upload buffer."""
    with open(path, 'rb') as fh:
        d = fh.read()
    comp_len = struct.unpack_from('<I', d)[0]
    assert comp_len == len(d) - 4, 'container framing'
    blob = decompress(d[4:4+comp_len])
    # vtable+0x70 uploads RECT_W*RECT_H 16-bit words = 16384 bytes from blob.
    # The blob is shorter (14235-16178); the game reads past the end into
    # stale BSS. We pad with zeros (game's tail is undefined).
    up = blob + b'\x00' * (RECT_W * RECT_H * 2 - len(blob))
    return blob, up[:RECT_W*RECT_H*2]

def main():
    _KIT
    files = sorted(glob.glob(kit + '/extracted/bin_overlays/DATA/12_IKKI/DATA/IC_*.BIN'))
    print('IC files:', len(files))
    for f in files:
        blob, up = load_ic(f)
        print('%-12s blob=%5d upload=%5d' % (os.path.basename(f)[:12], len(blob), len(up)))
    print()
    print('NOTE: upload buffer is the raw VRAM content. No viewable decode found.')

if __name__ == '__main__':
    main()
