#!/usr/bin/env python3
"""text_lzss.py -- thin wrapper over kit/tools/lzss.py (consolidated 2026-10-02).

The implementation lives in lzss.py, which encodes the TRUE hardware semantics
of text_decode_stream @0x800C3144 (LSB-first flags; 2-byte match copies
(t0>>2)+3; 1-byte match copies ((t0&0x30)>>4)+2; literal run = (t0&0x3F)+8
fresh bytes; history 0x400 @0x8017AB1C, write pos starts 0x3DE).
See lzss.py and docs/lzss_consolidation.md.

BEHAVIOUR CHANGE (2026-10-02): decompress() is now STRICT -- it raises
lzss.TruncationError if the stream ends mid-token instead of silently
returning partial output. Callers that scan unknown data should use
lzss.iter_candidates(); callers that decode known blobs should catch
lzss.LZSSError.
"""

from lzss import (
    decode_strict,
    decode,
    decode_container,
    iter_candidates,
    LZSSError,
    TruncationError,
    TrailingBytesError,
)

__version__ = "2.0.0"


def decompress(data: bytes) -> bytes:
    """Decompress LZSS payload. Strict: raises LZSSError on truncation."""
    return decode_strict(data)


def looks_like_text(data: bytes, threshold: float = 0.7) -> bool:
    """Heuristic: mostly printable ASCII / common bytes."""
    if not data:
        return False
    printable = sum(1 for b in data if 0x20 <= b <= 0x7E or b in (0x0A, 0x0D))
    return printable / len(data) >= threshold


if __name__ == '__main__':
    import sys
    with open(sys.argv[1], 'rb') as f:
        data = f.read()
    off = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0
    ln = int(sys.argv[3], 0) if len(sys.argv) > 3 else len(data) - off
    try:
        out = decompress(data[off:off+ln])
    except LZSSError as ex:
        print(f"decode failed: {ex}")
        sys.exit(1)
    print(f"decompressed {ln} -> {len(out)} bytes")
    print(f"text-like: {looks_like_text(out)}")
    # print first 512 bytes as repr
    print(repr(out[:512]))
