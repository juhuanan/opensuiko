#!/usr/bin/env python3
"""Register-passed 0x34-struct +0xC sweep over MAIN.EXE code.

Primary: every `lw $r,0xC($base)` (base != $sp/$fp), fingerprint the base
register via co-accessed struct offsets, and track the dest reg forward for
(a) indexed pointer-table deref, (b) byte-walk, (c) pass-as-arg, (d) compare/store.
Secondary: the sll/addu/lw idiom anchored on ANY lw, then backward-trace check.
"""
import sys
sys.path.insert(0, '/home/hatch/workspace/suikoden/kit/work')
from fsweep_helper import DATA, BASE, FUNCS, MD, func_of, disas_range, fmt
from capstone import CS_AC_READ, CS_AC_WRITE, CS_GRP_JUMP, CS_GRP_CALL, CS_GRP_RET
from capstone.mips_const import MIPS_OP_REG, MIPS_OP_MEM, MIPS_OP_IMM

SP_FP = {'sp', 'fp'}
EXCLUDE = {0x800c4538, 0x80127de0, 0x80127e4c, 0x80132228, 0x80142180}
STRUCT_OFFS = {0x0, 0x1, 0x2, 0x4, 0x8, 0x10}
LOAD_MN = {'lw', 'lh', 'lhu', 'lb', 'lbu', 'lwu', 'lwl', 'lwr'}
STORE_MN = {'sw', 'sh', 'sb', 'swl', 'swr', 'sc', 'swc1', 'sdc1'}
FLOAT_MN = {'lwc1', 'swc1', 'mtc1', 'mfc1', 'dmfc1', 'dmtc1', 'cfc1', 'ctc1'}
ARG_REGS = ('a0', 'a1', 'a2', 'a3')


BRANCH_MN = {'beq', 'bne', 'beql', 'bnel', 'blt', 'bltu', 'bge', 'bgeu',
              'bltz', 'bgez', 'bltzl', 'bgezl', 'bltzal', 'bltzall',
              'bgezal', 'bgezall', 'bgtz', 'bgtzl', 'blez', 'blezl',
              'bc1t', 'bc1f', 'bc1tl', 'bc1fl', 'bc2t', 'bc2f'}
NOWRITE_MN = {'mult', 'multu', 'div', 'divu', 'madd', 'msub', 'mthi', 'mtlo',
              'mtc0', 'mtc1', 'mtc2', 'dmtc1', 'ctc1', 'ctc2', 'cache',
              'sync', 'syscall', 'break', 'eret', 'wait', 'tlbp', 'tlbr',
              'tlbwi', 'tlbwr', 'nop'}


def decode(ins):
    mn = ins.mnemonic
    writes, reads = set(), set()
    mem = None
    store_src = None
    regops = []
    for op in ins.operands:
        if op.type == MIPS_OP_REG:
            regops.append(ins.reg_name(op.reg))
        elif op.type == MIPS_OP_MEM:
            b = ins.reg_name(op.mem.base)
            mem = (b, op.mem.disp)
            reads.add(b)
    if mn in STORE_MN:
        reads.update(regops)
        if regops:
            store_src = regops[0]
    elif mn == 'jal':
        writes.add('ra')
    elif mn == 'jalr':
        if len(regops) == 2:
            writes.add(regops[0])
            reads.add(regops[1])
        elif regops:
            writes.add('ra')
            reads.add(regops[0])
    elif mn in BRANCH_MN or mn in ('jr',):
        reads.update(regops)
    elif mn in NOWRITE_MN:
        reads.update(regops)
    else:
        if regops:
            writes.add(regops[0])
            reads.update(regops[1:])
    shamt = None
    if mn == 'sll':
        for op in ins.operands:
            if op.type == MIPS_OP_IMM:
                shamt = op.imm
    target = None
    for op in ins.operands:
        if op.type == MIPS_OP_IMM:
            target = op.imm & 0xFFFFFFFF
            break
    return dict(mn=mn, writes=writes, reads=reads, mem=mem, store_src=store_src,
                shamt=shamt, is_jump=ins.group(CS_GRP_JUMP),
                is_call=ins.group(CS_GRP_CALL), is_ret=ins.group(CS_GRP_RET),
                target=target)


def callee_name(tgt):
    try:
        f = func_of(tgt)
        return '%s%s' % (f[1], '' if f[0] == tgt else '+%#x' % (tgt - f[0]))
    except Exception:
        return '?'


