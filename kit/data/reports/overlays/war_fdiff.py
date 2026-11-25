#!/usr/bin/env python3
"""Word-level diff of one function address across scenario files.
Usage: war_fdiff.py <addr_hex> [file1 file2]
"""
import sys, struct, json
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

BASE = 0x80010000
WAR_DIR = '/home/hatch/workspace/suikoden/kit/extracted/bin_overlays/DATA/16_WAR/'
FILES = ['WAR_GARA.BIN','WAR_KITA.BIN','WAR_KUWA.BIN','WAR_LAST.BIN','WAR_SCA1.BIN',
         'WAR_SCA2.BIN','WAR_SHAS.BIN','WAR_TEO1.BIN','WAR_TEO2.BIN']
addr = int(sys.argv[1], 16)
pair = sys.argv[2:] if len(sys.argv) > 2 else ['WAR_GARA.BIN', 'WAR_KITA.BIN']

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
cdata = json.load(open('/home/hatch/workspace/suikoden/kit/work/overlays/war_cluster.json'))

def body(fn):
    data = open(WAR_DIR + fn, 'rb').read()
    words = struct.unpack('<%dI' % (len(data) // 4), data)
    v = cdata['files'][fn]['funcs'][hex(addr)]
    return data, words, v['end']

d0, w0, e0 = body(pair[0])
d1, w1, e1 = body(pair[1])
o0, o1 = (addr - BASE) // 4, (e0 - BASE) // 4
p0, p1 = (addr - BASE) // 4, (e1 - BASE) // 4
n0, n1 = o1 - o0 + 1, p1 - p0 + 1
print(f"{pair[0]} body words: {n0}, {pair[1]} body words: {n1}")
diffs = 0
for k in range(max(n0, n1)):
    a0 = w0[o0 + k] if k < n0 else None
    a1 = w1[p0 + k] if k < n1 else None
    if a0 != a1:
        diffs += 1
        if diffs <= 40:
            i0 = list(md.disasm(d0[(o0+k)*4:(o0+k)*4+4], addr + k*4))[0] if a0 is not None else None
            i1 = list(md.disasm(d1[(p0+k)*4:(p0+k)*4+4], addr + k*4))[0] if a1 is not None else None
            s0 = f"{i0.mnemonic} {i0.op_str}" if i0 and i0.id else (hex(a0) if a0 is not None else '-')
            s1 = f"{i1.mnemonic} {i1.op_str}" if i1 and i1.id else (hex(a1) if a1 is not None else '-')
            print(f"  +{k*4:#x} {pair[0]}: {s0}")
            print(f"  +{k*4:#x} {pair[1]}: {s1}")
print('total differing words:', diffs)
