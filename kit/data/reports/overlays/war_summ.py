#!/usr/bin/env python3
"""Behavioral summaries, one per normalized cluster (GARA representative).
Usage: war_summ.py <workdir> [cluster_prefix...]
Outputs compact lines: addr n= ext=... str=... jt?= callers=
"""
import sys, json, struct, csv
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

WORK = sys.argv[1]
BASE = 0x80010000
WAR_DIR = '/home/hatch/workspace/suikoden/kit/extracted/bin_overlays/DATA/16_WAR/'
REF = 'WAR_GARA.BIN'
FILES = ['WAR_GARA.BIN','WAR_KITA.BIN','WAR_KUWA.BIN','WAR_LAST.BIN','WAR_SCA1.BIN',
         'WAR_SCA2.BIN','WAR_SHAS.BIN','WAR_TEO1.BIN','WAR_TEO2.BIN']

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
md.detail = True
md.skipdata = True

data = open(WAR_DIR + REF, 'rb').read()
words = struct.unpack('<%dI' % (len(data) // 4), data)
def va(o): return BASE + o
def in_range(a): return BASE <= a < BASE + len(data)
def jtarget(a, w): return ((a + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)

# per-word decode cache
_dcache = {}
def dec(a):
    if a in _dcache: return _dcache[a]
    o = a - BASE
    r = None
    if 0 <= o <= len(data) - 4:
        for ins in md.disasm(data[o:o+4], a):
            if ins.id != 0:
                r = ins
            break
    _dcache[a] = r
    return r

# MAIN.EXE names
main = {}
with open('/home/hatch/workspace/suikoden/kit/work/function_labels.csv') as f:
    for r in csv.DictReader(f):
        try: main[int(r['address'], 16)] = r['name']
        except: pass

# strings in REF
strs = {}
i = 0
while i < len(data):
    if 32 <= data[i] < 127:
        j = i
        while j < len(data) and 32 <= data[j] < 127: j += 1
        if j < len(data) and data[j] == 0 and j - i >= 4:
            strs[va(i)] = data[i:j].decode()
        i = j
    i += 1

cdata = json.load(open(WORK + '/war_cluster.json'))
nclusters = json.load(open(WORK + '/war_norm.json'))

# bodies from cluster data (GARA entries)
bodies = {}
for as_, v in cdata['files'][REF]['funcs'].items():
    bodies[int(as_, 16)] = v

# invert: addr -> cluster
addr2cl = {}
for h, members in nclusters.items():
    for fn, a, n in members:
        if fn == REF:
            addr2cl.setdefault(int(a, 16), []).append(h)

def summarize(a):
    v = bodies[a]
    # walk contiguous range entry..end collecting real insns
    insns = []
    x = a
    while x <= v['end']:
        ins = dec(x)
        if ins: insns.append((x, ins))
        x += 4
    ext, srefs, drefs, intrac = [], set(), set(), []
    has_jrreg = False
    vals = {}
    for x, ins in insns:
        w = words[(x - BASE) // 4]; op = w >> 26
        m = ins.mnemonic
        rs, rt = (w >> 21) & 31, (w >> 16) & 31
        rd = (w >> 11) & 31
        imm = w & 0xFFFF; simm = imm - 0x10000 if imm & 0x8000 else imm
        if m == 'lui':
            vals[rt] = imm << 16
        elif m in ('addiu', 'addi'):
            if rs in vals: vals[rt] = (vals[rs] + simm) & 0xFFFFFFFF
            else: vals.pop(rt, None)
        elif m == 'ori':
            if rs in vals: vals[rt] = (vals[rs] | imm) & 0xFFFFFFFF
            else: vals.pop(rt, None)
        elif m == 'addu' and rs in vals and rt in vals:
            vals[rd] = (vals[rs] + vals[rt]) & 0xFFFFFFFF
        else:
            try:
                for o in ins.operands:
                    if o.type == 2 and (o.access & 2) and o.reg < 32:
                        vals.pop(o.reg, None)
            except: pass
        if op == 3:
            t = jtarget(x, w)
            if in_range(t): intrac.append(t)
            else: ext.append(t)
        elif m == 'jalr':
            if rs in vals:
                t = vals[rs]
                if in_range(t): intrac.append(t)
                else: ext.append(t)
            else:
                ext.append(('jalr?', rs))
        if m == 'jr' and 'ra' not in ins.op_str: has_jrreg = True
        if m in ('lw','sw','lbu','sb','lh','sh','lhu') and rs in vals:
            addr = (vals[rs] + simm) & 0xFFFFFFFF
            if addr in strs: srefs.add(addr)
            elif in_range(addr): drefs.add(addr)
    ext_real = sorted(set(t for t in ext if isinstance(t, int)))
    ext_unres = sorted(set(t[1] for t in ext if isinstance(t, tuple)))
    return {
        'n': len(insns),
        'ext': ext_real,
        'ext_named': sorted(set((t, main.get(t, '?')) for t in ext_real)),
        'ext_unres': ext_unres,
        'strs': sorted(srefs),
        'drefs': sorted(drefs)[:8],
        'intrac': sorted(set(intrac))[:12],
        'n_intrac': len(set(intrac)),
        'jrreg': has_jrreg,
    }

only = sys.argv[2:] if len(sys.argv) > 2 else None
# order clusters by min GARA addr
clus = []
for h, members in nclusters.items():
    gaddrs = sorted(int(a, 16) for fn, a, n in members if fn == REF)
    if not gaddrs: continue
    files = sorted({fn for fn, _, _ in members})
    clus.append((gaddrs[0], h, gaddrs, files))
clus.sort()
for gmin, h, gaddrs, files in clus:
    if only and not any(h.startswith(p) for p in only): continue
    s = summarize(gmin)
    filetag = 'ALL9' if files == FILES else ('GARA+' + str(len(files)-1) if 'WAR_GARA.BIN' in files else 'NO-GARA')
    line = f"{h} @{hex(gmin)} n={s['n']} {filetag}"
    if len(gaddrs) > 1: line += f" x{len(gaddrs)}addrs"
    if s['jrreg']: line += " JRREG"
    if s['n_intrac']: line += f" ic={s['n_intrac']}"
    if s['ext_named']:
        line += " ext=" + ",".join(f"{hex(t)}:{nm}" for t, nm in s['ext_named'][:8])
    if s['ext_unres']: line += " unres_jalr"
    if s['strs']:
        line += " str=" + "|".join(f"{hex(a)}:{strs[a][:28]!r}" for a in s['strs'][:4])
    if s['drefs']:
        line += " data=" + ",".join(hex(a) for a in s['drefs'])
    print(line)
