import os, struct, json, re
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
cs = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
ROOT='/home/hatch/workspace/suikoden/kit/extracted/bin_overlays'
def reg_dest(opstr):
    return opstr.split(',')[0].strip()
inv = json.load(open('/home/hatch/workspace/suikoden/kit/extracted/bin_overlay_inventory.json'))
print('=== lhu-driven dispatch candidates ===')
for e in inv:
    if e['n27bd']==0: continue
    f=e['file']; data=open(os.path.join(ROOT,f),'rb').read()
    for r in e['regions']:
        start=int(r['start'],16); end=min(int(r['end'],16)+0x1000, len(data))
        insns=list(cs.disasm(data[start:end], start))
        for idx,i in enumerate(insns):
            if i.mnemonic not in ('lh','lhu'): continue
            rd = reg_dest(i.op_str)
            # look ahead 25 insns for dispatch on rd
            window = insns[idx+1:idx+26]
            found=None
            for j in window:
                ops = j.op_str
                uses_rd = rd in ops.split(',')[1:] if ',' in ops else rd in ops
                if j.mnemonic in ('slti','sltiu') and ops.startswith(rd+','):
                    # check imm in tag-range-ish
                    try:
                        v=int(ops.split(',')[-1].strip(),16)
                        if 0x210<=v<=0x250: found=f'{j.mnemonic} {ops} @0x{j.address:x}'
                    except: pass
                if j.mnemonic=='jr' and rd in ops:
                    found=f'jr {ops} @0x{j.address:x} (direct)'
                if j.mnemonic in ('beq','bne') and rd in ops:
                    # check if comparing to tag-like imm? beq uses regs, skip
                    pass
                if found: break
            if found:
                print(f"  {f} lhu@0x{i.address:x} ({i.op_str}) -> {found}")
