#!/usr/bin/env python3
"""slus_show.py — full disassembly of one SLUS function.
Usage: slus_show.py <addr_hex> [--raw]
Uses /tmp/slus_funcs.json bodies + capstone.
"""
import sys, struct, json
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

PATH = '/home/hatch/workspace/suikoden/SLUS_body.bin'
BASE = 0x80010000
data = open(PATH, 'rb').read()
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
md.detail = True

with open('/tmp/slus_funcs.json') as f:
    FUNCS = {int(k, 16): v for k, v in json.load(f).items()}

# string table for comment annotations
STR = {}
i, n = 0, len(data)
import re
while i < n:
    if 32 <= data[i] < 127:
        j = i
        while j < n and 32 <= data[j] < 127: j += 1
        if j < n and data[j] == 0 and j - i >= 4:
            STR[BASE + i] = data[i:j].decode('ascii')[:70]
        i = j
    i += 1

def main():
    a = int(sys.argv[1], 16)
    # find containing function
    fstart = None
    for s, b in FUNCS.items():
        if a in b:
            fstart = s; break
    if fstart is None:
        print("address not in any function body"); return
    body = sorted(FUNCS[fstart])
    print(f"### function {fstart:#010x}  ({len(body)} insns)")
    lui_vals = {}
    for pc in body:
        o = pc - BASE
        w = struct.unpack_from('<I', data, o)[0]
        try:
            ins = next(md.disasm(data[o:o+4], pc, count=1))
            mn, ops = ins.mnemonic, ins.op_str
        except StopIteration:
            mn, ops = '.word', f"{w:#010x}"
        cmt = ''
        if mn == 'lui':
            try:
                rt, im = [x.strip() for x in ops.split(',')]
                lui_vals[rt] = int(im, 0) << 16
            except: pass
        elif mn in ('addiu', 'ori'):
            try:
                parts = [x.strip() for x in ops.split(',')]
                if len(parts) == 3 and parts[1] in lui_vals:
                    im = int(parts[2], 0)
                    imm = (im - 0x10000) if (im & 0x8000) and mn == 'addiu' else im
                    addr = (lui_vals[parts[1]] + imm) & 0xFFFFFFFF
                    if addr in STR:
                        cmt = f"  ; \"{STR[addr]}\""
                    elif 0x80000000 <= addr < 0x80400000:
                        cmt = f"  ; ={addr:#010x}"
            except: pass
        print(f"  {pc:#010x}  {w:08x}  {mn:8s} {ops}{cmt}")

if __name__ == '__main__':
    main()
