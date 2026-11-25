#!/usr/bin/env python3
"""Recursive-descent MIPS disassembler + xref engine for SLUS_002.92."""
import struct
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

LOAD = 0x80010000
BIN = '/home/hatch/workspace/suikoden/kit/work/slus_code.bin'
data = open(BIN, 'rb').read()
DSIZE = len(data)

def r2a(off): return off + LOAD
def a2r(addr): return addr - LOAD
def valid(addr): return LOAD <= addr < LOAD + DSIZE
def u32(addr):
    if not valid(addr): return None
    return struct.unpack('<I', data[a2r(addr):a2r(addr)+4])[0]

MD = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
MD.detail = True

BRANCH_OPS = {'beq','bne','beqz','bnez','bgez','bgezal','bgtz','blez','bltz','bltzal',
              'bc1t','bc1f','bc2t','bc2f','b','bal'}

def dis_one(addr):
    w = u32(addr)
    if w is None: return None, None
    ins = list(MD.disasm(struct.pack('<I', w), addr))
    if not ins: return None, None
    return ins[0], w

def fmt(addr):
    ins, w = dis_one(addr)
    if not ins: return f"0x{addr:08x}: ???"
    return f"0x{addr:08x}: {ins.mnemonic:8s} {ins.op_str}"

def dump(addr, n=40):
    for i in range(n):
        a = addr + i*4
        ins, w = dis_one(a)
        if ins is None:
            print(f"0x{a:08x}: <invalid>"); break
        print(fmt(a))
        if ins.mnemonic in ('jr', 'j', 'syscall', 'break'):
            d, _ = dis_one(a+4)
            if d: print(fmt(a+4))
            break

# ---- string xref: find lui/addiu loads of a data address ----
# index all lui instructions: {hi -> [(addr, rt)]}
_lui_index = None
def lui_index():
    global _lui_index
    if _lui_index is not None: return _lui_index
    idx = {}
    for off in range(0, DSIZE, 4):
        w = struct.unpack('<I', data[off:off+4])[0]
        if w >> 16 == 0x3C00:  # lui rt,imm
            rt = (w >> 16) & 0x1F
            imm = w & 0xFFFF
            idx.setdefault(imm, []).append((r2a(off), rt))
    _lui_index = idx
    return idx

def addr_users(addr, window=12):
    """Find code that loads `addr` via lui+addiu/ori/addu or gp-relative lw."""
    hi, lo = addr >> 16, addr & 0xFFFF
    hits = []
    for la, rt in lui_index().get(hi, []):
        for i in range(1, window+1):
            a = la + i*4
            ins, w = dis_one(a)
            if not ins: break
            op = ins.mnemonic
            used = False
            if op in ('addiu', 'ori', 'addi') and (w & 0xFFFF) == lo:
                # dest rt? rs anywhere
                if ((w >> 16) & 0x1F) == rt: used = True
            elif op in ('lw','lh','lhu','lb','lbu','sw','sh','sb') and (w & 0xFFFF) == lo:
                if ((w >> 21) & 0x1F) == rt: used = True
            if used:
                hits.append((a, ins.mnemonic + ' ' + ins.op_str, rt))
                break
            if op in ('lui',): break
    return hits

# ---- jal xref ----
def jal_callers(tgt):
    word = 0x0C000000 | ((tgt >> 2) & 0x3FFFFFF)
    pat = struct.pack('<I', word)
    out = []
    start = 0
    while True:
        i = data.find(pat, start)
        if i < 0: break
        out.append(r2a(i))
        start = i + 1
    return out

# ---- trampoline detection: jr $t9 after lui $t9, or j to code ----
def is_trampoline(addr):
    """True if function is just a jump stub (PsyQ-style)."""
    insns = []
    for i in range(6):
        ins, w = dis_one(addr + i*4)
        if not ins: return False, None
        insns.append((ins, w))
        if ins.mnemonic == 'jr':
            # delay slot
            d, _ = dis_one(addr + (i+1)*4)
            return True, f"jr {ins.op_str}"
        if ins.mnemonic == 'j':
            return True, f"j {ins.op_str}"
    return False, None
