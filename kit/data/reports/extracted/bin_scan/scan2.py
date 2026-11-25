import os, struct, json, re
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
ROOT='/home/hatch/workspace/suikoden/kit/extracted/bin_overlays'
cs = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
TAG_IMMS = {0x200,0x201,0x20c,0x247,0x248,0x249,0x24a}
BR = {'beq','bne','beqz','bnez','blez','bgtz','bltz','bgez','bltzal','bgezal','bc1t','bc1f'}
tgt_re = re.compile(r'0x[0-9a-fA-F]+')
imm_re = re.compile(r'(?:^|, )(0x[0-9a-fA-F]+|-\d+|\d+)$')

def last_imm(opstr):
    toks=[t.strip() for t in opstr.split(',')]
    if not toks: return None
    t=toks[-1]
    try: return int(t,16) if t.startswith('0x') else int(t)
    except: return None

inv = json.load(open('/home/hatch/workspace/suikoden/kit/extracted/bin_overlay_inventory.json'))
hits=[]
for e in inv:
    if e['n27bd']==0: continue
    f=e['file']; data=open(os.path.join(ROOT,f),'rb').read()
    for r in e['regions']:
        start=int(r['start'],16); end=min(int(r['end'],16)+0x2000, len(data))
        insns=list(cs.disasm(data[start:end], start))
        pro=[i.address for i in insns if i.mnemonic=='addiu' and i.op_str.startswith('$sp, $sp, -')]
        bounds=pro+[end]
        for bi in range(len(pro)):
            fs,fe=pro[bi],bounds[bi+1]
            fn=[i for i in insns if fs<=i.address<fe]
            # find loops: backward branches
            loops=[]
            for i in fn:
                if i.mnemonic in BR:
                    m=tgt_re.findall(i.op_str)
                    if m:
                        t=int(m[-1],16)
                        if fs<=t<i.address: loops.append((t,i.address))
            for lt,lb in loops:
                body=[i for i in fn if lt<=i.address<=lb]
                has_lh=any(i.mnemonic in ('lh','lhu') for i in body)
                has_a16=any(i.mnemonic=='addiu' and last_imm(i.op_str)==0x10 for i in body)
                tagset=set()
                for i in body:
                    if i.mnemonic in ('slti','sltiu','addiu','addi','andi','ori','xori','subiu'):
                        v=last_imm(i.op_str)
                        if v is not None and (v&0xffff) in TAG_IMMS: tagset.add(v&0xffff)
                # range check 0x47/0x48 with nearby 0x201-ish subtract
                has_rng=any(i.mnemonic in ('sltiu','slti') and last_imm(i.op_str) in (0x47,0x48,0x49,0x4a) for i in body)
                score=(3 if has_lh else 0)+(3 if has_a16 else 0)+4*len(tagset)+(2 if has_rng else 0)
                if score>=6:
                    hits.append(dict(file=f,func='0x%x'%fs,loop='0x%x->0x%x'%(lt,lb),score=score,
                        tags=sorted(hex(t) for t in tagset),rng=has_rng,nins=len(fn)))
hits.sort(key=lambda r:-r['score'])
seen=set(); out=[]
for h in hits:
    k=(h['file'],h['func'],h['loop'])
    if k in seen: continue
    seen.add(k); out.append(h)
json.dump(out, open('/home/hatch/workspace/suikoden/kit/extracted/bin_scan/hits2.json','w'), indent=1)
print('loop-aware candidates:', len(out))
for r in out[:30]:
    print(f"score={r['score']:2d} tags={r['tags']} rng={int(r['rng'])} {r['file']} func@{r['func']} loop@{r['loop']}")
