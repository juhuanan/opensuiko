#!/usr/bin/env python3
"""Link source population, construction bindings and frozen event programs offline."""
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
import compile_event_programs as compiler
import export_field_actor_bindings as binder
import opening_audience
import vb6_arrival
from export_first_room import source

SCHEMA = "suikoden-scene-event-bundle/1"
FIXTURE_SCHEMA = "suikoden-scene-event-bundle-fixtures/1"
REPORT_SCHEMA = "suikoden-scene-event-bundle-report/1"
E9_CONTENT = "vb6_room6_entity09"
E9_PROGRAM = compiler.FOLLOWON_9
OUTPUTS = (
    "kit/data/reports/scene_event_bundles.json",
    "kit/data/registry/extract_scene_event_bundles.jsonl",
    "game/assets/scenes/events/vaa_room2.json",
    "game/assets/scenes/events/vb6_room6.json",
    "game/tests/fixtures/scene_event_bundles.json",
)
FROZEN = {
    "game/assets/events/vaa_audience_choice.json": "c12efae170b82594afc97a11a50d2e2ae848d970c5e5f060abbcd7a09abc7731",
    "game/assets/events/vb6_room6_arrival.json": "45f0aca8cd2c6a99a016ad4a6b2d25495c96d577486ad1433a45ee0d1fe59fc3",
    "game/assets/events/vb6_room6_field_host.json": "43cc5e4fac24ac9d5ce95be6a3011c4639a76c79b9ae6878b63f425cef2cd275",
    "game/assets/scenes/population/vaa_room2.json": "67a69d506d8442323b51b0c3fedf27bd2026d2b1e570f306a7f293bb862d5a2e",
    "game/assets/scenes/population/vb6_room6.json": "90af5391a085c4f97a7162cd6374fad973ceee22081f9c90c11f5396f1a5d741",
    "game/assets/scenes/bindings/field_actor_bindings.json": "be643aca837a74621a6a3c7efa913abaf704e0cb4991470c6d224227618fc9e0",
    "kit/data/reports/field_party_queue.json": "e3233c3d13a3af0a191fe11b454fd2cf1ed7f3ffff36f811e7f59b89ad49157b",
    "kit/data/reports/scene_population.json": "ebc4a601f0204210f48aca5a7f40971b2ac58c6c52b677bbdba9d40493b480d0",
}
HELPER_HASHES = {
    "compile_event_programs.py": "a074781da52823a7eafc5cf32c02c07607c5fc8e64c89134c36468b8c23918e3",
    "export_field_actor_bindings.py": "d7ba454289b802693b460d7cf686e5ce0755e286d47ac06321ffb9f874ba9bb1",
    "export_scene_population.py": "f9c2ff82c4349493980b3b9458b18235519a10080d8fc87ab4e4b4cc831b5c76",
    "opening_audience.py": "64ec5ce0671d8dbc4fa23a675239225c0fd8c711e22b1a444c05b9cd90d73f8b",
    "event_script_decode.py": "e6c1f021aa2d3b7e8ddca039443c0f9e974a0938738aef930e943ff1897f5f46",
    "event_vm_semantics.py": "1f318e68906f818af4950a4d33a081377ae65e11cb907961588ee0865d6a7db1",
    "export_first_room.py": "0ee3faa2eb2e3851f7bb3a0da1c07f647e42f99fa0d209d33b78820adbd79f54",
    "area_scene.py": "42a7ac42e56c2ffde69fb3002ddbbcb31325ab5184b930203a47dfd165a23232",
}
EXPECTED_COMMANDS = {
    compiler.AUDIENCE: 201,
    compiler.INIT_23: 2,
    compiler.INIT_24: 10,
    compiler.ARRIVAL: 28,
    E9_PROGRAM: 29,
}
SCENES = (("vaa_room2", "/VAA.BIN", 2), ("vb6_room6", "/VB6.BIN", 6))
EXECUTABLE_ENTRIES = {
    ("vaa_room2", 22): ("vaa_room2_entity_22", compiler.AUDIENCE),
    ("vaa_room2", 23): ("vaa_room2_entity_23", compiler.INIT_23),
    ("vaa_room2", 24): ("vaa_room2_entity_24", compiler.INIT_24),
    ("vb6_room6", 5): ("vb6_room6_entity_05", compiler.ARRIVAL),
    ("vb6_room6", 6): ("vb6_room6_entity_06", "vb6_room6_init_06"),
    ("vb6_room6", 9): ("vb6_room6_entity_09", E9_PROGRAM),
}


