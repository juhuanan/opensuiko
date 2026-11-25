#!/usr/bin/env python3
"""Static map of MAIN.EXE's game-state dispatcher and callback installs.

Run with --modes for the top-level routes, --json [PATH] for the model, or
--verify to re-read its word anchors and census direct callback stores.
"""
from __future__ import annotations

import argparse
import bisect
import csv
import json
import os
import re
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)

import disc  # noqa: E402
import mipsdec  # noqa: E402
from mips_writers import resolve_reg, writer_of  # noqa: E402

MAIN_BASE = 0x800C0800
MAIN_LBA = 17976
MAIN_SIZE = 757760
MAIN_HEADER = 2048
MODE_WORD = 0x801B9BBC
MODE_TABLE = 0x8017DA94
ROOT_SLOT = 0x8017DA90

# The mode word is read after the active mode-handler returns anything except -1.
# Mode 0 requests the outer dispatcher teardown; 1..5 and 99 select handlers.
ROUTES = [
    {"mode": -1, "handler": None, "install": None,
     "guard": "callback return != -1; game_state+0x1BBC == -1",
     "action": "print game over and set outer dispatcher state to 99"},
    {"mode": 0, "handler": None, "install": None,
     "guard": "callback return != -1; game_state+0x1BBC == 0",
     "action": "set outer dispatcher state 0x80179E00 to 99"},
    {"mode": 1, "handler": 0x801279E8, "install": 0x800C9AA8,
     "guard": "callback return != -1; game_state+0x1BBC == 1",
     "action": "install handler in game-state callback slot 0"},
    {"mode": 2, "handler": 0x80130EC4, "install": 0x800C9AB8,
     "guard": "callback return != -1; game_state+0x1BBC == 2",
     "action": "install handler in game-state callback slot 0"},
    {"mode": 3, "handler": 0x800DDF98, "install": 0x800C9AD0,
     "guard": "callback return != -1; game_state+0x1BBC == 3",
     "action": "install standard battle handler in game-state callback slot 0"},
    {"mode": [4, 5], "handler": 0x80125DC0, "install": 0x800C9AF0,
     "guard": "callback return != -1; 4 <= game_state+0x1BBC < 6",
     "action": "install special-content loader in game-state callback slot 0"},
    {"mode": 99, "handler": 0x80125DC0, "install": 0x800C9AF0,
     "guard": "callback return != -1; game_state+0x1BBC == 99",
     "action": "install special-content/teardown handler in game-state callback slot 0"},
]

ROUTE_INSTALLS = {0x800C9AA8, 0x800C9AB8, 0x800C9AD0, 0x800C9AF0}
ROOT_LIFECYCLE_INSTALLS = {0x800C96D0, 0x800C98D4, 0x800C9B58}
BOOTSTRAP_INSTALL = 0x800C2BBC
MODE_SWITCH_TABLE = 0x800C18C4
MODE_SWITCH_WORDS = [0x80131FF8, 0x80131FF8, 0x80132008,
                     0x80132008, 0x80131FF8, 0x80131FF8,
                     0x80132008, 0x80132008, 0x80131FF8]

