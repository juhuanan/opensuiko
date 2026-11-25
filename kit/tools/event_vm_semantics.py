#!/usr/bin/env python3
"""
event_vm_semantics.py -- MAIN.EXE event/area script VM: dispatch table + per-opcode
effect semantics.

Target
------
The MAIN.EXE event stream interpreter (``event_opcode_stream_tick`` @ 0x8013E028)
walks a byte stream with a cursor in ``event_stream_ptr`` @ 0x8017AF84.  The tick
pre-advances the cursor past the opcode byte and dispatches through an
**82-entry handler table** @ 0x80171718 (opcodes 0x00-0x51), then re-loops while
the byte @ 0x8017A180 is non-zero.

This tool does two things:

1. **Parse the dispatch table from the binary** (``handler_table()``) -- the
   table address, the 82 entries, the three NULL slots (3/39/40) and the exact
   handler address of every opcode are read from the disc image at build time,
   never hard-coded.
2. **Hold the per-opcode effect as data** (``EFFECTS``): operand layout, the
   globals read/written, the engine calls made, the control-flow behaviour and a
   one-line statement of what the opcode does.

A static analyser (``scan_handler``) disassembles each handler and its
jump-table targets and extracts the *machine-checked* half of that data:
absolute global reads/writes, base+index table reads/writes, ``jal`` targets and
indirect calls.  It also follows a **pointer global** (``lw $a0,-0x41e0($x)``
then ``sb $v0,0x4e0($a0)``) so that struct-relative fields are recorded as
``(pointer cell, offset)`` -- without that, a write through a loaded base is
invisible and opcode 0x4A was recorded as side-effect free while its delay slot
writes ``game_state+0x28+idx``.

``--verify`` cross-checks the curated ``EFFECTS`` entries against the
disassembly (declared globals, calls and struct fields), and re-derives every
record in ``EVIDENCE`` -- the per-opcode claim plus the machine-checkable
checks (instructions, tables, cross-references, resolved store constants) that
back it.  ``struct_xrefs``/``jal_xrefs``/``materializes`` scan the whole image,
so the *consumer* of a field is findable even when it lives in a frame routine
far from the VM (``--xref``, ``--consumers``).

Provenance: ``MAIN.EXE`` (PS-X EXE, LBA 17976, 757760 B) minus its 2048-byte
PS-X header = the image at base 0x800C0800, read through ``tools/disc.py``.

Usage:
    python3 event_vm_semantics.py --selftest        # table + effect consistency
    python3 event_vm_semantics.py --table           # the opcode -> handler table
    python3 event_vm_semantics.py --op 0x32         # effect + disassembly
    python3 event_vm_semantics.py --json            # full table as JSON
    python3 event_vm_semantics.py --verify          # curated data vs binary
    python3 event_vm_semantics.py --evidence        # re-derive the EVIDENCE claims
    python3 event_vm_semantics.py --consumers       # claims + their consumer routines
    python3 event_vm_semantics.py --xref 0x4DC      # all image accesses to *(area_state)+0x4DC
"""

import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)

from mipsdec import dec  # noqa: E402  (tools/ convention)

# ---------------------------------------------------------------------------
# Provenance
# ---------------------------------------------------------------------------
MAINEXE_LBA = 17976
MAINEXE_SIZE = 757760
MAINEXE_HEADER = 2048
MAIN_BASE = 0x800C0800

# The dispatch itself.
TABLE_BASE = 0x80171718
TABLE_SIZE = 82
NULL_OPCODES = (3, 39, 40)
TICK = 0x8013E028
CURSOR = 0x8017AF84
RELOOP_FLAG = 0x8017A180
DFLAG_80171C29 = 0x80171C29

_IMAGE = None


def main_image():
    """The 755712-byte MAIN.EXE image (header stripped) at base 0x800C0800."""
    global _IMAGE
    if _IMAGE is None:
        import disc
        raw = disc.extract(MAINEXE_LBA, MAINEXE_SIZE)
        _IMAGE = raw[MAINEXE_HEADER:]
    return _IMAGE


def word(va):
    off = va - MAIN_BASE
    img = main_image()
    if off < 0 or off + 4 > len(img):
        return None
    return struct.unpack_from('<I', img, off)[0]


def u8(va):
    off = va - MAIN_BASE
    img = main_image()
    if off < 0 or off >= len(img):
        return None
    return img[off]


def handler_table():
    """The 82 handler addresses at TABLE_BASE, parsed from the image."""
    return [word(TABLE_BASE + 4 * i) for i in range(TABLE_SIZE)]


# ---------------------------------------------------------------------------
# Handler scanner
#
# A recursive-descent disassembler over one handler and the jump-table targets
# it dispatches to, plus a forward abstract interpretation that tracks
#  - absolute constants   ('c', v)
#  - base+index addresses ('i', base, idx_reg, scale)   (table accesses)
#  - a jump-table load    ('j', table_va, entries)
#  - unknown              ('u', bound_or_None)
#
# Delay slots of jr/jalr/j/branches are executed and analysed (several handlers
# keep their only store in the `jr $ra` delay slot -- missing it is how three
# earlier "read-only" opcode claims were produced).
# ---------------------------------------------------------------------------
LOAD_OPS = {0x20: 1, 0x21: 2, 0x23: 4, 0x24: 1, 0x25: 2}
STORE_OPS = {0x28: 1, 0x29: 2, 0x2B: 4}
CALLER_CLOBBER = frozenset([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 24, 25, 31])

RAM_LO, RAM_HI = 0x800C0000, 0x80200000


