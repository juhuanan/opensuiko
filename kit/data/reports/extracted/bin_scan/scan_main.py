import struct, re
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
cs = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
data = open('/home/hatch/workspace/suikoden/MAIN.EXE','rb').read()
print('MAIN.EXE size:', len(data))
# PS-X EXE has 2048-byte header; code starts at 0x800
code = data[0x800:]
base = 0x800C0800  # load address per task
n=len(code)//4
pro=[]
for i in range(n):
    w=struct.unpack('<I',code[i*4:i*4+4])[0]
    if (w>>16)==0x27bd: pro.append(i*4)
print('prologues in MAIN.EXE:', len(pro))
TAG_IMMS = {0x201,0x20c,0x247,0x248,0x249,0x24a,0x24b,0x24c,0x200}
def last_imm(opstr):
    toks=[t.strip() for t in opstr.split(',')]
    try: t=toks[-1]; return int(t,16) if t.startswith('0x') else int(t)
    except: return None
hits=[]
for bi,p in enumerate(pro):
    end = pro[bi+1] if bi+1 < len(pro) else min(p+0x2000, len(code))
    # cap function length to avoid runaway linear disasm through data
    fend = min(end, p+0x2000)
    insns=list(cs.disasm(code[p:fend], base+p))
    # trim at jr ra
    cut=len(insns)
    for k,i in enumerate(insns):
        if i.mnemonic=='jr' and i.op_str=='$ra': cut=k+2; break
    insns=insns[:cut]
    for i in insns:
        if i.mnemonic in ('slti','sltiu','addiu','addi','andi','ori','xori'):
            v=last_imm(i.op_str)
            if v is not None and (v&0xffff) in TAG_IMMS:
                hits.append((f'0x{i.address:08x}', i.mnemonic, i.op_str, f'func@0x{base+p:08x}'))
print('tag-immediate hits in MAIN.EXE:', len(hits))
for h in hits[:40]: print(' ', h)