class BundleError(ValueError):
    pass


class E9Unsupported(BundleError):
    def __init__(self, row: tuple, detail: str):
        offset, opcode, operands, _ = row
        super().__init__(f"E9 {offset:#x}: {detail}")
        self.detail = {"source_offset": offset, "source_address": 0x80010000 + offset,
                       "opcode": opcode, "operands_hex": operands.hex(), "reason": detail}


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


def reference(content_id: str, content_hash: str, program_id: str) -> dict:
    return {"namespace": compiler.SCHEMA, "content_id": content_id,
            "content_sha256": content_hash, "program_id": program_id}


def ref_key(value: dict) -> tuple:
    return (value.get("namespace"), value.get("content_id"),
            value.get("content_sha256"), value.get("program_id"))


def read_json(root: Path, relative: str) -> dict:
    path = root / relative
    actual = file_hash(path)
    if actual != FROZEN[relative]:
        raise BundleError(f"frozen input changed: {relative}: {actual}")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise BundleError(f"frozen input is not an object: {relative}")
    return value


def load_inputs(root: Path = ROOT) -> dict:
    values = {name: read_json(root, name) for name in FROZEN}
    for name, expected in HELPER_HASHES.items():
        actual = file_hash(TOOLS / name)
        if actual != expected:
            raise BundleError(f"frozen helper changed: {name}: {actual}")
    corrected = binder.build(root)
    if corrected["packet"] != values["game/assets/scenes/bindings/field_actor_bindings.json"]:
        raise BundleError("corrected construction-binding packet does not match its frozen artifact")
    return values


def source_actor(bindings: dict, scene_id: str, program_id: str, selector: int, story: dict) -> str:
    state = {"story": story,
             "scene": {"phase": "active", "released_selectors": [], "construction_story": {}}}
    resolved = binder.resolve(bindings, scene_id, program_id, selector, state)
    if resolved["status"] != "resolved" or resolved.get("domain") != "scene_actor":
        raise BundleError(f"E9 selector {selector:#x} is not a constructed scene actor: {resolved}")
    return resolved["actor_id"]


