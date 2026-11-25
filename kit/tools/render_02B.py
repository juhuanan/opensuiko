#!/usr/bin/env python3
"""render_02B.py -- Render all map rooms from 02_AREA.B main VB files.

Pipeline (proven on VB5.BIN):
1. First word -> area struct S. S+8=table1, S+4=table2. Iterate table2[i] -> header.
2. Header: width=u16@[0], height=u16@[2], tilemap=u32@[+0x14], pal_table=u32@[+0x0c].
3. Blobs: scan for [u32 comp_len][LZSS->16384B].
4. Index: blob=index//64, subtile=index%64. 16x16 subtiles, 8x8 per 128x128 blob.
5. Palette: from header's palette table. VB5 uses two-palette mapping.
"""

import struct
import sys
import os
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lzss import decode_container, LZSSError
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


_KIT
DATA_DIR = os.path.join(BASE, "extracted/bin_overlays/DATA/02_AREA.B")
OUT_DIR = os.path.join(BASE, "work/area_tiles/02B")
LOAD_BASE = 0x80010000

FILES = ["VB1", "VB2", "VB3", "VB4", "VB5", "VB6", "VB7", "VB7A", "VB7D", "VB8", "VB9"]

def ram_to_file(ptr, filesize):
    off = ptr - LOAD_BASE
    if 0 <= off < filesize:
        return off
    return None

def find_blobs(data):
    """Scan for [u32 comp_len][LZSS->16384B] at 4-byte alignment.

    This is a CANDIDATE SCAN over every 4-byte offset, so a non-decodable offset
    is expected and is not an error. Nothing else is swallowed: only genuine
    stream failures (LZSSError) are skipped, and only full-consumption decodes
    are accepted as blobs.
    """
    blobs = []
    n = len(data)
    for off in range(0, n - 4, 4):
        comp_len = struct.unpack_from('<I', data, off)[0]
        # Pre-filter: comp_len must be sane for 16384-byte LZSS output
        # (observed 9000-15000 in VB5; allow 500-16384)
        if comp_len < 500 or comp_len > 16384:
            continue
        if off + 4 + comp_len > n:
            continue
        try:
            out, consumed = decode_container(data, off)
        except LZSSError:
            # not a valid stream at this candidate offset -- expected
            continue
        if consumed != 4 + comp_len:
            continue  # partial decode: not a real container
        if len(out) == 16384:
            blobs.append((off, comp_len))
    return blobs

def get_headers(data):
    """Enumerate area headers via S -> table2."""
    n = len(data)
    if n < 4:
        return []
    s_ptr = struct.unpack_from('<I', data, 0)[0]
    s_off = ram_to_file(s_ptr, n)
    if s_off is None or s_off + 12 > n:
        return []
    table1_ptr = struct.unpack_from('<I', data, s_off + 8)[0]
    table2_ptr = struct.unpack_from('<I', data, s_off + 4)[0]
    table2_off = ram_to_file(table2_ptr, n)
    if table2_off is None:
        return []
    
    headers = []
    for i in range(64):
        if table2_off + i*4 + 4 > n:
            break
        h_ptr = struct.unpack_from('<I', data, table2_off + i*4)[0]
        if h_ptr == 0:
            continue
        h_off = ram_to_file(h_ptr, n)
        if h_off is None or h_off + 0x40 > n:
            continue
        width = struct.unpack_from('<H', data, h_off)[0]
        height = struct.unpack_from('<H', data, h_off + 2)[0]
        if width == 0 or height == 0 or width > 200 or height > 200:
            continue
        tm_ptr = struct.unpack_from('<I', data, h_off + 0x14)[0]
        tm_off = ram_to_file(tm_ptr, n)
        if tm_off is None or tm_off + width*height*2 > n:
            continue
        # Palette table via header+0x0c
        pal_tbl_ptr = struct.unpack_from('<I', data, h_off + 0x0c)[0]
        pal_tbl_off = ram_to_file(pal_tbl_ptr, n)
        palettes = []
        if pal_tbl_off is not None:
            for j in range(16):
                if pal_tbl_off + j*4 + 4 > n:
                    break
                p_ptr = struct.unpack_from('<I', data, pal_tbl_off + j*4)[0]
                if p_ptr == 0:
                    break
                p_off = ram_to_file(p_ptr, n)
                if p_off is None or p_off + 512 > n:
                    break
                # Validate: entry0 should be 0x0000
                if struct.unpack_from('<H', data, p_off)[0] != 0:
                    break
                palettes.append(p_off)
        headers.append({
            'index': i,
            'offset': h_off,
            'width': width,
            'height': height,
            'tilemap_off': tm_off,
            'palettes': palettes,
        })
    return headers