class HandlerScan(object):
    """Disassembly + global-effect summary for one opcode handler."""

    def __init__(self, entry, max_insns=4000):
        self.entry = entry
        self.max_insns = max_insns
        self.code = {}          # pc -> (word, asm, fields)
        self.delay = set()      # delay-slot pcs (execute, then stop)
        self.extra_succ = {}    # delay pc -> additional successors
        self.sub_entries = []   # jump-table targets followed inside the handler
        self.reads = {}         # absolute global read  va -> count
        self.writes = {}        # absolute global write va -> count
        self.treads = {}        # indexed global read  base va -> count
        self.twrites = {}       # indexed global write base va -> count
        # struct-relative accesses: a register loaded from a pointer variable
        # (a global cell whose content is a pointer) is tracked as ('p', cell,
        # acc); an access off it is recorded here as (cell, offset) -> count.
        # ('px', cell, acc, idxreg) additionally carries an index register.
        # Without this, `lw $a0, -0x41e0($x)` + `sb $v0, 0x4e0($a0)` is
        # invisible: the base is not a constant, so `writes`/`twrites` miss the
        # store entirely (this is how opcode 0x4A was recorded as side-effect
        # free while its delay slot writes game_state+0x28+idx).
        self.sreads = {}        # (ptr cell, offset) read -> count
        self.swrites = {}       # (ptr cell, offset) written -> count
        self.sxreads = {}       # (ptr cell, offset, idx reg) read -> count
        self.sxwrites = {}      # (ptr cell, offset, idx reg) written -> count
        self.pointer_cells = set()   # cells observed to hold a pointer
        self.calls = {}         # jal target -> count
        self.jalr = []          # pcs of indirect calls
        self.cursor_reads = set()   # operand offsets read off the cursor register
        self.cursor_writes = set()  # cursor writeback offsets (None = computed)
        self.bad = []           # addresses that failed to decode/fetch
        self._walk(entry)
        self._analyze()
        self.sub_entries = sorted(set(self.sub_entries))

    # -- discovery ---------------------------------------------------------
    def _succ(self, pc, f):
        if pc in self.delay:
            return []
        op = f['op']
        fn = f.get('fn')
        if op == 0 and fn == 0x08:      # jr: delay slot runs, then the function returns
            self.delay.add(pc + 4)
            return [pc + 4]
        if op == 0 and fn == 0x09:      # jalr: delay slot, then resume after the call
            self.delay.add(pc + 4)
            return [pc + 4, pc + 8]
        if op == 2:                     # j
            self.delay.add(pc + 4)
            return [pc + 4, f['jt']]
        if op == 3:                     # jal (delay slot, return to pc+8)
            return [pc + 4, pc + 8]
        if op in (1, 4, 5, 6, 7):       # branches (delay slot, then either)
            self.extra_succ.setdefault(pc + 4, []).extend([f['br'], pc + 8])
            return [pc + 4]
        return [pc + 4]

    def _walk(self, entry):
        stack = [entry]
        while stack:
            a = stack.pop()
            if a in self.code:
                continue
            if len(self.code) >= self.max_insns:
                break
            w = word(a)
            if w is None or not (RAM_LO <= a < RAM_HI):
                self.bad.append(a)
                continue
            s, f = dec(a, w)
            self.code[a] = (w, s, f)
            for t in self._succ(a, f) + self.extra_succ.get(a, []):
                if t not in self.code:
                    stack.append(t)

    # -- value tracking helpers -------------------------------------------
    @staticmethod
    def _diff(a, b):
        return any(a.get(k) != b.get(k) for k in set(a) | set(b))

    @staticmethod
    def _merge(a, b):
        return {k: a[k] for k in set(a) & set(b) if a[k] == b[k]}

    def _record(self, table, va):
        if RAM_LO <= va < RAM_HI:
            table[va] = table.get(va, 0) + 1

    def _access(self, c, rs, off, load):
        src = c.get(rs)
        if not src:
            return
        if src[0] == 'c':
            self._record(self.reads if load else self.writes, (src[1] + off) & 0xFFFFFFFF)
        elif src[0] == 'i':
            self._record(self.treads if load else self.twrites, (src[1] + off) & 0xFFFFFFFF)
        elif src[0] == 'p':
            cell = self._cell(src[1])
            tgt = (cell, (src[2] + off) & 0xFFFFFFFF)
            tbl = self.sreads if load else self.swrites
            tbl[tgt] = tbl.get(tgt, 0) + 1
        elif src[0] == 'px':
            cell = self._cell(src[1])
            tgt = (cell, (src[2] + off) & 0xFFFFFFFF, src[3])
            tbl = self.sxreads if load else self.sxwrites
            tbl[tgt] = tbl.get(tgt, 0) + 1

    def _cell(self, va):
        """Remember a cell that a handler dereferences as a pointer."""
        if RAM_LO <= va < RAM_HI:
            self.pointer_cells.add(va)
        return va

    def _arith(self, c, rt, rs, imm, kind):
        src = c.get(rs)
        if rs == 0:
            c[rt] = ('c', imm & 0xFFFFFFFF)
            return
        if src is None:
            c.pop(rt, None)
            return
        if src[0] == 'c':
            v = src[1]
            if kind == 'add':
                v = (v + imm) & 0xFFFFFFFF
            elif kind == 'ori':
                v |= imm & 0xFFFFFFFF
            else:
                v &= imm & 0xFFFFFFFF
            c[rt] = ('c', v)
        elif src[0] == 'i' and kind == 'add':
            c[rt] = src
        elif src[0] == 'k' and kind == 'add':
            c[rt] = ('k', None if src[1] is None else src[1] + imm)
        elif src[0] == 'p' and kind == 'add':
            c[rt] = ('p', src[1], (src[2] + imm) & 0xFFFFFFFF)
        elif src[0] == 'px' and kind == 'add':
            c[rt] = ('px', src[1], (src[2] + imm) & 0xFFFFFFFF, src[3])
        else:
            c.pop(rt, None)

    def _addu(self, c, rd, rs, rt):
        a, b = c.get(rs), c.get(rt)
        if a and a[0] == 'c' and b and b[0] == 'c':
            c[rd] = ('c', (a[1] + b[1]) & 0xFFFFFFFF)
        elif a and a[0] == 'c' and (b is None or b[0] == 'u'):
            c[rd] = ('i', a[1], rt, 1)
        elif b and b[0] == 'c' and (a is None or a[0] == 'u'):
            c[rd] = ('i', b[1], rs, 1)
        elif a and a[0] == 'i' and b and b[0] == 'c':
            c[rd] = ('i', (a[1] + b[1]) & 0xFFFFFFFF, a[2], a[3])
        elif b and b[0] == 'i' and a and a[0] == 'c':
            c[rd] = ('i', (b[1] + a[1]) & 0xFFFFFFFF, b[2], b[3])
        elif a and a[0] == 'p' and b and b[0] == 'c':
            c[rd] = ('p', a[1], (a[2] + b[1]) & 0xFFFFFFFF)
        elif b and b[0] == 'p' and a and a[0] == 'c':
            c[rd] = ('p', b[1], (b[2] + a[1]) & 0xFFFFFFFF)
        elif a and a[0] == 'p' and (b is None or b[0] in ('u', 'px')):
            c[rd] = ('px', a[1], a[2], rt)
        elif b and b[0] == 'p' and (a is None or a[0] in ('u', 'px')):
            c[rd] = ('px', b[1], b[2], rs)
        elif a and a[0] == 'px' and b and b[0] == 'c':
            c[rd] = ('px', a[1], (a[2] + b[1]) & 0xFFFFFFFF, a[3])
        elif b and b[0] == 'px' and a and a[0] == 'c':
            c[rd] = ('px', b[1], (b[2] + a[1]) & 0xFFFFFFFF, b[3])
        else:
            c.pop(rd, None)

    def _succ_state(self, pc):
        out = list(self.extra_succ.get(pc, []))
        return out

    # -- abstract interpretation ------------------------------------------
    def _analyze(self):
        # the cursor global is modelled as a memory cell so that re-loading it
        # keeps the entry-relative operand offset ('k', n)
        CK = '@%08x' % CURSOR
        states = {self.entry: {CK: ('k', 0)}}
        work = [self.entry]
        while work:
            pc = work.pop()
            st = states[pc]
            w, s, f = self.code[pc]
            c = dict(st)
            op = f['op']
            fn = f.get('fn')
            if op == 0x0F:
                c[f['rt']] = ('c', (f['uimm'] << 16) & 0xFFFFFFFF)
            elif op in (8, 9):
                self._arith(c, f['rt'], f['rs'], f['imm'], 'add')
            elif op == 0x0B:
                src = c.get(f['rs'])
                if src and src[0] == 'u':
                    c[f['rt']] = ('u', None)
                    c[f['rs']] = ('u', f['imm'])
                else:
                    c.pop(f['rt'], None)
            elif op == 0x0D:
                self._arith(c, f['rt'], f['rs'], f['uimm'], 'ori')
            elif op == 0x0C:
                self._arith(c, f['rt'], f['rs'], f['uimm'], 'andi')
            elif op == 0 and fn == 0x21:
                self._addu(c, f['rd'], f['rs'], f['rt'])
            elif op == 0 and fn == 0x2B:          # sltu: const vs byte bounds
                a, b = c.get(f['rs']), c.get(f['rt'])
                if a and a[0] == 'c' and b and b[0] == 'u' and b[1] is None:
                    c[f['rt']] = ('u', a[1] + 1)
                elif b and b[0] == 'c' and a and a[0] == 'u' and a[1] is None:
                    c[f['rs']] = ('u', b[1] + 1)
                c.pop(f['rd'], None)
            elif op == 0 and fn in (0x00, 0x02, 0x03) and f['rd'] != 0:
                src = c.get(f['rt'])
                if src and src[0] == 'c':
                    v = src[1]
                    if fn == 0x00:
                        v = (v << f['sa']) & 0xFFFFFFFF
                    elif fn == 0x02:
                        v = v >> f['sa']
                    else:
                        v = v >> f['sa']
                    c[f['rd']] = ('c', v)
                elif src and src[0] == 'i' and fn == 0x00:
                    c[f['rd']] = ('i', src[1], src[2], src[3] * (1 << f['sa']))
                elif src and src[0] == 'u' and fn == 0x00:
                    c[f['rd']] = ('u', src[1])
                else:
                    c.pop(f['rd'], None)
            elif op in LOAD_OPS:
                self._access(c, f['rs'], f['imm'], load=True)
                src = c.get(f['rs'])
                if src and src[0] == 'k':
                    if src[1] is not None:
                        self.cursor_reads.add(src[1] + f['imm'])
                    c[f['rt']] = ('u', None)
                elif op == 0x23 and src and src[0] == 'i':
                    idx = c.get(src[2])
                    n = idx[1] if (idx and idx[0] == 'u' and idx[1]) else 16
                    c[f['rt']] = ('j', (src[1] + f['imm']) & 0xFFFFFFFF, n)
                elif (op == 0x23 and src and src[0] == 'c'
                      and ((src[1] + f['imm']) & 0xFFFFFFFF) == CURSOR):
                    c[f['rt']] = c.get(CK, ('k', 0))
                elif op == 0x23 and src and src[0] == 'c':
                    # a word load from a constant address: the register now
                    # holds the pointer stored in that global cell.
                    c[f['rt']] = ('p', (src[1] + f['imm']) & 0xFFFFFFFF, 0)
                else:
                    c[f['rt']] = ('u', None)
            elif op in STORE_OPS:
                src = c.get(f['rs'])
                if (op == 0x2B and src and src[0] == 'c'
                        and ((src[1] + f['imm']) & 0xFFFFFFFF) == CURSOR):
                    v = c.get(f['rt'])
                    c[CK] = v if (v and v[0] == 'k') else ('u', None)
                    self.cursor_writes.add(v[1] if (v and v[0] == 'k') else None)
                self._access(c, f['rs'], f['imm'], load=False)
            elif op == 3:
                self.calls[f['jt']] = self.calls.get(f['jt'], 0) + 1
            elif op == 0 and fn == 0x09:
                self.jalr.append(pc)
            elif op == 0 and fn == 0x08:
                src = st.get(f['rs'])
                if src and src[0] == 'j':
                    tgt, n = src[1], src[2]
                    for i in range(n):
                        e = word(tgt + 4 * i)
                        if e and RAM_LO <= e < RAM_HI and e % 4 == 0 and e not in self.code:
                            self.sub_entries.append(e)
                            self._walk(e)
            else:
                if op == 0:
                    if fn in (0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
                              0x2A, 0x2B, 0x02, 0x03, 0x04, 0x10, 0x12):
                        c.pop(f['rd'], None)
                elif op in (0x08, 0x0A, 0x0B, 0x0E):
                    c.pop(f['rt'], None)
                elif op == 0x01 and f['rt'] in (0x10, 0x11):
                    c[31] = ('u', None)
            # Caller-saved registers are clobbered by the *callee*, i.e. after
            # the delay slot has run.  Popping them at the call instruction
            # itself loses any struct pointer the delay slot still uses (this
            # hid opcode 0x25's `sh $v0,0x4de($a0)` delay-slot store).
            call_after = op == 3 or (op == 0 and fn == 0x09)
            if call_after:
                c_after = dict(c)
                for r in CALLER_CLOBBER:
                    c_after.pop(r, None)
            for t in self._succ(pc, f) + self._succ_state(pc):
                if t not in self.code:
                    continue
                tc = c_after if (call_after and t == pc + 8) else c
                old = states.get(t)
                if old is None:
                    states[t] = tc
                    work.append(t)
                elif self._diff(old, tc):
                    states[t] = self._merge(old, tc)
                    work.append(t)