def compile_e9(bindings: dict) -> tuple[dict | None, dict, dict | None]:
    """Lower every E9 operation through FrozenLowering, or return one full typed gap."""
    data, source_proof = source("/VB6.BIN")
    if sha256(data) != binder.SOURCE_HASHES["DATA/02_AREA.B/VB6.BIN"]:
        raise BundleError("VB6 original source identity changed")
    entry = scene.entities(data, scene.room_record(data, 6))[9]
    guard, guard_proof = compiler.source_predicate(data, entry["stream_offsets"][1], "event", E9_PROGRAM)
    start = entry["stream_offsets"][2]
    rows = compiler.decode_bounded(data, start, E9_PROGRAM)
    story = {"scenario_0015": 0x40, "scenario_0016": 0}
    actor = source_actor(bindings, "vb6_room6", E9_PROGRAM, 0, story)
    lowering = compiler.FrozenLowering("vb6_e09")
    actions = []
    spans = []
    tracks = []
    try:
        for row in rows:
            offset, opcode, args, note = row
            spans.append({"offset": offset, "opcode": opcode, "operands": args.hex()})
            if opcode == 0x36:
                action = {"kind": "queue_glyphs_a"}
            elif opcode == 0x37:
                action = {"kind": "queue_glyphs_b"}
            elif opcode in (0x33, 0x38):
                action = {"kind": "wait_text_queue_empty" if opcode == 0x33 else "wait_text_queue_drain_and_release"}
            elif opcode in (0x0B, 0x17):
                action = {"kind": "open_dialogue_box", "slot": 0 if opcode == 0x0B else 1, "layout": args[0]}
            elif opcode in (0x0C, 0x18):
                action = {"kind": "close_dialogue_box", "slot": 0 if opcode == 0x0C else 1}
            elif opcode == 0x12:
                action = {"kind": "start_or_wait_dialogue", "slot": args[0], "code": args[1]}
            elif opcode == 0x1C:
                text = vb6_arrival.text_reference(data, args[1], args[2])
                action = {"kind": "dialogue", "speaker_slot": args[0], "table": args[1],
                          "index": args[2], "pages": text["pages"]}
            elif opcode == 0x02:
                action = {"kind": "wait_for_accept"}
            elif opcode == 0x46:
                action = {"kind": "wait_event_flags_low2_clear"}
            elif opcode == 0x32:
                track_id = f"vb6_r06_entity09_track_{len(tracks):02d}"
                tracks.append({"id": track_id, "actor": actor, "commands": opening_audience.track(args[1:])})
                action = {"kind": "queue_track", "track": track_id}
            elif opcode == 0x11:
                parameter = (1, 3, 0, 2)[args[1]]
                mask = 1 if parameter in (1, 2) else 2
                kind = "descriptor_flags_or" if parameter in (1, 3) else "descriptor_flags_and"
                action = {"kind": kind, "selector": args[0], "parameter": parameter, "mask": mask}
            elif opcode == 0x3A:
                action = {"kind": "release_actor", "actor": source_actor(bindings, "vb6_room6", E9_PROGRAM, args[0], story)}
            elif opcode == 0x09:
                action = {"kind": "story_or", "byte_index": args[0], "mask": args[1], "scope": "persistent"}
            elif opcode == 0xFD:
                action = {"kind": "end_stream"}
            else:
                raise E9Unsupported(row, f"no source-action lowering for opcode {opcode:#x}; {note}")
            actions.append(action)
        commands = lowering.commands(actions, E9_PROGRAM)
    except (compiler.CompilationError, IndexError, KeyError, ValueError) as error:
        row = rows[len(actions)] if len(actions) < len(rows) else rows[-1]
        detail = error.detail if isinstance(error, E9Unsupported) else {
            "source_offset": row[0], "source_address": 0x80010000 + row[0],
            "opcode": row[1], "operands_hex": row[2].hex(), "reason": str(error)}
        gap = {"schema": "suikoden-event-compilation-gap/1", "id": E9_PROGRAM,
               "executable": False, "complete_program_suppressed": True,
               "source": source_proof | {"room": 6, "entity": 9, "stream_offset": start},
               "guard": guard, "guard_provenance": guard_proof,
               "unsupported": detail, "decoded_instruction_count": len(rows),
               "source_actions_translated_before_failure": len(actions),
               "partial_commands_emitted": False,
               "trigger_constraint": "ordinary source selection only; never auto-chain E7 into E9"}
        return None, {"source": source_proof, "instructions": spans}, gap
    actor_row = next(row for row in bindings["scenes"] if row["id"] == "vb6_room6")
    construction = next(row for row in actor_row["scene_actors"] if row["stable_actor_id"] == actor)
    content = compiler.identified({
        "schema": compiler.SCHEMA, "id": E9_CONTENT,
        "story_values": [compiler.story_value(15), compiler.story_value(16)],
        "actors": [{"id": actor, "character": construction["source_character_id"],
                    "x": 2032, "y": 2032, "attached": False, "conditions": []}],
        "texts": list(lowering.texts.values()), "tracks": tracks,
        "programs": [{"id": E9_PROGRAM, "entry": "ordinary", "entity": 9,
                      "trigger": "area_entry", "conditions": guard, "commands": commands}],
    })
    proof = {"source": source_proof, "room": 6, "entity": 9,
             "entry_offset": entry["offset"], "event_predicate_offset": entry["stream_offsets"][1],
             "stream_offset": start, "guard_provenance": guard_proof,
             "instructions": spans, "actor_binding": construction,
             "command_count": len(commands),
             "lowering": "Every source operation passed through compile_event_programs.FrozenLowering; no partial or replacement IR."}
    return content, proof, None


def embedded(content: dict, program_id: str, relation: str) -> dict:
    program = next(row for row in content["programs"] if row["id"] == program_id)
    return {"reference": reference(content["id"], content["content_sha256"], program_id),
            "relation": relation, "command_count": len(program["commands"]), "content": content}


