#!/usr/bin/env python3
"""Compile reviewed source-event subsets into the frozen suikoden-event-ir/1.

The source front ends remain opening_audience, opening_events and the reviewed
Kobold decoder. This module adds shared frozen-IR lowerings, entry predicates,
content identities, deterministic selection and analysis-only follow-on diagnostics.
Accepted packets are comparison witnesses, never compiler inputs.

Original input comes from the US v1.1 disc through export_first_room.source().
Generated packets and reports are written only to explicit CLI paths.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import area_scene as scene
import event_script_decode
import event_script_reachability as reachability
import event_vm_semantics
import opening_audience
import opening_events
import vb6_arrival
from export_first_room import source
from export_scene_population import decode_predicate

SCHEMA = "suikoden-event-ir/1"
REPORT_SCHEMA = "suikoden-event-program-compiler/1"
VAA_CONTENT = "vaa_audience_choice"
VB6_CONTENT = "vb6_room6_arrival"
AUDIENCE = "vaa_room2_audience"
INIT_23 = "vaa_room2_init_23"
INIT_24 = "vaa_room2_init_24"
ARRIVAL = "vb6_r06_first_arrival"
FOLLOWON_7 = "vb6_r06_entity07_followon"
FOLLOWON_9 = "vb6_r06_entity09_followon"
POSITIVE_PROGRAMS = (AUDIENCE, INIT_23, INIT_24, ARRIVAL)
DIAGNOSTIC_PROGRAMS = (FOLLOWON_7, FOLLOWON_9)
ALL_PROGRAMS = (*POSITIVE_PROGRAMS, *DIAGNOSTIC_PROGRAMS)
CONTENT_PROGRAMS = {
    VAA_CONTENT: (AUDIENCE, INIT_23, INIT_24),
    VB6_CONTENT: (ARRIVAL,),
}
PROGRAM_CONTENT = {
    program: content for content, programs in CONTENT_PROGRAMS.items() for program in programs
}
HELPERS = (
    "disc.py", "export_first_room.py", "area_scene.py", "maindec.py",
    "character_table.py", "war_text.py", "event_script_decode.py",
    "event_vm_semantics.py", "event_script_reachability.py",
    "opening_audience.py", "opening_events.py", "export_scene_population.py",
    "vb6_arrival.py",
)
COMMAND_FIELDS = (
    "actor", "character", "box", "image", "name", "text", "track",
    "transition", "x", "y", "updates", "cue", "dx", "dy", "variant",
    "value", "options", "target", "layout", "code", "speaker_slot",
    "table", "index", "requested_prefix", "selector", "parameter", "mask",
    "glyph_bytes", "countdown", "flags", "blend_mode", "draw_slot", "destination", "area",
)
SUPPORTED_ACTION_KINDS = frozenset({
    "align_hero", "actor_transition", "open_box", "speaker", "text",
    "wait_confirm", "close_box", "queue_track", "queue_draw_record", "wait_tracks", "delay",
    "cue", "pan", "next_variant", "previous_variant", "wait_variant",
    "set_variant", "actor_motion", "actor_x", "actor_y", "release_actor",
    "create_double", "choice", "jump", "branch_choice", "label",
    "free_double", "follow_character", "complete_audience", "wait_boxes",
    "finish", "select_cue", "continue_tick", "yield_tick", "end_stream",
    "request_area_party_prefix", "queue_glyphs_a", "queue_glyphs_b",
    "wait_text_queue_empty", "wait_text_queue_drain_and_release",
    "open_dialogue_box", "close_dialogue_box", "start_or_wait_dialogue",
    "dialogue", "wait_for_accept", "wait_event_flags_low2_clear",
    "descriptor_flags_and", "descriptor_flags_or", "story_or", "story_andnot", "dialogue_cleanup", "area_action", "fade_out",
    "room_transition",
})


class CompilationError(ValueError):
    """A source or lowering cannot be represented completely and explicitly."""


class UnsupportedProgram(CompilationError):
    """A diagnostic-only selection has no executable output by contract."""


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical(value: dict) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def serialize(value: dict) -> str:
    return json.dumps(value, indent=2) + "\n"


def identified(content: dict) -> dict:
    result = dict(content)
    result["content_sha256"] = ""
    result["content_sha256"] = hashlib.sha256(canonical(result)).hexdigest()
    return result


def story_id(index: int) -> str:
    if not 0 <= index < 240:
        raise CompilationError(f"scenario index outside frozen storage: {index}")
    return f"scenario_{index:04d}"


def story_value(index: int, initial: int = 0) -> dict:
    if not 0 <= initial <= 255:
        raise CompilationError(f"invalid scenario initial value: {initial}")
    return {"id": story_id(index), "storage": "scenario", "byte_index": index, "initial": initial}


def flag(index: int, mask: int) -> dict:
    if not 0 < mask <= 255:
        raise CompilationError(f"invalid scenario mask: {mask}")
    return {"id": story_id(index), "mask": mask}


def wait(kind: str, ident: str) -> dict:
    return {"kind": kind, "id": ident}


def predicate_conditions(predicate: dict, context: str) -> list[dict]:
    conditions = []
    for term in predicate["terms"]:
        kind = term["kind"]
        if kind not in ("story_mask_set", "story_mask_clear"):
            raise CompilationError(f"{context}: predicate is not frozen-IR story conjunction: {kind}")
        source_flag = term["flag"]
        index = int(source_flag["id"][9:])
        conditions.append({"kind": kind, "flag": flag(index, source_flag["mask"])})
    return conditions


def source_predicate(data: bytes, offset: int | None, domain: str, context: str) -> tuple[list[dict], dict]:
    decoded, proof = decode_predicate(data, offset, domain)
    return predicate_conditions(decoded, context), proof


class FrozenLowering:
    """Shared named-source-action to frozen-command lowering; never emits no-ops."""

    def __init__(self, text_prefix: str):
        self.text_prefix = text_prefix
        self.texts: dict[str, dict] = {}

    def command(self, action: dict) -> dict:
        if not isinstance(action, dict) or not isinstance(action.get("kind"), str):
            raise CompilationError("malformed source action: expected a kind string")
        kind = action["kind"]
        if kind not in SUPPORTED_ACTION_KINDS:
            raise CompilationError(f"unsupported source action kind: {kind}")
        result = {"kind": kind} | {key: action[key] for key in COMMAND_FIELDS if key in action}
        if kind == "complete_audience":
            result = {"kind": "story_or", "flag": flag(0, 0x40)}
        elif kind in ("finish", "end_stream"):
            result = {"kind": "end_stream", "requires": wait("event_flags_low2", "dialogue_flags")}
        elif kind == "select_cue":
            result = {"kind": "cue", "cue": action["cue"]}
        elif kind == "open_dialogue_box":
            result = {"kind": "open_box", "layout": action["layout"], "box": action["slot"],
                      "requires": wait("box_closed", f"box_{action['slot']}")}
        elif kind == "close_dialogue_box":
            result = {"kind": "close_box", "box": action["slot"]}
        elif kind == "start_or_wait_dialogue":
            result = {"kind": kind, "box": action["slot"], "code": action["code"],
                      "wait": wait("speaker_prefix", f"box_{action['slot']}")}
        elif kind == "dialogue":
            text_id = f"{self.text_prefix}_text_{action['table']}_{action['index']}"
            text = {"id": text_id, "tokens": [{"kind": "glyph", "text": page} for page in action["pages"]]}
            previous = self.texts.setdefault(text_id, text)
            if previous != text:
                raise CompilationError(f"conflicting source text identity: {text_id}")
            result = {"kind": "text", "speaker_slot": action["speaker_slot"],
                      "table": action["table"], "index": action["index"],
                      "box": action["speaker_slot"], "text": text_id, "wait": wait("text", text_id)}
        elif kind == "wait_event_flags_low2_clear":
            result = {"kind": "wait_event_flags_low2"}
        elif kind in ("descriptor_flags_and", "descriptor_flags_or"):
            result = {"kind": "descriptor_flags", "selector": action["selector"],
                      "parameter": action["parameter"], "mask": action["mask"]}
        elif kind in ("story_or", "story_andnot"):
            result = {"kind": kind, "flag": flag(action["byte_index"], action["mask"])}
            if "mask" in action:
                result["mask"] = action["mask"]
        elif kind == "wait_confirm":
            result = {"kind": "wait_for_accept"}
        else:
            result["kind"] = kind

        kind = result["kind"]
        if kind == "release_actor":
            result["actor"] = result["actor"].replace("descriptor_", "scene_actor_")
        if kind == "request_area_party_prefix":
            result["scope"] = "area_transient"
        if kind == "align_hero":
            if "cell_x" in action:
                result.update(x=action["cell_x"] * 8, y=action["cell_y"] * 8)
            result["wait"] = wait("alignment", "alignment")
        elif kind == "open_box" and "requires" not in result:
            result["requires"] = wait("box_closed", f"box_{result['box']}")
        elif kind == "speaker":
            result["wait"] = wait("speaker_prefix", f"box_{result['box']}")
        elif kind == "text" and "wait" not in result:
            result["wait"] = wait("text", result["text"])
        elif kind == "delay":
            result["wait"] = wait("delay", "delay")
        elif kind == "pan":
            result["wait"] = wait("pan", "pan")
        elif kind == "fade_out":
            result["wait"] = wait("fade", "fade")
        elif kind == "wait_variant":
            result["requires"] = wait("variant", result["actor"])
        return result

    def commands(self, actions: list[dict], context: str) -> list[dict]:
        if not actions:
            raise CompilationError(f"{context}: empty source program")
        result = [self.command(action) for action in actions]
        transitions = ("room_transition", "world_transition")
        if result[-1]["kind"] not in ("end_stream", *transitions):
            raise CompilationError(f"{context}: complete lowering must end with a terminal command")
        branch_target = 0
        for index, command in enumerate(result[:-1]):
            kind = command["kind"]
            if kind in transitions or (kind == "end_stream" and branch_target <= index):
                raise CompilationError(f"{context}: command {index} ends the program before the remaining commands")
            if kind in ("jump", "branch_choice"):
                target = command.get("target")
                if type(target) is int and 0 <= target < len(result):
                    branch_target = max(branch_target, target)
        return result


def audience_instruction_proof(proof: dict) -> list[dict]:
    rows = [row for row in proof["instructions"] if "command" in row]
    return sorted(rows, key=lambda row: row["command"])


def compile_vaa() -> tuple[dict, dict]:
    audience, audience_proof = opening_audience.export()
    initializers, initializer_proof = opening_events.export()
    data, source_proof = source("/VAA.BIN")
    entries = scene.entities(data, scene.room_record(data, 2))
    lowering = FrozenLowering("vaa")
    programs = []
    proofs = []

    ordinary = entries[22]
    if ordinary["stream_offsets"][2] != 0x50D80:
        raise CompilationError("VAA audience source entry changed")
    conditions, condition_proof = source_predicate(data, ordinary["stream_offsets"][0], "classification", AUDIENCE)
    interaction, interaction_proof = decode_predicate(data, ordinary["stream_offsets"][1], "event")
    if [term["kind"] for term in interaction["terms"]] != ["interaction"]:
        raise CompilationError("VAA audience interaction predicate changed")
    programs.append({
        "id": AUDIENCE, "entry": "ordinary", "entity": 22, "trigger": "interaction",
        "conditions": conditions, "commands": lowering.commands(audience["commands"], AUDIENCE),
    })
    proofs.append({
        "id": AUDIENCE, "content_id": VAA_CONTENT, "entry_offset": ordinary["offset"],
        "classification": condition_proof, "event_predicate": interaction_proof,
        "stream_offset": ordinary["stream_offsets"][2],
        "instructions": audience_instruction_proof(audience_proof),
    })

    initializer_by_id = {row["id"]: row for row in initializer_proof["programs"]}
    for program in initializers["programs"]:
        program_id = program["id"]
        if program_id not in (INIT_23, INIT_24):
            raise CompilationError(f"unexpected VAA initializer identity: {program_id}")
        proof = initializer_by_id[program_id]
        entry = entries[proof["entity"]]
        conditions, condition_proof = source_predicate(data, entry["stream_offsets"][1], "event", program_id)
        programs.append({
            "id": program_id, "entry": "initialization", "entity": proof["entity"], "trigger": "none",
            "conditions": conditions, "commands": lowering.commands(program["commands"], program_id),
        })
        proofs.append({
            "id": program_id, "content_id": VAA_CONTENT, "entry_offset": entry["offset"],
            "event_predicate": condition_proof, "stream_offset": entry["stream_offsets"][2],
            "instructions": proof["instructions"],
        })

    content = identified({
        "schema": SCHEMA, "id": VAA_CONTENT,
        "story_values": [story_value(0, initializers["initial_flags"]["story_0006"] * 64)],
        "actors": audience["actors"], "texts": audience["texts"], "tracks": audience["tracks"],
        "programs": programs,
    })
    return content, {"source": source_proof, "room": 2, "programs": proofs,
                     "audience_source_proof": audience_proof,
                     "initializer_source_proof": initializer_proof}


def compile_vb6() -> tuple[dict, dict]:
    data, source_proof = source("/VB6.BIN")
    entries = scene.entities(data, scene.room_record(data, 6))
    arrival = entries[5]
    conditions, condition_proof = source_predicate(data, arrival["stream_offsets"][1], "event", ARRIVAL)
    actions, spans = vb6_arrival.compile_arrival(data, arrival["stream_offsets"][2])
    lowering = FrozenLowering("vb6")
    commands = lowering.commands(actions, ARRIVAL)

    actors = []
    actor_proofs = []
    for index in vb6_arrival.CHARACTER_INDICES:
        entry = entries[index]
        visibility, visibility_proof = source_predicate(
            data, entry["stream_offsets"][0], "classification", f"VB6 entity {index}")
        stable_id = f"vb6_r06_e{index:02d}_char_{entry['id']:03d}"
        actors.append({
            "id": stable_id, "character": entry["id"],
            "x": entry["x_half"] * 8, "y": entry["y_half"] * 8,
            "attached": False, "conditions": visibility,
        })
        actor_proofs.append({"id": stable_id, "entity": index, "entry_offset": entry["offset"],
                             "classification": visibility_proof})

    story_indices = {15, 19}
    for command in commands:
        if command["kind"] == "story_or":
            story_indices.add(int(command["flag"]["id"][9:]))
    content = identified({
        "schema": SCHEMA, "id": VB6_CONTENT,
        "story_values": [story_value(index) for index in sorted(story_indices)],
        "actors": actors, "texts": list(lowering.texts.values()), "tracks": [],
        "programs": [{
            "id": ARRIVAL, "entry": "ordinary", "entity": 5, "trigger": "area_entry",
            "conditions": conditions, "commands": commands,
        }],
    })
    return content, {
        "source": source_proof, "room": 6, "actors": actor_proofs,
        "programs": [{
            "id": ARRIVAL, "content_id": VB6_CONTENT, "entry_offset": arrival["offset"],
            "event_predicate": condition_proof, "stream_offset": arrival["stream_offsets"][2],
            "instructions": spans,
        }],
    }


def decode_bounded(data: bytes, start: int, program_id: str) -> list[tuple]:
    rows = []
    for row in event_script_decode.decode_stream(data, start, max_insns=128):
        offset, opcode, operands, note = row
        if any(word in note for word in ("UNKNOWN", "TRUNCATED", "truncated", "NULL")):
            raise CompilationError(f"{program_id}: undecodable instruction at {offset:#x}: {note}")
        rows.append(row)
        if opcode == 0xFD:
            return rows
    raise CompilationError(f"{program_id}: no bounded inline terminator")


def followon_semantics(row: tuple, data: bytes) -> dict:
    offset, opcode, operands, note = row
    effect = event_vm_semantics.EFFECTS.get(opcode, {})
    result = {
        "offset": offset, "address": 0x80010000 + offset, "opcode": opcode,
        "handler": event_vm_semantics.handler_table()[opcode] if opcode < 0x52 else None,
        "operands_hex": operands.hex(), "decoder_note": note,
        "source_effect": effect.get("effect", "inline stream exit; see MAIN 0x8013E028"),
        "source_semantics": "proven" if opcode in event_vm_semantics.EFFECTS else "inline_decoded",
    }
    if opcode == 0x03:
        result.update(
            lowering="unsupported_frozen_ir",
            known="event_stream_read_args format 06 changes to room 6 at half-cell (27,25), after the low-two-bit dialogue barrier",
            missing="Frozen IR has no typed room/coordinate transition or corresponding inline-exit effect",
            next_investigation="Owner must specify and prove a typed transition contract before any lowering decision; no host effect is presumed",
        )
    elif opcode in (0x07, 0x32, 0x3A):
        result.update(
            lowering="source_proven_actor_binding_unresolved",
            known="This exact operation family is lowered in accepted VAA/arrival source slices",
            missing="VB6 descriptor selector to stable frozen-IR actor identity is not established by the accepted packet",
            next_investigation="Trace VB6 descriptor construction/order and bind the selector to a stable source actor before compilation",
        )
        if opcode == 0x32:
            result["track_commands"] = opening_audience.track(operands[1:])
        elif opcode == 0x07:
            result["descriptor_mode"] = operands[1]
        elif opcode == 0x3A:
            result["descriptor_selector"] = operands[0]
    else:
        result["lowering"] = "covered_by_existing_source_lowering"
    if opcode == 0x1C:
        reference = vb6_arrival.text_reference(data, operands[1], operands[2])
        result["text_reference"] = reference
    return result


def diagnose_followon(program_id: str, entity_index: int) -> dict:
    data, source_proof = source("/VB6.BIN")
    entry = scene.entities(data, scene.room_record(data, 6))[entity_index]
    guard, guard_proof = source_predicate(data, entry["stream_offsets"][1], "event", program_id)
    start = entry["stream_offsets"][2]
    rows = decode_bounded(data, start, program_id)
    graph = reachability.walk(data, [start])
    instructions = [followon_semantics(row, data) for row in rows]
    writes = [{
        "offset": offset, "address": 0x80010000 + offset,
        "byte_index": operands[0], "mask": operands[1],
        "flag": flag(operands[0], operands[1]), "effect": "story_or",
    } for offset, opcode, operands, _ in rows if opcode == 0x09]
    schema_frontiers = [row for row in instructions if row["lowering"] == "unsupported_frozen_ir"]
    binding_frontiers = [row for row in instructions if row["lowering"] == "source_proven_actor_binding_unresolved"]
    if entity_index == 7:
        terminal = "scenario_0015 OR 0x40 is source-proven at 0x35181 before the inline room transition; subsequent same-room execution is not claimed"
        unsupported_reason = "inline room transition is absent from frozen IR"
    else:
        terminal = "scenario_0016 OR 0x01 is source-proven at 0x351D6 immediately before the decoded 0xFD stream exit"
        unsupported_reason = "VB6 descriptor/actor binding is not established; no schema deficiency is claimed for the remaining decoded operations"
    return {
        "id": program_id, "analysis_only": True, "executable": False,
        "source": source_proof, "room": 6, "entity": entity_index,
        "entry_offset": entry["offset"], "event_predicate_offset": entry["stream_offsets"][1],
        "stream_offset": start, "stream_address": 0x80010000 + start,
        "guard": guard, "guard_provenance": guard_proof,
        "reachability": {
            "scope": "entry-rooted possible paths; waits and campaign feasibility are not execution traces",
            "nodes": graph["nodes"], "frontier": graph["frontier"], "inline_exits": graph["inline_exits"],
        },
        "instructions": instructions, "terminal_story_writes": writes,
        "terminal_assessment": terminal,
        "frontiers": {
            "frozen_ir": schema_frontiers,
            "actor_binding": binding_frontiers,
        },
        "unsupported_reason": unsupported_reason,
        "trigger_constraint": "ordinary source selection only; do not auto-chain entity7 into entity9",
        "decoder_dependency": "event_script_decode supplies operand boundaries; event_vm_semantics and original consumers supply independent semantic corroboration",
    }


def compile_sources() -> dict:
    vaa, vaa_proof = compile_vaa()
    vb6, vb6_proof = compile_vb6()
    return {
        "contents": {VAA_CONTENT: vaa, VB6_CONTENT: vb6},
        "proofs": {VAA_CONTENT: vaa_proof, VB6_CONTENT: vb6_proof},
        "diagnostics": {
            FOLLOWON_7: diagnose_followon(FOLLOWON_7, 7),
            FOLLOWON_9: diagnose_followon(FOLLOWON_9, 9),
        },
    }


def selected_content(content: dict, program_ids: tuple[str, ...]) -> dict:
    selected = [dict(program) for program in content["programs"] if program["id"] in program_ids]
    result = {key: value for key, value in content.items() if key not in ("programs", "content_sha256")}
    result["programs"] = selected
    return identified(result)


def compare_content(content: dict, full: dict, baseline_root: Path) -> dict:
    path = baseline_root / "game/assets/events" / f"{full['id']}.json"
    if not path.is_file():
        raise CompilationError(f"accepted baseline unavailable: {path}")
    baseline = json.loads(path.read_text())
    baseline_programs = {program["id"]: program for program in baseline["programs"]}
    comparisons = []
    for program in content["programs"]:
        comparisons.append({
            "program_id": program["id"],
            "exact_json_value_match": program == baseline_programs.get(program["id"]),
            "comparison": "no normalization; ordering, conditions, values, text/track identities and control flow retained",
        })
    support_equal = all(content[key] == baseline[key] for key in ("story_values", "actors", "texts", "tracks"))
    exact = content == baseline
    return {
        "path": str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path),
        "baseline_content_sha256": baseline["content_sha256"],
        "exact_complete_content_match": exact,
        "supporting_content_match": support_equal,
        "programs": comparisons,
        "match": support_equal and all(row["exact_json_value_match"] for row in comparisons),
        "note": "Baseline is comparison evidence only; source producers and shared lowerings produce the candidate",
    }


def compile_selection(program_ids: tuple[str, ...] | None = None, baseline_root: Path = ROOT) -> dict:
    selection = POSITIVE_PROGRAMS if program_ids is None else tuple(program_ids)
    if not selection or len(set(selection)) != len(selection) or any(pid not in ALL_PROGRAMS for pid in selection):
        raise CompilationError("selection must contain unique known program IDs")
    compiled = compile_sources()
    contents = {}
    emit_ids = []
    baseline = {}
    failures = []
    for content_id, programs in CONTENT_PROGRAMS.items():
        chosen = tuple(pid for pid in programs if pid in selection)
        if not chosen:
            continue
        content = selected_content(compiled["contents"][content_id], chosen)
        comparison = compare_content(content, compiled["contents"][content_id], baseline_root)
        contents[content_id] = content
        baseline[content_id] = comparison
        if comparison["match"]:
            emit_ids.append(content_id)
        else:
            failures.append({"id": content_id, "reason": "accepted baseline mismatch; executable output suppressed"})
    diagnostics = [compiled["diagnostics"][pid] for pid in DIAGNOSTIC_PROGRAMS if pid in selection]
    failures.extend({"id": row["id"], "reason": row["unsupported_reason"], "analysis_only": True} for row in diagnostics)
    return {
        "success": not failures,
        "selection": list(selection), "contents": contents, "emit_ids": emit_ids,
        "baseline": baseline, "diagnostics": diagnostics, "failures": failures,
        "proofs": compiled["proofs"],
    }


def deterministic_metadata(result: dict) -> dict:
    selected = set(result["selection"])
    programs = []
    for content_id, proof in result["proofs"].items():
        for program in proof["programs"]:
            if program["id"] in selected:
                programs.append(program | {"content_id": content_id, "source": proof["source"]})
    return {
        "schema": REPORT_SCHEMA,
        "status": "SOURCE/MODULE IMPLEMENTED; PENDING INDEPENDENT REVIEW",
        "target": "Suikoden US v1.1 SLUS_002.92",
        "selection": result["selection"], "success": result["success"],
        "frozen_schema": SCHEMA,
        "source_inputs": {
            content_id: proof["source"] for content_id, proof in result["proofs"].items()
        },
        "address_conversion": {
            "VAA/VB6": "absolute source pointer - 0x80010000 = overlay file offset; no PS-X header",
            "MAIN.EXE": "file offset 2048 + (VA - 0x800C0800); header excluded from image addresses",
        },
        "helpers_sha256": {name: file_hash(TOOLS / name) for name in HELPERS},
        "reviewed_kobold_helper_sha256": file_hash(TOOLS / "vb6_arrival.py"),
        "programs": programs,
        "contents": [{
            "id": content_id, "content_sha256": result["contents"][content_id]["content_sha256"],
            "program_ids": [row["id"] for row in result["contents"][content_id]["programs"]],
            "baseline": result["baseline"][content_id],
        } for content_id in result["contents"]],
        "diagnostics": result["diagnostics"], "failures": result["failures"],
        "coverage": {
            "positive_program_count": len([pid for pid in selected if pid in POSITIVE_PROGRAMS]),
            "diagnostic_program_count": len([pid for pid in selected if pid in DIAGNOSTIC_PROGRAMS]),
            "source_lowering": "shared named-action lowerings over complete source-producer command lists; no per-program command templates",
            "scope": "only the four accepted programs; not all 82 opcodes",
        },
        "determinism": "No timestamps, cache paths, working-directory paths or execution traces are included",
        "limitations": [
            "Follow-ons are analysis-only and never emitted as runnable programs",
            "VAA descriptor-to-actor bindings reuse the source-proven opening mapping; VB6 follow-on descriptor bindings remain unresolved",
            "Runtime evidence is module-level only; catalog registration, host integration and gameplay acceptance are separate",
        ],
    }


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(serialize(value))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True,
                        help="directory for generated frozen-IR packets; no repository assets are changed")
    parser.add_argument("--program", action="append", choices=ALL_PROGRAMS,
                        help=f"program to compile or diagnose; repeat as needed (default: {','.join(POSITIVE_PROGRAMS)})")
    parser.add_argument("--report", type=Path,
                        help="optional deterministic metadata/diagnostics JSON path")
    parser.add_argument("--baseline-root", type=Path, default=ROOT,
                        help="root containing accepted game/assets/events comparison packets (default: repository)")
    args = parser.parse_args(argv)
    selection = tuple(args.program) if args.program else None
    try:
        result = compile_selection(selection, args.baseline_root.resolve())
        metadata = deterministic_metadata(result)
        for content_id in result["emit_ids"]:
            write_json(args.output.resolve() / f"{content_id}.json", result["contents"][content_id])
        if args.report:
            write_json(args.report.resolve(), metadata)
    except (CompilationError, OSError, KeyError, IndexError, TypeError) as error:
        parser.exit(2, f"compilation failed: {error}\n")
    for failure in result["failures"]:
        print(f"unsupported {failure['id']}: {failure['reason']}", file=sys.stderr)
    print(f"compiled {len(result['emit_ids'])} content packet(s); diagnostics {len(result['diagnostics'])}; success={result['success']}")
    return 0 if result["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
