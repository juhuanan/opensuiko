#!/usr/bin/env python3
"""Find runs of code-pointer words (jump tables) in an overlay blob.
Usage: tablescan.py <bin> <base>
Prints table locations and their targets."""
import sys, struct
path, base_s = sys.argv[1], sys.argv[2]
base = int(base_s, 16)
data = open(path, 'rb').read()
words = struct.unpack('<%dI' % (len(data)//4), data)
def in_code(a): return base <= a < base + len(data) and a % 4 == 0
runs = []
i = 0
n = len(words)
while i < n:
    if in_code(words[i]):
        j = i
        while j < n and in_code(words[j]): j += 1
        if j - i >= 2:
            runs.append((base + i*4, [words[k] for k in range(i, j)]))
        i = j
    else:
        i += 1
for addr, tgts in runs:
    print("TABLE at 0x%08x n=%d" % (addr, len(tgts)))
    for t in tgts:
        print("   -> 0x%08x" % t)