def external(content: dict, program_id: str, asset: str, asset_sha256: str) -> dict:
    program = next(row for row in content["programs"] if row["id"] == program_id)
    return {"reference": reference(content["id"], content["content_sha256"], program_id),
            "relation": "required_external_verified", "command_count": len(program["commands"]),
            "source_asset": asset, "source_asset_sha256": asset_sha256}


def assemble_scene(scene_id: str, inputs: dict, e9_content: dict | None, e9_gap: dict | None) -> dict:
    population = inputs[f"game/assets/scenes/population/{scene_id}.json"]
    bindings = inputs["game/assets/scenes/bindings/field_actor_bindings.json"]
    binding_scene = next(row for row in bindings["scenes"] if row["id"] == scene_id)
    actor_by_entity = {row["source_entity_id"]: row for row in binding_scene["scene_actors"]}
    contents = []
    entry_programs = {}
    if scene_id == "vaa_room2":
        content = inputs["game/assets/events/vaa_audience_choice.json"]
        for program_id in (compiler.AUDIENCE, compiler.INIT_23, compiler.INIT_24):
            contents.append(embedded(content, program_id, "embedded_accepted"))
            entry_programs[content["programs"][[row["id"] for row in content["programs"]].index(program_id)]["entity"]] = contents[-1]["reference"]
    else:
        arrival = inputs["game/assets/events/vb6_room6_arrival.json"]
        contents.append(embedded(arrival, compiler.ARRIVAL, "embedded_accepted"))
        entry_programs[5] = contents[-1]["reference"]
        host_name = "game/assets/events/vb6_room6_field_host.json"
        host = inputs[host_name]
        contents.append(external(host, "vb6_room6_init_06", host_name, FROZEN[host_name]))
        entry_programs[6] = contents[-1]["reference"]
        if e9_content is not None:
            contents.append(embedded(e9_content, E9_PROGRAM, "embedded_new_complete"))
            entry_programs[9] = contents[-1]["reference"]
    entries = []
    for entity in population["entities"]:
        index = entity["source_order"]
        ref = entry_programs.get(index)
        status = "source_only"
        if ref is not None:
            linked = next(row for row in contents if row["reference"] == ref)
            status = "executable_embedded" if linked["relation"].startswith("embedded") else "executable_required_external"
        elif scene_id == "vb6_room6" and index == 7:
            status = "blocked_unsupported"
        row = {"source_entity_id": entity["id"], "source_order": index,
               "record_role": entity["record_role"], "trigger": entity["trigger"],
               "initialization_order": entity["initialization_order"],
               "guard": entity["event_selection"], "status": status,
               "program": ref, "resource_id": entity["resource_id"],
               "resource_domain": entity["resource_domain"]}
        if status == "source_only":
            row["unresolved"] = {"kind": "program_not_compiled", "executable": False,
                                 "source_stream_reference": entity["event"]["reference"]}
        if index == 7 and scene_id == "vb6_room6":
            row["gap"] = {"schema": "suikoden-event-compilation-gap/1",
                          "id": compiler.FOLLOWON_7, "executable": False,
                          "complete_program_suppressed": True,
                          "unsupported": {"source_offset": 0x35184, "source_address": 0x80035184,
                                          "opcode": 3, "operands_hex": "061b19",
                                          "kind": "room_coordinate_transition", "room": 6,
                                          "x_half_cell": 27, "y_half_cell": 25,
                                          "reason": "Frozen IR has no typed room/coordinate transition"},
                          "trigger_constraint": "ordinary source selection only; no automatic E7-to-E9 chain"}
        if index == 9 and scene_id == "vb6_room6" and e9_gap is not None:
            row["status"] = "blocked_unsupported"
            row["gap"] = e9_gap
        entries.append(row)
    resources = []
    for entity in population["entities"]:
        if entity["resource_id"] is None:
            continue
        binding = actor_by_entity.get(entity["id"])
        if binding is not None:
            binding_status, actor_id = "bound", binding["stable_actor_id"]
        elif entity["classification"]["pointer_state"] == "null":
            binding_status, actor_id = "not_constructed_null_classification", None
        else:
            binding_status, actor_id = "unsupported_actor", None
        resources.append({"source_entity_id": entity["id"], "source_order": entity["source_order"],
                          "actor_id": actor_id, "binding_status": binding_status,
                          "resource_id": entity["resource_id"], "resource_domain": entity["resource_domain"],
                          "position": entity["position"], "construction_classification": entity["classification"]})
    bundle = identified({
        "schema": SCHEMA, "id": scene_id,
        "source": population["source"],
        "population": {"content_id": population["id"], "content_sha256": population["content_sha256"]},
        "bindings": {"content_id": bindings["id"], "content_sha256": bindings["content_sha256"],
                     "acceptance_status": "locally_repaired_pending_independent_review",
                     "construction_rule": "Resolve compact descriptors from retained construction_story, never current story alone; release/reconstruction remain explicit lifecycle events."},
        "coordinate_contract": population["coordinate_contract"],
        "ordering": "entries preserve population source_order; initialization_order is the original relative initialization pump order",
        "entries": entries, "contents": contents, "resources": resources,
        "coverage": {
            "source_records": len(entries), "executable_entries": sum(row["status"].startswith("executable") for row in entries),
            "source_only_entries": sum(row["status"] == "source_only" for row in entries),
            "blocked_entries": sum(row["status"] == "blocked_unsupported" for row in entries),
            "bound_resources": sum(row["binding_status"] == "bound" for row in resources),
            "unresolved_actor_resources": sum(row["binding_status"] == "unsupported_actor" for row in resources),
        },
    })
    return bundle


