#!/usr/bin/env python3
"""
build_script_corpus.py — Decode every area-overlay event-script cluster into a
readable corpus, resolving dialogue against the canonical string table.

Canonical strings: kit/work/decoded_text/dialogue_found.txt (10173 entries,
[table,index] @address per overlay; 4044 original + 6129 from string-recovery
pass 2, 2026-10-02). This script NEVER re-decodes strings;
a 0x1C operand pointing at a [table,index] missing from dialogue_found.txt
is flagged as a GAP.

Script clusters: kit/docs/s1_command_table_via_s2.md §3
(overlay -> densest-4KB-region offset of opcode-0x1C triples).

Decoder: kit/tools/event_script_decode.py (extended 2026-10-02: 82-entry
table, 0x40-0x51 layouts, conditional layouts, unknown-op guard).

Output: kit/work/scripts_decoded/<OVERLAY>.txt + INDEX.md
"""

import os
import re
import sys

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)

sys.path.insert(0, os.path.join(_TOOLS))
from event_script_decode import (

    decode_stream, OPERAND_BYTES, HANDLER_NAMES,
    PROVISIONAL_OPS, REWIND_OPS, JUMP_OP,
)
from area_entity_probe import room_records, ENTITY_SIZE

KIT = _KIT
OUTDIR = os.path.join(KIT, "work", "scripts_decoded")

# overlay -> script-cluster offset (densest 4KB region of 0x1C triples)
CLUSTERS = {
    "VA1.BIN": 0x3C000, "VA2.BIN": 0x26000, "VA3.BIN": 0x2A000,
    "VA4.BIN": 0x36000, "VA6.BIN": 0xF000, "VA7.BIN": 0x25000,
    "VA8.BIN": 0x22000, "VA9.BIN": 0x15000, "VAA.BIN": 0x50000,
    "VAAD.BIN": 0x8000, "VB1.BIN": 0x20000, "VB2.BIN": 0x2C000,
    "VB3.BIN": 0x41000, "VB4.BIN": 0x1A000, "VB5A2.BIN": 0x3F000,
    "VB5B4.BIN": 0x29000, "VAC.BIN": 0x41000, "VAD.BIN": 0x4C000,
    "VH1.BIN": 0x49000, "VS2.BIN": 0x47000, "VB5B3.BIN": 0x2E000,
    "VB5C4.BIN": 0x3C000, "VB6.BIN": 0x35000, "VB7D.BIN": 0xC000,
    "VC4.BIN": 0x27000, "VC6.BIN": 0x3D000, "VD1.BIN": 0x4A000,
    "VD2.BIN": 0x45000, "VD3.BIN": 0x44000, "VD6.BIN": 0x47000,
    "VE1.BIN": 0x38000, "VE2.BIN": 0x46000, "VE6.BIN": 0x42000,
    "VF1.BIN": 0x48000, "VF3.BIN": 0x48000, "VF4.BIN": 0x38000,
    "VG1.BIN": 0x29000, "VG3.BIN": 0x15000, "VI1.BIN": 0x39000,
}

WINDOW = 0x1000  # decode this many bytes from the cluster offset


