#!/usr/bin/env python3
"""Overlay labeling workhorse: base verification, function boundaries (prologue +
jr-ra), per-function callees/string refs, string table, LZSS-shape scan.
Usage: ovl_analyze.py <bin> <base_hex> [--detail]"""
import sys, struct, csv, re
from collections import Counter
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

path, base_s = sys.argv[1], sys.argv[2]
detail = '--detail' in sys.argv
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
# decode word-by-word: file starts with data (dispatch tables), so the
# streaming disassembler would stall on the first non-insn word
for o in range(0, len(data)-3, 4):
    try:
        for ins in md.disasm(data[o:o+4], base+o):
            insns[ins.address] = ins
            break
    except Exception:
        pass
def get(a): return insns.get(a)

# ---- base verification: code-region j-target histogram ----
jt = Counter()
for i,w in enumerate(words):
    op = w>>26
    if op in (2,3):
        t = (base & 0xF0000000) | ((w & 0x3FFFFFF)<<2)
        if inr(t): jt[t>>12]+=1
print("== base check:", path, "base", hex(base), "size", len(raw))
print("   in-seg j/jal targets:", sum(jt.values()), "top pages:", [(hex(k<<12),c) for k,c in jt.most_common(5)])

# ---- strings ----
strs = {}
i=0
while i < len(data):
    if 32 <= data[i] < 127:
        j=i
        while j < len(data) and 32 <= data[j] < 127: j+=1
        if j < len(data) and data[j]==0 and j-i >= 4:
            strs[va(i)] = data[i:j].decode('ascii', 'replace')
        i=j
    i+=1
saddr = set(strs)
print("== strings:", len(strs))

# ---- seeds ----
seeds=set()
for i,w in enumerate(words):
    if (w>>26)==9:
        rs,rt=(w>>21)&31,(w>>16)&31
        imm=(w&0xFFFF)-0x10000 if w&0x8000 else w&0xFFFF
        if rs==29 and rt==29 and imm<0 and -imm%8==0 and -imm<0x2000:
            seeds.add(va(i*4))
jal_targets=set()
for i,w in enumerate(words):
    op=w>>26
    if op==3:
        t=(base&0xF0000000)|((w&0x3FFFFFF)<<2)
        if inr(t) and t%4==0: jal_targets.add(t)
for t in jal_targets: seeds.add(t)
sseeds=sorted(seeds)
print("== raw seeds:", len(sseeds), "(prologues + jal targets)")

# ---- boundary analysis: walk each seed to jr $ra / j / next seed ----
JRRA=0x03E00008
def insn_word(a):
    o=off(a)
    return words[o//4] if 0<=o<len(data)-3 else None
funcs=[]  # (start,end_exclusive)
for si,s in enumerate(sseeds):
    nxt = sseeds[si+1] if si+1<len(sseeds) else base+len(data)
    a=s; end=None
    while a < nxt:
        w=insn_word(a)
        if w is None: break
        ins=get(a)
        if ins is None: break
        if w==JRRA: end=a+8; break
        op=w>>26
        if op==2: end=a+8; break  # unconditional j: tail call, stop here
        m=ins.mnemonic
        if m=='jr' and 'ra' not in ins.op_str:
            # jr $rx non-ra: computed jump; stop block
            end=a+8; break
        a+=4
    if end is None: end=min(nxt, s+4)
    if end<=s: end=s+4
    funcs.append((s,end))

# merge overlaps: drop seeds contained in an earlier function's span
funcs.sort()
merged=[]
for s,e in funcs:
    if merged and s < merged[-1][1]:
        # contained or overlapping: keep earlier, extend if needed
        if e > merged[-1][1]: merged[-1]=(merged[-1][0],e)
    else:
        merged.append((s,e))
print("== functions after merge:", len(merged))

# MAIN.EXE labels
main={}
try:
    with open('/home/hatch/workspace/suikoden/kit/work/function_labels.csv') as f:
        for r in csv.DictReader(f):
            try: main[int(r['address'],16)]=(r['name'],r.get('role',''))
            except: pass
except Exception as e: print("   no main labels:", e)

def jtarget(a,w): return ((a+4)&0xF0000000)|((w&0x3FFFFFF)<<2)

print("\n== functions")
for (s,e) in merged:
    size=(e-s)//4
    calls_in=0; calls_main=[]
    str_refs=[]
    a=s
    while a<e:
        w=insn_word(a); ins=get(a)
        if w is None or ins is None: break
        op=w>>26
        if op==3:
            t=jtarget(a,w)
            if inr(t): calls_in+=1
            elif t in main: calls_main.append(main[t][0])
            elif 0x800C0800<=t<0x80180000: calls_main.append(hex(t)+'?')
        if (w>>26)==0x0F:  # lui: check if loads a string address
            hi=w&0xFFFF
            for sa in saddr:
                if (sa>>16)==hi:
                    str_refs.append(strs[sa][:38]); break
        a+=4
    # absolute word pointers to strings inside body
    for k in range((e-s)//4):
        w=words[off(s)//4+k]
        if w in saddr and strs[w][:38] not in str_refs:
            str_refs.append(strs[w][:38])
    tag=''
    print(f"  {hex(s)} size={size:4d} calls_in={calls_in:3d} main=[{','.join(calls_main[:6])}] str={str_refs[:3]}")

if detail:
    print("\n== string table")
    for a in sorted(strs):
        print(f"  {hex(a)} {strs[a][:90]}")

# ---- decompressor quarry: LZSS/bit-reader shape scan ----
print("\n== decompressor quarry scan")
for (s,e) in merged:
    score=[]; body=[]
    a=s
    while a<e:
        ins=get(a)
        if ins: body.append((a,ins.mnemonic,ins.op_str))
        a+=4
    mnems=[m for _,m,_ in body]
    # flag-bit loop: srl/sll + andi 1 + beq/bne tight
    has_shift_bit = any(m in ('srl','sll','sra') for m in mnems) and any('andi'==m for m in mnems)
    # match copy loop: lb/lbu + sb in a loop (branch backward)
    lbs=sum(1 for m in mnems if m in ('lb','lbu'))
    sbs=sum(1 for m in mnems if m=='sb')
    # window mask 0xfff / 0x1000 / 4096 consts
    win=False
    for _,m,op in body:
        if m in ('andi','addiu','ori','sltiu') and ('0xfff' in op or '0x1000' in op or ',4096' in op or ',0xfff' in op):
            win=True; break
    # loop count: backward branches
    back=0
    for k,(a,m,op) in enumerate(body):
        if m in ('bne','beq','blez','bgtz','bltz','bgez'):
            # crude: branch to earlier address?
            back+=1
    if (has_shift_bit and lbs>=1 and sbs>=1) or (win and lbs>=1 and sbs>=1) or (lbs>=3 and sbs>=2 and back>=3):
        print(f"  CANDIDATE {hex(s)} size={(e-s)//4} shiftbit={has_shift_bit} lb={lbs} sb={sbs} winmask={win} branches={back}")