def validate_bundle(bundle: dict, external_contents: list[dict]) -> None:
    if not isinstance(bundle, dict) or bundle.get("schema") != SCHEMA:
        raise BundleError("unsupported scene-event bundle schema")
    unsigned = dict(bundle, content_sha256="")
    if sha256(canonical(unsigned)) != bundle.get("content_sha256"):
        raise BundleError("bundle content identity mismatch")
    entries = bundle.get("entries")
    if not isinstance(entries, list) or [row.get("source_order") for row in entries] != list(range(len(entries))):
        raise BundleError("bundle source ordering is invalid")
    records = bundle.get("contents")
    if not isinstance(records, list):
        raise BundleError("bundle contents must be a list")
    by_ref = {}
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("reference"), dict):
            raise BundleError("malformed qualified content record")
        ref = record["reference"]
        key = ref_key(ref)
        if key in by_ref:
            raise BundleError("duplicate qualified program identity")
        if ref.get("namespace") != compiler.SCHEMA or any(not isinstance(ref.get(field), str) or not ref[field] for field in ("content_id", "content_sha256", "program_id")):
            raise BundleError("invalid qualified program reference")
        relation = record.get("relation")
        if relation.startswith("embedded"):
            content = record.get("content")
            if not isinstance(content, dict):
                raise BundleError("embedded content is missing")
            if sha256(canonical(dict(content, content_sha256=""))) != content.get("content_sha256"):
                raise BundleError("embedded frozen content identity mismatch")
            if ref["content_id"] != content.get("id") or ref["content_sha256"] != content.get("content_sha256"):
                raise BundleError("qualified content hash/identity mismatch")
            programs = [row for row in content.get("programs", []) if row.get("id") == ref["program_id"]]
            if len(programs) != 1:
                raise BundleError("qualified program is missing")
            if len(programs[0].get("commands", [])) != record.get("command_count"):
                raise BundleError("qualified program command-count mismatch")
            if EXPECTED_COMMANDS.get(ref["program_id"]) != record["command_count"]:
                raise BundleError("accepted/new program integrity baseline mismatch")
        elif relation == "required_external_verified":
            matches = []
            for content in external_contents:
                if sha256(canonical(dict(content, content_sha256=""))) != content.get("content_sha256"):
                    continue
                programs = [row for row in content.get("programs", []) if row.get("id") == ref["program_id"]]
                if (content.get("id") == ref["content_id"] and content.get("content_sha256") == ref["content_sha256"]
                        and len(programs) == 1):
                    matches.append((content, programs[0]))
            if len(matches) != 1:
                raise BundleError("required external qualified dependency is missing or incompatible")
            if len(matches[0][1].get("commands", [])) != record.get("command_count"):
                raise BundleError("required external program command-count mismatch")
        else:
            raise BundleError("unknown content relation")
        by_ref[key] = record
    for entry in entries:
        status = entry.get("status")
        ref = entry.get("program")
        if status.startswith("executable"):
            if not isinstance(ref, dict) or ref_key(ref) not in by_ref:
                raise BundleError("executable entry has a dangling qualified reference")
            contract = EXECUTABLE_ENTRIES.get((bundle["id"], entry.get("source_order")))
            if contract != (entry.get("source_entity_id"), ref.get("program_id")):
                raise BundleError("source entity is not authorized to execute this program")
            expected = "executable_required_external" if by_ref[ref_key(ref)]["relation"] == "required_external_verified" else "executable_embedded"
            if status != expected:
                raise BundleError("entry/link relation mismatch")
        elif status in ("source_only", "blocked_unsupported"):
            if ref is not None:
                raise BundleError("non-executable entry cannot fall back to a program")
        else:
            raise BundleError("unknown entry execution status")
    if bundle["id"] == "vb6_room6":
        init6 = reference("vb6_room6_arrival", "c193e2bd7f15276628062e480386f2ea609671f6c37bac5f9ece1ea88a37796d", "vb6_room6_init_06")
        if not any(row["reference"] == init6 and row["relation"] == "required_external_verified" for row in records):
            raise BundleError("required external init6 identity/integrity mismatch")
        if entries[7]["status"] != "blocked_unsupported" or entries[7]["program"] is not None:
            raise BundleError("E7 must remain a non-executable transition gap")
        for index in (8, 28):
            if entries[index]["status"] != "source_only" or entries[index]["program"] is not None:
                raise BundleError(f"init{index} must remain source-only")


