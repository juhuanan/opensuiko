#!/usr/bin/env python3
"""Summarize one function in one file. Usage: war_fsum.py FILE ADDR"""
import sys, struct, json
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
BASE = 0x80010000
WAR_DIR = '/home/hatch/workspace/suikoden/kit/extracted/bin_overlays/DATA/16_WAR/'
fn, addr = sys.argv[1], int(sys.argv[2], 16)
data = open(WAR_DIR + fn, 'rb').read()
words = struct.unpack('<%dI' % (len(data) // 4), data)
cdata = json.load(open('/home/hatch/workspace/suikoden/kit/work/overlays/war_cluster.json'))
labels = {}
for line in open('/home/hatch/workspace/suikoden/kit/work/function_labels.csv'):
    p = line.strip().split(',')
    if len(p) >= 3 and p[0].startswith('0x'):
        try: labels[int(p[0], 16)] = p[2]
        except: pass
v = cdata['files'][fn]['funcs'][hex(addr)]
o0 = (addr - BASE) // 4; o1 = (v['end'] - BASE) // 4
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
ext, refs = set(), set()
for i in range(o0, o1 + 1):
    w = words[i]; op = w >> 26
    if op == 3:
        t = ((w & 0x3FFFFFF) << 2) | 0x80000000
        ext.add(hex(t) + ':' + labels.get(t, '?'))
    elif op in (0x20, 0x21, 0x23, 0x24, 0x25, 0x28, 0x29, 0x2B):
        rs = (w >> 21) & 31; imm = w & 0xFFFF; simm = imm - 0x10000 if imm & 0x8000 else imm
        if rs in (1, 28, 29, 30): continue
        # resolve lui base: look back for lui
        base = None
        for j in range(i - 1, max(i - 6, o0 - 1), -1):
            wj = words[j]
            if (wj >> 26) == 0x0F and ((wj >> 16) & 31) == rs:
                base = ((wj & 0xFFFF) << 16); break
        if base is not None:
            refs.add(hex((base + simm) & 0xFFFFFFFF))
print(f"{fn} {hex(addr)} n={o1-o0+1}")
print(' ext:', sorted(ext)[:10])
print(' refs:', sorted(refs)[:12])
# print first 12 insns
c = 0
for ins in md.disasm(data[o0*4:o0*4+200], addr):
    print('  ', hex(ins.address), ins.mnemonic, ins.op_str)
    c += 1
    if c >= 14: break
