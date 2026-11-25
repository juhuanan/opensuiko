#!/usr/bin/env python3
"""MIPS-I (R3000) disassembler + overlay function analysis. Static only."""
import struct, sys, hashlib
from collections import Counter

REGS = ['zero','at','v0','v1','a0','a1','a2','a3','t0','t1','t2','t3','t4','t5',
        't6','t7','s0','s1','s2','s3','s4','s5','s6','s7','t8','t9','k0','k1',
        'gp','sp','fp','ra']

def sx16(v): return v - 0x10000 if v & 0x8000 else v

class Insn:
    __slots__=('w','op','rs','rt','rd','sh','fn','imm','tgt','txt','code')
    def __init__(s,w): s.w=w

def dis(w):
    i=Insn(w)
    op=(w>>26)&0x3F; i.op=op
    i.rs=(w>>21)&0x1F; i.rt=(w>>16)&0x1F; i.rd=(w>>11)&0x1F
    i.sh=(w>>6)&0x1F; i.fn=w&0x3F; i.imm=w&0xFFFF; i.tgt=w&0x3FFFFFF
    i.code=(w>>6)&0xFFFFF
    R=lambda r:'$'+REGS[r]
    if op==0:
        f=i.fn
        if f==0: t=f'sll {R(i.rd)},{R(i.rt)},{i.sh}' if i.rd or i.rt or i.sh else 'nop'
        elif f==2: t=f'srl {R(i.rd)},{R(i.rt)},{i.sh}'
        elif f==3: t=f'sra {R(i.rd)},{R(i.rt)},{i.sh}'
        elif f==4: t=f'sllv {R(i.rd)},{R(i.rt)},{R(i.rs)}'
        elif f==6: t=f'srlv {R(i.rd)},{R(i.rt)},{R(i.rs)}'
        elif f==7: t=f'srav {R(i.rd)},{R(i.rs)},{R(i.rt)}'
        elif f==8: t=f'jr {R(i.rs)}'
        elif f==9: t=f'jalr {R(i.rs)}' if i.rd==31 else f'jalr {R(i.rd)},{R(i.rs)}'
        elif f==12: t=f'syscall'
        elif f==13: t=f'break'
        elif f==16: t=f'mfhi {R(i.rd)}'
        elif f==17: t=f'mthi {R(i.rs)}'
        elif f==18: t=f'mflo {R(i.rd)}'
        elif f==19: t=f'mtlo {R(i.rs)}'
        elif f==24: t=f'mult {R(i.rs)},{R(i.rt)}'
        elif f==25: t=f'multu {R(i.rs)},{R(i.rt)}'
        elif f==26: t=f'div {R(i.rs)},{R(i.rt)}'
        elif f==27: t=f'divu {R(i.rs)},{R(i.rt)}'
        elif f==32: t=f'add {R(i.rd)},{R(i.rs)},{R(i.rt)}'
        elif f==33: t=f'addu {R(i.rd)},{R(i.rs)},{R(i.rt)}'
        elif f==34: t=f'sub {R(i.rd)},{R(i.rs)},{R(i.rt)}'
        elif f==35: t=f'subu {R(i.rd)},{R(i.rs)},{R(i.rt)}'
        elif f==36: t=f'and {R(i.rd)},{R(i.rs)},{R(i.rt)}'
        elif f==37: t=f'or {R(i.rd)},{R(i.rs)},{R(i.rt)}'
        elif f==38: t=f'xor {R(i.rd)},{R(i.rs)},{R(i.rt)}'
        elif f==39: t=f'nor {R(i.rd)},{R(i.rs)},{R(i.rt)}'
        elif f==42: t=f'slt {R(i.rd)},{R(i.rs)},{R(i.rt)}'
        elif f==43: t=f'sltu {R(i.rd)},{R(i.rs)},{R(i.rt)}'
        else: t=f'.fn_{f:02x}'
        i.txt=t
    elif op==2: t='j'
    elif op==3: t='jal'
    elif op==4: t=f'beq {R(i.rs)},{R(i.rt)}'
    elif op==5: t=f'bne {R(i.rs)},{R(i.rt)}'
    elif op==6: t=f'blez {R(i.rs)}'
    elif op==7: t=f'bgtz {R(i.rs)}'
    elif op==1:
        b={0:'bltz',1:'bgez',16:'bltzal',17:'bgezal'}; t=f"{b.get(i.rt,'bcond?')} {R(i.rs)}"
    elif op in (8,9,10,11,12,13,14,15):
        n={8:'addi',9:'addiu',10:'slti',11:'sltiu',12:'andi',13:'ori',14:'xori',15:'lui'}[op]
        if op==15: t=f'lui {R(i.rt)},0x{i.imm:04x}'
        else: t=f'{n} {R(i.rt)},{R(i.rs)},{sx16(i.imm) if op<12 else i.imm:#x}'
    elif op==16: t='cop0_op'
    elif op==17: t='cop1_op'
    elif op==18: t='cop2_op'
    elif op==19: t='cop3_op'
    elif op in (32,33,34,35,36,37,38):
        n={32:'lb',33:'lh',34:'lwl',35:'lw',36:'lbu',37:'lhu',38:'lwr'}[op]
        t=f'{n} {R(i.rt)},{sx16(i.imm)}({R(i.rs)})'
    elif op in (40,41,42,43,46):
        n={40:'sb',41:'sh',42:'swl',43:'sw',46:'swr'}[op]
        t=f'{n} {R(i.rt)},{sx16(i.imm)}({R(i.rs)})'
    elif op in (49,50,57,58):
        n={49:'lwc1',50:'lwc2',57:'swc1',58:'swc2'}[op]
        t=f'{n} {R(i.rt)},{sx16(i.imm)}({R(i.rs)})'
    else: t=f'.op_{op:02x}'
    i.txt=t
    return i

