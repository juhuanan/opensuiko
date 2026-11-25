import os, struct, json, re
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
ROOT='/home/hatch/workspace/suikoden/kit/extracted/bin_overlays'
cs = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
BR = {'beq','bne','beqz','bnez','blez','bgtz','bltz','bgez','bltzal','bgezal'}
tgt_re = re.compile(r'0x[0-9a-fA-F]+')
def last_imm(opstr):
    toks=[t.strip() for t in opstr.split(',')]
    try: t=toks[-1]; return int(t,16) if t.startswith('0x') else int(t)
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
            for i in fn:
                if i.mnemonic not in BR: continue
                m=tgt_re.findall(i.op_str)
                if not m: continue
                t=int(m[-1],16)
                if not (fs<=t<i.address): continue
                body=[x for x in fn if t<=x.address<=i.address]
                has_lh=any(x.mnemonic in ('lh','lhu') for x in body)
                has_a16=any(x.mnemonic=='addiu' and last_imm(x.op_str)==0x10 for x in body)
                has_call=any(x.mnemonic=='jalr' or (x.mnemonic=='jr' and x.op_str!='$ra') for x in body)
                if has_lh and has_a16 and has_call:
                    # show the lhu/addiu/jalr lines
                    sig=[f"{x.mnemonic} {x.op_str}" for x in body if x.mnemonic in ('lh','lhu','jalr') or (x.mnemonic=='addiu' and last_imm(x.op_str)==0x10)]
                    hits.append(dict(file=f,func='0x%x'%fs,loop='0x%x->0x%x'%(t,i.address),sig=sig[:8],nins=len(fn)))
seen=set(); out=[]
for h in hits:
    k=(h['file'],h['func'],h['loop'])
    if k not in seen: seen.add(k); out.append(h)
json.dump(out, open('/home/hatch/workspace/suikoden/kit/extracted/bin_scan/hits4.json','w'), indent=1)
print('parse+dispatch candidates:', len(out))
for r in out[:20]:
    print(f"{r['file']} func@{r['func']} loop@{r['loop']} nins={r['nins']}")
    for s in r['sig']: print(f'    {s}')
