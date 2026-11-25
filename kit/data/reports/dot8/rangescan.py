"""Collect every resolvable absolute address in a range, corpus-wide,
base-independently (lui + signed-imm reconstruction)."""
import os, struct, glob, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import refscan2

def scan_range(root, lo, hi, window=8):
    out = {}
    for f in refscan2.corpus(root):
        d = open(f, 'rb').read()
        n = len(d)//4
        hits = []
        for i in range(n):
            w = struct.unpack_from('<I', d, 4*i)[0]
            if (w >> 26) & 0x3F != 0x0F:
                continue
            reg = (w >> 16) & 0x1F
            hi16 = (w & 0xFFFF) << 16
            for k in range(1, window+1):
                j = i+k
                if j >= n: break
                w2 = struct.unpack_from('<I', d, 4*j)[0]
                op = (w2 >> 26) & 0x3F
                if op == 0x0F: break
                if ((w2 >> 21) & 0x1F) != reg: continue
                if op in refscan2.IMM or op in refscan2.LOAD or op in refscan2.STORE or op in refscan2.SPEC:
                    a = (hi16 + refscan2.sx16(w2)) & 0xFFFFFFFF
                    if lo <= a < hi:
                        hits.append((a, 4*i, 4*j, op))
        if hits: out[f] = hits
    return out