def fixtures(bundles: dict, e9: dict) -> dict:
    base = {"story": {"scenario_0000": 0x40},
            "scene": {"phase": "active", "released_selectors": [], "construction_story": {"scenario_0000": 0}}}
    return identified({
        "schema": FIXTURE_SCHEMA, "id": "vaa_vb6_scene_event_bundle_cases",
        "bundle_content_sha256": {key: value["content_sha256"] for key, value in bundles.items()},
        "source_grounded_cases": [
            {"id": "vaa_initialization_order", "scene_id": "vaa_room2", "source_entities": [23, 24], "expected_programs": [compiler.INIT_23, compiler.INIT_24]},
            {"id": "vb6_conditional_initializers", "scene_id": "vb6_room6", "source_entities": [8, 28], "expected_status": "source_only", "expected_initialization_order": [1, 2]},
            {"id": "e7_not_chained", "scene_id": "vb6_room6", "source_entity": 7, "expected_status": "blocked_unsupported", "expected_program": None},
            {"id": "e9_complete", "scene_id": "vb6_room6", "source_entity": 9, "expected_status": "executable_embedded", "expected_program": E9_PROGRAM, "expected_commands": 29},
        ],
        "construction_lifetime_cases": [
            {"id": "story_change_retains_constructed", "selector": 12, "state": base, "expected": {"status": "resolved", "actor_id": "scene_actor_12"}},
            {"id": "story_change_does_not_construct", "selector": 12,
             "state": base | {"story": {"scenario_0000": 0}, "scene": base["scene"] | {"construction_story": {"scenario_0000": 0x40}}},
             "expected": {"status": "missing", "reason": "classification_rejected_inactive_slot"}},
        ],
        "e9_source_expectation": {
            "program_id": E9_PROGRAM, "content_id": e9["id"], "content_sha256": e9["content_sha256"],
            "guard": e9["programs"][0]["conditions"], "command_count": 29,
            "effect_command_indices": {"queue_track": 8, "descriptor_or_1": 9, "descriptor_and_2": 16,
                                       "release_actor": 24, "story_or": 27},
            "track": e9["tracks"][0], "terminal_flag": {"id": "scenario_0016", "mask": 1},
            "headless_host": "Complete text/track/queue/box/dialogue waits; apply descriptor operations using selector40/41 and record release/track; verify guard rejection before and after completion.",
        },
        "negative_contracts": ["wrong qualified hash", "same content ID with wrong content hash cannot select init6", "missing embedded program", "dangling executable reference", "duplicate qualified identity", "non-executable fallback program", "stale or missing generated output"],
    })


