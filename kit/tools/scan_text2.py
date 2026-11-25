#!/usr/bin/env python3
"""Better English text detector for decompressed blobs."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lzss import LZSSError  # noqa: E402
from text_lzss import decompress  # noqa: E402

def english_score(data: bytes) -> float:
    """Score 0-1 for how much data looks like English text.
    English: lots of lowercase, spaces, some uppercase/punct. Very few control bytes."""
    if len(data) < 32:
        return 0.0
    n = len(data)
    lower = sum(1 for b in data if 0x61 <= b <= 0x7A)
    upper = sum(1 for b in data if 0x41 <= b <= 0x5A)
    space = sum(1 for b in data if b == 0x20)
    punct = sum(1 for b in data if b in b".,!?;:'\"-()")
    # Control bytes (except \n \r \t) are very suspicious
    bad = sum(1 for b in data if b < 0x20 and b not in (0x0A, 0x0D, 0x09))
    # High bytes suspicious for English
    high = sum(1 for b in data if b >= 0x80)
    # English: lower should dominate, spaces frequent, bad/high rare
    score = (lower / n) * 2.0 + (space / n) * 3.0 + (upper / n) * 0.5 + (punct / n) * 0.5
    score -= (bad / n) * 5.0 + (high / n) * 3.0
    return max(0.0, min(1.0, score))

def scan_file(path, step=512, max_len=8192):
    with open(path, 'rb') as f:
        data = f.read()
    best = []
    for off in range(0, len(data) - 64, step):
        try:
            out = decompress(data[off:off+max_len])
        except LZSSError:
            # not a valid stream at this offset -- expected while scanning
            continue
        if len(out) < 64:
            continue
        s = english_score(out)
        if s > 0.35:
            best.append((s, off, len(out), out[:300]))
    best.sort(reverse=True)
    return best[:10]

if __name__ == '__main__':
    path = sys.argv[1]
    print(f"Scanning {path}...")
    hits = scan_file(path)
    if not hits:
        print("No hits.")
    for s, off, ln, sample in hits:
        print(f"\n=== score {s:.2f} offset {off:#x}, out {ln} bytes ===")
        print(repr(sample))
