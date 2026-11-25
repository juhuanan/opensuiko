#!/usr/bin/env python3
"""slus_summ.py — per-function summaries for SLUS_body.bin labeling.
Usage: slus_summ.py --build   (writes /tmp/slus_summ.json)
       slus_summ.py --show <addr>   (pretty summary of one function)
       slus_summ.py --strings       (dump string table)
Summary per function: size, jal calls, string refs (via lui tracking),
absolute RAM refs, loop?, syscall?, first/last few instructions.
"""
import sys, struct, re, json
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

PATH = '/home/hatch/workspace/suikoden/SLUS_body.bin'
BASE = 0x80010000
data = open(PATH, 'rb').read()
nwords = len(data) // 4
words = struct.unpack('<%dI' % nwords, data)
def va(off): return BASE + off
def off(a): return a - BASE
def in_range(a): return BASE <= a < BASE + len(data)

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
md.detail = True
insns = {}
for o in range(0, len(data) - 3, 4):
    a = BASE + o
    try:
        for ins in md.disasm(data[o:o+4], a, count=1):
            insns[a] = (words[o//4], ins.mnemonic, ins.op_str)
            break
    except Exception:
        pass

def find_strings():
    out = []
    i, n = 0, len(data)
    while i < n:
        if 32 <= data[i] < 127:
            j = i
            while j < n and 32 <= data[j] < 127: j += 1
            run = data[i:j]
            try: txt = run.decode('ascii')
            except: txt = ''
            if len(run) >= 6 and j < n and data[j] == 0 and re.search(r'[a-z]{2,}', txt):
                out.append((va(i), txt))
            i = j
        i += 1
    return out

STRINGS = find_strings()
STR_AT = {a: s for a, s in STRINGS}

def load_funcs():
    funcs = {}
    with open('/tmp/slus_funcs.txt') as f:
        for line in f:
            p = line.split()
            a = int(p[0], 16); funcs[a] = []
    # bodies recomputed via json if present
    try:
        with open('/tmp/slus_funcs.json') as f:
            j = json.load(f)
        return {int(k,16): v for k,v in j.items()}
    except FileNotFoundError:
        return None

def imm16(w): return (w & 0xFFFF) - 0x10000 if (w & 0x8000) else (w & 0xFFFF)
def jtarget(a, w): return ((a + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)

def summarize(start, body):
    body = sorted(body)
    calls, strrefs, absrefs = [], [], []
    lui_vals = {}
    has_loop = False
    syscalls = 0
    for a in body:
        r = insns.get(a)
        if r is None: continue
        w, mn, ops = r
        if mn == 'lui':
            try:
                rt, im = [x.strip() for x in ops.split(',')]
                lui_vals[rt] = int(im, 0) << 16
            except: pass
        elif mn in ('addiu', 'ori', 'addi', 'lw', 'sw', 'lbu', 'sb', 'lh', 'sh', 'lhu'):
            try:
                parts = [x.strip() for x in ops.split(',')]
                if len(parts) == 3:
                    rt, rs, ims = parts
                    im = int(ims, 0)
                    if rs in lui_vals:
                        addr = (lui_vals[rs] + (imm16(w) if mn in ('addiu','addi','lw','sw','lbu','sb','lh','sh','lhu') else im)) & 0xFFFFFFFF
                        if addr in STR_AT and addr not in [x[0] for x in strrefs]:
                            strrefs.append((addr, STR_AT[addr][:60]))
                        elif 0x80000000 <= addr < 0x80300000:
                            absrefs.append(addr)
                elif '(' in ops:  # lw $r, off($base) without lui
                    pass
            except: pass
        elif mn == 'jal':
            try: t = int(ops, 0)
            except: t = None
            if t is not None and t not in calls: calls.append(t)
        elif mn in ('bne','beq','blez','bgtz','bltz','bgez','bnez','beqz'):
            try:
                t = int(ops.split(',')[-1].strip(), 0)
                if t <= a: has_loop = True
            except: pass
        elif mn == 'syscall':
            syscalls += 1
    head = []
    for a in body[:6]:
        r = insns.get(a)
        if r: head.append(f"{a:#010x} {r[1]} {r[2]}")
    tail = []
    for a in body[-4:]:
        r = insns.get(a)
        if r: tail.append(f"{a:#010x} {r[1]} {r[2]}")
    return {'a': start, 'n': len(body), 'calls': calls,
            'strs': strrefs, 'abs': sorted(set(absrefs))[:10],
            'loop': has_loop, 'sys': syscalls, 'head': head, 'tail': tail}

def main():
    if '--strings' in sys.argv:
        for a, s in STRINGS:
            print(f"{a:#010x} {s[:80]}")
        return
    if '--build' in sys.argv:
        sys.path.insert(0, '/home/hatch/workspace/suikoden/kit/work/overlays')
        import slus_dis as D
        seeds = D.find_seeds()
        bodies = {s: D.descend(s) for s in sorted(seeds)}
        starts = set()
        for s in sorted(seeds):
            if not any(t != s and s in b for t, b in bodies.items()):
                starts.add(s)
        final = {s: sorted(D.descend(s, func_starts=starts)) for s in sorted(starts)}
        # frameless
        jr_ra = [a for a, r in D.insns.items() if r[1] == 'jr' and r[2].strip() in ('$ra', '$31')]
        covered = set()
        for b in final.values(): covered |= set(b)
        for jra in sorted(jr_ra):
            if jra in covered: continue
            a = jra - 4; start = None
            for _ in range(3000):
                if not D.in_range(a): break
                if a in starts: break
                r = D.get(a)
                if r is not None and r[1] == 'jr':
                    start = a + 8; break
                a -= 4
            if start is None or start in final or not D.in_range(start): continue
            b = D.descend(start, func_starts=set(final) | {start})
            if jra in b and len(b) > 2:
                final[start] = b; covered |= set(b)
        with open('/tmp/slus_funcs.json', 'w') as f:
            json.dump({hex(s): sorted(b) for s, b in final.items()}, f)
        with open('/tmp/slus_funcs.txt', 'w') as f:
            for s in sorted(final):
                f.write(f"{s:#010x} {len(final[s])}\n")
        # summaries
        with open('/tmp/slus_summ.json', 'w') as f:
            for s in sorted(final):
                f.write(json.dumps({'a': hex(s),
                    **{k: v for k, v in summarize(s, final[s]).items() if k != 'a'}},
                    default=lambda o: o) + '\n')
        print(f"functions: {len(final)}, summaries written", file=sys.stderr)
        return
    if '--show' in sys.argv:
        a = int(sys.argv[sys.argv.index('--show') + 1], 16)
        found = None
        with open('/tmp/slus_summ.json') as f:
            for line in f:
                j = json.loads(line)
                if int(j['a'], 16) == a:
                    found = j; break
        if not found:
            print("not found"); return
        print(f"== {found['a']}  size={found['n']} loop={found['loop']} syscall={found['sys']}")
        print("calls:", ' '.join(f"{c:#010x}" for c in found['calls'][:20]))
        for sa, ss in found['strs'][:10]:
            print(f"  str {sa:#010x}: {ss}")
        if found['abs']:
            print("abs:", ' '.join(f"{x:#010x}" for x in found['abs'][:10]))
        print("head:"); [print("   ", h) for h in found['head']]
        print("tail:"); [print("   ", t) for t in found['tail']]

if __name__ == '__main__':
    main()