def handler_disasm(entry):
    """(ordered [(pc, word, fields, asm)] list, scan) for one handler entry."""
    sc = HandlerScan(entry)
    return [(pc, sc.code[pc][0], sc.code[pc][2], sc.code[pc][1])
            for pc in sorted(sc.code)], sc


# ---------------------------------------------------------------------------
# The 82-opcode effect table.
#
# Per entry:
#   name       short mnemonic label
#   operands   list of (symbol, kind) -- kind is 'b','w','tbl' or a note
#   reads      global names read (None where the read is struct-relative)
#   writes     global names written
#   calls      engine functions called
#   effect     one-line statement of what the opcode does to game state
#   control    'next' | 'rewind' | 'branch' | 'stop' | 'reloop'
#   status     'proven' | 'partial'
#   evidence   where the reading comes from
# ---------------------------------------------------------------------------
EFFECTS = {}


def _e(op, **kw):
    kw.setdefault('status', 'proven')
    kw.setdefault('control', 'next')
    kw.setdefault('reads', ())
    kw.setdefault('writes', ())
    kw.setdefault('calls', ())
    EFFECTS[op] = kw


# ---------------------------------------------------------------------------
# THE OPCODE EFFECT TABLE
#
# Every live opcode (all 79 of the 82 table slots; 3/39/40 are NULL) carries an
# entry here.  Fields:
#   name      short mnemonic
#   operands  (symbol, kind) pairs; kind 'b' = 1 byte.  Where the layout is
#             data-dependent the entry adds 'layout' with the rule.
#   reads     globals read (ints are machine-checked against the disassembly)
#   writes    globals written (ints are machine-checked)
#   calls     engine functions called (ints are machine-checked)
#   effect    what the opcode does to game state, i.e. what a port must run
#   control   'next'  = continue at the byte after the operands
#             'rewind'= may move the cursor back (wait / re-execute)
#             'branch'= computes a non-linear cursor (jump / switch)
#             'stop'  = yield the frame (clears the re-loop flag)
#             'reloop'= keep interpreting more opcodes in this same frame
#             'callback'= overlay-defined cursor continuation
#   status    'proven' | 'partial'
# ---------------------------------------------------------------------------
from event_vm_effects import EFFECTS