def forward_taint(insns, feats, start, seed, sll_all, full=True):
    """Track seed reg forward. Returns event list.

    full=True: collect (a)/(b)/(c)/(d) events. full=False: (a)-only fast path.
    """
    tainted = {seed}
    ev = []
    sll_live = dict(sll_all)  # reg -> (sll_addr, shamt)
    addu_t = {}               # reg -> (addu_addr, sll_addr)
    n = len(feats)
    for i in range(start + 1, n):
        f = feats[i]
        ins = insns[i]
        a = ins.address
        mn = f['mn']
        # invalidate sll regs overwritten by other insns
        for w in f['writes']:
            if w in sll_live and not (mn == 'sll' and f['shamt'] in (1, 2)):
                del sll_live[w]
            if w in addu_t:
                del addu_t[w]
        if f['mem'] is not None:
            base, disp = f['mem']
            if mn in LOAD_MN:
                if full and base in tainted:
                    ev.append(('b', a, '%s base=$%s disp=%#x' % (mn, base, disp)))
                if base in addu_t:
                    aa, sa, sh = addu_t[base]
                    ev.append(('a', a,
                               'INDEXED %s ($%s)+%#x via addu@%#x (sll@%#x sh=%d)' %
                               (mn, base, disp, aa, sa, sh)))
                    # keep detail simple; recompute shamt below
            elif mn in STORE_MN:
                if full and f['store_src'] in tainted:
                    ev.append(('d-store', a, '%s $%s -> ($%s)+%#x' %
                               (mn, f['store_src'], base, disp)))
        if f['is_call']:
            args = [r for r in ARG_REGS if r in tainted]
            if full and args:
                if f['target']:
                    ev.append(('c', a, 'args %s -> jal %#x %s' %
                               (args, f['target'], callee_name(f['target']))))
                else:
                    ev.append(('c', a, 'args %s -> jalr' % (args,)))
            # a call clobbers t0-t9/v0/v1/a0-a3/ra in spirit; keep taint (best effort)
        elif f['is_jump']:
            tr = f['reads'] & tainted
            if full and tr and not f['is_ret']:
                ev.append(('d-cmp', a, 'branch on $%s' % ','.join(sorted(tr))))
        if mn in ('slt', 'sltu', 'slti', 'sltiu') and (f['reads'] & tainted):
            if full:
                ev.append(('d-cmp', a, 'slt on tainted'))
        if mn in ('addu', 'add', 'daddu', 'dadd'):
            srcs = f['reads']
            if (srcs & tainted) and (srcs & set(sll_live)):
                for w in f['writes']:
                    if w != 'zero':
                        sr = next(iter(srcs & set(sll_live)))
                        ssa, sh = sll_live[sr]
                        addu_t[w] = (a, ssa, sh)
        # generic propagation
        if f['writes'] and (f['reads'] & tainted):
            tainted |= (f['writes'] - {'zero'})
    return ev


def fingerprint(feats, base):
    offs = {}
    for f in feats:
        if f['mem'] and f['mem'][0] == base and \
                f['mn'] in LOAD_MN | STORE_MN | {'lwc1'}:
            offs.setdefault(f['mem'][1], 0)
            offs[f['mem'][1]] += 1
    struct_hits = sorted(o for o in offs if o in STRUCT_OFFS)
    return struct_hits, offs


def provenance(insns, feats, hit_idx, base):
    for i in range(hit_idx - 1, -1, -1):
        if base in feats[i]['writes']:
            return insns[i].address, fmt(insns[i])
    if base in ARG_REGS:
        return None, 'never written in func: incoming arg $%s' % base
    return None, 'never written in func (global/unknown $%s)' % base


