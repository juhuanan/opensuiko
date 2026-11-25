#!/usr/bin/env python3
"""Annotated per-function dump for overlay blobs."""
import sys, struct, csv
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

path, base_s = sys.argv[1], sys.argv[2]
only = sys.argv[3] if len(sys.argv) > 3 else None
base = int(base_s, 16)
data = open(path, 'rb').read()
words = struct.unpack('<%dI' % (len(data)//4), data)
def va(off): return base + off
def off(a): return a - base
def in_range(a): return base <= a < base + len(data)

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_LITTLE_ENDIAN)
md.detail = True
_insn_cache = {}
def get(a):
    if a in _insn_cache: return _insn_cache[a]
    o = a - base
    ins = None
    if 0 <= o <= len(data) - 4:
        for i in md.disasm(data[o:o+4], a):
            ins = i; break
    _insn_cache[a] = ins
    return ins

# MAIN.EXE label map
main = {}
try:
    with open('/home/hatch/workspace/suikoden/kit/work/function_labels.csv') as f:
        for r in csv.DictReader(f):
            try: main[int(r['address'],16)] = (r['name'], r['role'])
            except: pass
except Exception as e: print("no main labels", e)

# strings
strs = {}
i = 0
while i < len(data):
    if 32 <= data[i] < 127:
        j = i
        while j < len(data) and 32 <= data[j] < 127: j += 1
        if j < len(data) and data[j] == 0 and j - i >= 4:
            strs[va(i)] = data[i:j].decode()
        i = j
    i += 1

# seeds: prologues
seeds = set()
for i, w in enumerate(words):
    if (w >> 26) == 9:
        rs, rt = (w >> 21) & 31, (w >> 16) & 31
        imm = (w & 0xFFFF) - 0x10000 if w & 0x8000 else w & 0xFFFF
        if rs == 29 and rt == 29 and imm < 0 and -imm % 8 == 0 and -imm < 0x2000:
            seeds.add(va(i*4))


def jtarget(a, w): return ((a + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)

func_insns = {}
visited_global = set()
seedlist = sorted(seeds)
def descend(entry):
    stack = [entry]; seen = set(); body = []
    while stack:
        a = stack.pop()
        while True:
            if a in seen or (a in visited_global and a != entry): break
            ins = get(a)
            if ins is None: break
            seen.add(a); body.append(a)
            w = words[off(a)//4]; op = w >> 26; m = ins.mnemonic
            if m == 'jr': break
            if op == 2:
                t = jtarget(a, w)
                if in_range(t) and t not in seen: stack.append(t)
                break
            if op == 3:
                t = jtarget(a, w)
                if in_range(t) and t not in visited_global: seedlist.append(t)
                a += 8; continue
            taken = None
            if m in ('beq','bne','beqz','bnez','bgez','bgezal','bgtz','blez','bltz','bltzal','beql','bnel','bc1t','bc1f'):
                imm = w & 0xFFFF; imm -= 0x10000 if imm & 0x8000 else 0
                taken = a + 4 + (imm << 2)
            if taken is not None and in_range(taken) and taken not in seen:
                stack.append(taken)
            a += 4
    return sorted(seen)

for s in seedlist:
    b = descend(s)
    if b:
        if s not in func_insns:
            func_insns[s] = b
            visited_global.update(b)
        # else: seed absorbed into earlier function; skip

REGS = ['zero','at','v0','v1','a0','a1','a2','a3','t0','t1','t2','t3','t4','t5','t6','t7','s0','s1','s2','s3','s4','s5','s6','s7','t8','t9','k0','k1','gp','sp','fp','ra']

def analyze(f, body):
    refs = set()      # data addresses referenced
    vtable_calls = [] # (addr, offset)
    ext_calls = []    # (addr, target)
    int_calls = []
    lui801b = False
    vtregs = {}       # reg -> True if holds vtable pointer (loaded via offset 7108)
    for a in body:
        ins = get(a); w = words[off(a)//4]; op = w >> 26
        m = ins.mnemonic
        # track vtable base loads: lw $rx, 7108($ry)
        if m == 'lw':
            rs = (w>>21)&31; rt=(w>>16)&31; imm=(w&0xFFFF)-(0x10000 if w&0x8000 else 0)
            if imm == 7108: vtregs[rt] = a
            if rs in vtregs:
                vtable_calls.append((a, imm))
                del vtregs[rs]
        if m == 'jalr':
            pass
        if op == 3:
            t = jtarget(a, w)
            if in_range(t): int_calls.append((a,t))
            else:
                nm = main.get(t)
                ext_calls.append((a, t, nm[0] if nm else None))
    # second pass: constant tracking for string refs
    vals = {}
    for a in body:
        ins = get(a); w = words[off(a)//4]; op = w >> 26
        rs=(w>>21)&31; rt=(w>>16)&31; rd=(w>>11)&31; imm=w&0xFFFF
        simm = imm-0x10000 if imm&0x8000 else imm
        m = ins.mnemonic
        def val(r): return vals.get(r)
        if m == 'lui': vals[rt] = imm << 16
        elif m in ('addiu','addi'):
            vals[rt] = (vals[rs]+simm)&0xFFFFFFFF if rs in vals else None
            if vals[rt] is None: vals.pop(rt,None)
        elif m == 'ori':
            vals[rt] = (vals[rs]|imm)&0xFFFFFFFF if rs in vals else None
            if vals[rt] is None: vals.pop(rt,None)
        elif m in ('addu','add','subu','sub','and_','or','xor','nor','sll','srl','sra','mult','div','mflo','mfhi','lui'):
            pass
        # memory operand with known base
        if m in ('lw','sw','lbu','sb','lh','sh','lhu','lwc1','swc1'):
            b = vals.get(rs)
            if b is not None:
                addr = (b + simm) & 0xFFFFFFFF
                if in_range(addr) or addr in strs: refs.add(addr)
            if rs in vals: pass
        # invalidate on other writes
        if ins.op_str:
            pass
        # crude: any GPR write not tracked above kills value
        written = set()
        try:
            for o in ins.operands:
                if o.type == 2 and o.access & 2: written.add(o.reg)
        except: pass
        for r in written:
            rn = REGS[r] if r < 32 else None
            if m not in ('lui','addiu','addi','ori') and r in vals:
                del vals[r]
        if 0x801B0000 <= (vals.get(rs) or 0) < 0x801C0000: lui801b = True
    for r,v in vals.items():
        if v is not None and 0x801B0000 <= v < 0x801C0000: lui801b = True
    return refs, vtable_calls, ext_calls, int_calls, lui801b

for f in sorted(func_insns):
    if only and only not in hex(f): continue
    body = func_insns[f]
    refs, vtc, extc, intc, gs = analyze(f, body)
    print("="*100)
    print("FUNC", hex(f), "n=", len(body), "end=", hex(body[-1]), "gamestate_ref" if gs else "")
    if vtc: print("  vtable calls:", sorted(set(o for _,o in vtc)))
    if extc:
        for a,t,nm in extc[:12]:
            print("  ext call @%s -> %s %s" % (hex(a), hex(t), nm or '(unlabeled MAIN.EXE)'))
    if intc: print("  int calls:", [hex(t) for _,t in intc][:12])
    srefs = sorted(a for a in refs if a in strs)
    if srefs:
        for a in srefs[:10]: print("  str @%s: %r" % (hex(a), strs[a][:60]))
    drefs = sorted(a for a in refs if a not in strs)
    if drefs: print("  data refs:", [hex(a) for a in drefs[:12]])
    print()
    for a in body:
        ins = get(a)
        print("  %s  %-28s %s" % (hex(a), ins.mnemonic+' '+ins.op_str, ''))
    print()
