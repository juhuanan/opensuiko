#!/usr/bin/env python3
"""Second-attempt dialogue blob hunt with the FIXED LZSS decoder (hpos=0x3DE).

Two prongs:
  1. RETRY: blind [u32 len] framing scan over candidate files + specific offsets.
  2. STRUCTURAL: follow the Path-A dialogue chain rooted at the area overlay's
     first word: [0x80010000] -> struct -> +8 -> 16-byte entries ->
     [[E+4] + u8(E+5)*4] -> table -> [table+0x34] -> {id,blob,param} array ->
     blob = [u32 len][lzss].

Dialogue decodes to tile/char INDEX streams (not ASCII). Judging heuristics
are structural (anchor via the real lookup chain) + sanity (non-degenerate).
"""
import struct, sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lzss import LZSSError
from text_lzss import decompress

BASE = 0x80010000

def u32(d, o):
    return struct.unpack_from('<I', d, o)[0]

def internal(va, size):
    return BASE <= va < BASE + size

def judge(out):
    """Return (score, notes) for decoded output. Higher = more dialogue-like."""
    n = len(out)
    if n < 8 or n > 8192:
        return -1, 'badlen'
    if n == 0:
        return -1, 'empty'
    from collections import Counter
    c = Counter(out)
    distinct = len(c)
    if distinct < 8:
        return -1, f'distinct{distinct}'
    topfrac = c.most_common(1)[0][1] / n
    if topfrac > 0.6:
        return -1, f'topfrac{topfrac:.2f}'
    ent = -sum(v/n*math.log2(v/n) for v in c.values())
    if ent < 1.5 or ent > 7.6:
        return -1, f'ent{ent:.2f}'
    # control codes 0x80/0x81/0xFF are special-cased by text_char_decoder
    ctrl = sum(out.count(b) for b in (0x80, 0x81, 0xFF))
    score = 0
    notes = [f'len{n}', f'dist{distinct}', f'ent{ent:.2f}']
    if ctrl:
        score += 2
        notes.append(f'ctrl{ctrl}')
    # plausible dialogue-box line lengths: runs between control codes
    score += 1
    return score, ','.join(notes)

def try_blob(d, off, size, where):
    """Try [u32 len][lzss] at file offset off. Return (out, info) or None."""
    if off + 4 > size:
        return None
    ln = u32(d, off)
    if ln < 8 or ln > 0x8000 or off + 4 + ln > size:
        return None
    try:
        out = decompress(d[off+4:off+4+ln])
    except LZSSError:
        # candidate offset that is not a valid stream -- expected during a sweep
        return None
    score, notes = judge(out)
    return (out, f'{where} off=0x{off:X} clen={ln} score={score} {notes}')

def framing_scan(path, align=1):
    with open(path, 'rb') as fh:
        d = fh.read()
    size = len(d)
    hits = []
    for off in range(0, size - 8, align):
        r = try_blob(d, off, size, os.path.basename(path))
        if r and r[1].split('score=')[1][0] != '-':
            hits.append(r)
    return hits

def chain_sweep(path):
    """Follow the Path-A chain (re-derived from 0x80132044 + 0x8013F584):
    struct=u32(file+0); parr=u32(struct+4); earr=u32(struct+8);
    for each 16-byte entry: idx=u8(E+5); T=parr[idx];
    A=u32(T+0x34); entries: eptr=u32(A+j*4) -> {id,blob,param}."""
    with open(path, 'rb') as fh:
        d = fh.read()
    size = len(d)
    name = os.path.basename(path)
    results = []
    if size < 16:
        return results
    w0 = u32(d, 0)
    if not internal(w0, size):
        return results
    struct_off = w0 - BASE
    if struct_off + 12 > size:
        return results
    parr = u32(d, struct_off+4)
    earr = u32(d, struct_off+8)
    if not (internal(parr, size) and internal(earr, size)):
        return results
    parr_off, earr_off = parr - BASE, earr - BASE
    for i in range(40):
        e = earr_off + i*16
        if e + 16 > size:
            break
        if not internal(u32(d, e), size):
            break  # entry shape ended
        idx = d[e+5]
        t_off = parr_off + idx*4
        if t_off + 4 > size:
            continue
        t_va = u32(d, t_off)
        if not internal(t_va, size):
            continue
        t = t_va - BASE
        if t + 0x38 > size:
            continue
        a_va = u32(d, t + 0x34)
        if not internal(a_va, size):
            continue
        a = a_va - BASE
        for j in range(256):
            eo = a + j*4
            if eo + 4 > size:
                break
            eptr_va = u32(d, eo)
            if eptr_va == 0 or not internal(eptr_va, size):
                break
            ep = eptr_va - BASE
            if ep + 12 > size:
                break
            bid = u32(d, ep)
            blob_va = u32(d, ep+4)
            if not internal(blob_va, size):
                continue
            r = try_blob(d, blob_va - BASE, size,
                         f'{name} e{i} idx{idx} id=0x{bid:X}')
            if r:
                out, info = r
                if not info.split('score=')[1].startswith('-'):
                    results.append((out, info))
    return results

if __name__ == '__main__':
    mode = sys.argv[1]
    if mode == 'retry':
        for path in sys.argv[2:]:
            print(f'== framing scan {path}')
            hits = framing_scan(path)
            for out, info in hits[:40]:
                print('  HIT', info)
            print(f'  {len(hits)} total hits')
    elif mode == 'offsets':
        path = sys.argv[2]
        with open(path, 'rb') as fh:
            d = fh.read()
        for off_s in sys.argv[3:]:
            off = int(off_s, 0)
            for a in range(4):
                r = try_blob(d, off+a, len(d), f'{path}@+{a}')
                print(r[1] if r else f'{path} 0x{off+a:X}: no framing')
                if r:
                    out = r[0]
                    print('   first64:', out[:64].hex())
    elif mode == 'chain':
        for path in sys.argv[2:]:
            res = chain_sweep(path)
            print(f'== chain {path}: {len(res)} dialogue-like blobs')
            for out, info, name, bid in res[:20]:
                print('  ', info)
                print('    first48:', out[:48].hex())
