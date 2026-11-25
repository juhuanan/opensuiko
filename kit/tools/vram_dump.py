#!/usr/bin/env python3
"""
Extract PS1 VRAM (1024x512 16-bit) from a PCSX-Redux SaveState v4 file.

Format (reverse-engineered 2026-09-30):
  file = gzip( protobuf SaveState )
  top-level protobuf fields (all length-delimited):
    field 1: 27B  - inner message "PCSX-Redux SaveState v4"
    field 3: ~18MB - main emulator state blob
    field 4: ~8KB
    field 5: ~1MB  - GPU/VRAM container (nested protobuf):
        field 1: varint (gpu id/magic, e.g. 3556909703)
        field 2: 1024 bytes (unknown metadata)
        field 3: 1048576 bytes = raw VRAM, 1024x512 16-bit 555 (XBBBBBGGGGGRRRRR)
    field 6: ~627KB
    fields 7,8,10,11,14: small

Usage:
  python3 vram_dump.py <state.sstate0> -o <out.png> [--raw <out.bin>]
"""

import argparse
import gzip
import struct
import sys


def read_varint(d, pos):
    val, shift = 0, 0
    while True:
        b = d[pos]
        pos += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return val, pos


def parse_fields(d, start, end, max_fields=64):
    """Parse protobuf fields in d[start:end]; yields (field_no, wire, value, data_off)."""
    pos, out = start, []
    while pos < end and len(out) < max_fields:
        tag = d[pos]
        pos += 1
        fn, wire = tag >> 3, tag & 7
        if wire == 0:
            v, pos = read_varint(d, pos)
            out.append((fn, wire, v, None))
        elif wire == 2:
            ln, pos = read_varint(d, pos)
            out.append((fn, wire, ln, pos))
            pos += ln
        elif wire == 5:
            v = int.from_bytes(d[pos:pos + 4], "little")
            pos += 4
            out.append((fn, wire, v, None))
        elif wire == 1:
            v = int.from_bytes(d[pos:pos + 8], "little")
            pos += 8
            out.append((fn, wire, v, None))
        else:
            raise ValueError(f"unknown wire type {wire} at 0x{pos-1:X}")
    return out


def extract_vram(state_path):
    with gzip.open(state_path, "rb") as f:
        data = f.read()
    top = parse_fields(data, 0, len(data))
    f5 = next((f for f in top if f[0] == 5 and f[1] == 2), None)
    if not f5:
        raise ValueError("top-level field 5 (VRAM container) not found")
    _, _, ln, off = f5
    nested = parse_fields(data, off, off + ln)
    f3 = next((f for f in nested if f[0] == 3 and f[1] == 2), None)
    if not f3 or f3[2] != 1024 * 512 * 2:
        raise ValueError(f"nested VRAM field not 1048576 bytes (got {f3[2] if f3 else None})")
    _, _, vlen, voff = f3
    return data[voff:voff + vlen]


def vram_to_png(vram, out_path):
    from PIL import Image
    img = Image.new("RGB", (1024, 512))
    px = img.load()
    for y in range(512):
        base = y * 2048
        for x in range(1024):
            p = vram[base + x * 2] | (vram[base + x * 2 + 1] << 8)
            r, g, b = p & 0x1F, (p >> 5) & 0x1F, (p >> 10) & 0x1F
            px[x, y] = ((r * 255) // 31, (g * 255) // 31, (b * 255) // 31)
    img.save(out_path)


def main():
    ap = argparse.ArgumentParser(description="Dump VRAM from PCSX-Redux SaveState v4")
    ap.add_argument("state", help="input .sstate0 file")
    ap.add_argument("-o", "--output", required=True, help="output PNG path")
    ap.add_argument("--raw", default=None, help="also write raw 1MB VRAM bin")
    args = ap.parse_args()

    vram = extract_vram(args.state)
    vram_to_png(vram, args.output)
    print(f"VRAM PNG -> {args.output}")
    if args.raw:
        with open(args.raw, "wb") as f:
            f.write(vram)
        print(f"VRAM raw -> {args.raw}")


if __name__ == "__main__":
    sys.exit(main())
