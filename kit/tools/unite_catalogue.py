#!/usr/bin/env python3
"""Complete Unite catalogue and participant lifecycle analysis from MAIN.EXE.

Reads MAIN.EXE statically through ``disc.py`` to extract the 32 Unite records,
membership/reservation/target/execution/recovery contracts, and hit-gate /
reaction bindings.

Usage::

    .venv/bin/python kit/tools/unite_catalogue.py            # write outputs
    .venv/bin/python kit/tools/unite_catalogue.py --check    # verify only
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit" / "tools"))

import maindec  # noqa: E402
import war_text  # noqa: E402

BASE = "a50852c24c3124093ce2aaf99c9c5147d4579316"
VERSION = "unite-catalogue.7"
TASK = "battle-unite-catalogue"

ASSET_DIR = "game/assets/battle_systems"
CATALOGUE_PATH = f"{ASSET_DIR}/unite_catalogue.json"
DATA_PATH = "game/assets/battle_systems.zig"

# --- source constants (MAIN.EXE, PS-X EXE body base 0x800C0800) -------------
UNITE_TABLE = 0x8016CD0C
UNITE_STRIDE = 0x24
UNITE_COUNT = 32
UNITE_POINTERS = 0x8016D190
UNITE_ACTION_TABLE = 0x8016D2D0
UNITE_ACTION_COUNT = 0x20
NAME_BYTES = 0x14
FLAGS_OFF = 0x16
COUNT_OFF = 0x18
ID_OFF = 0x19
MEMBERS_OFF = 0x1A
MAX_MEMBERS = 4

#: combined-physical helpers: (address, gate, description)
DAMAGE_HELPERS = {
    0x800F9488: ("leader_hit_flag", "sum of physical results; gate A[leader]+0x40 bit1; clears each member's bit1; one 0x800E1654 commit"),
    0x800F95E8: ("target_active", "sum of physical results against B[target]+0x45 == 0; one 0x800E1654 commit"),
}

#: the matcher/commit/validator/recovery instruction words this tool pins.
PINS: dict[str, dict[int, str]] = {
    "membership": {
        0x800F91EC: "lb t4,0x48(v0)   ; B[actor]+0x48 = one-based record ordinal",
        0x800F91F8: "lb t7,0x49(v0)   ; B[actor]+0x49 = chosen target",
        0x800F9204: "lw v1,0(a0)      ; record = pointer_table[ordinal]",
        0x800F9210: "lbu t3,0x18(v1)  ; member count",
        0x800F9238: "lbu a3,0x1a(v0)  ; member character id",
        0x800F925C: "bne v0,a3        ; compare against A[i]+0x00",
        0x800F9264: "sb t2,0x46(a2)   ; B[i]+0x46 = 1 mark",
        0x800F928C: "slt v0,t0,t3     ; loop bound is the record count byte",
        0x800F9300: "sh zero,0x40(a3) ; clear A[i]+0x40 flag word",
        0x800F9304: "sb t7,0x49(t1)   ; B[i]+0x49 = target",
        0x800F9344: "sll v0,t0,3      ; post-pass starts at party_count+1",
        0x800F9374: "sh zero,0x40(v1) ; clears A[k]+0x40 for the non-party tail",
    },
    "reservation": {
        0x800E9FFC: "andi v0,v0,0x20  ; sleep clears the slot's selectable flag",
        0x800EA00C: "sw zero,0xb4(a0) ; status-blocked slot: flag 0",
        0x800EA010: "sw t1,0xb4(a0)   ; otherwise flag 1 (still selectable)",
        0x800EA014: "addiu a0,a0,4    ; per-slot array stride 4",
        0x800EDF98: "sb t1,0x47(v0)   ; B[i]+0x47 = 4 (Unite command)",
        0x800EDFA8: "lbu v1,0x50(v1)  ; selected one-based record ordinal",
        0x800EDFAC: "sb s2,0x49(v0)   ; B[i]+0x49 = chosen target",
        0x800EDFB0: "sb v1,0x48(v0)   ; B[i]+0x48 = record ordinal",
        0x800EDFC4: "sw zero,0xb4(v0) ; consume the slot's selectable flag",
        0x800EF254: "lw v1,0xb4(a0)   ; availability check reads the flag",
        0x800EF25C: "bne v1,v0        ; only flag == 1 is eligible",
        0x800EF29C: "andi v0,v0,0x61  ; B+0x4A & 0x61 must be clear",
        0x800EB050: "sw t2,0xb4(a1)   ; command cancel restores the flag",
    },
    "target": {
        0x800EDA00: "lhu v0,0x16(v0)  ; record flags",
        0x800EDA08: "andi v0,v0,2     ; bit1 selects the individual picker",
        0x800EDAD0: "lui v0,0x800f    ; picker handler 0x800EDB18",
        0x800EDAD4: "addiu v0,v0,-0x24e8",
        0x800EDAE8: "lui v0,0x800f    ; bypass handler 0x800EDE58",
        0x800EDAEC: "addiu v0,v0,-0x21a8",
        0x800EDC20: "sb v1,0x49(v0)   ; picker confirmation writes the target",
        0x800F5890: "lb a0,0x49(s0)   ; execution reads the same target byte",
        0x800F5894: "andi v1,v0,3     ; low flag bits select the rule",
        0x800F58C0: "lw v0,0x2c(v0)   ; bypass gate: living enemy count",
        0x800F58C8: "bgtz v0          ; require at least one living enemy",
        0x800F58D8: "jal 0x800F8680   ; validate chosen target",
        0x800F58E8: "jal 0x800F6344   ; repair invalid target",
        0x800F58F4: "beq a0,zero      ; no replacement -> reject the unite",
        0x800F58FC: "sb a0,0x49(s0)   ; write the repaired target back",
        0x800F5914: "lbu v0,0x19(v0)  ; unite id selects the action pointer",
        0x800F5920: "lui at,0x8017    ; action table 0x8016D2D0",
        0x800F5924: "addiu at,at,-0x2d30",
        0x800F593C: "sw v1,0x18(a0)   ; install the unite initializer",
        0x800F86BC: "lbu v0,0x45(v1)  ; target eligibility: B+0x45 == 0",
        0x800F86C4: "bne v0,zero      ; nonzero -> invalid",
        0x800F86CC: "lh v0,0x12(v1)   ; B+0x12 minus B+0x4E",
        0x800F86D0: "lh v1,0x4e(v1)",
        0x800F86DC: "bgez v0          ; >= 0 is valid",
        0x800F8628: "lbu v1,0x55(v0)  ; repair candidate A[i]+0x05 == 0",
        0x800F8650: "lbu v1,0x45(a0)  ; repair candidate B[i]+0x45 == 0",
        0x800F866C: "subu v0,v0,v1",
        0x800F8670: "slt v0,zero,v0   ; repair requires diff > 0",
        0x800F6360: "addiu s0,v1,1    ; repair scan starts at party_count+1",
        0x800F6364: "slt v0,v0,s0",
        0x800F6370: "jal 0x800F8604   ; candidate structural check",
        0x800F6380: "jal 0x800F8680   ; candidate target check",
        0x800F6388: "beq v0,zero      ; first accepted index is returned",
    },
    "effect": {
        0x800F98B8: "ori a1,zero,2    ; shared 2-member handler: count 2",
        0x800F98BC: "ori a2,zero,0x14 ; multiplier 20",
        0x800F98C0: "jal 0x800F9488   ; combined physical helper",
        0x800F9A80: "ori a1,zero,2    ; Fisherman: count 2",
        0x800F9A84: "ori a2,zero,0x1e ; multiplier 30",
        0x800F9A88: "jal 0x800F9488",
        0x800FA5E0: "ori a1,zero,4    ; Blacksmith: count 4",
        0x800FA5E4: "ori a2,zero,0x1e ; multiplier 30",
        0x800FA5EC: "jal 0x800F9488",
        0x800F94F8: "lhu v0,0x40      ; leader A+0x40 flag word",
        0x800F94FC: "lb s4,0xb89(a0)  ; target = B[leader]+0x49",
        0x800F9500: "andi v0,v0,2     ; gate on the leader hit flag",
        0x800F9558: "andi a0,a0,0xfffd; clear each member's hit bit",
        0x800F9564: "mult s2,s7       ; sum * multiplier",
        0x800F9574: "div a1,10        ; / 10",
        0x800F95A0: "jal 0x800E1654   ; one combined HP commit",
        0x800F9630: "lbu v0,0xb85(v1) ; alternate helper: target B+0x45",
        0x800F9638: "bne v0,zero      ; target must be active",
        0x800F9674: "mult s2,s5       ; sum * multiplier",
        0x800F96B0: "jal 0x800E1654   ; one HP commit",
        0x800F9390: "slot recorder: sets one slot per member ready bit",
        0x800F9718: "all-slots wait: 1 only when every slot is nonzero",
        0x800F98E0: "jal 0x800F9718   ; completion waits for both members",
        0x800F9900: "jal 0x800C2DC0   ; free the unite state on completion",
    },
    "recovery": {
        0x800E6AB8: "actor-script op40 handler",
        0x800E6BCC: "ori v0,zero,0x19 ; party Turtle exemption before RNG",
        0x800E05CC: "sb v1,0x4d(v0)   ; recovery counter 1",
        0x800E05D0: "sb v1,0x46(v0)   ; participation mark",
        0x800E05F8: "sb v0,0x4c(v1)   ; long counter 2 (separate status class)",
        0x800E0618: "or a0,a0,a1      ; status mask OR",
        0x800E0800: "lhu a0,0(0x8017BAA8) ; status class -> mask",
        0x800E0810: "nor a0,zero,a0",
        0x800E0814: "and a1,a1,a0     ; clear the class bit",
        0x800F657C: "lhu v0,0x4a(s0)  ; round boundary: B+0x4A",
        0x800F6584: "andi v0,v0,0x40  ; recovery bit",
        0x800F65A0: "jal 0x800E0778   ; clear the recovery class",
        0x800F65B4: "sb v0,0x4d(s0)   ; decrement the counter",
        0x800E2D7C: "sb v1,0x45(v0)   ; death path raises B+0x45",
        0x800F6564: "sb s2,0x45(s0)   ; status mask 8 raises B+0x45",
    },
    "resume": {
        0x800F6BF8: "sb zero,0x49(v1) ; round reset clears the target",
        0x800F6BFC: "sb zero,0x48(v1) ; and the unite ordinal",
        0x800F6C00: "sb zero,0x47(v1) ; and the command byte",
        0x800F6C1C: "beq v0,zero      ; for every combatant record",
        0x800EF2FC: "sw fp,0x80(v0)   ; availability list stores a one-based ordinal",
        0x800EF2F0: "sll v0,s6,2      ; list index",
        0x800EF2F4: "addiu s6,s6,1",
        0x800EF324: "addiu fp,fp,1    ; ordinal increments from 1",
        0x8016D284: "op40(7,100)      ; common return descriptor: recovery on every participant",
    },
}

#: halfword operands of the common return descriptor at 0x8016D284
RETURN_DESCRIPTOR = (0x8016D284, (0x0028, 0x0007, 0x0064))

CHARACTER_TABLE = "kit/data/catalogs/character_table.json"

#: Compositions the manual names explicitly (`manual/11-battle.md` and
#: `archive/docs/talisman_joint_action.md`).  The character ids in each record
#: must resolve to exactly these names through the tracked character table.
DOCUMENTED_COMPOSITIONS = {
    0: ("Talisman attack", ("Pahn", "Gremio")),
    1: ("Fisherman attack", ("Tai Ho", "Yam Koo")),
    5: ("Blacksmith attack", ("Maas", "Moose", "Meese", "Mace")),
    16: ("Couple attack", ("Eileen", "Lepant")),
    21: ("Blacksmith attack", ("Maas", "Moose", "Meese", "Mose")),
    22: ("Blacksmith attack", ("Mose", "Moose", "Meese", "Mace")),
    23: ("Blacksmith attack", ("Maas", "Mose", "Meese", "Mace")),
    24: ("Blacksmith attack", ("Maas", "Moose", "Mose", "Mace")),
    31: ("Master pupil attack", ("Hero", "Kai")),
}

#: the eight records that skip the individual target picker (established in
#: `archive/docs/unite_target_flag.md`; re-derived here from the flag data)
PICKER_BYPASS_INDICES = (2, 9, 14, 19, 20, 25, 29, 31)


# --- byte helpers -----------------------------------------------------------
def body() -> bytes:
    return maindec.body()


def word(va: int) -> int:
    value = maindec.mword(va)
    if value is None:
        raise SystemExit(f"address outside MAIN.EXE body: {va:#x}")
    return value


def byte(va: int) -> int:
    return body()[va - maindec.MBASE]


def half(va: int) -> int:
    return struct.unpack_from("<H", body(), va - maindec.MBASE)[0]


def opcode(insn: int) -> int:
    return (insn >> 26) & 0x3F


def rs(insn: int) -> int:
    return (insn >> 21) & 0x1F


def rt(insn: int) -> int:
    return (insn >> 16) & 0x1F


def imm(insn: int) -> int:
    value = insn & 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def jal_target(insn: int, pc: int) -> int | None:
    if opcode(insn) != 3:
        return None
    return ((insn & 0x03FFFFFF) << 2) | (pc & 0xF0000000)


def function_end(start: int, limit: int = 0x1000) -> int:
    va = start
    while va < start + limit:
        insn = word(va)
        if opcode(insn) == 0 and (insn & 0x3F) == 8 and rs(insn) == 31:
            return va + 8
        va += 4
    raise SystemExit(f"no jr $ra within {limit:#x} of {start:#x}")


def load_constant(reg: int, start: int, at: int) -> int | None:
    """Value of `reg` built by the nearest preceding lui (+ optional addiu)."""
    for pc in range(at - 4, start - 4, -4):
        insn = word(pc)
        if rt(insn) != reg:
            continue
        if opcode(insn) == 0x0F:
            base = (insn & 0xFFFF) << 16
            for pc2 in range(pc + 4, at, 4):
                insn2 = word(pc2)
                if opcode(insn2) == 9 and rs(insn2) == reg and rt(insn2) == reg:
                    return (base + imm(insn2)) & 0xFFFFFFFF
            return base
    return None


def install_update(init_start: int, init_end: int) -> int | None:
    """The update pointer the initializer installs.

    Two shapes exist.  Most initializers store the update directly into battle
    state ``+0x18``.  Three unite ids (8, 9 and 17) are thunks that pass the
    update in ``a0`` to the shared installer ``0x800F9114``, which stores it in
    the same slot through ``0x800F9178``.  Both are the same fact.
    """
    for va in range(init_start, init_end, 4):
        insn = word(va)
        if opcode(insn) == 0x2B and imm(insn) == 0x18:
            value = load_constant(rt(insn), init_start, va)
            if value is not None and 0x800C0000 <= value < 0x80140000:
                return value
    for va in range(init_start, init_end, 4):
        insn = word(va)
        if jal_target(insn, va) == 0x800F9114:
            value = load_constant(4, init_start, va)
            if value is not None and 0x800C0000 <= value < 0x80140000:
                return value
    return None


def damage_call(update_start: int, update_end: int) -> tuple[int, int, int] | None:
    """(helper, count, multiplier) of the update's combined-physical call."""
    for va in range(update_start, update_end, 4):
        insn = word(va)
        target = jal_target(insn, va)
        if target not in DAMAGE_HELPERS:
            continue
        count = multiplier = None
        for pc in range(max(update_start, va - 0x60), va, 4):
            prev = word(pc)
            if opcode(prev) == 0x0D and rs(prev) == 0 and rt(prev) == 5:
                count = prev & 0xFFFF
            if opcode(prev) == 0x0D and rs(prev) == 0 and rt(prev) == 6:
                multiplier = prev & 0xFFFF
        if count is None or multiplier is None:
            raise SystemExit(f"damage call at {va:#x} lacks immediate count/multiplier")
        return target, count, multiplier
    return None


