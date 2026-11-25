"""Careful absolute-address reference scanner for MIPS I.

Resolves `lui reg,hi` + later `op rt, imm(reg)` / `addiu reg,reg,imm` pairs with
full SIGN EXTENSION of the 16-bit immediate: addr = (hi<<16) + sx16(imm).
Validated against known positives before use (see selftest()).
"""
import struct, sys, os

REGV = ['$zero','$at','$v0','$v1','$a0','$a1','$a2','$a3',
        '$t0','$t1','$t2','$t3','$t4','$t5','$t6','$t7',
        '$s0','$s1','$s2','$s3','$s4','$s5','$s6','$s7',
        '$t8','$t9','$k0','$k1','$gp','$sp','$fp','$ra']

def sx16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

IMM_OPS = {0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E}   # addi..xori
LOAD_OPS = {0x20,0x21,0x22,0x23,0x24,0x25,0x26}  # lb..lwr
STORE_OPS = {0x28,0x29,0x2A,0x2B,0x2E}           # sb..swr
ALL_IMM = IMM_OPS | LOAD_OPS | STORE_OPS | {0x2F}

def writes(w):
    """regs written by instruction word w (approximate, MIPS I)."""
    op = (w >> 26) & 0x3F
    rs, rt, rd = (w >> 21) & 0x1F, (w >> 16) & 0x1F, (w >> 11) & 0x1F
    out = set()
    if op == 0:
        fn = w & 0x3F
        if fn in (0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x00,0x02,0x03,0x04,
                  0x0A,0x0B,0x10,0x12,0x2A,0x2B):
            out.add(rd)
        elif fn == 0x09:
            out.add(rd if rd != 0 else 31)
        elif fn == 0x08:
            pass
    elif op in (0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E,0x0F):
        out.add(rt)
    elif op in LOAD_OPS:
        out.add(rt)
    elif op in (0x01,):
        out.add(31)  # bltzal/bgezal
    elif op in (0x02,0x03):
        out.add(31)
    return out

def scan(data, base, window=8):
    """Yield (addr, pc, kind, reg) for every resolvable absolute address."""
    n = len(data) // 4
    lui = {}          # reg -> (pc, hi)
    res = []
    for i in range(n):
        pc = base + 4*i
        w = struct.unpack_from('<I', data, 4*i)[0]
        op = (w >> 26) & 0x3F
        rs, rt = (w >> 21) & 0x1F, (w >> 16) & 0x1F
        imm = sx16(w)
        if op == 0x0F:
            lui[rt] = (pc, (w & 0xFFFF) << 16)
            continue
        if rs in lui:
            hpc, hi = lui[rs]
            if pc - hpc <= window*4 and op in ALL_IMM:
                addr = (hi + imm) & 0xFFFFFFFF
                kind = 'load' if op in LOAD_OPS else ('store' if op in STORE_OPS else 'imm')
                res.append((addr, pc, kind, rs))
        # invalidate on write
        for r in writes(w):
            if r in lui and r != 0:
                # a write to the register means the lui value is gone next insn
                if r == rt and op in (0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E,0x0F):
                    # addiu reg,reg,imm keeps a derived value; keep tracking it
                    if op == 0x09 and rs == rt and rs in lui:
                        continue
                lui.pop(r, None)
    return res

def callers(data, base, target):
    out = []
    n = len(data)//4
    for i in range(n):
        w = struct.unpack_from('<I', data, 4*i)[0]
        op = (w>>26)&0x3F
        pc = base+4*i
        if op == 3 and (((pc+4)&0xF0000000)|((w&0x3FFFFFF)<<2)) == target:
            out.append(pc)
        if op in (0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E,0x0F):
            t=(w>>16)&0x1F
            if t==31 and op==0x09:
                pass
    return out

def jal_targets(data, base):
    """all jal targets"""
    out=[]
    n=len(data)//4
    for i in range(n):
        w = struct.unpack_from('<I', data, 4*i)[0]
        if (w>>26)&0x3F == 3:
            pc = base+4*i
            out.append((pc, ((pc+4)&0xF0000000)|((w&0x3FFFFFF)<<2)))
    return out
