#!/usr/bin/env python3
"""Convert PCSX-Redux raw screenshots to PNG.
Reads <tag>.raw + <tag>.meta (width/height/bpp) from a shots dir.
Usage: shots2png.py <shots_dir> [out_dir]
"""
import os, struct, sys

try:
    from PIL import Image
except ImportError:
    sys.exit("PIL required")

def convert(raw_path, meta_path, out_path):
    meta = {}
    with open(meta_path) as f:
        for token in f.read().split():
            if '=' in token:
                k, v = token.split('=', 1)
                meta[k.strip()] = v.strip()
    w, h = int(meta['width']), int(meta['height'])
    bpp = meta.get('bpp', '')
    data = open(raw_path, 'rb').read()
    img = Image.new('RGB', (w, h))
    px = img.load()
    if bpp in ('0', 'BPP_16') or len(data) == w * h * 2:
        # PSX 15-bit: r=v&31 g=(v>>5)&31 b=(v>>10)&31 (may be BGR-swapped; still legible)
        for y in range(h):
            off = y * w * 2
            for x in range(w):
                v = struct.unpack_from('<H', data, off + x * 2)[0]
                r = (v & 0x1F) * 255 // 31
                g = ((v >> 5) & 0x1F) * 255 // 31
                b = ((v >> 10) & 0x1F) * 255 // 31
                px[x, y] = (r, g, b)
    elif len(data) == w * h * 3:
        i = 0
        for y in range(h):
            for x in range(w):
                px[x, y] = (data[i], data[i+1], data[i+2])
                i += 3
    else:
        sys.exit(f"unknown format for {raw_path}: {len(data)} bytes, {w}x{h} bpp={bpp}")
    img.save(out_path)
    print(f"{out_path} ({w}x{h})")

def main():
    shots = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(shots, 'png')
    os.makedirs(out, exist_ok=True)
    for name in sorted(os.listdir(shots)):
        if name.endswith('.raw'):
            tag = name[:-4]
            meta = os.path.join(shots, tag + '.meta')
            if os.path.exists(meta):
                convert(os.path.join(shots, name), meta, os.path.join(out, tag + '.png'))

main()
