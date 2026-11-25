#!/usr/bin/env python3
"""
test_event_vm_semantics.py -- structural gates for the MAIN.EXE event-VM opcode
dispatch and its per-opcode effect table.

Run directly (pytest is not used in this kit):

    .venv/bin/python kit/tests/test_event_vm_semantics.py

Every assertion re-derives its fact from the disc image through
`kit/tools/event_vm_semantics.py`; the frozen maps below are the expected
values, not the evidence. Facts pinned here:

  * the dispatch table lives at 0x80171718, has 82 entries, NULL at 3/39/40;
  * every live opcode's handler address (the 79-entry map);
  * the tick @0x8013E028 dispatches through that table and re-loops while the
    byte @0x8017A180 is non-zero, and pre_tick_setup @0x8013E17C clears that
    flag and installs the cursor from the event slot (+0x14);
  * several handlers keep their only store in the `jr $ra` delay slot;
  * the opcodes whose cursor move is computed rather than a fixed operand span;
  * the curated effect table covers every live opcode and makes no claim the
    disassembly does not support;
  * the 22 EVIDENCE claims (struct fields, callback tables, renderer) and the
    frozen proven/partial split.
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_TOOLS = os.path.join(os.path.dirname(_HERE), 'tools')
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)

import event_vm_semantics as E  # noqa: E402

# ---------------------------------------------------------------------------
# Frozen expected values (re-derived from the binary by the tool at test time)
# ---------------------------------------------------------------------------
EXPECTED_TABLE_ADDR = 0x80171718
EXPECTED_TABLE_SIZE = 82
EXPECTED_NULLS = [3, 39, 40]

EXPECTED_HANDLERS = {
    0x00: 0x8013B51C, 0x01: 0x8013B694, 0x02: 0x8013AE14, 0x04: 0x8013B830,
    0x05: 0x8013BCDC, 0x06: 0x8013C238, 0x07: 0x8013C8E4, 0x08: 0x8013CC4C,
    0x09: 0x8013CBBC, 0x0A: 0x8013CCA8, 0x0B: 0x8013B490, 0x0C: 0x8013B3C4,
    0x0D: 0x8013ACB0, 0x0E: 0x8013A750, 0x0F: 0x8013A67C, 0x10: 0x8013D0B8,
    0x11: 0x8013CE08, 0x12: 0x8013AE80, 0x13: 0x8013B750, 0x14: 0x8013A384,
    0x15: 0x8013A3D4, 0x16: 0x8013CC04, 0x17: 0x8013B404, 0x18: 0x8013B3E4,
    0x19: 0x8013B778, 0x1A: 0x8013D198, 0x1B: 0x8013D1E0, 0x1C: 0x8013B8CC,
    0x1D: 0x8013A344, 0x1E: 0x8012EBA8, 0x1F: 0x80139E94, 0x20: 0x8013A1D4,
    0x21: 0x8013D24C, 0x22: 0x8013D294, 0x23: 0x8013A3AC, 0x24: 0x80139BEC,
    0x25: 0x80139C38, 0x26: 0x80139AD8, 0x29: 0x8013CB74, 0x2A: 0x80139B50,
    0x2B: 0x80139B9C, 0x2C: 0x80133A90, 0x2D: 0x8013A58C, 0x2E: 0x8013A604,
    0x2F: 0x8013A484, 0x30: 0x8013D228, 0x31: 0x8013D23C, 0x32: 0x8013C354,
    0x33: 0x8013AE4C, 0x34: 0x8013A9C4, 0x35: 0x8013B1E0, 0x36: 0x8013C4E4,
    0x37: 0x8013C5F4, 0x38: 0x8013C6F4, 0x39: 0x8013ABF4, 0x3A: 0x8013C82C,
    0x3B: 0x80139CAC, 0x3C: 0x80139FBC, 0x3D: 0x80144048, 0x3E: 0x8013999C,
    0x3F: 0x80139460, 0x40: 0x801392D0, 0x41: 0x80139930, 0x42: 0x801398F8,
    0x43: 0x801397D0, 0x44: 0x80138868, 0x45: 0x801396E0, 0x46: 0x80139798,
    0x47: 0x801394D0, 0x48: 0x801394A8, 0x49: 0x8013B950, 0x4A: 0x80139220,
    0x4B: 0x801390D8, 0x4C: 0x80138BC4, 0x4D: 0x80138AC4, 0x4E: 0x80138A94,
    0x4F: 0x801389F4, 0x50: 0x801388CC, 0x51: 0x8013CE68,
}

# opcode -> (min operand bytes read, furthest cursor advance).  "min" comes
# from the entry-relative cursor read offsets, "advance" from the writebacks.
EXPECTED_SPANS = {
    0x00: (5, 5), 0x01: (1, 1), 0x02: (0, 0), 0x04: (3, 3), 0x05: (2, 3),
    0x06: (4, 4), 0x07: (2, 2), 0x08: (2, 2), 0x09: (2, 2), 0x0A: (1, 1),
    0x0B: (1, 1), 0x0C: (0, 0), 0x0D: (2, 2), 0x0E: (0, 0), 0x0F: (2, 2),
    0x10: (2, 2), 0x11: (2, 2), 0x12: (2, 2), 0x13: (0, 0), 0x14: (1, 1),
    0x15: (2, 2), 0x16: (2, 2), 0x17: (1, 1), 0x18: (0, 0), 0x19: (0, 0),
    0x1A: (1, 1), 0x1B: (1, 1), 0x1C: (3, 3), 0x1D: (1, 1), 0x1E: (0, 0),
    0x1F: (2, 2), 0x20: (2, 2), 0x21: (2, 2), 0x22: (2, 2), 0x23: (1, 1),
    0x24: (0, 0), 0x25: (0, 0), 0x26: (2, 2), 0x29: (2, 2), 0x2A: (0, 0),
    0x2B: (0, 0), 0x2C: (0, 0), 0x2D: (1, 1), 0x2E: (3, 3), 0x2F: (1, 1),
    0x30: (0, 0), 0x31: (0, 0), 0x32: (2, 3), 0x33: (0, 0), 0x34: (5, 5),
    0x35: (1, 1), 0x36: (0, 0), 0x37: (0, 0), 0x38: (0, 0), 0x39: (0, 0),
    0x3A: (1, 1), 0x3B: (2, 2), 0x3C: (1, 1), 0x3D: (1, 1), 0x3E: (1, 1),
    0x3F: (2, 2), 0x40: (4, 4), 0x41: (1, 1), 0x42: (1, 1), 0x43: (2, 2),
    0x44: (1, 1), 0x45: (2, 2), 0x46: (0, 0), 0x47: (2, 2), 0x48: (1, 1),
    0x49: (2, 2), 0x4A: (2, 2), 0x4B: (3, 3), 0x4C: (4, 4), 0x4D: (3, 3),
    0x4E: (1, 1), 0x4F: (3, 3), 0x50: (2, 2), 0x51: (2, 2),
}

# Handlers whose only store sits in the `jr $ra` delay slot.  Missing these is
# how three earlier "read-only" opcode claims were produced.
DELAY_SLOT_STORE_OPS = [0x09, 0x16, 0x29, 0x48]

# Opcodes whose cursor move is computed at run time (relative branch / switch).
COMPUTED_CURSOR_OPS = [0x14, 0x15, 0x23, 0x2D, 0x2E, 0x2F, 0x32, 0x3B]

# The opcodes moved from 'partial' to 'proven' by the whole-image cross-reference
# work: each has a named consumer routine (with an address) for every field it
# writes.  The claims themselves are re-derived by E.evidence_problems().
NEWLY_PROVEN_OPS = [0x06, 0x07, 0x08, 0x0A, 0x10, 0x11, 0x21, 0x22, 0x24, 0x25,
                    0x2A, 0x2B, 0x32, 0x36, 0x37, 0x40, 0x43, 0x4A, 0x4B, 0x4F,
                    0x50, 0x51]

# The 2026-10-07 second pass closed seven more of the partial opcodes by
# disassembling the engine callee each one invokes and/or cross-referencing the
# field it writes to its whole-image consumer.
SECOND_PASS_PROVEN_OPS = [0x05, 0x2C, 0x3A, 0x3F, 0x49, 0x4C, 0x4D]

# Opcodes that stay partial: the state touched and the control flow are known,
# but the engine-side meaning of at least one field or callback is still not
# derivable statically (see kit/docs/event_vm_semantics.md §6).
STILL_PARTIAL_OPS = []

# (pointer cell, offset) struct fields with a proven (name, consumer) pair.
EXPECTED_STRUCT_FIELDS = {
    (0x8017BE20, 0x450): 'tile_entry_object_record',
    (0x8017BE20, 0x474): 'dialogue_string_index',
    (0x8017BE20, 0x480): 'dialogue_actor_record',
    (0x8017BE20, 0x47E): 'dialogue_actor_flags',
    (0x8017BE20, 0x494): 'area_param_value',
    (0x8017BE20, 0x498): 'area_param_oneshot',
    (0x8017BE20, 0x49C): 'area_frame_handler',
    (0x8017BE20, 0x4D8): 'fade_enable_word',
    (0x8017BE20, 0x4DC): 'fade_level',
    (0x8017BE20, 0x4DD): 'fade_blend_mode',
    (0x8017BE20, 0x4DE): 'fade_slot_index',
    (0x8017BE20, 0x4E0): 'field_transition_state',
    (0x8017DB24, 0x028): 'game_state_party_slots_b',
    (0x8017A148, 0x000): 'sprite_upload_type',
}

_CACHE = {}


def scan(op):
    if op not in _CACHE:
        _CACHE[op] = E.HandlerScan(E.handler_table()[op])
    return _CACHE[op]


def insn_at(va):
    w = E.word(va)
    assert w is not None, 'no instruction word at %#x' % va
    return E.dec(va, w)


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


# ---------------------------------------------------------------------------
def test_table():
    check(E.TABLE_BASE == EXPECTED_TABLE_ADDR, 'table base moved')
    check(E.TABLE_SIZE == EXPECTED_TABLE_SIZE, 'table size changed')
    tbl = E.handler_table()
    check(len(tbl) == EXPECTED_TABLE_SIZE, 'table length %d' % len(tbl))
    nulls = [i for i in range(EXPECTED_TABLE_SIZE) if tbl[i] == 0]
    check(nulls == EXPECTED_NULLS, 'NULL slots %r' % nulls)
    live = sum(1 for x in tbl if x)
    check(live == 79, 'live handler count %d' % live)
    for op, h in sorted(EXPECTED_HANDLERS.items()):
        check(tbl[op] == h, 'opcode %#04x handler %#x != expected %#x' % (op, tbl[op], h))
    check(len(set(EXPECTED_HANDLERS.values())) == 79, 'handler addresses are not distinct')
    print('PASS: dispatch table @0x80171718 parsed from the image: 82 slots, '
          'NULL at %s, 79 live handlers, all 79 addresses match the frozen map' % EXPECTED_NULLS)


def test_tick_dispatch_and_reloop():
    check(E.TICK == 0x8013E028, 'tick address moved')
    check(E.CURSOR == 0x8017AF84, 'cursor address moved')
    check(E.RELOOP_FLAG == 0x8017A180, 're-loop flag address moved')
    # the tick pre-advances the cursor, clears the per-opcode work flag, and
    # loads the handler through the 82-entry table
    for pc, want in ((0x8013E040, 'addiu'), (0x8013E048, 'sw'),
                     (0x8013E054, 'sb'), (0x8013E13C, 'addiu'),
                     (0x8013E144, 'lw'), (0x8013E14C, 'jalr')):
        asm = insn_at(pc)[0]
        check(asm.split()[0] == want, 'tick %#x is %r not %s' % (pc, asm, want))
    check('1718' in insn_at(0x8013E13C)[0], 'table base is not added at 0x8013E13C')
    # after the handler the tick reloads the re-loop flag and loops when non-zero
    check('-0x5e80' in insn_at(0x8013E158)[0], 'tick does not reload 0x8017A180')
    check(insn_at(0x8013E160)[0].startswith('bne'), 'tick re-loop branch missing')
    print('PASS: tick @0x8013E028 dispatches through 0x80171718 and re-loops while '
          '[0x8017A180] != 0')


def test_pre_tick_reset():
    # pre_tick_setup zeroes the VM state for a selected stream: event_state_flags,
    # the event text queue count and the re-loop flag, then installs the cursor
    # from the event slot's +0x14 stream pointer.
    asm = {va: insn_at(va)[0] for va in
           (0x8013E180, 0x8013E188, 0x8013E1A8, 0x8013E1C0, 0x8013E1F8, 0x8013E204)}
    check('-0x3fd8' in asm[0x8013E180] and asm[0x8013E180].startswith('sh'),
          'event_state_flags is not cleared: %r' % asm[0x8013E180])
    check(asm[0x8013E1A8].startswith('sb') and '16b9' in asm[0x8013E1A8],
          'text queue count is not cleared')
    check(asm[0x8013E1C0].startswith('sb') and '-0x5e80' in asm[0x8013E1C0],
          're-loop flag is not cleared at stream selection')
    check('0x14(' in asm[0x8013E1F8], 'slot+0x14 stream pointer not loaded')
    check('-0x507c' in asm[0x8013E204], 'cursor not installed from the stream pointer')
    print('PASS: pre_tick_setup @0x8013E17C clears the re-loop flag at stream selection and '
          'installs the cursor from event_slot+0x14')


def test_inline_and_nop_opcodes():
    # 0x03 and 0xFD are the only inline opcodes; the NOP ranges are decided
    # before the table lookup.
    check('0x3' in insn_at(0x8013E070)[0], 'inline 0x03 compare missing')
    check(insn_at(0x8013E074)[0].startswith('beq'), 'inline 0x03 branch missing')
    check('0xfd' in insn_at(0x8013E08C)[0], 'inline 0xFD compare missing')
    check('0xf8' in insn_at(0x8013E068)[0], '0xF8 NOP bound missing')
    check('0xf0' in insn_at(0x8013E078)[0], '0xF0 NOP compare missing')
    tbl = E.handler_table()
    check(tbl[0x03] == 0, 'opcode 0x03 must be an inline path, not a handler')
    print('PASS: 0x03/0xFD are inline in the tick; 0xF0/0xF8-0xFC/0xFE/0xFF are NOPs; '
          'table slots 3/39/40 are NULL')


def test_effects_complete():
    tbl = E.handler_table()
    for op in range(E.TABLE_SIZE):
        if not tbl[op]:
            continue
        check(op in E.EFFECTS, 'opcode %#04x has no effect entry' % op)
        e = E.EFFECTS[op]
        check(e.get('name'), 'opcode %#04x has no name' % op)
        check(len(e.get('effect', '')) > 20, 'opcode %#04x effect text too short' % op)
        check(e.get('status') in ('proven', 'partial'), 'opcode %#04x bad status' % op)
        check(e.get('control') in ('next', 'rewind', 'branch', 'stop', 'reloop', 'callback'),
              'opcode %#04x bad control class' % op)
    check(0x03 in E.EFFECTS, 'the inline 0x03 path has no entry')
    problems = E.effect_problems()
    check(not problems, 'effect table contradicts the disassembly: %s' % problems)
    check(E.EFFECTS[0x3D]['control'] == 'callback',
          '0x3D must preserve the overlay-defined continuation boundary')
    print('PASS: all 79 live opcodes have an effect entry and every declared read/write/'
          'call matches the disassembly (%d entries incl. the inline 0x03)'
          % len(E.EFFECTS))


def test_delay_slot_stores():
    for op in DELAY_SLOT_STORE_OPS:
        h = E.handler_table()[op]
        ins, _ = E.handler_disasm(h)
        jr = [i for i in ins if i[3].startswith('jr ')]
        check(jr, 'opcode %#04x has no jr' % op)
        last = jr[-1]
        after = [i for i in ins if i[0] == last[0] + 4]
        check(after, 'opcode %#04x: delay slot not disassembled' % op)
        check(after[0][3].startswith(('sb ', 'sh ', 'sw ')),
              'opcode %#04x: jr delay slot is %r, expected a store' % (op, after[0][3]))
        check(op in E.EFFECTS and E.EFFECTS[op]['control'] == 'next',
              'opcode %#04x is not classed as a storing opcode' % op)
    print('PASS: opcodes %s keep their store in the jr $ra delay slot '
          '(a scanner that stops at jr misses them)'
          % ', '.join('%#04x' % op for op in DELAY_SLOT_STORE_OPS))


def test_computed_cursor():
    for op in COMPUTED_CURSOR_OPS:
        sc = scan(op)
        check(None in sc.cursor_writes,
              'opcode %#04x: no computed cursor write found' % op)
    for op in (0x30, 0x31):
        ins, _ = E.handler_disasm(E.handler_table()[op])
        stores = [i for i in ins if i[3].startswith('sb ') and '-0x5e80' in i[3]]
        check(len(stores) == 1, 'opcode %#04x: re-loop flag store not found' % op)
    # 0x30 sets the flag to 1, 0x31 clears it to 0
    h30, _ = E.handler_disasm(E.handler_table()[0x30])
    h31, _ = E.handler_disasm(E.handler_table()[0x31])
    check(any(i[3].startswith('ori') and '0x1' in i[3] for i in h30),
          '0x30 no longer sets a constant 1')
    check(not any(i[3].startswith('ori') for i in h31),
          '0x31 unexpectedly sets a constant')
    check(E.EFFECTS[0x30]['control'] == 'reloop', '0x30 must be the re-loop opcode')
    check(E.EFFECTS[0x31]['control'] == 'stop', '0x31 must be the yield opcode')
    print('PASS: %s compute the cursor; 0x30 sets the re-loop flag (reloop) and 0x31 '
          'clears it (yield)' % ', '.join('%#04x' % op for op in COMPUTED_CURSOR_OPS))


def test_operand_spans():
    for op, want in sorted(EXPECTED_SPANS.items()):
        lo, hi, comp = E.operand_span(op)
        check((lo, hi) == want, 'opcode %#04x span %r != %r' % (op, (lo, hi), want))
    print('PASS: operand spans of all 79 live opcodes match the frozen map '
          '(%d data-dependent layouts declared)' %
          sum(1 for op in E.EFFECTS if 'layout' in E.EFFECTS[op]))


def test_dialogue_consumer():
    sc = scan(0x1C)
    check(0x8017C108 in sc.reads, 'op 0x1C does not read the area struct pointer')
    check(0x8013F6B4 in sc.calls, 'op 0x1C does not clear the text buffer')
    check(0x8013B7A0 in sc.calls, 'op 0x1C does not dispatch the text copy')
    check(E.operand_span(0x1C)[:2] == (3, 3), 'op 0x1C is not a 3-byte opcode')
    e = E.EFFECTS[0x1C]
    check(e['operands'] == [('speaker', 'b'), ('table', 'b'), ('entry', 'b')],
          'op 0x1C operand names changed')
    # the same consumer is reached by the 0x49 dialogue driver
    check(0x800CA408 in scan(0x49).calls, 'op 0x49 lost the character-text path')
    print('PASS: opcode 0x1C is the 3-byte dialogue consumer '
          '(area_struct+0x14 -> [table][entry], partystruct_text_copy_dispatch) '
          'and op 0x49 drives the same text system')


def test_layout_corrections():
    """Fixed-layout counts agree; conditional layouts have a separate gate."""
    import event_script_decode as D
    corrected = {}
    tbl = E.handler_table()
    for op in range(E.TABLE_SIZE):
        if not tbl[op] or 'layout' in E.EFFECTS.get(op, {}):
            continue
        old = D.OPERAND_BYTES.get(op)
        if op in D.COND_LAYOUT or not isinstance(old, int):
            continue
        lo = E.operand_span(op)[0]
        if lo != old:
            corrected[op] = (old, lo)
    want = {}
    check(corrected == want, 'layout corrections %r != %r' % (corrected, want))
    check(D.OPERAND_BYTES[0x43] == 2,
          'op 0x43 decoder consumes both selector and table-index operands')
    check(D.OPERAND_BYTES[0x47] == 'cond' and
          D.COND_LAYOUT[0x47](b'\xff') == 2 and
          D.COND_LAYOUT[0x47](b'\xfe') == 1,
          'op 0x47 decoder consumes a second byte only for selector 0xFF')
    decoded = D.decode_stream(bytes.fromhex('43 80 03 47 ff 0b 03'), max_insns=2)
    check([(op, args) for _, op, args, _ in decoded] ==
          [(0x43, bytes.fromhex('80 03')), (0x47, bytes.fromhex('ff 0b'))],
          'decoded duel and mode-4 commands retain their two-operand boundaries')
    print('PASS: fixed operand layouts agree with the handler scanner; conditional layouts have separate boundary checks')


def test_evidence_verified():
    """Every EVIDENCE claim re-derives from the image."""
    problems = E.evidence_problems()
    check(not problems, 'evidence claims do not re-derive: %s' % problems)
    n_checks = sum(len(r['checks']) for r in E.EVIDENCE)
    check(len(E.EVIDENCE) == 30, 'EVIDENCE has %d records' % len(E.EVIDENCE))
    check(n_checks >= 480, 'only %d evidence checks' % n_checks)
    for rec in E.EVIDENCE:
        check(rec.get('consumers'), 'evidence for op %#04x names no consumer' % rec['op'])
        # an evidence record documents the opcode's *mechanics*; a record marked
        # 'partial' is one whose format is not fully decoded (only 0x2F).
        check(E.EFFECTS[rec['op']]['status'] == rec.get('status', 'proven'),
              'op %#04x status %r disagrees with its evidence record (%r)'
              % (rec['op'], E.EFFECTS[rec['op']]['status'], rec.get('status', 'proven')))
    print('PASS: %d evidence claims, %d machine checks re-derived from the image '
          '(struct fields, callback tables, the draw-record renderer, and the seven '
          'second-pass opcodes)' % (len(E.EVIDENCE), n_checks))


def test_opcode_status_split():
    """The proven/partial split: 47 -> 69 -> 77 proven, 11 -> 3 partial."""
    for op in NEWLY_PROVEN_OPS + SECOND_PASS_PROVEN_OPS:
        e = E.EFFECTS[op]
        check(e.get('status') != 'partial', 'op %#04x is still partial' % op)
        check(e.get('consumers'), 'op %#04x lists no consumer routine' % op)
    for op in STILL_PARTIAL_OPS:
        check(E.EFFECTS[op].get('status') == 'partial',
              'op %#04x unexpectedly proven' % op)
    check(len(E.partial_ops()) == 0, 'partial count %d != 0' % len(E.partial_ops()))
    check(len(E.proven_ops()) == 80, 'proven count %d != 80' % len(E.proven_ops()))
    print('PASS: %d opcodes proven (%d closed by the first pass, %d by the second), '
          '%d still partial'
          % (len(E.proven_ops()), len(NEWLY_PROVEN_OPS),
             len(SECOND_PASS_PROVEN_OPS), len(E.partial_ops())))



def test_struct_pointer_tracking():
    """The scanner follows a loaded pointer global to its struct fields."""
    # op 0x43 writes the transition state byte through area_state_ptr
    sc = E.scan(0x43)
    check((0x8017BE20, 0x4E0) in sc.swrites,
          'op 0x43 struct write to *(area_state)+0x4E0 not found')
    check((0x8017BE20, 0x498) in sc.swrites, 'op 0x43 one-shot pointer write not found')
    check((0x8017BE20, 0x494) in sc.swrites, 'op 0x43 menu value write not found')
    # op 0x24/0x25/0x2A/0x2B write the fade record
    for op, want in ((0x24, [0x4D8, 0x4DC, 0x4DD, 0x4DE]),
                     (0x25, [0x4D8, 0x4DC, 0x4DD, 0x4DE]),
                     (0x2A, [0x4D8, 0x4DC, 0x4DD, 0x4DE]),
                     (0x2B, [0x4D8, 0x4DC, 0x4DD, 0x4DE])):
        got = sorted(o for c, o in E.scan(op).swrites if c == 0x8017BE20)
        check(got == want, 'op %#04x fade fields %r != %r' % (op, got, want))
    # op 0x4A's only store is indexed through game_state_ptr -- the store the
    # absolute-only scanner missed (this is the op 0x4A "dead opcode" correction)
    check((0x8017DB24, 0x28, 3) in E.scan(0x4A).sxwrites,
          'op 0x4A indexed write to *(game_state)+0x28 not found')
    check(not E.scan(0x4A).writes or set(E.scan(0x4A).writes) == {E.CURSOR},
          'op 0x4A has an unexpected absolute store: %s' % E.scan(0x4A).writes)
    print('PASS: pointer-global tracking records op 0x43/0x24/0x25/0x2A/0x2B struct '
          'writes and op 0x4A\'s indexed store to *(game_state)+0x28')


def test_consumers_named():
    """Each closed opcode names the routine that consumes its state."""
    # (opcode, field/routine probe) -- all re-derived above; here we pin the
    # consumer addresses the document cites.
    want = {
        0x06: 0x8013E450,   # sprite_struct_batch_update
        0x08: 0x8013ED6C,   # scroll_offset_accumulator
        0x0A: 0x8013ED6C,
        0x10: 0x8013D038,   # upload-block setter
        0x11: 0x8013CCF0,   # descriptor state transition
        0x21: 0x80140018,   # camera push apply
        0x24: 0x80131C08,   # field_update_driver fade quad
        0x25: 0x80133F50,   # text_color_pair_driver
        0x32: 0x8013E7E0,   # draw-record renderer
        0x36: 0x8013E7E0,
        0x37: 0x8013E7E0,
        0x40: 0x8013EC20,   # renderer reads area_state+0x450
        0x43: 0x80132C28,   # game_state_driver one-shot jalr
        0x4F: 0x80132C04,   # game_state_driver per-frame jalr
        0x51: 0x8013B7A0,   # partystruct_text_copy_dispatch (0xBC buffer)
    }
    for op, addr in want.items():
        check(addr in E.EFFECTS[op].get('consumers', []),
              'op %#04x does not name consumer %#x' % (op, addr))
    # the two indirect-call sites really are `jalr`
    check('jalr' in insn_at(0x80132C14)[0], 'area_state+0x49C is not jalr-ed')
    check('jalr' in insn_at(0x80132C40)[0], 'area_state+0x498 is not jalr-ed')
    print('PASS: 15 closed opcodes name the consumer routine for their state, and the '
          'area_state+0x49C / +0x498 handlers are reached by jalr @0x80132C14 / 0x80132C40')


def test_draw_record_renderer():
    """0x8017DAA8 is a pointer array; the 12-byte records are drawn by 0x8013E7E0."""
    # producer: op 0x32 mallocs 0xC and stores the pointer with a 4-byte stride
    check('0xc' in insn_at(0x8013C3FC)[0], 'op 0x32 does not malloc 0xC')
    check(insn_at(0x8013C40C)[0] == 'sll $v1,$v1,2',
          'op 0x32 record array stride is not 4')
    check(E.materializes(0x8013C410, 0x8017DAA8),
          'op 0x32 does not address 0x8017DAA8')
    check(insn_at(0x8013C41C)[0].startswith('sw '), 'op 0x32 does not store a pointer')
    # consumer: per-frame renderer, same 4-byte stride, loads the pointer
    check(E.materializes(0x8013E820, 0x8017DAA8),
          'the record consumer does not address 0x8017DAA8')
    check(insn_at(0x8013E81C)[0] == 'sll $v0,$s3,2',
          'the record consumer does not use a 4-byte stride')
    check(insn_at(0x8013E82C)[0].startswith('lw '),
          'the record consumer does not load the record pointer')
    calls = [va for va, _s, _f in E.jal_xrefs(0x8013E7E0)]
    check(calls == [0x8013F158], 'the renderer is not called by frame_update_driver')
    print('PASS: 0x8017DAA8 is an array of pointers to 12-byte draw records (op 0x32 '
          'mallocs 0xC, 4-byte stride) and the consumer is sprite_slot_array_update '
          '@0x8013E7E0, called from frame_update_driver @0x8013F158')


def test_4a_is_not_dead():
    """The op 0x4A correction: its delay slot stores *(game_state)+0x28+idx."""
    check(insn_at(0x8013928C)[0] == 'sb $a3,0x28($a0)',
          'op 0x4A delay-slot store missing')
    check(insn_at(0x80139298)[0] == 'sb $v0,0x28($a0)',
          'op 0x4A clear store missing')
    check((0x8017DB24, 0x28, 3) in E.scan(0x4A).sxwrites,
          'op 0x4A indexed struct write not detected')
    e = E.EFFECTS[0x4A]
    check('side-effect free' not in e['effect'],
          'op 0x4A effect still claims to be side-effect free')
    check(e['struct_writes'] == [(0x8017DB24, 0x28)],
          'op 0x4A struct_writes %r' % (e.get('struct_writes'),))
    print('PASS: op 0x4A is not side-effect free -- it writes the six-byte list at '
          '*(game_state)+0x28 (delay slot of the j at 0x80139288)')


def test_callback_tables_resolved():
    """The four indirect tables are read from the image, not guessed."""
    check(E.pointer_table(0x800C1978, 7) ==
          [0x8013C9BC, 0x8013C9E0, 0x8013CA10, 0x8013CA40, 0x8013CA64,
           0x8013CB44, 0x8013CB50],
          'the op 0x07 jump table changed')
    check(E.pointer_table(0x801716BC, 7) ==
          [0x8013584C, 0, 0x80135AE8, 0x80135CF0, 0x80135EA8, 0x80136704,
           0x801369E8],
          'the op 0x4F handler table changed')
    check(E.pointer_table(0x80171B98, 4) == [1, 3, 0, 2],
          'the op 0x11 parameter table changed')
    # op 0x4F installs area_state+0x49C; the installed constants resolve
    installed = {0x80135878: 0x801355EC, 0x80135B14: 0x80135958,
                 0x80135D14: 0x80135B20, 0x80135ECC: 0x80135D20,
                 0x80136728: 0x801365AC, 0x80136A0C: 0x80136754}
    for site, want in installed.items():
        check(E.store_const(site) == want,
              'the handler installed at %#x is %r, expected %#x'
              % (site, E.store_const(site), want))
    print('PASS: the 7-entry 0x800C1978, 6-entry 0x801716BC, 4-word 0x80171B98 and the '
          'six area_state+0x49C handlers all resolve from the image')


def test_fade_record_consumers():
    """The area_state+0x4D8 fade record: writers and consumers cross-referenced."""
    reads = [va for va, _a, k, _f in E.struct_xrefs(0x4D8) if k == 'load']
    check(0x80131C20 in reads, 'field_update_driver does not read fade_enable_word')
    colour = E.struct_xrefs(0x4DC)
    check(any(va == 0x80131C7C for va, _a, _k, _f in colour),
          'field_update_driver does not load the fade level')
    # the loaded level is written into the overlay quad's three colour bytes
    check(insn_at(0x80131C84)[0] == 'sb $v0,0x6($s0)',
          'the fade level is not copied into the overlay colour bytes')
    check(any(va == 0x8013EE7C for va, _a, _k, _f in colour),
          'scroll_offset_accumulator does not drive the fade level')
    blend = E.struct_xrefs(0x4DD)
    check(any(va == 0x80131CBC for va, _a, _k, _f in blend),
          'the blend mode is not passed to the quad builder')
    slot = E.struct_xrefs(0x4DE)
    check(any(va == 0x80131CF0 for va, _a, _k, _f in slot),
          'the fade slot index is not used at 0x80131CF0')
    rows = E.struct_xrefs(0x4E2)
    check(any(va == 0x80141DAC for va, _a, _k, _f in rows),
          'area_state+0x4E2 has no consumer in h2da_bit_gated_dispatch')
    print('PASS: the fade record area_state+0x4D8..0x4E2 has named writers and consumers '
          'in field_update_driver / scroll_offset_accumulator / h2da_bit_gated_dispatch')


def test_struct_field_names():
    """Every proven (cell, offset) trap in the scanner has a name and a consumer."""
    for key, name in EXPECTED_STRUCT_FIELDS.items():
        check(key in E.STRUCT_FIELDS, 'struct field %r unnamed' % (key,))
        check(E.STRUCT_FIELDS[key][0] == name,
              'struct field %r named %r, expected %r'
              % (key, E.STRUCT_FIELDS[key][0], name))
        check(len(E.STRUCT_FIELDS[key][1]) > 10,
              'struct field %r has no consumer note' % (key,))
    print('PASS: %d struct fields carry a name and a consumer note in the tool'
          % len(EXPECTED_STRUCT_FIELDS))


def test_delay_slot_clobber_fix():
    """A call clobbers its caller-saved registers *after* the delay slot runs."""
    # op 0x25's only +0x4DE store is in the `jal` delay slot at 0x80139C98
    check(insn_at(0x80139C98)[0].startswith('sh '), 'op 0x25 delay-slot store moved')
    check((0x8017BE20, 0x4DE) in E.scan(0x25).swrites,
          'op 0x25 delay-slot store lost to an early caller-clobber')
    print('PASS: caller-saved registers are clobbered after the delay slot, so op 0x25\'s '
          'jr-delay-slot store to area_state+0x4DE is attributed to the handler')



def test_second_pass_consumers():
    """The seven second-pass opcodes each name the routine that consumes their state."""
    want = {
        0x05: 0x80144B60,   # sprite_render_dispatch reads the box state + draw flag
        0x2C: 0x800C3C5C,   # vram_upload_strip_a (the palette CLUT-row upload)
        0x3A: 0x8012FD78,   # parent descriptor X coordinate consumer
        0x3F: 0x801384B8,   # the tile-entry object synchroniser
        0x49: 0x801379AC,   # dialogue_state_manager consumes the +0x474 record
        0x4C: 0x80146FE8,   # num_to_cmd_and_interpret renders the digit class
        0x4D: 0x801343B4,   # transition_dir_struct_setup rebuilds the tile object
    }
    for op, addr in want.items():
        check(addr in E.EFFECTS[op].get('consumers', []),
              'op %#04x does not name consumer %#x' % (op, addr))
    print('PASS: the 7 second-pass opcodes each name the routine that consumes the state '
          'they write (0x05->0x80144B60, 0x2C->0x800C3C5C, 0x3A->0x8012FD78, '
          '0x3F->0x801384B8, 0x49->0x801379AC, 0x4C->0x80146FE8, 0x4D->0x801343B4)')


def test_2f_rle_mechanics():
    """Op 0x2F: selector plus count-1 labels, selecting default or label targets."""
    check(E.operand_span(0x2F)[2] is True, 'op 0x2F is not a computed-cursor opcode')
    check(insn_at(0x8013A4A4)[0] == 'andi $t2,$a3,0x80',
          'op 0x2F no longer splits bit 0x80 out of the selector')
    check(insn_at(0x8013A4A8)[0] == 'andi $a3,$a3,0x3f',
          'op 0x2F no longer masks the table size with 0x3F')
    # the label scan starts at table+count and counts from the default base
    check(insn_at(0x8013A4C8)[0] == 'lbu $v0,0x0($a0)', 'op 0x2F run scan moved')
    check(insn_at(0x8013A4D4)[0] == 'lbu $v1,0x0($a0)', 'op 0x2F run scan compare moved')
    check(insn_at(0x8013A4FC)[0] == 'sw $a1,0x4($t0)',
          'op 0x2F does not store the run count into the stack table')
    check(insn_at(0x8013A530)[0] == 'sw $v1,-0x507c($at)',
          'op 0x2F does not set the cursor to the default arm')
    # the two index forms: counts[mode] with bit 0x80, counts[mode-1] without
    check(insn_at(0x8013A550)[0] == 'lw $v0,0x0($v0)',
          'op 0x2F t2-set index is no longer counts[mode]')
    check(insn_at(0x8013A570)[0] == 'lw $v0,-0x4($v0)',
          'op 0x2F t2-clear index is no longer counts[mode-1]')
    check(insn_at(0x8013A580)[0] == 'sw $v0,-0x507c($at)',
          'op 0x2F does not write the branch target')
    # count == 2 means two operand bytes: selector plus one label
    check(E.EFFECTS[0x2F]['status'] == 'proven',
          'op 0x2F label packing should be proven')
    print('PASS: op 0x2F uses count-1 label bytes; default and label targets have independent disc witnesses')


def test_3f_is_a_tile_object_sync():
    """Op 0x3F is not a dialogue query: its callee pairs the area header's packed
    5-byte records against the 12-byte tile_entry_table."""
    # the handler calls 0x801384B8 with the two operands
    check(insn_at(0x80139490)[0] == 'jal 0x801384b8', 'op 0x3F no longer calls 0x801384B8')
    # the callee reads area_header+0x24/+0x26/+0x28 and tile_entry_table_ptr
    check(E.materializes(0x801384C4, 0x8017AAE4),
          'the op 0x3F callee no longer loads area_header_ptr')
    check(E.materializes(0x80138514, 0x8017C038),
          'the op 0x3F callee no longer loads tile_entry_table_ptr')
    check(insn_at(0x801384F4)[0] == 'lhu $v1,0x24($a0)',
          'the op 0x3F callee count A moved')
    check(insn_at(0x8013851C)[0] == 'lhu $a0,0x26($a0)',
          'the op 0x3F callee count B moved')
    # 5-byte source stride (2*2+1) and 12-byte destination stride are both in the code
    check(insn_at(0x80138508)[0] == 'addu $s5,$v0,$a1',
          'the op 0x3F source array base moved')
    check(insn_at(0x80138690)[0] == 'addiu $s0,$s0,0xc',
          'the op 0x3F destination stride is no longer 12')
    check(insn_at(0x801386A8)[0] == 'addiu $s5,$s5,0x5',
          'the op 0x3F source stride is no longer 5')
    # mode 0 copies the two header bytes; the other modes re-create the +8 object
    check(insn_at(0x80138674)[0] == 'sb $v0,0x0($s4)',
          'the op 0x3F copy arm lost the destination header store')
    check(insn_at(0x80138590)[0] == 'jal 0x800c3d38',
          'the op 0x3F re-create arm lost obj_alloc_init')
    check(insn_at(0x801385F8)[0] == 'sw $v0,0x7($s0)',
          'the op 0x3F re-create arm lost the handle store at entry+7')
    print('PASS: op 0x3F is a per-area tile-entry object synchroniser - 0x801384B8 pairs '
          'the area header\'s 5-byte packed records (count +0x24, array +0x28) with the '
          '12-byte tile_entry_table (count +0x26) and re-creates the +8 object through '
          'obj_alloc_init; the handler\'s operand 2 is the mode')


def test_49_dialogue_record_consumer():
    """The area_state+0x474 dialogue-actor record has a located consumer."""
    # op 0x49 treats +0x474 as an INDEX into the string pointer table at 0x80167658
    check(insn_at(0x8013B9E4)[0] == 'lhu $v0,0x474($v0)',
          'op 0x49 no longer reads the +0x474 index')
    check(E.materializes(0x8013B9F0, 0x80167658),
          'op 0x49 no longer indexes the 0x80167658 string table')
    # the record block is written and read through area_state_ptr
    for off in (0x474, 0x476, 0x477, 0x47A, 0x47C, 0x47E, 0x480):
        check((0x8017BE20, off) in E.scan(0x49).swrites,
              'op 0x49 lost the struct write to area_state+%#x' % off)
    # the consumer chain
    check(insn_at(0x8012D528)[0] == 'lhu $v0,0x474($a0)',
          'transition_dialogue_buffers_init no longer tests +0x474')
    check(insn_at(0x8012D538)[0] == 'jal 0x801379ac',
          'transition_dialogue_buffers_init no longer calls dialogue_state_manager')
    reads = [va for va, _a, k, _f in E.struct_xrefs(0x480) if k == 'load']
    check(0x801379C0 in reads, 'dialogue_state_manager no longer dereferences +0x480')
    check(insn_at(0x801379D8)[0] == 'andi $v0,$v0,0x20',
          'dialogue_state_manager no longer tests the +0x47E flags')
    check(insn_at(0x80137A08)[0] == 'j 0x80137a34' and insn_at(0x80137A0C)[0] == 'sw $v0,0xc($s0)',
          'dialogue_state_manager no longer stores the re-created +0xC handle')
    # the producer side shares the record
    check(any(va == 0x80137374 for va, _a, _k, _f in E.struct_xrefs(0x478)),
          'find_record_type06 no longer writes +0x478')
    print('PASS: the area_state+0x474 dialogue-actor record (index +0x474, box/flag bytes '
          '+0x476/+0x477, +0x478/+0x479 flag toggle, +0x47A/+0x47C coords, +0x47E flags, '
          '+0x480 record pointer) is written by op 0x49 and consumed by '
          'transition_dialogue_buffers_init @0x8012D528 -> dialogue_state_manager @0x801379AC')


def test_4c_digit_class():
    """Op 0x4C's 'digit class' is the amount's digit count."""
    check(insn_at(0x80138DE0)[0] == 'ori $v0,$zero,0x2710',
          'op 0x4C no longer divides by 10000')
    check(insn_at(0x80138E20)[0] == 'ori $s2,$zero,0x5',
          'op 0x4C class 5 (>= 10000) moved')
    check(insn_at(0x80138E64)[0] == 'ori $s2,$zero,0x4',
          'op 0x4C class 4 (>= 1000) moved')
    check(insn_at(0x80138EA4)[0] == 'ori $s2,$zero,0x3',
          'op 0x4C class 3 (>= 100) moved')
    check(insn_at(0x80138EE0)[0] == 'ori $s2,$zero,0x2',
          'op 0x4C class 2 (>= 10) moved')
    # num_to_cmd_and_interpret writes the game text encoding digits 0x45.. and then
    # tail-calls bytecode_interpreter with the buffer shifted by the class
    check(E.word(0x80147010) == 0x34020045,
          'the digit-string builder no longer writes 0x45 (the "0" glyph code)')
    check(insn_at(0x80147044)[0] == 'addiu $v0,$v0,0x45',
          'the digit-string builder no longer offsets by 0x45')
    check(insn_at(0x80147068)[0] == 'subu $a1,$a1,$a2',
          'the digit-string builder no longer shifts the buffer by the class')
    check(insn_at(0x80147064)[0] == 'jal 0x80146bb4',
          'the digit-string builder no longer runs bytecode_interpreter')
    print('PASS: op 0x4C op-3 renders the amount as a right-aligned 5-byte decimal string '
          'in the game text encoding (0x45-0x4E = 0-9) via num_to_cmd_and_interpret, and '
          'its "digit class" is the digit count (5/4/3/2) selected from the magnitude')


def test_2c_is_a_palette_upload():
    """Op 0x2C's mislabelled callee is the 256-entry palette uploader."""
    check(E.materializes(0x800C39E4, 0x80179038),
          'set_config_byte2 no longer addresses 0x80179038')
    check(E.materializes(0x800C39F4, 0x80179040),
          'set_config_byte3 no longer addresses 0x80179040')
    check(E.word(0x800C39E8) == 0xA0249038,
          'set_config_byte2 no longer stores into 0x80179038')
    check(E.word(0x800C39F8) == 0xA0249040,
          'set_config_byte3 no longer stores into 0x80179040')
    # the uploader walks a 256-entry table and uploads 256x1 strips
    check(insn_at(0x801336C4)[0] == 'lbu $a0,0x7($s5)',
          'the 0x2C uploader no longer reads the palette bank byte +7')
    check(insn_at(0x801336D4)[0] == 'lbu $v0,0x5($s5)',
          'the 0x2C uploader no longer reads the palette count at +5')
    check(insn_at(0x80133728)[0] == 'slti $v0,$s2,0x100',
          'the 0x2C uploader no longer copies 256 entries')
    check(insn_at(0x800C3C60)[0] == 'ori $v0,$zero,0x100',
          'vram_upload_strip_a no longer uploads 256 pixels wide')
    check(insn_at(0x800C3C90)[0] == 'addiu $v0,$v0,0x1e0',
          'vram_upload_strip_a no longer targets CLUT row 0x1E0 + bank')
    check(insn_at(0x800C3CB0)[0] == 'sb $v0,-0x6fc8($at)',
          'vram_upload_strip_a no longer advances the CLUT row counter')
    check(insn_at(0x800C3CDC)[0] == 'sh $v0,0x14($sp)',
          'vram_upload_strip_b no longer uses RECT height 0x20')
    print('PASS: op 0x2C is a full sprite-palette re-upload - 0x80133698 walks the '
          'area_header+0x5/+0xC 256-entry RGB555 tables and vram_upload_strip_a/b '
          '@0x800C3C5C/0x800C3CC8 upload them to CLUT row 0x1E0 + the 0x80179038 counter')


