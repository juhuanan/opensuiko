#!/usr/bin/env python3
"""Map ASCII strings to referencing code locations in an overlay blob.
Usage: strxref.py <bin> <base> [minlen]
Prints: string_addr "string" <- code refs (with function entry from prologue scan)"""
import sys, struct
from collections import defaultdict
path, base_s = sys.argv[1], sys.argv[2]
minlen = int(sys.argv[3]) if len(sys.argv) > 3 else 4
base = int(base_s, 16)
data = open(path, 'rb').read()
words = struct.unpack('<%dI' % (len(data)//4), data)
def va(off): return base + off
def in_range(a): return base <= a < base + len(data)

# strings
strs = {}
def _ok(c): return 32 <= c < 127 or c in (9, 10, 13)
i = 0
while i < len(data):
    if _ok(data[i]):
        j = i
        while j < len(data) and _ok(data[j]): j += 1
        if j < len(data) and data[j] == 0 and j - i >= minlen:
            strs[va(i)] = data[i:j].decode()
        i = j
    i += 1

# prologue-scan function entries (for attributing refs)
seeds = set()
for i, w in enumerate(words):
    if (w >> 26) == 9:
        rs, rt = (w >> 21) & 31, (w >> 16) & 31
        imm = (w & 0xFFFF) - 0x10000 if w & 0x8000 else w & 0xFFFF
        if rs == 29 and rt == 29 and imm < 0 and -imm % 8 == 0 and -imm < 0x2000:
            seeds.add(va(i*4))
entries = sorted(seeds)
def func_of(a):
    f = 0
    for e in entries:
        if e <= a: f = e
        else: break
    return f

# lui $r,hi ... then addiu/ori $r2,$r,lo within 16 insns
lui_pos = defaultdict(list)  # (reg,hi) -> [addrs]
for i, w in enumerate(words):
    if (w >> 26) == 0x0F:
        lui_pos[((w >> 16) & 31, w & 0xFFFF)].append(va(i*4))

refs = defaultdict(set)
for saddr in strs:
    hi, lo = (saddr >> 16) & 0xFFFF, saddr & 0xFFFF
    for reg in range(32):
        for la in lui_pos.get((reg, hi), []):
            idx = (la - base)//4
            for k in range(idx+1, min(idx+17, len(words))):
                w = words[k]
                op = w >> 26
                rs, rt = (w >> 21) & 31, (w >> 16) & 31
                imm = w & 0xFFFF
                if op in (9, 13) and rs == reg and imm == lo:
                    a = va(k*4)
                    refs[saddr].add((a, func_of(a)))
                    break
                if op == 0x0F: break
    # pointer words in data
    # (skip: rare for strings)

for saddr in sorted(refs):
    s = strs[saddr]
    print("0x%08x %r" % (saddr, s[:70]))
    for a, f in sorted(refs[saddr]):
        print("    ref @0x%08x in func 0x%08x" % (a, f))
