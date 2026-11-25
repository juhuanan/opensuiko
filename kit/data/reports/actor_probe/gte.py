import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import rd
LO = 0x800C0800; HI = LO + rd.size()
counts = {}
hits = []
pc = LO
while pc < HI:
    w = rd.word(pc)
    if w is None: break
    op = (w >> 26) & 0x3F
    if op in (0x12, 0x32, 0x3A):
        counts[op] = counts.get(op,0)+1
        hits.append((pc, op, w))
    pc += 4
print("GTE-ish opcode counts:", {hex(k):v for k,v in counts.items()})
# cluster addresses into bands of 0x400
from collections import Counter
c = Counter()
for pc,op,w in hits:
    c[pc & ~0x3FF] += 1
for base in sorted(c):
    print(f"{base:#010x}  {c[base]}")
