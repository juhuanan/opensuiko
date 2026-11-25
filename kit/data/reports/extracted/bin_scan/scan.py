import os, glob, struct, json, re
from collections import defaultdict
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

ROOT='/home/hatch/workspace/suikoden/kit/extracted/bin_overlays'
cs = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
TAG_IMMS = {0x200,0x201,0x20c,0x247,0x248}
imm_re = re.compile(r'(0x[0-9a-fA-F]+)|(-\d+)')

def imms(opstr):
    out=[]
    for m in imm_re.finditer(opstr):
        s=m.group(0)
        out.append(int(s,16) if s.startswith('0x') else int(s))
    return out

inv = json.load(open('/home/hatch/workspace/suikoden/kit/extracted/bin_overlay_inventory.json'))
results=[]
for e in inv:
    if e['n27bd']==0: continue
    f=e['file']; path=os.path.join(ROOT,f)
    with open(path,'rb') as fh: data=fh.read()
    for r in e['regions']:
        start=int(r['start'],16); end=int(r['end'],16)
        end=min(end+0x2000, len(data))  # extend a bit past last prologue
        insns=list(cs.disasm(data[start:end], start))
        # per-function split at prologues
        pro=[i.address for i in insns if i.mnemonic=='addiu' and i.op_str.startswith('$sp, $sp, -')]
        bounds=pro+[end]
        for bi in range(len(pro)):
            fs,fe=pro[bi],bounds[bi+1]
            fn=[i for i in insns if fs<=i.address<fe]
            has_lh=any(i.mnemonic in ('lh','lhu') for i in fn)
            has_add16=any(i.mnemonic=='addiu' and re.match(r'^(\$\w+), \1, (0x10|16)$',i.op_str) for i in fn)
            tagrefs=defaultdict(int)
            for i in fn:
                if i.mnemonic in ('slti','sltiu','addiu','addi','andi','ori','subiu','xori'):
                    for v in imms(i.op_str):
                        if (v & 0xffff) in TAG_IMMS: tagrefs[v&0xffff]+=1
            # range-check idiom: sub/add 0x201 then sltiu 0x47/0x48
            has_range = any(i.mnemonic in ('sltiu','slti') and (imms(i.op_str)==[0x47] or imms(i.op_str)==[0x48]) for i in fn)
            score = (2 if has_lh else 0)+(2 if has_add16 else 0)+len(tagrefs)*3+(2 if has_range else 0)
            if score>=3:
                results.append(dict(file=f, func='0x%x'%fs, score=score, lh=has_lh, add16=has_add16,
                    tags={hex(k):v for k,v in tagrefs.items()}, range=has_range, nins=len(fn)))
results.sort(key=lambda r:-r['score'])
json.dump(results, open('/home/hatch/workspace/suikoden/kit/extracted/bin_scan/hits.json','w'), indent=1)
print('candidate functions:', len(results))
for r in results[:40]:
    print(f"score={r['score']} lh={int(r['lh'])} add16={int(r['add16'])} range={int(r['range'])} tags={r['tags']} {r['file']} func@{r['func']} ({r['nins']} insns)")
