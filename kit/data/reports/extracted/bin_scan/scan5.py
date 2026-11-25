import os, struct, json, re
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
ROOT='/home/hatch/workspace/suikoden/kit/extracted/bin_overlays'
cs = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
inv = json.load(open('/home/hatch/workspace/suikoden/kit/extracted/bin_overlay_inventory.json'))
hits=[]
for e in inv:
    if e['n27bd']==0: continue
    f=e['file']; data=open(os.path.join(ROOT,f),'rb').read()
    for r in e['regions']:
        start=int(r['start'],16); end=min(int(r['end'],16)+0x2000, len(data))
        insns=list(cs.disasm(data[start:end], start))
        for idx,i in enumerate(insns):
            if i.mnemonic=='jr' and i.op_str!='$ra':
                jr_reg=i.op_str
                prev=insns[max(0,idx-25):idx]
                pm=[p.mnemonic for p in prev]
                has_lh=any(p.mnemonic in ('lh','lhu') for p in prev)
                has_sll=any(p.mnemonic=='sll' for p in prev)
                has_lw=any(p.mnemonic=='lw' for p in prev)
                has_addu=any(p.mnemonic=='addu' for p in prev)
                # computed jump via table: lw->jr or sll+addu+lw+jr
                if has_lw and (has_sll or has_addu):
                    ctx=[f"0x{p.address:x}: {p.mnemonic} {p.op_str}" for p in prev[-12:]]
                    hits.append(dict(file=f, jr_at='0x%x'%i.address, reg=jr_reg,
                        lh=has_lh, sll=has_sll, ctx=ctx))
json.dump(hits, open('/home/hatch/workspace/suikoden/kit/extracted/bin_scan/hits5.json','w'), indent=1)
print('computed-jump candidates:', len(hits))
# group by file
from collections import Counter
c=Counter(h['file'] for h in hits)
for f,n in c.most_common(15): print(f'{n:4d} {f}')
