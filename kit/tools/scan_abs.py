#!/usr/bin/env python3
"""Scan ALL sw/sh/sb; resolve constant base via backward walk; report stores
hitting a watchlist of absolute addresses."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mipsdec import word_at, dec, BASE, size  # noqa: E402
from mips_writers import resolve_reg  # noqa: E402

START = BASE


def _end():
    """End VA of the loaded EXE body (computed lazily from the disc)."""
    return BASE + size()

# writer_of() and resolve_reg() moved to kit/tools/mips_writers.py on 2026-10-04;
# this file's private copy omitted loads as writers, so a loaded value could be
# reported as a constant base. See kit/docs/scanner_writer_fix.md.

WATCH = {0x800B00FC, 0x800B1938, 0x8009F6F8, 0x8009F6FC, 0x8009F700, 0x8009F704}

def main():
    hits = []
    pc = START
    n = 0
    end = _end()
    while pc < end:
        w = word_at(pc)
        op = (w >> 26) & 0x3F
        if op in (0x2B, 0x29, 0x28):  # sw, sh, sb
            rs = (w >> 21) & 0x1F
            rt = (w >> 16) & 0x1F
            imm = w & 0xFFFF
            imm = imm - 0x10000 if imm & 0x8000 else imm
            base, _ = resolve_reg(pc, rs)
            if base is not None:
                tgt = (base + imm) & 0xFFFFFFFF
                if tgt in WATCH:
                    val, vchain = resolve_reg(pc, rt)
                    s, _ = dec(pc, w)
                    hits.append((pc, s, tgt, val, vchain))
        pc += 4
        n += 1
    for pc, s, tgt, val, vchain in hits:
        print(f"{pc:#10x}  {s:34s} -> {tgt:#x}")
        print(f"    val: {val:#x}" if val is not None else f"    val: UNRESOLVED [{vchain}]")

if __name__ == '__main__':
    main()
