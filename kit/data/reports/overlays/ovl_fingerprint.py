#!/usr/bin/env python3
"""Function fingerprinting for cross-overlay engine matching.
Fingerprint = (size, mnemonic sequence with immediates/regs normalized).
Usage:
  ovl_fingerprint.py build <bin> <base> <out.json>
  ovl_fingerprint.py match <bin> <base> <db.json>   (prints addr -> best db match)
"""
import sys, json, struct
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

def load(path, base):
    raw = open(path,'rb').read()
    n = len(raw)//4; data = raw[:n*4]
    words = struct.unpack('<%dI'%n, data)
    def va(o): return base+o
    def off(a): return a-base
    def inr(a): return base <= a < base+len(data)
    md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32|CS_MODE_LITTLE_ENDIAN)
    md.detail = True
    insns = {}
    for o in range(0, len(data)-3, 4):
        try:
            for ins in md.disasm(data[o:o+4], base+o):
                insns[ins.address] = ins; break
        except Exception: pass
    def get(a): return insns.get(a)
    def word_at(a):
        o = off(a); return words[o//4] if 0 <= o <= len(data)-4 else None
    def jtarget(a,w): return ((a+4)&0xF0000000)|((w&0x3FFFFFF)<<2)
    BRANCH_OPS = {1,4,5,6,7}
    def branch_target(a,w):
        imm = w & 0xFFFF
        if imm & 0x8000: imm -= 0x10000
        return (a+4 + (imm<<2)) & 0xFFFFFFFF
    seeds = set()
    for o in range(0, len(data)-3, 4):
        w = words[o//4]
        if (w>>26) == 9:
            rs, rt = (w>>21)&31, (w>>16)&31
            imm = (w&0xFFFF)-0x10000 if w&0x8000 else w&0xFFFF
            if rs==29 and rt==29 and imm<0 and -imm%8==0 and -imm<0x2000:
                seeds.add(va(o))
    JRRA = 0x03E00008
    def walk_body(s, seed_set):
        seen = set(); jals = set(); stack = [s]
        limit = base+len(data)
        while stack:
            a = stack.pop()
            while True:
                if a in seen: break
                if a in seed_set and a != s: break
                w = word_at(a); ins = get(a)
                if w is None or ins is None: break
                seen.add(a)
                if w == JRRA: break
                m = ins.mnemonic; op = w>>26
                if m == 'jr': break
                if op == 2:
                    t = jtarget(a,w)
                    if s <= t < limit and t not in seen: stack.append(t)
                    break
                if op == 3:
                    t = jtarget(a,w)
                    if inr(t) and get(t) is not None: jals.add(t)
                    a += 8; continue
                if op in BRANCH_OPS:
                    t = branch_target(a,w)
                    if s <= t < limit and t not in seen: stack.append(t)
                    a += 4; continue
                a += 4
        return seen, jals
    changed = True
    while changed:
        changed = False
        for s in sorted(seeds):
            _, jals = walk_body(s, seeds)
            new = {t for t in jals if t not in seeds}
            if new: seeds.update(new); changed = True
    funcs = []
    for s in sorted(seeds):
        seen, _ = walk_body(s, seeds)
        if seen: funcs.append((s, max(seen)+4))
        else: funcs.append((s, s+4))
    funcs.sort()
    merged = []
    for s,e in funcs:
        if merged and s < merged[-1][1]:
            if e > merged[-1][1]: merged[-1] = (merged[-1][0],e)
        else: merged.append((s,e))
    real = [(s,e) for (s,e) in merged if get(s) is not None]
    return real, get, word_at

def fingerprint(s, e, get):
    """shape sig (operands masked) + strict sig (immediates kept, regs masked)"""
    shape = []; strict = []
    a = s
    while a < e:
        ins = get(a)
        if ins is None: break
        m = ins.mnemonic
        shp = []; stc = []
        for op in ins.operands:
            if op.type == 1:
                shp.append('R'); stc.append('R')
            elif op.type == 2:
                shp.append('I'); stc.append('I%d' % (op.imm & 0xFFFFFFFF))
            elif op.type == 3:
                shp.append('M'); stc.append('M%d' % (op.mem.disp & 0xFFFFFFFF))
        shape.append(m + ':' + ','.join(shp))
        strict.append(m + ':' + ','.join(stc))
        a += 4
    return (e-s)//4, '|'.join(shape), '|'.join(strict)

def main():
    cmd = sys.argv[1]
    if cmd == 'build':
        path, base_s, out = sys.argv[2], sys.argv[3], sys.argv[4]
        base = int(base_s, 16)
        real, get, _ = load(path, base)
        db = {}
        for (s,e) in real:
            size, shape, strict = fingerprint(s, e, get)
            db.setdefault(shape, []).append((path, hex(s), size, strict))
        json.dump(db, open(out,'w'))
        print(f"db: {len(db)} unique shape sigs from {len(real)} funcs")
    elif cmd == 'match':
        path, base_s, dbpath = sys.argv[2], sys.argv[3], sys.argv[4]
        base = int(base_s, 16)
        db = json.load(open(dbpath))
        real, get, _ = load(path, base)
        n_shape = n_strict = 0
        for (s,e) in real:
            size, shape, strict = fingerprint(s, e, get)
            if shape in db:
                n_shape += 1
                cands = db[shape]
                sstrict = [c for c in cands if c[3] == strict]
                if sstrict:
                    n_strict += 1
                    print(f"{hex(s)} size={size} STRICT {sstrict[0][1]}")
                else:
                    print(f"{hex(s)} size={size} SHAPE {cands[0][1]}")
            else:
                print(f"{hex(s)} size={size} NEW")
        print(f"shape {n_shape}/{len(real)} strict {n_strict}/{len(real)}")

main()
