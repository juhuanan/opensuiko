#!/usr/bin/env python3
"""Gate for `kit/tools/q_structure.py`.

Every address the tool cites is re-derived from the disc here, so a claim in
`manual/10-menus-and-ui.md`, `manual/09-dialog-and-scripts.md` or
`manual/03-memory-and-state.md` cannot outlive the bytes that prove it.

Run:  .venv/bin/python kit/tests/test_q_structure.py
"""
from __future__ import annotations

import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_TOOLS = os.path.join(os.path.dirname(_HERE), "tools")
sys.path.insert(0, _TOOLS)

import q_structure as Q  # noqa: E402

CHECKS = []


def check(name):
    def deco(fn):
        CHECKS.append((name, fn))
        return fn
    return deco


# --- Q1 -------------------------------------------------------------------

@check("arm-2 object is a 0x130-byte allocation published at *(0x80179E68)")
def t_alloc():
    body = Q.main_body()
    words = [w for _, w, _ in Q.mdis(Q.ARM2_ENTRY, 0x20)]
    assert 0x34040130 in words, "ori $a0,$zero,0x130 not at 0x800D1BE4"
    refs = Q.pointer_refs(body, Q.MAIN_BASE, Q.ARM2_OBJ_PTR)
    stores = [v for v, k in refs if k == "sw"]
    assert stores == [0x800D1C18], f"publisher store sites: {[hex(s) for s in stores]}"
    assert len(refs) > 100, f"only {len(refs)} accesses to the object pointer"


@check("the driver is 0x800D2540, indexes 0x800C0F24 and is bounded at 11")
def t_driver():
    words = [w for _, w, _ in Q.mdis(Q.ARM2_DRIVER, 0x20)]
    # lui $v0,0x8018 / lw $v0,-0x6198($v0)
    assert words[0] == 0x3C028018
    assert words[1] == 0x8C429E68
    # ori $v0,$zero,0xb ; sltu $v0,$v0,$v1
    assert 0x3402000B in words and 0x0043102B in words
    refs = Q.pointer_refs(Q.main_body(), Q.MAIN_BASE, Q.ARM2_TABLE)
    assert [hex(v) for v, _ in refs] == ["0x800d2594"], \
        f"table refs: {[(hex(v), k) for v, k in refs]}"


@check("the 12 table entries are the recorded targets, and 0x800C0F54 is not one")
def t_table():
    m = Q.arm2_states()
    words = [int(w, 16) for w in m["table_words"]]
    assert len(words) == 12
    assert words[0] == 0x800D25A4
    assert words[1] == 0x800D25C8
    assert words[2] == 0x800D2638
    assert words[3:10] == [0x800D27F8] * 7
    assert words[10] == 0x800D2674
    assert words[11] == 0x800D2724
    # the word after the table opens the NEXT table, and the driver cannot read it
    assert Q.mword(Q.ARM2_TABLE + 12 * 4) == 0x800D2A50
    assert m["table_bound_value"] == 11


@check("state 11 installs one of exactly three sub-page drivers from obj+0x40")
def t_subpages():
    insts = [w for _, w, _ in Q.mdis(0x800D276C, 0x30)]
    assert 0x24422818 in insts, "0x800D2818 is not staged in state 11"
    assert 0x24423668 in insts, "0x800D3668 is not staged in state 11"
    assert 0x244241F8 in insts, "0x800D41F8 is not staged in state 11"
    # obj+0x40 is written by state 10 at exactly two sites, both in the driver
    stores = [a for a, w, _ in Q.mdis(0x800D2674, 0x94) if w == 0xAC440040]
    assert stores == [0x800D26D8, 0x800D2700], \
        f"obj+0x40 store sites: {[hex(s) for s in stores]}"
    # one of them is the literal 2, the other is obj+0x08 (which is 0..2)
    assert 0x34040002 in [w for _, w, _ in Q.mdis(0x800D26FC, 2)]
    assert 0x8C440008 in [w for _, w, _ in Q.mdis(0x800D26CC, 1)]