def load_dialogue():
    """Parse dialogue_found.txt -> {(overlay, table, idx): (addr, text)}."""
    table = {}
    cur = None
    cur_key = None
    buf = []
    pat = re.compile(r"^--- (\S+) \(")
    ent = re.compile(r"^\[(\d+),(\d+)\] @(0x[0-9a-fA-F]+): ?(.*)$")

    def flush():
        if cur_key and buf:
            # first line already captured; join continuation lines
            table[cur_key] = (cur_addr, "\n".join(buf).rstrip())

    with open(os.path.join(KIT, "work/decoded_text/dialogue_found.txt"),
              encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            m = pat.match(line)
            if m:
                flush(); cur = m.group(1); cur_key = None; buf = []
                continue
            m = ent.match(line)
            if m:
                flush()
                t, i, addr, first = int(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
                cur_key = (cur, t, i); cur_addr = addr; buf = [first]
            elif cur_key is not None:
                buf.append(line)
    flush()
    return table


def find_overlay(name):
    for root, _ds, fs in os.walk(os.path.join(KIT, "extracted")):
        if name in fs:
            return os.path.join(root, name)
    return None


def _clean_ahead(data, pc, end, valid_keys, n=3):
    """True if n consecutive instructions decode cleanly inside [pc, end).

    CORRECTION 2026-10-04 (workstream B): an anchor was previously accepted as
    soon as an instruction *started* before `end`; its operands were never
    checked against the window.  That let truncated tail instructions count as
    "clean" (e.g. `_clean_ahead(b'\\x02\\x02\\x04', 0, 3, set())` returned True
    although opcode 0x04 needs two more bytes).  Every instruction's operand
    extent must now END inside the window; the last accepted instruction is
    always fully contained.

    Resync candidates use the same counted/conditional decoder as the walk.
    These windows are heuristic regions, not established script entry points.
    """
    p = pc
    for _ in range(n):
        rows = decode_stream(data[p:end], max_insns=1)
        if not rows or any(mark in rows[0][3] for mark in
                           ('UNKNOWN', 'TRUNCATED', 'truncated', 'NULL', 'VARIABLE', 'CALLBACK')):
            return False
        p += 1 + len(rows[0][2])
    return True


def _selftest_extent_bounds():
    """Assertions for the two counterexamples from the 2026-10-04 audit."""
    # fixed-length branch: opcode 0x04 needs 2 operand bytes beyond `end`
    assert _clean_ahead(b'\x02\x02\x04', 0, 3, set()) is False, \
        "truncated fixed-length instruction accepted as clean"
    # variable-wait branch (0x03 fmt 0xFC = 5 operand bytes)
    assert _clean_ahead(b'\x02\x02\x03\xfc', 0, 4, set()) is False, \
        "truncated variable-wait instruction accepted as clean"
    assert _clean_ahead(b'\x02\x02\x03\xfc\x00\x00\x00\x00', 0, 7, set()) is False
    # fully contained instances still pass
    assert _clean_ahead(b'\x02\x02\x04\x00\x00', 0, 5, set()) is True
    assert _clean_ahead(b'\x02\x02\x03\xfc\x00\x00\x00\x00', 0, 8, set()) is True
    return True


def data_ranges(data, overlay, dtable):
    """Typed source context, not proof that no branch can ever execute the bytes."""
    ranges = []
    # shortcut: reuse the bounded room probe; prove room-count bounds before claiming exhaustive coverage.
    for room in room_records(data):
        start = room['ent_off']
        if start is not None and 0 <= start < start + ENTITY_SIZE * room['count'] <= len(data):
            ranges.append((start, start + ENTITY_SIZE * room['count'],
                           f"room {room['index']} entity records @{start:#x}"))
    for (ov, table, index), (addr, _) in dtable.items():
        if ov != overlay:
            continue
        start = int(addr, 16)
        if not 0 <= start < len(data):
            raise ValueError(f'{overlay}: text address outside source: {addr}')
        end = data.find(b'\x00', start)
        if end < 0:
            raise ValueError(f'{overlay}: unterminated text body at {addr}')
        ranges.append((start, end + 1, f'text [{table},{index}] body @{start:#x}'))
    return ranges


def decode_window(data, start, window, overlay, dtable):
    """Decode [start, start+window). Resync-scan past var/unknown ops.

    Returns (lines, stats). lines are pre-formatted strings.
    """
    lines = []
    stats = {"insns": 0, "dialogue": 0, "gaps": 0, "gaps_real": 0,
             "gaps_phantom": 0, "gaps_data": 0, "resyncs": 0, "unknown": 0, "speakers": {}}
    contexts = data_ranges(data, overlay, dtable)
    valid_keys = {(t, i) for (ov, t, i) in dtable if ov == overlay}
    end = min(len(data), start + window)
    pc = start
    n = 0
    while start <= pc < end and n < 10000:
        n += 1
        op = data[pc]
        # fast path: known opcode -> single-step via decode_stream on slice
        chunk = decode_stream(data[pc:end], 0, max_insns=1)
        if not chunk:
            break
        off, cop, ops, note = chunk[0]
        if 'TRUNCATED' in note or 'truncated' in note:
            lines.append(f'  ... [stop: truncated instruction at {pc:#x}]')
            stats['unknown'] += 1
            break
        if "UNKNOWN OPCODE" in note or "VARIABLE-LENGTH" in note:
            # resync: scan forward for next plausible opcode start.
            # A resync anchor must decode 3 consecutive instructions cleanly;
            # 0x1C anchors additionally require sane speaker + in-bounds
            # operands (high-confidence alignment).
            stats["resyncs"] += 1
            skipped_from = pc
            pc += 1
            while pc < end:
                o2 = data[pc]
                ok = False
                if o2 in (0x03, 0xFD, 0xF0) or 0xF8 <= o2 <= 0xFC or o2 >= 0xFE:
                    ok = True
                elif o2 in OPERAND_BYTES and o2 not in (3, 39, 40):
                    if o2 == 0x1C:
                        if (pc + 3 < end and data[pc + 1] in (0, 1)
                                and (data[pc + 2], data[pc + 3]) in valid_keys):
                            ok = True
                    else:
                        ok = True
                if ok and _clean_ahead(data, pc, end, valid_keys):
                    break
                pc += 1
            lines.append(f"  ... [resync: skipped {skipped_from:#x}-{pc:#x} "
                         f"({note.split(':')[0].strip()})]")
            stats["unknown"] += 1
            continue
        abs_off = pc
        ops_hex = ops.hex() if ops else "-"
        name = HANDLER_NAMES.get(cop, f"handler_{cop}")
        extra = ""
        if cop == 0x1C and len(ops) == 3:
            dsp, tbl, idx = ops[0], ops[1], ops[2]
            stats["speakers"][dsp] = stats["speakers"].get(dsp, 0) + 1
            key = (overlay, tbl, idx)
            if key in dtable:
                addr, text = dtable[key]
                stats["dialogue"] += 1
                first = text.split("\n")[0].rstrip()
                rest = [line.rstrip() for line in text.split("\n")[1:]]
                extra = (f"\n      speaker={dsp} [{tbl},{idx}] @{addr}: {first}")
                for rl in rest:
                    extra += f"\n        {rl}" if rl else "\n"
            else:
                context = next((label for lo, hi, label in contexts if lo <= pc < hi), None)
                if context:
                    stats['gaps_data'] += 1
                    extra = (f"\n      speaker={dsp} [{tbl},{idx}]: "
                             f"*** DATA CONTEXT — {context}; apparent opcode is "
                             f"inside typed data, not evidence of missing text ***")
                else:
                    stats["gaps"] += 1
                    # Speaker 0/1 is only a plausibility heuristic, not reachability proof.
                    if dsp in (0, 1):
                        stats["gaps_real"] += 1
                        extra = (f"\n      speaker={dsp} [{tbl},{idx}]: "
                                 f"*** GAP — not in dialogue_found.txt "
                                 f"(plausible real dialogue) ***")
                    else:
                        stats["gaps_phantom"] += 1
                        extra = (f"\n      speaker={dsp} [{tbl},{idx}]: "
                                 f"*** GAP — likely phantom (implausible speaker "
                                 f"byte; probable misalignment) ***")
        tag = ""
        if cop in PROVISIONAL_OPS:
            tag = " [semantics provisional]"
        if cop in REWIND_OPS:
            tag += " [may rewind]"
        if cop == JUMP_OP:
            tag += " [jump]"
        lines.append(f"  {abs_off:#8x}: op {cop:#04x} ({cop:3d}) "
                     f"ops={ops_hex:8s} {name}{tag}{extra}")
        stats["insns"] += 1
        pc += 1 + len(ops)
    return lines, stats


def main():
    _selftest_extent_bounds()
    os.makedirs(OUTDIR, exist_ok=True)
    dtable = load_dialogue()
    print(f"canonical strings: {len(dtable)}")
    index = []
    totals = {"insns": 0, "dialogue": 0, "gaps": 0, "overlays": 0, "gaps_data": 0}
    for ov, cl in sorted(CLUSTERS.items()):
        path = find_overlay(ov)
        if not path:
            print(f"  !! {ov}: file not found")
            index.append((ov, cl, "FILE NOT FOUND", 0, 0, 0))
            continue
        with open(path, "rb") as f:
            data = f.read()
        lines, st = decode_window(data, cl, WINDOW, ov, dtable)
        out_path = os.path.join(OUTDIR, ov.replace(".BIN", ".txt"))
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(f"# Event script — {ov}\n")
            f.write(f"# source: {os.path.relpath(path, _ROOT)}\n")
            f.write(f"# window: file+{cl:#x} .. +{cl + WINDOW:#x} "
                    f"(densest 0x1C-triple 4KB region per "
                    f"s1_command_table_via_s2.md §3)\n")
            f.write(f"# decoder: kit/tools/event_script_decode.py "
                    f"(82-entry table, cond layouts, unknown-op guard)\n")
            f.write(f"# dialogue: resolved against "
                    f"kit/work/decoded_text/dialogue_found.txt (canonical; "
                    f"never re-decoded here)\n")
            f.write(f"# stats: {st['insns']} insns, {st['dialogue']} dialogue "
                    f"lines, {st['gaps']} gaps ({st['gaps_real']} plausible / "
                    f"{st['gaps_phantom']} likely phantom), "
                    f"{st['gaps_data']} typed-data matches, "
                    f"{st['resyncs']} resyncs, "
                    f"speakers={dict(sorted(st['speakers'].items()))}\n")
            f.write(f"# note: linear decode; rewind/jump ops are control flow\n")
            f.write(f"#   — execution order may differ past the first one.\n\n")
            f.write("\n".join(line.rstrip() for line in "\n".join(lines).split("\n")) + "\n")
        totals["insns"] += st["insns"]; totals["dialogue"] += st["dialogue"]
        totals["gaps"] += st["gaps"]; totals["overlays"] += 1
        totals["gaps_data"] += st["gaps_data"]
        index.append((ov, cl, os.path.basename(out_path),
                      st["insns"], st["dialogue"], st["gaps"]))
        print(f"  {ov}: {st['insns']} insns, {st['dialogue']} dialogue, "
              f"{st['gaps']} gaps, {st['resyncs']} resyncs")
    with open(os.path.join(OUTDIR, "INDEX.md"), "w", encoding="utf-8") as f:
        f.write("# Decoded event-script corpus\n\n")
        f.write("Per-overlay event-script decodes from the §3 script clusters "
                "(window: cluster offset +0x1000 bytes). Dialogue resolved "
                "against the canonical `dialogue_found.txt`; gaps flagged, "
                "never silently re-decoded. These are heuristic linear windows; "
                "resynchronisation is not proof of instruction alignment.\n\n")
        f.write(f"Totals: {totals['overlays']} overlays, {totals['insns']} "
                f"instructions, {totals['dialogue']} dialogue lines, "
                f"{totals['gaps']} string-table gaps.\n\n"
                f"{totals['gaps_data']} typed-data apparent references.\n\n")
        f.write("| overlay | cluster | file | insns | dialogue | gaps |\n")
        f.write("|---|---|---|---|---|---|\n")
        for ov, cl, fn, ni, nd, ng in index:
            f.write(f"| {ov} | {cl:#x} | {fn} | {ni} | {nd} | {ng} |\n")
    print("TOTALS:", totals)


if __name__ == "__main__":
    main()
