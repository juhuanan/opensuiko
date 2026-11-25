#!/usr/bin/env python3
"""
nibble_delta_decode.py — Delta decoder for .8 area record nibble payloads.

STATUS: EXPERIMENTAL / UNVERIFIED
The "0x239 yields smooth 1->64 ramp" claim from docs/container_8.md could NOT
be reproduced. Accumulating 0x0225-0x0228 nibbles as signed deltas produces
small diagonal paths (X in -61..55, Y in -51..53), not plausible 2D map
coordinates. The @0x80137400 "nibble unpacker" label is misleading — it's
position lookup math (srl by 4 = divide by 16), not nibble extraction.

This tool implements the best-effort delta accumulation for further testing.
Do NOT treat its output as verified decoded coordinates.

Usage:
    python3 tools/nibble_delta_decode.py work/DJ2.8 --tag 0x225 --plot
    python3 tools/nibble_delta_decode.py work/DJ2.8 --tag 0x239 --dump
"""

import struct
import argparse
import sys

def get_nibbles(payload):
    """Unpack 14 bytes to 28 nibbles, high-first."""
    nibs = []
    for b in payload:
        nibs.append((b >> 4) & 0xF)
        nibs.append(b & 0xF)
    return nibs

def signed4(n):
    """Signed 4-bit: 0-7 positive, 8-15 -> -8..-1."""
    return n - 16 if n > 7 else n

def decode_deltas(nibbles, start=(0, 0)):
    """
    Accumulate nibbles as (dx,dy) signed delta pairs.
    Returns list of (x,y) points.
    UNVERIFIED: produces diagonal paths, not confirmed as coordinates.
    """
    x, y = start
    pts = []
    for j in range(0, len(nibbles) - 1, 2):
        x += signed4(nibbles[j])
        y += signed4(nibbles[j+1])
        pts.append((x, y))
    return pts

def decode_unsigned_ramp(nibbles):
    """
    Accumulate nibbles as unsigned values.
    This IS monotonic but does not match the claimed 1->64 ramp.
    """
    acc = 0
    curve = []
    for n in nibbles:
        acc += n
        curve.append(acc)
    return curve

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file', help='.8 file path')
    ap.add_argument('--tag', required=True, help='Tag hex, e.g. 0x225')
    ap.add_argument('--dump', action='store_true', help='Dump first 3 records')
    ap.add_argument('--plot', action='store_true', help='Save ramp plot')
    ap.add_argument('--count', type=int, default=5, help='Records to process')
    args = ap.parse_args()

    tag = int(args.tag, 16)
    with open(args.file, 'rb') as f:
        data = f.read()

    recs = []
    for i in range(len(data) // 16):
        rec = data[i*16:(i+1)*16]
        if struct.unpack('<H', rec[0:2])[0] == tag:
            recs.append((i, rec[2:]))
    print(f"Found {len(recs)} records with tag 0x{tag:03x}", file=sys.stderr)

    if args.dump:
        for i, payload in recs[:args.count]:
            nibs = get_nibbles(payload)
            pts = decode_deltas(nibs)
            ramp = decode_unsigned_ramp(nibs)
            print(f"Rec {i}:")
            print(f"  nibbles: {nibs}")
            print(f"  delta pts (first 5): {pts[:5]}")
            print(f"  unsigned ramp: {ramp[0]} -> {ramp[-1]}")

    if args.plot:
        try:
            import matplotlib
            matplotlib.use('Agg')
            import matplotlib.pyplot as plt
        except ImportError:
            print("matplotlib not available", file=sys.stderr)
            return
        fig, axes = plt.subplots(1, 2, figsize=(12, 5))
        for i, payload in recs[:10]:
            nibs = get_nibbles(payload)
            pts = decode_deltas(nibs)
            xs = [p[0] for p in pts]
            ys = [p[1] for p in pts]
            axes[0].plot(xs, ys, 'o-', alpha=0.5, markersize=3)
            ramp = decode_unsigned_ramp(nibs)
            axes[1].plot(ramp, alpha=0.5)
        axes[0].set_title(f'Tag 0x{tag:03x}: delta paths (UNVERIFIED)')
        axes[0].set_xlabel('X'); axes[0].set_ylabel('Y')
        axes[0].grid(True); axes[0].axhline(0, color='k', lw=0.5); axes[0].axvline(0, color='k', lw=0.5)
        axes[1].set_title(f'Tag 0x{tag:03x}: unsigned accumulation')
        axes[1].set_xlabel('Nibble index'); axes[1].set_ylabel('Accumulated')
        axes[1].grid(True)
        out = f'work/area_tiles/dj2_nibble_ramp_0x{tag:03x}.png'
        fig.savefig(out, dpi=100)
        print(f"Saved {out}")

if __name__ == '__main__':
    main()
