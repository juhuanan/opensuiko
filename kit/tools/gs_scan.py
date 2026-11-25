#!/usr/bin/env python3
"""Scan MAIN_body.bin for game-state (0x801B8000) accesses.
Two modes:
  P1: direct absolute accesses via lui 0x801B/0x801C (+addiu/ori materialization).
  P2: indirect via the h2da pointer at 0x8017DB24 (lui 0x8018; lw -0x24DC),
      or a validated literal GS materialization, then track offset-based accesses.
"""
import os
from collections import deque
import struct, csv, bisect, json, sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

from mips_writers import (dst_reg_of_word, is_call_word,  # noqa: E402
                          is_load_word, writer_of)

MBASE = 0x800C0800
GSBASE = 0x801B8000

# MAIN.EXE body on disc: PS-X EXE header is 2048 bytes, code loads at 0x800C0800.
MAINEXE_LBA = 17976
MAINEXE_SIZE = 757760
MAINEXE_HEADER = 2048

# Loaded lazily: importing this module must have no file side effects.
_STATE = {}


def _load(reader=None):
    """Load the MAIN.EXE body + function labels on first use.

    `reader` is an optional injected code source: a callable ``reader(va) -> word
    or None`` covering the same VA range as the EXE body (``MBASE`` onward). It
    exists so a synthetic instruction window can drive `scan()` without a disc,
    mirroring ``mips_writers.writer_of(..., reader=)``. When it is given, no disc
    access and no label file read happen at all.
    """
    if reader is not None:
        return {'W': None, 'reader': reader, 'funcs': [], 'faddrs': []}
    if _STATE:
        return _STATE
    sys.path.insert(0, TOOLS)
    import disc
    raw = disc.extract(MAINEXE_LBA, MAINEXE_SIZE)
    body = raw[MAINEXE_HEADER:]
    n = len(body) // 4
    W = [struct.unpack_from('<I', body, i * 4)[0] for i in range(n)]

    funcs = []
    labels = os.path.join(KIT, 'work', 'function_labels.csv')
    with open(labels, newline='') as f:
        for row in csv.DictReader(f):
            a = (row.get('address') or '').strip()
            try:
                funcs.append((int(a, 16), row['name']))
            except (ValueError, KeyError):
                continue
    funcs.sort()

    _STATE.update(body=body, W=W, funcs=funcs,
                  faddrs=[a for a, _ in funcs], reader=None)
    return _STATE


def _word_at(state, i):
    """Word at word index `i`, from the disc body or the injected reader."""
    if state.get('reader') is not None:
        return state['reader'](MBASE + i * 4)
    W = state['W']
    return W[i] if 0 <= i < len(W) else None


def _nwords(state, cap):
    """Number of addressable words, bounded by `cap` for injected readers."""
    if state.get('reader') is not None:
        return cap
    return len(state['W'])


def _provably_zero(state, k, reg, maxback=12, history=None):
    """Is `reg` provably $zero at window index `k` (i.e. just before it)?

    A *bounded, local* backward fact, not constant propagation: the nearest
    writer of `reg` within `maxback` instructions must be an operation that
    writes literal 0 (`addu/or r,$zero,$zero`, `addiu/ori/andi/xori r,$zero,0`).
    Anything else (a load, a call, a distant writer, no writer) is not a proof
    and returns False. This exists so `addu $base,$gsptr,$idx` with a locally
    zero `$idx` keeps its correct concrete offset instead of being downgraded to
    `gs+?` -- measured 2026-10-04: 71 of the 185 downgrades were of this shape,
    e.g. `addu $a0,$zero,$zero` @0x800c4f18 then `addu $v0,$a2,$a0`.
    """
    if reg == 0:
        return True
    previous=reversed(history[-maxback:]) if history is not None else range(k-1,max(0,k-1-maxback),-1)
    for kk in previous:
        w = _word_at(state, kk)
        if w is None:
            return False
        o = op(w)
        if o == 0x00 and rd(w) == reg and rd(w) != 0:
            fn = funct(w)
            if fn == 0x21 and rs(w) == 0 and rt(w) == 0:   # addu r,$zero,$zero
                return True
            return False
        if o in (0x08, 0x09, 0x0C, 0x0D, 0x0E) and rt(w) == reg:  # addi..xori
            return rs(w) == 0 and imm(w) == 0
        if o in (0x0F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26) and rt(w) == reg:
            return False                                    # lui/load writes non-zero
        if is_call_word(w) and reg in VOLATILE:
            if history is None or kk != history[-1]:return False
    return False