# These are the direct MAIN writers, with the local branch condition at each
# transition. Values copied from gs+0x1BB8 remain symbolic until that field's
# producer is known at the call site.
MODE_STORE_CONTEXTS = [
    {"site": 0x800C95FC, "value": 0,
     "guard": "MAIN initialization in gpu_heap_init"},
    {"site": 0x800DE4A4, "value": "gs+0x1BB8",
     "guard": "$s4 != 1 at 0x800DE480; also sets gs+0x1BB8 = 3"},
    {"site": 0x800DE4C0, "value": 99,
     "guard": "$s4 == 1 at 0x800DE480"},
    {"site": 0x800DE538, "value": 99,
     "guard": "byte gs+0x1D5E == 0 at 0x800DE500"},
    {"site": 0x80125FE8, "value": 99,
     "guard": "byte 0x8017C0F8 != 0 at 0x80125FD4"},
    {"site": 0x80126020, "value": -1,
     "guard": "byte 0x8017C0F8 == 0 and word 0x8017A0A0 == 1"},
    {"site": 0x80126038, "value": "gs+0x1BB8",
     "guard": "byte 0x8017C0F8 == 0 and word 0x8017A0A0 != 1; copies the old gs+0x1BB8 before setting it to 2"},
    {"site": 0x80128578, "value": 2,
     "guard": "callback 0x80128528 is installed at 0x80128168 when 0x8017A0C0==1 (set by h2da_state_init_driver), or at 0x801284F4 after descriptor-coordinate matches and a nonzero indexed callback return"},
    {"site": 0x801285FC, "value": 3,
     "guard": "body 0x801285AC is reached through installed wrapper 0x801285A4 when ctx+0x38<0, field_state_gate_driver returns nonzero, and (0x8017BDCC&0x200)==0"},
    {"site": 0x80128DA4, "value": 2,
     "guard": "type-13 object handler 0x800D1384 calls it at 0x800D13CC only when gs+0x2E==1; it is selected through 0x80167928[13]"},
    {"site": 0x80131F18, "value": 3,
     "guard": "(context+0x48C == 0 or context+0x35 != 0), where context = *(0x8017BE20); then context+0x37 bit 0 is set (possibly after 0x801424C8); and *(0x8017AAE4)+0x38 != 0"},
    {"site": 0x80132030, "value": "1, 2, 3, 4 or 5",
     "guard": "after the common context gate and bit-0 encounter path: context+0x37 bits 0x02/0x04/0x08/0x10 request modes 2/3/4/5 in priority order; with all clear, context+0x35 bit 0 selects mode 1 if set, otherwise mode 2"},
]

