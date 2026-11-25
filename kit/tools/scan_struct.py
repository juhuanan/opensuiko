#!/usr/bin/env python3
"""Map accesses to the 0x801BA000 struct: for each lui $r,0x801B, look ahead
for loads/stores through $r (incl. ori/addiu-derived and addu-indexed)."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mipsdec import word_at, dec, BASE, size, REGS  # noqa: E402

START = BASE
MEMOPS = {0x20:'lb',0x21:'lh',0x23:'lw',0x24:'lbu',0x25:'lhu',
          0x28:'sb',0x29:'sh',0x2B:'sw',0x22:'lwl',0x26:'lwr',0x2A:'swl',0x2E:'swr'}


def _end():
    """End VA of the loaded EXE body (computed lazily from the disc)."""
    return BASE + size()

def scan():
    # collect all lui 0x801B sites
    end = _end()
    sites = []
    pc = START
    while pc < end:
        w = word_at(pc)
        if (w >> 26) & 0x3F == 0x0F and (w & 0xFFFF) == 0x801B:
            sites.append((pc, (w >> 16) & 0x1F))
        pc += 4
    print(f"lui 0x801B sites: {len(sites)}", file=sys.stderr)
    for spc, reg in sites:
        # track derived regs: map reg -> (kind, base_off)
        derived = {reg: 0x801B0000}
        pc = spc + 4
        for _ in range(60):
            if pc >= end: break
            w = word_at(pc)
            op = (w >> 26) & 0x3F
            rs = (w >> 21) & 0x1F; rt = (w >> 16) & 0x1F
            rd = (w >> 11) & 0x1F
            imm = w & 0xFFFF; imm_s = imm - 0x10000 if imm & 0x8000 else imm
            fn = w & 0x3F
            s, _ = dec(pc, w)
            if op == 0x0D and rs in derived:  # ori rt,rs,uimm
                derived[rt] = (derived[rs] + imm) & 0xFFFFFFFF
            elif op == 0x09 and rs in derived and rs == rt:  # addiu r,r,imm
                derived[rt] = (derived[rt] + imm_s) & 0xFFFFFFFF
            elif op == 0 and fn in (0x21, 0x25):  # addu/or
                if rt == 0 and rs in derived: derived[rd] = derived[rs]
                elif rs == 0 and rt in derived: derived[rd] = derived[rt]
                elif rd in derived: del derived[rd]
            elif op in MEMOPS and rs in derived:
                base = derived[rs]
                tgt = (base + imm_s) & 0xFFFFFFFF
                if 0x801B0000 <= tgt < 0x801C0000:
                    print(f"{spc:#x} -> {pc:#x}  {s:36s}  abs={tgt:#x} (struct+{tgt-0x801BA000:#x})")
            # register clobbered by other writer: drop tracking (except $at pattern ok)
            if op == 0x0F and rt in derived and rt != reg:
                pass
            pc += 4

if __name__ == '__main__':
    scan()