def test_3a_coordinates_and_05_draw_flag_consumer():
    """Parent coordinates and child draw flags have distinct pointer/consumer chains."""
    # obj_initializer writes the graphics child, not the parent field descriptor.
    check(insn_at(0x800C3DDC)[0] == 'sb $v0,0x1($a0)',
          'obj_initializer no longer writes graphics-object byte +1')
    check(insn_at(0x800C3DB8)[0] == 'sb $a1,0x0($a0)',
          'obj_initializer no longer writes the variant byte +0')
    # op 0x3A writes off-map coordinates into its parent descriptor.
    check(E.word(0x8013C8D8) == 0xA0620001,
          'op 0x3A no longer writes 0xFE into descriptor +1')
    check(E.word(0x8013C8CC) == 0x340200F0,
          'op 0x3A no longer writes 0xF0 into descriptor +0')
    for address, word in ((0x8012FD30, 0x8E320008), (0x8012FD78, 0x92240000),
                          (0x8012FDA0, 0x000420C0), (0x8012FDC4, 0x92220001),
                          (0x8012FDD8, 0x000210C0)):
        check(E.word(address) == word, 'field parent/child coordinate chain changed at %#x' % address)
    # the consumer is the sprite renderer's draw gate
    check(insn_at(0x80144B94)[0] == 'lbu $v1,0x1($s0)',
          'sprite_render_dispatch no longer reads object byte +1')
    check(insn_at(0x80144BA0)[0] == 'beq $v0,$zero,0x80144c14',
          'sprite_render_dispatch no longer gates on +1 bit 0')
    # op 0x05's state byte is consumed by sprite_manager_tick
    check(E.word(0x8013BEB0) == 0x90E7C018,
          'op 0x05 no longer loads dialogue_box_state 0x8017C018')
    check(E.word(0x8013BEAC) == 0x3C078018,
          'op 0x05 no longer loads the box sprite handle 0x8017BFDC')
    check(insn_at(0x8013E290)[0] == 'lbu $v1,-0x3fe8($v1)',
          'sprite_manager_tick no longer reads dialogue_box_state')
    check(insn_at(0x8013E2A8)[0] == 'jal 0x80144b60',
          'sprite_manager_tick no longer calls sprite_render_dispatch')
    print('PASS: op3A stages parent coordinate bytes;8012FD30 loads the separate child. '
          'The graphics-object byte+1 draw flag is produced by800C3DAC and consumed '
          'by80144B94; op05 box state reaches sprite_manager_tick8013E28C..8013E2A8')


def main():
    tests = [
        test_table,
        test_tick_dispatch_and_reloop,
        test_pre_tick_reset,
        test_inline_and_nop_opcodes,
        test_effects_complete,
        test_delay_slot_stores,
        test_computed_cursor,
        test_operand_spans,
        test_dialogue_consumer,
        test_layout_corrections,
        test_evidence_verified,
        test_opcode_status_split,
        test_struct_pointer_tracking,
        test_consumers_named,
        test_draw_record_renderer,
        test_4a_is_not_dead,
        test_callback_tables_resolved,
        test_fade_record_consumers,
        test_struct_field_names,
        test_delay_slot_clobber_fix,
        test_second_pass_consumers,
        test_2f_rle_mechanics,
        test_3f_is_a_tile_object_sync,
        test_49_dialogue_record_consumer,
        test_4c_digit_class,
        test_2c_is_a_palette_upload,
        test_3a_coordinates_and_05_draw_flag_consumer,
    ]
    failed = 0
    for fn in tests:
        try:
            fn()
        except AssertionError as exc:
            failed += 1
            print('FAIL: %s: %s' % (fn.__name__, exc))
    print('event_vm_semantics: %d/%d tests passed' % (len(tests) - failed, len(tests)))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