# Raw words, read from the headerless MAIN.EXE body. These cover the outer
# return gate, mode compares/routes, loader distinctions, entry guards and
# writes. The final table word is data, not an instruction. The separate test
# re-reads each word independently.
ANCHOR_WORDS = {
    0x800C2870: 0x0040F809, 0x800C2874: 0x00002021,
    0x800C99E4: 0x8E020000, 0x800C99EC: 0x0040F809,
    0x800C99F0: 0x26240001, 0x800C99F8: 0x10520058,
    0x800C9A34: 0x8C431BBC, 0x800C9A3C: 0x1062001B,
    0x800C9A40: 0x28620003, 0x800C9A44: 0x10400009,
    0x800C9A4C: 0x1060002F, 0x800C9A54: 0x1C600011,
    0x800C9A5C: 0x10720027, 0x800C9A6C: 0x28620006,
    0x800C9A70: 0x10400005, 0x800C9A74: 0x28620004,
    0x800C9A78: 0x10400018, 0x800C9A88: 0x34020063,
    0x800C9A8C: 0x10620013,
    0x800C9A9C: 0x3C028012, 0x800C9AA0: 0x244279E8,
    0x800C9AA8: 0xAE020000,
    0x800C9AAC: 0x3C028013, 0x800C9AB0: 0x24420EC4,
    0x800C9AB8: 0xAE020000,
    0x800C9ABC: 0x3C02800E, 0x800C9AC0: 0x2442DF98,
    0x800C9AD0: 0xAC220000,
    0x800C9ADC: 0x3C028012, 0x800C9AE0: 0x24425DC0,
    0x800C9AF0: 0xAC220000,
    0x800C9AFC: 0x3C04800C, 0x800C9B00: 0x24840DB4,
    0x800C9B04: 0x0C051F5E,
    0x800C9B0C: 0x34020063, 0x800C9B14: 0xAC229E00,
    0x800C9B4C: 0x3C018018, 0x800C9B50: 0x2421DA90,
    0x800C9B54: 0x00230821, 0x800C9B58: 0xAC220000,
    0x800DDF98: 0x27BDFFE8, 0x801279E8: 0x27BDFFD8,
    0x80130EC4: 0x3C028018, 0x80125DC0: 0x3C028018,
    0x80127A78: 0x90440002, 0x80127AD0: 0x3C018017,
    0x80127AD4: 0x2421F3B4, 0x80127ADC: 0x8C240000,
    0x80127AE0: 0x0C030BBE, 0x80127AE4: 0x3C058008,
    0x800CBBE8: 0x9062001F, 0x800CBBF8: 0x24217928,
    0x800CBC20: 0xACC322B8,
    0x800CC0D0: 0x9042001F, 0x800CC0E0: 0x24217928,
    0x800CC100: 0xAC8322B8, 0x800CC1E4: 0x0060F809,
    0x800CEF18: 0x0040F809,
    0x800D13BC: 0x9083002E, 0x800D13C4: 0x1462000B,
    0x800D13CC: 0x0C04A34E,
    0x80130F48: 0x90430002, 0x80130F50: 0x00031880,
    0x80130F54: 0x3C018017, 0x80130F58: 0x2421F67C,
    0x80130F60: 0x8C230000, 0x80130F6C: 0x8C440000,
    0x80130F70: 0x0C030BBE, 0x80130F74: 0x3C058001,
    0x80125E5C: 0x8C631BC0, 0x80125E64: 0x00031880,
    0x80125E68: 0x3C018017, 0x80125E6C: 0x2421F258,
    0x80125E74: 0x8C240000, 0x80125E80: 0x0C030BBE,
    0x80125E84: 0x3C058001,
    0x800C9D10: 0x3C048016, 0x800C9D14: 0x24843D64,
    0x800C9D18: 0x3C05800A, 0x800C9D1C: 0x0C030BBE,
    0x800C9D20: 0x34A5A000,
    0x80141E08: 0x27BDFFE8, 0x80141F30: 0x0040F809,
    0x80128578: 0xAC831BBC, 0x801285FC: 0xAC621BBC,
    0x80128144: 0x8C63A0C0, 0x80128148: 0x34020001,
    0x8012814C: 0x14620009, 0x80128168: 0xAC220000,
    0x80128198: 0x3C158017, 0x8012819C: 0x26B5F37C,
    0x801281B0: 0x96020002, 0x801281B4: 0x96050004,
    0x801281D4: 0x10430003, 0x801281D8: 0x24420001,
    0x801281DC: 0x14430012, 0x801281E8: 0x9463F29A,
    0x801281F0: 0x10430003, 0x801281F4: 0x24420001,
    0x801281F8: 0x1443000B,
    0x80128200: 0x92020000, 0x80128208: 0x00021080,
    0x8012820C: 0x00551021, 0x80128210: 0x8C420000,
    0x80128218: 0x0040F809, 0x80128220: 0x144000A6,
    0x80128414: 0x8C420038, 0x8012841C: 0x04410011,
    0x80128424: 0x0C04982E,
    0x8012842C: 0x1040000D, 0x80128438: 0x8C42BDCC,
    0x80128440: 0x30420200, 0x80128444: 0x14400007,
    0x80128460: 0xAC220000, 0x801284F4: 0xAC230000,
    0x801285A4: 0x3C028018, 0x801285A8: 0x8C42A0B8,
    0x800DE480: 0x12820009, 0x800DE4A4: 0xAC651BBC,
    0x800DE498: 0x34040003, 0x800DE49C: 0xAC641BB8,
    0x800DE4B0: 0x3404000A, 0x800DE4B4: 0xAC641BC0,
    0x800DE4B8: 0xAC601BB8, 0x800DE4BC: 0x34040063,
    0x800DE4C0: 0xAC641BBC,
    0x800DE500: 0x90621D5E, 0x800DE508: 0x1440000C,
    0x800DE528: 0xAC641BC0, 0x800DE52C: 0xAC601BB8,
    0x800DE538: 0xAC641BBC,
    0x80125FD4: 0x10400009, 0x80125FE8: 0xAC431BBC,
    0x80126008: 0x14620006, 0x80126020: 0xAC621BBC,
    0x80126034: 0xAC431BB8, 0x80126038: 0xAC441BBC,
    0x80128570: 0xAC831BB8, 0x80128D9C: 0xAC821BB8,
    0x80128DA4: 0xAC821BBC,
    0x80131E80: 0x8C82048C, 0x80131E88: 0x10400007,
    0x80131E90: 0x90820035, 0x80131E98: 0x14400003,
    0x80131EA0: 0x0804C80D, 0x80131EB4: 0x90420037,
    0x80131EC0: 0x1440000B, 0x80131EC8: 0x0C050932,
    0x80131EDC: 0x90830037, 0x80131EE4: 0x30620001,
    0x80131EE8: 0x10400012, 0x80131EF0: 0x3C038018,
    0x80131EF4: 0x8C63AAE4, 0x80131EFC: 0x8C620038,
    0x80131F04: 0x1040FFE6, 0x80131F18: 0xAC821BBC,
    0x80131FA0: 0x90820035, 0x80131FA8: 0x30420001,
    0x80131FAC: 0x1040001D, 0x80131FB4: 0x0C04C752,
    0x80131FC8: 0x90430002, 0x80131FD0: 0x0043102B,
    0x80131FD4: 0x1440000C, 0x80131FDC: 0x3C01800C,
    0x80131FE0: 0x242118C4, 0x80131FE4: 0x00220821,
    0x80131FE8: 0x8C220000, 0x80131FF0: 0x00400008,
    0x80131FF8: 0x0C030C41, 0x80132008: 0x0C030C41,
    0x8013201C: 0x0804C80C, 0x80132020: 0x34030001,
    0x8013202C: 0x34030002, 0x80132030: 0xAC831BBC,
    0x80128D44: 0xA0620002, 0x80128D98: 0xAC22A0C0,
    0x8016795C: 0x800D1384,
    0x80131EEC: 0x30620002,
    0x80131F34: 0x10400005,
    0x80131F38: 0x34020004,
    0x80131F3C: 0x3C048018,
    0x80131F40: 0x8C84DB24,
    0x80131F44: 0x0804C80C,
    0x80131F48: 0x34030002,
    0x80131F4C: 0x30620004,
    0x80131F50: 0x10400005,
    0x80131F54: 0x34020003,
    0x80131F58: 0x3C048018,
    0x80131F5C: 0x8C84DB24,
    0x80131F60: 0x0804C80C,
    0x80131F64: 0x34030003,
    0x80131F68: 0x30620008,
    0x80131F6C: 0x10400005,
    0x80131F70: 0x00001021,
    0x80131F74: 0x3C048018,
    0x80131F78: 0x8C84DB24,
    0x80131F7C: 0x0804C80C,
    0x80131F80: 0x34030004,
    0x80131F84: 0x30620010,
    0x80131F88: 0x10400005,
    0x80131F8C: 0x00001021,
    0x80131F90: 0x3C048018,
    0x80131F94: 0x8C84DB24,
    0x80131F98: 0x0804C80C,
    0x80131F9C: 0x34030005,
    0x80131FFC: 0x34040201,
    0x80132000: 0x0804C804,
    0x80132004: 0x00000000,
    0x80132008: 0x0C030C41,
    0x8013200C: 0x34040202,
    0x801394F4: 0x90630000,
    0x801394F8: 0x8CA2001C,
    0x801394FC: 0x00000000,
    0x80139500: 0x00622021,
    0x80139504: 0x340200FF,
    0x80139508: 0x14620012,
    0x8013950C: 0x340200FE,
    0x80139510: 0x3C038018,
    0x80139514: 0x8C63BE20,
    0x80139518: 0x00000000,
    0x8013951C: 0x90620037,
    0x80139520: 0x00000000,
    0x80139524: 0x34420008,
    0x80139528: 0xA0620037,
    0x8013952C: 0x3C048018,
    0x80139530: 0x8C84AF84,
    0x80139534: 0x3C038018,
    0x80139538: 0x8C63DB24,
    0x8013953C: 0x24820001,
    0x80139540: 0x3C018018,
    0x80139544: 0xAC22AF84,
    0x80139548: 0x90820000,
    0x8013954C: 0x0804E567,
    0x80139550: 0xAC621BC0,
    0x80139554: 0x14620009,
    0x80139558: 0x00041080,
    0x8013955C: 0x3C038018,
    0x80139560: 0x8C63BE20,
    0x80139564: 0x00000000,
    0x80139568: 0x90620037,
    0x8013956C: 0x00000000,
    0x80139570: 0x34420010,
    0x80139574: 0x0804E567,
    0x80139578: 0xA0620037,
    0x8013957C: 0x8CA30020,
    0x80139580: 0x00000000,
    0x80139584: 0x00431021,
    0x80139588: 0x8C430000,
    0x8013958C: 0x3C028018,
    0x80139590: 0x8C42DB24,
    0x80139594: 0x0C04B2EF,
    0x80139598: 0xAC431BB4,
    0x8012CBBC: 0x3C038018,
    0x8012CBC0: 0x8C63BE20,
    0x8012CBC4: 0x00000000,
    0x8012CBC8: 0x90620037,
    0x8012CBCC: 0x00000000,
    0x8012CBD0: 0x34420004,
    0x8012CBD4: 0xA0620037,
    0x8012CBD8: 0x3C038018,
    0x8012CBDC: 0x8C63BE20,
    0x8012CBE0: 0x34020001,
    0x8012CBE4: 0x3C018017,
    0x8012CBE8: 0xA022159A,
    0x8012CBEC: 0x03E00008,
    0x8012CBF0: 0xA0620036,
    0x800C2B54: 0x3C02801B,
    0x800C2B58: 0x3442A000,
    0x800C2B5C: 0x3C018018,
    0x800C2B60: 0xAC22C20C,
    0x800C9618: 0x3C028018,
    0x800C961C: 0x2442DA90,
    0x800C9620: 0xAC821BC8,
    0x800C9648: 0x3C028017,
    0x800C964C: 0x2442B358,
    0x800C9650: 0xAC6214B8,
    0x8013108C: 0x3C028001,
    0x80131090: 0x8C420000,
    0x8013109C: 0x3C018018,
    0x801310A0: 0xAC22C108,
    0x801398A0: 0x3C048018,
    0x801398A4: 0x8C84C108,
    0x801398B4: 0x90620000,
    0x801398B8: 0x8C830010,
    0x801398BC: 0x00021080,
    0x801398C0: 0x00431021,
    0x801398C4: 0x8C42000C,
    0x801398CC: 0xACA20494,
}