# --- extraction -------------------------------------------------------------
def extract_records() -> list[dict]:
    pointers = [word(UNITE_POINTERS + 4 * i) for i in range(UNITE_COUNT)]
    records = []
    for i in range(UNITE_COUNT):
        stride_addr = UNITE_TABLE + UNITE_STRIDE * i
        pointer = pointers[i]
        if pointer != stride_addr:
            raise SystemExit(
                f"record {i}: pointer {pointer:#x} != fixed stride {stride_addr:#x}")
        raw = body()[pointer - maindec.MBASE: pointer - maindec.MBASE + UNITE_STRIDE]
        name, _ = war_text.decode(raw, 0, NAME_BYTES)
        # war_text escapes bytes outside the game table; keep the raw marker so
        # a partially decoded label is never presented as a settled name.
        name_fully_decoded = "\\x" not in name
        flags = half(pointer + FLAGS_OFF)
        count = byte(pointer + COUNT_OFF)
        unite_id = byte(pointer + ID_OFF)
        members = [byte(pointer + MEMBERS_OFF + k) for k in range(count)]
        if not name:
            raise SystemExit(f"record {i}: empty name")
        if count < 2 or count > MAX_MEMBERS:
            raise SystemExit(f"record {i}: unsupported member count {count}")
        if len(set(members)) != len(members):
            raise SystemExit(f"record {i}: duplicate member id in {members}")
        if flags & 1 == 0:
            raise SystemExit(f"record {i}: bit0 clear in flags {flags:#x}")
        if flags & 3 not in (1, 3):
            raise SystemExit(f"record {i}: unknown low flag bits {flags & 3}")
        records.append({
            "index": i,
            "name": name,
            "name_fully_decoded": name_fully_decoded,
            "flags": flags,
            "target_rule": "individual" if flags & 2 else "bypass",
            "member_count": count,
            "members": members,
            "unite_id": unite_id,
        })
    return records


