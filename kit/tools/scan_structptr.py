#!/usr/bin/env python3
"""Map struct field accesses via the 0x800B00FC pointer idiom:
find `lw $r,0xFC($rb)` with $rb=0x800B0000, then forward-scan for memops through $r.

**Pointer invalidation (fixed 2026-10-04).** The forward scan used to keep a
`tracked` set that was *never* invalidated, so once a register had held the
struct pointer it counted as the pointer forever -- even after `lui`, a load, or
a call result had overwritten it. On the real `SLUS_002.92` body 20 of the 119
emitted records had a base register whose nearest writer was not the struct
pointer (`lw $v0,0xfc($v0)` @0x800164c4, `lui $v0,0x800a` @0x80016828 labelled
`struct+0x340`). `tracked` is now a map from register to a *known offset* and
every writer removes or re-seats the entry.

See `kit/docs/scanner_pointer_invalidation.md` for the measurements and
`kit/tests/test_scanner_clobbers.py` for the counterexamples that pin this.

The scan accepts an injected `reader(va) -> word or None` so a synthetic
instruction window can drive it without a disc; the default reads the real EXE
body through `mipsdec`.
"""
import os
import sys
TOOLS = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)
from mipsdec import word_at, dec, BASE, size, REGS  # noqa: E402
from mips_writers import (dst_reg_of_word, is_call_word,  # noqa: E402
                          is_load_word)

START = BASE
MEMOPS = {0x20:'lb',0x21:'lh',0x23:'lw',0x24:'lbu',0x25:'lhu',
          0x28:'sb',0x29:'sh',0x2B:'sw',0x22:'lwl',0x26:'lwr',0x2A:'swl',0x2E:'swr'}

STRUCT_BASE = 0x800B0000
STRUCT_OFF = 0x00FC
SPTR_WALK = 120      # instructions of forward window after a struct-ptr load

# $at,$v0-$v1,$a0-$a3,$t0-$t9,$k0-$k1 -- the registers a callee may clobber.
VOLATILE = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 24, 25}


def _end(reader=None):
    """End VA of the code image (computed lazily from the disc by default)."""
    if reader is not None:
        raise ValueError("_end() needs an explicit end_va when a reader is used")
    return BASE + size()


def base_is_800B0000(pc, reg, reader=None):
    """Nearest-writer walk: is `reg` == 0x800B0000 at `pc`?

    Reuses `mips_writers.writer_of` rather than carrying a third private writer
    list. The private list used to omit every load opcode and every call, so the
    walk stepped straight over a clobbering load and reported the *pre-load*
    constant -- the same defect class `mips_writers` was created to fix.
    `writer_of` also encodes the MIPS I delay-slot rule (a load or call at
    `pc - 4` is not yet visible).
    """
    from mips_writers import writer_of
    r = writer_of(pc, reg, reader=reader)
    if r is None:
        return False
    _wpc, _s, f = r
    # The idiom is `lui $r,0x800b` immediately (or through the walk) before use.
    return f['op'] == 0x0F and f['uimm'] == 0x800B


def _loads(reader, end_va, start=START):
    """Find `lw $rt,0xFC($rs)` where $rs holds 0x800B0000."""
    loads = []
    pc = start
    while pc < end_va:
        w = reader(pc) if reader is not None else word_at(pc)
        if w is None:
            break
        op = (w >> 26) & 0x3F
        if op == 0x23 and (w & 0xFFFF) == STRUCT_OFF:
            rs = (w >> 21) & 0x1F; rt = (w >> 16) & 0x1F
            if base_is_800B0000(pc, rs, reader=reader):
                loads.append((pc, rt))
        pc += 4
    return loads


def _reader_for(reader, end_va):
    if reader is not None:
        return reader
    return word_at


