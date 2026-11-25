"""MAIN.EXE-only structural scans for the .8 payload reader.

The 2026-10-01 whole-corpus sweep (quad_record_layout.md 4.1) ran its
16-stride / tag-dispatch / index-x16 scans over the 95 overlays + SLUS only;
MAIN.EXE was covered for the nibble-unbias scan alone. These scans close that
gap. Everything here works on 4-byte aligned words with the local mipsdec.
"""
import struct, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mx, mipsdec

WORDS = [struct.unpack_from('<I', mx.BODY, 4*i)[0] for i in range(len(mx.BODY)//4)]
VAS   = [mx.BASE + 4*i for i in range(len(WORDS))]
IDX   = {va: i for i, va in enumerate(VAS)}

def f(w):
    return dict(op=(w>>26)&0x3F, rs=(w>>21)&0x1F, rt=(w>>16)&0x1F,
                rd=(w>>11)&0x1F, sa=(w>>6)&0x1F, fn=w&0x3F, imm=mipsdec.sx16(w))

def stride_loops(stride=0x10, maxlen=400):
    """Backward branch whose body contains addiu r,r,stride."""
    out = []
    for i, w in enumerate(WORDS):
        g = f(w)
        if g['op'] not in (0x01,0x04,0x05,0x06,0x07):
            continue
        tgt = VAS[i] + 4 + (g['imm'] << 2)
        ti = IDX.get(tgt)
        if ti is None or ti >= i or i - ti > maxlen:
            continue
        body = range(ti, i+1)
        st = [VAS[k] for k in body
              if f(WORDS[k])['op'] == 0x09 and f(WORDS[k])['rs'] == f(WORDS[k])['rt']
              and f(WORDS[k])['imm'] == stride]
        if st:
            out.append((tgt, VAS[i], st, i-ti+1))
    return out

def index_x_stride(shift, maxlen=200):
    """loops containing sll r,x,shift followed by addu r2,r2,r (index*stride+base)"""
    out = []
    for i, w in enumerate(WORDS):
        g = f(w)
        if g['op'] not in (0x01,0x04,0x05,0x06,0x07):
            continue
        tgt = VAS[i] + 4 + (g['imm'] << 2)
        ti = IDX.get(tgt)
        if ti is None or ti >= i or i - ti > maxlen:
            continue
        hits = []
        for k in range(ti, i+1):
            gk = f(WORDS[k])
            if gk['op'] == 0 and gk['fn'] == 0x00 and gk['sa'] == shift and WORDS[k] != 0:
                hits.append(VAS[k])
        if hits:
            out.append((tgt, VAS[i], hits))
    return out

def tag_load_dispatch():
    """lhu/lbu at a small offset from a base reg feeding a compare or a table index"""
    out = []
    for i, w in enumerate(WORDS):
        g = f(w)
        if g['op'] not in (0x21, 0x24, 0x25):   # lh / lbu / lhu
            continue
        off = g['imm']
        if not (-0x10 <= off <= 0x10):
            continue
        rt = g['rt']
        # within the next 6 insns, is rt compared/dispatched?
        for k in range(i+1, min(i+7, len(WORDS))):
            gk = f(WORDS[k])
            if gk['op'] in (0x04,0x05) and (gk['rs'] == rt or gk['rt'] == rt):
                out.append((VAS[i], off, 'cmp', VAS[k])); break
            if gk['op'] == 0 and gk['fn'] == 0x00 and gk['sa'] == 2 and gk['rt'] == rt:
                out.append((VAS[i], off, 'sll2', VAS[k])); break
            if gk['op'] == 0x0C and gk['rs'] == rt:
                out.append((VAS[i], off, 'andi', VAS[k])); break
    return out