def action_table() -> list[int]:
    return [word(UNITE_ACTION_TABLE + 4 * i) for i in range(UNITE_ACTION_COUNT)]


def handler_table() -> dict[int, int]:
    """unite id -> initializer, restricted to executable text pointers.

    Slots 0 and 26 are null; slots 27..31 are not code (one small integer and
    four data pointers) and no unite record uses them.
    """
    table = {}
    for unite_id, pointer in enumerate(action_table()):
        if 0x800C0000 <= pointer < 0x80140000:
            table[unite_id] = pointer
    return table


def classify_handlers(table: dict[int, int]) -> dict[int, dict]:
    facts = {}
    for unite_id, init in sorted(table.items()):
        init_end = function_end(init)
        update = install_update(init, init_end)
        if update is None or update == 0:
            raise SystemExit(f"unite id {unite_id}: no installed update at {init:#x}")
        chain = []
        while True:
            if update in chain or len(chain) == 8:
                raise ValueError(f"cyclic or excessive Unite callback chain for {unite_id}")
            chain.append(update)
            update_end = function_end(update)
            call = damage_call(update, update_end)
            if call is not None:
                break
            following = install_update(update, update_end)
            if following is None:
                break
            update = following
        if call is None:
            facts[unite_id] = {
                "init": init,
                "update": update,
                "family": "custom",
                "gate": None,
                "damage_count": 0,
                "multiplier": 0,
            }
        else:
            helper, count, multiplier = call
            gate, _ = DAMAGE_HELPERS[helper]
            facts[unite_id] = {
                "init": init,
                "update": update,
                "family": "combined_physical",
                "gate": gate,
                "damage_count": count,
                "multiplier": multiplier,
                "helper": helper,
            }
        facts[unite_id]["callback_chain"] = chain
    return facts


