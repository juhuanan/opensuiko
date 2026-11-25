"""Whole-MAIN.EXE static scans for the .8 payload reader.

Uses the local mipsdec (no capstone in .venv). Scans every 4-byte aligned word
of the MAIN.EXE body (base 0x800C0800); hits in data regions are expected and
are filtered by requiring the instruction to be part of a plausible run.
"""
import struct, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mx
import mipsdec

def iter_words():
    for i in range(len(mx.BODY)//4):
        va = mx.BASE + 4*i
        w = struct.unpack_from('<I', mx.BODY, 4*i)[0]
        yield va, w

def fields(w):
    op = (w>>26)&0x3F
    return dict(op=op, rs=(w>>21)&0x1F, rt=(w>>16)&0x1F, rd=(w>>11)&0x1F,
                sa=(w>>6)&0x1F, fn=w&0x3F, imm=mipsdec.sx16(w))

def find_nibble_idioms():
    """srl r,x,4 ; andi r,y,0xF ; sll/sra 28 ; addiu +/-8 after srl 4"""
    res = dict(andiF=[], srl4=[], signext=[], bias8=[])
    words = list(iter_words())
    for idx, (va, w) in enumerate(words):
        f = fields(w)
        if f['op'] == 0x0C and f['imm'] == 0xF:
            res['andiF'].append(va)
        if f['op'] == 0 and f['fn'] == 0x02 and f['sa'] == 4:
            res['srl4'].append(va)
            # next 2 instructions: addiu +/-8 on the same rd
            for k in (1,2):
                if idx+k >= len(words): break
                v2, w2 = words[idx+k]
                f2 = fields(w2)
                if f2['op'] in (0x08,0x09) and f2['imm'] in (8,-8):
                    res['bias8'].append((va, v2))
        if f['op'] == 0 and f['fn'] == 0x03 and f['sa'] == 28:
            if idx >= 1:
                v0, w0 = words[idx-1]
                if fields(w0)['op'] == 0 and fields(w0)['fn'] == 0x00 and fields(w0)['sa'] == 28:
                    res['signext'].append((v0,v2 if False else va))
    return res

def find_stride_loops(stride=0x10):
    """backward branches whose body contains addiu r,r,stride"""
    words = list(iter_words())
    addr2idx = {va: i for i,(va,w) in enumerate(words)}
    out = []
    for i, (va, w) in enumerate(words):
        f = fields(w)
        is_br = f['op'] in (0x01,0x04,0x05,0x06,0x07)
        if not is_br:
            continue
        tgt = va + 4 + (f['imm']<<2)
        if tgt not in addr2idx: continue
        ti = addr2idx[tgt]
        if ti >= i or i-ti > 300: continue
        body = words[ti:i+1]
        strides = []
        for k,(bv,bw) in enumerate(body):
            bf = fields(bw)
            if bf['op'] == 0x09 and bf['rs'] == bf['rt'] and bf['imm'] == stride:
                strides.append(bv)
            if bf['op'] == 0x09 and bf['rs'] == bf['rt'] and bf['imm'] == -stride:
                strides.append(bv)
        if strides:
            out.append((tgt, va, strides))
    return out

def find_table_dispatch():
    """andi r,r,0xFF (or 0x1F/0x3F) ; sll r,r,2 ; lw ; jr r  -- any index width"""
    words = list(iter_words())
    out = []
    for i,(va,w) in enumerate(words):
        f = fields(w)
        if f['op'] == 0 and f['fn'] == 0x08:      # jr $rs
            reg = f['rs']
            # look back up to 10 insns for sll reg, x, 2 and an andi feeding x
            for k in range(1, 11):
                if i-k < 0: break
                v2,w2 = words[i-k]
                f2 = fields(w2)
                if f2['op'] == 0 and f2['fn'] == 0x00 and f2['sa'] == 2 and f2['rd'] == reg:
                    out.append((va, v2, 'sll2'))
                    break
    return out

def find_ops(pattern, data=None, base=None):
    """pattern(w, fields) -> bool ; returns list of (va, words_around)"""
    data = data if data is not None else mx.BODY
    base = base if base is not None else mx.BASE
    out = []
    for i in range(len(data)//4):
        w = struct.unpack_from('<I', data, 4*i)[0]
        f = fields(w)
        if pattern(w, f):
            out.append(base + 4*i)
    return out
