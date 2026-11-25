#!/usr/bin/env python3
"""Render all map rooms from 01_AREA.A BIN files.

Pipeline (proven on VB5.BIN and VA1.BIN):
1. First word -> area struct S. S+8=table1, S+4=table2.
2. For each table2[i] -> area header. Skip if w/h invalid or tilemap null.
3. Header+0x08 -> blob/palette table. Entries 0-5 = blob ptrs, 12-20 = palette ptrs.
4. Blobs: [u32 comp_len][LZSS] -> 16384 bytes (128x128 8-bit).
5. Index mapping: blob=index//64, subtile=index%64. 16x16 subtiles, 8x8 grid, row-major.
6. Palette: try all 9 candidates, pick lowest-saturation (most natural).

Usage: render_01a.py <bin_path> <out_dir>
Outputs: {basename}_h{i}.png and {basename}_h{i}_2x.png per valid header.
"""

import struct
import sys
import os
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from lzss import decode_container, LZSSError
from psx_vram import rgb555_to_rgb888

BASE = 0x80010000

def to_off(ram_ptr):
    return ram_ptr - BASE

def load_palette(data, off):
    """Load 256-entry RGB555 palette at file offset."""
    pal = []
    for i in range(256):
        c = struct.unpack_from('<H', data, off + i*2)[0]
        pal.append(rgb555_to_rgb888(c))
    return pal

