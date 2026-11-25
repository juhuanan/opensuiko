"""Find every run of >=3 consecutive words in MAIN.EXE that are pointers into
the executable body -- i.e. code dispatch tables."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import rd
LO = 0x800C0800; HI = LO + rd.size()
lo = int(sys.argv[1], 16) if len(sys.argv) > 1 else LO
hi = int(sys.argv[2], 16) if len(sys.argv) > 2 else HI
def isptr(w):
    return w is not None and LO <= w < HI and (w & 3) == 0
runs = []
cur = None
va = lo
while va < hi:
    w = rd.word(va)
    if isptr(w):
        if cur is None: cur = [va, [w]]
        else: cur[1].append(w)
    else:
        if cur and len(cur[1]) >= 3: runs.append(cur)
        cur = None
    va += 4
if cur and len(cur[1]) >= 3: runs.append(cur)
for base, ws in runs:
    print(f"table @ {base:#x}  {len(ws)} entries")
    for i, w in enumerate(ws):
        print(f"   [{i:2d}] {w:#x}")
