"""Symbolic sweep of MAIN.EXE for accesses into the struct arrays hanging off
G = *(0x8017BE3C).

A value is `(g, coeffs, const)`:
  g       - 1 when the value contains G (so the access is G-relative)
  coeffs  - {symbol: coefficient}; a symbol is a register whose value the sweep
            cannot know (a function argument or an unclassified load)
  const   - byte constant

All arithmetic is on BYTE offsets; there is no word/byte index ambiguity
anywhere in this file. The trace invalidates a register on every call and on
every writer it does not model, so a hit means "base still live", never a
fabricated constant.
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import rd
from mipsdec import dec

G_ADDR = 0x8017BE3C
LO = 0x800C0800
HI = LO + rd.size()
ACCESS = {0x20:'lb',0x21:'lh',0x22:'lwl',0x23:'lw',0x24:'lbu',0x25:'lhu',0x26:'lwr',
          0x28:'sb',0x29:'sh',0x2A:'swl',0x2B:'sw',0x2E:'swr'}
LOADS = (0x20,0x21,0x22,0x23,0x24,0x25,0x26)
IMMOPS = (0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E)
REGS = ['zero','at','v0','v1','a0','a1','a2','a3','t0','t1','t2','t3','t4','t5','t6','t7',
        's0','s1','s2','s3','s4','s5','s6','s7','t8','t9','k0','k1','gp','sp','fp','ra']

def sx16(v):
    v &= 0xFFFF
    return v-0x10000 if v & 0x8000 else v

def norm(g, c, k):
    c = {s: v for s, v in c.items() if v}
    return (g & 1, c, k & 0xFFFFFFFF)

def addv(a, b, sign=1):
    if a is None or b is None: return None
    g = a[0] | b[0]
    c = dict(a[1])
    for s, v in b[1].items(): c[s] = c.get(s, 0) + sign*v
    return norm(g, c, a[2] + sign*b[2])

def shl(a, sa):
    if a is None: return None
    return norm(a[0], {s: v << sa for s, v in a[1].items()}, a[2] << sa)

def entry_points():
    """Every jal target plus the body start -- the sweep resets register
    knowledge there and seeds the argument registers as unknown symbols."""
    pts = {LO}
    # handler-table entries are reached only through the table, never by jal
    for base in (0x8016BABC, 0x8016BB74):
        i = 0
        while True:
            w = rd.word(base + 4*i)
            if w is None or not (LO <= w < HI): break
            pts.add(w); i += 1
    pc = LO
    while pc < HI:
        w = rd.word(pc)
        if w is None: break
        if (w >> 26) == 0x03:
            pts.add(((pc + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2))
        pc += 4
    return pts

def seed():
    d = {0: norm(0, {}, 0)}                                       # $zero
    d.update({r: norm(0, {f'r{r}': 1}, 0) for r in (4, 5, 6, 7)})  # a0..a3 = unknown
    return d

def sweep():
    entries = entry_points()
    reg = seed()
    reset_next = False
    pc = LO
    while pc < HI:
        w = rd.word(pc)
        if w is None: break
        if pc in entries:
            reg = seed()
        if reset_next:
            reg = seed(); reset_next = False
        s, f = dec(pc, w)
        op, rs, rt, rdv, sa, imm = f['op'], f['rs'], f['rt'], f['rd'], f['sa'], f['imm']
        if op == 0x0F:
            reg[rt] = norm(0, {}, (imm & 0xFFFF) << 16)
        elif op in IMMOPS:
            b = reg.get(rs)
            if b is None:
                reg.pop(rt, None)
            elif op == 0x0D and b[0] == 0 and not b[1]:
                reg[rt] = norm(0, {}, b[2] | (imm & 0xFFFF))
            elif op in (0x08, 0x09):
                reg[rt] = addv(b, norm(0, {}, sx16(imm)))
            else:
                reg.pop(rt, None)
        elif op in LOADS:
            b = reg.get(rs)
            ea = addv(b, norm(0, {}, sx16(imm))) if b is not None else None
            if ea is not None and ea[0]:
                yield (pc, ACCESS[op], ea)
            if ea is not None and ea[0] == 0 and not ea[1] and ea[2] == G_ADDR and op == 0x23:
                reg[rt] = norm(1, {}, 0)
            elif ea is not None and ea[0] == 0 and not ea[1]:
                # a load from a known constant address: value unknown
                reg.pop(rt, None)
            else:
                reg.pop(rt, None)
        elif op in ACCESS:
            b = reg.get(rs)
            ea = addv(b, norm(0, {}, sx16(imm))) if b is not None else None
            if ea is not None and ea[0]:
                yield (pc, ACCESS[op], ea)
        elif op == 0x03:
            reg.pop(31, None)
        elif op == 0 and f.get('fn') == 0x09:
            if rdv: reg.pop(rdv, None)
        elif op == 0 and f.get('fn') == 0x00:
            if sa == 0:
                reg[rdv] = reg.get(rt)
            else:
                v = shl(reg.get(rt), sa)
                if v is None: reg.pop(rdv, None)
                else: reg[rdv] = v
        elif op == 0 and f.get('fn') in (0x20, 0x21, 0x23, 0x22):
            sg = 1 if f['fn'] in (0x20, 0x21) else -1
            v = addv(reg.get(rs), reg.get(rt), sg)
            if v is None: reg.pop(rdv, None)
            else: reg[rdv] = v
        else:
            d = None
            if op == 0 and f.get('fn') in (0x02,0x03,0x04,0x10,0x12):
                d = rdv
            if d is not None: reg.pop(d, None)
            if op == 0 and f.get('fn') == 0x08:      # jr
                reset_next = True
        pc += 4

if __name__ == '__main__':
    lo = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0
    hi = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0xFFFFFFFF
    from collections import defaultdict
    d = defaultdict(list)
    for pc, kind, ea in sweep():
        if not (lo <= pc < hi): continue
        key = (tuple(sorted(ea[1])), ea[2])
        d[key].append((pc, kind, ea))
    for key in sorted(d, key=lambda k: (len(k[0]), k[1])):
        items = d[key]
        idxs, const = key
        print(f"=== idx={list(idxs)} const={const:#x}  ({len(items)})")
        for pc, kind, ea in items[:60]:
            print(f"    {pc:#010x} {kind:4s} const={ea[2]:#x} coeffs={ {REGS[int(s[1:])]:v for s,v in ea[1].items()} }")
