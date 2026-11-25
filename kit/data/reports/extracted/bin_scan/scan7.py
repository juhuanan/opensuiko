import os, struct, json
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
cs = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
ROOT='/home/hatch/workspace/suikoden/kit/extracted/bin_overlays'
def last_imm(opstr):
    toks=[t.strip() for t in opstr.split(',')]
    try: t=toks[-1]; return int(t,16) if t.startswith('0x') else int(t)
    except: return None
def sext16(v): return v-0x10000 if v&0x8000 else v
inv = json.load(open('/home/hatch/workspace/suikoden/kit/extracted/bin_overlay_inventory.json'))
targets = {'bins': [], 'main': []}
# scan BINs
for e in inv:
    if e['n27bd']==0: continue
    f=e['file']; data=open(os.path.join(ROOT,f),'rb').read()
    for r in e['regions']:
        start=int(r['start'],16); end=min(int(r['end'],16)+0x2000, len(data))
        for i in cs.disasm(data[start:end], start):
            v=last_imm(i.op_str)
            if v is None: continue
            sv = sext16(v & 0xffff)
            # tag-0x201 normalization, or bounds 0x24c/0x24d/76
            if i.mnemonic in ('addiu','addi','subiu','subi') and sv==-0x201:
                targets['bins'].append((f, f'0x{i.address:x}', i.mnemonic, i.op_str))
            if i.mnemonic in ('slti','sltiu') and v in (0x24c,0x24d,0x4c,76,0x4d):
                targets['bins'].append((f, f'0x{i.address:x}', i.mnemonic, i.op_str))
# scan MAIN.EXE
mdata=open('/home/hatch/workspace/suikoden/MAIN.EXE','rb').read()[0x800:]
for i in cs.disasm(mdata, 0x800C0800):
    v=last_imm(i.op_str)
    if v is None: continue
    sv = sext16(v & 0xffff)
    if i.mnemonic in ('addiu','addi') and sv==-0x201:
        targets['main'].append((f'0x{i.address:08x}', i.mnemonic, i.op_str))
    if i.mnemonic in ('slti','sltiu') and v in (0x24c,0x24d,0x4c,76,0x4d):
        targets['main'].append((f'0x{i.address:08x}', i.mnemonic, i.op_str))
print('BIN norm/bounds hits:', len(targets['bins']))
for t in targets['bins'][:20]: print('  ', t)
print('MAIN norm/bounds hits:', len(targets['main']))
for t in targets['main'][:20]: print('  ', t)
