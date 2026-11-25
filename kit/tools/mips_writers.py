#!/usr/bin/env python3
"""Shared MIPS register-writer classification, backward writer search and
constant resolution for the static scanners.

**Why this module exists.** `scan_abs.py` and `scan_stores.py` each carried a
private copy of the same backward walk, and both copies had the same two
defects (recorded in `kit/docs/python_review_verification.md` §§7-8):

1. **Loads were not classified as writers.** Their writer lists covered `lui`,
   the immediate arithmetic ops and a set of R-type ops, but not `lb..lwr`. So
   the walk stepped straight over an instruction that had overwritten the
   register and returned the *pre-load* constant. On the real `SLUS_002.92`
   body this converts **223** stores into a confident wrong address where the
   honest answer is UNKNOWN (measured 2026-10-04; see
   `kit/docs/scanner_writer_fix.md`).
2. **Cross-register arithmetic dropped its addend.** `addiu t0,t1,0xfc` was
   treated as a pure copy of `t1`, losing `0xfc`.

`jal`/`jalr` (which write `$ra`/`rd`) were also unclassified, so a call did not
stop the walk.

**Delay slots.** On MIPS I a load's result is not visible to the instruction in
its delay slot; the same one-instruction delay applies to the `$ra` written by
`jal`/`jalr`. A writer found at `addr - 4` that is a load or a call is therefore
*not* the value the instruction at `addr` sees — the walk skips it and keeps
going. Where the walk cannot prove a value it returns `(None, reason)`, which is
the point: an unresolved value must stay unresolved rather than become a
plausible wrong constant.

Callers may pass `reader=` to supply code words instead of reading the disc,
which is what makes the walk unit-testable (`kit/tests/test_scanner_writers.py`).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mipsdec import BASE, dec, word_at  # noqa: E402

# lb, lh, lwl, lw, lbu, lhu, lwr -- every MIPS I load writes its rt.
LOAD_OPS = (0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26)

# Immediate arithmetic that folds onto a traced base: addi, addiu.
ADD_IMM_OPS = (0x08, 0x09)

# The rest of the immediate group (slti, sltiu, andi, ori, xori) writes rt too
# but is not folded except for `ori`, which resolve_reg handles explicitly.
IMM_OPS = (0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E)

# R-type fns known to write rd.
RTYPE_WRITERS = (0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
                 0x00, 0x02, 0x03, 0x04, 0x2A, 0x2B, 0x10, 0x12, 0x0A, 0x0B)


def is_load(f):
    return f['op'] in LOAD_OPS


def is_call(f):
    """jal, or jalr (jr $ra is not a call -- it writes nothing)."""
    if f['op'] == 0x03:
        return True
    return f['op'] == 0 and f.get('fn') == 0x09


def dst_reg(f):
    """The GPR this instruction writes, or None if it writes no GPR.

    Deliberately complete for the cases that mattered: loads, `mfc0`, and the
    `$ra`/`rd` written by calls. Missing writers are what let the old walk
    invent constants, so anything this returns must be a genuine write.
    """
    op, fn = f['op'], f.get('fn')
    if op == 0x0F:                                  # lui rt,uimm
        return f['rt']
    if op in IMM_OPS:                               # addi..xori rt,rs,imm
        return f['rt']
    if op in LOAD_OPS:                              # lb..lwr rt,imm(rs)
        return f['rt']
    if op == 0x10 and f['rs'] == 0:                 # COP0 mfc0 rt,rd
        return f['rt']
    if op == 0x03:                                  # jal -> $ra
        return 31
    if op == 0:                                     # SPECIAL
        if fn == 0x09:                              # jalr rd,rs
            return f['rd'] or None
        if fn in RTYPE_WRITERS:
            return f['rd'] or None                  # rd == $zero writes nothing
    return None


def dst_reg_of_word(addr, w):
    """`dst_reg` for callers that hold a raw word rather than decoded fields.

    The word-level forward scanners (`gs_scan.py`, `scan_structptr.py`) work on
    packed words, so they need the same classification without a `dec()` round
    trip. Kept here rather than duplicated so a writer list cannot drift from
    `dst_reg` again -- that divergence is exactly what produced this fix.
    """
    if w is None:
        return None
    op = (w >> 26) & 0x3F
    if op == 0x0F:                                  # lui rt,uimm
        return (w >> 16) & 0x1F
    if op in IMM_OPS:                               # addi..xori rt,rs,imm
        return (w >> 16) & 0x1F
    if op in LOAD_OPS:                              # lb..lwr rt,imm(rs)
        return (w >> 16) & 0x1F
    if op == 0x10 and ((w >> 21) & 0x1F) == 0:      # COP0 mfc0 rt,rd
        return (w >> 16) & 0x1F
    if op == 0x03:                                  # jal -> $ra
        return 31
    if op == 0:                                     # SPECIAL
        fn = w & 0x3F
        if fn == 0x09:                              # jalr rd,rs
            return ((w >> 11) & 0x1F) or None
        if fn in RTYPE_WRITERS:
            return ((w >> 11) & 0x1F) or None       # rd == $zero writes nothing
    return None


def is_load_word(w):
    return w is not None and ((w >> 26) & 0x3F) in LOAD_OPS


def is_call_word(w):
    """jal, or jalr (jr writes nothing)."""
    if w is None:
        return False
    op = (w >> 26) & 0x3F
    if op == 0x03:
        return True
    return op == 0 and (w & 0x3F) == 0x09


def writer_of(addr, reg, maxback=400, reader=None):
    """Most recent instruction before `addr` that writes `reg`.

    Returns (pc, mnemonic, fields) or None. A writer sitting at `addr - 4` that
    is a load or a call is skipped: its result is not yet visible to the
    instruction at `addr` (MIPS I delay slot).
    """
    if reg == 0:
        return None
    reader = reader or word_at
    pc = addr - 4
    for _ in range(maxback):
        if pc < BASE:
            break
        w = reader(pc)
        if w is None:
            break
        s, f = dec(pc, w)
        if dst_reg(f) == reg:
            if pc == addr - 4 and (is_load(f) or is_call(f)):
                pc -= 4
                continue
            return pc, s, f
        pc -= 4
    return None


def _apply(base, ops):
    """Apply `ops` to `base` in application order.

    The walk discovers operations from the store backwards, i.e. from the
    *last* executed to the first, so they must be replayed in reverse. Order
    matters: `lui B; addiu t,t,0x10; ori t,t,0xfc` yields `(B+0x10)|0xfc`
    while `lui B; ori t,t,0xfc; addiu t,t,0x10` yields `(B|0xfc)+0x10`.
    """
    v = base & 0xFFFFFFFF
    for kind, arg in reversed(ops):
        v = (v + arg) & 0xFFFFFFFF if kind == 'add' else (v | arg) & 0xFFFFFFFF
    return v


def resolve_reg(addr, reg, maxdepth=8, reader=None):
    """Resolve `reg` to a constant at `addr`, the point just after its writer.

    Returns (value, chain) on success or (None, reason) when the walk cannot
    prove a value. `None` is the honest answer for a load, a call, or any
    operation the walk does not fold -- callers must treat it as unknown rather
    than falling back to a nearby constant.
    """
    chain = []
    ops = []
    cur = reg
    depth = 0
    while depth < maxdepth:
        r = writer_of(addr, cur, reader=reader)
        if r is None:
            return None, "no writer found: " + (" <- ".join(chain) or "no chain")
        pc, s, f = r
        op, fn = f['op'], f.get('fn')
        chain.append("%#x:%s" % (pc, s))

        if op == 0x0F:                                  # lui rt,uimm
            return _apply(f['uimm'] << 16, ops), " <- ".join(chain)

        if op in ADD_IMM_OPS:                           # addi/addiu rt,rs,imm
            ops.append(('add', f['imm']))
            if f['rs'] == 0:                            # rt = imm
                return _apply(0, ops), " <- ".join(chain)
            cur, addr = f['rs'], pc

        elif op == 0x0D:                                # ori rt,rs,uimm
            if f['rs'] == cur:                          # rt = cur | uimm, keep tracing
                ops.append(('or', f['uimm']))
                addr = pc
            elif f['rs'] == 0:                          # rt = uimm
                ops.append(('or', f['uimm']))
                return _apply(0, ops), " <- ".join(chain)
            else:                                       # rt = rs | uimm
                v, _ = resolve_reg(pc, f['rs'], maxdepth, reader=reader)
                if v is None:
                    return None, "ori chain failed: " + " <- ".join(chain)
                ops.append(('or', f['uimm']))
                return _apply(v, ops), " <- ".join(chain)

        elif op == 0 and fn in (0x21, 0x25):            # addu/or as a move
            src = f['rs'] if f['rt'] == 0 else (f['rt'] if f['rs'] == 0 else None)
            if src is None:
                return None, "non-move addu/or: " + " <- ".join(chain)
            cur, addr = src, pc

        else:
            return None, "unresolved writer kind: " + " <- ".join(chain)

        depth += 1
    return None, "depth exceeded: " + " <- ".join(chain)