def character_names() -> dict[int, str]:
    rows = json.loads((ROOT / CHARACTER_TABLE).read_text())
    names = {}
    for row in rows:
        if row["id"] in names:
            raise SystemExit(f"duplicate character id {row['id']} in {CHARACTER_TABLE}")
        names[row["id"]] = row["name"]
    if len(names) != len(rows) or not names:
        raise SystemExit(f"character table did not yield a unique id map: {len(names)}/{len(rows)}")
    return names


def queued_target_facts(entry: dict) -> dict | None:
    if entry['index'] != 31:
        return None
    import character_table
    import export_first_room
    import export_battle_trial
    import journey_battle
    pins = {0x800FE764: 0xACA6003C, 0x800FE944: 0xA0500049,
            0x800FE94C: 0xAE20003C, 0x800FE954: 0x28620007,
            0x800FEA20: 0x80440049, 0x800FEA28: 0x0C03E57A,
            0x800FEA8C: 0x28620028}
    for pc, expected in pins.items():
        if word(pc) != expected: raise ValueError(f'Master pupil queue changed at {pc:#x}')
    by_id = {row['id']: row for row in character_table.records()}
    members = []
    for member in entry['members']:
        data, source = export_first_room.source('/' + by_id[member]['sprite_file'])
        section = struct.unpack_from('<I', data, 36)[0]
        _, animations, _ = export_battle_trial.section_art(data, section)
        setup = journey_battle.script_events(animations, journey_battle.script(data, 10))
        strike = journey_battle.script_events(animations, journey_battle.script(data, 11))
        retreat = journey_battle.script_events(animations, journey_battle.script_at(body(), 0x8016D214-maindec.MBASE))
        members.append(dict(member=member, source=source, setup_script=10, strike_script=11,
                            animation_ticks=[sum(t or 256 for _, t in frames) for frames in animations],
                            setup_ready=setup['events'][16], impact=strike['events'][2],
                            ready=strike['events'][16], retreat=retreat['duration']))
    return dict(members=members, finish_delay=40)


