#!/usr/bin/env python3
"""Static analysis helpers for SLUS_002.92 frontend (MIPS R3000 LE, load 0x80010000)."""
import re, struct, sys

LOAD = 0x80010000
BIN = '/home/hatch/workspace/suikoden/kit/work/slus_code.bin'
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