def _read_main() -> bytes:
    return disc.extract(MAIN_LBA, MAIN_SIZE)[MAIN_HEADER:]


def _word(img: bytes, va: int) -> int | None:
    off = va - MAIN_BASE
    if off < 0 or off + 4 > len(img):
        return None
    return int.from_bytes(img[off:off + 4], "little")


def _labels() -> list[tuple[int, str]]:
    rows = []
    with open(os.path.join(_KIT, "work", "function_labels.csv"), newline="") as f:
        for row in csv.reader(f):
            if len(row) < 2:
                continue
            try:
                va = int(row[0], 16)
            except ValueError:
                continue
            rows.append((va, row[1]))
    return sorted(rows)


def _installs(img: bytes) -> list[dict]:
    """Find literal stores to either table base and established indexed stores."""
    labels = _labels()
    label_names = dict(labels)
    label_addrs = [r[0] for r in labels]
    words = lambda va: _word(img, va)
    found = []
    for off in range(0, len(img) - 3, 4):
        pc = MAIN_BASE + off
        w = words(pc)
        if w is None or w >> 26 != 0x2B:
            continue
        _, f = mipsdec.dec(pc, w)
        label_i = bisect.bisect_right(label_addrs, pc) - 1
        if label_i < 0:
            continue
        owner_va, owner = labels[label_i]
        table = None
        value, chain = resolve_reg(pc, f["rs"], reader=words)
        effective = None if value is None else (value + f["imm"]) & 0xFFFFFFFF
        if effective in (ROOT_SLOT, MODE_TABLE):
            chain_pcs = [int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]+):", chain)]
            if chain_pcs and min(chain_pcs) >= owner_va:
                table = effective
        if table is None and f["imm"] == 0:
            base_writer = writer_of(pc, f["rs"], reader=words)
            if not base_writer:
                continue
            writer_pc, _, wf = base_writer
            if writer_pc < owner_va or wf["op"] != 0 or wf["fn"] != 0x21:
                continue
            for src in (wf["rs"], wf["rt"]):
                value, chain = resolve_reg(writer_pc, src, reader=words)
                if value in (ROOT_SLOT, MODE_TABLE):
                    chain_pcs = [int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]+):", chain)]
                    if chain_pcs and min(chain_pcs) >= owner_va:
                        table = value
                        break
        if table is None:
            continue
        role = ("root_bootstrap" if pc == BOOTSTRAP_INSTALL else
                "mode_route" if pc in ROUTE_INSTALLS else
                "root_lifecycle" if pc in ROOT_LIFECYCLE_INSTALLS else
                "subordinate_callback")
        handler, handler_chain = resolve_reg(pc, f["rt"], reader=words)
        handler_sites = [int(x, 16) for x in
                         re.findall(r"0x([0-9a-fA-F]+):", handler_chain)]
        found.append({"site": pc, "table_base": table, "owner_va": owner_va,
                      "owner": owner, "role": role, "word": w,
                      "handler": handler,
                      "handler_label": label_names.get(handler, ""),
                      "handler_source_sites": handler_sites,
                      "handler_source_words": [words(va) for va in handler_sites]})
    return found


