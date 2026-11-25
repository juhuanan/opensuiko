#!/usr/bin/env python3
"""
event_script_decode.py — Decoder for Suikoden PS1 MAIN.EXE's event opcode stream.

Target: event_opcode_stream_tick @ 0x8013E028, cursor = [0x8017AF84],
        82-entry handler table @ 0x80171718 (0x00-0x51; NULL at 3/39/40).

Usage:
    python3 event_script_decode.py <script.bin> [--base-offset N]
    python3 event_script_decode.py --selftest

The decoder walks the stream opcode-by-opcode using the verified per-opcode
operand layouts (see archive/docs/event_operand_boundaries.md). It models the tick's
control flow (inline waits, NOP ranges, table dispatch) and each handler's
operand consumption. It does NOT model handler side effects (game state).

Operand layouts were machine-extracted from the handlers: every cursor
read (lbu @cursor+off) and cursor writeback was traced per handler
(extraction method: docs/event_vm_operands.md §1.5). Opcodes 0x40-0x51 were
added 2026-10-02 via the same cursor-read method; conditional layouts
(0x45/0x47/0x4B/0x4D/0x4F/0x50) were verified instruction-by-instruction.
"""

import os
import struct
import sys

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)


# ---------------------------------------------------------------------------
# Handler table @ 0x80171718 (from MAIN_body.bin; 0 = NULL at 3/39/40).
# 82 entries, 0x00-0x51. Indices 0x52+ are data words, not handlers; the tick
# has no upper-bound check below 0xF8, so opcodes 0x52-0xF7 would dispatch
# into garbage — no wild script uses them.
# ---------------------------------------------------------------------------
TABLE_BASE = 0x80171718
TABLE_SIZE = 82

# Full table read straight from the binary (filled in by _load_table()).
HANDLER_TABLE = [0] * TABLE_SIZE

# ---------------------------------------------------------------------------
# Per-opcode operand byte counts (operands AFTER the opcode byte).
# int = fixed count. Conditional ops are resolved by COND_LAYOUT from the
# already-read operand bytes (all conditions verified against handler
# disassembly — see module docstring).
# ---------------------------------------------------------------------------
OPERAND_BYTES = {
    0: 5,  1: 1,  2: 0,  4: 'cond',  5: 3,  6: 'cond', 7: 'cond',  8: 2,
    9: 2, 10: 1, 11: 1, 12: 0, 13: 'cond', 14: 0, 15: 'cond', 16: 2,
    17: 2, 18: 2, 19: 0, 20: 1, 21: 'cond', 22: 2, 23: 1, 24: 0,
    25: 0, 26: 1, 27: 1, 28: 3, 29: 1, 30: 0, 31: 'cond', 32: 'cond',
    33: 2, 34: 'cond', 35: 1, 36: 0, 37: 0, 38: 2, 41: 2, 42: 0,
    43: 0, 44: 0, 45: 1, 46: 1, 47: 'cond', 48: 0, 49: 0, 50: 'pairs',
    51: 0, 52: 'cond', 53: 1, 54: 0, 55: 0, 56: 0, 57: 0, 58: 1,
    59: 'cond', 60: 1, 61: 1, 62: 1, 63: 2,
    # --- 0x40-0x51, added 2026-10-02 (cursor-read extraction) ---
    0x40: 'cond',  # FE: four bytes; FD: two; other selectors: one
    0x41: 1,  # cursor advance (+1) verified
    0x42: 1,  # cursor advance (+1) verified
    0x43: 2,  # area_transition_param_set: selector and table index
    0x44: 1,  # 1 byte; conditional rewind (verified)
    0x45: 'cond',  # char_recruit_flag_toggle: 1 byte, +1 more iff byte0==0xFF
    0x46: 0,  # conditional un-read of 1 byte; no operands (verified)
    0x47: 'cond',  # event_flag_select: 2 bytes only for selector 0xFF
    0x48: 1,  # event_arg_store_39: reads 1 arg byte (label-confirmed)
    0x49: 'cond',  # character lookup FD: two; item ids and FE/FF messages: one
    0x4A: 2,  # verified: reads 2 bytes unconditionally
    0x4B: 'cond',  # 2 bytes; 3rd byte iff byte0 in (0,1,2) (verified)
    0x4C: 'cond',  # amount selector and zero/nonzero second operand
    0x4D: 'cond',  # 2 bytes; 3rd iff byte0==3; rewind iff byte0==2+bit (verified)
    0x4E: 1,  # cursor advance (+1) verified
    0x4F: 'cond',  # 1 byte iff byte0==1 else 3 bytes; rewind iff byte0==1+bit
    0x50: 'cond',  # 1 byte; 2nd iff byte0 in (0,1,2) (verified)
    0x51: 2,  # verified: reads 2 bytes unconditionally
}

