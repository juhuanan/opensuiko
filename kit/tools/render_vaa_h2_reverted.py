#!/usr/bin/env python3
"""Render VAA.BIN header 2 (throne room) with reverted wall palette.

Palette mapping (all disc-derived):
- Floor (most indices): pal4 @0x86c (peach, correct)
- Carpet (idx 263): @0x52e00 (crimson red, correct)
- Walls (indices 8,18,19,194,204,257-262): @0xc6c (REVERTED to original batch palette)

Output: work/area_tiles/01A/VAA_h2_walls_reverted.png (+_2x)
"""

import struct
import os
import sys
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from lzss import decode_container
from psx_vram import rgb555_to_rgb888

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)

# Back-compat alias: this tool used to define this from a hardcoded path.
BASE = _KIT


def _kit(*parts):
    return os.path.join(_KIT, *parts)


def _root(*parts):
    return os.path.join(_ROOT, *parts)


BASE = 0x80010000
BIN_PATH = _kit('extracted', 'bin_overlays', 'DATA', '01_AREA.A', 'VAA.BIN')
OUT_DIR = os.path.join(_KIT, "work/area_tiles/01A")

# Palette file offsets (verified disc-derived)
PAL_FLOOR = 0x86c      # header+0x0c table entry 4
PAL_WALLS = 0xc6c      # header+0x0c table entry 6 (original batch palette)
PAL_CARPET = 0x52e00   # separate crimson palette

# Per-index palette overrides
CARPET_IDX = 263
WALL_IDXS = {8, 18, 19, 194, 204, 257, 258, 259, 260, 261, 262}


def to_off(ram_ptr):
    return ram_ptr - BASE


def load_palette(data, off):
    pal = []
    for i in range(256):
        c = struct.unpack_from('<H', data, off + i * 2)[0]
        pal.append(rgb555_to_rgb888(c))
    return pal


def extract_subtile(blob, subtile_idx):
    """Extract 16x16 subtile from 128x128 8-bit blob. 8x8 grid, row-major."""
    sx = (subtile_idx % 8) * 16
    sy = (subtile_idx // 8) * 16
    out = bytearray(256)
    for y in range(16):
        for x in range(16):
            out[y * 16 + x] = blob[(sy + y) * 128 + (sx + x)]
    return bytes(out)


def main():
    with open(BIN_PATH, 'rb') as f:
        data = f.read()

    # Pointer chain: word0 -> S, S+4 = table2, table2[2] -> header 2
    S = to_off(struct.unpack_from('<I', data, 0)[0])
    t2 = to_off(struct.unpack_from('<I', data, S + 4)[0])
    hdr = to_off(struct.unpack_from('<I', data, t2 + 2 * 4)[0])
    print(f"Header 2 @ file {hdr:#x}")

    w, h = struct.unpack_from('<HH', data, hdr)
    print(f"Dims: {w}x{h}")
    assert (w, h) == (40, 56), f"Unexpected dims {w}x{h}"

    # Tilemap
    tm = to_off(struct.unpack_from('<I', data, hdr + 0x14)[0])
    tiles = struct.unpack_from(f'<{w*h}H', data, tm)
    print(f"Tilemap @ file {tm:#x}, {len(tiles)} tiles")

    # Blobs from header+0x08 table (entries 0-6)
    btab = to_off(struct.unpack_from('<I', data, hdr + 0x08)[0])
    blobs = []
    for bi in range(7):
        bptr = struct.unpack_from('<I', data, btab + bi * 4)[0]
        boff = to_off(bptr)
        # Blobs are PACKED back to back inside a larger overlay, so a blob is the
        # [u32 comp_len][payload] unit -- not "the rest of the file". That is
        # exactly why `used` must be checked: the comp_len field is the only
        # thing separating this stream from the next one.
        (comp_len,) = struct.unpack_from('<I', data, boff)
        out, used = decode_container(data, boff)
        if used != 4 + comp_len:
            raise SystemExit(
                f"Blob {bi} @{boff:#x}: PARTIAL DECODE - consumed {used} bytes, "
                f"comp_len says {4 + comp_len}")
        if len(out) != 16384:
            raise SystemExit(
                f"Blob {bi} @{boff:#x}: decoded {len(out)} bytes, want 16384")
        blobs.append(out)
    print(f"Decoded {len(blobs)} blobs")

    # Verify max index fits
    max_idx = max(tiles)
    print(f"Max tile index: {max_idx} -> blob {max_idx // 64}")
    assert max_idx // 64 < len(blobs), "Index out of blob range"

    # Load palettes
    pal_floor = load_palette(data, PAL_FLOOR)
    pal_walls = load_palette(data, PAL_WALLS)
    pal_carpet = load_palette(data, PAL_CARPET)
    print(f"Palettes loaded: floor@{PAL_FLOOR:#x} walls@{PAL_WALLS:#x} carpet@{PAL_CARPET:#x}")

    # Count per-category tiles
    n_carpet = sum(1 for t in tiles if t == CARPET_IDX)
    n_walls = sum(1 for t in tiles if t in WALL_IDXS)
    n_floor = len(tiles) - n_carpet - n_walls
    print(f"Tiles: floor={n_floor} carpet={n_carpet} walls={n_walls}")

    # Render with per-index palette selection
    img = Image.new('RGB', (w * 16, h * 16))
    px = img.load()
    for ty in range(h):
        for tx in range(w):
            idx = tiles[ty * w + tx]
            if idx == CARPET_IDX:
                pal = pal_carpet
            elif idx in WALL_IDXS:
                pal = pal_walls
            else:
                pal = pal_floor
            blob_idx = idx // 64
            sub_idx = idx % 64
            sub = extract_subtile(blobs[blob_idx], sub_idx)
            for y in range(16):
                for x in range(16):
                    pi = sub[y * 16 + x]
                    px[tx * 16 + x, ty * 16 + y] = pal[pi]

    # Save
    os.makedirs(OUT_DIR, exist_ok=True)
    out1x = os.path.join(OUT_DIR, 'VAA_h2_walls_reverted.png')
    out2x = os.path.join(OUT_DIR, 'VAA_h2_walls_reverted_2x.png')
    img.save(out1x)
    w2, h2 = img.size
    img.resize((w2 * 2, h2 * 2), Image.NEAREST).save(out2x)
    print(f"Saved: {out1x} ({w2}x{h2})")
    print(f"Saved: {out2x} ({w2*2}x{h2*2})")


if __name__ == '__main__':
    main()
