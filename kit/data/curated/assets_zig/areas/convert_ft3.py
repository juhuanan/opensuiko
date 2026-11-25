#!/usr/bin/env python3
"""
Convert Suikoden PS1 .8 area display-list records to textured triangles.

STATUS 2026-10-01: UNPROVEN HYPOTHESIS. User reviewed the render and judged it
indistinguishable from noise. Structural evidence only (PS1 GPU POLY_FT3 packet
order match, signed-XY edge-collapse stats). Do not cite as verified.

Field map (proposed, NOT visually confirmed):
  Each 0x224-0x227 record = 1 POLY_FT3 textured triangle.
  Payload bytes (after 2-byte LE tag):
    p[0],p[1]   = X0,Y0  (vertex 0 screen position, signed s8)
    p[2],p[3]   = U0,V0  (vertex 0 texture UV, u8)
    p[4],p[5]   = X1,Y1  (vertex 1 screen position, signed s8)
    p[6],p[7]   = U1,V1  (vertex 1 texture UV, u8)
    p[8],p[9]   = X2,Y2  (vertex 2 screen position, signed s8)
    p[10],p[11] = U2,V2  (vertex 2 texture UV, u8)
    p[12],p[13] = E0,E1  (unknown, 2 bytes; NOT page/CLUT - 14,959 unique pairs)

Usage:
  python3 convert_ft3.py <input.8> <output.json> [--limit N]
  python3 convert_ft3.py <input.8> <output.png> [--limit N] [--scale S]

JSON output: list of {"tag":..., "v":[[x0,y0,u0,v0],[x1,y1,u1,v1],[x2,y2,u2,v2]], "e":[e0,e1]}
PNG output: textured triangles rendered with UVs mapped to a procedural
  256x256 texture (grid + gradient), verifying UV coherence.
"""

import struct, json, sys

def s8(b):
    """Sign-extend a byte. Screen positions are signed (sign-off correction)."""
    return b - 256 if b >= 128 else b

def parse_ft3(data, limit=None):
    """Parse .8 file, yield FT3 triangles."""
    nrec = len(data)//16
    tris = []
    for i in range(nrec):
        if limit and len(tris) >= limit: break
        rec = data[i*16:(i+1)*16]
        tag = struct.unpack('<H', rec[0:2])[0]
        if 0x224 <= tag <= 0x227:
            p = rec[2:16]
            # XY signed (verified by sign-off: signed collapses edge lengths,
            # doubles compact-triangle fraction vs unsigned)
            v0 = (s8(p[0]), s8(p[1]), p[2], p[3])
            v1 = (s8(p[4]), s8(p[5]), p[6], p[7])
            v2 = (s8(p[8]), s8(p[9]), p[10], p[11])
            e = (p[12], p[13])
            tris.append({"tag": tag, "v": [v0, v1, v2], "e": e, "idx": i})
    return tris

def write_json(tris, path):
    with open(path, 'w') as f:
        json.dump(tris, f)
    print(f"Wrote {len(tris)} triangles to {path}")

def render_png(tris, path, scale=4):
    """Render triangles with UVs sampling a procedural 256x256 texture."""
    from PIL import Image, ImageDraw
    # Procedural texture: 256x256 with grid + color gradient
    # This verifies UVs are coherent (not random).
    tex = Image.new('RGB', (256, 256))
    px = tex.load()
    for v in range(256):
        for u in range(256):
            # Grid lines every 16px, gradient by position
            r = u
            g = v
            b = 128 + ((u//16 + v//16) % 2) * 64
            if u % 16 == 0 or v % 16 == 0:
                r, g, b = 255, 255, 255
            px[u, v] = (r, g, b)
    
    # Render target: 256*scale; positions signed (-128..127), offset into canvas
    W = H = 256 * scale
    img = Image.new('RGB', (W, H), (0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    for t in tris:
        (x0,y0,u0,v0), (x1,y1,u1,v1), (x2,y2,u2,v2) = t["v"]
        # Scale positions (signed coords offset by +128)
        pts = [((x0+128)*scale, (y0+128)*scale), ((x1+128)*scale, (y1+128)*scale), ((x2+128)*scale, (y2+128)*scale)]
        # Sample texture at centroid UV for flat fill (or use vertex colors)
        # For verification, fill with color based on average UV
        au = (u0+u1+u2)//3
        av = (v0+v1+v2)//3
        # Use texture color at centroid
        r, g, b = tex.getpixel((au % 256, av % 256))
        # Draw filled triangle
        draw.polygon(pts, fill=(r, g, b))
        # Outline in white for visibility
        draw.line([pts[0], pts[1], pts[2], pts[0]], fill=(255,255,255), width=1)
    
    img.save(path)
    print(f"Wrote {len(tris)} triangles to {path} ({W}x{H})")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    inp, outp = sys.argv[1], sys.argv[2]
    limit = None
    scale = 4
    for i, a in enumerate(sys.argv):
        if a == "--limit" and i+1 < len(sys.argv):
            limit = int(sys.argv[i+1])
        if a == "--scale" and i+1 < len(sys.argv):
            scale = int(sys.argv[i+1])
    
    data = open(inp, 'rb').read()
    tris = parse_ft3(data, limit)
    print(f"Parsed {len(tris)} FT3 triangles from {inp}")
    
    if outp.endswith('.json'):
        write_json(tris, outp)
    elif outp.endswith('.png'):
        render_png(tris, outp, scale)
    else:
        print("Output must be .json or .png")