def va(i):
    return MBASE + i * 4


def fname(v, state=None):
    # Never fall back to `_load()` when a state is supplied: with an injected
    # reader there is no disc to read, and a silent fallback here would make the
    # "no disc required" guarantee false (it did, until this was caught by the
    # mutation harness reading the disc during a synthetic-only test run).
    state = state if state is not None else _load()
    faddrs, funcs = state['faddrs'], state['funcs']
    i = bisect.bisect_right(faddrs, v) - 1
    return funcs[i][1] if i >= 0 else '?'

def simm(x): return x - 0x10000 if x & 0x8000 else x
def op(w): return w >> 26
def rs(w): return (w >> 21) & 31
def rt(w): return (w >> 16) & 31
def rd(w): return (w >> 11) & 31
def funct(w): return w & 63
def imm(w): return w & 0xFFFF

MEM = {0x20:('lb',1,'R'),0x21:('lh',2,'R'),
       0x23:('lw',4,'R'),0x2B:('sw',4,'W'),0x24:('lbu',1,'R'),0x28:('sb',1,'W'),
       0x25:('lhu',2,'R'),0x29:('sh',2,'W'),0x22:('lwl',4,'R'),0x26:('lwr',4,'R'),
       0x2A:('swl',4,'W'),0x2E:('swr',4,'W')}
VOLATILE = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,24,25}

def ends_fallthrough(w):
    """Unconditional transfers; their delay instruction still executes."""
    o=op(w)
    return (o==2 or (o==0 and funct(w)==8)
            or (o==0 and funct(w)==9 and rd(w)==0)
            or (o==4 and rs(w)==rt(w))
            or (o==1 and rs(w)==0 and rt(w)==1)
            or (o==6 and rs(w)==0))


def direct_destination(k,w):
    if op(w)==2:
        address=((va(k)+4)&0xF0000000)|((w&0x3FFFFFF)<<2)
        return (address-MBASE)//4
    if ends_fallthrough(w) and op(w)!=0:
        return k+1+simm(imm(w))
    return None


def fallthrough_window(state,start,end):
    """One bounded path: follow known direct transfers, retain their delay slot."""
    k=start;after=None
    for _ in range(end-start):
        if not start<=k<end:return
        w=_word_at(state,k)
        if w is None:return
        yield k
        if after is not None:
            k=after;after=None
            continue
        if ends_fallthrough(w):
            target=direct_destination(k,w)
            after=target if target is not None else end
        k+=1


recs = []  # (kind, va, func, opname, width, rw, target_desc)

def rec(kind, i, oname, width, rw, desc, state=None):
    recs.append((kind, va(i), fname(va(i), state), oname, width, rw, desc))