def resource_script_loads(entry: dict) -> list[dict]:
    """Local resource-pointer arguments consumed by the actor dispatcher."""
    from mips_writers import dst_reg_of_word, is_call_word
    loads = []
    for start in [entry['handler'], *entry['callback_chain']]:
        for pc in range(start, function_end(start), 4):
            insn = word(pc)
            if opcode(insn) != 3 or jal_target(insn, pc) != 0x800E3820:
                continue
            # Stop at a competing writer, call or branch; do not borrow another path's argument.
            for at in range(pc + 4, max(start - 4, pc - 40), -4):
                if at == pc:
                    continue
                candidate = word(at)
                if dst_reg_of_word(at, candidate) == 6:
                    offset = candidate & 0xFFFF
                    if opcode(candidate) == 0x23 and offset in range(0x24, 0x38, 4):
                        loads.append(dict(call=pc, load=at, script=offset // 4))
                    break
                if is_call_word(candidate) or opcode(candidate) in (1, 2, 4, 5, 6, 7):
                    break
    return loads


def hit_gate_binding(record, image):
    """Name the actor passed to the shared hit gate, independently of command ownership."""
    if record['gate'] == 'target_active':
        return dict(kind='target_active')
    if record['gate'] != 'leader_hit_flag':
        raise ValueError('Unbound Unite damage gate')
    from spell_scene_source import Analysis
    initial = [None] * 32
    initial[0], initial[4], initial[29] = 0, ('callback_actor',), ('stack',)
    candidates = []
    state = ('global', 0x8017A010)
    for function in record['callback_chain']:
        analysis = Analysis(image, function, end=function_end(function),
                            initial=tuple(initial), cut_backedges=True)
        for pc, event in analysis.events('call'):
            if event[1] != 0x800F9488:
                continue
            actor, count, multiplier, members = event[2][:4]
            if count != len(record['members']) or multiplier != record['multiplier']:
                raise ValueError('Unite hit-gate count/power disagrees with catalogue')
            if members == state:
                base = 0
            elif isinstance(members, tuple) and members[:2] == ('add', state) and isinstance(members[2], int):
                base = members[2]
            else:
                raise ValueError('Unbound Unite hit-gate member list')
            binding = dict(call=pc, callback=function, member_list_offset=base)
            if actor == ('callback_actor',):
                binding['kind'] = 'callback_actor'
            elif isinstance(actor, tuple) and actor[:2] == ('member', state) and isinstance(actor[2], int):
                index, remainder = divmod(actor[2] - base, 4)
                if remainder or not 0 <= index < len(record['members']):
                    raise ValueError('Unite hit-gate actor outside its member list')
                binding.update(kind='member', member_index=index, member=record['members'][index])
            else:
                raise ValueError('Unbound Unite hit-gate actor')
            candidates.append(binding)
    if len(candidates) != 1:
        raise ValueError('Unite hit-gate actor is not unique')
    return candidates[0]



def reaction_binding(record, image):
    """Resolve the shared damage helper's reaction selector to a member resource."""
    from spell_scene_source import Analysis, leaves, member, operation
    state = ('unite_state',)
    bindings = []
    for start in dict.fromkeys([record['handler'], *record['callback_chain']]):
        analysis = Analysis(image,start,end=function_end(start),cut_backedges=True)
        allocations = [(pc,event) for pc,event in analysis.events('call') if event[1]==0x800C2D30]
        allocation = None
        if allocations:
            pc,event = allocations[0]
            allocation = dict(call=pc,bytes=event[2][0])
            initial = list(analysis.after[pc])
            # Name this allocation to keep actor-index expressions inside the analyzer's size bound.
            initial[2] = state
            analysis = Analysis(image,start,end=function_end(start),entry=pc+8,
                                initial=tuple(initial),cut_backedges=True)
        stores = [(pc,event[2]) for pc,event in analysis.events('store') if event[1]==('global',0x8017A018)]
        for pc,value in stores:
            if value == 0:
                bindings.append(dict(kind='null_shared_helper_reaction',initializer=start,store=pc))
                continue
            matches = [(at,event[2][1]) for at,event in analysis.events('call') if event[1]==0x800F91C0]
            if len(matches)!=1 or allocation is None:
                raise ValueError('Unite reaction has no unique member-list allocation')
            match,list_base = matches[0]
            if list_base==state:
                base = 0
            elif isinstance(list_base,tuple) and list_base[:2]==('add',state) and isinstance(list_base[2],int):
                base = list_base[2]
            else:
                raise ValueError('Unresolved Unite reaction member list')
            offsets = {leaf[2] for leaf in leaves(value) if len(leaf)==3 and leaf[:2]==('member',state)}
            if len(offsets)!=1 or not isinstance(value,tuple) or len(value)!=3 or not isinstance(value[2],int):
                raise ValueError('Unresolved Unite reaction resource')
            offset = next(iter(offsets));index = (offset-base)//4
            slot = value[2]
            actor = member(state,offset)
            stride = operation('shl',operation('sub',operation('shl',operation('add',operation('shl',actor,3),actor),2),actor),2)
            expected = member(member(operation('add',stride,operation('add',('global',0x8017BE3C),80)),8),slot)
            if value!=expected or slot<0 or slot%4 or (offset-base)%4 or not 0<=index<len(record['members']):
                raise ValueError('Unite reaction does not select a participant resource script')
            if not isinstance(allocation['bytes'],int) or not 0<=base<=offset<allocation['bytes']-3:
                raise ValueError('Unite reaction member list outside its allocation')
            bindings.append(dict(kind='member_resource',initializer=start,store=pc,allocation=allocation,
                matcher=match,member_list_offset=base,member_index=index,member=record['members'][index],script=slot//4))
    if len(bindings)!=1:
        raise ValueError('Unite shared-helper reaction selector is not unique')
    return bindings[0]


def target_reaction_facts(entry: dict) -> tuple[int | None, dict]:
    import character_table
    import export_first_room
    import journey_battle
    from spell_scene_source import Image
    binding = reaction_binding(entry,Image())
    if binding['kind']=='null_shared_helper_reaction':
        return None, dict(binding=binding)
    character = next(row for row in character_table.records() if row['id']==binding['member'])
    data,source = export_first_room.source('/'+character['sprite_file'])
    operations = journey_battle.script(data,binding['script'])
    if any(op==5 for op,args in operations):
        raise ValueError('Unite target timing requires recipient animation durations')
    table = struct.unpack_from('<I',data,32)[0]
    offset = struct.unpack_from('<I',data,table+4*binding['script'])[0]
    length = sum(2+2*len(args) for op,args in operations)
    updates = journey_battle.script_events([],operations,initial_movement_wait=True)['duration']
    return updates, dict(binding=binding,source=source,source_offset=offset,byte_length=length,
        sha256=hashlib.sha256(data[offset:offset+length]).hexdigest(),
        timing_scope='Actor-local VM wait updates including the dispatch update; recipient graphics and callback/frame-driver alignment remain separate.')


def recovery_facts(entry: dict) -> tuple[list[bool], dict]:
    import character_table
    import export_first_room
    import journey_battle
    return_script = None
    for start in [entry["handler"], *entry["callback_chain"]]:
        for pc in range(start, function_end(start), 4):
            insn = word(pc)
            if opcode(insn) == 0x2B and rs(insn) == 1 and (insn & 0xFFFF) == 0xA020:
                value = load_constant(rt(insn), start, pc) if rt(insn) != 0 else 0
                if value in (0x8016D214, 0x8016D258):
                    return_script = value
    # Per-member resource scripts in the custom initializers/update callbacks.
    custom = {
        6: ((10, 11), (9,)),
        16: ((11,), (9, 10)),
        30: ((11,), (12,), (9,)),
        8: ((9,), (11, 12), (10,)),
        14: ((11,), (11,)),
        15: ((10,), (9,)),
        17: ((9, 10), (10,)),
        27: ((10, 11), (9,)),
        28: ((13,), (10, 11), (10, 11)),
        29: ((9, 10, 12), (11,), (9,)),
        31: ((10, 11), (10, 11)),
    }
    call_loads = {
        6: ((0x800FA71C, 0x28), (0x800FA7E4, 0x24), (0x800FA84C, 0x2C)),
        16: ((0x800FB190, 0x2C), (0x800FB1CC, 0x24), (0x800FB2A8, 0x28)),
        30: ((0x800FE43C, 0x2C), (0x800FE488, 0x30), (0x800FE4BC, 0x24)),
        8: ((0x800FDBA8, 0x24), (0x800FDBF0, 0x2C), (0x800FDC24, 0x28), (0x800FDCFC, 0x30)),
        14: ((0x800FB5B0, 0x2C), (0x800FB5F4, 0x2C)),
        15: ((0x800FAB60, 0x28), (0x800FAB94, 0x24)),
        17: ((0x800FCDB0, 0x24), (0x800FCE98, 0x28)),
        27: ((0x800FD3A8, 0x28), (0x800FD3EC, 0x24), (0x800FD5C0, 0x2C)),
        28: ((0x800FD850, 0x34), (0x800FD898, 0x28), (0x800FD8CC, 0x28)),
        29: ((0x800FDF50, 0x24), (0x800FDF8C, 0x2C), (0x800FDFC0, 0x24), (0x800FE0D4, 0x28), (0x800FE2D8, 0x30)),
        31: ((0x800FE7C8, 0x28), (0x800FE80C, 0x28)),
    }
    dispatched = resource_script_loads(entry)
    if entry['index']==8:
        for pc,expected in {0x800FDCD4:0x8E240004,0x800FDCF4:0x8C420008,0x800FDCFC:0x8C460030,0x800FDD00:0x0C038E08}.items():
            if word(pc)!=expected:raise ValueError(f'Pretty Girl Tengaar script12 owner changed at {pc:#x}')
    if entry['index'] in custom:
        script_sets = custom[entry['index']]
        for pc, offset in call_loads[entry['index']]:
            if not any(site['load'] == pc and site['script'] == offset // 4 for site in dispatched):
                raise ValueError(f"Unite actor script binding changed at {pc:#x}")
    else:
        if return_script is None:
            raise ValueError(f"Unqualified Unite return script: {entry['index']}")
        indices = {site['script'] for site in dispatched}
        if not indices:
            raise ValueError(f"Unite has no qualified resource scripts: {entry['index']}")
        script_sets = [sorted(indices)] * entry['member_count']
    common = [] if return_script is None else journey_battle.script_at(body(), return_script-maindec.MBASE)
    by_id = {row['id']: row for row in character_table.records()}
    recovery, sources = [], []
    for member, indices in zip(entry['members'], script_sets, strict=True):
        data, source = export_first_room.source('/' + by_id[member]['sprite_file'])
        operations = list(common)
        for index in indices:
            try:
                operations.extend(journey_battle.script(data, index))
            except ValueError as err:
                raise ValueError(f"Unite {entry['index']} member {member} script {index}: {err}") from err
        recovery.append(any(op == 40 and tuple(args) == (7, 100) for op, args in operations))
        sources.append(dict(member=member, scripts=list(indices), source=source))
    return recovery, dict(return_script=return_script, members=sources)


def build_catalogue(records: list[dict], handlers: dict[int, dict]) -> dict:
    names = character_names()
    entries = []
    for record in records:
        handler = handlers.get(record["unite_id"])
        if handler is None:
            raise SystemExit(f"record {record['index']}: unite id {record['unite_id']} has no handler")
        entry = dict(record)
        entry["handler"] = handler["init"]
        entry["update"] = handler["update"]
        entry["callback_chain"] = handler["callback_chain"]
        group_loops = {
            0x800F9CE8: (0x800F9E7C, 0x1040FFE4),
            0x800FC64C: (0x800FCB68, 0x1040FFF9),
            0x800FB63C: (0x800FB824, 0x1040FFEA),
            0x800FE000: (0x800FE338, 0x1040FFF9),
        }
        entry["all_enemies"] = handler["update"] in group_loops
        if entry["all_enemies"]:
            pc, expected = group_loops[handler["update"]]
            if word(pc) != expected:
                raise ValueError(f"group target loop changed at {pc:#x}")
        entry["recovery"], entry["recovery_source"] = recovery_facts(entry)
        entry["target_reaction_updates"], entry["target_reaction_source"] = target_reaction_facts(entry)
        entry["sequence"] = queued_target_facts(entry)
        entry["member_names"] = [names.get(member, f"<{member}>") for member in record["members"]]
        for member in record["members"]:
            if member not in names:
                raise SystemExit(f"record {record['index']}: member {member} is not a character id")
        if record["index"] in DOCUMENTED_COMPOSITIONS:
            expected_name, expected_members = DOCUMENTED_COMPOSITIONS[record["index"]]
            if record["name"] != expected_name:
                raise SystemExit(f"record {record['index']}: name {record['name']!r} != {expected_name!r}")
            if set(entry["member_names"]) != set(expected_members):
                raise SystemExit(
                    f"record {record['index']}: members {entry['member_names']} != {list(expected_members)}")
        if (handler["family"] == "combined_physical"
                and handler["damage_count"] == record["member_count"]):
            entry["family"] = "combined_physical"
            entry["gate"] = handler["gate"]
            entry["damage_count"] = handler["damage_count"]
            entry["multiplier"] = handler["multiplier"]
            entry["outcome"] = "proven"
            entry["blocker"] = None
        elif handler["family"] == "combined_physical":
            entry["family"] = "combined_physical"
            entry["gate"] = handler["gate"]
            entry["damage_count"] = handler["damage_count"]
            entry["multiplier"] = handler["multiplier"]
            entry["outcome"] = "blocked"
            entry["blocker"] = {
                "reason": "handler_member_count_mismatch",
                "detail": (f"record has {record['member_count']} members but the update "
                           f"combines {handler['damage_count']}"),
            }
        else:
            entry["family"] = "custom"
            entry["gate"] = None
            entry["damage_count"] = 0
            entry["multiplier"] = 0
            entry["outcome"] = "blocked"
            entry["blocker"] = {
                "reason": "effect_family_unestablished",
                "detail": (f"update {handler['update']:#x} never reaches 0x800F9488 or "
                           f"0x800F95E8; its effect is carried by track descriptors or "
                           f"callback objects that this pack does not qualify"),
            }
        from spell_scene_source import Image
        entry["hit_gate_source"] = hit_gate_binding(entry, Image())
        binding = entry["hit_gate_source"]
        entry["hit_actor"] = (dict(kind='command_owner', member=None)
                              if binding['kind'] == 'callback_actor' else
                              dict(kind='member', member=binding['member_index'])
                              if binding['kind'] == 'member' else None)
        entry["index"] = record["index"]
        entries.append(entry)
    return {"records": entries, "handlers": handlers}


def summary(entries: list[dict]) -> dict:
    proven = [e for e in entries if e["outcome"] == "proven"]
    blocked = [e for e in entries if e["outcome"] == "blocked"]
    by_count: dict[str, int] = {}
    for entry in entries:
        key = str(entry["member_count"])
        by_count[key] = by_count.get(key, 0) + 1
    proven_by_count: dict[str, int] = {}
    for entry in proven:
        key = str(entry["member_count"])
        proven_by_count[key] = proven_by_count.get(key, 0) + 1
    return {
        "records": len(entries),
        "proven": len(proven),
        "blocked": len(blocked),
        "blocked_indices": [e["index"] for e in blocked],
        "records_by_member_count": by_count,
        "proven_by_member_count": proven_by_count,
        "distinct_unite_ids": len({e["unite_id"] for e in entries}),
        "distinct_handlers": len({e["handler"] for e in entries}),
        "individual_picker_records": sum(1 for e in entries if e["target_rule"] == "individual"),
        "bypass_records": sum(1 for e in entries if e["target_rule"] == "bypass"),
        "undecoded_name_indices": [e["index"] for e in entries if not e["name_fully_decoded"]],
        "documented_compositions": len(DOCUMENTED_COMPOSITIONS),
        "resolved_member_ids": sum(e["member_count"] for e in entries),
    }


# --- anchor verification ----------------------------------------------------
def verify_anchors() -> dict:
    report = {}
    for group, pins in PINS.items():
        rows = []
        for va, meaning in pins.items():
            actual = word(va)
            rows.append({"addr": f"{va:#010x}", "word": f"{actual:#010x}", "meaning": meaning})
        report[group] = rows
    descriptor, operands = RETURN_DESCRIPTOR
    actual = tuple(half(descriptor + 2 * i) for i in range(len(operands)))
    if actual != operands:
        raise SystemExit(f"return descriptor drift at {descriptor:#x}: {actual}")
    report["recovery_descriptor"] = [{
        "addr": f"{descriptor:#x}",
        "operands": [f"{value:#06x}" for value in actual],
        "meaning": "op40(status 7, threshold 100): party handler applies mask 0x40 and counter 1",
    }]
    # the action table and record pointers are data anchors, not instructions
    report["tables"] = [
        {"addr": f"{UNITE_POINTERS:#x}", "words": UNITE_COUNT,
         "meaning": "32 unite-record pointers; bias 1 (B+0x48 = index + 1)"},
        {"addr": f"{UNITE_ACTION_TABLE:#x}", "words": UNITE_ACTION_COUNT,
         "meaning": "unite-id -> initializer; entries 0 and 26 are null, 25 ids are used"},
    ]
    return report


def source_digest() -> dict:
    data = body()
    catalogue_region = data[
        UNITE_TABLE - maindec.MBASE: UNITE_POINTERS - maindec.MBASE + 4 * UNITE_COUNT]
    action_region = data[
        UNITE_ACTION_TABLE - maindec.MBASE: UNITE_ACTION_TABLE - maindec.MBASE + 4 * UNITE_ACTION_COUNT]
    return {
        "file": "MAIN.EXE",
        "catalogue_region": f"{UNITE_TABLE:#x}..{UNITE_POINTERS + 4 * UNITE_COUNT:#x}",
        "catalogue_region_sha256": hashlib.sha256(catalogue_region).hexdigest(),
        "action_table_region": f"{UNITE_ACTION_TABLE:#x}..{UNITE_ACTION_TABLE + 4 * UNITE_ACTION_COUNT:#x}",
        "action_table_region_sha256": hashlib.sha256(action_region).hexdigest(),
        "lba": maindec.EXE_LBA,
        "size_with_header": maindec.EXE_SIZE,
        "header": maindec.EXE_HEADER,
        "body_bytes": len(data),
        "image_base": f"{maindec.MBASE:#010x}",
        "body_sha256": hashlib.sha256(data).hexdigest(),
    }


# --- packet -----------------------------------------------------------------
RULES = {
    "membership": {
        "matcher": "0x800F91c0",
        "commit": "0x800ede58",
        "summary": (
            "Execution re-runs the member matcher with the actor's B+0x48 ordinal. For each "
            "member id in record order it walks the party A records from index 1 and marks the "
            "first record whose A+0x00 equals the id with B+0x46 = 1, clears that record's "
            "A+0x40 flag word and writes the chosen target to B+0x49. The loop bound is the "
            "record's count byte, so a 3- or 4-member record marks 3 or 4 participants. The "
            "matcher does not consume a participant and does not check liveness; the command "
            "commit's pre-check is what guarantees every member is present and selectable."),
        "ordinal_bias": 1,
        "mark": "B+0x46 = 1",
        "clears": "A+0x40 = 0",
        "target_write": "B+0x49",
    },
    "reservation": {
        "availability": "0x800ef104",
        "commit": "0x800ede58",
        "cancel_restore": "0x800eb050",
        "summary": (
            "No participant can be double-booked. The command UI keeps one word per party slot "
            "at UI+0xB4+4*slot meaning 'still selectable' (1) or 'already assigned' (0); sleep "
            "clears it when the table is built (B+0x4A & 0x20). The unite availability "
            "enumerator accepts a member only when that flag is 1, 0x800F8680 accepts the "
            "participant index (B+0x45 == 0 and B+0x12-B+0x4E >= 0) and B+0x4A & 0x61 is clear. "
            "The commit writes command 4, the one-based record ordinal and the target into "
            "every member and clears all their flags, so a second command cannot select them. "
            "Stepping back restores the flag."),
        "slot_flag": "UI+0xB4+4*slot (1 = still selectable, 0 = assigned)",
        "eligibility": "0x800F8680 (1 <= index <= total, B+0x45 == 0, B+0x12-B+0x4E >= 0)",
        "status_mask": "B+0x4A & 0x61",
        "command": "B+0x47 = 4 (Unite)",
        "ordinal": "B+0x48 = record index + 1",
        "target": "B+0x49",
    },
    "target": {
        "picker_flag": "record+0x16 bit1",
        "individual": "0x800EDB18",
        "bypass": "0x800EDE58",
        "validator": "0x800F8680",
        "repair": "0x800F6344",
        "summary": (
            "Bit1 set (24 records) selects the individual target picker; confirmation writes "
            "the chosen actor index to participant B+0x49. Bit1 clear (8 records) bypasses the "
            "picker and reuses the actor's existing B+0x49. The execution validator dispatches "
            "on the record's low two flag bits: value 3 validates the chosen enemy index and, "
            "when invalid, repairs it by scanning enemy indices party_count+1..total for the "
            "first record with A+0x05 == 0, B+0x45 == 0 and B+0x12-B+0x4E > 0; a repaired index "
            "is written back, and no candidate rejects the unite. Value 1 instead requires the "
            "living-enemy count at battle state +0x2C to be positive."),
        "repair_scan": "enemy indices party_count+1..total, ascending",
        "repair_candidate": "A+0x05 == 0, B+0x45 == 0, B+0x12-B+0x4E > 0",
        "reject": "no candidate -> the unite is refused, not retargeted silently",
    },
    "execution": {
        "helper_hit_flag": "0x800F9488",
        "helper_target_active": "0x800F95E8",
        "apply": "0x800E1654",
        "slots": "0x800F9390",
        "wait": "0x800F9718",
        "free": "0x800C2DC0",
        "summary": (
            "A combined-physical update sums one physical result per participant in record "
            "order and applies sum*multiplier/10 once through 0x800E1654. 0x800F9488 gates on "
            "the leader's A+0x40 bit1 (the hit flag) and clears each member's bit; 0x800F95E8 "
            "gates on the target's B+0x45 == 0. 0x800F9390 records one completion slot per "
            "member from A+0x40 bit2, and 0x800F9718 returns 1 only when every slot is set; the "
            "update then frees its state. The two helpers are the only proven effect families "
            "in this catalogue."),
        "combine": "sum(physical(member, target)) * multiplier / 10",
        "commit": "one 0x800E1654 call",
        "completion": "all member slots set before the state is freed",
    },
    "recovery": {
        "ordinary_return": "0x8016D214",
        "recovery_return": "0x8016D258",
        "descriptor": "0x8016D284 op40(7,100)",
        "handler": "0x800E6AB8",
        "setter": "0x800E05B0",
        "boundary": "0x800F657C..0x800F65B8",
        "clear": "0x800E0778",
        "summary": (
            "Recovery follows each member's selected scripts and return chain. Talisman uses "
            "0x8016D214 without recovery; Fisherman uses 0x8016D258 with op40(7,100). The party "
            "handler applies status mask 0x40 and counter 1 only to a member receiving that command; the "
            "round boundary decrements the counter while retaining the flag and clears the "
            "class on the following boundary. While 0x40 is set the participant is excluded "
            "from Attack, Rune and Unite (B+0x4A & 0x61 is nonzero for every command picker), "
            "while Item and Defend stay available. The party Turtle rune 0x19 check at "
            "0x800E6BC8 skips the new status and its RNG draw; other applications consume a draw "
            "even at a threshold of 100."),
        "mask": "0x40",
        "counter": "B+0x4D = 1",
        "disabled": ["attack", "rune", "unite"],
        "allowed": ["item", "defend"],
        "boundary_order": "retain one round, clear on the next",
    },
    "resume": {
        "reset": "0x800F6BF8..0x800F6C2C",
        "summary": (
            "The round reset clears command B+0x47, unite ordinal B+0x48 and target B+0x49 for "
            "every combatant record, so a rolled-back or completed unite boundary leaves the "
            "next round with ordinary command selection. The port's rollback restores the same "
            "three bytes for the reserved participants instead of waiting for the reset."),
        "cleared": ["B+0x47", "B+0x48", "B+0x49"],
    },
}


def build_packet(entries: list[dict]) -> dict:
    packet = {
        "schema": "suikoden-unite-catalogue/6",
        "version": VERSION,
        "task": TASK,
        "base_commit": BASE,
        "source": source_digest(),
        "tables": {
            "records": f"{UNITE_TABLE:#x}",
            "stride": UNITE_STRIDE,
            "count": UNITE_COUNT,
            "pointers": f"{UNITE_POINTERS:#x}",
            "actions": f"{UNITE_ACTION_TABLE:#x}",
            "action_slots": UNITE_ACTION_COUNT,
            "name_bytes": NAME_BYTES,
        },
        "rules": RULES,
        "records": entries,
        "summary": summary(entries),
        "blockers": [
            {
                "record": e["index"],
                "name": e["name"],
                "unite_id": e["unite_id"],
                "update": f"{e['update']:#x}",
                "reason": e["blocker"]["reason"],
                "detail": e["blocker"]["detail"],
            }
            for e in entries if e["outcome"] == "blocked"
        ],
        "port_contract": {
            "schema": "suikoden-unite-boundary/3",
            "rng": "battle_rules.Draws (existing coordinator stream)",
            "order": [
                "plan: match members, validate target (repair per 0x800F6344), require every participant selectable",
                "commit: write command 4, one-based ordinal, target; clear the selectable flags",
                "impact: one physical result per participant in record order for each selected enemy; stage sum*multiplier/10 before HP commits",
                "finish: apply recovery mask 0x40/counter 1 to living members selected by their source scripts",
                "undo: restore the prior command bytes/flags and the draw cursor",
            ],
            "rollback": [
                "KO or interruption of any participant before the commit or before impact",
                "target invalid with no repair candidate",
                "caller cancel or retarget before impact",
                "partial draw exhaustion inside impact",
            ],
            "boundaries": [
                "the source does not re-validate participants at impact; the port refuses and rolls back rather than combine a partially-defined set",
                "a bypass record's target is not validated by the source; the port refuses a stale or non-enemy target",
                "records with an unproven effect family refuse instead of using the two-member fallback",
            ],
        },
    }
    packet["content_sha256"] = sha256(canonical({**packet, "content_sha256": ""}))
    return packet


# --- serialization ----------------------------------------------------------
def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def serialize(value) -> bytes:
    return (json.dumps(value, indent=1, sort_keys=True, ensure_ascii=False) + "\n").encode()


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# --- writes / checks --------------------------------------------------------
def collect() -> tuple[dict, list[dict]]:
    records = extract_records()
    handlers = classify_handlers(handler_table())
    built = build_catalogue(records, handlers)
    entries = built["records"]
    verify_anchors()
    if summary(entries)["individual_picker_records"] != 24:
        raise SystemExit("picker record count drifted from the established 24")
    bypass = tuple(e["index"] for e in entries if e["target_rule"] == "bypass")
    if bypass != PICKER_BYPASS_INDICES:
        raise SystemExit(f"bypass indices drifted: {bypass}")
    return build_packet(entries), entries


def write_outputs() -> None:
    packet, _ = collect()
    (ROOT / CATALOGUE_PATH).parent.mkdir(parents=True, exist_ok=True)
    (ROOT / CATALOGUE_PATH).write_bytes(serialize(packet))
    import re
    data_text = (ROOT / DATA_PATH).read_text()
    data_text = re.sub(r'unite_catalogue_file_sha256 = "[^"]+";', f'unite_catalogue_file_sha256 = "{file_hash(ROOT / CATALOGUE_PATH)}";', data_text, count=1)
    data_text = re.sub(r'unite_catalogue_canonical_sha256 = "[^"]+";', f'unite_catalogue_canonical_sha256 = "{sha256(canonical(packet))}";', data_text, count=1)
    (ROOT / DATA_PATH).write_text(data_text)
    print(f"wrote {CATALOGUE_PATH} records={packet['summary']['records']} "
          f"proven={packet['summary']['proven']} blocked={packet['summary']['blocked']}")
    print(f"updated digests in {DATA_PATH}")


def check_outputs() -> None:
    packet, _ = collect()
    stored_bytes = (ROOT / CATALOGUE_PATH).read_bytes()
    stored = json.loads(stored_bytes)
    if stored != packet:
        raise SystemExit("catalogue asset drift: rerun without --check")
    if stored["base_commit"] != BASE or stored["schema"] != "suikoden-unite-catalogue/6":
        raise SystemExit("catalogue base/schema drift")
    if sha256(canonical({**stored, "content_sha256": ""})) != stored["content_sha256"]:
        raise SystemExit("catalogue content identity mismatch")
    data_zig = (ROOT / DATA_PATH).read_text()
    for expected in (
        'pub const unite_catalogue_json = @embedFile("battle_systems/unite_catalogue.json");',
        f'pub const unite_catalogue_file_sha256 = "{file_hash(ROOT / CATALOGUE_PATH)}"',
        f'pub const unite_catalogue_canonical_sha256 = "{sha256(canonical(packet))}"',
    ):
        if expected not in data_zig:
            raise SystemExit(f"data.zig digest drift: missing {expected}")
    print("checked catalogue identity and data.zig digests")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="verify outputs without writing")
    args = parser.parse_args(argv)
    if args.check:
        check_outputs()
        return 0
    write_outputs()
    check_outputs()
    return 0


if __name__ == "__main__":
    sys.exit(main())
