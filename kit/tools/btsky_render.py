#!/usr/bin/env python3
"""
btsky_render.py -- BT/SKY duel-asset decoder (2026-10-01)

Decodes the BT (battle sprite) and SKY (background tile) files from
DATA/12_IKKI/DATA/*.BIN.

PROVEN (bit-exact vs text_decode_stream @0x800C3144):
  Container is [u32 comp_len][LZSS payload]. The LZSS uses **LSB-first** flags
  (1 = control, 0 = literal), a 0x400-byte zero-initialized history window whose
  write index starts at 0x3DE, and absolute (non-delta) 10-bit match offsets.
  Decompression is delegated to kit/tools/lzss.py v2.0.0 through
  kit/tools/text_lzss.py, which was verified bit-exact.

  CORRECTION 2026-10-03 -- this docstring previously claimed **MSB-first**
  flags here. That claim was wrong (it belonged to the separate, unlocated
  face_decompress.py guess). Authority: kit/tools/lzss.py v2.0.0 and
  kit/docs/lzss_consolidation.md.

NOT PROVEN (static analysis negative as of 2026-10-01):
  The pixel format of the decompressed blobs. An exhaustive format sweep
  (8/16-bit, row/col-major, tiled, CLUT variants, RLE second stage) produced
  only noise. The code paths previously believed to consume BT/SKY
  (@0x80131090, @0x801281E0 in MAIN.EXE) were re-disassembled and are NOT
  BT/SKY related:
    - 0x80131090 is entity_table_sweep_true: reads [0x80010000] as a kernel
      struct pointer (cached_kernel_ptr @0x8017C108), then derefs [+0x10].
      It operates on area-file loads, not duel sprites.
    - 0x801281E0 is a per-frame state machine dispatching through the
      function-pointer table @0x8016F37C, not a file loader.
  The duel overlay (PAN_TEO.BIN) loads only IC icons through its vtable
  dispatch (cd_read -> decompress -> LoadImage, 64x128 and 32x64 RECTs);
  BT/SKY entries sit in its 48-entry file table but are never uploaded via
  LoadImage in any of the three duel overlays. The ikki file table lives in
  SLUS_002.92 (@0x8004587C RAM), not MAIN.EXE.

  Because no code-derived pixel struct map was found, this tool does NOT
  emit PNGs. Rendering guessed formats would ship noise, which is worse
  than an honest negative.

Usage:
  python3 btsky_render.py --info            # list files, sizes
  python3 btsky_render.py --dump OUTDIR     # write decompressed blobs
"""

import struct, sys, os, glob, argparse

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(KIT, 'extracted', 'bin_overlays', 'DATA', '12_IKKI', 'DATA')

sys.path.insert(0, os.path.join(KIT, 'tools'))
from text_lzss import decompress as proven_decompress

def decompress_file(path: str) -> bytes:
    with open(path, 'rb') as f:
        blob = f.read()
    comp_len = struct.unpack_from('<I', blob, 0)[0]
    payload = blob[4:4+comp_len]
    return proven_decompress(payload)

def list_files():
    files = sorted(glob.glob(os.path.join(DATA_DIR, '*.BIN')))
    out = []
    for fn in files:
        base = os.path.basename(fn)
        if base.startswith('BT') or base.startswith('SKY'):
            sz = os.path.getsize(fn)
            dec = decompress_file(fn)
            out.append((base, sz, len(dec)))
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--info', action='store_true')
    ap.add_argument('--dump', metavar='OUTDIR')
    args = ap.parse_args()
    if args.info:
        for base, sz, dsz in list_files():
            print('%-14s comp=%6d decomp=%6d' % (base, sz, dsz))
    elif args.dump:
        os.makedirs(args.dump, exist_ok=True)
        for base, sz, dsz in list_files():
            dec = decompress_file(os.path.join(DATA_DIR, base))
            with open(os.path.join(args.dump, base + '.dec'), 'wb') as f:
                f.write(dec)
            print('wrote', base, dsz)
    else:
        ap.print_help()

if __name__ == '__main__':
    main()
