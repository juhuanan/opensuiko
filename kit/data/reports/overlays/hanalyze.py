#!/usr/bin/env python3
"""Analyze individual handler functions (table entries) in an overlay.
Usage: hanalyze.py <bin> <base> <addr1> [addr2 ...]
For each addr: disassembles until j/jr, reports jal targets, ext calls, string refs."""
import sys, struct, csv
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
path, base_s = sys.argv[1], sys.argv[2]
addrs = [int(x,16) for x in sys.argv[3:]]
base = int(base_s, 16)
data = open(path, 'rb').read()
words = struct.unpack('<%dI' % (len(data)//4), data)
def va(o): return base+o
def off(a): return a-base
def in_range(a): return base <= a < base+len(data)
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32|CS_MODE_LITTLE_ENDIAN)
md.detail=True
_insn_cache={}
def get(a):
    if a in _insn_cache: return _insn_cache[a]
    o=a-base; ins=None
    if 0<=o<=len(data)-4:
        for i in md.disasm(data[o:o+4], a):
            ins=i; break
    _insn_cache[a]=ins
    return ins
def jtarget(a,w): return ((a+4)&0xF0000000)|((w&0x3FFFFFF)<<2)
main={}
try:
    with open('/home/hatch/workspace/suikoden/kit/work/function_labels.csv') as f:
        for r in csv.DictReader(f):
            try: main[int(r['address'],16)]=(r['name'],r['role'])
            except: pass
except: pass
# strings (allow \n)
strs={}
def _ok(c): return 32<=c<127 or c in (9,10,13)
i=0
while i < len(data):
    if _ok(data[i]):
        j=i
        while j < len(data) and _ok(data[j]): j+=1
        if j < len(data) and data[j]==0 and j-i>=4: strs[va(i)]=data[i:j].decode()
        i=j
    i+=1
for entry in addrs:
    print("="*80); print("HANDLER", hex(entry))
    body=[]; a=entry; seen=set()
    for _ in range(2000):
        if a in seen or not in_range(a): break
        ins=get(a)
        if ins is None: break
        seen.add(a); body.append(a)
        w=words[off(a)//4]; op=w>>26; m=ins.mnemonic
        if m in ('jr',): a+=4; break
        if op==2: break  # j (tail jump)
        if op==3: a+=8; continue
        if m in ('beq','bne','bnez','beqz','bgez','bgtz','blez','bltz'):
            imm=w&0xFFFF; imm-=0x10000 if imm&0x8000 else 0
            t=a+4+(imm<<2)
            # follow fallthrough only; note branch target
            a+=4; continue
        a+=4
    # analyze body
    vals={}
    for a in body:
        ins=get(a); w=words[off(a)//4]; op=w>>26; m=ins.mnemonic
        rs=(w>>21)&31; rt=(w>>16)&31; imm=w&0xFFFF
        simm=imm-0x10000 if imm&0x8000 else imm
        if m=='lui': vals[rt]=imm<<16
        elif m in ('addiu','addi') and rs in vals: vals[rt]=(vals[rs]+simm)&0xFFFFFFFF
        elif m=='ori' and rs in vals: vals[rt]=(vals[rs]|imm)&0xFFFFFFFF
        elif m in ('lw','sw','lbu','sb','lh','sh') and rs in vals:
            addr=(vals[rs]+simm)&0xFFFFFFFF
            if addr in strs: print("  str ref @%s: %r" % (hex(a), strs[addr][:60]))
        if op==3:
            t=jtarget(a,w)
            nm=main.get(t)
            if in_range(t): print("  jal @%s -> %s (internal)" % (hex(a), hex(t)))
            else: print("  jal @%s -> %s %s" % (hex(a), hex(t), nm[0] if nm else '(unlabeled MAIN)'))
    print("  n_insns:", len(body))
