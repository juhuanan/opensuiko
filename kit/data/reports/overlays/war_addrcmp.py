#!/usr/bin/env python3
"""Per-address comparison across the 9 WAR scenario overlays (GARA = reference).
Usage: war_addrcmp.py <workdir>
Writes war_addrcmp.json: engine addrs, variant addrs, missing/extra per file.
"""
import sys, json, struct, hashlib
from collections import defaultdict

BASE = 0x80010000
WAR_DIR = '/home/hatch/workspace/suikoden/kit/extracted/bin_overlays/DATA/16_WAR/'
FILES = ['WAR_GARA.BIN','WAR_KITA.BIN','WAR_KUWA.BIN','WAR_LAST.BIN','WAR_SCA1.BIN',
         'WAR_SCA2.BIN','WAR_SHAS.BIN','WAR_TEO1.BIN','WAR_TEO2.BIN']

def token(w):
    op = w >> 26
    if op in (2, 3): return ('J', op)
    if op == 0x0F: return ('LUI',)
    if op == 0:
        funct = w & 0x3F
        return ('SP', funct, (w >> 21) & 31, (w >> 16) & 31, (w >> 11) & 31, (w >> 6) & 31)
    if op in (1, 4, 5, 6, 7):
        return ('BR', op, (w >> 21) & 31, (w >> 16) & 31)
    imm = w & 0xFFFF
    simm = imm - 0x10000 if imm & 0x8000 else imm
    return (op, (w >> 21) & 31, (w >> 16) & 31, simm if abs(simm) < 0x1000 else 'BIG')

def nhash(words, a, end):
    h = hashlib.sha1()
    o0, o1 = (a - BASE) // 4, (end - BASE) // 4
    for i in range(o0, o1 + 1):
        if 0 <= i < len(words):
            h.update(repr(token(words[i])).encode() + b';')
    return h.hexdigest()[:16]

cdata = json.load(open(sys.argv[1] + '/war_cluster.json'))
words_map = {}
for fn in FILES:
    data = open(WAR_DIR + fn, 'rb').read()
    words_map[fn] = struct.unpack('<%dI' % (len(data) // 4), data)

# normalized hash per (file, addr)
nh = {}
for fn in FILES:
    words = words_map[fn]
    for as_, v in cdata['files'][fn]['funcs'].items():
        a = int(as_, 16)
        nh[(fn, a)] = (nhash(words, a, v['end']), v['n'])

gara_addrs = sorted(a for (fn, a) in nh if fn == 'WAR_GARA.BIN')
engine, variants, missing = [], {}, defaultdict(list)
for a in gara_addrs:
    gh, gn = nh[('WAR_GARA.BIN', a)]
    per = {}
    miss = []
    for fn in FILES:
        if (fn, a) in nh:
            per[fn] = nh[(fn, a)]
        else:
            miss.append(fn)
    if miss:
        missing[hex(a)] = miss
        continue
    hashes = {h for h, n in per.values()}
    if len(hashes) == 1:
        engine.append(hex(a))
    else:
        variants[hex(a)] = {fn: h for fn, (h, n) in per.items()}

extra = defaultdict(list)
gset = set(gara_addrs)
for fn in FILES[1:]:
    for (f, a) in nh:
        if f == fn and a not in gset:
            extra[fn].append(hex(a))

print('engine (same addr, same norm-hash, all 9):', len(engine))
print('variants (same addr, differing norm-hash):', len(variants))
for a, per in sorted(variants.items(), key=lambda x: int(x[0], 16)):
    gh = dict((fn, h) for fn, h in per.items())
    uniq = sorted(set(gh.values()))
    print('  ', a, 'distinct variants:', len(uniq))
print('missing addrs:', {a: v for a, v in missing.items()})
for fn, addrs in extra.items():
    print('extra in', fn, ':', sorted(addrs, key=lambda x: int(x, 16)))

json.dump({'engine': engine, 'variants': variants, 'missing': dict(missing),
           'extra': {k: sorted(v, key=lambda x: int(x, 16)) for k, v in extra.items()},
           'gara_n': {hex(a): nh[('WAR_GARA.BIN', a)][1] for a in gara_addrs}},
          open(sys.argv[1] + '/war_addrcmp.json', 'w'), indent=1)
