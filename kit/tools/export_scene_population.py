#!/usr/bin/env python3
"""Compile source room records into versioned scene-population packets."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import area_scene as scene
import maindec
from export_first_room import source

SCHEMA = "suikoden-scene-population/1"
PREDICATE_OPERANDS = {
    0x01: 2, 0x02: 2, 0x03: 0, 0x04: 1, 0x05: 0,
    0x07: 2, 0x08: 2, 0x09: 2, 0x0A: 2,
    0x0B: 2, 0x0C: 2, 0x0D: 1, 0x0E: 1, 0x0F: 1,
    0x10: 1, 0x11: 1, 0x12: 1, 0x13: 2, 0x14: 2,
    0x15: 1, 0x16: 1, 0x17: 1, 0x18: 1, 0x19: 1,
}
ROOMS = (
    ("/VAA.BIN", 2, "vaa_room2"),
    ("/VB6.BIN", 6, "vb6_room6"),
)
KNOWN_PROGRAMS = {
    ("VAA.BIN", 2, 22): ("vaa_room2_audience", "vaa_audience_choice", "interaction", 0x50D80),
    ("VAA.BIN", 2, 23): ("vaa_room2_init_23", "vaa_audience_choice", "initialization", 0x50FF8),
    ("VAA.BIN", 2, 24): ("vaa_room2_init_24", "vaa_audience_choice", "initialization", 0x50FFC),
    ("VB6.BIN", 6, 5): ("vb6_r06_first_arrival", "vb6_room6_arrival", "area_entry", 0x35128),
}
HELPERS = (
    "disc.py", "export_first_room.py", "area_scene.py", "maindec.py",
    "event_script_decode.py", "event_vm_semantics.py",
    "opening_audience.py", "opening_events.py",
)


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
    return f"scenario_{index:04d}"


def story_flag(index: int, mask: int) -> dict:
    if not 0 <= index < 240 or not 0 < mask <= 255:
        raise ValueError(f"invalid story predicate byte/mask {index}/{mask}")
    return {"id": story_id(index), "mask": mask}


EXTENDED_SCHEMA = "suikoden-scene-population/3"
PAD_DIRECTION_MASKS = (0x1000, 0x2000, 0x4000, 0x8000)


class ReservedActorPredicate(ValueError):
    pass


def inherits_actor(entity):
    return bool(entity['flags'] & 0x101) and entity['stream_ptrs'][0] == 0


def actor_allocation_order(entities):
    """Source descriptor order: every non-null classifier reserves one slot."""
    return [i for i, entity in enumerate(entities)
            if entity['flags'] & 0x101 and entity['stream_ptrs'][0] != 0]


def interaction_actor_candidates(data, entities, index):
    """Resolve count-1 to its fixed constructor, including inactive reservations."""
    prior = [i for i in actor_allocation_order(entities) if i < index]
    if not prior:
        return None
    previous = prior[-1]
    entity = entities[previous]
    if entity['stream_offsets'][0] is None:
        return None
    try:
        predicate, _ = decode_predicate(data, entity['stream_offsets'][0], 'classification', full=True)
    except ReservedActorPredicate:
        return None
    if any(term['kind'] not in ('story_mask_set', 'story_mask_clear', 'recruit_present', 'recruit_absent', 'stage_at_least', 'party_excludes') for term in predicate['terms']):
        return None
    return [previous]


def decode_predicate(
    data: bytes,
    offset: int | None,
    domain: str,
    *,
    coordinate_ranges: bool = False,
    full: bool = False,
) -> tuple[dict, dict]:
    if offset is None:
        return {"pointer_state": "null", "terms": []}, {"offset": None, "size": 0, "terms": []}
    if domain not in ("classification", "event") or not scene.in_file(data, offset):
        raise ValueError(f"invalid {domain} predicate offset {offset!r}")
    terms = []
    proof_terms = []
    cursor = offset
    for _ in range(64):
        opcode_offset = cursor
        if not scene.in_file(data, cursor):
            raise ValueError(f"truncated {domain} predicate at {offset:#x}")
        opcode = data[cursor]
        cursor += 1
        if opcode == 0x06:
            proof_terms.append({"offset": opcode_offset, "opcode": opcode, "kind": "accept", "operands": []})
            return ({"pointer_state": "present", "terms": terms},
                    {"offset": offset, "size": cursor - offset, "terms": proof_terms})
        if opcode == 0x00:
            proof_terms.append({"offset": opcode_offset, "opcode": opcode, "kind": "nop", "operands": []})
            continue
        if opcode not in PREDICATE_OPERANDS:
            raise ValueError(f"unsupported {domain} predicate opcode {opcode:#x} at {opcode_offset:#x}")
        if domain == "classification" and opcode in {1, 2, 3, 4, 5, 0x0B, 0x0C, 0x0D, 0x12, 0x17, 0x18}:
            raise ReservedActorPredicate(f"opcode {opcode:#x} always rejects in classification at {opcode_offset:#x}")
        count = PREDICATE_OPERANDS[opcode]
        args = tuple(data[cursor:cursor + count])
        if len(args) != count:
            raise ValueError(f"truncated {domain} predicate at {opcode_offset:#x}")
        cursor += count
        proof = {"offset": opcode_offset, "opcode": opcode, "operands": list(args)}
        if opcode in (0x07, 0x08):
            kind = "story_mask_set" if opcode == 0x07 else "story_mask_clear"
            term = {"kind": kind, "flag": story_flag(args[0], args[1])}
            proof["kind"] = kind
            proof["byte_index"], proof["mask"] = args
        elif opcode == 0x05 and domain == "event":
            term = {"kind": "interaction"}
            proof["kind"] = "interaction"
        elif (coordinate_ranges or full) and opcode in (0x0B, 0x0C):
            first, last = args
            if first > last and not full:
                raise ValueError(f"reversed event coordinate range at {opcode_offset:#x}")
            term = {"kind": "coordinate_range", "coordinate": {
                "axis": "x" if opcode == 0x0B else "y", "first": first, "last": last,
            }}
            proof["kind"] = "coordinate_range"
        elif full:
            if opcode in (0x01, 0x02):
                first, last = args
                kind = "hero_x_strict" if opcode == 0x01 else "hero_y_strict"
                term = {"kind": kind, "coordinate": {
                    "axis": "x" if opcode == 0x01 else "y", "first": first, "last": last,
                }}
            elif opcode == 0x03:
                term = {"kind": "confirm_pressed"}
            elif opcode == 0x04:
                idx = args[0]
                if idx >= len(PAD_DIRECTION_MASKS):
                    raise ValueError(f"invalid pressed_mask index {idx} at {opcode_offset:#x}")
                term = {"kind": "pressed_mask", "index": idx, "mask": PAD_DIRECTION_MASKS[idx]}
            elif opcode in (0x09, 0x0A):
                kind = "room_mask_set" if opcode == 0x09 else "room_mask_clear"
                term = {"kind": kind, "index": args[0], "mask": args[1]}
            elif opcode == 0x0D:
                term = {"kind": "money_at_least", "amount": args[0] * 100}
            elif opcode in (0x0E, 0x0F):
                kind = "party_contains" if opcode == 0x0E else "party_excludes"
                term = {"kind": kind, "character_id": args[0]}
            elif opcode in (0x10, 0x11, 0x19):
                kind = {0x10: "recruit_present", 0x11: "recruit_absent", 0x19: "recruit_ever"}[opcode]
                term = {"kind": kind, "slot": args[0]}
            elif opcode == 0x12:
                term = {"kind": "party_count_equals", "count": args[0]}
            elif opcode == 0x13:
                term = {"kind": "level_at_least", "character_id": args[0], "level": args[1]}
            elif opcode == 0x14:
                term = {"kind": "stage_at_least", "stage": args[1]}
            elif opcode == 0x15:
                term = {"kind": "random_chance", "divisor": args[0] + 1}
            elif opcode == 0x16:
                term = {"kind": "recruit_count_at_least", "count": args[0]}
            elif opcode in (0x17, 0x18):
                term = {"kind": "has_item", "item_id": args[0], "require_key": opcode == 0x18}
            else:
                raise ValueError(f"unhandled predicate opcode {opcode:#x} at {opcode_offset:#x}")
            proof["kind"] = term["kind"]
        else:
            semantics = f"{domain}_predicate_{opcode:02x}"
            term = {"kind": "unsupported", "semantics": semantics}
            proof["kind"] = "unsupported"
            proof["semantics"] = semantics
            proof["meaning"] = "unresolved"
        terms.append(term)
        proof_terms.append(proof)
    raise ValueError(f"unterminated {domain} predicate at {offset:#x}")


def convert_position(x: int, y: int, half_width: int, half_height: int, character: bool) -> dict:
    if not character:
        placement = "not_applicable"
    elif 0 < x < half_width and 0 < y < half_height:
        placement = "placed"
    elif x == 0 and y == 0:
        placement = "unpositioned"
    else:
        placement = "off_map_staging"
    if not 0 <= x <= 255 or not 0 <= y <= 255:
        raise ValueError(f"source entity coordinate outside original byte-consumer range: {(x, y)}")
    return {"source_x": x, "source_y": y, "x": x * 8, "y": y * 8, "placement": placement}


def resolve_resource(bindings: dict, source_id: int, packet_id: str, entity_index: int) -> tuple[str, str, dict]:
    resource = source_id & 0xFF
    binding = bindings.get(resource)
    if binding is not None and binding.get("context") is not None:
        return f"{packet_id}_character_{resource:03d}", "area_character_context", dict(binding)
    return (f"party_character_{resource:03d}", "active_party_character",
            {"id": resource, "fallback": "active_party_character", "entity_index": entity_index})


def compile_room(suffix: str, room_number: int, packet_id: str) -> tuple[dict, dict]:
    data, source_proof = source(suffix)
    filename = source_proof["file"].rsplit("/", 1)[-1]
    record = scene.room_record(data, room_number)
    if record is None:
        raise ValueError(f"missing source room {filename}/{room_number}")
    source_entities = scene.entities(data, record)
    if len(source_entities) != record["entity_count"]:
        raise ValueError(f"truncated entity array for {packet_id}")
    section = scene.section_off(data, record["section"])
    if section is None:
        raise ValueError(f"missing section for {packet_id}")
    half_width, half_height = scene.u16(data, section) * 2, scene.u16(data, section + 2) * 2
    bindings = scene.character_bindings(data, section)

    entities = []
    proof_entities = []
    programs = {}
    initialization_order = 0
    for entry in source_entities:
        index = entry["index"]
        source_id = entry["id"]
        character = source_id != 0
        role = "initialization" if entry["flags"] & 0x10 else "character" if character else "event"
        resource_id = None
        resource_domain = None
        binding_proof = None
        if character:
            resource_id, resource_domain, binding_proof = resolve_resource(bindings, source_id, packet_id, index)
        classification, classification_proof = decode_predicate(data, entry["stream_offsets"][0], "classification")
        event_selection, event_proof = decode_predicate(data, entry["stream_offsets"][1], "event")
        stream_offset = entry["stream_offsets"][2]
        if stream_offset is None:
            raise ValueError(f"unresolved event stream for {packet_id} entity {index}")
        link = KNOWN_PROGRAMS.get((filename, room_number, index))
        reference = f"{packet_id}_entity_{index:02d}_stream"
        event = {"reference": reference, "status": "source_only", "program_id": None}
        if link:
            program_id, content_id, trigger, expected_stream = link
            if stream_offset != expected_stream:
                raise ValueError(f"resolved event reference mismatch for {packet_id} entity {index}: {stream_offset:#x} != {expected_stream:#x}")
            event = {"reference": reference, "status": "resolved", "program_id": program_id}
            programs[program_id] = {"id": program_id, "namespace": "suikoden-event-ir/1", "content_id": content_id}
        else:
            trigger = "initialization" if role == "initialization" else "ordinary"
            if any(term["kind"] == "interaction" for term in event_selection["terms"]):
                trigger = "interaction"
        init_index = None
        if role == "initialization":
            init_index = initialization_order
            initialization_order += 1
        stable_id = f"{packet_id}_entity_{index:02d}"
        entities.append({
            "id": stable_id,
            "source_order": index,
            "record_role": role,
            "population_candidate": character and bool(entry["flags"] & 0x101),
            "source_character_id": source_id if character else None,
            "resource_id": resource_id,
            "resource_domain": resource_domain,
            "position": convert_position(entry["x_half"], entry["y_half"], half_width, half_height, character),
            "classification": classification,
            "event_selection": event_selection,
            "trigger": trigger,
            "initialization_order": init_index,
            "event": event,
        })
        proof_entities.append({
            "id": stable_id, "entity_index": index, "entry_offset": entry["offset"],
            "source_flags": entry["flags"], "source_character_id": source_id,
            "classification": classification_proof, "event_predicate": event_proof,
            "event_stream_offset": stream_offset, "resource_binding": binding_proof,
            "event_program_id": event["program_id"],
        })

    story_indices = sorted({
        term["flag"]["id"] for entity in entities
        for predicate in (entity["classification"], entity["event_selection"])
        for term in predicate["terms"] if term["kind"].startswith("story_mask_")
    })
    story_values = [{"id": ident, "storage": "scenario", "byte_index": int(ident[9:])} for ident in story_indices]
    packet = identified({
        "schema": SCHEMA,
        "id": packet_id,
        "source": source_proof | {"room": room_number},
        "coordinate_contract": {
            "source_units": "half_cell",
            "pixel_units": "pixel",
            "source_to_pixel": "pixel = source * 8",
            "axes": "x_right_y_down",
            "origin": "room_top_left",
            "source_coordinate_max": 255,
            "pixel_coordinate_max": 2040,
            "room_half_width": half_width,
            "room_half_height": half_height,
        },
        "duplicate_policy": "preserve_source_records",
        "story_values": story_values,
        "programs": list(programs.values()),
        "entities": entities,
    })
    proof = {
        "source": source_proof,
        "room": {
            "record_offset": record["record_off"], "entity_array_offset": record["entity_off"],
            "entity_stride": scene.ENTITY_STRIDE, "entity_count": record["entity_count"],
            "section_index": record["section"], "section_offset": section,
            "half_width": half_width, "half_height": half_height,
        },
        "entities": proof_entities,
        "resource_bindings": [dict(bindings[key]) for key in sorted(bindings, key=lambda key: bindings[key]["index"])],
        "packet_content_sha256": packet["content_sha256"],
    }
    return packet, proof


def make_bounds_invalid(packet: dict) -> dict:
    result = copy.deepcopy(packet)
    positioned = next(entity for entity in result["entities"] if entity["position"]["placement"] == "placed")
    positioned["position"]["source_x"] = 256
    positioned["position"]["x"] = 2048
    return result


def export() -> dict:
    compiled = [compile_room(*spec) for spec in ROOMS]
    packets = {packet["id"]: packet for packet, _ in compiled}
    proofs = {packet["id"]: proof for packet, proof in compiled}
    report = {
        "schema": "suikoden-scene-population-report/1",
        "status": "MODULE/SOURCE IMPLEMENTED; PENDING INDEPENDENT REVIEW",
        "target": "Suikoden US v1.1 SLUS_002.92",
        "compiler": "kit/tools/export_scene_population.py",
        "regenerate": "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B kit/tools/export_scene_population.py",
        "input_requirements": "Private original US v1.1 disc through disc.py and the tracked ISO catalogue; no extracted binary aliases.",
        "helpers_sha256": {name: file_hash(TOOLS / name) for name in HELPERS},
        "address_conversion": {
            "VAA/VB6": "absolute source pointer - 0x80010000 = overlay file offset; no PS-X header",
            "MAIN.EXE": "file offset 2048 + (VA - 0x800C0800); header excluded from image addresses",
        },
        "source_consumer_evidence": {
            "room_selection": "MAIN 0x8013F1BC indexes the requested 16-byte room record directly and walks its declared count in source order at 0x8013F200/0x8013F218/0x8013F268.",
            "population_candidate": "MAIN 0x8012EF40 requires source flags & 0x101, then 0x8012EF58 calls the classification consumer; result 0 builds, result 1 skips, result 2 reserves an inactive slot.",
            "classification": "MAIN 0x8013D8E0 returns 0 present, 1 null, 2 rejected. Story mask opcodes 07/08 are consumed through 0x8013D6CC.",
            "event_selection": "MAIN 0x8013DB6C evaluates entry+0x10 separately; 0x8013F1BC selects the first ordinary match and 0x8013F2A4 visits every initialization record in order.",
            "event_reference": "MAIN 0x8013E1F8/0x8013E204 reads entry+0x14 into the event cursor. This is independent of classification and event predicates.",
            "resource_identity": "MAIN 0x8012F198 reads entry+6; 0x801346A8 masks the ID to a byte, matches section+0x34 ID records, and selects section+0x20[j+1] at 0x801346F8/0x80134704. A missing custom binding takes the active-party fallback at 0x80134740..0x801347A8, using the logical count and loaded character+0x28 at 0x80134784; packets label that domain party_character_NNN rather than guessing an area context.",
            "coordinates": "MAIN 0x8012EF88 and 0x8012EFB4 consume source X/Y as bytes into the 24-byte runtime entity. MAIN 0x801317D8/0x801317EC and the independent area_scene.npc_primitives consumer multiply cell coordinates by 8 for pixels. Source values above 255 are rejected rather than truncated.",
            "placement": "area_scene.npc_primitives uses 0 < x < section_width*2 and 0 < y < section_height*2 for in-map placement, preserves zero-position records separately, and treats other coordinates as off-map staging. No x<1000 pixel heuristic is used.",
            "party_count": "No classification term in either selected room reads active-party count. Count inputs therefore do not alter population. The separate VB6 arrival party-prefix effect is bounded by MAIN *(0x8017C164)+3, not storage capacity.",
        },
        "rooms": proofs,
        "contract": {
            "schema": SCHEMA,
            "identity": "content_sha256 is SHA-256 of canonical JSON with content_sha256 set to an empty string and a trailing newline.",
            "ordering": "source_order equals the zero-based source record index; no display-name/resource sort or duplicate collapse is permitted.",
            "coordinates": "Unsigned source half-cell values 0..255 are retained and also emitted as exact pixels 0..2040. X grows right and Y down from the room top-left.",
            "predicates": "Classification terms are conjunctions. Story terms use event_runtime.Condition-compatible kind/flag objects and host-owned StoryState.matches. Interaction and unresolved terms are metadata, not population votes.",
            "resource_identities": "resource_domain=area_character_context resolves through the source section; active_party_character requires the host's loaded party resource. Neither domain is a portrait index or live actor instance.",
            "event_references": "resolved names an existing suikoden-event-ir/1 program; source_only preserves a valid original stream for later export without claiming execution.",
            "runtime_bounds": "Implementation limits: at most 255 entities, 16 predicate terms per list, 64 resolved programs, and 1 MiB JSON input. These are not original game limits.",
        },
        "zig_api": {
            "load": "load(allocator, bytes) returns std.json.Parsed(Packet); caller owns it and must deinit. Validation failure deinitializes partial decode state.",
            "validate": "validate(packet) checks the complete schema, identities, source order, coordinates, predicates and program references before selection.",
            "select": "select(packet, facts, output) returns Selection.entities aliasing caller-owned output. Entity strings and predicate slices remain borrowed from the validated Packet. No allocation, gameplay mutation, event dispatch or filesystem access occurs.",
            "facts": "Facts borrows a host-owned event_runtime.StoryState and supplies active_party_count. Story masks are evaluated only through StoryState.matches; counts 0,1,3,6 are irrelevant to these two classification sets.",
            "errors": "Malformed/unsupported content, unsupported classification, and insufficient output return errors before any output element is exposed or written. Event-only unresolved predicates do not block population selection.",
        },
        "limitations": [
            "Pure compiler/validator/selector only; no live actor creation, event dispatch, field/world integration, or save writes.",
            "Only classification is evaluated for population. Event-selection predicates, interaction feasibility, initialization pumps, and source_only streams remain host/event-owner work.",
            "Unresolved predicate semantics remain explicit unsupported terms. Unknown opcodes and missing stream pointers fail compilation with room/entity context where applicable; character IDs without area bindings use the proven active-party fallback domain.",
            "Party-count inputs 0, 1, 3, and 6 do not affect either room's classification; this is not a universal six-member party invariant.",
            "The event foundation is fixed in this handoff and pending independent review; this module borrows its Condition and StoryState.matches boundary without changing it.",
        ],
    }
    registry = [
        {
            "id": "SPOP01", "stage": "X_SCENE_POPULATION", "class": "script",
            "claim": "VAA room2 and VB6 room6 compile every source entity record in original order with distinct record roles, population-candidate flags, byte-backed character resource identities, null/unconditional/story-mask classification, separate event predicates and stream references.",
            "addr": "MAIN:0x8012EF40;MAIN:0x8013D8E0;MAIN:0x8013DB6C;MAIN:0x8013F1BC;MAIN:0x8013F2A4;MAIN:0x8013E1F8;MAIN:0x801346A8",
            "evidence": "proven",
            "source": "kit/tools/export_scene_population.py;kit/tests/test_scene_population.py;kit/data/reports/scene_population.json",
            "superseded_by": "",
            "note": "VAA has 26 records and VB6 has 36. VB6 retains all 26 character streams as source_only except separate entity5 arrival. No character stream or follow-on is promoted by this packet.",
        },
        {
            "id": "SPOP02", "stage": "X_SCENE_POPULATION", "class": "graphics",
            "claim": "Source entity X/Y are unsigned half-cell coordinates consumed as bytes and scaled exactly by8 to pixels. In-map, zero-position and off-map staging roles use source room dimensions; VB6 placed positions are216/144,272/232,64/192 and its23 staged records are2032/2032.",
            "addr": "MAIN:0x8012EF88;MAIN:0x8012EFB4;MAIN:0x801317D8;MAIN:0x801317EC",
            "evidence": "proven",
            "source": "kit/tools/export_scene_population.py;kit/tools/area_scene.py;kit/tests/test_scene_population.py",
            "superseded_by": "",
            "note": "Values above the original byte-consumer range are explicit errors rather than truncated source. Coordinates are source facts, not live actor state.",
        },
        {
            "id": "SPOP03", "stage": "X_SCENE_POPULATION", "class": "script",
            "claim": "The pure Zig validator checks the complete versioned packet before selection, preserves source order, and resolves story-mask classification through the host-owned event_runtime.StoryState without a second predicate evaluator or gameplay-state owner.",
            "addr": "",
            "evidence": "proven",
            "source": "game/src/scene_population.zig;game/tests/scene_population.zig;kit/tests/test_scene_population.py",
            "superseded_by": "",
            "note": "MODULE/SOURCE IMPLEMENTED pending independent review. Unsupported semantics, malformed content, bad references and insufficient output fail without a partial population. Host integration and atomic saves are not supplied.",
        },
    ]
    return {
        "packets": packets,
        "report": report,
        "registry": registry,
        "bounds_invalid": make_bounds_invalid(packets["vaa_room2"]),
    }


def write_tree(root: Path = ROOT) -> None:
    exported = export()
    outputs = {
        root / "kit/data/reports/scene_population.json": exported["report"],
        root / "game/tests/fixtures/scene_population/bounds_invalid.json": exported["bounds_invalid"],
    }
    for packet_id, packet in exported["packets"].items():
        outputs[root / f"game/assets/scenes/population/{packet_id}.json"] = packet
        outputs[root / f"game/tests/fixtures/scene_population/{packet_id}.json"] = packet
    for path, value in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(serialize(value))
    registry_path = root / "kit/data/registry/extract_scene_population.jsonl"
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    registry_path.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in exported["registry"]))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT, help="output tree root; defaults to repository-owned packet paths")
    args = parser.parse_args()
    write_tree(args.output.resolve())
    print("Exported VAA room2 and VB6 room6 through suikoden-scene-population/1")


if __name__ == "__main__":
    main()
