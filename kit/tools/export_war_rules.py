#!/usr/bin/env python3
"""Export nine source-initialized war scenarios and executable rule parameters."""
from __future__ import annotations

import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import export_common as _common
import war_text
from export_common import (
    atomic_write,
    canonical,
    file_hash,
    identified,
    jsonl_bytes,
    run_exporter,
    sha256,
)
from mipsdec import jtarget, sx16


def serialize(value) -> bytes:
    return _common.serialize(value, ensure_ascii=False)

SCHEMA = "suikoden-war-rules/4"
FIXTURE_SCHEMA = "suikoden-war-rule-fixtures/1"
SESSION_FIXTURE_SCHEMA = "suikoden-war-session-fixtures/1"
REPORT_SCHEMA = "suikoden-war-rule-report/1"
OUTPUTS = (
    "kit/data/reports/war_rules.json",
    "kit/data/registry/extract_war_rules.jsonl",
    "game/assets/war/scenarios.json",
    "game/tests/fixtures/war_rules.json",
    "game/tests/fixtures/war_sessions.json",
)
NAMES = {
    "WAR_KUWA.BIN": "pannu_yakuta", "WAR_GARA.BIN": "garan",
    "WAR_SCA1.BIN": "scarleticia_pollen", "WAR_SCA2.BIN": "scarleticia_antidote",
    "WAR_TEO1.BIN": "teo_before_fire_spear", "WAR_TEO2.BIN": "teo_fire_spear",
    "WAR_KITA.BIN": "northern_checkpoint", "WAR_SHAS.BIN": "shasarazade",
    "WAR_LAST.BIN": "gregminster",
}
# Measured by the original fixture and retained in the packet's existing provenance.
SETUP_CLOCK_SAMPLES = {
    "WAR_KUWA.BIN": 0x8B62, "WAR_GARA.BIN": 0x7F1E, "WAR_SCA1.BIN": 0x3F46,
    "WAR_SCA2.BIN": 0x77A2, "WAR_TEO1.BIN": 0x4078, "WAR_TEO2.BIN": 0x4078,
    "WAR_KITA.BIN": 0x567A, "WAR_SHAS.BIN": 0x716E, "WAR_LAST.BIN": 0x68D0,
}
HELPERS = ("disc.py", "war_text.py", "war_strings.py", "war_graphics.py", "war_map.py",
           "lzss.py", "mipsdec.py", "vab_tones.py", "vag_extract.py", "export_war_content.py")
STATE_NAMES = {
    0: "idle", 1: "reset", 2: "move", 3: "melee", 4: "ranged", 5: "effect",
    6: "impact", 7: "retiring", 8: "retreat", 9: "special_wait",
    10: "special_move", 11: "inert", 12: "finished",
}


class RuleError(ValueError):
    pass


def source_record(name: str) -> dict:
    record = war_text._ws.war_files()[name]
    raw = war_text.load(name)
    return {"file": war_text.WAR_DIR + name, "lba": record["lba"], "size": len(raw), "sha256": sha256(raw)}


def address(raw: bytes, pc: int) -> int:
    high = struct.unpack_from("<I", raw, pc - 0x80010000)[0] & 0xFFFF
    word = struct.unpack_from("<I", raw, pc - 0x80010000 + 4)[0]
    immediate = word & 0xFFFF
    if immediate & 0x8000:
        immediate -= 0x10000
    return ((high << 16) + immediate) & 0xFFFFFFFF


def signed_coordinate(word: int) -> int:
    value = (word << 16) & 0xFFFFFFFF
    if value & 0x80000000:
        value -= 0x100000000
    return value >> 4


def unit_record(raw: bytes) -> dict:
    words = struct.unpack("<7I", raw)
    if len(raw) != 28:
        raise RuleError("unit record stride changed")
    state = raw[0x18]
    if state not in STATE_NAMES:
        raise RuleError(f"unsupported initial unit state {state}")
    return {
        "x": signed_coordinate(words[0]), "y": signed_coordinate(words[1]),
        "target_x": signed_coordinate(words[2]), "target_y": signed_coordinate(words[3]),
        "velocity_x": signed_coordinate(words[4]), "velocity_y": signed_coordinate(words[5]),
        "state": STATE_NAMES[state], "state_code": state,
        "secondary_state": raw[0x19], "counter": struct.unpack_from("<h", raw, 0x1A)[0],
    }


