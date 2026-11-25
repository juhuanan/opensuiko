#!/usr/bin/env python3
"""
FACE_*.BIN decompressor for Suikoden (PS1).

Format (reverse-engineered via black-box analysis):
- Bytes 0-3: u32 header (purpose unknown; NOT decompressed size)
- Bytes 4+: LZSS compressed data

LZSS parameters:
- 4KB sliding window (4096 bytes), zero-initialized, absolute offsets
- Flag bytes read MSB-first (bit 7 to bit 0)
- Flag 1 = literal byte (copy 1 byte from input to output)
- Flag 0 = match: 16-bit little-endian value
  - Offset = value >> 4 (12-bit, 0-4095, absolute window position)
  - Length = (value & 0xF) + 3 (3-18 bytes)
  - Copy from window[offset .. offset+length-1] (with wraparound)

Verified on FACE_01.BIN, FACE_02.BIN, FACE_03.BIN:
- Each decompresses to ~40-41KB
- Output entropy 4.2-5.0 (vs 7.67 input), 44-54% zeros
- Consistent structure across all three files

The decompressed data contains a byte-oriented header (sparse non-zero
values) followed by dense data starting ~18KB in. Image format of the
decompressed payload is not yet decoded.

Function address in MAIN.EXE: not yet located (binary search found only
false positives: VLQ decoder at 0x8015D418, graphics code at 0x8015C818).
"""

import struct
import sys
import os


class FaceDecodeError(ValueError):
    """Malformed FACE LZSS stream (a literal or match token is truncated)."""


def face_decompress(data: bytes, offset: int = 4, strict: bool = True) -> bytes:
    """
    Decompress FACE_*.BIN LZSS data.

    Args:
        data: Compressed file bytes
        offset: Start offset (default 4, skipping u32 header)
        strict: True (default) raises FaceDecodeError when the stream ends
            mid-token. False stops at the incomplete token and returns the
            partial decode -- only for candidates/detectors, never for assets:
            the old bare ``except IndexError: pass`` let a truncated tail pass
            for a complete decode.

    Returns:
        Decompressed bytes

    Raises:
        FaceDecodeError: strict=True and the stream ends mid-token.
    """
    out = bytearray()
    pos = offset
    window = bytearray(4096)  # Zero-initialized 4KB window
    win_pos = 0

    while pos < len(data):
        flags = data[pos]
        pos += 1
        # Process 8 flags, MSB first
        for i in range(8):
            if pos >= len(data):
                # input exhausted exactly at a flag boundary: clean stop
                break
            if (flags >> (7 - i)) & 1:
                # Literal: copy 1 byte
                b = data[pos]
                pos += 1
                out.append(b)
                window[win_pos] = b
                win_pos = (win_pos + 1) & 0xFFF
            else:
                # Match: 16-bit LE (offset = val>>4, len = (val&0xF)+3)
                if pos + 1 >= len(data):
                    if strict:
                        raise FaceDecodeError(
                            "truncated match token at byte %d of %d"
                            % (pos, len(data)))
                    return bytes(out)
                val = data[pos] | (data[pos + 1] << 8)
                pos += 2
                offset_val = val >> 4
                length = (val & 0xF) + 3
                for j in range(length):
                    b = window[(offset_val + j) & 0xFFF]
                    out.append(b)
                    window[win_pos] = b
                    win_pos = (win_pos + 1) & 0xFFF

    return bytes(out)

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <FACE_*.BIN> [output]")
        sys.exit(1)
    
    in_path = sys.argv[1]
    with open(in_path, 'rb') as f:
        data = f.read()
    
    header = struct.unpack('<I', data[:4])[0]
    print(f"Input: {in_path} ({len(data)} bytes)")
    print(f"Header u32: {header} (0x{header:08X})")
    
    decompressed = face_decompress(data)
    print(f"Decompressed: {len(decompressed)} bytes")
    
    if len(sys.argv) >= 3:
        out_path = sys.argv[2]
    else:
        base = os.path.splitext(in_path)[0]
        out_path = base + '.dec'
    
    with open(out_path, 'wb') as f:
        f.write(decompressed)
    print(f"Wrote: {out_path}")

if __name__ == '__main__':
    main()
