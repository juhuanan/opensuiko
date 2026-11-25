#!/usr/bin/env python3
"""Cross-file function clustering for the 9 WAR scenario overlays + WAR1.
Seeds: prologue scan + dispatch-table slots + jal targets.
Output: JSON with per-file function map {addr: {hash, size, end}} and hash clusters.
Usage: war_cluster.py <outdir>
"""
import sys, struct, json, hashlib
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

BASE = 0x80010000
WAR_DIR = '/home/hatch/workspace/suikoden/kit/extracted/bin_overlays/DATA/16_WAR/'
FILES = ['WAR1.BIN','WAR_GARA.BIN','WAR_KITA.BIN','WAR_KUWA.BIN','WAR_LAST.BIN',
         'WAR_SCA1.BIN','WAR_SCA2.BIN','WAR_SHAS.BIN','WAR_TEO1.BIN','WAR_TEO2.BIN']

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
md.detail = False
md.skipdata = True   # WAR1 starts with ASCII; bulk disasm halts at first invalid word otherwise

def load(fn):
    data = open(WAR_DIR+fn,'rb').read()
    n = len(data)//4
    words = struct.unpack('<%dI'%n, data)
    return data, words
def va(off): return BASE+off
def in_range(a, data): return BASE <= a < BASE+len(data)
def jtarget(a,w): return ((a+4)&0xF0000000)|((w&0x3FFFFFF)<<2)

def table_slots(words, data):
    """Dispatch table: consecutive in-file pointer words from 0x80010000
    (WAR1: strings first, table starts later). Find run of >=8 in-file ptrs."""
    n=len(words); slots=[]
    # find first run of >= 8 consecutive pointer words
    i=0
    while i < n-8:
        run=0; j=i
        while j<n:
            w=words[j]
            if (w&0xFFFF0000)==0x80010000 and (BASE<=w<BASE+len(data)) and w%4==0 and (w-BASE)>0x100:
                run+=1; j+=1
            else: break
        if run>=8:
            return [words[k] for k in range(i,j)], va(i*4)
        i+=1
    return [], None

def find_functions(data, words):
    n=len(words)
    seeds=set()
    for i,w in enumerate(words):
        if (w>>26)==9:
            rs,rt=(w>>21)&31,(w>>16)&31
            imm=(w&0xFFFF)-(0x10000 if w&0x8000 else 0)
            if rs==29 and rt==29 and imm<0 and -imm%8==0 and -imm<0x2000:
                seeds.add(va(i*4))
    slots, tbase = table_slots(words, data)
    for s in slots: seeds.add(s)
    # jal targets (in-file)
    for i,w in enumerate(words):
        if (w>>26)==3:
            t=jtarget(va(i*4),w)
            if in_range(t,data) and t%4==0: seeds.add(t)
    # disassemble all for fast lookup (skipdata: invalid words come through as data)
    insns={}
    for ins in md.disasm(data, BASE):
        if ins.id != 0 and ins.size == 4:
            insns[ins.address]=ins
    def get(a): return insns.get(a)
    func_bodies={}
    visited=set()
    def descend(entry):
        stack=[entry]; seen=set()
        while stack:
            a=stack.pop()
            while True:
                if a in seen or (a in visited and a!=entry): break
                ins=get(a)
                if ins is None: break
                seen.add(a)
                w=words[(a-BASE)//4]; op=w>>26; m=ins.mnemonic
                if m=='jr': break
                if op==2:
                    t=jtarget(a,w)
                    if in_range(t,data) and t not in seen: stack.append(t)
                    break
                if op==3:
                    t=jtarget(a,w)
                    a+=8; continue
                taken=None
                if m in ('beq','bne','beql','bnel','bgez','bgezal','bgtz','blez','bltz','bltzal'):
                    imm=w&0xFFFF; imm-=0x10000 if imm&0x8000 else 0
                    taken=a+4+(imm<<2)
                if taken is not None and in_range(taken,data) and taken not in seen:
                    stack.append(taken)
                a+=4
        return sorted(seen)
    # iterate seeds in order; jal-added seeds appended dynamically
    seedlist=sorted(seeds)
    si=0
    while si < len(seedlist):
        s=seedlist[si]; si+=1
        if s in func_bodies: continue
        b=descend(s)
        if b:
            func_bodies[s]=b
            visited.update(b)
            # add jal targets found inside as seeds
            for a in b:
                w=words[(a-BASE)//4]
                if (w>>26)==3:
                    t=jtarget(a,w)
                    if in_range(t,data) and t%4==0 and t not in func_bodies:
                        if t not in seedlist: seedlist.append(t)
    # hash each body by raw bytes at visited addrs
    result={}
    for s,b in func_bodies.items():
        h=hashlib.sha1()
        for a in b:
            h.update(data[(a-BASE):(a-BASE)+4])
        result[s]={'hash':h.hexdigest()[:16],'n':len(b),'end':b[-1]}
    return result, slots, tbase

outdir=sys.argv[1]
allmap={}
clusters={}  # hash -> [(file,addr)]
for fn in FILES:
    data,words=load(fn)
    fmap,slots,tbase=find_functions(data,words)
    allmap[fn]={'nfuncs':len(fmap),'nslots':len(slots),'tbase':hex(tbase) if tbase else None,
                'funcs':{hex(a):v for a,v in fmap.items()}}
    for a,v in fmap.items():
        clusters.setdefault(v['hash'],[]).append((fn,a))
    print(fn,'funcs:',len(fmap),'slots:',len(slots),'tbase:',hex(tbase) if tbase else None,flush=True)

# cluster stats
shared_all=[h for h,v in clusters.items() if len({f for f,_ in v})==10]
war1_only=[h for h,v in clusters.items() if {f for f,_ in v}=={'WAR1.BIN'}]
scen_only=[h for h,v in clusters.items() if 'WAR1.BIN' not in {f for f,_ in v}]
print('hashes identical in all 10 files:',len(shared_all))
print('hashes only in WAR1:',len(war1_only))
print('hashes in scenarios but not WAR1:',len(scen_only))
for h in sorted(scen_only, key=lambda h: min(a for f,a in clusters[h] if f!='WAR1.BIN')):
    v=clusters[h]
    files=sorted({f for f,_ in v})
    print('  ',h,'nfiles:',len(files),'addrs:',[(f,hex(a)) for f,a in sorted(v)][:4],'...' if len(v)>4 else '')

json.dump({'files':allmap,'clusters':{h:[(f,hex(a)) for f,a in v] for h,v in clusters.items()}},
          open(outdir+'/war_cluster.json','w'), indent=1)
print('wrote',outdir+'/war_cluster.json')
