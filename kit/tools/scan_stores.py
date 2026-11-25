#!/usr/bin/env python3
"""Scan SLUS_002.92 for stores to specific absolute addresses via lui+sw patterns."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mipsdec import word_at, dec, BASE, size  # noqa: E402
from mips_writers import resolve_reg  # noqa: E402

START = BASE


def _end():
    """End VA of the loaded EXE body (computed lazily from the disc)."""
    return BASE + size()

# writer_of() and resolve_reg() moved to kit/tools/mips_writers.py on 2026-10-04.
# This file and scan_abs.py held private copies of the same backward walk and
# both copies ignored loads as writers and dropped cross-register addends, so a
# loaded value was reported as a constant base. One shared implementation, with
# load/call writers classified and MIPS I delay slots respected, so the two
# scanners cannot diverge again. See kit/docs/scanner_writer_fix.md.

def scan_stores(offsets):
    """Find every sw to absolute addresses whose low16 is in offsets set.
    offsets: dict low16(int signed) -> label. Returns list of hits."""
    hits = []
    pc = START
    end = _end()
    while pc < end:
        w = word_at(pc)
        op = (w >> 26) & 0x3F
        if op == 0x2B:  # sw
            rs = (w >> 21) & 0x1F
            rt = (w >> 16) & 0x1F
            imm = w & 0xFFFF
            imm_s = imm - 0x10000 if imm & 0x8000 else imm
            if imm in offsets or imm_s in offsets:
                lab = offsets.get(imm, offsets.get(imm_s))
                base_val, chain = resolve_reg(pc, rs)
                val_val, vchain = resolve_reg(pc, rt)
                s, _ = dec(pc, w)
                hits.append((pc, s, lab, base_val, chain, rt, val_val, vchain))
        pc += 4
    return hits

if __name__ == '__main__':
    targets = {0x00FC: '0x800B00FC', 0x1938: '0x800B1938', 0xF6F8 - 0x10000: '0x8009F6F8'}
    # note: sw imm field is 16-bit; 0xF6F8 appears as imm=0xF6F8 (signed -0x908)
    hits = scan_stores(targets)
    for pc, s, lab, base_val, chain, rt, val_val, vchain in hits:
        print(f"{pc:#10x}  {s:32s}  -> {lab}")
        print(f"    base: {base_val:#x}" if base_val is not None else f"    base: UNRESOLVED [{chain}]")
        print(f"    val : {val_val:#x}" if val_val is not None else f"    val : UNRESOLVED [{vchain}]")