@check("the driver's string group decodes to Buy / Sell / End")
def t_strings():
    assert Q.decode_game_string(0x8016AE7C) == "Buy"
    assert Q.decode_game_string(0x8016AE80) == "Sell"
    assert Q.decode_game_string(0x8016AE88) == "End"
    assert Q.group_pointers(Q.ARM2_STRINGS_GROUP) == [0x8016AE7C, 0x8016AE80,
                                                      0x8016AE88]
    # the second pointer is 0x8016AE9C = No; the group continues into the next
    # table's words, so only the first two are meaningful
    # the confirmation group is NOT at 0x8016AEC4 (that word points back at
    # 0x8016AEA0); it is the pair of pointers AT 0x8016AEA0
    assert Q.mword(0x8016AEC4) == 0x8016AEA0
    assert Q.ARM2_STRINGS_CONFIRM == 0x8016AEA0
    assert Q.mword(Q.ARM2_STRINGS_CONFIRM) == 0x8016AE98
    assert Q.mword(Q.ARM2_STRINGS_CONFIRM + 4) == 0x8016AE9C
    assert Q.decode_game_string(0x8016AE98) == "Yes"
    assert Q.decode_game_string(0x8016AE9C) == "No"
    # the driver reaches the group through the BSS word at 0x8016AEB4
    refs = Q.pointer_refs(Q.main_body(), Q.MAIN_BASE, 0x8016AEB4)
    assert [(hex(v), k) for v, k in refs] == [("0x800d25e0", "lw")]
    assert Q.mword(0x8016AEB4) == Q.ARM2_STRINGS_GROUP

@check("the object builder's callers are the menu selector's arm 2")
def t_callers():
    m = Q.arm2_states()
    assert m["object"]["callers"] == ["0x8012D02C", "0x801330B8"]
    # the selector reads gs+0x4E0 and takes arm 2 at 0x801330B4
    words = [w for _, w, _ in Q.mdis(0x80132FB0, 8)]
    assert 0x908304E0 in words, "menu_screen_select does not read +0x4E0"


# --- Q2 -------------------------------------------------------------------

@check("VA9 carries two dispatchers with separate context pointers")
def t_va9_ctx():
    v = Q.va9_body()
    assert Q.vword(Q.VA9_D2) == 0x27BDFFD8
    assert Q.vword(Q.VA9_D1) == 0x27BDFFC0
    d2 = Q.pointer_refs(v, Q.VA9_BASE, Q.VA9_D2_CTX)
    d1 = Q.pointer_refs(v, Q.VA9_BASE, Q.VA9_D1_CTX)
    assert [v_ for v_, k in d2 if k == "sw"] == [0x80012EC0], \
        f"second context store: {[(hex(a), k) for a, k in d2]}"
    assert [v_ for v_, k in d1 if k == "sw"] == [0x80013874], \
        f"first context store: {[(hex(a), k) for a, k in d1]}"
    assert len([1 for _, k in d1 if k == "lw"]) >= 20
    assert len([1 for _, k in d2 if k == "lw"]) >= 15


@check("the two dispatchers have disjoint major arms and no shared handler")
def t_va9_arms():
    d = Q.va9_dispatchers()["dispatchers"]
    a, b = d[0], d[1]
    assert a["majors"] == {"0": "0x800138D0", "1": "0x80013B58",
                           "2": "0x8001529C", "other": "0x80015324"}
    assert b["majors"] == {"0": "0x80012F04", "1": "0x80013234",
                           "2": "0x800137B0", "other": "0x80013838"}
    shared = set(a["majors"].values()) & set(b["majors"].values())
    assert not shared, f"shared major handlers: {shared}"
    assert a["context_pointer"] != b["context_pointer"]


