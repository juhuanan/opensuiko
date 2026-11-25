#!/usr/bin/env python3
"""
Suikoden .8 -> OBJ converter (Stage 2, chained)

Chained delta decoding across records. Hypothesized layout for POLY_FT3:
- Nibbles 0-5: X0,Y0,X1,Y1,X2,Y2 (deltas, accumulate to absolute)
- Nibbles 6-11: U0,V0,U1,V1,U2,V2 (deltas)
- Rest: color/misc

Usage: python3 rip_8_stage2_chained.py <file.8> -o <output.obj>
"""

import struct
import argparse

def decode_chained(path, target_tags=None):
    """Decode .8 with chained accumulation."""
    with open(path, 'rb') as f:
        data = f.read()
    
    # Per-tag accumulators (different primitive types have separate chains?)
    # For now, use a single global accumulator
    accumulator = 0
    triangles = []
    
    for i in range(0, len(data), 16):
        rec = data[i:i+16]
        if len(rec) < 16:
            break
        tag = struct.unpack('<H', rec[0:2])[0]
        payload = rec[2:16]
        
        if payload == b'\x00' * 14:
            continue
            
        if target_tags and tag not in target_tags:
            continue
        
        # Decode nibbles
        nibbles = []
        for b in payload:
            nibbles.append((b >> 4) & 0xF)
            nibbles.append(b & 0xF)
        signed = [n if n < 8 else n - 16 for n in nibbles]
        
        # Chain accumulate
        chained = []
        total = accumulator
        for s in signed:
            total += s
            chained.append(total)
        accumulator = chained[-1]  # Carry forward
        
        # Extract triangle (hypothesized layout)
        low = tag & 0xFF
        if 0x20 <= low <= 0x3F:  # Polygon
            if len(chained) >= 12:
                # First 6: X/Y, next 6: U/V
                x0, y0, x1, y1, x2, y2 = chained[0:6]
                # u0, v0, u1, v1, u2, v2 = chained[6:12]  # For future UV mapping
                triangles.append(((x0, y0), (x1, y1), (x2, y2)))
    
    return triangles

def write_obj(triangles, path):
    with open(path, 'w') as f:
        f.write("# Suikoden .8 rip (chained)\n")
        f.write(f"# {len(triangles)} triangles\n\n")
        idx = 1
        for (x0, y0), (x1, y1), (x2, y2) in triangles:
            # PS1 Y is top-down; negate for OBJ
            f.write(f"v {x0} {-y0} 0\n")
            f.write(f"v {x1} {-y1} 0\n")
            f.write(f"v {x2} {-y2} 0\n")
        f.write("\n")
        idx = 1
        for _ in triangles:
            f.write(f"f {idx} {idx+1} {idx+2}\n")
            idx += 3
    print(f"Wrote {path}: {len(triangles)} triangles")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('input', help='Input .8 file')
    parser.add_argument('-o', '--output', required=True)
    args = parser.parse_args()
    
    # Focus on POLY_FT3 variants (0x224-0x227)
    tags = {0x224, 0x225, 0x226, 0x227}
    tris = decode_chained(args.input, tags)
    write_obj(tris, args.output)

if __name__ == '__main__':
    main()
