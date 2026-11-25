"""Disc access helper for .8 files (through kit/tools/disc.py only)."""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, os.path.join(ROOT, 'kit', 'tools'))
import disc

def read8(lba, nbytes, chunk=1 << 20):
    out = bytearray()
    got = 0
    while got < nbytes:
        n = min(chunk, nbytes - got)
        # disc.extract takes (lba, size) -- sizes here are sector-aligned in practice
        out += disc.extract(lba + got // 2048, n)
        got += n
    return bytes(out[:nbytes])