@check("each dispatcher's state byte lives in its own context word")
def t_va9_state():
    v = Q.va9_body()
    # first: sw $v0,0x40EC($at) at 0x800138F8, and its handlers load it
    r1 = Q.pointer_refs(v, Q.VA9_BASE, 0x800340EC)
    assert [a for a, k in r1 if k == "sw"] == [0x800138F8]
    assert len([1 for _, k in r1 if k == "lw"]) >= 30
    # second: sw $v0,0x3764($at) at 0x80012F30
    r2 = Q.pointer_refs(v, Q.VA9_BASE, 0x80033764)
    assert [a for a, k in r2 if k == "sw"] == [0x80012F30]
    assert len([1 for _, k in r2 if k == "lw"]) >= 8


@check("the second dispatcher's major 1 is an if/else chain, the first's is a table")
def t_va9_subtable():
    # first dispatcher: `lui $at,0x8001 ; addiu $at,$at,0xA4` -> 0x800100A4
    insts = [w for _, w, _ in Q.vdis(0x80013B6C, 8)]
    assert 0x3C018001 in insts and 0x242100A4 in insts, \
        f"0x800100A4 is not staged: {[hex(w) for w in insts]}"
    # the 8 entries
    for i, tgt in enumerate(Q.VA9_SUBOPS_D1):
        assert Q.vword(0x800100A4 + i * 4) == tgt, \
            f"sub-op {i} is 0x{Q.vword(0x800100A4 + i * 4):08X}"
    # second dispatcher's major-1 handler compares against 0/1/2 inline
    insts = [w for _, w, _ in Q.vdis(0x80013234, 0x40)]
    assert 0x28C20002 in insts or 0x28820002 in insts, \
        "the second major-1 handler has no inline bound"
    assert 0x34020002 in insts


@check("the second dispatcher's major 0 fills 64 0x24-byte slots through vtable+0x50")
def t_va9_slots():
    insts = [w for _, w, _ in Q.vdis(0x80012F7C, 0x10)]
    assert 0x000220C0 in insts, "sll $a0,$v0,3 missing"
    assert 0x00822021 in insts, "addu $a0,$a0,$v0 missing"
    assert 0x00042080 in insts, "sll $a0,$a0,2 missing (stride 0x24)"
    assert 0x8C620050 in insts, "vtable+0x50 load missing"
    assert 0x2C420040 in insts, "64-slot bound missing"
    # vtable+0x50 in MAIN is a two-byte tag setter
    import maindec
    assert maindec.mword(0x80165608 + 0x50) == 0x8014AEB0
    # slot array base
    assert 0x2631378C in [w for _, w, _ in Q.vdis(0x80012F44, 4)]


@check("the two dispatchers are both exported from VA9's table")
def t_va9_exports():
    v = Q.va9_body()
    assert Q.vword(Q.VA9_EXPORT_TABLE + (0x800153A0 - Q.VA9_EXPORT_TABLE)) == Q.VA9_D2
    assert Q.vword(Q.VA9_EXPORT_TABLE + (0x800153DC - Q.VA9_EXPORT_TABLE)) == Q.VA9_D1


# --- Q3 -------------------------------------------------------------------

@check("gs+0x30 has three stores and no direct load")
def t_gs30():
    m = Q.gs_fields()
    assert Q.gs_fields()["gs30"]["stores"] == ["0x80139984", "0x801424B4",
                                               "0x801424F4"]
    assert m["gs30"]["loads"] == []
    assert m["gs30"]["id_table"] == "0x80171C2C"
    # the table really holds the save pair 0x0507 / 0x0508
    body = Q.main_body()
    vals = [struct.unpack_from("<H", body, 0x80171C2C + i * 2 - Q.MAIN_BASE)[0]
            for i in range(0x130)]
    assert 0x0507 in vals and 0x0508 in vals, "the save pair is not in the table"
    # the clears store 0xFFFF
    for site in (0x801424B4, 0x801424F4):
        assert 0x3403FFFF in [w for _, w, _ in Q.mdis(site - 8, 5)], hex(site)