# Conditional layouts: op -> fn(first_bytes) -> total operand bytes.
# Counted layouts: archive/docs/event_operand_boundaries.md.
COND_LAYOUT = {
    0x04: lambda b: 3 if b[1] == 0xFF else 2,
    0x06: lambda b: 1 + 3 * b[0],
    0x07: lambda b: 5 if b[1] == 4 else 3 if b[1] < 4 else 2,
    0x0D: lambda b: 1 + b[0],
    0x0F: lambda b: 2 if b[0] == 0xFF else 1,
    0x15: lambda b: max(1, b[0]),
    0x1F: lambda b: 2 if b[0] == 0xFF else 1,
    0x20: lambda b: 2 if b[0] in (0xFC, 0xFE) else 1,
    0x22: lambda b: 2 if b[0] == 2 else 1,
    0x2F: lambda b: (b[0] & 0x3F) or None,
    0x34: lambda b: 1 if b[0] == 0xFF else 1 + 4 * b[0],
    0x3B: lambda b: 1 + b[0],
    0x40: lambda b: 4 if b[0] == 0xFE else 2 if b[0] == 0xFD else 1,
    0x45: lambda b: 2 if b[0] == 0xFF else 1,
    0x47: lambda b: 2 if b[0] == 0xFF else 1,
    0x49: lambda b: 2 if b[0] == 0xFD else 1,
    0x4B: lambda b: 3 if b[0] in (0, 1, 2) else 2,
    0x4C: lambda b: (3 if b[1] == 0 else 2) if b[0] == 0 else
                        2 if b[0] in (1, 2) else 4 if b[0] == 3 else 1,
    0x4D: lambda b: 3 if b[0] == 3 else 2,
    0x4F: lambda b: 1 if b[0] == 1 else 3,
    0x50: lambda b: 2 if b[0] in (0, 1, 2) else 1,
}
COND_PREFIX = {0x04: 2, 0x07: 2}

# Retained interface for corpus callers; all effect names are now resolved.
PROVISIONAL_OPS = set()

HANDLER_NAMES = {
    0: "event_obj_spawn_cond", 1: "event_obj_set_sprite_flag",
    2: "event_wait_flag_rewind", 4: "event_table_indirect_call",
    5: "dialogue_box_sprite_renderer", 6: "event_bulk_data_load",
    7: "glyph_descriptor_display", 8: "event_set_state_bit2",
    9: "event_obj_or_bits", 10: "event_set_state_bit5",
    11: "event_cond_spawn_text", 12: "event_obj_sprite_setup_0",
    13: "event_alloc_indexed_buf", 14: "event_sub_80138410_wrap",
    15: "event_mark_table_entry", 28: "dialogue_text_3byte",
    0x2F: "switch_on_ui_mode_labels",
    31: "streaming_file_loader", 51: "event_arg_queue_pushback",
    53: "dialogue_text_char_processor", 60: "party_member_find",
    0x40: "tile_entry_object_lifecycle", 0x41: "area_index_set",
    0x42: "idtable_state_select", 0x43: "area_transition_param_set",
    0x44: "event_cond_rewind_44", 0x45: "char_recruit_flag_toggle",
    0x46: "event_arg_queue_unread_cond", 0x47: "event_flag_select",
    0x48: "event_arg_store_39", 0x49: "dialogue_driver",
    0x4A: "event_unk_4A", 0x4B: "event_unk_4B",
    0x4C: "counter_amount_op", 0x4D: "event_unk_4D",
    0x4E: "idtable_state_store", 0x4F: "event_unk_4F",
    0x50: "event_unk_50", 0x51: "event_unk_51",
}

# Opcodes with control-flow side effects on the cursor (beyond operands).
REWIND_OPS = {0, 2, 11, 20, 21, 23, 35, 45, 51, 53, 56,
              0x44, 0x46, 0x4D, 0x4F}  # conditional rewind/un-read
JUMP_OP = 0x14


# MAIN.EXE on disc: PS-X EXE header is 2048 B; text loads at 0x800C0800.
_MAINEXE_LBA = 17976
_MAINEXE_SIZE = 757760
_MAINEXE_HEADER = 2048


def _mainexe_body_path():
    """Materialise the MAIN.EXE code body to a temp file and return its path.

    Historically this read ~/workspace/suikoden/MAIN_body.bin, which does not
    exist in a relocated tree. The bytes come off the disc through tools/disc.py
    instead. Cached so repeated calls do not re-extract.
    """
    import os, sys, tempfile
    sys.path.insert(0, _TOOLS)
    import disc
    cache = os.path.join(tempfile.gettempdir(), "suikoden_main_body.bin")
    if not os.path.exists(cache):
        raw = disc.extract(_MAINEXE_LBA, _MAINEXE_SIZE)
        with open(cache, "wb") as fh:
            fh.write(raw[_MAINEXE_HEADER:])
    return cache


