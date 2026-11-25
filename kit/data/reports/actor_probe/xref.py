"""Constant-address cross-reference scanner for the MAIN.EXE body.

Resolves every RAM address from the full lui+imm encoding WITH SIGN EXTENSION.
All addresses are BYTE addresses/offsets throughout (no word-index arithmetic).

usage: xref.py 0x8016B81C [0x8016B80C ...]     # exact matches
       xref.py --range 0x8016B800 0x8016B900   # anything inside a window
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import rd
from mipsdec import dec

LO = 0x800C0800
HI = LO + rd.size()
ACCESS = {0x20:'lb',0x21:'lh',0x22:'lwl',0x23:'lw',0x24:'lbu',0x25:'lhu',0x26:'lwr',
          0x28:'sb',0x29:'sh',0x2A:'swl',0x2B:'sw',0x2E:'swr',0x2F:'cache'}
LOADS = (0x20,0x21,0x22,0x23,0x24,0x25,0x26)
IMM = (0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E)

def sx16(v):
    v &= 0xFFFF
    return v-0x10000 if v & 0x8000 else v

def sweep():
    """Yield (pc, kind, ea_or_target, text, reg) for constant-address uses."""
    reg = {}
    pc = LO
    while pc < HI:
        w = rd.word(pc)
        if w is None: break
        s, f = dec(pc, w)
        op, rs, rt, rdv, imm = f['op'], f['rs'], f['rt'], f['rd'], f['imm']
        if op == 0x0F:
            reg[rt] = (imm & 0xFFFF) << 16
        elif op in IMM:
            b = reg.get(rs)
            if isinstance(b, int):
                if op == 0x09 or op == 0x08: reg[rt] = (b + sx16(imm)) & 0xFFFFFFFF
                elif op == 0x0D: reg[rt] = (b | (imm & 0xFFFF)) & 0xFFFFFFFF
                elif op == 0x0C: reg[rt] = (b & (imm & 0xFFFF)) & 0xFFFFFFFF
                else: reg.pop(rt, None)
            else: reg.pop(rt, None)
        elif op in LOADS:
            b = reg.get(rs)
            if isinstance(b, int):
                ea = (b + sx16(imm)) & 0xFFFFFFFF
                yield (pc, ACCESS[op], ea, s, rs)
                # a load yields an unknown value unless it is a small data read
                reg.pop(rt, None)
            else:
                reg.pop(rt, None)
        elif op in ACCESS:
            b = reg.get(rs)
            if isinstance(b, int):
                yield (pc, ACCESS[op], (b + sx16(imm)) & 0xFFFFFFFF, s, rs)
        elif op in (0x02, 0x03):
            yield (pc, 'j' if op == 0x02 else 'jal', f['jt'], s, None)
            if op == 0x03: reg.pop(31, None)
        elif op == 0 and f.get('fn') == 0x09:
            b = reg.get(rs)
            if isinstance(b, int): yield (pc, 'jalr', b, s, None)
            if rdv: reg.pop(rdv, None)
        elif op == 0 and f.get('fn') in (0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27):
            a, b = reg.get(rs), reg.get(rt)
            if isinstance(a,int) and isinstance(b,int):
                if f['fn'] == 0x21: reg[rdv] = (a+b) & 0xFFFFFFFF
                elif f['fn'] == 0x23: reg[rdv] = (a-b) & 0xFFFFFFFF
                else: reg.pop(rdv, None)
            else: reg.pop(rdv, None)
        else:
            d = None
            if op == 0 and f.get('fn') in (0x00,0x02,0x03,0x04,0x10,0x12):
                d = rdv
            if d is not None: reg.pop(d, None)
        pc += 4

if __name__ == '__main__':
    args = sys.argv[1:]
    rng = None
    if args and args[0] == '--range':
        rng = (int(args[1],16), int(args[2],16)); args = []
    want = {int(a,16) for a in args}
    n = 0
    for pc, kind, ea, text, rs in sweep():
        hit = (rng and rng[0] <= ea < rng[1]) or (ea in want)
        if hit:
            n += 1
            print(f"{pc:#010x} {kind:5s} -> {ea:#010x}  {text}")
    print(f"# {n} hits", file=sys.stderr)
