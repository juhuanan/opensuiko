"""Scan the MAIN.EXE body for accesses through the global struct pointer
stored at 0x8017BE3C, and report (function-ish, pc, access, offset).

Addresses are BYTE addresses throughout; offsets reported are BYTE offsets.
"""
import os, sys, re
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rd
from mipsdec import dec

G_ADDR = 0x8017BE3C          # the word that holds the struct pointer
LO, HI = 0x800C0800, 0x800C0800 + rd.size()

# symbolic values: int (absolute constant) or ('G', k) meaning *(0x8017BE3C)+k
ACCESS = {0x20:'lb',0x21:'lh',0x22:'lwl',0x23:'lw',0x24:'lbu',0x25:'lhu',0x26:'lwr',
          0x28:'sb',0x29:'sh',0x2A:'swl',0x2B:'sw',0x2E:'swr'}
LOADS = (0x20,0x21,0x22,0x23,0x24,0x25,0x26)

def sx16(v):
    v &= 0xFFFF
    return v-0x10000 if v & 0x8000 else v

def scan():
    reg = {}                # reg index -> value
    out = []
    pc = LO
    # a small linear sweep, resetting reg knowledge after a call/branch target
    leaders = set()
    # crude: reset at every jal target and after jr $ra
    while pc < HI:
        w = rd.word(pc)
        if w is None: break
        s, f = dec(pc, w)
        op, rs, rt, rd_, sa, imm = f['op'], f['rs'], f['rt'], f['rd'], f['sa'], f['imm']
        if op == 0x0F:                                  # lui
            reg[rt] = (imm & 0xFFFF) << 16
        elif op in (0x08, 0x09):                        # addi/addiu
            b = reg.get(rs)
            if isinstance(b, int): reg[rt] = (b + sx16(imm)) & 0xFFFFFFFF
            elif isinstance(b, tuple) and b[0]=='G': reg[rt] = ('G', b[1] + sx16(imm))
            else: reg.pop(rt, None)
        elif op == 0x0D:                                # ori
            b = reg.get(rs)
            if isinstance(b, int): reg[rt] = b | (imm & 0xFFFF)
            else: reg.pop(rt, None)
        elif op in LOADS:
            b = reg.get(rs)
            if isinstance(b, int):
                ea = (b + sx16(imm)) & 0xFFFFFFFF
                if ea == G_ADDR and f['op'] == 0x23:
                    reg[rt] = ('G', 0)                  # the global struct pointer
                    out.append((pc,'lw',ea,'G_ptr'))
                else:
                    reg[rt] = ('abs', ea)
            elif isinstance(b, tuple) and b[0]=='G':
                out.append((pc, ACCESS[op], b[1]+sx16(imm), 'G'))
                reg.pop(rt, None)
            else:
                reg.pop(rt, None)
        elif op in (0x28,0x29,0x2A,0x2B,0x2E):
            b = reg.get(rs)
            if isinstance(b, tuple) and b[0]=='G':
                out.append((pc, ACCESS[op], b[1]+sx16(imm), 'G'))
        elif op == 0x03:                                # jal
            reg.pop(31, None)
        elif op == 0 and f.get('fn') == 0x09:           # jalr
            if rd_: reg.pop(rd_, None)
        elif op == 0 and f.get('fn') in (0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27):
            a = reg.get(rs); b = reg.get(rt)
            if isinstance(a, int) and isinstance(b, int):
                if f['fn']==0x20: reg[rd_]=(a+b)&0xFFFFFFFF
                elif f['fn']==0x21: reg[rd_]=(a+b)&0xFFFFFFFF
                elif f['fn']==0x23: reg[rd_]=(a-b)&0xFFFFFFFF
                else: reg.pop(rd_, None)
            else: reg.pop(rd_, None)
        else:
            d = None
            if op == 0:
                if f.get('fn') in (0x00,0x02,0x03,0x04,0x10,0x12): d = rd_
            if d is not None: reg.pop(d, None)
        pc += 4
    return out

if __name__ == '__main__':
    out = scan()
    print(f"# accesses through G = *(0x8017BE3C): {len(out)}")
    from collections import defaultdict
    byoff = defaultdict(list)
    for pc, kind, off, src in out:
        byoff[off].append((pc, kind))
    for off in sorted(byoff):
        items = byoff[off]
        print(f"G+0x{off & 0xFFFFFFFF:04x} (={off}): {len(items)}  " +
              " ".join(f"{k}@{p:#x}" for p,k in items[:6]) +
              (" ..." if len(items)>6 else ""))
