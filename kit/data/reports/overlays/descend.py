#!/usr/bin/env python3
"""Recursive-descent MIPS disassembler for overlay blobs; per-function summaries."""
import sys, struct, re
from collections import Counter, defaultdict
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

path, base_s, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
base = int(base_s, 16)
data = open(path, 'rb').read()
words = struct.unpack('<%dI' % (len(data)//4), data)
def va(off): return base + off
def off(a): return a - base
def in_range(a): return base <= a < base + len(data)

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_LITTLE_ENDIAN)
md.detail = True
insns = {}
for ins in md.disasm(data, base):
    insns[ins.address] = ins
def get(a): return insns.get(a)

# seeds: prologues
seeds = set()
for i, w in enumerate(words):
    if (w >> 26) == 9:
        rs, rt = (w >> 21) & 31, (w >> 16) & 31
        imm = (w & 0xFFFF) - 0x10000 if w & 0x8000 else w & 0xFFFF
        if rs == 29 and rt == 29 and imm < 0 and -imm % 8 == 0 and -imm < 0x2000:
            seeds.add(va(i*4))

def jtarget(a, w): return ((a + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)

# recursive descent per seed
func_insns = {}  # func -> ordered list of addrs
visited_global = set()
def descend(entry):
    body = []
    stack = [entry]
    seen = set()
    while stack:
        a = stack.pop()
        while True:
            if a in seen or a in visited_global and a != entry:
                break
            ins = get(a)
            if ins is None: break
            seen.add(a); body.append(a)
            w = words[off(a)//4]
            op = w >> 26
            m = ins.mnemonic
            if m in ('jr',):
                break
            if m in ('j',) or op == 2:
                t = jtarget(a, w)
                if in_range(t) and t not in seen: stack.append(t)
                break
            if m in ('jal',) or op == 3:
                t = jtarget(a, w)
                if in_range(t): seeds.add(t)
                a += 8; continue  # delay slot then fallthrough
            # branches
            taken = None
            if m in ('beq','bne','beql','bnel','bgez','bgezal','bgtz','blez','bltz','bltzal'):
                imm = (w & 0xFFFF); imm -= 0x10000 if imm & 0x8000 else 0
                taken = a + 4 + (imm << 2)
            elif m in ('bc1t','bc1f','bc1tl','bc1fl'):
                imm = (w & 0xFFFF); imm -= 0x10000 if imm & 0x8000 else 0
                taken = a + 4 + (imm << 2)
            if taken is not None and in_range(taken) and taken not in seen:
                stack.append(taken)
            a += 4
    return sorted(seen)

for s in sorted(seeds):
    b = descend(s)
    if b:
        func_insns[s] = b
        visited_global.update(b)

print("== functions found:", len(func_insns))
for f, b in func_insns.items():
    print(hex(f), "insns:", len(b), "end:", hex(b[-1]))
