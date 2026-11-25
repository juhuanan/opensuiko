#!/usr/bin/env python3
"""Static analysis helpers for MAIN.EXE (MIPS R3000 LE, load 0x800C0800)."""
import re, struct, sys

LOAD = 0x800C0800
BIN = '/home/hatch/workspace/suikoden/kit/work/mainexe_code.bin'
data = open(BIN, 'rb').read()

def r2a(off): return off + LOAD
def a2r(addr): return addr - LOAD

# function prologues: addiu $sp,$sp,-X -> word 0x27BDxxxx
PROLOGS = sorted(
    m.start() - 2 for m in re.finditer(re.escape(b'\xbd\x27'), data)
    if (struct.unpack('<I', data[m.start()-2:m.start()+2])[0] >> 16) == 0x27BD
)

def func_of(addr):
    off = a2r(addr)
    cand = [p for p in PROLOGS if p <= off]
    return r2a(cand[-1]) if cand else None

def func_range(faddr):
    off = a2r(faddr)
    cand = [p for p in PROLOGS if p <= off]
    if not cand: return faddr, faddr + 256
    start = cand[-1]
    idx = PROLOGS.index(start)
    end = PROLOGS[idx+1] if idx+1 < len(PROLOGS) else len(data)
    return r2a(start), r2a(end)

def find_bytes(pat):
    return [r2a(m.start()) for m in re.finditer(re.escape(pat), data)]

def jal_to(t):
    return struct.pack('<I', 0x0C000000 | ((t >> 2) & 0x3FFFFFF))

def callers_of(t):
    return find_bytes(jal_to(t))

def u32_at(addr):
    return struct.unpack('<I', data[a2r(addr):a2r(addr)+4])[0]

def disasm(addr, nins, md=None):
    if md is None:
        from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
        md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
    out = []
    for ins in md.disasm(data[a2r(addr):a2r(addr)+nins*4], addr):
        out.append(ins)
        if len(out) >= nins: break
    return out

def show(addr, nins):
    for ins in disasm(addr, nins):
        mark = ' <===' if ins.mnemonic in ('jal', 'jr', 'jalr', 'j') else ''
        print('  %08x  %-10s %s%s' % (ins.address, ins.mnemonic, ins.op_str, mark))
