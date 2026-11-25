#!/usr/bin/env python3
"""Labeling worksheet generator for Suikoden event overlays.
Usage: ovl_worksheet.py <bin> <base_hex> <outdir>
Writes <outdir>/summary.txt (per-function: callees, vtable jalrs, string refs)
and <outdir>/func_<addr>.txt disassemblies."""
import sys, os, struct, csv, re
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

path, base_s, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(outdir, exist_ok=True)
base = int(base_s, 16)
raw = open(path, 'rb').read()
n = len(raw)//4
data = raw[:n*4]
words = struct.unpack('<%dI'%n, data)
def va(o): return base+o
def off(a): return a-base
def inr(a): return base <= a < base+len(data)

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32|CS_MODE_LITTLE_ENDIAN)
md.detail = True
insns = {}
for o in range(0, len(data)-3, 4):
    try:
        for ins in md.disasm(data[o:o+4], base+o):
            insns[ins.address] = ins
            break
    except Exception:
        pass
def get(a): return insns.get(a)
def word_at(a):
    o = off(a)
    return words[o//4] if 0 <= o <= len(data)-4 else None

# strings
def _pc(b): return 32 <= b < 127 or b in (9, 10, 13)
strs = {}
i = 0
while i < len(data):
    if _pc(data[i]):
        j = i
        while j < len(data) and _pc(data[j]): j += 1
        if j < len(data) and data[j] == 0 and j-i >= 4:
            strs[va(i)] = data[i:j].decode('ascii', 'replace')
        i = j
    i += 1

# MAIN.EXE labels
main = {}
try:
    with open('/home/hatch/workspace/suikoden/kit/work/function_labels.csv') as f:
        for r in csv.DictReader(f):
            try: main[int(r['address'],16)] = r['name']
            except: pass
except Exception as e: print("no main labels:", e)

# seeds: prologues first; then recursive-descent walks collect jal targets (fixpoint)
seeds = set()
for o in range(0, len(data)-3, 4):
    w = words[o//4]
    if (w>>26) == 9:
        rs, rt = (w>>21)&31, (w>>16)&31
        imm = (w&0xFFFF)-0x10000 if w&0x8000 else w&0xFFFF
        if rs==29 and rt==29 and imm<0 and -imm%8==0 and -imm<0x2000:
            seeds.add(va(o))
def jtarget(a,w): return ((a+4)&0xF0000000)|((w&0x3FFFFFF)<<2)
JRRA = 0x03E00008
BRANCH_OPS = {1,4,5,6,7}  # regimm, beq, bne, blez, bgtz (+bc1 ignored)
def branch_target(a,w):
    imm = w & 0xFFFF
    if imm & 0x8000: imm -= 0x10000
    return (a+4 + (imm<<2)) & 0xFFFFFFFF
def walk_body(s, seed_set):
    """recursive descent from s; returns (addrs set, jal targets found)"""
    seen = set(); jals = set(); stack = [s]
    limit = base+len(data)
    while stack:
        a = stack.pop()
        while True:
            if a in seen: break
            if a in seed_set and a != s: break  # ran into another function
            w = word_at(a); ins = get(a)
            if w is None or ins is None: break
            seen.add(a)
            if w == JRRA: break
            m = ins.mnemonic; op = w>>26
            if m == 'jr': break
            if op == 2:  # j
                t = jtarget(a,w)
                if s <= t < limit and t not in seen: stack.append(t)
                break
            if op == 3:  # jal
                t = jtarget(a,w)
                if inr(t) and get(t) is not None: jals.add(t)
                a += 8; continue
            if op in BRANCH_OPS:
                t = branch_target(a,w)
                if s <= t < limit and t not in seen: stack.append(t)
                a += 4; continue
            a += 4
    return seen, jals
# fixpoint: walk prologue seeds, add jal targets as seeds, repeat
all_jals = set()
changed = True
while changed:
    changed = False
    for s in sorted(seeds):
        _, jals = walk_body(s, seeds)
        new = {t for t in jals if t not in seeds}
        if new:
            seeds.update(new); all_jals.update(new); changed = True
# final extents
funcs = []
for s in sorted(seeds):
    seen, _ = walk_body(s, seeds)
    if seen:
        funcs.append((s, max(seen)+4))
    else:
        funcs.append((s, s+4))
funcs.sort()
merged = []
for s,e in funcs:
    if merged and s < merged[-1][1]:
        if e > merged[-1][1]: merged[-1] = (merged[-1][0],e)
    else: merged.append((s,e))
real = [(s,e) for (s,e) in merged if get(s) is not None]
real = [(s,e) for (s,e) in merged if get(s) is not None]

with open(os.path.join(outdir,'summary.txt'),'w') as out:
    out.write(f"file {path} base {hex(base)} size {len(raw)} strings {len(strs)} funcs {len(real)}\n\n")
    for (s,e) in real:
        size=(e-s)//4
        callees_in=[]; callees_main=[]; vtoff=set(); srefs=[]
        lui_vals={}  # reg -> hi value
        a=s
        addrs=[]
        while a < e:
            ins=get(a); w=word_at(a)
            if ins is None or w is None: break
            addrs.append(a)
            m=ins.mnemonic; ops=ins.operands
            if m=='lui' and len(ops)>=2 and ops[0].type==1 and ops[1].type==2:
                lui_vals[ops[0].reg]=ops[1].imm
            if m in ('addiu','ori','daddiu') and len(ops)>=3 and ops[1].type==1 and ops[2].type==2:
                rs=ops[1].reg
                if rs in lui_vals:
                    lo=ops[2].imm
                    if lo&0x8000: lo-=0x10000
                    addr=(lui_vals[rs]<<16)+lo & 0xFFFFFFFF
                    if addr in strs and strs[addr] not in srefs: srefs.append(strs[addr])
            if m in ('lw','sw','lbu','sb','lh','sh','lhu') and len(ops)>=2 and ops[1].type==3:
                mem=ops[1]
                if mem.mem.base in lui_vals:
                    disp=mem.mem.disp
                    addr=(lui_vals[mem.mem.base]<<16)+disp & 0xFFFFFFFF
                    if addr in strs and strs[addr] not in srefs: srefs.append(strs[addr])
            if m=='jal':
                t=jtarget(a,w)
                if inr(t): callees_in.append(t)
                elif t in main: callees_main.append(f"{main[t]}({hex(t)})")
                else: callees_main.append(hex(t))
            if m=='jalr':
                # look back for lw $rx, NN($ry) with small NN
                for b in range(a-16, a, 4):
                    bi=get(b)
                    if bi and bi.mnemonic=='lw' and len(bi.operands)>=2 and bi.operands[1].type==3:
                        if 0 <= bi.operands[1].mem.disp < 0x1000 and bi.operands[0].reg==ops[0].reg:
                            vtoff.add(bi.operands[1].mem.disp)
            a+=4
        # absolute word pointers to strings
        for k in range((e-s)//4):
            w=words[off(s)//4+k]
            if w in strs and strs[w] not in srefs: srefs.append(strs[w])
        out.write(f"{hex(s)} size={size} calls_in={[hex(c) for c in callees_in[:8]]} main={callees_main[:8]} vtable={sorted(vtoff)} str={[x[:44] for x in srefs[:4]]}\n")
        # disassembly file
        with open(os.path.join(outdir, f"func_{s:08x}.txt"),'w') as f:
            for a in addrs:
                ins=get(a)
                f.write(f"{hex(a)} {ins.mnemonic:8s} {ins.op_str}\n")
    out.write("\n== string table (printable >=4, addrs)\n")
    for a in sorted(strs):
        out.write(f"{hex(a)} {strs[a][:100]}\n")
print("wrote", outdir, "funcs:", len(real))