_SCAN_CACHE = {}

def scan(op):
    """Cached HandlerScan for one opcode (None for a NULL table slot)."""
    h = handler_table()[op]
    if not h:
        return None
    if op not in _SCAN_CACHE:
        _SCAN_CACHE[op] = HandlerScan(h)
    return _SCAN_CACHE[op]


def operand_span(op):
    """Machine-derived operand footprint of one opcode.

    Returns (min_bytes, max_bytes, computed) where the values come from the
    entry-relative cursor offsets the handler reads and writes:
      min_bytes = max(read offsets) + 1   (fewest operand bytes ever read)
      max_bytes = max(write offsets)      (furthest the cursor is advanced)
      computed  = the handler also moves the cursor by a computed amount
                  (relative branch / switch), so the span is not a layout.
    """
    sc = scan(op)
    if sc is None:
        return (0, 0, False)
    rd = [x for x in sc.cursor_reads if x is not None]
    wr = [x for x in sc.cursor_writes if x is not None]
    lo = (max(rd) + 1) if rd else 0
    hi = max([lo] + [w for w in wr if w > 0]) if wr else lo
    return (lo, hi, None in sc.cursor_writes)


def global_name(va):
    if va in GLOBALS:
        return GLOBALS[va][0]
    return '0x%08x' % va


def call_name(va):
    return CALL_NAMES.get(va, '0x%08x' % va)


# ---------------------------------------------------------------------------
# Pointer globals, struct fields, and whole-image cross-references
# ---------------------------------------------------------------------------
# A *pointer global* is a 4-byte cell whose content the engine dereferences as
# a struct base.  Offsets written through one (`area_state+0x4D8`) are the
# fields whose meaning this analysis has to name: an offset alone is not a
# claim, but offset + the routine that consumes it is.
POINTER_GLOBALS = {
    0x8017A110: 'sprite_slot_work_ptr',
    0x8017A118: 'trigger_scan_work_ptr',
    0x8017AAE4: 'area_header_ptr',
    0x8017AF94: 'sysfont_desc_table',
    0x8017B7FC: 'hud_work_ptr',
    0x8017BE20: 'area_state_ptr',
    0x8017C038: 'tile_entry_table_ptr',
    0x8017C0BC: 'teardown_word_c0bc',
    0x8017C108: 'area_struct_ptr',
    0x8017C164: 'game_state_copy_ptr',
    0x8017C21C: 'sprite_pool_ptr',
    0x8017DAA0: 'area_tile_desc_table',
    0x8017DB24: 'game_state_ptr',
}

