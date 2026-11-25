import os, struct, json, re
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
ROOT='/home/hatch/workspace/suikoden/kit/extracted/bin_overlays'
cs = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
TAG_IMMS = {0x200,0x201,0x20c,0x247,0x248,0x249,0x24a}
BR = {'beq','bne','beqz','bnez','blez','bgtz','bltz','bgez','bltzal','bgezal'}
tgt_re = re.compile(r'0x[0-9a-fA-F]+')
def last_imm(opstr):
    toks=[t.strip() for t in opstr.split(',')]
    try: t=toks[-1]; return int(t,16) if t.startswith('0x') else int(t)
    except: return None
def reg_base(opstr, idx):
    toks=[t.strip() for t in opstr.split(',')]
    return toks[idx] if idx < len(toks) else None

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
                # lhu $r, 0($p): offset 0
                lh_regs=[(reg_base(x.op_str,0),reg_base(x.op_str,1)) for x in body
                         if x.mnemonic in ('lh','lhu') and last_imm(x.op_str)==0]
                if not lh_regs: continue
                # addiu $p,$p,0x10 with $p = base reg of an lhu
                p_regs=set(b for _,b in lh_regs if b)
                adv=[x for x in body if x.mnemonic=='addiu' and last_imm(x.op_str)==0x10
                     and reg_base(x.op_str,0)==reg_base(x.op_str,1) and reg_base(x.op_str,0) in p_regs]
                if not adv: continue
                tagset=set()
                for x in body:
                    if x.mnemonic in ('slti','sltiu','addiu','addi','andi','ori','xori'):
                        v=last_imm(x.op_str)
                        if v is not None and (v&0xffff) in TAG_IMMS: tagset.add(v&0xffff)
                sll4=any(x.mnemonic=='sll' for x in body)
                nbeq=sum(1 for x in body if x.mnemonic in BR)
                score=6+4*len(tagset)+(2 if sll4 else 0)+min(nbeq,4)
                hits.append(dict(file=f,func='0x%x'%fs,loop='0x%x->0x%x'%(t,i.address),
                    score=score,tags=sorted(hex(v) for v in tagset),sll=sll4,nbeq=nbeq,nins=len(fn)))
hits.sort(key=lambda r:-r['score'])
seen=set(); out=[]
for h in hits:
    k=(h['file'],h['func'],h['loop'])
    if k not in seen: seen.add(k); out.append(h)
json.dump(out, open('/home/hatch/workspace/suikoden/kit/extracted/bin_scan/hits3.json','w'), indent=1)
print('tight candidates:', len(out))
for r in out[:25]:
    print(f"score={r['score']:2d} tags={r['tags']} sll={int(r['sll'])} nbeq={r['nbeq']} nins={r['nins']} {r['file']} func@{r['func']} loop@{r['loop']}")
