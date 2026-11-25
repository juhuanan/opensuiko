#!/usr/bin/env python3
"""
Suikoden .8 -> OBJ converter (Stage 2)

Converts decoded .8 records to Wavefront OBJ format.
Assumes first 6 accumulated nibble values are (x0,y0,x1,y1,x2,y2) for triangles.

Usage: python3 rip_8_stage2.py <input.json> -o <output.obj>
"""

import json
import argparse

def convert_to_obj(records, output_path):
    vertices = []
    faces = []
    vert_idx = 1
    
    for rec in records:
        tag = rec['tag_int']
        acc = rec['decoded']['accumulated']
        
        # POLY_FT3 (0x24-0x27): flat textured triangle
        # POLY_GT3 (0x34-0x37): gouraud textured triangle
        # For now, treat all 0x2x as triangles using first 6 values
        low_byte = tag & 0xFF
        
        if 0x20 <= low_byte <= 0x3F:  # Polygon
            if len(acc) >= 6:
                # Assume (x0,y0,x1,y1,x2,y2)
                x0, y0, x1, y1, x2, y2 = acc[0:6]
                # PS1 Y is top-down, OBJ Y is bottom-up; negate Y
                # Scale up (values are small deltas, need base)
                vertices.append((x0, -y0, 0))
                vertices.append((x1, -y1, 0))
                vertices.append((x2, -y2, 0))
                faces.append((vert_idx, vert_idx+1, vert_idx+2))
                vert_idx += 3
    
    with open(output_path, 'w') as f:
        f.write("# Suikoden .8 rip - DJ2.8\n")
        f.write(f"# {len(vertices)} vertices, {len(faces)} faces\n\n")
        for x, y, z in vertices:
            f.write(f"v {x} {y} {z}\n")
        f.write("\n")
        for a, b, c in faces:
            f.write(f"f {a} {b} {c}\n")
    
    print(f"Wrote {output_path}: {len(vertices)} verts, {len(faces)} faces")

def main():
    parser = argparse.ArgumentParser(description='.8 -> OBJ converter')
    parser.add_argument('input', help='Input JSON from stage1')
    parser.add_argument('-o', '--output', required=True, help='Output OBJ file')
    args = parser.parse_args()
    
    with open(args.input) as f:
        records = json.load(f)
    
    convert_to_obj(records, args.output)

if __name__ == '__main__':
    main()
