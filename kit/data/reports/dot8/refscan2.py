"""Base-independent absolute-address reference scan.

Works on raw words: finds `lui reg,hi` followed within a window by any
immediate/load/store op with rs==reg, and computes addr = (hi<<16) + sx16(imm)
with FULL SIGN EXTENSION (the documented lui trap). Because the address is
computed from the two instruction words alone, the result does not depend on
knowing the overlay's load base. The reported 'offset' is a file offset, only
for locating the hit.
"""
import os, struct, glob

IMM = {0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E}
LOAD = {0x20,0x21,0x22,0x23,0x24,0x25,0x26}
STORE = {0x28,0x29,0x2A,0x2B,0x2E}
SPEC = {0x2F}

def sx16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def corpus(root):
    fs = sorted(glob.glob(os.path.join(root,'kit','extracted','bin_overlays','DATA','**','*.BIN'), recursive=True))
    fs.append(os.path.join(root,'kit','work','mainexe_code.bin'))
    return fs

def scan_file(data, targets, window=8):
    hits = []
    n = len(data)//4
    for i in range(n):
        w = struct.unpack_from('<I', data, 4*i)[0]
        if (w>>26)&0x3F != 0x0F:
            continue
        reg = (w>>16)&0x1F
        hi = (w & 0xFFFF) << 16
        for k in range(1, window+1):
            j = i+k
            if j >= n: break
            w2 = struct.unpack_from('<I', data, 4*j)[0]
            op = (w2>>26)&0x3F
            rs = (w2>>21)&0x1F
            if op == 0x0F:
                break
            if rs != reg:
                continue
            if op in IMM or op in LOAD or op in STORE or op in SPEC:
                addr = (hi + sx16(w2)) & 0xFFFFFFFF
                if addr in targets:
                    hits.append((addr, 4*i, 4*j, op))
    return hits

def scan(root, targets):
    out = {}
    for f in corpus(root):
        d = open(f,'rb').read()
        h = scan_file(d, targets)
        if h:
            out[f] = h
    return out
