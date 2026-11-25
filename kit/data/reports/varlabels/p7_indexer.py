import struct, pickle
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

BASE = 0x800C0800
data = open('/home/hatch/workspace/suikoden/MAIN_body.bin','rb').read()
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_LITTLE_ENDIAN)
md.detail = False

REGMAP = {'zero':0,'at':1,'v0':2,'v1':3,'a0':4,'a1':5,'a2':6,'a3':7,
't0':8,'t1':9,'t2':10,'t3':11,'t4':12,'t5':13,'t6':14,'t7':15,
's0':16,'s1':17,'s2':18,'s3':19,'s4':20,'s5':21,'s6':22,'s7':23,
't8':24,'t9':25,'k0':26,'k1':27,'gp':28,'sp':29,'fp':30,'ra':31}
def regnum(r):
    r = r.strip()
    if not r.startswith('$'): return None
    n = r[1:]
    if n.isdigit(): return int(n)
    return REGMAP.get(n)

def s16(v):
    # v from int(s,16): may already be negative ('-0x1234') or unsigned
    if v < 0: return v
    return v - 0x10000 if v & 0x8000 else v

MEM_OPS = {'lw':4,'sw':4,'lh':2,'lhu':2,'sh':2,'lb':1,'lbu':1,'sb':1,
 'lwl':4,'lwr':4,'swl':4,'swr':4,'ll':4,'sc':4}

refs = {}
imap = {}
reg_hi = {}
BRANCH = {'beq','bne','bgez','bgtz','blez','bltz','bgezal','bltzal','bc1t','bc1f',
 'j','jal','jr','jalr','nop','syscall','break','mult','multu','div','divu',
 'mtc0','mtc1','mtc2','ctc0','ctc1','ctc2','swc1','swc2','sdc1','sdc2','lwc1','lwc2','ldc1','ldc2'}
NOWRITE = BRANCH | {'sw','sh','sb','swl','swr','sc'}

off = 0
n_ins = 0
while off + 4 <= len(data):
    chunk = data[off:off+4]
    ins = None
    for i in md.disasm(chunk, BASE+off, count=1):
        ins = i; break
    if ins is None or ins.size != 4:
        off += 4; continue
    n_ins += 1
    mn = ins.mnemonic
    ops = ins.op_str.strip().strip("'")
    imap[ins.address] = (mn, ops)
    parts = [p.strip() for p in ops.split(',')]
    if mn == 'lui' and len(parts) == 2:
        rd = regnum(parts[0])
        try: imm = int(parts[1], 16)
        except: imm = 0
        if rd is not None: reg_hi[rd] = imm
        off += 4; continue
    rd = regnum(parts[0]) if parts else None
    if mn in MEM_OPS and len(parts) >= 2:
        try:
            off_s, rest = parts[1].split('(')
            base = regnum(rest.rstrip(')'))
            o = s16(int(off_s, 16))
        except: base, o = None, 0
        if base is not None and base in reg_hi:
            t = ((reg_hi[base] << 16) + o) & 0xFFFFFFFF
            refs.setdefault(t, []).append({'pc':f"0x{ins.address:08x}",'asm':f"{mn} {ops}",'width':MEM_OPS[mn],'kind':'mem'})
        if rd is not None: reg_hi.pop(rd, None)
        off += 4; continue
    if mn == 'addiu' and len(parts) == 3:
        rs = regnum(parts[1])
        try: imm = int(parts[2], 16)
        except: imm = 0
        if rs is not None and rs in reg_hi:
            t = ((reg_hi[rs] << 16) + s16(imm)) & 0xFFFFFFFF
            refs.setdefault(t, []).append({'pc':f"0x{ins.address:08x}",'asm':f"{mn} {ops}",'width':0,'kind':'lea'})
        if rd is not None: reg_hi.pop(rd, None)
        off += 4; continue
    if mn not in NOWRITE and rd is not None:
        reg_hi.pop(rd, None)
    off += 4

print("insns:", n_ins, "targets:", len(refs))
pickle.dump(refs, open('/tmp/p7/refs.pkl','wb'))
pickle.dump(imap, open('/tmp/p7/insns.pkl','wb'))
