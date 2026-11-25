"""Descriptor halfword-length per opcode, read from the handler's own
`addiu Rt,Rt,N` + `sw Rt,0xc(base)` pair (BYTE advance / 2 = halfwords)."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import rd
from mipsdec import dec
from handler_map import table, T1, T2
from handler_summary import handler_end

if __name__ == '__main__':
    t1 = table(T1); bounds = sorted(set(t1))
    lens = {}
    for i, a in enumerate(t1):
        k = bounds.index(a)
        limit = bounds[k+1] if k+1 < len(bounds) else 0x800E7000
        end = handler_end(a, limit)
        found = []
        for pc in range(a, end, 4):
            w = rd.word(pc); nw = rd.word(pc+4)
            if w is None or nw is None: break
            s, f = dec(pc, w)
            if f['op'] == 0x09 and f['rs'] == f['rt'] and f['rt'] != 0:
                _, g = dec(pc+4, nw)
                if g['op'] == 0x2B and g['imm'] == 0xC:
                    found.append(f['imm'])
        lens[i] = sorted(set(found))
        print(f"op {i:2d} @ {a:#x}: advance bytes={[hex(x) for x in lens[i]]} "
              f"-> halfwords={[x//2 for x in lens[i]]}")
