#!/usr/bin/env python3
"""Scan files for LZSS-compressed text blobs (text_decode_stream format).
Tries decompression at various offsets, reports text-like output."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lzss import LZSSError  # noqa: E402
from text_lzss import decompress, looks_like_text  # noqa: E402

def scan_file(path, step=256, min_out=64):
    with open(path, 'rb') as f:
        data = f.read()
    hits = []
    # Try offsets aligned to step, plus try to be smart about it
    for off in range(0, len(data) - 32, step):
        try:
            out = decompress(data[off:off+4096])
        except LZSSError:
            # not a valid stream at this offset -- expected while scanning
            continue
        if len(out) >= min_out and looks_like_text(out, 0.75):
            # Extra check: not just repeating bytes
            if len(set(out)) > 10:
                hits.append((off, len(out), out[:200]))
                # Don't flood; break after a few hits per file
                if len(hits) >= 5:
                    break
    return hits

if __name__ == '__main__':
    path = sys.argv[1]
    print(f"Scanning {path}...")
    hits = scan_file(path)
    if not hits:
        print("No hits.")
    for off, ln, sample in hits:
        print(f"\n=== offset {off:#x}, decompressed {ln} bytes ===")
        print(repr(sample))