def extract_subtile(blob, subtile_idx):
    """Extract 16x16 subtile from 128x128 8-bit blob. 8x8 grid, row-major."""
    sx = (subtile_idx % 8) * 16
    sy = (subtile_idx // 8) * 16
    out = bytearray(256)
    for y in range(16):
        for x in range(16):
            out[y*16 + x] = blob[(sy + y) * 128 + (sx + x)]
    return bytes(out)

def render_tilemap(tiles, w, h, blobs, palette):
    """Render tilemap to PIL Image."""
    img = Image.new('RGB', (w * 16, h * 16))
    px = img.load()
    for ty in range(h):
        for tx in range(w):
            idx = tiles[ty * w + tx]
            blob_idx = idx // 64
            sub_idx = idx % 64
            if blob_idx >= len(blobs):
                # Out of range: magenta (visible error)
                for y in range(16):
                    for x in range(16):
                        px[tx*16+x, ty*16+y] = (255, 0, 255)
                continue
            sub = extract_subtile(blobs[blob_idx], sub_idx)
            for y in range(16):
                for x in range(16):
                    pi = sub[y*16 + x]
                    px[tx*16+x, ty*16+y] = palette[pi]
    return img

def saturation_score(img):
    """Lower = more natural (less neon). Compute avg saturation of non-black pixels."""
    import colorsys
    total_s = 0.0
    count = 0
    for r, g, b in img.getdata():
        if r < 16 and g < 16 and b < 16:
            continue
        h_, s, v = colorsys.rgb_to_hsv(r/255, g/255, b/255)
        if v < 0.1:
            continue
        total_s += s
        count += 1
    return total_s / count if count > 0 else 1.0

def palette_score(img):
    """Higher = more natural. Rewards white highlights (marble/lights) with moderate saturation.
    Wrong palettes are either neon (high sat) or flat (no whites)."""
    sat = saturation_score(img)
    white = sum(1 for r, g, b in img.getdata() if r > 240 and g > 240 and b > 240)
    # White pixels indicate proper highlights; penalize extreme saturation
    return white / (1.0 + sat * 10.0)

def process_bin(bin_path, out_dir):
    basename = os.path.splitext(os.path.basename(bin_path))[0]
    print(f"\n=== {basename} ===")
    
    with open(bin_path, 'rb') as f:
        data = f.read()
    
    # Pointer chain: word0 -> S
    S_ram = struct.unpack_from('<I', data, 0)[0]
    if not (BASE <= S_ram < BASE + len(data)):
        print(f"  Invalid S pointer: {S_ram:#x}")
        return []
    S = to_off(S_ram)
    
    # S+4 = table2
    t2_ram = struct.unpack_from('<I', data, S+4)[0]
    if not (BASE <= t2_ram < BASE + len(data)):
        print(f"  Invalid table2 pointer: {t2_ram:#x}")
        return []
    t2 = to_off(t2_ram)
    
    results = []
    # Enumerate table2 entries (24 max, per VA1.BIN structure)
    for i in range(24):
        hdr_ram = struct.unpack_from('<I', data, t2 + i*4)[0]
        if hdr_ram == 0:
            continue
        if not (BASE <= hdr_ram < BASE + len(data)):
            continue
        hdr = to_off(hdr_ram)
        
        w, h = struct.unpack_from('<HH', data, hdr)
        if w == 0 or h == 0 or w > 200 or h > 200:
            continue
        
        tm_ram = struct.unpack_from('<I', data, hdr + 0x14)[0]
        if tm_ram == 0:
            continue
        tm = to_off(tm_ram)
        if tm + w*h*2 > len(data):
            continue
        
        # Get blob/palette table from header+0x08
        tab_ram = struct.unpack_from('<I', data, hdr + 0x08)[0]
        if not (BASE <= tab_ram < BASE + len(data)):
            print(f"  h{i}: {w}x{h} - no valid table ptr")
            continue
        tab = to_off(tab_ram)
        
        # Decompress blobs (entries 0-5, try up to 12).
        # A blob that fails the consumption/size gate is REPORTED, never silently
        # skipped -- a bare `except: break` here used to hide decode failures.
        blobs = []
        for bi in range(12):
            bptr = struct.unpack_from('<I', data, tab + bi*4)[0]
            if not (BASE <= bptr < BASE + len(data)):
                break
            boff = to_off(bptr)
            if boff + 4 > len(data):
                break
            (comp_len,) = struct.unpack_from('<I', data, boff)
            try:
                out, used = decode_container(data, boff)
            except LZSSError as ex:
                print(f"    blob[{bi}] @{boff:#x}: {type(ex).__name__}: {ex}")
                break
            if used != 4 + comp_len:
                print(f"    blob[{bi}] @{boff:#x}: PARTIAL DECODE - consumed "
                      f"{used} bytes, comp_len says {4 + comp_len}")
                break
            if len(out) != 16384:
                print(f"    blob[{bi}] @{boff:#x}: {len(out)} bytes, want 16384")
                break
            blobs.append(out)
        
        if not blobs:
            print(f"  h{i}: {w}x{h} - no blobs decoded")
            continue
        
        # Read tilemap
        tiles = struct.unpack_from(f'<{w*h}H', data, tm)
        max_blob_needed = max(tiles) // 64 if tiles else 0
        if max_blob_needed >= len(blobs):
            print(f"  h{i}: {w}x{h} - need blob {max_blob_needed}, have {len(blobs)}")
            continue
        
        # Try palette candidates (entries 12-20), pick highest naturalness score
        best_img = None
        best_score = -1
        best_pal_idx = -1
        for pi in range(12, 21):
            pptr = struct.unpack_from('<I', data, tab + pi*4)[0]
            if not (BASE <= pptr < BASE + len(data)):
                continue
            poff = to_off(pptr)
            if poff + 512 > len(data):
                continue
            palette = load_palette(data, poff)
            img = render_tilemap(tiles, w, h, blobs, palette)
            score = palette_score(img)
            if score > best_score:
                best_score = score
                best_img = img
                best_pal_idx = pi
        
        if best_img is None:
            print(f"  h{i}: {w}x{h} - no palette worked")
            continue
        
        # Save
        out1x = os.path.join(out_dir, f"{basename}_h{i}.png")
        out2x = os.path.join(out_dir, f"{basename}_h{i}_2x.png")
        best_img.save(out1x)
        w2, h2 = best_img.size
        best_img.resize((w2*2, h2*2), Image.NEAREST).save(out2x)
        
        print(f"  h{i}: {w}x{h} blobs={len(blobs)} pal_entry={best_pal_idx} score={best_score:.1f} -> {os.path.basename(out1x)}")
        results.append((i, w, h, best_pal_idx, out1x))
    
    return results

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <bin_path> <out_dir>")
        sys.exit(1)
    os.makedirs(sys.argv[2], exist_ok=True)
    results = process_bin(sys.argv[1], sys.argv[2])
    print(f"\nDone: {len(results)} rooms rendered")