def _mode_stores(img: bytes) -> list[int]:
    out = []
    for off in range(0, len(img) - 3, 4):
        pc = MAIN_BASE + off
        w = _word(img, pc)
        if w is None:
            continue
        _, f = mipsdec.dec(pc, w)
        if f["op"] == 0x2B and f["imm"] == 0x1BBC:
            out.append(pc)
    return out


def model(img: bytes | None = None) -> dict:
    img = img if img is not None else _read_main()
    return {
        "binary": {"path": "MAIN.EXE", "lba": MAIN_LBA,
                   "image_base": MAIN_BASE, "header_bytes": MAIN_HEADER},
        "mode_word": {"name": "game_state_mode", "address": MODE_WORD,
                      "base": 0x8017DB24, "offset": 0x1BBC, "width": 4},
        "dispatcher": {"address": 0x800C98F0, "callback_table": MODE_TABLE,
                       "calls_slot_at": 0x800C99EC, "return_minus_one_gate": 0x800C99F8,
                       "root_callback_table": ROOT_SLOT},
        "routes": ROUTES,
        "mode_word_store_sites": _mode_stores(img),
        "mode_word_transitions": MODE_STORE_CONTEXTS,
        "field_command_selector": {"source": 0x801B8002,
                               "jump_table": MODE_SWITCH_TABLE,
                               "table_words": MODE_SWITCH_WORDS,
                               "command_201_values": [0, 1, 4, 5, 8],
                               "command_202_values": [2, 3, 6, 7],
                               "command_202_default_at_or_above": 9,
                               "selected_mode": 1},
        "mode2_flag_request": {"event_opcode": 0x42, "event_handler": 0x801398F8,
                                "ui_command": 3, "ui_dispatcher": 0x80141814,
                                "ui_command_table": 0x800C1AC0,
                                "ui_request_flag": 0x8017159B, "mask": 0x02,
                                "consumer": 0x801326CC,
                                "area_flag_store": 0x8013270C,
                                "context_gate_store": 0x8013271C,
                                "transition_callback": 0x80132898,
                                "selector0_writer": 0x801284C0,
                                "selector0_source": "zero-based field-counter descriptor index"},
        "duel_entry_chain": {"mode": 2, "selector_bytes": [2, 5],
                             "record_table": 0x8016F67C,
                             "area_chain": 0x8016F4DC, "area_record": 0x801644C4,
                             "area_overlay_lba": 99160,
                             "resource_directory": 0x8016B358,
                             "loaders": [0x800101F4, 0x80010258, 0x8001049C],
                             "module_group_indices": [4, 5, 6],
                             "module_lbas": [161871, 162008, 161940],
                             "asset_group_pairs": [[9, 10], [13, 14], [11, 12]],
                             "script_routes": [
                                 {"file": "VB7D.BIN", "lba": 63043,
                                  "script_sites": [0xC1BB, 0xC5FD, 0xC615],
                                  "callback_table": 0x80013DE8,
                                  "callback_indices": [3, 4, 4],
                                  "callbacks": [0x80010130, 0x80010194, 0x80010194],
                                  "module_group_indices": [4, 5, 5],
                                  "module_lbas": [161871, 162008, 162008]},
                                 {"file": "VC6.BIN", "lba": 99160,
                                  "script_sites": [0x3E319],
                                  "callback_table": 0x800175F4,
                                  "callback_indices": [3],
                                  "callbacks": [0x8001049C],
                                  "module_group_indices": [6],
                                  "module_lbas": [161940]},
                             ]},
        "callback_alias": {"store": 0x800C9620, "field": "gs+0x1BC8",
                           "target": ROOT_SLOT, "consumer": None},
        "callback_install_census": _installs(img),
        "still_open": [
            "The exact story-script roots for the duel commands remain open; event opcode 0x42 command 3 is a proven producer of the context+0x37 mode-2 request flag. Other context+0x35 bit-0 producers remain untraced.",
            "The gs+0x1BC8 callback-table alias has no direct-offset reader in the bounded MAIN/overlay scan; arbitrary callback pointers built from unrelated sources remain outside that scan.",
        ],
    }


