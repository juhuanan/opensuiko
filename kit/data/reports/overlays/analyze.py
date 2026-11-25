#!/usr/bin/env python3
"""First-pass static labeling for Suikoden PS1 overlay blobs.
Usage: analyze.py <bin> <base> <prefix> [--full]
--full also prints per-function detail."""
import sys, struct, re
from collections import Counter
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

path, base_s, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
full = '--full' in sys.argv
base = int(base_s, 16)
data = open(path, 'rb').read()
n = len(data) // 4
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
md.detail = True

words = struct.unpack('<%dI' % n, data)

def va(off): return base + off
def in_range(a): return base <= a < base + len(data)

# ---- sanity: lui histogram, j/jal targets ----
lui = Counter(); jt = []
for i, w in enumerate(words):
    if (w >> 26) == 0x0F: lui[w & 0xFFFF] += 1
    op = w >> 26
    if op in (2, 3):
        t = ((base & 0xF0000000) | ((w & 0x3FFFFFF) << 2))
        jt.append(t)
print("== sanity", path, "base", hex(base), "size", len(data))
print("top lui:", [(hex(k), c) for k, c in lui.most_common(8)])
inseg = [t for t in jt if in_range(t)]
print("j/jal targets:", len(jt), "in own segment:", len(inseg), "frac:", round(len(inseg)/max(1,len(jt)), 3))
if inseg:
    import statistics
    print("in-seg target range:", hex(min(inseg)), hex(max(inseg)))

# ---- strings ----
def find_strings():
    out = []
    i = 0
    while i < len(data):
        if 32 <= data[i] < 127:
            j = i
            while j < len(data) and 32 <= data[j] < 127: j += 1
            if j < len(data) and data[j] == 0 and j - i >= 4:
                out.append((va(i), data[i:j].decode('ascii')))
            i = j
        i += 1
    return out
strings = find_strings()
saddr = {a: s for a, s in strings}

# map absolute pointer words in data -> referenced strings
ptr_refs = {}
for i, w in enumerate(words):
    if w in saddr:
        ptr_refs.setdefault(va(i), []).append(w)

# ---- decode all instructions ----
insns = {}  # va -> (mnem, opstr, bytes, size, detail)
for ins in md.disasm(data, base):
    insns[ins.address] = ins

# ---- find function seeds: prologues ----
seeds = set()
for i, w in enumerate(words):
    if (w >> 26) == 9:  # addiu
        rs, rt = (w >> 21) & 31, (w >> 16) & 31
        imm = w & 0xFFFF
        if imm >= 0x8000: imm -= 0x10000
        if rs == 29 and rt == 29 and imm < 0 and -imm % 8 == 0 and -imm < 0x2000:
            seeds.add(va(i * 4))

# jal/j targets inside segment
for i, w in enumerate(words):
    op = w >> 26
    if op in (2, 3):
        t = ((base & 0xF0000000) | ((w & 0x3FFFFFF) << 2))
        if in_range(t) and (t % 4) == 0:
            seeds.add(t)

# jump-table targets via lui of own base followed by addu/jr pattern: cheap approach:
# find 'jr $rx' preceded by addu; extract table via lw pattern is complex; skip for now.

funcs = sorted(seeds)
print("\n== function seeds:", len(funcs))
for f in funcs: print("  ", hex(f))