def _transfer_gs(state,k,gs,delayed,step,history):
    """Update aliases for one instruction on a particular bounded control-flow path."""
    w3 = _word_at(state, k)
    if w3 is None: return gs,delayed
    o3 = op(w3)
    pc3 = k * 4 + MBASE
    # Retire delayed writes whose delay slot has passed. A load/call at
    # `pc` writes its destination, but on MIPS I that result is NOT
    # visible to the instruction in its delay slot (`pc+4`); it is
    # visible from `pc+8` on. `writer_of`'s backward walk encodes the
    # same rule from the other direction.
    still = []
    for retire, r_ in delayed:
        if step >= retire:
            gs.pop(r_, None)
        else:
            still.append((retire, r_))
    delayed = still
    if not gs: return gs,delayed
    if o3 in MEM and rs(w3) in gs:
        off = gs[rs(w3)][0] + simm(imm(w3))
        idx = gs[rs(w3)][1]
        unk = gs[rs(w3)][2]
        if unk:
            # The base is still the game-state pointer, but an
            # unprovable addend sits between it and this access, so the
            # constant offset is unknown. Say that instead of inventing
            # one -- this is the case `addu $r,$idx,$gsptr` produces.
            #
            # NO range test here. The `-0x400 <= off < 0x8000` window
            # exists to reject offsets that cannot be game-state fields,
            # and it is only meaningful for a *computed* offset. Testing
            # a meaningless `off` here would turn "offset unknown" into
            # "record absent", which is the one thing this fix exists to
            # prevent: an unresolved access must stay unresolved, not
            # vanish. (Caught by the orchestrator mid-flight.)
            m,wd,rw = MEM[o3]
            rec('indirect', k, m, wd, rw, 'gs+?%s' % ('+idx' if idx else ''), state)
        elif -0x400 <= off < 0x8000:
            m,wd,rw = MEM[o3]
            rec('indirect', k, m, wd, rw, 'gs+0x%X%s' % (off & 0xFFFFFFFF, '+idx' if idx else ''), state)
        # NOTE: no `return gs,delayed` here. An instruction that is BOTH a memory
        # access and a writer (e.g. `lw s0,0(s0)`) must still reach the
        # clobber handling below; the old early exit let the base stay
        # tracked with its stale offset and produced `gs+0x4`.
    if o3 == 0x00 and funct(w3) in (0x21, 0x25):  # addu/or rd,rs,rt
        a, b, d = rs(w3), rt(w3), rd(w3)
        # A propagated pointer requires a genuine *move*: one source is
        # tracked and the other is $zero. `addu rd,rs,rt` with two live
        # sources is arithmetic, not a copy, and propagates nothing.
        #
        # Note `d` may itself be `a` or `b` (`addu $s0,$s1,$s0`): the
        # destination register being one of the sources changes nothing
        # about the arithmetic, so there is deliberately no `a != d` /
        # `b != d` guard. An earlier draft of this fix had those guards
        # and silently dropped every `addu $r,$x,$r`, losing 123 real
        # access sites.
        if d == 0:
            pass
        elif a in gs and b == 0:
            gs[d] = gs[a]
        elif b in gs and a == 0:
            gs[d] = gs[b]
        elif a in gs and b in gs:
            # base + index, both tracked: the base survives and only the
            # index is unknown.
            gs[d] = (gs[a][0], True, gs[a][2] or gs[b][2])
        elif a in gs and b != 0:
            # One tracked source plus one UNTRACKED register that is not
            # $zero. If the untracked side is provably zero the offset is
            # still exact; otherwise the base is the game-state pointer
            # but its constant offset is no longer provable. Track it as
            # unknown rather than either reusing the source offset (the
            # old addend-dropping bug, e.g. `ori $s1,0x1bcc` then
            # `addu $s0,$s1,$s0` reported as `gs+0x16`) or dropping a
            # genuine access entirely.
            if _provably_zero(state,k,b,history=history):
                gs[d] = gs[a]
            else:
                gs[d] = (gs[a][0], True, True)
        elif b in gs and a != 0:
            if _provably_zero(state,k,a,history=history):
                gs[d] = gs[b]
            else:
                gs[d] = (gs[b][0], True, True)
        elif d in gs:
            del gs[d]
        return gs,delayed
    if o3 == 0x00 and funct(w3) == 0x00:  # sll rd,rt,sh
        t_, d = rt(w3), rd(w3)
        if t_ in gs and d != 0: gs[d] = (gs[t_][0], True, gs[t_][2]); return gs,delayed
        if d in gs: del gs[d]
        return gs,delayed
    if o3 == 0x09 and rs(w3) in gs:  # addiu rd,rs,imm
        d = rt(w3)
        src_off, src_idx, src_unk = gs[rs(w3)]
        if d != 0 and abs(simm(imm(w3))) < 0x2000:
            # Cross-register arithmetic: the destination is the source
            # base plus the addend. Keeping the addend is what the old
            # copy-vs-drop choice got wrong in both directions: it either
            # silently reused the source's offset (dropping the addend)
            # or dropped the register entirely. A known addend onto an
            # unknown offset stays unknown but keeps the constant part.
            gs[d] = (src_off + simm(imm(w3)), src_idx, src_unk)
        elif d in gs:
            del gs[d]
        return gs,delayed
    if is_call_word(w3):
        for r_ in gs:
            if r_ in VOLATILE:delayed.append((step+2,r_))
        delayed.append((step+2,31))
        return gs,delayed
    # generic write detection
    wr = dst_reg_of_word(pc3, w3)
    if wr:
        if is_load_word(w3) or is_call_word(w3):
            delayed.append((step + 2, wr))   # visible from pc+8
        else:
            gs.pop(wr, None)
            if not gs: return gs,delayed
    return gs,delayed


