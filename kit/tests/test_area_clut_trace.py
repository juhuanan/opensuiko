#!/usr/bin/env python3
"""Tests for kit/tools/area_clut_trace.py -- the area CLUT channel trace.

Workstream V, 2026-10-04.  Static analysis only.

These assertions pin the *mechanical* findings so they cannot silently rot:

  1. ``section+0x14`` really is a ``w*h`` u16 tilemap (span coincidence with the
     room's own blob/palette tables), and it is NOT a pointer table -- so it
     cannot be the object-descriptor table the sprite emitter indexes.
  2. the primitive's CLUT attribute is ``0x1e0 + descriptor[+6] + vertex[+2]``:
     the instruction pair that forms it exists, at the documented addresses, and
     ``0x1e0`` is the row ``FUN_800c3c5c`` uploads palette 0 to.
  3. the section-pointer global ``[0x8017AAE4]`` is dereferenced for many fields
     but the *only* site that reads ``+0x14`` indexes it as a table of tables
     (the script/text-stream walker) -- the standing negative.
  4. for ``VB5_h0`` and ``VB4_h0`` the object-type descriptor tables resolve
     inside their own overlay, and VB5's does NOT carry palette base byte 2 --
     i.e. the blue water palette is not reached through VB5_h0's own descriptor
     table.  That is the honest limitation, pinned as a fact rather than prose.

Runs without the disc: it reads MAIN.EXE through ``maindec`` (disc-backed) and
the extracted overlay cache.  Both are prerequisites, as for every other area
probe in this tree.

Stdlib only.  Run directly or with pytest:

    .venv/bin/python kit/tests/test_area_clut_trace.py
    .venv/bin/python -m pytest kit/tests/test_area_clut_trace.py
"""
from __future__ import annotations

import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
TOOLS = os.path.join(ROOT, 'kit', 'tools')
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import area_clut_trace as act  # noqa: E402
from mipsdec import dec  # noqa: E402

AREA_DIR = os.path.join(ROOT, 'kit', 'extracted', 'bin_overlays', 'DATA', '02_AREA.B')


def _ov(name):
    path = os.path.join(AREA_DIR, name + '.BIN')
    if not os.path.exists(path):
        return None
    return act.Overlay(path)


# --------------------------------------------------------------------------
# 1. the tilemap field
# --------------------------------------------------------------------------

def test_vb5_h0_header_fields():
    ov = _ov('VB5')
    if ov is None:
        return
    rec = act.resolve_room(ov, 0)
    assert rec is not None
    f = rec['fields']
    assert (f['w'], f['h']) == (48, 30)
    assert f['palette_count'] == 6
    assert f['tilemap'] == 0x80013114
    assert f['palette_table'] == 0x80013d7c
    # the CLUT bank entry 0 names the base palette that build_area_cluts.py
    # finds independently by byte pattern
    assert ov.u32(f['palette_table']) == 0x80012514
    assert ov.u32(f['palette_table'] + 4 * 2) == 0x80012914   # entry 2: blue water


def test_tilemap_span_is_consistent_and_not_a_pointer_table():
    for name, slot, w, h in (('VB5', 0, 48, 30), ('VB4', 0, 40, 22)):
        ov = _ov(name)
        if ov is None:
            return
        rec = act.resolve_room(ov, slot)
        o = rec['tilemap_file']
        span = w * h * 2
        assert o > 0 and o + span <= len(ov)
        vals = struct.unpack_from('<%dH' % (w * h), ov.d, o)
        assert max(vals) < 1024                     # tile codes, not addresses
        assert len(set(vals)) > 20
        # If the field were a table of pointer tables, roughly every other u16
        # would be 0x8001.  None inside the w*h span is -- and the span is
        # bounded by the room's own blob/palette tables.
        assert 0x8001 not in set(vals)