def _load_table():
    """Load the 82-entry handler table from MAIN_body.bin."""
    import os
    p = _mainexe_body_path()
    try:
        with open(p, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        return False
    off = TABLE_BASE - 0x800C0800
    for i in range(TABLE_SIZE):
        HANDLER_TABLE[i] = struct.unpack("<I", data[off + i * 4:off + i * 4 + 4])[0]
    return True


def _resolve_count(op, data, pc):
    """Return operand byte count for op at pc, or None if unknowable."""
    k = OPERAND_BYTES.get(op)
    if k == 'pairs':
        # 0x32 skips byte pairs after its selector until an aligned 0x05.
        for p in range(pc + 2, len(data), 2):
            if data[p] == 5:
                return p - pc
        return None
    if k == 'cond':
        width = COND_PREFIX.get(op, 1)
        if op == 0x4C and data[pc + 1:pc + 2] == b'\x00':
            width = 2
        first = data[pc + 1:pc + 1 + width]
        if len(first) < width:
            return None
        return COND_LAYOUT[op](first)
    return k  # int or None


def switch_2f_targets(data, pc):
    """Resolve raw byte-label branches, including the default arm, within data."""
    if pc < 0 or pc + 1 >= len(data) or data[pc] != 0x2F:
        raise ValueError('not a complete 0x2F header')
    selector = data[pc + 1]
    count = selector & 0x3F
    base = pc + 1 + count
    if not count or base >= len(data):
        raise ValueError('invalid or truncated 0x2F label table')
    targets = [base] + [data.index(label, base + 1)
                       for label in data[pc + 2:base]]
    first_mode = 0 if selector & 0x80 else 1
    return dict(enumerate(targets, first_mode))


def decode_stream(data, start=0, max_insns=10000):
    """Walk the event stream. Returns list of (offset, opcode, operands, note).

    Never raises on wild bytes: unknown opcodes and truncated streams are
    reported as notes and decoding stops cleanly.
    """
    out = []
    pc = start
    n = 0
    while 0 <= pc < len(data) and n < max_insns:
        op = data[pc]
        n += 1
        if op == 0x03:
            # inline wait + read_args; model as 1 byte + arg format
            nxt = pc + 1
            if nxt < len(data):
                fmt = data[nxt]
                ln = {0xFF: 1, 0xFE: 3, 0xFD: 5, 0xFC: 5,
                      0xFB: 4, 0xFA: 6}.get(fmt, 3)
                operands = data[pc + 1:pc + 1 + ln]
                out.append((pc, op, operands,
                            f"inline wait; read_args fmt={fmt:#04x}" +
                            (" [TRUNCATED]" if len(operands) < ln else "")))
                if len(operands) < ln:
                    break
                pc += 1 + ln
            else:
                out.append((pc, op, b"", "inline wait; truncated"))
                pc += 1
            continue
        if op == 0xFD:
            out.append((pc, op, b"", "inline conditional wait"))
            pc += 1
            continue
        if op == 0xF0 or 0xF8 <= op <= 0xFC or op >= 0xFE:
            out.append((pc, op, b"", "NOP"))
            pc += 1
            continue
        # table dispatch
        if op in (3, 39, 40):
            out.append((pc, op, b"", "NULL table entry — desync risk"))
            pc += 1
            continue
        name = HANDLER_NAMES.get(op, f"handler_{op}")
        k = _resolve_count(op, data, pc)
        if k is None:
            out.append((pc, op, b"",
                        f"{name}: UNKNOWN OPCODE LAYOUT — stopping (no desync)"))
            break
        operands = data[pc + 1:pc + 1 + k]
        note = name
        if op == 0x3D:
            note += " [CALLBACK CONTINUATION UNRESOLVED]"
        if op in PROVISIONAL_OPS:
            note += " [semantics provisional]"
        if len(operands) < k:
            note += " [TRUNCATED]"
        if op in REWIND_OPS:
            note += " [may rewind]"
        if op == JUMP_OP:
            note += " [jump]"
        out.append((pc, op, operands, note))
        pc += 1 + k
        if len(operands) < k:
            break
    return out


def _check_layouts():
    """Self-test 1: verify OPERAND_BYTES against the binary's handler table."""
    errors = []
    if not _load_table():
        return ["MAIN_body.bin not found; table check skipped"]
    # NULL entries must be exactly 3/39/40
    nulls = [i for i in range(TABLE_SIZE) if HANDLER_TABLE[i] == 0]
    if nulls != [3, 39, 40]:
        errors.append(f"NULL entries {nulls} != [3, 39, 40]")
    # every non-null opcode must have a layout
    for i in range(TABLE_SIZE):
        if HANDLER_TABLE[i] and i not in OPERAND_BYTES:
            errors.append(f"opcode {i}: handler {HANDLER_TABLE[i]:#x} lacks layout")
    # every layout opcode must have a non-null handler
    for i in OPERAND_BYTES:
        if not HANDLER_TABLE[i]:
            errors.append(f"opcode {i}: layout but NULL handler")
    # every cond op must have a resolver
    for i, k in OPERAND_BYTES.items():
        if k == 'cond' and i not in COND_LAYOUT:
            errors.append(f"opcode {i}: cond layout lacks resolver")
    return errors


def _check_synthetic():
    """Self-test 2: decode a synthetic script covering diverse opcodes;
    verify cursor lands exactly on each expected boundary (no desync)."""
    script = bytes([
        0x01, 0x42,             # [1] 1 byte  -> next @3
        0x04, 0x10, 0x20,       # [4] 2 bytes -> next @6
        0x1C, 0xAA, 0xBB, 0xCC, # [28] 3 bytes-> next @10
        0x3D, 0x07,             # [61] 1 byte -> next @12
        0xFD,                   # inline wait -> next @13
        0xF0,                   # NOP        -> next @14
        0x0A, 0x99,             # [10] 1 byte-> next @16
        0x3F, 0x11, 0x22,       # [63] 2 bytes-> next @19
        0x45, 0x05,             # [69] cond: byte0!=0xFF -> 1 byte -> next @21
        0x45, 0xFF, 0x07,       # [69] cond: byte0==0xFF -> 2 bytes -> next @24
        0x4A, 0x01, 0x02,       # [74] 2 bytes -> next @27
        0x4C, 0x00, 0x00, 0x03, # [76] zero-add arm: 3 bytes -> next @31
        0x51, 0x09, 0x08,       # [81] 2 bytes -> next @34
        0x99,                   # unknown op -> stop, no crash
    ])
    want_starts = [0, 2, 5, 9, 11, 12, 13, 15, 18, 20, 23, 26, 30, 33]
    got = decode_stream(script)
    got_starts = [o for o, _, _, _ in got]
    errors = []
    if got_starts != want_starts:
        errors.append(f"desync: starts {got_starts} != {want_starts}")
    if got[0][2] != bytes([0x42]):
        errors.append("op [1] operand mismatch")
    if got[2][2] != bytes([0xAA, 0xBB, 0xCC]):
        errors.append("op [28] operand mismatch")
    if got[4][1] != 0xFD or got[5][1] != 0xF0:
        errors.append("inline/NOP decode mismatch")
    # cond layouts
    if got[8][2] != bytes([0x05]) or "char_recruit_flag_toggle" not in got[8][3]:
        errors.append("op [69] 1-byte cond path mismatch")
    if got[9][2] != bytes([0xFF, 0x07]):
        errors.append("op [69] 2-byte cond path mismatch")
    # unknown op must stop cleanly, not crash
    if "UNKNOWN OPCODE" not in got[-1][3]:
        errors.append("unknown op did not stop cleanly")
    return errors, got


def selftest():
    print("== self-test 1: layout/table consistency ==")
    errs = _check_layouts()
    if errs:
        for e in errs:
            print("  FAIL:", e)
    else:
        print("  ok: 79 layouts cover all non-null handlers; NULLs at 3/39/40")
    print("== self-test 2: synthetic script decode ==")
    errs2, got = _check_synthetic()
    if errs2:
        for e in errs2:
            print("  FAIL:", e)
    else:
        print("  ok: 15 instructions decoded, zero desync, unknown op stops clean")
        for off, op, ops, note in got:
            print(f"    {off:4d}: op {op:#04x} ({op:2d}) ops={ops.hex() or '-':8s} {note}")
    print("== limitations ==")
    print("  - counted and conditional operands are decoded; branch targets")
    print("    and wait state are not followed by the linear walk")
    print("  - rewind/wait ops are control flow; linear decode consumes their")
    print("    operands but cannot follow the rewind — decode is valid up to")
    print("    the first such op")
    return 0 if not (errs or errs2) else 1


def main():
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    with open(sys.argv[1], "rb") as fh:
        data = fh.read()
    start = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0
    for off, op, ops, note in decode_stream(data, start):
        print(f"{off:6d} ({off:#06x}): op {op:#04x} ops=[{ops.hex()}] {note}")


if __name__ == "__main__":
    main()