def verify() -> list[str]:
    img = _read_main()
    out = []
    for va, expected in ANCHOR_WORDS.items():
        got = _word(img, va)
        assert got == expected, f"{va:#010x}: {got!r} != {expected:#010x}"
    out.append(f"ok   {len(ANCHOR_WORDS)} word anchors re-read from headerless MAIN.EXE")
    stores = _mode_stores(img)
    assert len(stores) == 12, f"expected 12 game_state+0x1BBC stores, found {len(stores)}"
    with open(os.path.join(_KIT, "work", "gs_recs.json")) as f:
        gs_records = json.load(f)
    tracked_stores = [row[1] for row in gs_records
                      if row[0] == "indirect" and row[4] == 4
                      and row[5] == "W" and row[6] == "gs+0x1BBC"]
    assert len(tracked_stores) == 12 and set(stores) == set(tracked_stores), \
        "direct mode-word stores disagree with tracked game-state writer census"
    assert {row["site"] for row in MODE_STORE_CONTEXTS} == set(stores), \
        "mode-word transition context is missing a direct writer"
    out.append("ok   all 12 direct +0x1BBC stores inventoried")
    table_words = [_word(img, MODE_SWITCH_TABLE + i * 4) for i in range(9)]
    assert table_words == MODE_SWITCH_WORDS, "field command selector jump table changed"
    out.append("ok   field command selector table independently read at 0x800C18C4")
    installs = _installs(img)
    assert len(installs) == 160, f"expected 160 direct-address callback stores, found {len(installs)}"
    assert len({r["site"] for r in installs}) == len(installs)
    assert all(r["handler"] is not None and r["handler_source_sites"]
               for r in installs), "callback handler target did not resolve"
    assert all(MAIN_BASE <= r["handler"] < MAIN_BASE + len(img)
               for r in installs), "callback handler target is outside MAIN.EXE"
    assert {r["site"] for r in installs if r["role"] == "mode_route"} == ROUTE_INSTALLS
    assert {r["site"] for r in installs if r["role"] == "root_bootstrap"} == {BOOTSTRAP_INSTALL}
    out.append("ok   160 direct-address callback stores classified by bootstrap/dispatcher/lifecycle/owner")
    out.append("ok   all 160 stored handler targets resolve to MAIN.EXE instruction addresses")
    assert _word(img, 0x800C9AA0) == 0x244279E8
    assert _word(img, 0x800C9AB0) == 0x24420EC4
    assert _word(img, 0x800C9AC0) == 0x2442DF98
    assert _word(img, 0x800C9AE0) == 0x24425DC0
    out.append("ok   mode 1/2/3/4-5,99 handlers re-derived from route encodings")
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--modes", action="store_true")
    ap.add_argument("--json", nargs="?", const="-", metavar="PATH")
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args(argv)
    if args.verify:
        for line in verify():
            print(line)
        print("PASS: mode_map verifies against headerless MAIN.EXE")
        return 0
    if args.json is not None:
        data = json.dumps(model(), indent=2)
        if args.json == "-":
            print(data)
        else:
            with open(args.json, "w") as f:
                f.write(data + "\n")
        return 0
    if args.modes:
        print(f"mode word: game_state+0x1BBC @ {MODE_WORD:#x}")
        for row in ROUTES:
            modes = row["mode"]
            handler = (f"{row['handler']:#010x}" if row["handler"] else
                       row["action"])
            print(f"  {str(modes):<8} {handler:<16} guard: {row['guard']}")
        print("Still open: remaining context-flag/story predicates and arbitrary callback-pointer flows.")
        return 0
    ap.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