def scan(reader=None):
    """Run the P1 + P2 sweeps and return the record list.

    `reader` is the optional injected code source described in `_load()`; the
    default reads the real MAIN.EXE body off the disc through `disc`/`mipsdec`.
    Known direct transfers follow their destination after the delay slot;
    conditional branches keep separate alias states for both successors, and
    indirect terminal transfers end the walk. This is not an exhaustive
    control-flow or interprocedural field census.
    Each call starts from an empty record list, so repeated calls (as the tests
    make) cannot accumulate stale records from an earlier window.
    """
    del recs[:]
    state = _load(reader)
    n = _nwords(state, 100000)
    # ---------- P1: lui 0x801B / 0x801C ----------
    for i in range(n - 10):
        w = _word_at(state, i)
        if w is None: continue
        if i and ends_fallthrough(_word_at(state,i-1) or 0):continue
        if op(w) != 0x0F: continue
        hi, r = imm(w), rt(w)
        if hi not in (0x801B, 0x801C): continue
        base = hi << 16
        for j in fallthrough_window(state,i+1,min(i+9,n)):
            w2 = _word_at(state, j)
            if w2 is None: break
            o2 = op(w2)
            if o2 in MEM and rs(w2) == r:
                eff = base + simm(imm(w2))
                if 0x801B0000 <= eff < 0x801C0000:
                    m,wd,rw = MEM[o2]
                    rec('direct', j, m, wd, rw, 'abs 0x%08X' % eff, state)
            elif o2 == 0x09 and rs(w2) == r and rt(w2) == r:  # addiu r,r,imm -> gsptr?
                eff = base + simm(imm(w2))
                if eff == GSBASE:
                    # track r as gsptr for following mem ops
                    for k in fallthrough_window(state,j+1,min(j+60,n)):
                        w3 = _word_at(state, k)
                        if w3 is None: break
                        o3 = op(w3)
                        if o3 in MEM and rs(w3) == r:
                            off = simm(imm(w3))
                            if -0x200 <= off < 0x8000:
                                m,wd,rw = MEM[o3]
                                rec('direct', k, m, wd, rw, 'gs+0x%X' % (off & 0xFFFFFFFF), state)
                        elif o3 == 0x0F and rt(w3) == r:
                            break
                        elif o3 == 0x03:  # jal: $ra is written, so drop $ra
                            # The comment used to claim volatiles were dropped
                            # here while the branch body was a bare `pass`, so
                            # nothing was dropped at all. Tracked register `r` is
                            # a lui-materialized base and `jal` does not preserve
                            # it across the call unless it is an $s register, so
                            # the honest action is to stop at the call rather than
                            # keep reporting accesses off a register the callee
                            # may have redefined.
                            if r not in (16,17,18,19,20,21,22,23):
                                break
                        # stop if r overwritten
                        written = False
                        if o3 == 0x00 and rd(w3) == r and rd(w3) != 0: written = True
                        if o3 in (0x08,0x09,0x0D,0x0C,0x0A,0x0B,0x0E,0x20,0x21,0x22,
                                  0x23,0x24,0x25,0x26,0x0F) and rt(w3) == r: written = True
                        if written: break
            elif o2 == 0x0F and rt(w2) == r:
                break

    # ---------- P2: h2da pointer loads and literal GS materializations ----------
    for i in range(n - 610):
        w = _word_at(state, i)
        if w is None: continue
        if i and ends_fallthrough(_word_at(state,i-1) or 0):continue
        gs = None  # reg -> base offset
        # pattern A: lui 0x8018 ; lw rt,-0x24DC(rs)
        if op(w) == 0x0F and imm(w) == 0x8018:
            r1 = rt(w)
            for j in fallthrough_window(state,i+1,min(i+9,n)):
                w2 = _word_at(state, j)
                if w2 is None: break
                o2 = op(w2)
                if o2 == 0x23 and rs(w2) == r1 and simm(imm(w2)) == -0x24DC:
                    if ends_fallthrough(_word_at(state,j-1) or 0):break
                    gs = {rt(w2): (0, False, False)}
                    start = j + 1
                    break
                if o2 == 0x0F and rt(w2) == r1: break
        # pattern B: lw rt,-0x24DC($gp=28)
        elif op(w) == 0x23 and rs(w) == 28 and simm(imm(w)) == -0x24DC:
            gs = {rt(w): (0, False, False)}
            start = i + 1
        elif op(w) in (0x09, 0x0D) and imm(w) == 0x8000:
            source = writer_of(va(i), rs(w), reader=lambda address:
                               _word_at(state, (address - MBASE) // 4))
            if source:
                source_pc, _, fields = source
                base = fields['uimm'] << 16
                value = (base + simm(imm(w)) if op(w) == 0x09 else base | imm(w))
                first = (source_pc - MBASE) // 4
                path = list(fallthrough_window(state, first + 1, i + 1))
                source_previous = _word_at(state, first - 1) if first else None
                previous = _word_at(state, i - 1) if i else None
                if fields['op'] == 0x0F and value == GSBASE and \
                        i in path and \
                        not (source_previous is not None and
                             (ends_fallthrough(source_previous) or
                              (is_call_word(source_previous) and rs(w) in VOLATILE))) and \
                        not (rs(w) in VOLATILE and
                             any(k < i - 1 and is_call_word(_word_at(state, k) or 0) for k in path)) and \
                        not (previous is not None and is_call_word(previous) and rt(w) in VOLATILE):
                    gs = {rt(w): (0, False, False)}
                    start = i + 1
        if gs is None: continue
        end=min(start+600,n)
        todo=deque([(start,gs,[],0,None,())]);seen=set();entry={}
        while todo:
            k,gs,delayed,step,after,history=todo.popleft()
            if step>=600 or not start<=k<end:continue
            key=(k,tuple(sorted(gs.items())),tuple((at-step,r) for at,r in delayed),after,history)
            if key in seen:continue
            seen.add(key)
            entry.setdefault(k,dict(gs))
            w3=_word_at(state,k)
            if w3 is None:continue
            gs,delayed=_transfer_gs(state,k,gs,delayed,step,history)
            if not gs:continue
            if after is not None:
                successors=[(dest,None) for dest in after]
            else:
                o3=op(w3)
                if ends_fallthrough(w3):
                    target=direct_destination(k,w3)
                    successors=[(k+1,() if target is None else (target,))]
                elif o3 in (1,4,5,6,7):
                    target=k+1+simm(imm(w3))
                    impossible=((o3==5 and rs(w3)==rt(w3)) or
                                (o3==1 and rs(w3)==0 and rt(w3)==0) or
                                (o3==7 and rs(w3)==0))
                    successors=[(k+1,(k+2,) if impossible else (k+2,target))]
                else:successors=[(k+1,None)]
            for dest,targets in successors:
                outgoing=dict(gs)
                if after is not None and dest<=k:
                    initial=entry.get(dest,{})
                    for r_,value in outgoing.items():
                        if r_ in initial and value!=initial[r_]:
                            outgoing[r_]=(0,True,True)
                todo.append((dest,outgoing,list(delayed),step+1,targets,(history+(k,))[-12:]))
    recs[:]=list(dict.fromkeys(recs))
    return recs


def main():
    """Run the scan and write its report."""
    records = scan()
    out = os.path.join(KIT, 'work', 'gs_recs.json')
    with open(out, 'w') as fh:
        json.dump(records, fh)
    print('total recs:', len(records))
    kinds = {}
    for r_ in records:
        kinds[r_[0]] = kinds.get(r_[0], 0) + 1
    print(kinds)
    print('wrote', out)


if __name__ == '__main__':
    main()
