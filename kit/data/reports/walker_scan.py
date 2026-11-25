#!/usr/bin/env python3
"""Scan PS1 overlay binaries + SLUS for the .8 16-byte-record walker.

Signature: a loop containing
  - addiu $r, $r, 0x10        (16-byte stride pointer advance)
  - lhu/lh $t, off($r)       (tag load from record pointer)
  - backward branch forming the loop
Plus (stronger): jump-table dispatch (sll by 2 / lw / jr) or tag compare.
"""
import csv, struct, sys
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

EXT = '/home/hatch/workspace/suikoden/kit/extracted/bin_overlays'
SLUS = '/home/hatch/workspace/suikoden/SLUS_body.bin'

def load(path):
    with open(path, 'rb') as f:
        return f.read()

def disasm(data, base):
    md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_LITTLE_ENDIAN)
    md.detail = True
    md.skipdata = True
    return [i for i in md.disasm(data, base) if i.mnemonic != '.byte']

def find_loops(insns):
    """Return list of (target_idx, branch_idx) for backward branches/jumps."""
    res = []
    addr2idx = {i.address: n for n, i in enumerate(insns)}
    for n, i in enumerate(insns):
        m = i.mnemonic
        is_br = (m.startswith('b') and m != 'break') or m in ('j',)
        if not is_br or not i.op_str:
            continue
        try:
            tgt = int(i.op_str.split(',')[-1].strip(), 0)
        except ValueError:
            continue
        if tgt in addr2idx and addr2idx[tgt] < n:
            res.append((addr2idx[tgt], n))
    return res

def regs_of(insn):
    return [r for r in insn.regs_access()[0]]

def regs_written(insn):
    return [r for r in insn.regs_access()[1]]

def scan_one(data, base, name):
    insns = disasm(data, base)
    if not insns:
        return []
    hits = []
    for t_idx, b_idx in find_loops(insns):
        if b_idx - t_idx > 400:
            continue  # phantom loop from misdisassembled data
        body = insns[t_idx:b_idx + 1]
        stride_regs = set()   # regs advanced by exactly 0x10
        lhu_regs = {}         # ptr reg -> list of (insn_idx, offset)
        has_jr_dispatch = False
        has_tag_cmp = False
        has_sll2 = False
        for k, ins in enumerate(body):
            m = ins.mnemonic
            ops = ins.op_str
            if m == 'addiu':
                parts = [p.strip() for p in ops.split(',')]
                if len(parts) == 3 and parts[0] == parts[1]:
                    try:
                        if int(parts[2], 0) == 0x10:
                            stride_regs.add(parts[0])
                    except ValueError:
                        pass
            elif m in ('lhu', 'lh', 'lbu', 'lb', 'lw'):
                # op: $t, offset($r)
                try:
                    dst, rest = [p.strip() for p in ops.split(',', 1)]
                    off_s, base_s = rest.split('(')
                    base_r = base_s.rstrip(')')
                    lhu_regs.setdefault(base_r, []).append((k, int(off_s, 0)))
                except Exception:
                    pass
            elif m == 'jr' and ops.strip() != '$ra':
                has_jr_dispatch = True
            elif m in ('beq', 'bne') :
                has_tag_cmp = True
            elif m == 'sll':
                parts = [p.strip() for p in ops.split(',')]
                if len(parts) == 3 and parts[2] == '2':
                    has_sll2 = True
        # walker = stride pointer AND tag-load from that same pointer in loop
        tagged = [r for r in stride_regs if r in lhu_regs]
        if tagged:
            score = 1 + (1 if has_jr_dispatch else 0) + (1 if has_sll2 else 0)
            hits.append({
                'file': name,
                'loop_start': hex(insns[t_idx].address),
                'loop_end': hex(insns[b_idx].address),
                'ptr_regs': tagged,
                'lhu_offsets': {r: lhu_regs[r] for r in tagged},
                'jr_dispatch': has_jr_dispatch,
                'sll2': has_sll2,
                'score': score,
            })
    return hits

def main():
    rows = list(csv.DictReader(open('/home/hatch/workspace/suikoden/kit/work/overlay_survey.csv')))
    allhits = []
    for r in rows:
        path = EXT + '/' + r['file']
        base = int(r['load_base_guess'], 16)
        try:
            data = load(path)
        except FileNotFoundError:
            print(f'MISSING {path}', file=sys.stderr)
            continue
        hits = scan_one(data, base, r['file'])
        allhits.extend(hits)
        if hits:
            print(f'{r["file"]}: {len(hits)} candidate loops')
    # SLUS
    data = load(SLUS)
    hits = scan_one(data, 0x80010000, 'SLUS_002.92')
    allhits.extend(hits)
    print(f'SLUS_002.92: {len(hits)} candidate loops')
    # rank
    allhits.sort(key=lambda h: -h['score'])
    print('\n=== RANKED (score>=2) ===')
    for h in allhits:
        if h['score'] >= 2:
            print(f"{h['file']} loop {h['loop_start']}..{h['loop_end']} ptr={h['ptr_regs']} "
                  f"lhu_off={h['lhu_offsets']} jr={h['jr_dispatch']} sll2={h['sll2']}")
    print(f'\nTotal candidates: {len(allhits)}')

if __name__ == '__main__':
    main()
