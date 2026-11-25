#!/usr/bin/env python3
"""Export and resolve source-backed VAA-room2/VB6-room6 field actor bindings.

Generation reads the original disc and accepted frozen packets, but resolve() is
pure: it uses only its packet, named program context, selector and normalized
state arguments. No runtime actor, movement, track or event execution is provided.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import area_scene as scene
import event_script_decode
import event_vm_semantics
import export_field_party_queue as party_queue
import maindec
from export_first_room import source
from export_journey import field_event_bindings

SCHEMA = "suikoden-field-actor-bindings/1"
FIXTURE_SCHEMA = "suikoden-field-actor-binding-fixtures/1"
REPORT_SCHEMA = "suikoden-field-actor-bindings-report/1"
SELECTOR_OPS = {0x07: 0, 0x11: 0, 0x32: 0, 0x3A: 0, 0x4D: 1}
PROGRAMS = (
    ("vaa_room2", "/VAA.BIN", 2, 22, "vaa_room2_audience", False),
    ("vaa_room2", "/VAA.BIN", 2, 23, "vaa_room2_init_23", False),
    ("vaa_room2", "/VAA.BIN", 2, 24, "vaa_room2_init_24", False),
    ("vb6_room6", "/VB6.BIN", 6, 5, "vb6_r06_first_arrival", False),
    ("vb6_room6", "/VB6.BIN", 6, 7, "vb6_r06_entity07_followon", True),
    ("vb6_room6", "/VB6.BIN", 6, 9, "vb6_r06_entity09_followon", True),
)
FROZEN = {
    "game/assets/events/vaa_audience_choice.json": "c12efae170b82594afc97a11a50d2e2ae848d970c5e5f060abbcd7a09abc7731",
    "game/assets/events/vb6_room6_arrival.json": "45f0aca8cd2c6a99a016ad4a6b2d25495c96d577486ad1433a45ee0d1fe59fc3",
    "game/assets/scenes/population/vaa_room2.json": "67a69d506d8442323b51b0c3fedf27bd2026d2b1e570f306a7f293bb862d5a2e",
    "game/assets/scenes/population/vb6_room6.json": "90af5391a085c4f97a7162cd6374fad973ceee22081f9c90c11f5396f1a5d741",
    "kit/data/reports/field_party_queue.json": "e3233c3d13a3af0a191fe11b454fd2cf1ed7f3ffff36f811e7f59b89ad49157b",
}
SOURCE_HASHES = {
    "DATA/01_AREA.A/VAA.BIN": "c029671098582c2668fd15161b753df6723b8074ac4e0c0c4a61c0caaea97110",
    "DATA/02_AREA.B/VB6.BIN": "3f67b5fe69b6fd591a1e7ebab5934cf7ceab6b7f5bdb1f090146b51ce3fc1f6a",
    "MAIN.EXE:image": "e123263c3046a7283d8ca26598185672ed3f8de72d97f5efb0ee8e88ccaa55fa",
}
HELPERS = (
    "disc.py", "export_first_room.py", "area_scene.py", "maindec.py",
    "event_script_decode.py", "event_vm_semantics.py", "opening_audience.py",
    "opening_events.py", "export_scene_population.py", "export_journey.py",
    "export_field_party_queue.py",
)
OUTPUTS = (
    "kit/data/reports/field_actor_bindings.json",
    "kit/data/registry/extract_field_actor_bindings.jsonl",
    "game/assets/scenes/bindings/field_actor_bindings.json",
    "game/tests/fixtures/field_actor_bindings.json",
)


class BindingError(ValueError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_hash(path: Path) -> str:
    return sha256(path.read_bytes())


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def serialize(value) -> bytes:
    return (json.dumps(value, indent=2) + "\n").encode()


def identified(value: dict) -> dict:
    result = dict(value)
    result["content_sha256"] = ""
    result["content_sha256"] = sha256(canonical(result))
    return result


def read_json(root: Path, relative: str) -> dict:
    path = root / relative
    actual = file_hash(path)
    if actual != FROZEN[relative]:
        raise BindingError(f"accepted input changed: {relative}: {actual}")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise BindingError(f"accepted input is not an object: {relative}")
    return value


def require_original_instructions() -> dict:
    anchors = {
        "scene_classification_call": (0x8012EF58, 0x0C04F638),
        "scene_accepted_append": (0x8012F278, 0xA2620000),
        "scene_rejected_reserve": (0x8012F310, 0xA2150000),
        "scene_rejected_count_advance": (0x8012F380, 0x24420001),
        "scene_null_count_rewind": (0x8012F2FC, 0x244200FF),
        "scene_source_character": (0x8012F194, 0x9604FFFE),
        "selector_40_mask": (0x8013CD1C, 0x3086003F),
        "selector_80_compare": (0x8013CCF8, 0x34020080),
        "temporary_count_minus_hero": (0x8013A830, 0x2442FFFF),
        "temporary_area_party_read": (0x8013A884, 0x9050008A),
        "temporary_selector_or_40": (0x8013C56C, 0x36030040),
        "dynamic_count": (0x8013AA18, 0xAC23BF7C),
        "dynamic_character_read": (0x8013AA60, 0x90900000),
        "release_object_guard": (0x8013C8AC, 0x1040000B),
        "release_draw_flag": (0x8013C8D8, 0xA0620001),
        "temporary_free_count_zero": (0x8013AC90, 0xAC20BF7C),
        "hero_coordinate_read": (0x8013D0F0, 0x90A20000),
    }
    for name, (address, expected) in anchors.items():
        actual = maindec.mword(address)
        if actual != expected:
            raise BindingError(f"original consumer changed at {address:#x} ({name}): {actual!r}")
    handlers = event_vm_semantics.handler_table()
    expected_handlers = {0x07: 0x8013C8E4, 0x11: 0x8013CE08,
                         0x32: 0x8013C354, 0x34: 0x8013A9C4, 0x3A: 0x8013C82C}
    if any(handlers[opcode] != address for opcode, address in expected_handlers.items()):
        raise BindingError("original selector-handler dispatch table changed")
    return {name: {"address": f"0x{address:08X}", "word": f"0x{word:08X}"}
            for name, (address, word) in anchors.items()}


def bounded_rows(data: bytes, start: int, program: str) -> list[tuple]:
    rows = []
    for row in event_script_decode.decode_stream(data, start, max_insns=256):
        offset, opcode, operands, note = row
        if any(word in note for word in ("UNKNOWN", "TRUNCATED", "truncated", "NULL")):
            raise BindingError(f"{program}: undecodable instruction at {offset:#x}: {note}")
        rows.append(row)
        if opcode == 0xFD:
            return rows
    raise BindingError(f"{program}: unterminated source stream")


def source_inventory(data: bytes, entries: list[dict], entity: int, program: str,
                     scene_id: str, diagnostic: bool) -> tuple[list[dict], list[dict]]:
    entry = entries[entity]
    start = entry["stream_offsets"][2]
    rows = bounded_rows(data, start, program)
    occurrences = []
    constructions = []
    for command, (offset, opcode, operands, _note) in enumerate(rows):
        base = {
            "scene_id": scene_id, "program_id": program, "diagnostic_only": diagnostic,
            "source_entity": entity, "source_stream_offset": start,
            "source_offset": offset, "source_address": 0x80010000 + offset,
            "command_index": command, "opcode": opcode, "operands_hex": operands.hex(),
        }
        if opcode in SELECTOR_OPS:
            operand = SELECTOR_OPS[opcode]
            selector = operands[operand]
            rule = ("fixed_hero" if selector == 0x80 else
                    "scene_compaction" if selector < 0x40 else "selector_40_family")
            occurrences.append(base | {
                "occurrence_id": f"{program}@{offset:06x}:selector",
                "selector": selector, "selector_operand_index": operand,
                "selector_form": f"0x{selector:02X}", "binding_rule": rule,
                "coverage": "resolved_rule",
            })
        if opcode == 0x34:
            count = operands[0]
            if count == 0xFF or len(operands) != 1 + 4 * count:
                raise BindingError(f"{program}: unsupported dynamic descriptor construction at {offset:#x}")
            constructions.append(base | {
                "construction_id": f"{program}@{offset:06x}:dynamic",
                "kind": "dynamic_opcode_34", "count": count,
                "selectors": [0x40 + index for index in range(count)],
                "character_ids": [operands[1 + 4 * index] for index in range(count)],
                "coverage": "resolved_rule",
            })
        elif opcode in (0x36, 0x37, 0x38, 0x39):
            kind = {0x36: "temporary_create_and_spread", 0x37: "temporary_return",
                    0x38: "temporary_drain_and_free", 0x39: "dynamic_free"}[opcode]
            constructions.append(base | {
                "construction_id": f"{program}@{offset:06x}:lifetime-{opcode:02x}",
                "kind": kind, "count": "active_party_count_minus_1" if opcode in (0x36, 0x37) else 0,
                "selectors": "0x40+i_for_i_1_to_active_party_count_minus_1" if opcode in (0x36, 0x37) else [],
                "coverage": "resolved_rule",
            })
    return occurrences, constructions


def match_stable_actors(population: dict, events: dict, scene_id: str) -> list[dict]:
    candidates = [row for row in population["entities"]
                  if row["population_candidate"] and row["classification"]["pointer_state"] != "null"]
    actors = events["actors"]
    if len(candidates) != len(actors):
        raise BindingError(f"{scene_id}: population/accepted actor count mismatch")
    result = []
    for compact, (entity, actor) in enumerate(zip(candidates, actors)):
        source_character = entity["source_character_id"]
        accepted_character = (actor.get("character") if scene_id == "vb6_room6" else
                              int(actor["graphic"].rsplit("_", 1)[1]))
        if accepted_character != source_character:
            raise BindingError(f"{scene_id}: accepted actor identity mismatch at compact {compact}")
        result.append({
            "source_entity_id": entity["id"], "source_order": entity["source_order"],
            "source_character_id": source_character, "resource_id": entity["resource_id"],
            "resource_domain": entity["resource_domain"], "stable_actor_id": actor["id"],
            "baseline_compact_index": compact, "classification": entity["classification"],
        })
    return result


def predicate_state(terms: list[dict], story: dict) -> str:
    for term in terms:
        kind = term.get("kind")
        if kind not in ("story_mask_set", "story_mask_clear"):
            return "unsupported"
        flag = term.get("flag", {})
        ident, mask = flag.get("id"), flag.get("mask")
        if ident not in story:
            return "ambiguous"
        value = story[ident]
        if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 255:
            return "ambiguous"
        present = bool(value & mask)
        if present != (kind == "story_mask_set"):
            return "false"
    return "true"


def compact_actors(scene_packet: dict) -> list[dict]:
    actors = []
    for actor in scene_packet["scene_actors"]:
        classification = actor["classification"]
        if classification.get("pointer_state") == "null":
            continue
        if classification.get("pointer_state") != "present":
            raise BindingError("unsupported scene classification pointer state")
        actors.append(actor)
    return actors


def outcome(status: str, scene_id: str, program_id: str, selector: int, **fields) -> dict:
    return {"status": status, "scene_id": scene_id, "program_id": program_id,
            "selector": selector, **fields}


def validate_packet(packet: dict) -> None:
    if not isinstance(packet, dict) or packet.get("schema") != SCHEMA:
        raise BindingError("unsupported binding packet schema")
    if packet.get("id") != "vaa_vb6_field_actor_bindings":
        raise BindingError("unsupported binding packet identity")
    if not isinstance(packet.get("content_sha256"), str):
        raise BindingError("missing packet content identity")
    unsigned = dict(packet, content_sha256="")
    if sha256(canonical(unsigned)) != packet["content_sha256"]:
        raise BindingError("binding packet content identity mismatch")
    scenes = packet.get("scenes")
    if not isinstance(scenes, list) or any(not isinstance(row, dict) for row in scenes):
        raise BindingError("binding packet scenes must be object records")
    if {row.get("id") for row in scenes} != {"vaa_room2", "vb6_room6"}:
        raise BindingError("binding packet scene inventory mismatch")
    program_ids = set()
    for scene_row in scenes:
        actors = scene_row.get("scene_actors", [])
        if not isinstance(actors, list) or any(not isinstance(row, dict) for row in actors):
            raise BindingError("scene actors must be object records")
        identities = [row.get("stable_actor_id") for row in actors]
        if len(identities) != len(set(identities)) or any(not isinstance(x, str) or not x for x in identities):
            raise BindingError("duplicate or invalid stable scene actor identity")
        orders = [row.get("source_order") for row in actors]
        if orders != sorted(set(orders)) or any(not isinstance(x, int) for x in orders):
            raise BindingError("scene actors are not unique source-order records")
        for actor in actors:
            if not isinstance(actor.get("classification"), dict):
                raise BindingError("truncated scene actor classification")
        programs = scene_row.get("programs", [])
        if not isinstance(programs, list) or any(not isinstance(row, dict) for row in programs):
            raise BindingError("scene programs must be object records")
        for program in programs:
            if program.get("id") in program_ids:
                raise BindingError("duplicate program identity")
            program_ids.add(program.get("id"))
    if program_ids != {row[4] for row in PROGRAMS}:
        raise BindingError("program inventory mismatch")
    occurrences = packet.get("selector_occurrences")
    if not isinstance(occurrences, list) or len(occurrences) != 61:
        raise BindingError("selector occurrence inventory mismatch")
    if any(not isinstance(row, dict) for row in occurrences):
        raise BindingError("selector occurrences must be object records")
    ids = [row.get("occurrence_id") for row in occurrences]
    if len(ids) != len(set(ids)):
        raise BindingError("duplicate selector occurrence")
    for row in occurrences:
        if row.get("program_id") not in program_ids or not isinstance(row.get("selector"), int) or not 0 <= row["selector"] <= 255:
            raise BindingError("invalid selector occurrence")
    lifetime = packet.get("lifetime_occurrences")
    if not isinstance(lifetime, list) or any(not isinstance(row, dict) for row in lifetime):
        raise BindingError("lifetime occurrences must be object records")


def _party(state: dict, count: int) -> list[int]:
    party = state.get("temporary_party")
    if not isinstance(party, list) or len(party) != count:
        raise BindingError("temporary_party length must equal logical active_party_count")
    if any(not isinstance(x, int) or isinstance(x, bool) or not 0 <= x < 255 for x in party):
        raise BindingError("logical temporary party contains an invalid/sentinel member")
    if count and party[0] != 8:
        raise BindingError("source Hero slot must contain character 8")
    return party


def resolve(packet: dict, scene_id: str, program_id: str, selector: int, state: dict) -> dict:
    """Resolve one source selector without I/O or mutation.

    state.story maps current scenario_NNNN values to bytes. state.scene is
    {phase: pre_creation|active|recreated, released_selectors: [...],
     construction_story: {scenario_NNNN: byte}}. construction_story is the
    retained classification input from the active/recreated construction boundary;
    changing current story alone never reconstructs or reclassifies an object.
    Selector-40 resolution additionally needs state.dynamic or state.temporary
    ({phase: not_created|active|released}) and, for temporary actors,
    active_party_count plus the complete temporary_party including Hero.
    """
    try:
        validate_packet(packet)
        if not isinstance(selector, int) or isinstance(selector, bool) or not 0 <= selector <= 255:
            raise BindingError("selector must be one unsigned byte")
        if not isinstance(state, dict) or not isinstance(state.get("story"), dict):
            raise BindingError("normalized story state is required")
        scene_row = next((row for row in packet["scenes"] if row["id"] == scene_id), None)
        if scene_row is None or program_id not in {row["id"] for row in scene_row["programs"]}:
            return outcome("unsupported", scene_id, program_id, selector, reason="unknown_scene_or_program")
        scene_state = state.get("scene")
        if not isinstance(scene_state, dict) or scene_state.get("phase") not in ("pre_creation", "active", "recreated"):
            raise BindingError("scene lifetime phase is required")
        released = scene_state.get("released_selectors")
        if not isinstance(released, list) or any(not isinstance(x, int) or isinstance(x, bool) for x in released):
            raise BindingError("released_selectors must be integer source selectors")
        if scene_state["phase"] == "recreated" and released:
            raise BindingError("recreated scene cannot retain prior release markers")
        if selector == 0x80:
            return outcome("resolved", scene_id, program_id, selector,
                           domain="hero", actor_id="hero", source_character_id=8,
                           lifetime="fixed_room_hero", identity_rule="MAIN fixed descriptor 0x8017BD74")
        if selector < 0x40:
            if scene_state["phase"] == "pre_creation":
                return outcome("missing", scene_id, program_id, selector, reason="scene_not_created")
            actors = compact_actors(scene_row)
            if selector >= len(actors):
                return outcome("missing", scene_id, program_id, selector, reason="compact_index_not_constructed")
            actor = actors[selector]
            classification = actor["classification"]
            construction_story = scene_state.get("construction_story")
            if not isinstance(construction_story, dict):
                raise BindingError("retained scene construction_story is required")
            status = predicate_state(classification.get("terms", []), construction_story)
            if status in ("unsupported", "ambiguous"):
                return outcome(status, scene_id, program_id, selector,
                               reason=f"construction_classification_{status}")
            if status == "false":
                return outcome("missing", scene_id, program_id, selector,
                               domain="scene_actor", actor_id=actor["stable_actor_id"],
                               source_entity_id=actor["source_entity_id"],
                               compact_index=selector, reason="classification_rejected_inactive_slot")
            result = outcome("resolved", scene_id, program_id, selector,
                             domain="scene_actor", actor_id=actor["stable_actor_id"],
                             source_entity_id=actor["source_entity_id"],
                             source_character_id=actor["source_character_id"],
                             resource_id=actor["resource_id"], resource_domain=actor["resource_domain"],
                             compact_index=selector, lifetime=scene_state["phase"])
            if selector in released:
                result.update(status="released", reason="descriptor_release_marker")
            return result
        if not 0x40 <= selector <= 0x7F:
            return outcome("unsupported", scene_id, program_id, selector, reason="selector_form_not_in_scope")
        table_kind = scene_row["selector_40_domain"]
        table_state = state.get("dynamic" if table_kind == "dynamic_opcode_34" else "temporary")
        if not isinstance(table_state, dict) or table_state.get("phase") not in ("not_created", "active", "released"):
            raise BindingError(f"{table_kind} lifetime phase is required")
        if table_state["phase"] == "not_created":
            return outcome("missing", scene_id, program_id, selector, reason="descriptor_table_not_created")
        if table_kind == "dynamic_opcode_34":
            index = selector - 0x40
            if index >= scene_row["dynamic_descriptor_count"]:
                return outcome("missing", scene_id, program_id, selector, reason="dynamic_index_not_constructed")
            dynamic = next(row for row in scene_row["dynamic_actors"] if row["compact_index"] == index)
            result = outcome("resolved", scene_id, program_id, selector,
                             domain="dynamic_scene_actor", actor_id=dynamic["stable_actor_id"],
                             source_character_id=dynamic["source_character_id"],
                             compact_index=index, lifetime=table_state["phase"])
            if index >= scene_row["dynamic_descriptor_count"]:
                return outcome("missing", scene_id, program_id, selector, reason="dynamic_index_not_constructed")
            if table_state["phase"] == "released":
                result.update(status="released", reason="descriptor_table_freed")
            return result
        count = state.get("active_party_count")
        if not isinstance(count, int) or isinstance(count, bool) or not 1 <= count <= 6:
            raise BindingError("source temporary-party logical active count must be 1..6")
        party = _party(state, count)
        index = selector - 0x40
        if index >= count - 1:
            return outcome("missing", scene_id, program_id, selector,
                           domain="temporary_party_slot", reason="non_hero_party_slot_not_constructed",
                           active_party_count=count)
        slot = index + 1
        result = outcome("resolved", scene_id, program_id, selector,
                         domain="temporary_party_slot", party_slot=slot,
                         source_character_id=party[slot], active_party_count=count,
                         compact_index=index, lifetime=table_state["phase"],
                         membership="area-transient order including Hero at slot0; not persistent ordinary-party ownership")
        if table_state["phase"] == "released":
            result.update(status="released", reason="temporary_descriptor_table_freed")
        return result
    except (BindingError, KeyError, IndexError, TypeError, StopIteration) as error:
        return outcome("invalid", scene_id, program_id, selector if isinstance(selector, int) else -1,
                       reason=str(error))


def fixture_cases(packet: dict) -> list[dict]:
    def case(ident, scene_id, program, selector, state, expected):
        return {"id": ident, "scene_id": scene_id, "program_id": program,
                "selector": selector, "state": state, "expected": expected}
    def scene(phase="active", released=(), construction_story=None):
        return {"phase": phase, "released_selectors": list(released),
                "construction_story": ({"scenario_0000": 0} if construction_story is None
                                       else construction_story)}
    vaa = "vaa_room2_audience"
    vb6 = "vb6_r06_first_arrival"
    base_vaa = {"story": {"scenario_0000": 0}, "scene": scene()}
    cases = [
        case("vaa_compact_entity22", "vaa_room2", vaa, 12, base_vaa,
             {"status": "resolved", "actor_id": "scene_actor_12", "source_entity_id": "vaa_room2_entity_22"}),
        case("vaa_null_exclusion_shifts_later", "vaa_room2", vaa, 5, base_vaa,
             {"status": "resolved", "actor_id": "scene_actor_5", "source_entity_id": "vaa_room2_entity_08"}),
        case("vaa_story_change_does_not_remove_constructed", "vaa_room2", vaa, 12,
             base_vaa | {"story": {"scenario_0000": 64}},
             {"status": "resolved", "actor_id": "scene_actor_12", "source_entity_id": "vaa_room2_entity_22"}),
        case("vaa_story_change_does_not_construct_absent", "vaa_room2", vaa, 12,
             base_vaa | {"story": {"scenario_0000": 0},
                         "scene": scene(construction_story={"scenario_0000": 64})},
             {"status": "missing", "reason": "classification_rejected_inactive_slot",
              "actor_id": "scene_actor_12", "source_entity_id": "vaa_room2_entity_22"}),
        case("vaa_reconstruction_uses_new_construction_state", "vaa_room2", vaa, 12,
             base_vaa | {"story": {"scenario_0000": 64},
                         "scene": scene("recreated", construction_story={"scenario_0000": 64})},
             {"status": "missing", "reason": "classification_rejected_inactive_slot",
              "actor_id": "scene_actor_12", "source_entity_id": "vaa_room2_entity_22"}),
        case("vaa_hero", "vaa_room2", vaa, 128, base_vaa,
             {"status": "resolved", "domain": "hero", "actor_id": "hero", "source_character_id": 8}),
        case("vaa_released", "vaa_room2", vaa, 12, base_vaa | {"scene": scene(released=(12,))},
             {"status": "released", "actor_id": "scene_actor_12"}),
        case("vaa_recreated_same_identity", "vaa_room2", vaa, 12, base_vaa | {"scene": scene("recreated")},
             {"status": "resolved", "actor_id": "scene_actor_12", "source_entity_id": "vaa_room2_entity_22"}),
        case("vaa_double_pre_creation", "vaa_room2", vaa, 64,
             base_vaa | {"dynamic": {"phase": "not_created"}},
             {"status": "missing", "reason": "descriptor_table_not_created"}),
        case("vaa_double_active", "vaa_room2", vaa, 64,
             base_vaa | {"dynamic": {"phase": "active"}},
             {"status": "resolved", "domain": "dynamic_scene_actor", "actor_id": "audience_double", "source_character_id": 8}),
        case("vaa_double_post_release", "vaa_room2", vaa, 64,
             base_vaa | {"dynamic": {"phase": "released"}},
             {"status": "released", "actor_id": "audience_double"}),
        case("vaa_double_recreated", "vaa_room2", vaa, 64,
             base_vaa | {"dynamic": {"phase": "active"}},
             {"status": "resolved", "actor_id": "audience_double"}),
    ]
    for count, party in ((3, [8, 2, 4]), (6, [8, 2, 4, 13, 12, 11])):
        common = {"story": {"scenario_0019": 0}, "scene": scene(), "temporary": {"phase": "active"},
                  "active_party_count": count, "temporary_party": party,
                  "ordinary_party": [8, 2, 4]}
        for selector, slot in ((64, 1), (65, 2)):
            cases.append(case(f"vb6_count{count}_selector{selector:02x}", "vb6_room6", vb6, selector, common,
                              {"status": "resolved", "domain": "temporary_party_slot",
                               "party_slot": slot, "source_character_id": party[slot], "active_party_count": count}))
        cases.append(case(f"vb6_count{count}_entity7", "vb6_room6", "vb6_r06_entity07_followon", 0, common,
                          {"status": "resolved", "actor_id": "vb6_r06_e07_char_014",
                           "source_entity_id": "vb6_room6_entity_07"}))
    common = {"story": {}, "scene": scene(), "temporary": {"phase": "released"},
              "active_party_count": 3, "temporary_party": [8, 2, 4]}
    cases.extend([
        case("vb6_released_party_slot", "vb6_room6", vb6, 64, common,
             {"status": "released", "domain": "temporary_party_slot", "party_slot": 1, "source_character_id": 2}),
        case("vb6_absent_party_slot", "vb6_room6", vb6, 65,
             common | {"temporary": {"phase": "active"}, "active_party_count": 1, "temporary_party": [8]},
             {"status": "missing", "reason": "non_hero_party_slot_not_constructed"}),
        case("unknown_selector_fails_closed", "vb6_room6", vb6, 129, common,
             {"status": "unsupported", "reason": "selector_form_not_in_scope"}),
        case("invalid_count_fails_closed", "vb6_room6", vb6, 64,
             common | {"active_party_count": 0, "temporary_party": []},
             {"status": "invalid"}),
    ])
    for row in cases:
        actual = resolve(packet, row["scene_id"], row["program_id"], row["selector"], row["state"])
        for key, expected in row["expected"].items():
            if actual.get(key) != expected:
                raise BindingError(f"fixture {row['id']}: {key}: {actual.get(key)!r} != {expected!r}")
        row["expected"] = {key: actual[key] for key in row["expected"]}
    return cases


def build(input_root: Path = ROOT) -> dict:
    frozen = {name: read_json(input_root, name) for name in FROZEN if name.endswith(".json")}
    queue_packet, queue_proof = party_queue.export()
    if queue_proof["content_sha256"] != frozen["kit/data/reports/field_party_queue.json"]["content_sha256"]:
        raise BindingError("temporary-party extraction disagrees with accepted proof")
    ordinary_identities = field_event_bindings()
    hero_identity = next((row for row in ordinary_identities["records"] if row["source_character"] == 8), None)
    if hero_identity is None or hero_identity["id"] != "hero":
        raise BindingError("ordinary Hero identity evidence changed")
    instruction_proof = require_original_instructions()
    sources = {}
    source_data = {}
    for suffix, ident in (("/VAA.BIN", "DATA/01_AREA.A/VAA.BIN"), ("/VB6.BIN", "DATA/02_AREA.B/VB6.BIN")):
        data, proof = source(suffix)
        if proof["file"] != ident or sha256(data) != SOURCE_HASHES[ident]:
            raise BindingError(f"original source identity changed: {ident}")
        sources[ident] = proof
        source_data[suffix] = data
    if sha256(maindec.body()) != SOURCE_HASHES["MAIN.EXE:image"]:
        raise BindingError("MAIN.EXE image identity changed")

    occurrences, lifetime_occurrences = [], []
    scene_rows = []
    for scene_id, suffix, room_number, population_name, event_name in (
        ("vaa_room2", "/VAA.BIN", 2, "game/assets/scenes/population/vaa_room2.json", "game/assets/events/vaa_audience_choice.json"),
        ("vb6_room6", "/VB6.BIN", 6, "game/assets/scenes/population/vb6_room6.json", "game/assets/events/vb6_room6_arrival.json"),
    ):
        data = source_data[suffix]
        entries = scene.entities(data, scene.room_record(data, room_number))
        population = frozen[population_name]
        events = frozen[event_name]
        specs = [row for row in PROGRAMS if row[0] == scene_id]
        programs = []
        for _scene, _suffix, _room, entity, program, diagnostic in specs:
            entry = entries[entity]
            new_occurrences, new_lifetimes = source_inventory(data, entries, entity, program, scene_id, diagnostic)
            occurrences.extend(new_occurrences)
            lifetime_occurrences.extend(new_lifetimes)
            programs.append({"id": program, "source_entity": entity,
                             "source_stream_offset": entry["stream_offsets"][2],
                             "diagnostic_only": diagnostic})
        scene_actors = match_stable_actors(population, events, scene_id)
        selector_40 = "dynamic_opcode_34" if any(row["kind"] == "dynamic_opcode_34" for row in lifetime_occurrences if row["scene_id"] == scene_id) else "temporary_area_party"
        dynamic = []
        if selector_40 == "dynamic_opcode_34":
            creates = [row for row in events["programs"][0]["commands"] if row["kind"] == "create_double"]
            constructions = [row for row in lifetime_occurrences if row["scene_id"] == scene_id and row["kind"] == "dynamic_opcode_34"]
            if len(creates) != 1 or len(constructions) != 1 or constructions[0]["count"] != 1:
                raise BindingError("VAA dynamic construction contract changed")
            dynamic = [{"compact_index": 0, "stable_actor_id": creates[0]["actor"],
                        "source_character_id": constructions[0]["character_ids"][0],
                        "construction_id": constructions[0]["construction_id"]}]
            if creates[0]["character"] != "hero" or dynamic[0]["source_character_id"] != 8:
                raise BindingError("VAA dynamic Hero source identity changed")
        scene_rows.append({
            "id": scene_id, "population_content_id": population["content_sha256"],
            "event_content_id": events["content_sha256"], "source": population["source"],
            "scene_actors": scene_actors, "programs": programs,
            "selector_40_domain": selector_40,
            "dynamic_descriptor_count": len(dynamic), "dynamic_actors": dynamic,
            "compaction_rule": "Walk source_order population candidates. Null classifiers exclude records and consume no compact index. Present classifiers consume the next slot even when their conjunction is false: false reserves an inactive descriptor with null objects, not a later-index shift.",
        })
    packet = identified({
        "schema": SCHEMA, "id": "vaa_vb6_field_actor_bindings",
        "contract": {
            "selector_domains": "00..3F compact scene descriptors; 40..7F scene-specific dynamic or temporary descriptors; 80 fixed Hero. Other values are unsupported, never aliases.",
            "scene_identity": "Stable actor IDs come from accepted event packets and remain attached to source entity records across compaction and room recreation; resource IDs are not actor identities.",
            "party_identity": "Hero is its own fixed domain. Ordinary party is persistent host membership and may supply resources. Temporary party is area-transient order including Hero at slot0; 40+i maps to non-Hero slot i+1.",
            "lifetime": "pre_creation/not_created are missing; released retains the proven identity as a typed negative; recreation reconstructs the same source/stable identity and clears prior release markers. Current story is not construction state: only an explicit reconstruction boundary supplies new construction_story classification facts.",
            "resolution_api": "resolve(packet, scene_id, program_id, selector, state) -> JSON-compatible outcome; pure and deterministic. status is resolved, missing, released, unsupported, ambiguous or invalid.",
            "state": "{story:{scenario_NNNN:byte}, scene:{phase:pre_creation|active|recreated,released_selectors:[byte],construction_story:{scenario_NNNN:byte}}, dynamic|temporary:{phase:not_created|active|released}, active_party_count, temporary_party, ordinary_party}. Scene construction_story retains classification inputs from that construction boundary and is required for active/recreated compact-scene resolution. Only fields relevant to the selected domain are consumed.",
            "ordinary_party": "Host-owned persistent member IDs are explicitly separate from temporary_party. No scoped selector directly indexes persistent ordinary-party slots; active_party_character resource fallback remains a resource domain.",
            "fail_closed": "Unknown selectors/programs, malformed packets/state, missing story facts and unsupported predicates never default to an actor or presence vote.",
            "scope": "Binding and lifetime identities only; no actor creation, event execution, movement/track extraction, live export or integration.",
        },
        "ordinary_party_identities": ordinary_identities["records"],
        "scenes": scene_rows, "selector_occurrences": occurrences,
        "lifetime_occurrences": lifetime_occurrences,
    })
    fixtures = identified({"schema": FIXTURE_SCHEMA, "id": "vaa_vb6_field_actor_binding_cases",
                           "packet_content_sha256": packet["content_sha256"],
                           "comparison": "Each expected object is a subset of the pure resolver outcome; unrelated explanatory fields are not compared.",
                           "cases": fixture_cases(packet)})
    by_scene = {}
    for scene_id in ("vaa_room2", "vb6_room6"):
        rows = [row for row in occurrences if row["scene_id"] == scene_id]
        by_scene[scene_id] = {
            "explicit_occurrences": len(rows), "distinct_selectors": sorted({row["selector"] for row in rows}),
            "resolved_rule_occurrences": sum(row["coverage"] == "resolved_rule" for row in rows),
            "supported_negative_cases": sum(row["scene_id"] == scene_id and row["expected"]["status"] in ("missing", "released") for row in fixtures["cases"]),
            "unresolved_selector_semantics": 0,
            "accepted_program_occurrences": sum(not row["diagnostic_only"] for row in rows),
            "diagnostic_only_occurrences": sum(row["diagnostic_only"] for row in rows),
        }
    by_domain = {}
    for row in occurrences:
        if row["selector"] == 0x80:
            domain = "hero"
        elif row["selector"] < 0x40:
            domain = "scene_actor"
        elif row["scene_id"] == "vaa_room2":
            domain = "dynamic_scene_actor"
        else:
            domain = "temporary_party_slot"
        coverage = by_domain.setdefault(domain, {"explicit_occurrences": 0,
                                                "resolved_rule_occurrences": 0,
                                                "unresolved_selector_semantics": 0})
        coverage["explicit_occurrences"] += 1
        coverage["resolved_rule_occurrences"] += row["coverage"] == "resolved_rule"
    helper_hashes = {name: file_hash(TOOLS / name) for name in HELPERS}
    helper_hashes["test_vb2_dice_states.py"] = file_hash(ROOT / "kit/tests/test_vb2_dice_states.py")
    report = {
        "schema": REPORT_SCHEMA, "status": "SOURCE/MODULE IMPLEMENTED; PENDING INDEPENDENT REVIEW",
        "packet_content_sha256": packet["content_sha256"], "fixture_content_sha256": fixtures["content_sha256"],
        "baseline_origin": "Independent compiler review GREEN at source/module level 2026-10-26; no runtime acceptance and no independent Zig rerun for this binder.",
        "accepted_compiler_receipt_sha256": "92b7bd04d97943154a7187a3134d7a5bd283928e210754ef9b9e314a96110203",
        "inputs": {name: {"sha256": digest, "role": "accepted frozen binding/population/party evidence"} for name, digest in FROZEN.items()},
        "original_sources": sources | {"MAIN.EXE:image": {"sha256": SOURCE_HASHES["MAIN.EXE:image"], "lba": maindec.EXE_LBA, "header_bytes": maindec.EXE_HEADER, "image_base": maindec.MBASE}},
        "helpers_sha256": helper_hashes,
        "coverage": {"explicit_occurrences": len(occurrences), "distinct_programs": len(PROGRAMS),
                     "lifetime_or_construction_occurrences": len(lifetime_occurrences),
                     "resolved_rule_occurrences": len(occurrences), "unresolved_selector_semantics": 0,
                     "by_scene": by_scene, "by_domain": by_domain,
                     "denominator_note": "61 explicit source selector references are separate from implicit construction/lifetime occurrences and from the 201/2/10/28 accepted command totals."},
        "independent_consumer_evidence": {
            "scene_compaction": "MAIN 0x8012EF40/0x8012EF58 classifies before construction. Result0 appends a sequential compact index at0x8012F278; result2 reserves an inactive slot and still advances the count at0x8012F380; null result1 rewinds the count at0x8012F2F4. Selector consumers0x8013CCF0 and0x8013C8E4 independently index24-byte area descriptors.",
            "construction_lifetime": "Classification is read during scene construction at MAIN 0x8012EF58, not during selector use. The independent review witness constructed VAA selector12 with scenario_0000=0, changed only that byte to0x40, and observed the same descriptor object and a subsequent flag update through 0x8013CCF0. Therefore current story cannot retroactively remove or create a slot; active/recreated resolution consumes retained construction_story, and only explicit reconstruction supplies a new classification boundary.",
            "stable_scene_identity": "Source entity+6 at MAIN 0x8012F194 feeds resource lookup 0x801346A8, while the accepted actor table supplies the stable runtime ID. Resource selection is retained separately and never used as identity.",
            "temporary_party": "MAIN 0x8013A828..0x8013A884 builds active_count-1 records from area-transient +0x8A order (Hero excluded); 0x8013C56C emits selector40|i. 0x8013CCF0 consumes the same 0x40 family. Existing export_field_party_queue supplies track provenance without duplication.",
            "ordinary_party": "export_journey.field_event_bindings supplies existing stable IDs for persistent member identities. No scoped selector indexes that domain; temporary party resolution never reads ordinary_party.",
            "ordinary_party_provenance": ordinary_identities["provenance"],
            "dynamic_double": "Opcode34 handler 0x8013A9C4 reads its count and per-entry character ID at 0x8013AA18/0x8013AA60. VAA 0x50EA9 constructs one character8 descriptor, bound to accepted audience_double, not to a persistent party slot.",
            "hero": "Selector80 chooses fixed 0x8017BD74 in 0x8013CCF0 and opcode10 reads the same Hero coordinates at 0x8013D0F0. MAIN identity/resource lookup independently identifies character8.",
            "release_recreation": "0x8013C82C guards object presence and writes release markers; 0x8013ABF4 frees temporary/dynamic objects and sets count0. Room reconstruction repeats source-order construction and therefore restores the same source entity/stable IDs, not a new character identity.",
            "party_counts": "Original party constructor tests cover all counts; this binder directly verifies counts3 and6. Count includes Hero. Slots are1..count-1; persistent ordinary-party and temporary area-party arrays are not conflated.",
            "non_bindings": "VB6 inline03 at0x35184 is a room transition, not a selector. 0B/17 operand41 is a dialogue layout. Entity9 remains diagnostic-only and is not emitted as an executable event program.",
        },
        "original_instruction_anchors": instruction_proof,
        "source_consumer_crosscheck": "event_vm_semantics.handler_table() maps 07/11/32/34/3A to 0x8013C8E4/0x8013CE08/0x8013C354/0x8013A9C4/0x8013C82C; independently disassembled MAIN words above validate selection, construction and release.",
        "determinism": "Four logical outputs are generated from fixed source/input identities with stable ordering and no timestamps, absolute paths or runtime observations. --check recomputes and compares without repairs.",
        "limitations": [
            "Pure source packet and Python resolver only; no runtime, native, media or host acceptance is claimed.",
            "Only VAA room2 and VB6 room6 scoped programs are covered; this is not a whole-game binding rule set.",
            "The two VB6 follow-ons remain diagnostic-only; their binding coverage does not make them executable or integrated.",
            "Released identity is retained for diagnostics; the resolver does not decide whether a later original operation reactivates rendering.",
            "The gameplay owner must supply normalized story, ordinary/temporary party and lifetime state and bind these identities to live actors later.",
        ],
    }
    registry = [
        {"id": "FAB01", "stage": "X_FIELD_ACTOR_BINDING", "class": "script", "claim": "All61 explicit selector occurrences in the four accepted VAA/VB6 programs and two diagnostic VB6 follow-ons have source-backed scene, Hero, dynamic or temporary-party binding rules; no scoped selector remains unresolved.", "addr": "VAA:0x50D80;VAA:0x50FF8;VAA:0x50FFC;VB6:0x35128;VB6:0x35164;VB6:0x351A0;MAIN:0x8013CCF0;MAIN:0x8013C8E4", "evidence": "proven", "source": "kit/tools/export_field_actor_bindings.py;kit/tests/test_field_actor_bindings.py;kit/data/reports/field_actor_bindings.json", "superseded_by": "", "note": "Occurrence coverage is not event-program completeness. Follow-ons stay diagnostic-only."},
        {"id": "FAB02", "stage": "X_FIELD_ACTOR_BINDING", "class": "script", "claim": "Compact scene selectors follow source order after classification. Null classifiers exclude records and shift later indices; false classifiers reserve inactive slots without shifting later identities.", "addr": "MAIN:0x8012EF40;MAIN:0x8012EF58;MAIN:0x8012F278;MAIN:0x8012F2FC;MAIN:0x8012F310;MAIN:0x8012F380;MAIN:0x8013D8E0", "evidence": "proven", "source": "kit/tools/area_scene.py;kit/tools/export_scene_population.py;kit/tools/export_field_actor_bindings.py", "superseded_by": "", "note": "VAA null entity7 makes raw entity8 compact5. Scenario_0000 mask0x40 makes entity22 inactive at compact12 rather than removing it or shifting entity25."},
        {"id": "FAB03", "stage": "X_FIELD_ACTOR_BINDING", "class": "script", "claim": "VB6 selectors40/41 denote area-transient non-Hero party slots1/2 at logical counts3 and6; selector80 is fixed Hero and VAA40 is the opcode34 audience double, a separate domain.", "addr": "MAIN:0x8013A808;MAIN:0x8013A884;MAIN:0x8013C4E4;MAIN:0x8013C56C;MAIN:0x8013A9C4;MAIN:0x8013CCF0", "evidence": "proven", "source": "kit/tools/export_field_party_queue.py;kit/tests/test_field_party_queue.py;kit/tools/export_field_actor_bindings.py", "superseded_by": "", "note": "Count includes Hero. Count3 order[8,2,4] binds40->character2 and41->character4; count6 preserves those slots and appends retained members."},
        {"id": "FAB04", "stage": "X_FIELD_ACTOR_BINDING", "class": "script", "claim": "Scene classification belongs to the construction boundary: changing current story alone neither removes a constructed object nor constructs an absent one. Explicit reconstruction uses its retained construction-story facts; release and table-free states retain typed identities without fallback.", "addr": "MAIN:0x8012EF58;MAIN:0x8013CCF0;MAIN:0x8013C82C;MAIN:0x8013ABF4;MAIN:0x8012ED84", "evidence": "proven", "source": "kit/tools/event_vm_semantics.py;kit/tools/export_field_actor_bindings.py;kit/tests/test_field_actor_bindings.py", "superseded_by": "", "note": "construction_story is separate from current story. Recreation clears prior release markers. The packet does not infer render reactivation, permanent death, replacement flags or substitute identities."},
    ]
    return {"packet": packet, "fixtures": fixtures, "report": report, "registry": registry}


def output_bytes(exported: dict) -> dict[str, bytes]:
    return {
        "kit/data/reports/field_actor_bindings.json": serialize(exported["report"]),
        "kit/data/registry/extract_field_actor_bindings.jsonl": "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in exported["registry"]).encode(),
        "game/assets/scenes/bindings/field_actor_bindings.json": serialize(exported["packet"]),
        "game/tests/fixtures/field_actor_bindings.json": serialize(exported["fixtures"]),
    }


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-root", type=Path, default=ROOT,
                        help="repository root for frozen inputs (default: this repository)")
    parser.add_argument("--output-root", type=Path, default=ROOT,
                        help="root for the four logical generated outputs; may be isolated temporary storage")
    parser.add_argument("--check", action="store_true",
                        help="read-only comparison of all four outputs; never create or repair files")
    args = parser.parse_args(argv)
    try:
        expected = output_bytes(build(args.input_root.resolve()))
        output_root = args.output_root.resolve()
        mismatches = []
        for relative, data in expected.items():
            path = output_root / relative
            if args.check:
                if not path.is_file():
                    mismatches.append(f"missing {relative}")
                elif path.read_bytes() != data:
                    mismatches.append(f"stale {relative}")
            else:
                atomic_write(path, data)
        if mismatches:
            for row in mismatches:
                print(row, file=sys.stderr)
            return 1
        print(("checked" if args.check else "generated") + f" 4 field-actor binding outputs; selectors 61; unresolved 0")
        return 0
    except (BindingError, OSError, KeyError, IndexError, TypeError, json.JSONDecodeError) as error:
        print(f"field actor binding failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