def build(input_root: Path = ROOT) -> dict:
    inputs = load_inputs(input_root)
    bindings = inputs["game/assets/scenes/bindings/field_actor_bindings.json"]
    e9, e9_proof, e9_gap = compile_e9(bindings)
    bundles = {scene_id: assemble_scene(scene_id, inputs, e9, e9_gap) for scene_id, _suffix, _room in SCENES}
    external_contents = [inputs["game/assets/events/vb6_room6_field_host.json"]]
    for bundle in bundles.values():
        validate_bundle(bundle, external_contents)
    if e9 is None:
        raise BundleError(f"E9 has a full non-executable gap: {e9_gap['unsupported']}")
    fixture = fixtures(bundles, e9)
    report = {
        "schema": REPORT_SCHEMA, "status": "SOURCE/MODULE IMPLEMENTED; PENDING INDEPENDENT REVIEW",
        "binder_status": "Two local repairs implemented and tested; independent re-review pending. Part2 freezes this binder and does not broaden it.",
        "inputs": {name: {"sha256": digest, "role": "accepted/read-only frozen dependency"} for name, digest in FROZEN.items()},
        "helpers_sha256": dict(HELPER_HASHES),
        "original_sources": {scene_id: bundles[scene_id]["source"] for scene_id, _suffix, _room in SCENES},
        "coverage": {scene_id: bundle["coverage"] for scene_id, bundle in bundles.items()},
        "programs": [{"scene_id": scene_id, **record["reference"], "relation": record["relation"],
                      "command_count": record["command_count"]}
                     for scene_id, bundle in bundles.items() for record in bundle["contents"]],
        "accepted_program_integrity": "The four accepted programs remain embedded as exact JSON values in their original accepted contents; source assets are never rewritten. Counts 201/2/10/28 are integrity checks, not scene coverage denominators.",
        "e9": e9_proof | {"status": "complete_frozen_ir", "content_id": e9["id"],
                           "content_sha256": e9["content_sha256"], "gap": None,
                           "headless_validation": "Private frozen-core harness required and reported separately; this deterministic report contains no runtime observation."},
        "unresolved": {
            "e7": "Non-executable typed room/coordinate transition gap at VB6 0x35184; no E7-to-E9 auto-chain.",
            "conditional_initializers": "VB6 entity8/init8 and entity28/init28 retain proven guards and source order but remain source_only; init6 alone is a verified required-external executable dependency.",
            "source_only_streams": "All remaining entries retain source guards/resources and are not dangling executable references or claimed completed coverage.",
            "actor_resources": "No unresolved actor/resource identities in the two packets; null-classified records are deliberately not constructed, not unsupported fallbacks.",
        },
        "contract": {
            "qualified_reference": "Every program reference is namespace + content_id + content_sha256 + program_id. Shared program/content IDs with different content hashes cannot be selected by ID alone.",
            "entry_status": "executable_embedded, executable_required_external, source_only, or blocked_unsupported. Only the first two may carry a program reference.",
            "resources": "Source entity, stable actor, resource and party/dynamic selector domains remain distinct. Construction classification is a construction-time fact, not a current-story vote.",
            "generation": "Five deterministic outputs; --check recomputes and compares without repairs. No timestamps, absolute paths, runtime observations or live exports.",
            "integration_limit": "Offline source/module assembly only. No runtime/core/compiler/host changes, live actor creation, dispatch, world/field/save integration or gameplay acceptance.",
        },
        "registry_rows": ["SEB01", "SEB02", "SEB03", "SEB04", "SEB05"],
    }
    registry = [
        {"id": "SEB01", "stage": "X_SCENE_EVENT_BUNDLE", "class": "script", "claim": "VAA room2 and VB6 room6 entries retain source order, event guards, resources and qualified program identities across population, binding and event-content boundaries.", "addr": "MAIN:0x8013F1BC;MAIN:0x8013F2A4;MAIN:0x8013DB6C;MAIN:0x8013E1F8", "evidence": "proven", "source": "kit/tools/export_scene_event_bundles.py;kit/tests/test_scene_event_bundles.py;kit/data/reports/scene_event_bundles.json", "superseded_by": "", "note": "source_only and blocked entries are not executable coverage."},
        {"id": "SEB02", "stage": "X_SCENE_EVENT_BUNDLE", "class": "script", "claim": "The accepted VAA audience/init23/init24 and VB6 arrival retain exact content and command integrity; VB6 init6 is a required external reference qualified by its distinct field-host content hash.", "addr": "VAA:0x50D80;VAA:0x50FF8;VAA:0x50FFC;VB6:0x35128;VB6:0x3512C", "evidence": "proven", "source": "game/assets/events/vaa_audience_choice.json;game/assets/events/vb6_room6_arrival.json;game/assets/events/vb6_room6_field_host.json", "superseded_by": "", "note": "Program ID alone is insufficient; the two VB6 contents share vb6_room6_arrival with different hashes."},
        {"id": "SEB03", "stage": "X_SCENE_EVENT_BUNDLE", "class": "script", "claim": "VB6 entity9 lowers completely to 29 frozen-IR commands through FrozenLowering, including its source track, descriptor transitions, actor release and terminal scenario_0016 OR1.", "addr": "VB6:0x351A0;VB6:0x351AE;VB6:0x351C2;VB6:0x351D2;VB6:0x351D6;MAIN:0x8013C354;MAIN:0x8013CCF0;MAIN:0x8013C82C", "evidence": "proven", "source": "kit/tools/export_scene_event_bundles.py;kit/tools/compile_event_programs.py;kit/tools/export_field_actor_bindings.py", "superseded_by": "", "note": "Module/source completeness and private headless evidence do not establish live gameplay integration."},
        {"id": "SEB04", "stage": "X_SCENE_EVENT_BUNDLE", "class": "script", "claim": "VB6 entity7 remains non-executable because inline03 format06 performs a room/coordinate transition absent from frozen IR; it is never auto-chained to entity9.", "addr": "VB6:0x35184;MAIN:0x8013BF94", "evidence": "proven", "source": "kit/tools/compile_event_programs.py;kit/tools/export_scene_event_bundles.py", "superseded_by": "", "note": "The full gap records source offset0x35184, operands061b19 and transition room6 half-cell27/25."},
        {"id": "SEB05", "stage": "X_SCENE_EVENT_BUNDLE", "class": "script", "claim": "Constructed scene bindings use retained construction-story facts; current story changes alone neither remove nor create descriptors, while explicit reconstruction and release remain lifecycle boundaries.", "addr": "MAIN:0x8012EF58;MAIN:0x8013CCF0;MAIN:0x8013C82C", "evidence": "proven", "source": "kit/tools/export_field_actor_bindings.py;kit/tests/test_field_actor_bindings.py", "superseded_by": "", "note": "Binder repair is locally tested and pending independent re-review; no permanent-death or replacement semantics are inferred."},
    ]
    return {"bundles": bundles, "fixtures": fixture, "report": report, "registry": registry,
            "e9": e9, "e9_proof": e9_proof, "inputs": inputs}