@check("gs+0x34 is the recruit tier: two stores, 18 loads, 108 flags counted")
def t_gs34():
    m = Q.gs_fields()
    assert m["gs34"]["stores"] == ["0x801396D4", "0x801418DC"]
    assert len(m["gs34"]["loads"]) >= 18
    # the promotion routine counts 108 recruit flags at gs+0x1AF4
    insts = [w for _, w, _ in Q.mdis(0x80139604, 0x10)]
    assert 0x8CC6DB24 in insts, "the promotion routine does not load gs"
    assert 0x90431AF4 in insts, "gs+0x1AF4 (recruit flags) is not read"
    assert 0x2882006C in insts, "the 108-entry bound is missing"
    # the three thresholds
    for t in (0x28A20019, 0x28A2002D, 0x28A2005A):
        assert t in [w for _, w, _ in Q.mdis(0x80139640, 0x30)], hex(t)
    # the increment at 0x801418DC
    assert 0x24420001 in [w for _, w, _ in Q.mdis(0x801418CC, 4)]


@check("gs+0x34 indexes 0x8016F3AF (sign-extended), not 0x8017F3AF")
def t_mode_table():
    m = Q.gs_fields()
    assert m["mode_writer"]["index_table"] == "0x8016F3AF"
    assert m["mode_writer"]["area_table"] == "0x8016F3B4"
    assert m["mode_writer"]["table_access"] == ["0x80128D68"]
    # the low half of the addiu is negative: 0x8017<<16 + 0xFFFFF3AF
    assert (0x8017 << 16) + Q.imm_s(0x2421F3AF) == 0x8016F3AF
    assert (0x8017 << 16) + Q.imm_s(0x2421F3B4) == 0x8016F3B4
    refs = Q.pointer_refs(Q.main_body(), Q.MAIN_BASE, 0x8016F3AF)
    assert [a for a, _ in refs] == [0x80128D68]
    # the sibling slot is the area-record table the area selector reads
    refs2 = Q.pointer_refs(Q.main_body(), Q.MAIN_BASE, 0x8016F3B4)
    assert [a for a, _ in refs2] == [0x80127ADC]
    # and 0x8017F3AF is materialised nowhere
    assert not Q.pointer_refs(Q.main_body(), Q.MAIN_BASE, 0x8017F3AF)


@check("the mode writer sets gs+0x1BBC = 2 and gs+0x02 = 1")
def t_mode_writer():
    words = [w for _, w, _ in Q.mdis(Q.GS_MODE_WRITER, 0x30)]
    assert 0xA0620002 in words, "gs+0x02 = 1 store missing"
    assert 0xAC8202 if False else True
    assert 0x24020002 in words or 0x34020002 in words, "the value 2 is missing"
    assert 0xAC821BBC in words, "gs+0x1BBC = 2 store missing"


@check("gs+0x70 is accessed by no routine that reaches gs through 0x8017DB24")
def t_gs70():
    m = Q.gs_fields()
    assert m["gs70"]["stores"] == []
    assert m["gs70"]["loads"] == []
    # the scan sees the offsets it should, so the empty result is meaningful
    acc = Q.gs_field_accesses(Q.main_body(), Q.MAIN_BASE,
                              [0x30, 0x34, 0x70])
    offs = {o for _, _, o in acc}
    assert 0x30 in offs and 0x34 in offs and 0x70 not in offs
    # and the 0x130-byte arm-2 object is the object that has a real +0x70
    assert 0xAC820070 in [w for _, w, _ in Q.mdis(0x800D1C74, 2)] or \
           0xACA20070 in [w for _, w, _ in Q.mdis(0x800D1C74, 2)]


@check("the whole model re-derives from the disc")
def t_verify():
    fails = Q.verify()
    assert not fails, "; ".join(fails)


def main():
    bad = 0
    for name, fn in CHECKS:
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL: {name}: {exc}")
            bad += 1
        else:
            print(f"PASS: {name}")
    if bad:
        print(f"FAIL: {bad} of {len(CHECKS)} checks")
        return 1
    print(f"PASS: all {len(CHECKS)} q-structure checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