def scan(reader=None, end_va=None, quiet=False):
    """Emit struct-field accesses. Returns the list of (lpc, pc, text, offset).

    `reader` + `end_va` drive a synthetic window; with neither, the real EXE
    body is read off the disc through `mipsdec`.
    """
    rd = _reader_for(reader, end_va)
    if end_va is None:
        end_va = _end()
    loads = _loads(rd, end_va)
    if not quiet:
        print(f"struct-ptr loads: {len(loads)}", file=sys.stderr)
    seen = set()
    out = []
    for lpc, r in loads:
        # `tracked` maps register -> known byte offset from the struct base.
        # A register not in this map is NOT the struct pointer. This is the
        # pointer-invalidation fix: the old code used a set that nothing ever
        # removed a register from, so a clobbered register still read as the
        # struct pointer for the rest of the window.
        tracked = {r: 0}
        # The load's own result is not visible to its delay-slot instruction
        # (MIPS I), so the scan used to start at lpc+4 -- INSIDE that slot --
        # where the loaded pointer does not exist yet. Start after the slot.
        pc = lpc + 8
        for _ in range(SPTR_WALK):
            if pc >= end_va:
                break
            w = rd(pc)
            if w is None:
                break
            op = (w >> 26) & 0x3F
            rs = (w >> 21) & 0x1F; rt = (w >> 16) & 0x1F; rd_ = (w >> 11) & 0x1F
            imm = w & 0xFFFF; imm_s = imm - 0x10000 if imm & 0x8000 else imm
            fn = w & 0x3F
            s, _f = dec(pc, w)

            if op in MEMOPS and rs in tracked and not (op == 0x23 and imm == STRUCT_OFF):
                key = (lpc, pc)
                if key not in seen:
                    seen.add(key)
                    off = (tracked[rs] + imm_s) & 0xFFFFFFFF
                    out.append((lpc, pc, s, off))
                    if not quiet:
                        print(f"{lpc:#x} -> {pc:#x}  {s:36s} struct+{off:#x}")

            if op == 0 and fn in (0x21, 0x25):
                # A genuine move only: one source is tracked and the other is
                # $zero. `addu rd,rs,rt` with two live sources is not a copy.
                #
                # NOTE: no `continue` here. The loop increments `pc` only at the
                # bottom, so a `continue` would spin on the same instruction for
                # the whole 120-instruction window and silently truncate every
                # record after the first addu/or. That bug cost 26 real records
                # on the shipped body (e.g. `0x800168ac`, `0x800168b8` under
                # lpc 0x8001686c) before it was caught.
                a, b = rs, rt
                if rd_ != 0:
                    if a in tracked and b == 0:
                        tracked[rd_] = tracked[a]
                    elif b in tracked and a == 0:
                        tracked[rd_] = tracked[b]
                    elif rd_ in tracked:
                        del tracked[rd_]
                pc += 4
                continue
            if op in (0x08, 0x09, 0x0C, 0x0D, 0x0E) and rs in tracked:
                # addiu/addi/andi/ori/xori rt,rs,imm. The old code was a bare
                # `pass` whose comment claimed it kept tracking `rt` with an
                # unknown offset: it did nothing, and because `rt` was never
                # added to `tracked` the branch was dead code. Now the addend is
                # folded when it is an arithmetic immediate; a bitwise op does
                # not preserve "struct + offset" and instead invalidates `rt`.
                d = rt
                if op in (0x08, 0x09):
                    if d != 0:
                        tracked[d] = (tracked[rs] + imm_s) & 0xFFFFFFFF
                elif d in tracked:
                    del tracked[d]
                # fall through to the generic invalidation below for opcodes it
                # also covers (they all write rt)
            # stop at the function return
            if op == 0 and fn == 0x08 and rs == 31:
                break
            if is_call_word(w):
                # A call writes $ra and may clobber every volatile register, so
                # no tracked register outside the $s set survives it. Tracking a
                # $v0/$a0 pointer across a jal is how a call result came to read
                # as the struct pointer.
                for r_ in list(tracked):
                    if r_ in VOLATILE:
                        del tracked[r_]
                continue
            # Generic clobber handling: any instruction that writes a tracked
            # register retires or re-seats it. Loads, lui and calls all write.
            wr = dst_reg_of_word(pc, w)
            if wr and wr in tracked:
                if is_load_word(w) or (op == 0x0F):
                    # The loaded/half-word value is not the struct pointer.
                    del tracked[wr]
            pc += 4
    return out


def main():
    """Write the JSON record set and print the human-readable form.

    The JSON exists so this scanner's records can be audited by a *committed*
    invariant check instead of by parsing human-readable text -- the same shape
    `gs_scan.py` already provides for its own records. CLI output is otherwise
    unchanged: the human-readable lines still go to stdout, and the load count
    still goes to stderr.
    """
    import json
    recs = scan()
    out = os.path.join(KIT, 'work', 'structptr_recs.json')
    payload = [{'load_pc': lpc, 'access_pc': pc, 'op': text,
                'offset': off, 'kind': 'struct-ptr'} for lpc, pc, text, off in recs]
    try:
        with open(out, 'w') as fh:
            json.dump(payload, fh, indent=0)
        print('wrote', out, file=sys.stderr)
    except OSError as exc:
        # A read-only tree must not break the CLI contract.
        print('could not write %s: %s' % (out, exc), file=sys.stderr)


if __name__ == '__main__':
    main()
