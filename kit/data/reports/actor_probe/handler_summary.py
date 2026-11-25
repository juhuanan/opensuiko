"""One-line summary per handler: descriptor halfwords read, descriptor advance,
callees, and the rec fields touched. Byte addresses only."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import rd
from mipsdec import dec
import scan_records as SR
from handler_map import table, T1, T2

LO = 0x800C0800; HI = LO + rd.size()

def handler_end(start, limit):
    pc = start
    while pc < limit:
        w = rd.word(pc)
        if w is None: return pc
        if w == 0x03E00008: return pc + 8
        pc += 4
    return limit

def main():
    t1 = table(T1); t2 = table(T2)
    bounds = sorted(set(t1))
    acc = {}
    for pc, kind, ea in SR.sweep():
        if ea[0]: acc.setdefault(pc, []).append((kind, ea))
    for i, a in enumerate(t1):
        k = bounds.index(a)
        limit = bounds[k+1] if k+1 < len(bounds) else 0x800E7000
        end = handler_end(a, limit)
        desc_offs = []
        calls = []
        for pc in range(a, end, 4):
            w = rd.word(pc)
            if w is None: break
            s, f = dec(pc, w)
            if f['op'] in (0x21, 0x25, 0x23) and f['rs'] == 2 and f['imm'] > 0:
                pass
            if f['op'] == 0x21 and f['rs'] == 2:            # lh Rt,imm($v0)
                desc_offs.append(('lh', f['imm']))
            elif f['op'] == 0x25 and f['rs'] == 2:          # lhu
                desc_offs.append(('lhu', f['imm']))
            elif f['op'] == 0x24 and f['rs'] == 2:          # lbu
                desc_offs.append(('lbu', f['imm']))
            elif f['op'] == 0x23 and f['rs'] == 2:          # lw
                desc_offs.append(('lw', f['imm']))
            if f['op'] == 0x03: calls.append(f['jt'])
        fields = sorted({ea[2]-0x50 for pc in range(a, end, 4)
                         for kind, ea in acc.get(pc, [])
                         if ea[1] == {'r4': 140}})
        print(f"op {i:2d} @ {a:#x}..{end:#x} ({end-a:5d} B)  desc={' '.join(f'{k}+{o:#x}' for k,o in desc_offs) or '-'}")
        print(f"      calls: {' '.join(hex(c) for c in sorted(set(calls))) or '-'}")
        print(f"      rec fields (idx*140): {' '.join(hex(x) for x in fields) or '-'}")

if __name__ == '__main__':
    main()