def main():
    out = []
    # ---- per-function pre-decode ----
    funcs = []
    for va, name, size in FUNCS:
        try:
            insns = disas_range(va, va + size)
        except Exception:
            continue
        feats = [decode(i) for i in insns]
        sll_all = {}
        float_n = 0
        has_loop = False
        for i, f in zip(insns, feats):
            if f['mn'] == 'sll' and f['shamt'] in (1, 2):
                w = (f['writes'] - {'zero'})
                if w:
                    sll_all[next(iter(w))] = (i.address, f['shamt'])
            if f['mn'] in FLOAT_MN or f['mn'].endswith(('.s', '.d')) \
                    or f['mn'].startswith('c.'):
                float_n += 1
            if f['is_jump'] and not f['is_call'] and not f['is_ret'] \
                    and f['target'] is not None and f['target'] < i.address:
                has_loop = True
        funcs.append((va, name, size, insns, feats, sll_all, float_n, has_loop))

    # ---- PRIMARY sweep: lw $r,0xC($base) ----
    hits = []  # (va,name,load_addr,dest,base)
    for va, name, size, insns, feats, sll_all, float_n, has_loop in funcs:
        for i, f in zip(insns, feats):
            if f['mn'] != 'lw' or not f['mem']:
                continue
            base, disp = f['mem']
            if disp != 0xC or base in SP_FP or base == 'zero':
                continue
            if i.address in EXCLUDE:
                continue
            dest = (f['writes'] - {'zero'})
            if not dest:
                continue
            hits.append((va, name, i.address, next(iter(dest)), base))

    out.append('PRIMARY HITS: %d lw+0xC (base not sp/fp, excl. 5 known init addrs)'
               % len(hits))

    strong = []
    for va, name, laddr, dest, base in hits:
        rec = next(r for r in funcs if r[0] == va)
        _, _, _, insns, feats, sll_all, float_n, has_loop = rec
        idx = next(k for k, x in enumerate(insns) if x.address == laddr)
        shits, offs = fingerprint(feats, base)
        score = len(shits)
        verdict = 'STRONG' if score >= 3 else ('weak' if score >= 1 else 'none')
        paddr, prov = provenance(insns, feats, idx, base)
        ev = forward_taint(insns, feats, idx, dest, sll_all, full=True)
        kinds = sorted(set(k for k, _, _ in ev))
        flow = ','.join(kinds) if kinds else 'IGNORED'
        if score >= 3:
            strong.append((va, name, laddr))
        out.append('---')
        out.append('FUNC %#x %s | load@%#x dest=$%s base=$%s' %
                   (va, name, laddr, dest, base))
        out.append('  fingerprint: %s (%d/6) struct_offs=%s all_offs=%s' %
                   (verdict, score,
                    ['%#x' % o for o in shits],
                    sorted('%#x:%d' % (o, c) for o, c in offs.items())))
        out.append('  base provenance: %s' %
                   ((' %#x %s' % (paddr, prov)) if paddr else prov))
        out.append('  dest flow: %s%s' % (flow, ' loop=%s' % has_loop if any(
            k == 'b' for k, _, _ in ev) else ''))
        for k, a, d in ev:
            out.append('    [%s] %#x %s' % (k, a, d))
        if float_n > 8:
            out.append('  NOTE: heavy float/cop1 use (%d insns)' % float_n)

    out.append('')
    out.append('STRONG-FINGERPRINT FUNCTIONS: %d' % len(strong))

    # ---- SECONDARY sweep: sll/addu/lw idiom on ANY lw ----
    out.append('')
    out.append('SECONDARY SWEEP (idiom on any lw):')
    seen = set()
    sec = []
    for va, name, size, insns, feats, sll_all, float_n, has_loop in funcs:
        if not sll_all:
            continue
        for k, f in enumerate(feats):
            if f['mn'] != 'lw' or not f['mem']:
                continue
            base, disp = f['mem']
            if base in SP_FP or base == 'zero':
                continue
            dest = (f['writes'] - {'zero'})
            if not dest:
                continue
            B = next(iter(dest))
            ev = forward_taint(insns, feats, k, B, sll_all, full=False)
            for ek, ea, ed in ev:
                if ek != 'a':
                    continue
                key = (va, ea)
                if key in seen:
                    continue
                seen.add(key)
                # backward trace: does this func also do lw+0xC off `base`?
                plusc = [x.address for x, ff in zip(insns, feats)
                         if ff['mn'] == 'lw' and ff['mem'] == (base, 0xC)]
                sec.append((va, name, insns[k].address, disp, base, ea, ed,
                            plusc))
    for va, name, aaddr, disp, base, eaddr, ed, plusc in sec:
        tag = 'PRIMARY-OVERLAP' if disp == 0xC else 'disp=%#x' % disp
        out.append('  %#x %s anchor lw@%#x $%s,%#x($%s) [%s] -> %#x %s %s' %
                   (va, name, aaddr, '?', disp, base, tag, eaddr, ed,
                    ('same-func +0xC off $%s @%s' % (base, ['%#x' % x for x in plusc])
                     if plusc else '')))
    out.append('SECONDARY idiom sites: %d' % len(sec))

    sys.stdout.write('\n'.join(out) + '\n')


if __name__ == '__main__':
    main()
