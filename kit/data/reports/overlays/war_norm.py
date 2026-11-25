#!/usr/bin/env python3
"""Normalized function clustering for WAR overlays.
Normalizes away absolute addresses (jal/j targets, lui immediates, big offsets,
branch offsets) so engine functions cluster across files despite scenario data
addresses differing. Usage: war_norm.py <outdir>
"""
import sys, struct, json, hashlib
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

BASE = 0x80010000
WAR_DIR = '/home/hatch/workspace/suikoden/kit/extracted/bin_overlays/DATA/16_WAR/'
FILES = ['WAR1.BIN','WAR_GARA.BIN','WAR_KITA.BIN','WAR_KUWA.BIN','WAR_LAST.BIN',
         'WAR_SCA1.BIN','WAR_SCA2.BIN','WAR_SHAS.BIN','WAR_TEO1.BIN','WAR_TEO2.BIN']

def token(w):
    op = w >> 26
    if op in (2, 3):
        return ('J', op)
    if op == 0x0F:
        return ('LUI',)
    if op == 0:
        funct = w & 0x3F
        return ('SP', funct, (w >> 21) & 31, (w >> 16) & 31, (w >> 11) & 31, (w >> 6) & 31)
    if op in (1, 4, 5, 6, 7):
        return ('BR', op, (w >> 21) & 31, (w >> 16) & 31)
    imm = w & 0xFFFF
    simm = imm - 0x10000 if imm & 0x8000 else imm
    imm_tok = simm if abs(simm) < 0x1000 else 'BIG'
    return (op, (w >> 21) & 31, (w >> 16) & 31, imm_tok)

def load(fn):
    data = open(WAR_DIR + fn, 'rb').read()
    words = struct.unpack('<%dI' % (len(data) // 4), data)
    return data, words

def va(off): return BASE + off
def in_range(a, data): return BASE <= a < BASE + len(data)
def jtarget(a, w): return ((a + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)

# function bodies from war_cluster-style discovery; reuse JSON if present
cdata = json.load(open(sys.argv[1] + '/war_cluster.json'))
clusters = {}
for fn in FILES:
    data, words = load(fn)
    fmap = cdata['files'][fn]['funcs']
    for as_, v in fmap.items():
        a = int(as_, 16)
        n = v['n']
        toks = []
        # body addrs: recompute by walking? use stored end: approximate contiguous
        # range may include data; instead walk words from a to end stepping 4 and
        # tokenize only real instructions via capstone single-decode
        toks.append(n)  # include size class
        # tokenize contiguous range a..end (descent bodies are near-contiguous)
        end = v['end']
        h = hashlib.sha1()
        h.update(str(n).encode() + b'|')
        o0, o1 = (a - BASE) // 4, (end - BASE) // 4
        for i in range(o0, o1 + 1):
            if 0 <= i < len(words):
                h.update(repr(token(words[i])).encode() + b';')
        nh = h.hexdigest()[:16]
        clusters.setdefault(nh, []).append((fn, a, n))

n_all10 = sum(1 for v in clusters.values() if len({f for f, _, _ in v}) == 10)
n_all9 = sum(1 for v in clusters.values()
             if {f for f, _, _ in v} == set(FILES[1:]))
n_war1only = sum(1 for v in clusters.values() if {f for f, _, _ in v} == {'WAR1.BIN'})
print('normalized clusters spanning all 10 files:', n_all10)
print('normalized clusters spanning all 9 scenarios (not WAR1):', n_all9)
print('normalized clusters WAR1-only:', n_war1only)
print('total clusters:', len(clusters))

# per-file unique clusters (scenario-specific candidates)
for fn in FILES[1:]:
    uniq = [(h, v) for h, v in clusters.items()
            if len(v) == 1 and v[0][0] == fn]
    uniq.sort(key=lambda x: x[1][0][1])
    print(f'--- {fn}: {len(uniq)} unique-to-file functions')
    for h, v in uniq[:40]:
        print('   ', hex(v[0][1]), 'n=', v[0][2], h)

json.dump({h: [(f, hex(a), n) for f, a, n in v] for h, v in clusters.items()},
          open(sys.argv[1] + '/war_norm.json', 'w'))
