import os, struct, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, os.path.join(ROOT, 'kit', 'tools'))
BASE = 0x800C0800
_path = os.path.join(ROOT, 'kit', 'work', 'mainexe_code.bin')
BODY = open(_path, 'rb').read()
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mipsdec

def off(va):
    return va - BASE

def w(va):
    o = off(va)
    if o < 0 or o + 4 > len(BODY):
        return None
    return struct.unpack_from('<I', BODY, o)[0]

def h(va):
    o = off(va)
    return struct.unpack_from('<H', BODY, o)[0]

def b(va):
    return BODY[off(va)]

def dis(va, n):
    out = []
    pc = va
    for _ in range(n):
        ww = w(pc)
        if ww is None: break
        s, f = mipsdec.dec(pc, ww)
        out.append((pc, ww, s, f))
        pc += 4
    return out

def show(va, n, label=''):
    if label: print('=== %s @ %#x ===' % (label, va))
    for pc, ww, s, f in dis(va, n):
        print('%08x  %08x  %s' % (pc, ww, s))