def test_vb5_tilemap_contains_the_water_codes():
    ov = _ov('VB5')
    if ov is None:
        return
    rec = act.resolve_room(ov, 0)
    o = rec['tilemap_file']
    w, h = rec['fields']['w'], rec['fields']['h']
    vals = struct.unpack_from('<%dH' % (w * h), ov.d, o)
    water = [i for i, v in enumerate(vals) if v in (202, 203)]
    assert len(water) == 50
    assert all(v // 64 == 3 for v in (vals[i] for i in water))


# --------------------------------------------------------------------------
# 2. the emitter's CLUT field
# --------------------------------------------------------------------------

def _insns():
    import maindec
    b = maindec.body()
    base = maindec.MBASE
    out = {}
    for i in range(len(b) // 4):
        pc = base + i * 4
        w = struct.unpack_from('<I', b, i * 4)[0]
        s, f = dec(pc, w)
        f['s'] = s
        out[pc] = f
    return out


def test_emitter_forms_clut_from_descriptor_plus_vertex():
    ins = _insns()
    # t0 = pkt[+0x14] (the descriptor table)
    assert ins[0x800C3FD0]['s'] == 'lw $t0,0x14($s2)'
    # v1 = lbu t0[+6] (palette base byte)
    assert ins[0x800C3FD8]['s'] == 'lbu $v1,0x6($t0)'
    # v0 = lbu s1[+2] (per-vertex palette byte)
    assert ins[0x800C3FD4]['s'] == 'lbu $v0,0x2($s1)'
    # s4 = v1 + v0
    assert ins[0x800C406C]['s'] == 'addu $s4,$v0,$zero'
    # (s4 & 0xff) + 0x1e0 -> primitive +0x22
    assert ins[0x800C4110]['s'] == 'andi $v0,$s4,0xff'
    assert ins[0x800C4114]['s'] == 'addiu $v0,$v0,0x1e0'
    assert ins[0x800C4118]['s'] == 'sh $v0,0x22($sp)'


def test_clut_uploader_puts_palette_zero_at_row_0x1e0():
    ins = _insns()
    # FUN_800c3c5c: read the slot counter, add 0x1e0, hand it to LoadImage
    assert ins[0x800C3C74]['s'] == 'lbu $v0,-0x6fc8($v0)'
    assert ins[0x800C3C90]['s'] == 'addiu $v0,$v0,0x1e0'
    assert ins[0x800C3C94]['s'] == 'jal 0x80148590'
    # ... and the counter increments after each upload
    assert ins[0x800C3CB0]['s'] == 'sb $v0,-0x6fc8($at)'
    assert act.CLUT_ROW0 == 0x1E0


def test_obj_initializer_reaches_the_descriptor_from_the_packet():
    ins = _insns()
    # pkt[+0x14] -> [+0x14] -> table[type] -> descriptor
    assert ins[0x800C3DB4]['s'] == 'lw $v0,0x14($a0)'
    assert ins[0x800C3DBC]['s'] == 'lw $v0,0x14($v0)'
    assert ins[0x800C3DC0]['s'] == 'sll $a1,$a1,2'
    assert ins[0x800C3DC8]['s'] == 'lw $v0,0x0($v0)'


# --------------------------------------------------------------------------
# 3. the standing negative on section+0x14
# --------------------------------------------------------------------------

def test_section_global_is_read_for_every_field_but_0x14_is_not_a_tilemap():
    """Walk [0x8017AAE4] sites; assert the +0x14 read indexes a table of tables.

    This is the case that *falsifies* "section+0x14 has no static reader": it
    does have one, and it is a script/text-stream walker, so the tilemap
    negative is about *interpretation*, not about absence of readers.
    """
    ins = _insns()
    pcs = sorted(ins)
    sites = []
    for i, pc in enumerate(pcs):
        f = ins[pc]
        if f['op'] != 0x0F:
            continue
        hi = (f['uimm'] << 16) & 0xFFFFFFFF
        for j in range(i + 1, min(i + 5, len(pcs))):
            g = ins[pcs[j]]
            if g['op'] in (0x20, 0x21, 0x23, 0x24, 0x25) and g['rs'] == f['rt']:
                if (hi + g['imm']) & 0xFFFFFFFF == act.SECTION_GLOBAL:
                    sites.append(pcs[j])
                break
            if g['op'] == 0x0F:
                continue
            break
    assert len(sites) >= 15
    # the +0x14 reader: after `lw a2,0x14(a2)` it does `lw v1,0x0(v1)` on an
    # index into that field -- a table of tables, not a w*h u16 array.
    assert ins[0x8013B918]['s'] == 'lw $a2,0x14($a2)'
    assert ins[0x8013B928]['s'] == 'lw $v1,0x0($v1)'
    assert ins[0x8013B934]['s'] == 'lw $a0,0x0($v0)'
    # and the text cursor that drives it is a *byte* stream
    assert ins[0x8013B8F8]['s'] == 'lbu $a1,0x0($a0)'
    assert ins[0x8013B908]['s'] == 'lbu $v1,0x1($a0)'
    assert ins[0x8013B91C]['s'] == 'lbu $v0,0x2($a0)'


# --------------------------------------------------------------------------
# 4. the descriptor tables for the two complaint rooms
# --------------------------------------------------------------------------

def test_descriptor_chain_resolves_for_both_rooms():
    for name, w, h in (('VB5', 48, 30), ('VB4', 40, 22)):
        ov = _ov(name)
        if ov is None:
            return
        rec = act.resolve_room(ov, 0)
        assert rec['w'] == w and rec['h'] == h
        types = rec['descriptor_types']
        assert len(types) >= 3
        for e in types:
            assert e['desc_file'] is not None, (name, e['type'])


def test_vb4_uses_per_type_palette_bases_and_vb5_h0_does_not_carry_base_2():
    """The asymmetry that keeps the selector open.

    VB4_h0's descriptor table carries *different* base bytes per type
    (1, 3, 5, then 0) -- proof that the descriptor byte is a real per-type
    palette channel.  VB5_h0's chain carries none equal to 2, so the blue water
    palette is NOT reached through its own packet-context descriptor table.
    """
    ovb4, ovb5 = _ov('VB4'), _ov('VB5')
    if ovb4 is None or ovb5 is None:
        return
    vb4 = act.resolve_room(ovb4, 0)['descriptor_types']
    bases4 = [e['palette_base_byte'] for e in vb4 if e.get('palette_base_byte') is not None]
    assert bases4[:3] == [1, 3, 5]
    assert len(set(bases4)) > 1

    vb5 = act.resolve_room(ovb5, 0)['descriptor_types']
    bases5 = [e['palette_base_byte'] for e in vb5 if e.get('palette_base_byte') is not None]
    assert 2 not in bases5          # <-- the limitation, pinned


def test_room_walk_is_deterministic():
    ov = _ov('VB5')
    if ov is None:
        return
    a = act.resolve_room(ov, 0)
    b = act.resolve_room(ov, 0)
    assert a == b


if __name__ == "__main__":
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
        except Exception as ex:            # noqa: BLE001 - report all
            failed += 1
            print("FAIL %s: %s: %s" % (name, type(ex).__name__, ex))
        else:
            print("ok   %s" % name)
    print("\n%d passed, %d failed" % (len(tests) - failed, failed))
    sys.exit(1 if failed else 0)