# (pointer global, offset) -> (name, what consumes it).  Every one of these is
# machine-checked by the EVIDENCE checks below; `--verify` re-derives them.
STRUCT_FIELDS = {
    (0x8017BE20, 0x037): ('area_state_transition_flags', 'be20 flag byte, |=8 / |=0x10 from op 0x47'),
    (0x8017BE20, 0x039): ('area_state_scroll_step', 'fade step written by op 0x48; read by scroll_offset_accumulator @0x8013EE6C'),
    (0x8017BE20, 0x089): ('area_state_party_order', 'six-entry party id list rebuilt by op 0x3B'),
    (0x8017BE20, 0x0BC): ('area_state_transition_vector', 'direction/distance block written by op 0x51'),
    (0x8017BE20, 0x441): ('fade_scan_active', 'read by text_color_pair_driver @0x80134158 and entity_table_sweep_true @0x80130A48'),
    (0x8017BE20, 0x442): ('fade_scan_timer', 'set to 0x12 by flag800_clear_all @0x80140520'),
    (0x8017BE20, 0x443): ('fade_scan_index', 'scan cursor in the 0x801404B8..0x801409D0 family'),
    (0x8017BE20, 0x444): ('fade_scan_mode', '0/1/2 selector set by op 0x22 arms'),
    (0x8017BE20, 0x446): ('fade_scan_acc', 'halfword accumulator in the same family'),
    (0x8017BE20, 0x448): ('fade_scan_timer_b', 'halfword compared with 0xB4 by flag800_apply_b @0x80140988'),
    (0x8017BE20, 0x44C): ('fade_scan_limit', 'halfword limit set by op 0x22 sel 2'),
    (0x8017BE20, 0x44E): ('fade_scan_generation', 'halfword incremented by flag800_clear_all @0x801404F0'),
    (0x8017BE20, 0x450): ('tile_entry_object_record', '8-byte tile-entry selector; consumed by sprite_slot_array_update @0x8013EC20 and entity_move_collision_resolve @0x8012DD98'),
    (0x8017BE20, 0x474): ('dialogue_string_index', 'index into the area string-pointer table 0x80167658, set by op 0x49 (sh at 0x8013BC44); read as an index back by op 0x49 itself at 0x8013B9E4 and tested non-zero by transition_dialogue_buffers_init @0x8012D528'),
    (0x8017BE20, 0x476): ('dialogue_aux_bytes', 'cleared by op 0x49 @0x8013BC48; the +0x477 companion is the entry+0x1E byte when entry+0x1C has bits 0xC, else 0 (0x8013BC4C..0x8013BC80)'),
    (0x8017BE20, 0x47A): ('dialogue_actor_x', 'halfword x of the current dialogue actor; written by op 0x49 @0x8013BB4C, find_record_type06 @0x8013748C and entity_table_sweep_true @0x80131574; copied into the record at +0 by dialogue_state_manager @0x80137A10'),
    (0x8017BE20, 0x47C): ('dialogue_actor_y', 'halfword y of the current dialogue actor; written by op 0x49 @0x8013BB50, find_record_type06 @0x801374A4 and entity_table_sweep_true @0x80131578; copied into the record at +1 by dialogue_state_manager @0x80137A28'),
    (0x8017BE20, 0x47E): ('dialogue_actor_flags', 'halfword flags; bit 0x20 selects the object re-create arm in dialogue_state_manager @0x801379D8, written by op 0x49 @0x8013BB58 and find_record_type06 @0x80137498'),
    (0x8017BE20, 0x480): ('dialogue_actor_record', 'pointer to the area tile/entity record the dialogue actor uses; written by op 0x49 @0x8013BB48, find_record_type06 @0x80137480 and entity_table_sweep_true @0x80131570; dereferenced by dialogue_state_manager @0x801379C0 (frees/+0xC object handle, copies +0x47A/+0x47C into record +0/+1)'),
    (0x8017BE20, 0x478): ('dialogue_flag_byte', 'game-state byte index set by find_record_type06 @0x80137374, read by dialogue_state_manager @0x80137A40 and op 0x49 @0x8013BB14'),
    (0x8017BE20, 0x479): ('dialogue_flag_bits', 'bits XORed into game_state[0x190 + +0x478] by dialogue_state_manager @0x80137A4C and ORed by op 0x49 @0x8013BB30; set by find_record_type06 @0x80137384'),
    (0x8017BE20, 0x494): ('area_param_value', 'entry+0xC of the area +0x10 table; read by menu_gold_setup_driver @0x8012D028'),
    (0x8017BE20, 0x498): ('area_param_oneshot', 'one-shot callback pointer; game_state_driver @0x80132C28 jalr\'s it then clears it'),
    (0x8017BE20, 0x49C): ('area_frame_handler', 'per-frame state handler installed by op 0x4F; game_state_driver @0x80132C04 jalr\'s it'),
    (0x8017BE20, 0x4D8): ('fade_enable_word', 'nonzero = fade overlay active; read by field_update_driver @0x80131C20'),
    (0x8017BE20, 0x4DC): ('fade_level', 'fade brightness; copied into the overlay quad colour bytes at 0x80131C84 and driven by scroll_offset_accumulator'),
    (0x8017BE20, 0x4DD): ('fade_blend_mode', '1 or 2; passed to the quad builder at 0x80131CBC'),
    (0x8017BE20, 0x4DE): ('fade_slot_index', 'draw-slot index 0x0A; used at 0x80131CF0'),
    (0x8017BE20, 0x4E0): ('field_transition_state', 'nonzero gate in field_update_driver @0x801319E4; set by op 0x43'),
    (0x8017BE20, 0x4E1): ('field_transition_b', 'cleared by entity_table_sweep_true @0x80131548'),
    (0x8017BE20, 0x4E2): ('field_transition_c', 'read/written by h2da_bit_gated_dispatch @0x80141C5C'),
    (0x8017DB24, 0x028): ('game_state_party_slots_b', 'six-byte char-id list written by op 0x4A'),
    (0x8017A148, 0x000): ('sprite_upload_type', '8-byte selector array; op 0x06 fills it, sprite_struct_batch_update @0x8013E4AC consumes it'),
    (0x8017A150, 0x000): ('sprite_upload_param', '8-byte parameter-table index; consumed at 0x8013E4BC/0x8013E544'),
    (0x8017A158, 0x000): ('sprite_upload_enable', '8-byte enable gate; consumed at 0x8013E4BC'),
}

_IMAGE_WORDS = None