def output_bytes(exported: dict) -> dict[str, bytes]:
    return {
        "kit/data/reports/scene_event_bundles.json": serialize(exported["report"]),
        "kit/data/registry/extract_scene_event_bundles.jsonl": "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in exported["registry"]).encode(),
        "game/assets/scenes/events/vaa_room2.json": serialize(exported["bundles"]["vaa_room2"]),
        "game/assets/scenes/events/vb6_room6.json": serialize(exported["bundles"]["vb6_room6"]),
        "game/tests/fixtures/scene_event_bundles.json": serialize(exported["fixtures"]),
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
    parser.add_argument("--input-root", type=Path, default=ROOT, help="root of frozen input artifacts")
    parser.add_argument("--output-root", type=Path, default=ROOT, help="root for the five logical outputs; may be temporary")
    parser.add_argument("--check", action="store_true", help="read-only comparison; never create or repair outputs")
    args = parser.parse_args(argv)
    try:
        expected = output_bytes(build(args.input_root.resolve()))
        mismatches = []
        for relative, data in expected.items():
            path = args.output_root.resolve() / relative
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
        print(("checked" if args.check else "generated") + " 5 scene-event outputs; embedded programs 5; required external 1; E9 complete")
        return 0
    except (BundleError, compiler.CompilationError, binder.BindingError, OSError, KeyError, IndexError, TypeError, json.JSONDecodeError) as error:
        print(f"scene-event export failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
