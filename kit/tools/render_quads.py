#!/usr/bin/env python3
"""

> **CORRECTION 2026-10-05 — `.8` FILES ARE XA AUDIO.**
> They are MODE2 **Form 2** sectors (2324-byte user field); `disc.extract()`
> returns the Form 1 (2048-byte) field, so every "record" this file reads is a
> 276-bytes-per-sector alignment artifact, and the payload/nibble layout asserted
> below describes that misread stream. Every sampled sector of all 67 `.8` files
> carries XA submode `0x08` = audio. Kept as the error record; its renders are not
> art. See `kit/docs/dot8_is_xa_audio.md`.
render_quads.py — Render textured-primitive records from Suikoden PS1 .8 area files.

Each .8 file is an array of 16-byte records: u16-LE tag + 14 payload bytes.
Drawable tags use the PS1 GPU primitive command in the low byte:
  0x224-0x227  POLY_FT3  textured triangle
  0x228-0x22B  POLY_F4   flat quad (partially mapped)
  0x234-0x237  POLY_GT3  gouraud textured triangle (unmapped)
  0x244-0x248  LINE_F2/F3 (unmapped)

FT3 payload layout (14 bytes), in PS1 GPU packet order
(interleaved X,Y / U,V, mirroring the hardware POLY_FT3 packet):
  byte  0 : X0        byte  1 : Y0
  byte  2 : U0        byte  3 : V0
  byte  4 : X1        byte  5 : Y1
  byte  6 : U1        byte  7 : V1
  byte  8 : X2        byte  9 : Y2
  byte 10 : U2        byte 11 : V2
  byte 12 : extra0    byte 13 : extra1   (unknown; maybe color/CLUT)

Positions are byte-valued (0-255). Verified: DJ2.8 FT3 positions render
as a clean 16-unit tile grid; the interleave order matches the PS1 GPU
POLY_FT3 packet word order. UV pairing is inferred from packet order only
(angle-coherence of UV vs position triangles was NOT confirmed — see
quad_fields.md for the honest ledger).

Usage:
  python3 render_quads.py IN.8 OUT.png [--limit N] [--scale S] [--fill]
  python3 render_quads.py --stats IN.8
"""
import struct, sys, argparse, random
import numpy as np

def parse(path):
    with open(path, 'rb') as fh:
        d = fh.read()
    n = len(d) // 16
    tags = np.frombuffer(d, dtype='<u2', count=n * 8).reshape(n, 8)[:, 0].copy()
    pay = np.frombuffer(d, dtype=np.uint8, count=n * 16).reshape(n, 16)[:, 2:].copy()
    return tags, pay

def ft3_tris(pay):
    """Return (N,3,2) position array and (N,3,2) uv array for FT3 records."""
    pos = np.stack([pay[:, [0, 1]], pay[:, [4, 5]], pay[:, [8, 9]]], axis=1).astype(int)
    uv  = np.stack([pay[:, [2, 3]], pay[:, [6, 7]], pay[:, [10, 11]]], axis=1).astype(int)
    return pos, uv

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('inp', help='.8 input file')
    ap.add_argument('out', nargs='?', help='output PNG')
    ap.add_argument('--limit', type=int, default=40000)
    ap.add_argument('--scale', type=int, default=4)
    ap.add_argument('--fill', action='store_true', help='fill triangles with random colors instead of wireframe')
    ap.add_argument('--stats', action='store_true')
    a = ap.parse_args()

    tags, pay = parse(a.inp)
    m = (tags >= 0x224) & (tags <= 0x227)
    P = pay[m][:a.limit]
    print(f'{a.inp}: {m.sum()} FT3 records, using {len(P)}')

    if a.stats:
        pos, uv = ft3_tris(P)
        e1 = pos[:, 1] - pos[:, 0]; e2 = pos[:, 2] - pos[:, 0]
        ap_ = np.abs(e1[:, 0] * e2[:, 1] - e2[:, 0] * e1[:, 1]) / 2
        f1 = uv[:, 1] - uv[:, 0]; f2 = uv[:, 2] - uv[:, 0]
        au = np.abs(f1[:, 0] * f2[:, 1] - f2[:, 0] * f1[:, 1]) / 2
        print(f'  pos area: median {np.median(ap_):.1f}  p90 {np.percentile(ap_, 90):.1f}')
        print(f'  uv  area: median {np.median(au):.1f}  p90 {np.percentile(au, 90):.1f}')
        print(f'  pos x range [{pos[:,:,0].min()},{pos[:,:,0].max()}]  y range [{pos[:,:,1].min()},{pos[:,:,1].max()}]')
        return

    from PIL import Image, ImageDraw
    S = a.scale
    pos, _ = ft3_tris(P)
    img = Image.new('RGB', (256 * S, 256 * S), (0, 0, 0))
    dr = ImageDraw.Draw(img)
    if a.fill:
        random.seed(0)
        for t in pos:
            c = (random.randint(40, 255), random.randint(40, 255), random.randint(40, 255))
            dr.polygon([(int(t[0,0])*S, int(t[0,1])*S),
                        (int(t[1,0])*S, int(t[1,1])*S),
                        (int(t[2,0])*S, int(t[2,1])*S)], fill=c, outline=(0, 0, 0))
    else:
        for t in pos:
            dr.polygon([(int(t[0,0])*S, int(t[0,1])*S),
                        (int(t[1,0])*S, int(t[1,1])*S),
                        (int(t[2,0])*S, int(t[2,1])*S)], outline=(0, 255, 0))
    img.save(a.out)
    print(f'wrote {a.out}')

if __name__ == '__main__':
    main()