def load(path):
    data=open(path,'rb').read(); n=len(data)//4
    return data,[struct.unpack('<I',data[j*4:j*4+4])[0] for j in range(n)]

def jaddr(base,k,w): return ((base+(k*4)+4)&0xF0000000)|((w&0x3FFFFFF)<<2)
def brtarget(base,k,w): return base+(k*4)+4+(sx16(w&0xFFFF)<<2)

def find_table(data, base):
    n=len(data)//4; words=struct.unpack('<%dI'%(n), data[:n*4]); flen=len(data)
    tab=[]
    for j,w in enumerate(words):
        if 0x80010000<=w<base+flen and (w&3)==0: tab.append((base+j*4,w))
        else: break
    return tab

def get_funcs(path, base):
    data,words=load(path); n=len(words); ins=[dis(w) for w in words]; flen=len(data)
    def incode(a): return base<=a<base+flen and (a&3)==0
    tab=find_table(data,base)
    seeds=set(t[1] for t in tab)
    for k,i in enumerate(ins):
        if i.op==3:
            a=jaddr(base,k,words[k])
            if incode(a): seeds.add(a)
    visited=set(); funcs={}
    for s in sorted(seeds):
        k0=(s-base)//4
        if k0 in visited: continue
        seen=set(); stack=[s]
        while stack:
            a=stack.pop()
            while True:
                if not incode(a): break
                k=(a-base)//4
                if k in visited or k in seen: break
                seen.add(k); visited.add(k)
                i=ins[k]; w=words[k]
                if i.op==2:
                    t=jaddr(base,k,w)
                    if incode(t) and t not in seeds: stack.append(t)
                    break
                elif i.op in (4,5,6,7,1):
                    t=brtarget(base,k,w)
                    if incode(t) and t not in seeds: stack.append(t)
                elif i.op==0 and i.fn==8: break
                a+=4
        funcs[s]=seen
    return data,words,ins,tab,funcs

def dump(path, base, start, ninsn, fh=sys.stdout):
    data,words=load(path); n=len(words)
    k0=(start-base)//4
    for k in range(k0, min(k0+ninsn, n)):
        w=words[k]; i=dis(w); extra=''
        if i.op==2 or i.op==3:
            t=((base+(k*4)+4)&0xF0000000)|((w&0x3FFFFFF)<<2); extra=' -> 0x%08x'%t
        elif i.op in (4,5,6,7,1):
            t=base+(k*4)+4+(sx16(w&0xFFFF)<<2); extra=' -> 0x%08x'%t
        fh.write('0x%08x %08x %s%s\n'%(base+k*4, w, i.txt, extra))

def sym_run(base, words, ins, seen):
    """Symbolic lui/ori tracker over sorted word indexes. Returns (calls, data_refs, imms)."""
    vals={}; calls=[]; refs=set(); imms=set()
    for k in sorted(seen):
        w=words[k]; i=ins[k]; op=i.op
        if op==15: vals[i.rt]=(i.imm<<16)
        elif op==13:
            bv=vals.get(i.rs); vals[i.rt]=((bv&0xFFFF0000)|i.imm) if bv is not None else None
        elif op in (8,9):
            bv=vals.get(i.rs); vals[i.rt]=(bv+sx16(i.imm))&0xFFFFFFFF if bv is not None else None
        elif op==0 and i.fn==33:
            a,b2=vals.get(i.rs),vals.get(i.rt)
            vals[i.rd]=(a+b2)&0xFFFFFFFF if a is not None and b2 is not None else None
        elif op==0 and i.fn==37:
            a,b2=vals.get(i.rs),vals.get(i.rt)
            vals[i.rd]=(a|b2) if a is not None and b2 is not None else None
        elif op==0 and i.fn==9:
            t=vals.get(i.rs)
            if t is not None: calls.append(('jalr',t))
            vals[i.rd]=None
        elif op==3:
            calls.append(('jal', jaddr(base,k,w)))
        elif op in (32,33,35,36,37,40,41,43):
            bv=vals.get(i.rs)
            if bv is not None: refs.add((bv+sx16(i.imm))&0xFFFFFFFF)
            if op in (32,33,35,36,37): vals[i.rt]=None
        elif op in (12,13,14) and i.imm not in (0,1): imms.add(i.imm)
        elif op in (10,11): imms.add(sx16(i.imm)&0xFFFF)
        elif op==0 and i.fn in (0,2,3) and i.sh: imms.add(i.sh)
    return calls, refs, imms
