#!/usr/bin/env python3
"""slus_analyze.py — function discovery + per-function summaries for SLUS_body.bin.
Usage: slus_analyze.py [--seeds-only] [--funcs] [--summary <csv_out>]
Discovers functions: entry 0x800241C4 + prologue scan + j/jal targets,
recursive descent from seeds, jr $ra boundary analysis for frameless code.
"""
import sys, struct, re, json
from collections import Counter, defaultdict
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

PATH = '/home/hatch/workspace/suikoden/SLUS_body.bin'
BASE = 0x80010000
ENTRY = 0x800241C4
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
    try:
        for ins in md.disasm(data[o:o+4], BASE + o, count=1):
            insns[ins.address] = ins
            break
    except Exception:
        pass

def get(a): return insns.get(a)
def word_at(a):
    o = off(a)
    if 0 <= o <= len(data) - 4 and o % 4 == 0:
        return words[o // 4]
    return None

def imm16(w): return (w & 0xFFFF) - 0x10000 if (w & 0x8000) else (w & 0xFFFF)
def jtarget(a, w): return ((a + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)

# ---------------- strings ----------------
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
            else:
                for m in re.finditer(rb'[A-Za-z_][A-Za-z0-9_]{3,}|%[0-9]*[dxXsu]|--[a-z]+--[a-z%]+', run):
                    tok = m.group(0).decode('ascii')
                    if re.search(r'[a-zA-Z]{2}', tok):
                        out.append((va(i + m.start()), tok))
            i = j
        i += 1
    seen = set(); res = []
    for a, s in out:
        if (a, s) not in seen: seen.add((a, s)); res.append((a, s))
    return res

strings = find_strings()
print(f"strings found: {len(strings)}", file=sys.stderr)

# ---------------- seeds ----------------
seeds = {ENTRY}
for i, w in enumerate(words):
    op = w >> 26
    if op == 9:  # addiu
        rs, rt = (w >> 21) & 31, (w >> 16) & 31
        im = imm16(w)
        if rs == 29 and rt == 29 and im < 0 and -im % 8 == 0 and -im < 0x2000:
            seeds.add(va(i * 4))
for i, w in enumerate(words):
    op = w >> 26
    if op in (2, 3):
        t = jtarget(va(i * 4), w)
        if in_range(t) and t % 4 == 0:
            seeds.add(t)
print(f"seeds: {len(seeds)}", file=sys.stderr)

# ---------------- recursive descent ----------------
# function body = reachable instructions from seed, stop at jr $ra / jr reg
# (jr $ra usually ends function; jr $t9 etc. = tail call / switch)
def descend(seed):
    body = set()
    stack = [seed]
    while stack:
        a = stack.pop()
        if a in body or not in_range(a): continue
        ins = get(a)
        if ins is None: continue
        body.add(a)
        mn = ins.mnemonic
        if mn == 'jr':
            continue  # end of this path
        elif mn in ('j', 'jal'):
            t = int(ins.op_str, 16) if ins.op_str.startswith('0x') else None
            if t is None:
                try: t = int(ins.op_str, 0)
                except: t = None
            if t is not None and in_range(t):
                stack.append(t)
                # delay slot
                ds = get(a + 4)
                if ds is not None: body.add(a + 4)
            if mn == 'j':
                continue  # unconditional: no fallthrough
            stack.append(a + 8)
        elif mn.startswith('b'):
            # branch: both paths
            stack.append(a + 8)
            try:
                t = int(ins.op_str.split(',')[-1].strip(), 0)
                if in_range(t): stack.append(t)
            except: pass
        else:
            stack.append(a + 4)
    return body

seed_bodies = {}
for s in sorted(seeds):
    seed_bodies[s] = descend(s)

# ---------------- jr $ra boundaries ----------------
# any address that is a jr $ra target-return site: instruction after jr $ra
# that is a seed or reachable start = function end; also find jr $ra addrs
# whose preceding code isn't covered by any seed body -> frameless function starts
jr_ra_addrs = []
for a, ins in insns.items():
    if ins.mnemonic == 'jr' and ins.op_str.strip() in ('$ra', '$31'):
        jr_ra_addrs.append(a)

covered = set()
for b in seed_bodies.values(): covered |= b

# find function starts via: for each jr $ra at X, scan backward for the
# function start (nearest seed or nearest address after previous jr $ra)
# and forward: next function likely starts at X+8
funcs = {}  # start -> set(body addrs)
for s, b in seed_bodies.items():
    funcs[s] = b

# frameless: jr $ra whose function isn't seeded — walk back to find start
for jra in sorted(jr_ra_addrs):
    # is the code before jra covered?
    if jra in covered: continue
    # walk back up to 2000 insns looking for a plausible start:
    # stop at previous jr $ra, or an address that's a known func start
    start = None
    a = jra - 4
    steps = 0
    while steps < 2000 and in_range(a):
        if a in funcs:
            break
        pins = get(a)
        if pins is not None and pins.mnemonic == 'jr':
            start = a + 8
            break
        a -= 4; steps += 1
    else:
        continue
    if start is None: continue
    if start in funcs: continue
    # descend from candidate start to verify it reaches jra
    b = descend(start)
    if jra in b and len(b) > 2:
        funcs[start] = b
        covered |= b

print(f"functions discovered: {len(funcs)}", file=sys.stderr)

if '--seeds-only' in sys.argv:
    for s in sorted(funcs): print(f"{s:#010x}")
    sys.exit(0)

# ---------------- per-function summaries ----------------
# string refs: lui/addiu pairs resolving to string addresses
str_set = {a for a, _ in strings}
str_by_addr = {a: s for a, s in strings}

def summarize(start, body):
    calls = []
    strrefs = []
    absrefs = []
    has_loop = False
    v0 = None
    sorted_body = sorted(body)
    # track lui values for string resolution
    lui_vals = {}
    for a in sorted_body:
        ins = get(a)
        if ins is None: continue
        mn = ins.mnemonic
        if mn == 'lui':
            try:
                parts = ins.op_str.split(',')
                rt = parts[0].strip(); im = int(parts[1].strip(), 0)
                lui_vals[rt] = im << 16
            except: pass
        elif mn in ('addiu', 'ori', 'addi'):
            try:
                parts = ins.op_str.split(',')
                rt, rs = parts[0].strip(), parts[1].strip()
                im = int(parts[2].strip(), 0)
                if rs in lui_vals:
                    addr = (lui_vals[rs] + im) & 0xFFFFFFFF
                    if addr in str_set:
                        strrefs.append(str_by_addr[addr])
                    elif 0x80000000 <= addr < 0x80200000:
                        absrefs.append(addr)
            except: pass
        elif mn == 'jal':
            try: t = int(ins.op_str, 0)
            except: t = None
            if t is not None: calls.append(t)
        elif mn in ('bne', 'beq', 'blez', 'bgtz', 'bltz', 'bgez'):
            try:
                t = int(ins.op_str.split(',')[-1].strip(), 0)
                if t is not None and t <= a: has_loop = True
            except: pass
    # syscall?
    syscalls = [a for a in sorted_body if get(a) is not None and get(a).mnemonic == 'syscall']
    return {
        'start': start, 'size': len(body),
        'calls': sorted(set(calls)),
        'strrefs': strrefs[:8],
        'absrefs': sorted(set(absrefs))[:8],
        'has_loop': has_loop,
        'syscalls': syscalls,
    }

if '--funcs' in sys.argv:
    for s in sorted(funcs):
        sm = summarize(s, funcs[s])
        print(f"{s:#010x} size={sm['size']:4d} calls={len(sm['calls'])} strs={len(sm['strrefs'])} loop={sm['has_loop']} sys={len(sm['syscalls'])}")
    sys.exit(0)

if '--summary' in sys.argv:
    out = sys.argv[sys.argv.index('--summary') + 1]
    with open(out, 'w') as f:
        for s in sorted(funcs):
            sm = summarize(s, funcs[s])
            f.write(json.dumps({
                'a': hex(s), 'n': sm['size'],
                'calls': [hex(c) for c in sm['calls']],
                'strs': sm['strrefs'],
                'abs': [hex(x) for x in sm['absrefs']],
                'loop': sm['has_loop'], 'sys': len(sm['syscalls']),
            }) + '\n')
    print(f"wrote {out}", file=sys.stderr)