def initialize(name: str, raw: bytes, loss_divisor: int) -> dict:
    def word(offset):
        return struct.unpack_from("<I", raw, offset)[0]

    if word(0x5E8) >> 16 != 0x3402 or word(0x5AC) >> 26 != 3:
        raise RuleError(f"unrecognized troop initialization: {name}")
    parameter = word(0x5E8) & 0xFFFF
    total_address = address(raw, 0x8001059C)
    parameter_address = address(raw, 0x800105EC)
    # Keep the historical diagnostic offsets in the serialized witness.
    table_address = address(raw, 0x8001857C)
    count_address = address(raw, 0x80018554)
    total = 0
    sides = [{"total_records": 0, "remaining_records": 0, "records": []} for _ in range(2)]
    recruit_query = jtarget(0x800105AC, word(0x5AC))
    if recruit_query == 0x8001AEFC:
        # The retained ordinary scenario starts with every recruit enabled and zero draws.
        leaders_base = address(raw, 0x800105C0) - war_text.OVERLAY_BASE
        total = sum(struct.unpack_from("<H", raw, leaders_base + 6 * member)[0] for member in range(108))
        total &= 0xFFFF
        if word(0x8AD0) != (0x34030000 | loss_divisor) or word(0x8B08) != 0xA6020000:
            raise RuleError(f"unrecognized unit count writer: {name}")
        targets = address(raw, 0x800176F8) - war_text.OVERLAY_BASE
        movement_instructions = {
            0x8CC4: 0x244200B4, 0x8D3C: 0x2403FF4C, 0x8DC0: 0x24420046,
            0x771C: 0x0C005D28, 0x7614: 0x24420032, 0x7658: 0x0C006026,
            0x765C: 0x2446000C, 0x7674: 0x34030002, 0x767C: 0xA0430018,
        }
        if any(word(offset) != expected for offset, expected in movement_instructions.items()):
            raise RuleError(f"unrecognized initial unit movement writer: {name}")
        for side, troops in enumerate((total, parameter)):
            count = 1 + troops // loss_divisor
            x = sx16(word(0x8CC4 if side == 0 else 0x8D3C)) << 4
            y = sx16(word(0x8DC0)) << 4
            target_x, _ = struct.unpack_from("<hh", raw, targets + 4 * side)
            target_y = sx16(word(0x7614))
            speed = sx16(word(0x765C))
            dx = target_x * 16 - x
            dy = target_y * 16 - y
            counter = abs(dx) // speed
            if not counter or abs(dy) >= abs(dx):
                raise RuleError(f"unrecognized initial movement axis: {name}/{side}")
            step_x = speed if dx > 0 else -speed
            step_y = (abs(dy) // counter) * (1 if dy >= 0 else -1)
            target = (target_x & 0xFFFF) | (target_y << 16)
            record = struct.pack("<6iBBh", x, y, step_x, step_y, target, 0, word(0x7674) & 0xFF, 0, counter)
            unit = unit_record(record)
            sides[side] = {"total_records": count, "remaining_records": count,
                           "records": [dict(unit) for _ in range(count)]}
    elif recruit_query not in (0x8001AF10, 0x8001AFF8):
        raise RuleError(f"unrecognized scripted troop query: {name}")
    return {
        "initial_army_troops": total,
        "scenario_parameter": parameter,
        "initial_stage": 5,
        "sides": sides,
        "proof": {
            "initializer": "MAIN/overlay 0x8001053C then scenario setup 0x80010990 under bounded instruction execution",
            "total_address": total_address, "parameter_address": parameter_address,
            "unit_table_address": table_address, "unit_count_address": count_address,
            "record_stride": 28, "coordinate_rule": "signed((word << 16) >> 20)",
            "setup_instruction_calls": SETUP_CLOCK_SAMPLES[name],
        },
    }


def lifecycle(raw: bytes, initial: dict) -> dict:
    instruction = struct.unpack_from("<I", raw, 0x4A8)[0]
    if instruction >> 26 != 0x03:
        raise RuleError("scenario phase dispatcher is not a direct call")
    entry = 0x80000000 | ((instruction & 0x03FFFFFF) << 2)
    phase_address = address(raw, entry)
    table_address = address(raw, entry + 0x30)
    table_offset = table_address - war_text.OVERLAY_BASE
    table = list(struct.unpack_from("<17I", raw, table_offset))
    if any(not war_text.OVERLAY_BASE <= pointer < war_text.OVERLAY_BASE + len(raw) for pointer in table):
        raise RuleError("scenario phase table points outside its overlay")
    scripted = all(side["total_records"] == 0 for side in initial["sides"])
    transitions = []
    for phase, ticks, following in ((0, 1, 2), (2, 128, 3), (3, 248, 4), (4, 41, 5),
                                    (5, 198, 6), (6, 128, 7), (7, 1, 8), (8, 62, 13),
                                    (10, 81, 13), (11, 61, 7)):
        transitions.append({"phase": phase, "ticks": ticks, "next": following})
    transitions.append({"phase": 14, "ticks": 1, "next": 14, "terminal": True})
    return {
        "kind": "scripted" if scripted else "unit_battle",
        "phase_entry": entry, "phase_state_address": phase_address,
        "main_state_address": address(raw, 0x80010368),
        "phase_table_address": table_address, "phase_table": table,
        "wait_phase": 9, "dispatch_phase": 13, "confirmation_count": 2 if scripted else 4,
        "second_confirmation_phase": 14, "completion_main_phase": 0,
        "transitions": transitions,
        "proof": "Direct 0x800104A8 call target and 17-entry phase table; zero-force scenes reach two phase-9 confirmations at call 1161, ordinary battles reach four at call 1576 before phase-14 cleanup.",
    }


def leaders(raw: bytes) -> list[dict]:
    result = []
    stats_offset = address(raw, 0x800105C0) - war_text.OVERLAY_BASE - 4
    members_offset = stats_offset + 0x288
    if stats_offset < 0 or stats_offset + 108 * 6 > len(raw) or members_offset + 108 > len(raw):
        raise RuleError("combatant/team table is outside the overlay")
    members = [int.from_bytes(raw[members_offset + index:members_offset + index + 1], "little") for index in range(108)]
    for index, (offset, row) in enumerate(war_text.leader_records(raw)):
        record_offset = stats_offset + index * 6
        troops = struct.unpack_from("<H", raw, record_offset + 4)[0]
        fields = list(raw[record_offset:record_offset + 4])
        result.append({"id": index, "record_offset": record_offset, "troops": troops,
                       "flags": fields[0], "unit_class": fields[1], "attack_class": fields[2], "variant": fields[3],
                       "member_ids": members[index * 3:index * 3 + 3] if index < 36 else []})
    return result


def attack_rows(raw: bytes) -> list[dict]:
    result = []
    for offset, flags, text in war_text.attack_table(raw):
        _flags, _name, first, second = struct.unpack_from("<4I", raw, offset)
        result.append({"offset": offset, "flags": flags, "name": text,
                       "parameter0": first, "parameter1": second})
    return result


def enemy_policy(raw: bytes) -> dict:
    attacks = war_text.attack_table(raw)
    range_offset = attacks[0][0] + len(attacks) * 16
    map_offset = range_offset + 12
    ranges = [[raw[range_offset + index * 2], raw[range_offset + index * 2 + 1]] for index in range(5)]
    action_map = list(raw[map_offset:map_offset + 9])
    if len(action_map) != 9 or any(code > 2 for code in action_map):
        raise RuleError("enemy action map is invalid")
    if any(start > end or end >= len(attacks) for start, end in ranges):
        raise RuleError("enemy attack range is invalid")
    return {"range_address": war_text.OVERLAY_BASE + range_offset,
            "action_map_address": war_text.OVERLAY_BASE + map_offset,
            "ranges": ranges, "action_map": action_map,
            "selector": "0x8001AFDC; candidate=start+rand//(32767//span); retry used candidates; reset after group 4"}


def ordinary_contract() -> dict:
    return {
        "action_map": [2, 0, 1, 1, 2, 0, 0, 1, 2],
        "strength": "P=teamStrength+player_troops//3000; E=enemyAttackPower+enemy_troops//3000; T=teamStrength; Q=enemyAttackPower; R=rand//541",
        "cells": [
            {"code": 0, "category": 0, "enemy_survivors": "130P+R-30", "player_survivors": "80P+R-30"},
            {"code": 0, "category": 1, "enemy_survivors": "120P+R-30", "player_survivors": "0"},
            {"code": 0, "category": 2, "enemy_survivors": "200T", "player_survivors": "0"},
            {"code": 1, "category": 0, "enemy_survivors": "0", "player_survivors": "200Q"},
            {"code": 1, "category": 1, "enemy_survivors": "80P+R-30", "player_survivors": "130P+R-30"},
            {"code": 1, "category": 2, "enemy_survivors": "0", "player_survivors": "120E+R-30"},
            {"code": 2, "category": 0, "enemy_survivors": "100P+R-30", "player_survivors": "100E+R-30"},
            {"code": 2, "category": 1, "enemy_survivors": "90P+R-30", "player_survivors": "90E+R-30"},
            {"code": 2, "category": 2, "enemy_survivors": "200T", "player_survivors": "0"},
        ],
        "source": "0x80014F24 team category; 0x8001AA30 strength; 0x8001B610 action matrix and ratio inputs",
    }


def special_contract() -> dict:
    return {
        "teams": {"24": "thieves", "32": "strategists", "33": "ninja", "34": "dragon_knights", "35": "merchants"},
        "ninja": {"effect": "reveal selected enemy attack", "source": "0x8002051C"},
        "thieves": {"roll": "rand//8191 >= 3", "reward": "min(2000,999999-current_bits)", "source": "0x80020954;0x80020E1C"},
        "strategists": {"effect": "store teamStrength as charge boost", "source": "0x80021220;0x8001AA30"},
        "dragon_knights": {"roll": "rand//8191 != 0", "damage": "quarter if player_reference < enemy_troops//8 else eighth; player loss=player_troops+damage; enemy loss=damage", "source": "0x800213D0;0x800215A4;0x800218B4"},
        "merchants": {"effect": "enemy_troops//4 loss unless enemy attack type==1", "source": "0x80021AF4;0x80021B44"},
    }


def record_loss_rule(raw: bytes) -> tuple[int, int]:
    matches = []
    for offset in range(0x8000, 0x8500, 4):
        mask, branch, divisor = struct.unpack_from("<3I", raw, offset)
        if (mask, branch, divisor >> 16) != (0x3083FFFF, 0x14600008, 0x3402):
            continue
        if (struct.unpack_from("<2I", raw, offset + 0x58) == (branch, divisor)
                and all(struct.unpack_from("<I", raw, offset + step)[0] == 0x0062001B
                        for step in (0x28, 0x7C))):
            matches.append((war_text.OVERLAY_BASE + offset, divisor & 0xFFFF))
    if len(matches) != 1 or matches[0][1] == 0:
        raise RuleError("war record loss divisor is unresolved")
    return matches[0]


def validate(packet: dict) -> None:
    if packet.get("schema") != SCHEMA or sha256(canonical(dict(packet, content_sha256=""))) != packet.get("content_sha256"):
        raise RuleError("war rule packet identity/schema mismatch")
    scenarios = packet.get("scenarios", [])
    if len(scenarios) != 9 or [row["selector"] for row in scenarios] != list(range(9)):
        raise RuleError("war scenario selector inventory mismatch")
    costs = packet.get("troops_per_record", [])
    if len(costs) != len(scenarios) or any(type(cost) is not int or not 0 < cost <= 65535 for cost in costs):
        raise RuleError("war record loss divisors are invalid")
    for scenario in scenarios:
        if scenario["id"] != NAMES[war_text.SELECTOR_ORDER[scenario["selector"]]]:
            raise RuleError("war scenario id mismatch")
        if scenario.get("content_sha256") != sha256(canonical(dict(scenario, content_sha256=""))):
            raise RuleError("war scenario content identity mismatch")
        lifecycle_row = scenario["lifecycle"]
        empty = all(side["total_records"] == 0 for side in scenario["initial"]["sides"])
        if lifecycle_row["kind"] != ("scripted" if empty else "unit_battle") or len(lifecycle_row["phase_table"]) != 17:
            raise RuleError("war lifecycle/source force mismatch")
        if empty and ([row["phase"] for row in lifecycle_row["transitions"]] != [0, 2, 3, 4, 5, 6, 7, 8, 10, 11, 14]
                      or lifecycle_row["confirmation_count"] != 2):
            raise RuleError("war scripted transition contract mismatch")
        for side in scenario["initial"]["sides"]:
            if side["total_records"] != side["remaining_records"] or side["total_records"] != len(side["records"]):
                raise RuleError("war initial side counts mismatch")
            for record in side["records"]:
                if record["state_code"] not in STATE_NAMES:
                    raise RuleError("war initial record state unsupported")


def build() -> dict:
    scenarios = []
    loss_rules = []
    for selector, name in enumerate(war_text.SELECTOR_ORDER):
        raw = war_text.load(name)
        loss_rule = record_loss_rule(raw)
        loss_rules.append(loss_rule)
        initial = initialize(name, raw, loss_rule[1])
        scenarios.append(identified({"selector": selector, "id": NAMES[name], "source": source_record(name),
                                     "initial": initial, "lifecycle": lifecycle(raw, initial),
                                     "attacks": attack_rows(raw),
                                     "enemy_policy": enemy_policy(raw) if any(side["total_records"] for side in initial["sides"]) else None,
                                     "leaders": leaders(raw)}))
    base = war_text.load("WAR_GARA.BIN")
    packet = identified({
        "schema": SCHEMA, "id": "war_scenarios", "target": "Suikoden I US v1.1 SLUS_002.92",
        "selector_contract": "MAIN 0x8016F258 and loader 0x80125E5C select exactly nine overlays; WAR1.BIN is excluded.",
        "leader_contract": {"record_bytes": 6, "record_count": 108,
                            "fields": "108 combatant stat records: four stat bytes plus u16 troop contribution; 36 three-member team rows are at combatant_table+0x288",
                            "command_binding": "0x80014F24 filters teams by first recruited member category; 0x8001AA30 evaluates team strength; 0x8001B610 resolves the exported 3x3 action matrix.",
                            "leaders": leaders(base)},
        "state_contract": {"names": STATE_NAMES,
                           "record": "28-byte source records with named position/target/velocity/state/counter; runtime pointers are not persisted"},
        "rng_contract": "Caller-owned source rand inputs in original consumption order; reject invalid commands before any draw.",
        "casualty_contract": "Each overlay converts nonzero troop loss to floor(loss/troops_per_record)+1 records with u8 wrapping. GARA 0x80018478 computes max(0,(previous-current)*initial_troops/previous), with previous==0 returning initial_troops. Scripted noncombat results force zero casualties.",
        "ordinary_contract": ordinary_contract(), "special_contract": special_contract(),
        "troops_per_record": [cost for _, cost in loss_rules],
        "scenarios": scenarios,
        "variant_matrix": [
            {"selector": row["selector"], "id": row["id"],
             "initial_army_troops": row["initial"]["initial_army_troops"],
             "scenario_parameter": row["initial"]["scenario_parameter"],
             "side_record_counts": [side["total_records"] for side in row["initial"]["sides"]],
             "troop_loss_routine": routine, "troops_per_record": cost,
             "attack_offsets": [attack["offset"] for attack in row["attacks"]],
             "lifecycle": row["lifecycle"]["kind"], "scenario_content_sha256": row["content_sha256"],
             "policy": "source-timed scripted completion" if row["lifecycle"]["kind"] == "scripted" else "shared team command engine with nine-cell ordinary matrix and five special families"}
            for row, (routine, cost) in zip(scenarios, loss_rules, strict=True)
        ],
    })
    validate(packet)
    reference_cases = []
    for scenario in scenarios:
        reference_cases.append({"selector": scenario["selector"], "id": scenario["id"],
                                "initial": scenario["initial"], "expected": "source initialized state exactly"})
    fixture = identified({"schema": FIXTURE_SCHEMA, "id": "war_source_initialization_cases",
                          "packet_content_sha256": packet["content_sha256"], "cases": reference_cases})
    registry = [
        {"id": "WAR01", "stage": "X_WAR_RULES", "class": "battle", "claim": "Exactly nine selector-reachable war overlays are exported in MAIN selector order with source identity, attacks and source-initialized two-side unit records; WAR1.BIN is not a tenth scenario.", "addr": "MAIN:0x8016F258;MAIN:0x80125E5C;OVERLAY:0x8001053C;OVERLAY:0x80010990", "evidence": "proven", "source": "kit/tools/export_war_rules.py;kit/tools/war_text.py;kit/tests/test_war_rules.py", "superseded_by": "", "note": "Initial state is produced by bounded original initialization/setup rather than inferred from labels."},
        {"id": "WAR02", "stage": "X_WAR_RULES", "class": "battle", "claim": "The 108 six-byte records are combatant stat/troop-contribution rows consumed by team-strength routine 0x8001AA30 through 36 three-member teams at combatant_table+0x288. They are not per-unit command definitions. Live army records separately use a 28-byte stride with coordinates, state and counter.", "addr": "OVERLAY:0x800105AC;OVERLAY:0x80018530;OVERLAY:0x8001AA30", "evidence": "proven", "source": "kit/tools/export_war_rules.py;kit/tools/war_text.py;kit/tests/test_war_rules.py", "superseded_by": "", "note": "The table base is resolved from 0x800105C0; GREGMINSTER is four bytes earlier than GARA. Team commands bind through first recruited category and team strength, never combatant index alone."},
        {"id": "WAR03", "stage": "X_WAR_CONTENT", "class": "graphics", "claim": "War map cells are row-major u16 values selecting page=code>>6 and 32x32 tile=code&63 within decoded 128x128 pages and the descriptor CLUT.", "addr": "MAIN:0x800C4514;MAIN:0x8014CEB4", "evidence": "proven", "source": "kit/tools/export_war_content.py;kit/tools/war_map.py;kit/tests/test_war_content.py", "superseded_by": "", "note": "Battlefield and sky groups preserve independent cell grids and page identities."},
        {"id": "WAR04", "stage": "X_WAR_CONTENT", "class": "audio", "claim": "WAR.VA/WAR.VB form a version-6 VAB with validated program/tone/sample references; the content manifest carries their identities without executing audio.", "addr": "DATA/16_WAR/WAR.VA;DATA/16_WAR/WAR.VB", "evidence": "proven", "source": "kit/tools/export_war_content.py;kit/tools/vab_tones.py;kit/tools/vag_extract.py", "superseded_by": "", "note": "XA2 identity is separate from the VAB effect bank and requires the platform's CD-XA path."},
        {"id": "WAR05", "stage": "X_WAR_RULES", "class": "battle", "claim": "SCA1, TEO1 and TEO2 have zero-force scripted lifecycles, not empty unit battles. Their direct scenario phase entries and 17-entry tables drive two phase-9 confirmations and phase-14 cleanup at source call 1161; this establishes scene completion, not an in-overlay victory/defeat flag.", "addr": "OVERLAY:0x800104A8;OVERLAY:0x800102FC;SCA1:0x80025808;TEO1:0x80025878;TEO2:0x80025A58", "evidence": "proven", "source": "kit/tools/export_war_rules.py;kit/tests/test_war_rules.py;game/tests/war.zig;game/tests/war_session.zig", "superseded_by": "", "note": "Bounded original phase execution uses explicit callback objects. Runtime snapshots retain phase, previous phase, clock and confirmation count."},
        {"id": "WAR06", "stage": "X_WAR_RULES", "class": "battle", "claim": "Each overlay converts nonzero troop loss to floor(loss/troops_per_record)+1 records with u8 wrapping. Troop casualties use max(0,(previous_records-current_records)*initial_troops/previous_records), with previous_records==0 returning initial_troops.", "addr": "OVERLAY:0x8001839C;OVERLAY:0x800183B0;OVERLAY:0x80018498;OVERLAY:0x80018478", "evidence": "proven", "source": "kit/tools/export_war_rules.py;kit/tests/test_war_rules.py;game/src/war.zig;game/tests/war.zig", "superseded_by": "", "note": "Both sides use the same divisor within each overlay. In selector order the divisors are 300, 300, 400, 400, 450, 450, 450, 500 and 600. Scripted noncombat results carry zero casualties."},
        {"id": "WAR07", "stage": "X_WAR_RULES", "class": "battle", "claim": "Ordinary war commands use first-recruited category availability and team strength, then the shared nine-cell action matrix. Enemy attack selection uses five range pairs, a used set, and reset after group 4.", "addr": "OVERLAY:0x80014F24;OVERLAY:0x8001AA30;OVERLAY:0x8001AFDC;OVERLAY:0x8001B610", "evidence": "proven", "source": "kit/tools/export_war_rules.py;game/src/war.zig;game/tests/war.zig", "superseded_by": "", "note": "All nine cells have source-measured expectations; all 36 GARA team strengths and category lists are independently checked."},
        {"id": "WAR08", "stage": "X_WAR_RULES", "class": "battle", "claim": "The five special families are distinct: ninja reconnaissance, thief rand//8191>=3 reward, strategist strength boost, dragon-knight eighth/quarter two-sided ratio, and merchant quarter loss unless enemy type 1.", "addr": "OVERLAY:0x8002051C;OVERLAY:0x80020954;OVERLAY:0x80020E1C;OVERLAY:0x80021238;OVERLAY:0x800213D0;OVERLAY:0x800215A4;OVERLAY:0x800218B4;OVERLAY:0x80021B44", "evidence": "proven", "source": "kit/tools/export_war_rules.py;game/src/war.zig;game/tests/war.zig", "superseded_by": "", "note": "Dragon roll zero has no effect; player loss includes current troops plus dragon damage. Thief reward is capped at 999999 bits."},
        {"id": "WAR09", "stage": "X_WAR_CONTENT", "class": "graphics", "claim": "War atlas scripts are executed by MAIN 0x80146BB4 and export frame, width, height, secondary and flags; unit rendering samples indexed source rectangles rather than scaling the whole 128x128 atlas.", "addr": "MAIN:0x80146BB4", "evidence": "proven", "source": "kit/tools/export_war_content.py;kit/tests/test_war_content.py;game/src/war_view.zig;game/tests/war_view.zig", "superseded_by": "", "note": "Both army atlases per scenario require nonempty pose lists; effect atlases may be empty."},
    ]
    report = {
        "schema": REPORT_SCHEMA, "status": "SHARED COMMAND ENGINE, POSES AND HOST TRANSACTION IMPLEMENTED; SCORE-EVENT AND CANONICAL-STORY MAPPING PENDING",
        "scenario_count": 9, "selector_order": war_text.SELECTOR_ORDER,
        "scenario_sources": [row["source"] for row in scenarios],
        "variant_matrix": packet["variant_matrix"],
        "completeness_matrix": [
            {"selector": row["selector"], "id": row["id"], "lifecycle": row["lifecycle"]["kind"],
             "initialization": "source-backed", "scripted_completion": "implemented" if row["lifecycle"]["kind"] == "scripted" else "not_applicable",
             "ordinary_commands": "not_applicable" if row["lifecycle"]["kind"] == "scripted" else "implemented; nine-cell source matrix",
             "special_commands_and_enemy_ai": "not_applicable" if row["lifecycle"]["kind"] == "scripted" else "implemented; five typed families and used-set selector",
             "terrain": "implemented", "unit_pose_composition": "implemented; MAIN script frames and source rectangles",
             "controller_and_cpu_view": "implemented", "snapshot_restore": "schema-v6 implemented with attempt and initial RNG",
             "audio": "VAB and three-channel XA2 adapters implemented; score-event mapping pending",
             "campaign_mapping": "attempt-unique atomic host transactions implemented; canonical story mapping pending"}
            for row in scenarios
        ],
        "helpers_sha256": {name: file_hash(TOOLS / name) for name in HELPERS},
        "contracts": {key: packet[key] for key in ("selector_contract", "leader_contract", "state_contract", "rng_contract", "casualty_contract", "ordinary_contract", "special_contract")},
        "source_consumer_evidence": {
            "ordinary_commands": "0x80014F24 selects the first recruited category; 0x8001AA30 computes strength; 0x8001AFDC consumes enemy selection RNG; 0x8001B610 supplies nine source action formulas.",
            "specials": "0x8002051C, 0x80020954, 0x80021238, 0x800213D0 and 0x80021B44 implement five separate special policies rather than a generic special command.",
            "casualties": "Both sides load the divisor before the divu in each overlay's troop loss routine. The variant matrix records its address and divisor. GARA 0x80018478 provides troop casualty ratios. The Python gate reads the divisor words independently at the known addresses, and Zig checks 300- and 400-troop record boundaries.",
            "initialization": "Static reads of 0x8001053C and the ordinary setup path through 0x80018AC0 and 0x800174A0 derive troop counts and the initial unit records. The zero-force cases and instruction counts match the retained initialization witness.",
            "shared_lifecycle": "0x80018530 walks two side counts in source order and dispatches each 28-byte record through the state table at 0x80010054. The state names are data labels only; behavior is implemented from each target routine.",
            "scripted_lifecycle": "SCA1/TEO1/TEO2 use the direct call at 0x800104A8 and a 17-entry table at 0x800102FC. Bounded source execution with explicit callback objects reaches two phase-9 confirmations and phase-14 cleanup at call 1161. Runtime scripted_completion is a scene result, not an invented victory/defeat flag.",
            "terrain": "Descriptor+0x14 supplies row-major u16 cells. MAIN 0x8014CEB4 derives atlas=code>>6 and tile=code&63, with 32x32 tiles in decoded 128x128 pages. KITA uses23x15, other battlefields20x15, sky16x12.",
            "poses": "Static reads of the atlas descriptor prefixes match the retained zero-initialized MAIN 0x80146BB4 witness. The frame, width, height, secondary and flags drive the exported 8x8 rectangles.",
            "audio": "WAR.VA/WAR.VB pass the existing VAB size/tone/sample table validators. XA2 has three accepted WAV channel identities xa/xa2_ch0.wav through xa/xa2_ch2.wav, separate from the VAB effect bank.",
        },
        "campaign_contract": "Entry accepts source-derived Initial, a 108-member roster, optional current bits and optional attempt_id. Session.applyResult validates all requests, then commits Host bits, casualties, outcome and (scenario.content_sha256,attempt_id,receipt) atomically with Session.consumeResult. Host stores sixteen owned receipts and rejects duplicates; restart advances attempt_id. Snapshot v6 stores attempt_id and initial_rng. scripted_completion emits scenario_completed; the gameplay owner must map it to canonical story effects.",
        "boundary_contract": "Presentation ticks restore canonical combat RNG after visual state progression. Record underflow is clamped at zero in production to prevent army revival; recordsAfterLoss retains raw u8 wrapping only for source-byte reference tests. Ordinary admission follows four phase-9 confirmations and 1574 updates; zero-force scenes use two and 1160.",
        "limitations": ["This report does not assert campaign, native or live gameplay acceptance.",
                        "Score-event mapping and canonical story/consequence mappings remain owner integration work; no direct score-start calls were found in the war overlay."],
        "registry_rows": [row["id"] for row in registry],
        "generated_identities": {"packet_content_sha256": packet["content_sha256"],
                                 "fixture_content_sha256": fixture["content_sha256"]},
    }
    session_cases = []
    for selector, initial_state in ((0, 1), (1, 19), (8, 0xFFFFFFFF)):
        state = initial_state
        draws = []
        for _cursor in range(8):
            state = (state * 0x41C64E6D + 0x3039) & 0xFFFFFFFF
            draws.append((state >> 16) & 0x7FFF)
        session_cases.append({"scenario_selector": selector, "initial_rng_state": initial_state,
                              "expected_final_rng_state": state, "expected_draws": draws})
    session_fixture = identified({"schema": SESSION_FIXTURE_SCHEMA, "id": "war_session_cases",
                                  "packet_content_sha256": packet["content_sha256"], "cases": session_cases})
    return {"packet": packet, "fixtures": fixture, "session_fixtures": session_fixture,
            "report": report, "registry": registry}


def output_bytes(exported: dict) -> dict[str, bytes]:
    return {
        "kit/data/reports/war_rules.json": serialize(exported["report"]),
        "kit/data/registry/extract_war_rules.jsonl": jsonl_bytes(exported["registry"]),
        "game/assets/war/scenarios.json": serialize(exported["packet"]),
        "game/tests/fixtures/war_rules.json": serialize(exported["fixtures"]),
        "game/tests/fixtures/war_sessions.json": serialize(exported["session_fixtures"]),
    }


def main(argv: list[str] | None = None) -> int:
    return run_exporter(
        argv,
        root=ROOT,
        description=__doc__,
        build_outputs=lambda: (exported := build(), output_bytes(exported)),
        summary=lambda _: "5 war rule outputs; scenarios 9",
        error_types=(RuleError, OSError, KeyError, IndexError, TypeError, ValueError),
        error_prefix="war rule export failed",
        output_root_help="",
        check_help="",
    )


if __name__ == "__main__":
    raise SystemExit(main())
