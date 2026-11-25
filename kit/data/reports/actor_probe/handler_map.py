"""Boundary + field map for every entry of the actor action-script handler
table at 0x8016BABC (and the second table at 0x8016BB74).

All addresses are BYTE addresses; descriptor advances are BYTE counts read from
the `addiu ...,N` that updates rec[0x0C].
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import rd
from mipsdec import dec
import scan_records as SR

T1 = 0x8016BABC
T2 = 0x8016BB74

def table(base):
    out = []
    i = 0
    while True:
        w = rd.word(base + 4*i)
        if w is None or not (0x800C0800 <= w < 0x800C0800 + rd.size()):
            break
        out.append(w); i += 1
    return out

def handler_end(start, limit):
    """First `jr $ra` whose next word is a stack-restore/addiu $v0, i.e. the
    function's own return."""
    pc = start
    while pc < limit:
        w = rd.word(pc)
        if w is None: return pc
        if w == 0x03E00008:
            return pc + 8
        pc += 4
    return limit

def advances(start, end):
    """Every `addiu Rt,Rt,N` immediately followed by `sw Rt,0xc(base)`."""
    out = []
    for pc in range(start, end, 4):
        w = rd.word(pc)
        if w is None: break
        s, f = dec(pc, w)
        if f['op'] == 0x09 and f['rs'] == f['rt'] and f['rt'] not in (0,):
            nw = rd.word(pc+4)
            if nw is not None and ((nw >> 26) & 0x3F) == 0x2B:
                _, g = dec(pc+4, nw)
                if g['imm'] == 0xC:
                    out.append((pc, f['imm']))
    return out

if __name__ == '__main__':
    t1 = table(T1)
    t2 = table(T2)
    print(f"table 0x8016BABC: {len(t1)} entries")
    for i, a in enumerate(t1):
        print(f"  op {i:2d} -> {a:#x}")
    print(f"table 0x8016BB74: {len(t2)} entries")
    for i, a in enumerate(t2):
        print(f"  T2[{i:2d}] -> {a:#x}")

    bounds = sorted(set(t1))
    nxt = {a: (bounds[k+1] if k+1 < len(bounds) else 0x800E6E00)
           for k, a in enumerate(bounds)}
    # G-relative accesses per pc
    acc = {}
    for pc, kind, ea in SR.sweep():
        if ea[0]: acc.setdefault(pc, []).append((kind, ea))
    print()
    for i, a in enumerate(t1):
        end = nxt[a]
        kinds = {}
        for pc in range(a, end, 4):
            for kind, ea in acc.get(pc, []):
                coeffs = tuple(sorted(ea[1]))
                key = (coeffs, ea[2])
                kinds.setdefault(key, []).append((pc, kind))
        adv = advances(a, end)
        print(f"--- op {i} @ {a:#x} .. {end:#x}  adv={[f'+{n:#x}' for _,n in adv]}")
        for key in sorted(kinds, key=lambda k: (len(k[0]), k[1])):
            coeffs, const = key
            items = kinds[key]
            print(f"     G+{const:#x}({const})" + (f" idx={coeffs}" if coeffs else "") +
                  " " + " ".join(f"{k}@{p:#x}" for p, k in items[:8]))