def load_palette(data, pal_off):
    pal = []
    for i in range(256):
        c = struct.unpack_from('<H', data, pal_off + i*2)[0]
        pal.append(rgb555_to_rgb888(c))
    return pal

def render_room(data, header, blobs, pal0_off, pal1_off=None, is_vb5=False):
    W = header['width']
    H = header['height']
    tm_off = header['tilemap_off']
    
    # Load palettes
    pal0 = load_palette(data, pal0_off)
    pal1 = load_palette(data, pal1_off) if pal1_off else None
    
    # Decode blobs to 128x128 images (as 2D arrays of palette indices).
    # A blob that fails the consumption/size gate is recorded as missing (the
    # room renders magenta there) and REPORTED -- never silently blanked.
    blob_imgs = []
    bad_blobs = []
    for b_off, b_len in blobs:
        try:
            out, used = decode_container(data, b_off)
        except LZSSError as ex:
            bad_blobs.append((b_off, '%s: %s' % (type(ex).__name__, ex)))
            blob_imgs.append(None)
            continue
        if used != 4 + b_len:
            bad_blobs.append((b_off, 'partial decode: consumed %d, comp_len %d'
                              % (used, 4 + b_len)))
            blob_imgs.append(None)
            continue
        if len(out) != 16384:
            bad_blobs.append((b_off, 'decoded %d bytes, want 16384' % len(out)))
            blob_imgs.append(None)
            continue
        # 128x128, row-major
        blob_imgs.append([out[r*128:(r+1)*128] for r in range(128)])
    for b_off, why in bad_blobs:
        print(f"    blob @{b_off:#x}: {why}")
    
    # Render tilemap
    out_img = Image.new('RGB', (W*16, H*16))
    px = out_img.load()
    
    for ty in range(H):
        for tx in range(W):
            idx = struct.unpack_from('<H', data, tm_off + (ty*W + tx)*2)[0]
            blob = idx // 64
            subtile = idx % 64
            
            # VB5 two-palette mapping
            if is_vb5 and pal1:
                if blob == 3 or (blob == 2 and subtile >= 38):
                    pal = pal1
                else:
                    pal = pal0
            else:
                pal = pal0
            
            if blob >= len(blob_imgs) or blob_imgs[blob] is None:
                # Fill with magenta for missing blob
                for y in range(16):
                    for x in range(16):
                        px[tx*16+x, ty*16+y] = (255, 0, 255)
                continue
            
            bimg = blob_imgs[blob]
            # Subtile: 8x8 grid, each 16x16, row-major
            sx = (subtile % 8) * 16
            sy = (subtile // 8) * 16
            
            for y in range(16):
                for x in range(16):
                    pi = bimg[sy+y][sx+x]
                    px[tx*16+x, ty*16+y] = pal[pi]
    
    return out_img

def process_file(basename):
    path = os.path.join(DATA_DIR, basename + ".BIN")
    if not os.path.exists(path):
        print(f"  {basename}: NOT FOUND")
        return 0
    
    with open(path, 'rb') as f:
        data = f.read()
    
    print(f"  {basename}: {len(data):#x} bytes")
    
    headers = get_headers(data)
    print(f"    Found {len(headers)} valid headers")
    
    if not headers:
        return 0
    
    # Find blobs (cache per file)
    print(f"    Scanning for blobs...")
    blobs = find_blobs(data)
    print(f"    Found {len(blobs)} blobs")
    
    if not blobs:
        print(f"    WARNING: no blobs found, skipping")
        return 0
    
    is_vb5 = (basename == "VB5")
    
    count = 0
    for h in headers:
        i = h['index']
        palettes = h['palettes']
        if not palettes:
            print(f"    h{i} ({h['width']}x{h['height']}): no palettes, skipping")
            continue
        
        pal0_off = palettes[0]
        pal1_off = palettes[1] if len(palettes) > 1 else None
        
        # For VB5, use known palette offsets
        if is_vb5:
            pal0_off = 0x2514
            pal1_off = 0x2714
        
        try:
            img = render_room(data, h, blobs, pal0_off, pal1_off, is_vb5)
            out1x = os.path.join(OUT_DIR, f"{basename}_h{i}.png")
            out2x = os.path.join(OUT_DIR, f"{basename}_h{i}_2x.png")
            img.save(out1x)
            w, hh = img.size
            img.resize((w*2, hh*2), Image.NEAREST).save(out2x)
            print(f"    h{i} ({h['width']}x{h['height']}): saved")
            count += 1
        except Exception as e:
            print(f"    h{i}: ERROR {e}")
    
    return count

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    total = 0
    for basename in FILES:
        print(f"Processing {basename}...")
        total += process_file(basename)
    print(f"\nDone. Rendered {total} rooms.")

if __name__ == "__main__":
    main()
