import os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
BASE = 0x800C0800
BODY_PATH = os.path.join(ROOT, 'kit', 'work', 'mainexe_code.bin')
_B = open(BODY_PATH,'rb').read()
def size(): return len(_B)
def off(va):
    """byte offset of virtual address va in the body (BASE-relative)."""
    return va - BASE
def word(va):
    """u32 at virtual address va (little endian). Returns None if OOB.
    NOTE: va is a BYTE address; off() converts to a BYTE offset."""
    o = off(va)
    if o < 0 or o+4 > len(_B): return None
    return struct.unpack_from('<I', _B, o)[0]
def half(va):
    o = off(va)
    if o < 0 or o+2 > len(_B): return None
    return struct.unpack_from('<H', _B, o)[0]
def s16(va):
    h = half(va)
    if h is None: return None
    return h-0x10000 if h & 0x8000 else h
def byte(va):
    o = off(va)
    if o < 0 or o >= len(_B): return None
    return _B[o]
def dword(va): return word(va)
sys.path.insert(0, os.path.join(ROOT,'kit','tools'))
from mipsdec import dec
def dis(va, n):
    out=[]
    for i in range(n):
        pc = va + 4*i
        w = word(pc)
        if w is None: out.append((pc,None,'OUT')); continue
        s,f = dec(pc,w)
        out.append((pc,w,s,f))
    return out
def show(va, n):
    for pc,w,s,f in dis(va,n):
        print(f"{pc:#010x} {w:08x}  {s}" if w is not None else f"{pc:#010x} ????????  OUT")