def image_words():
    """[(va, word)] for every 4-byte word of the MAIN.EXE image."""
    global _IMAGE_WORDS
    if _IMAGE_WORDS is None:
        img = main_image()
        _IMAGE_WORDS = [(MAIN_BASE + 4 * i, struct.unpack_from('<I', img, 4 * i)[0])
                        for i in range(len(img) // 4)]
    return _IMAGE_WORDS


def _mips_writers():
    import mips_writers
    return mips_writers


def base_origin(va, reg):
    """What `reg` holds at `va`: ('const', v) | ('cell', G) | None.

    ('cell', G) means the register was loaded with `lw $reg, off(G)` for a
    constant address G -- i.e. it holds the *pointer stored in* the global cell
    at G (or G+off).  That is the step that turns `obscure offset 0x4E0` into
    `area_state_ptr + 0x4E0`, and it is the whole reason the struct fields are
    nameable at all.
    """
    mw = _mips_writers()
    if reg == 0:
        return ('const', 0)
    r = mw.writer_of(va, reg, reader=word)
    if r is None:
        return None
    pc, s, f = r
    if mw.is_load(f):
        src, _chain = mw.resolve_reg(pc, f['rs'], reader=word)
        if src is None:
            return None
        return ('cell', (src + f['imm']) & 0xFFFFFFFF)
    v, _chain = mw.resolve_reg(va, reg, reader=word)
    if v is None:
        return None
    return ('const', v)


_MEM_LOAD_OPS = {0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26}
_MEM_OPS = _MEM_LOAD_OPS | {0x28, 0x29, 0x2A, 0x2B, 0x2E}


def struct_xrefs(off, cell=0x8017BE20):
    """[(va, asm, 'load'|'store', fn)] for every image access to *(cell)+off.

    Scans the *whole* image, not just one handler, so the accessors of a field
    are found even when the consumer is a frame routine far from the VM.
    `fn` is the enclosing routine from kit/work/function_labels.csv when known.
    """
    out = []
    for va, w in image_words():
        op = (w >> 26) & 0x3F
        if op not in _MEM_OPS:
            continue
        if (w & 0xFFFF) != off:
            continue
        if base_origin(va, (w >> 21) & 0x1F) != ('cell', cell):
            continue
        out.append((va, dec(va, w)[0], 'load' if op in _MEM_LOAD_OPS else 'store',
                    routine_of(va)))
    return out


def jal_xrefs(target):
    """[(va, asm, fn)] for every `jal target` in the image."""
    out = []
    for va, w in image_words():
        if (w >> 26) & 0x3F != 3:
            continue
        t = ((va + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)
        if t == target:
            out.append((va, dec(va, w)[0], routine_of(va)))
    return out


def pointer_table(va, n):
    """The n consecutive words at `va` (a jump/callback table read from the image)."""
    return [word(va + 4 * i) for i in range(n)]


def materializes(va, value):
    """True if the `lui` at `va` is folded into `value` by a following op.

    Handles the `lui` sign-extension trap: `lui $r,0x8018` + `lw $r,-0x5eb8($r)`
    is 0x8017A148, not 0x8018A148.
    """
    w = word(va)
    if w is None or (w >> 26) & 0x3F != 0x0F:
        return False
    rt = (w >> 16) & 0x1F
    for j in range(1, 6):
        b = va + 4 * j
        wb = word(b)
        if wb is None:
            return False
        if (wb >> 21) & 0x1F != rt:
            return False
        op = (wb >> 26) & 0x3F
        if op not in _MEM_OPS and op not in (0x08, 0x09, 0x0D):
            continue
        imm = wb & 0xFFFF
        imm = imm - 0x10000 if imm & 0x8000 else imm
        if ((w & 0xFFFF) << 16) + imm == value:
            return True
    return False


def store_const(va):
    """The constant value stored by a `sw`/`sb`/`sh` at `va`, or None."""
    w = word(va)
    if w is None or (w >> 26) & 0x3F not in (0x28, 0x29, 0x2B):
        return None
    v, _chain = _mips_writers().resolve_reg(va, (w >> 16) & 0x1F, reader=word)
    return v


_RTN_LABELS = None


def _labels():
    global _RTN_LABELS
    if _RTN_LABELS is None:
        import csv
        path = os.path.join(os.path.dirname(_TOOLS), 'work', 'function_labels.csv')
        m = {}
        try:
            with open(path) as fh:
                for row in csv.DictReader(fh):
                    try:
                        m[int(row['address'], 16)] = row.get('name', '')
                    except (KeyError, ValueError):
                        pass
        except IOError:
            pass
        _RTN_LABELS = m
    return _RTN_LABELS


def routine_of(va):
    """(start, name) of the labelled routine containing `va`, or (None, None)."""
    labels = _labels()
    cands = [a for a in labels if a <= va]
    if not cands:
        return (None, None)
    a = max(cands)
    return (a, labels[a])


# ---------------------------------------------------------------------------
# EVIDENCE -- the machine-checked backing for every claim this tool now makes
# beyond the dispatch table and the operand spans.  Each record is one claim
# plus the checks that re-derive it from the image; `--verify` runs them all.
#
# Check kinds (all re-derived from MAIN.EXE through tools/disc.py):
#   ('insn', addr, text)              disassembly at addr contains text
#   ('word', addr, value)             image word at addr == value
#   ('table', addr, [values])         consecutive words at addr
#   ('scan_reads'|'scan_writes', op, va)      HandlerScan(op) absolute access
#   ('scan_treads'|'scan_twrites', op, va)    HandlerScan(op) indexed access
#   ('scan_calls', op, target)
#   ('sread'|'swrite', op, cell, off)         struct-relative access in handler
#   ('sxread'|'sxwrite', op, cell, off)       struct-relative indexed access
#   ('struct_read'|'struct_write', cell, off, addr)   whole-image accessor
#   ('call', target, addr)            a `jal target` exists at addr
#   ('materializes', addr, value)     the lui at addr resolves to value
#   ('store_const', addr, value)      the store at addr stores the constant
# ---------------------------------------------------------------------------
from event_vm_evidence import EVIDENCE


def table_problems():
    """Structural problems with the parsed dispatch table (empty == good)."""
    problems = []
    tbl = handler_table()
    nulls = [i for i in range(TABLE_SIZE) if tbl[i] == 0]
    if nulls != list(NULL_OPCODES):
        problems.append('NULL entries %r != %r' % (nulls, list(NULL_OPCODES)))
    for i, h in enumerate(tbl):
        if h and not (RAM_LO <= h < RAM_HI):
            problems.append('opcode %#04x handler %#x outside the image' % (i, h))
    return problems


def effect_problems():
    """Curated EFFECTS vs the binary: missing ops and unbacked claims."""
    problems = []
    tbl = handler_table()
    for i, h in enumerate(tbl):
        if not h:
            continue
        if i not in EFFECTS:
            problems.append('opcode %#04x (%#x) has no EFFECTS entry' % (i, h))
            continue
        e = EFFECTS[i]
        if not e.get('effect'):
            problems.append('opcode %#04x: empty effect text' % i)
        if e.get('handler') is not None and e['handler'] != h:
            problems.append('opcode %#04x: effect says handler %#x, table says %#x'
                            % (i, e['handler'], h))
    # every declared global write must really be written by that handler
    cache = {}
    for i in sorted(EFFECTS):
        e = EFFECTS[i]
        if not e.get('writes') or tbl[i] == 0:
            continue
        sc = cache.get(i) or handler_disasm(tbl[i])[1]
        cache[i] = sc
        seen = set(sc.writes) | set(sc.twrites)
        for g in e['writes']:
            if isinstance(g, int) and g not in seen:
                problems.append('opcode %#04x claims write of %#x, not in the '
                                'disassembly writes %s' % (i, g, sorted(hex(x) for x in seen)))
        rseen = set(sc.reads) | set(sc.treads)
        for g in e.get('reads', ()):
            if isinstance(g, int) and g not in rseen:
                problems.append('opcode %#04x claims read of %#x, not in the '
                                'disassembly reads %s' % (i, g, sorted(hex(x) for x in rseen)))
        for g in e.get('calls', ()):
            if isinstance(g, int) and g not in sc.calls:
                problems.append('opcode %#04x claims call of %#x, not in the '
                                'disassembly calls' % (i, g))
        # struct-relative claims ('struct_writes' = [(ptr cell, offset), ...])
        for ptr, off in e.get('struct_writes', ()):
            if (ptr, off) not in sc.swrites and (ptr, off) not in [
                    (c, o) for (c, o, _r) in sc.sxwrites]:
                problems.append('opcode %#04x claims write of *(%#x)+%#x, not found '
                                '(swrites=%s)' % (i, ptr, off,
                                                  sorted((hex(c), hex(o)) for c, o in sc.swrites)))
        for ptr, off in e.get('struct_reads', ()):
            if (ptr, off) not in sc.sreads and (ptr, off) not in [
                    (c, o) for (c, o, _r) in sc.sxreads]:
                problems.append('opcode %#04x claims read of *(%#x)+%#x, not found'
                                % (i, ptr, off))
    return problems


def _check_one(kind, args):
    """Re-derive one EVIDENCE check.  Returns a failure string or None."""
    if kind == 'insn':
        addr, sub = args
        w = word(addr)
        if w is None:
            return 'no instruction at %#x' % addr
        text = dec(addr, w)[0]
        return None if sub in text else 'insn %#x is %r, expected %r' % (addr, text, sub)
    if kind == 'word':
        addr, want = args
        got = word(addr)
        return None if got == want else 'word %#x is %s, expected %#x' % (
            addr, hex(got) if got is not None else 'None', want)
    if kind == 'table':
        addr, want = args
        got = [word(addr + 4 * i) for i in range(len(want))]
        return None if got == list(want) else 'table %#x is %s, expected %s' % (
            addr, [hex(g) if g is not None else None for g in got],
            [hex(g) for g in want])
    if kind == 'bytes':
        addr, want = args
        got = [u8(addr + i) for i in range(len(want))]
        return None if got == list(want) else 'bytes %#x are %s, expected %s' % (
            addr, [hex(g) if g is not None else None for g in got],
            [hex(g) for g in want])
    if kind in ('scan_reads', 'scan_writes', 'scan_treads', 'scan_twrites',
                'scan_calls'):
        op, want = args
        sc = scan(op)
        if sc is None:
            return 'opcode %#04x has no handler' % op
        tbl = {'scan_reads': sc.reads, 'scan_writes': sc.writes,
               'scan_treads': sc.treads, 'scan_twrites': sc.twrites,
               'scan_calls': sc.calls}[kind]
        return None if want in tbl else 'opcode %#04x: %s lacks %#x' % (op, kind, want)
    if kind in ('sread', 'swrite', 'sxread', 'sxwrite'):
        op, cell, off = args
        sc = scan(op)
        if sc is None:
            return 'opcode %#04x has no handler' % op
        if kind in ('sread', 'swrite'):
            tbl = sc.sreads if kind == 'sread' else sc.swrites
            return None if (cell, off) in tbl else (
                'opcode %#04x: no %s of *(%#x)+%#x' % (op, kind, cell, off))
        tbl = sc.sxreads if kind == 'sxread' else sc.sxwrites
        if any(c == cell and o == off for c, o, _r in tbl):
            return None
        return 'opcode %#04x: no %s of *(%#x)+%#x (indexed)' % (op, kind, cell, off)
    if kind in ('struct_read', 'struct_write'):
        cell, off, addr = args
        want = 'load' if kind == 'struct_read' else 'store'
        hits = struct_xrefs(off, cell)
        for va, _asm, k, _fn in hits:
            if va == addr and k == want:
                return None
        return 'no %s of *(%#x)+%#x at %#x (found %s)' % (
            want, cell, off, addr, ', '.join('%#x/%s' % (v, k) for v, _a, k, _f in hits))
    if kind == 'call':
        target, addr = args
        for va, _asm, _fn in jal_xrefs(target):
            if va == addr:
                return None
        return 'no `jal %#x` at %#x' % (target, addr)
    if kind == 'materializes':
        addr, value = args
        return None if materializes(addr, value) else (
            'the lui at %#x does not resolve to %#x' % (addr, value))
    if kind == 'store_const':
        addr, value = args
        got = store_const(addr)
        return None if got == value else 'store %#x stores %s, expected %#x' % (
            addr, hex(got) if got is not None else 'None', value)
    if kind == 'routine':
        addr, start = args
        got = routine_of(addr)[0]
        return None if got == start else 'routine of %#x is %s, expected %#x' % (
            addr, hex(got) if got is not None else 'None', start)
    if kind == 'reg_value':
        addr, reg, value = args
        got, _chain = _mips_writers().resolve_reg(addr, reg, reader=word)
        return None if got == value else (
            'register %d at %#x resolves to %s, expected %#x' % (
                reg, addr, hex(got) if got is not None else 'None', value))
    return 'unknown check kind %r' % kind


def evidence_problems():
    """Re-derive every EVIDENCE claim from the image (empty == all supported)."""
    problems = []
    for rec in EVIDENCE:
        for check in rec['checks']:
            msg = _check_one(check[0], check[1:])
            if msg:
                problems.append('op %#04x: %s' % (rec['op'], msg))
    return problems


def proven_ops():
    """The opcodes whose EFFECTS entry is proven (plus the inline 0x03)."""
    return sorted(op for op, e in EFFECTS.items() if e.get('status') != 'partial')


def partial_ops():
    return sorted(op for op, e in EFFECTS.items() if e.get('status') == 'partial')


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _fmt_ops(entry):
    if not entry.get('operands'):
        return '-'
    return ', '.join('%s:%s' % (n, k) for n, k in entry['operands'])


def cmd_table():
    tbl = handler_table()
    print('event-VM dispatch table @ %#x (%d entries); tick @ %#x, cursor @ %#x'
          % (TABLE_BASE, TABLE_SIZE, TICK, CURSOR))
    for i, h in enumerate(tbl):
        e = EFFECTS.get(i, {})
        span = '' if not h else ('ops %d..%d%s' % (
            operand_span(i)[0], operand_span(i)[1],
            '+' if operand_span(i)[2] else ''))
        print('%#04x  %s  %-30s %-14s %s' % (
            i,
            ('--------' if not h else '%08x' % h),
            e.get('name', '(NULL)' if not h else '(no effect entry)'),
            span,
            e.get('effect', '')))


def cmd_op(op):
    tbl = handler_table()
    h = tbl[op]
    e = EFFECTS.get(op, {})
    print('opcode %#04x  handler %s' % (op, ('(NULL)' if not h else '%#010x' % h)))
    for key in ('name', 'operands', 'effect', 'control', 'status', 'evidence'):
        if key in e:
            print('  %-9s %s' % (key + ':', e[key] if key != 'operands' else _fmt_ops(e)))
    if e.get('reads'):
        print('  reads:    %s' % ', '.join(global_name(g) if isinstance(g, int) else g
                                          for g in e['reads']))
    if e.get('writes'):
        print('  writes:   %s' % ', '.join(global_name(g) if isinstance(g, int) else g
                                          for g in e['writes']))
    if e.get('calls'):
        print('  calls:    %s' % ', '.join(call_name(c) if isinstance(c, int) else c
                                           for c in e['calls']))
    if h:
        ins, sc = handler_disasm(h)
        print('  -- disassembly (%d instructions, %d jump-table arms) --'
              % (len(ins), len(sc.sub_entries)))
        for pc, w, f, asm in ins:
            print('   %08x  %s' % (pc, asm))


def cmd_json():
    import json
    tbl = handler_table()
    out = []
    for i, h in enumerate(tbl):
        e = dict(EFFECTS.get(i, {}))
        e['opcode'] = i
        e['handler'] = h
        for k in ('reads', 'writes', 'calls'):
            e[k] = [global_name(x) if k != 'calls' else call_name(x)
                    for x in e.get(k, ()) if isinstance(x, int)]
        e['operands'] = [{'name': n, 'kind': k} for n, k in e.get('operands', ())]
        out.append(e)
    print(json.dumps(out, indent=1))


def disasm_report():
    """Text listing of every handler: instructions + machine-extracted globals."""
    tbl = handler_table()
    for i, h in enumerate(tbl):
        if not h:
            continue
        ins, sc = handler_disasm(h)
        e = EFFECTS.get(i, {})
        print('### op %#04x handler %#010x  %s' % (i, h, e.get('name', '')))
        for pc, w, f, asm in ins:
            tag = ''
            if f['op'] in (2, 3):
                tag = '   ; -> %s' % call_name(f['jt'])
            if pc in sc.sub_entries:
                tag += '   [jump-table arm]'
            print('  %08x  %s%s' % (pc, asm, tag))
        print('  -- writes   : %s' % ', '.join('%s%s' % (global_name(a), '[]' if a in sc.twrites else '')
                                               for a in sorted(sc.writes) + sorted(sc.twrites)))
        print('  -- reads    : %s' % ', '.join('%s%s' % (global_name(a), '[]' if a in sc.treads else '')
                                               for a in sorted(sc.reads) + sorted(sc.treads)))
        print('  -- calls    : %s' % ', '.join(call_name(c) for c in sorted(sc.calls)))
        print()



def cmd_layouts():
    """Print the operand-layout disagreements with tools/event_script_decode.py."""
    import event_script_decode as D
    tbl = handler_table()
    print('opcode  machine operand span (min..max advance)  event_script_decode  verdict')
    print('(opcodes whose EFFECTS entry declares a data-dependent layout are not '
          'counted as corrections)')
    nfix = 0
    for op in range(TABLE_SIZE):
        if not tbl[op]:
            continue
        lo, hi, comp = operand_span(op)
        old = D.OPERAND_BYTES.get(op)
        old = 'cond' if op in D.COND_LAYOUT else old
        declared = 'layout' in EFFECTS.get(op, {})
        if declared or comp:
            verdict = 'data-dependent'
        elif isinstance(old, int) and old != lo:
            verdict = 'CORRECTED: %d -> %d' % (old, lo)
            nfix += 1
        else:
            verdict = 'ok'
        print('%#04x    %d..%d%s   %-8s  %s' % (
            op, lo, hi, ' computed' if comp else '', str(old), verdict))
    print('fixed-layout corrections vs the existing decoder: %d' % nfix)


def cmd_xref(off, cell=0x8017BE20):
    """Every image access to *(cell)+off, with the enclosing routine."""
    print('accesses to *(%s)+%#x:' % (global_name(cell), off))
    hits = struct_xrefs(off, cell)
    if not hits:
        print('  (none resolved)')
    for va, asm, kind, fn in hits:
        print('  %08x  %-34s %-5s %s' % (va, asm, kind, fn or '?'))


def cmd_consumers():
    """The EVIDENCE table: each newly proven claim and its consumers."""
    for rec in EVIDENCE:
        print('opcode %#04x  status=%s' % (rec['op'], EFFECTS.get(rec['op'], {}).get('status')))
        print('  consumers: %s' % ', '.join('%s@%#x' % (call_name(c), c)
                                            for c in rec.get('consumers', ())))
        print('  claim: %s' % rec['claim'])
        print('  checks: %d' % len(rec['checks']))
        print()
    print('evidence records: %d, proven opcodes: %d, partial: %d'
          % (len(EVIDENCE), len(proven_ops()), len(partial_ops())))


def cmd_evidence():
    bad = evidence_problems()
    for p in bad:
        print('FAIL: %s' % p)
    if not bad:
        n = sum(len(r['checks']) for r in EVIDENCE)
        print('evidence OK: %d claims, %d checks re-derived from the image'
              % (len(EVIDENCE), n))
    return 1 if bad else 0


def main(argv):
    if '--selftest' in argv:
        bad = table_problems() + effect_problems() + evidence_problems()
        for p in bad:
            print('FAIL: %s' % p)
        print('table: %d entries, %d live handlers, NULL at %s'
              % (TABLE_SIZE, sum(1 for x in handler_table() if x), list(NULL_OPCODES)))
        print('effects: %d/%d live opcodes have effect entries'
              % (len(EFFECTS), sum(1 for x in handler_table() if x)))
        print('evidence: %d claims, %d checks'
              % (len(EVIDENCE), sum(len(r['checks']) for r in EVIDENCE)))
        return 1 if bad else 0
    if '--table' in argv:
        cmd_table()
        return 0
    if '--json' in argv:
        cmd_json()
        return 0
    if '--layouts' in argv:
        cmd_layouts()
        return 0
    if '--disasm' in argv:
        disasm_report()
        return 0
    if '--consumers' in argv:
        cmd_consumers()
        return 0
    if '--evidence' in argv:
        return cmd_evidence()
    if '--xref' in argv:
        i = argv.index('--xref')
        cell = 0x8017BE20
        if '--cell' in argv:
            cell = int(argv[argv.index('--cell') + 1], 0)
        cmd_xref(int(argv[i + 1], 0), cell)
        return 0
    if '--verify' in argv:
        bad = table_problems() + effect_problems() + evidence_problems()
        for p in bad:
            print('FAIL: %s' % p)
        if not bad:
            print('verify OK: table + %d effect entries agree with the binary; '
                  '%d evidence claims (%d checks) re-derived'
                  % (len(EFFECTS), len(EVIDENCE),
                     sum(len(r['checks']) for r in EVIDENCE)))
        return 1 if bad else 0
    if '--op' in argv:
        i = argv.index('--op')
        cmd_op(int(argv[i + 1], 0))
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
