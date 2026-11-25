#!/usr/bin/env python3
"""slus_dis.py — clean disassembly + function discovery for SLUS_body.bin.
Base 0x80010000, entry 0x800241C4.
"""
import sys, struct, re, json
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

# per-word independent decode
insns = {}
for o in range(0, len(data) - 3, 4):
    a = BASE + o
    w = words[o // 4]
    try:
        for ins in md.disasm(struct.pack('<I', w), a, count=1):
            insns[a] = (w, ins.mnemonic, ins.op_str)
            break
    except Exception:
        pass

def get(a):
    return insns.get(a)  # (word, mnemonic, op_str) or None

def imm16(w): return (w & 0xFFFF) - 0x10000 if (w & 0x8000) else (w & 0xFFFF)
def jtarget(a, w): return ((a + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)
def brtarget(a, w):
    return (a + 4 + (imm16(w) << 2)) & 0xFFFFFFFF

def is_prologue(w):
    if (w >> 26) != 9: return False
    rs, rt = (w >> 21) & 31, (w >> 16) & 31
    im = imm16(w)
    return rs == 29 and rt == 29 and im < 0 and -im % 8 == 0 and -im < 0x2000

def find_seeds():
    seeds = {ENTRY}
    for i, w in enumerate(words):
        a = va(i * 4)
        if is_prologue(w):
            seeds.add(a)
        op = w >> 26
        if op in (2, 3):
            t = jtarget(a, w)
            if in_range(t):
                seeds.add(t)
    return seeds

def descend(seed, func_starts=None):
    """Recursive descent. Returns set of addresses in this function body.
    Stops at jr (any), returns, and does NOT cross known function starts
    (except the seed itself) to avoid merging."""
    body = set()
    stack = [seed]
    while stack:
        a = stack.pop()
        if a in body or not in_range(a):
            continue
        if func_starts is not None and a != seed and a in func_starts:
            continue
        r = get(a)
        if r is None:
            continue
        w, mn, ops = r
        body.add(a)
        if mn == 'jr':
            continue
        elif mn == 'j':
            t = jtarget(a, w)
            if in_range(t):
                stack.append(t)
            # delay slot
            if get(a + 4): body.add(a + 4)
            continue  # no fallthrough
        elif mn == 'jal':
            t = jtarget(a, w)
            if in_range(t) and not (func_starts and t in func_starts):
                pass  # callee handled separately; don't descend into
            stack.append(a + 8)
            if get(a + 4): body.add(a + 4)
        elif mn == 'syscall' or mn == 'break':
            continue
        elif mn.startswith('b'):
            stack.append(a + 8)
            t = brtarget(a, w)
            if in_range(t):
                stack.append(t)
        else:
            stack.append(a + 4)
    return body

def main():
    seeds = find_seeds()
    print(f"seeds: {len(seeds)}", file=sys.stderr)
    # two passes: first descend all seeds without start-blocking to find
    # which seeds are actually inside other functions; then final pass
    bodies = {}
    for s in sorted(seeds):
        bodies[s] = descend(s)
    # a seed inside another seed's body (and not equal) is not a function start
    # unless it's a known entry (j target of a call). Keep it simple:
    # function starts = seeds that are not strictly inside another seed's body
    starts = set()
    for s in sorted(seeds):
        inside = False
        for t, b in bodies.items():
            if t != s and s in b:
                inside = True
                break
        if not inside:
            starts.add(s)
    print(f"function starts after containment filter: {len(starts)}", file=sys.stderr)
    # final bodies with start-blocking
    final = {}
    for s in sorted(starts):
        final[s] = descend(s, func_starts=starts)
    # frameless: jr $ra sites whose function has no start
    jr_ra = [a for a, r in insns.items() if r[1] == 'jr' and r[2].strip() in ('$ra', '$31')]
    covered = set()
    for b in final.values(): covered |= b
    added = 0
    for jra in sorted(jr_ra):
        if jra in covered:
            continue
        # walk back to find start: previous jr, or known start
        a = jra - 4
        start = None
        for _ in range(3000):
            if not in_range(a):
                break
            if a in starts:
                break
            r = get(a)
            if r is not None and r[1] == 'jr':
                start = a + 8
                break
            a -= 4
        if start is None or start in final or not in_range(start):
            continue
        b = descend(start, func_starts=set(final) | {start})
        if jra in b and len(b) > 2:
            final[start] = b
            covered |= b
            added += 1
    print(f"frameless added: {added}", file=sys.stderr)
    print(f"total functions: {len(final)}", file=sys.stderr)
    if '--out' in sys.argv:
        out = sys.argv[sys.argv.index('--out') + 1]
        with open(out, 'w') as f:
            for s in sorted(final):
                f.write(f"{s:#010x} {len(final[s])}\n")
        print(f"wrote {out}", file=sys.stderr)
    if '--json' in sys.argv:
        out = sys.argv[sys.argv.index('--json') + 1]
        with open(out, 'w') as f:
            json.dump({hex(s): sorted(b) for s, b in final.items()}, f)
        print(f"wrote {out}", file=sys.stderr)

if __name__ == '__main__':
    main()
