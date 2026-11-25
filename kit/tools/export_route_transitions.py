#!/usr/bin/env python3
"""Compile the proven region-B/VB6/region-C transitions into an offline route packet."""
from __future__ import annotations

import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import area_scene as scene
import compile_event_programs as event_compiler
import event_script_decode
import event_vm_semantics
import export_journey as journey
import export_world_travel as world_travel
import maindec
import opening_audience
import vb6_arrival
from export_common import (
    atomic_write,
    canonical,
    identified,
    jsonl_bytes,
    run_exporter,
    serialize,
    sha256,
)
from export_first_room import source, village_content

SCHEMA = "suikoden-route-transitions/1"
FIXTURE_SCHEMA = "suikoden-route-transition-fixtures/1"
REPORT_SCHEMA = "suikoden-route-transition-report/1"
BASE = 0x80010000
OUTPUTS = (
    "kit/data/reports/route_transitions.json",
    "kit/data/registry/extract_route_transitions.jsonl",
    "game/assets/routes/region_b_vb6_c.json",
    "game/tests/fixtures/route_transitions.json",
)
HELPERS = (
    "disc.py", "export_first_room.py", "export_journey.py", "export_world_travel.py",
    "area_scene.py", "event_script_decode.py", "event_vm_semantics.py",
    "compile_event_programs.py", "export_field_actor_bindings.py", "maindec.py",
    "opening_audience.py",
)
ROOM_SPECS = (
    (0, ((0, bytes.fromhex("41 6c")),)),
    (1, ((0, bytes.fromhex("41 33")), (1, b""))),
    (2, tuple((index, b"") for index in range(4))),
    (3, tuple((index, b"") for index in range(6))),
    (4, tuple((index, b"") for index in range(4))),
    (5, ((0, b""), (1, b""))),
    (6, ((0, b""),)),
)
ROOM_IDS = {number: name for number, name in journey.ROOMS.items() if 0 <= number <= 6}
CONSUMERS = ["MAIN:0x8013DB6C", "MAIN:0x8013E028", "MAIN:0x8013BF94"]


class RouteError(ValueError):
    pass


def flag(index: int, mask: int) -> dict:
    if not 0 <= index < 240 or not 0 < mask <= 255:
        raise RouteError(f"invalid scenario reference {index}/{mask}")
    return {"id": f"scenario_{index:04d}", "mask": mask}


def coordinate(domain: str, x: int, y: int) -> dict:
    if domain not in ("half_cell", "field_pixel", "world_cell"):
        raise RouteError(f"unknown coordinate domain {domain}")
    return {"domain": domain, "x": x, "y": y}


def effect_from_row(data: bytes, row: tuple, track_count: int = 0) -> dict:
    offset, opcode, args, _note = row
    names = {
        0x07: "glyph_descriptor_display", 0x32: "queue_track",
        0x33: "wait_text_queue_empty", 0x11: "descriptor_state_transition",
        0x0B: "open_dialogue_box", 0x12: "start_or_wait_dialogue",
        0x1C: "dialogue", 0x02: "wait_for_accept", 0x0C: "close_dialogue_box",
        0x46: "wait_event_flags_low2_clear", 0x09: "story_or", 0x41: "area_index_set",
    }
    if opcode not in names:
        raise RouteError(f"unsupported transition prefix opcode {opcode:#x} at {offset:#x}")
    effect = {"kind": names[opcode], "source_offset": offset,
              "source_address": BASE + offset, "operands": list(args)}
    if opcode == 0x41:
        table = 0x80171C2C + 2 * args[0]
        effect["area_index"] = struct.unpack_from("<H", maindec.body(), table - maindec.MBASE)[0]
        effect["area_index_source_address"] = table
    elif opcode == 0x09:
        effect["flag"] = flag(args[0], args[1])
    elif opcode == 0x32:
        effect["track"] = {"id": f"vb6_r06_e07_track_{track_count:02d}",
                           "selector": args[0], "commands": opening_audience.track(args[1:])}
    elif opcode == 0x11:
        parameter = (1, 3, 0, 2)[args[1]]
        effect.update(selector=args[0], parameter=parameter,
                      mask=1 if parameter in (1, 2) else 2)
    elif opcode == 0x0B:
        effect.update(slot=0, layout=args[0])
    elif opcode == 0x12:
        effect.update(slot=args[0], code=args[1])
    elif opcode == 0x1C:
        text = vb6_arrival.text_reference(data, args[1], args[2])
        effect.update(speaker_slot=args[0], table=args[1], index=args[2], pages=text["pages"])
    return effect


def prefix_effects(data: bytes, prefix: bytes, stream: int) -> list[dict]:
    if not prefix:
        return []
    if data[stream:stream + len(prefix)] != prefix:
        raise RouteError(f"prefix changed at {stream:#x}")
    rows = event_script_decode.decode_stream(data, stream, max_insns=16)
    effects = []
    consumed = 0
    for row in rows:
        if row[0] >= stream + len(prefix):
            break
        effects.append(effect_from_row(data, row))
        consumed = row[0] + 1 + len(row[2]) - stream
    if consumed != len(prefix):
        raise RouteError(f"prefix decode did not consume exactly {len(prefix)} bytes at {stream:#x}")
    return effects


def destination(location_id: str, source_x: int, source_y: int) -> dict:
    if location_id.startswith("region_"):
        return {"location_id": location_id,
                "source_spawn": coordinate("world_cell", source_x, source_y),
                "spawn": coordinate("world_cell", source_x, source_y)}
    return {"location_id": location_id,
            "source_spawn": coordinate("half_cell", source_x, source_y),
            "spawn": coordinate("field_pixel", source_x * 8, source_y * 8)}


def reconstruction(origin: str, dest: str, e7: bool = False) -> dict:
    required = not dest.startswith("region_")
    return {"required": required,
            "same_room": origin == dest,
            "construction_story": "current_after_prefix_effects" if required else "not_applicable"}


def continuation(dest: str, e7: bool = False) -> dict:
    kind = "ordinary_source_selection" if e7 else "world_ready" if dest.startswith("region_") else "field_ready"
    return {"kind": kind, "automatic_program_id": None}


def world_entries(b: dict, c: dict, proofs: dict) -> list[dict]:
    routes = []
    for region, packet in (("region_b", b), ("region_c", c)):
        point = next(row for row in packet["points"] if row["destination"] is not None)
        dest = point["id"]
        source_order = 5 if region == "region_b" else 6
        routes.append({
            "id": f"{region}_point_{source_order:02d}_to_{dest.removeprefix('vb6_')}",
            "status": "proven", "source_order": source_order,
            "origin": {"location_id": region, "trigger": {
                "kind": "world_point", "point": coordinate("world_cell", point["x"], point["y"])}},
            "destination": destination(dest, point["spawn_x"] // 8, point["spawn_y"] // 8),
            "conditions": [], "event_flags_low2_clear": False, "effects": [],
            "reconstruction": reconstruction(region, dest), "continuation": continuation(dest),
            "provenance": {"file": "MAIN.EXE", "world_table": proofs[region]["world_table"],
                           "point_index": source_order, "record_stride": 14,
                           "consumers": ["MAIN world-point table", "kit/tools/export_world_travel.py:export"]},
        })
    return routes


def field_door(data: bytes, room: int, index: int, prefix: bytes) -> dict:
    door, proof = journey.transition(data, room, index, prefix)
    entry = scene.entities(data, scene.room_record(data, room))[index]
    dest = door["room"]
    origin = ROOM_IDS[room]
    return {
        "id": f"vb6_r{room:02d}_e{index:02d}_to_{dest.removeprefix('vb6_')}",
        "status": "proven", "source_order": index,
        "origin": {"location_id": origin, "trigger": {
            "kind": "field_rectangle",
            "rectangle": {"domain": "field_pixel", "x": door["x"], "y": door["y"],
                          "w": door["w"], "h": door["h"]},
            "direction": door.get("direction")}},
        "destination": destination(dest, door["spawn_x"] // 8, door["spawn_y"] // 8),
        "conditions": [], "event_flags_low2_clear": True,
        "effects": prefix_effects(data, prefix, entry["stream_offsets"][2]),
        "reconstruction": reconstruction(origin, dest), "continuation": continuation(dest),
        "provenance": {"file": "DATA/02_AREA.B/VB6.BIN", "room": room, "entity": index,
                       "entry_offset": entry["offset"], "predicate_offset": proof["predicate"],
                       "stream_offset": proof["stream"], "prefix_hex": prefix.hex(),
                       "consumers": CONSUMERS},
    }


def parse_world_exit(data: bytes, room: int, index: int, region: str) -> dict:
    entry = scene.entities(data, scene.room_record(data, room))[index]
    predicate, stream = entry["stream_offsets"][1:]
    rows = event_compiler.decode_bounded(data, stream, f"vb6_r{room:02d}_e{index:02d}_world_exit")
    transition_index = next((i for i, row in enumerate(rows) if row[1] == 3), None)
    if transition_index is None or transition_index + 2 != len(rows) or rows[-1][1] != 0xFD:
        raise RouteError(f"unsupported world-exit stream at {stream:#x}")
    transition = rows[transition_index]
    args = transition[2]
    expected_region = 1 if region == "region_b" else 2
    if args[0] != 0xFB or args[1] != expected_region:
        raise RouteError(f"world destination changed at {transition[0]:#x}")
    raw = data[predicate:predicate + 12]
    if raw[0] != 0x0B or raw[3] not in (0x06, 0x0C) or (raw[3] == 0x0C and raw[6] != 6):
        raise RouteError(f"unsupported world-exit predicate at {predicate:#x}")
    if raw[3] == 0x0C:
        rect = {"domain": "field_pixel", "x": raw[1] * 8, "y": raw[4] * 8,
                "w": (raw[2] - raw[1] + 1) * 8, "h": (raw[5] - raw[4] + 1) * 8}
    else:
        rect = {"domain": "field_pixel", "x": raw[1] * 8, "y": 0,
                "w": (raw[2] - raw[1] + 1) * 8, "h": 384}
    effects = [effect_from_row(data, row) for row in rows[:transition_index]]
    origin = ROOM_IDS[room]
    return {
        "id": f"vb6_r{room:02d}_e{index:02d}_to_{region}", "status": "proven",
        "source_order": index,
        "origin": {"location_id": origin, "trigger": {"kind": "field_rectangle", "rectangle": rect}},
        "destination": destination(region, args[2], args[3]), "conditions": [],
        "event_flags_low2_clear": True, "effects": effects,
        "reconstruction": reconstruction(origin, region), "continuation": continuation(region),
        "provenance": {"file": "DATA/02_AREA.B/VB6.BIN", "room": room, "entity": index,
                       "entry_offset": entry["offset"], "predicate_offset": predicate,
                       "stream_offset": stream, "transition_offset": transition[0],
                       "consumers": CONSUMERS + ["MAIN:0x80132790", "MAIN:0x80132898"]},
    }


def e7_route(data: bytes) -> dict:
    entry = scene.entities(data, scene.room_record(data, 6))[7]
    predicate, stream = entry["stream_offsets"][1:]
    conditions, predicate_proof = event_compiler.source_predicate(
        data, predicate, "event", event_compiler.FOLLOWON_7)
    expected = [
        {"kind": "story_mask_clear", "flag": flag(15, 0x40)},
        {"kind": "story_mask_set", "flag": flag(15, 0x20)},
    ]
    if conditions != expected:
        raise RouteError("E7 entry guard changed")
    rows = event_compiler.decode_bounded(data, stream, event_compiler.FOLLOWON_7)
    transition_index = next((i for i, row in enumerate(rows) if row[1] == 3), None)
    if transition_index is None or transition_index + 2 != len(rows) or rows[-1][1] != 0xFD:
        raise RouteError("E7 transition/terminal structure changed")
    transition = rows[transition_index]
    if transition[2] != bytes((6, 27, 25)):
        raise RouteError("E7 destination changed")
    effects = []
    for row in rows[:transition_index]:
        effects.append(effect_from_row(data, row, sum(row_effect["kind"] == "queue_track" for row_effect in effects)))
    if not effects or effects[-1]["kind"] != "story_or" or effects[-1]["flag"] != flag(15, 0x40):
        raise RouteError("E7 must commit scenario_0015 bit 0x40 immediately before reconstruction")
    return {
        "id": "vb6_r06_e07_same_room_reconstruction", "status": "proven", "source_order": 7,
        "origin": {"location_id": "vb6_kobold_village", "trigger": {"kind": "ordinary_event"}},
        "destination": destination("vb6_kobold_village", 27, 25), "conditions": conditions,
        "event_flags_low2_clear": True, "effects": effects,
        "reconstruction": reconstruction("vb6_kobold_village", "vb6_kobold_village", True),
        "continuation": continuation("vb6_kobold_village", True),
        "provenance": {"file": "DATA/02_AREA.B/VB6.BIN", "room": 6, "entity": 7,
                       "entry_offset": entry["offset"], "predicate_offset": predicate,
                       "predicate": predicate_proof, "stream_offset": stream,
                       "transition_offset": transition[0], "transition_operands": list(transition[2]),
                       "consumers": CONSUMERS + ["MAIN:0x8012EF58", "MAIN:0x8013CCF0"]},
    }


def locations() -> list[dict]:
    result = [
        {"id": "region_b", "kind": "world_region", "world_region": 1},
        {"id": "region_c", "kind": "world_region", "world_region": 2},
    ]
    result.extend({"id": name, "kind": "field_room", "source_file": "DATA/02_AREA.B/VB6.BIN",
                   "source_room": number} for number, name in sorted(ROOM_IDS.items()))
    return result


def validate_packet(packet: dict) -> None:
    if not isinstance(packet, dict) or packet.get("schema") != SCHEMA:
        raise RouteError("unsupported route packet schema")
    if sha256(canonical(dict(packet, content_sha256=""))) != packet.get("content_sha256"):
        raise RouteError("route content identity mismatch")
    location_by_id = {}
    for location in packet.get("locations", []):
        ident = location["id"]
        if ident in location_by_id:
            raise RouteError(f"duplicate location {ident}")
        location_by_id[ident] = location
    story_values = {row["id"]: row for row in packet.get("story_values", [])}
    for ident, value in story_values.items():
        if ident != f"scenario_{value['byte_index']:04d}" or not 0 <= value["byte_index"] < 240:
            raise RouteError(f"invalid story value {ident}")
    route_ids = set()
    for route in packet.get("routes", []):
        if route["id"] in route_ids:
            raise RouteError(f"duplicate route {route['id']}")
        route_ids.add(route["id"])
        if route["status"] != "proven":
            raise RouteError("non-proven route cannot produce a transition plan")
        origin = route["origin"]["location_id"]
        dest = route["destination"]
        if origin not in location_by_id or dest["location_id"] not in location_by_id:
            raise RouteError(f"dangling route location {route['id']}")
        destination_kind = location_by_id[dest["location_id"]]["kind"]
        expected_domain = "world_cell" if destination_kind == "world_region" else "field_pixel"
        if dest["spawn"]["domain"] != expected_domain:
            raise RouteError(f"destination coordinate domain mismatch {route['id']}")
        source_spawn = dest["source_spawn"]
        expected_source = "world_cell" if expected_domain == "world_cell" else "half_cell"
        if source_spawn["domain"] != expected_source:
            raise RouteError(f"source spawn domain mismatch {route['id']}")
        if expected_source == "half_cell" and (dest["spawn"]["x"] != source_spawn["x"] * 8 or
                                               dest["spawn"]["y"] != source_spawn["y"] * 8):
            raise RouteError(f"spawn conversion mismatch {route['id']}")
        trigger = route["origin"]["trigger"]
        if trigger["kind"] == "field_rectangle":
            rect = trigger["rectangle"]
            if rect["domain"] != "field_pixel" or rect["w"] <= 0 or rect["h"] <= 0:
                raise RouteError(f"invalid trigger rectangle {route['id']}")
        elif trigger["kind"] == "world_point":
            if trigger["point"]["domain"] != "world_cell":
                raise RouteError(f"invalid world point {route['id']}")
        elif trigger["kind"] != "ordinary_event":
            raise RouteError(f"unsupported trigger {route['id']}")
        for condition in route["conditions"]:
            reference = condition["flag"]
            if condition["kind"] not in ("story_mask_set", "story_mask_clear") or reference["id"] not in story_values or reference["mask"] == 0:
                raise RouteError(f"unsupported route predicate {route['id']}")
        for effect in route["effects"]:
            if effect["kind"] == "story_or" and effect["flag"]["id"] not in story_values:
                raise RouteError(f"unknown effect story value {route['id']}")
        required = destination_kind == "field_room"
        reconstruction = route["reconstruction"]
        if reconstruction["required"] != required or reconstruction["same_room"] != (origin == dest["location_id"]):
            raise RouteError(f"reconstruction contract mismatch {route['id']}")
        if reconstruction["construction_story"] != ("current_after_prefix_effects" if required else "not_applicable"):
            raise RouteError(f"construction story contract mismatch {route['id']}")
        if route["continuation"]["automatic_program_id"] is not None:
            raise RouteError("automatic continuation is not source-backed")


def make_fixtures(packet: dict) -> dict:
    by_id = {route["id"]: route for route in packet["routes"]}

    def request(route_id: str, kind: str, x: int | None = None, y: int | None = None,
                domain: str = "field_pixel", direction=None, story=None, barrier: int = 0) -> dict:
        route = by_id[route_id]
        trigger = {"kind": kind}
        if kind != "ordinary_event":
            trigger["position"] = coordinate(domain, x, y)
            trigger["direction"] = direction
        return {"route_id": route_id, "origin_id": route["origin"]["location_id"],
                "trigger": trigger, "story": story or {}, "event_flags_low2": barrier}

    def expected(route_id: str) -> dict:
        route = by_id[route_id]
        return {"status": "plan", "destination_id": route["destination"]["location_id"],
                "spawn": route["destination"]["spawn"],
                "effect_kinds": [row["kind"] for row in route["effects"]],
                "reconstruction": route["reconstruction"],
                "continuation": route["continuation"]}

    cases = []
    for ident, route_id, req in (
        ("region_b_entry", "region_b_point_05_to_village", request("region_b_point_05_to_village", "world_point", 86, 83, "world_cell")),
        ("region_b_entry_far_corner", "region_b_point_05_to_village", request("region_b_point_05_to_village", "world_point", 87, 84, "world_cell")),
        ("region_b_return", "vb6_r00_e01_to_region_b", request("vb6_r00_e01_to_region_b", "field_rectangle", 224, 360)),
        ("region_c_entry", "region_c_point_06_to_kobold_village", request("region_c_point_06_to_kobold_village", "world_point", 59, 36, "world_cell")),
        ("region_c_entry_far_corner", "region_c_point_06_to_kobold_village", request("region_c_point_06_to_kobold_village", "world_point", 60, 37, "world_cell")),
        ("region_c_return", "vb6_r06_e01_to_region_c", request("vb6_r06_e01_to_region_c", "field_rectangle", 360, 0)),
        ("maze_upper_branch", "vb6_r02_e01_to_forest_crossing", request("vb6_r02_e01_to_forest_crossing", "field_rectangle", 360, 32)),
        ("maze_lower_branch", "vb6_r02_e02_to_forest_crossing", request("vb6_r02_e02_to_forest_crossing", "field_rectangle", 360, 144)),
        ("maze_return_branch", "vb6_r03_e05_to_forest_bend", request("vb6_r03_e05_to_forest_bend", "field_rectangle", 360, 272)),
        ("e7_reconstruction", "vb6_r06_e07_same_room_reconstruction", request("vb6_r06_e07_same_room_reconstruction", "ordinary_event", story={"scenario_0015": 0x20})),
    ):
        cases.append({"id": ident, "request": req, "expected": expected(route_id)})
    cases.extend([
        {"id": "e7_story_ineligible", "request": request("vb6_r06_e07_same_room_reconstruction", "ordinary_event"),
         "expected": {"status": "error", "error": "RouteIneligible"}},
        {"id": "e7_dialogue_barrier", "request": request("vb6_r06_e07_same_room_reconstruction", "ordinary_event", story={"scenario_0015": 0x20}, barrier=1),
         "expected": {"status": "error", "error": "TransitionBarrierBlocked"}},
        {"id": "unrestricted_direction_up", "request": request("vb6_r00_e01_to_region_b", "field_rectangle", 224, 360, direction="up"),
         "expected": expected("vb6_r00_e01_to_region_b")},
        {"id": "outside_doorway", "request": request("vb6_r00_e01_to_region_b", "field_rectangle", 224, 352),
         "expected": {"status": "error", "error": "RouteTriggerMismatch"}},
    ])
    return identified({"schema": FIXTURE_SCHEMA, "id": "region_b_vb6_c_transition_cases",
                       "packet_content_sha256": packet["content_sha256"], "cases": cases})


def build() -> dict:
    data, vb6_source = source("/VB6.BIN")
    b, b_proof = world_travel.export("b")
    c, c_proof = world_travel.export("c")
    _, _, village_proof = village_content(data)
    if village_proof["event"]["persistent_write"] != {"opcode": 9, "index": 39, "mask": 16, "consumer": "0x8013CBBC"}:
        raise RouteError("village world-exit prefix identity changed")
    routes = world_entries(b, c, {"region_b": b_proof, "region_c": c_proof})
    routes.extend(field_door(data, room, index, prefix) for room, specs in ROOM_SPECS for index, prefix in specs)
    routes.append(parse_world_exit(data, 0, 1, "region_b"))
    routes.append(parse_world_exit(data, 6, 1, "region_c"))
    routes.append(e7_route(data))
    story_indices = sorted({condition["flag"]["id"] for route in routes for condition in route["conditions"]} |
                           {effect["flag"]["id"] for route in routes for effect in route["effects"] if effect["kind"] == "story_or"})
    packet = identified({
        "schema": SCHEMA, "id": "region_b_vb6_c",
        "sources": [vb6_source, source("/B_DATA.BIN")[1], source("/C_DATA.BIN")[1], source("MAIN.EXE")[1]],
        "locations": locations(),
        "coordinate_contracts": {
            "half_cell": "Unsigned source byte; X right/Y down from room top-left; field_pixel = half_cell * 8.",
            "field_pixel": "Integer field pixels; X right/Y down from room top-left. Trigger rectangles are half-open.",
            "world_cell": "Unsigned world-map cell coordinates. World point anchors activate the inclusive 2x2 area from anchor through anchor+(1,1); entrance and return coordinates are independent source facts; no field scale applies.",
        },
        "ordering": "World entries precede VB6 room/entity source order, world exits and E7. source_order is the original entity or world-point index within its source table.",
        "story_values": [{"id": ident, "storage": "scenario", "byte_index": int(ident[9:])} for ident in story_indices],
        "routes": routes,
        "coverage": {"proven": len(routes), "unresolved": 0, "field_doorways": 20,
                     "world_entries_and_returns": 4, "same_room_reconstructions": 1},
    })
    validate_packet(packet)
    fixtures = make_fixtures(packet)
    helper_hashes = {name: sha256((TOOLS / name).read_bytes()) for name in HELPERS}
    report = {
        "schema": REPORT_SCHEMA, "status": "SOURCE/MODULE IMPLEMENTED; PENDING INDEPENDENT REVIEW",
        "bundle_repair": "External content hashes are recomputed and executable entries require their exact source-entity/program contract. Twelve focused bundle tests pass locally; independent review remains separate.",
        "packet": {"id": packet["id"], "content_sha256": packet["content_sha256"]},
        "sources": packet["sources"], "helpers_sha256": helper_hashes,
        "coverage": packet["coverage"] | {
            "route_ids": [route["id"] for route in routes],
            "maze_branches": "All 20 source doorways are retained, including three room2->room3 and three room3->room2 branches; no reverse edge is inferred.",
            "unresolved_details": [],
        },
        "source_consumer_evidence": {
            "field_predicates": "MAIN 0x8013DB6C consumes entity+0x10 coordinate/input predicates. Existing journey tests independently execute the originals; route tests repeat direct table walks and boundary cases.",
            "field_destinations": "MAIN 0x8013BF94 inline03 writes room and source half-cells to game-state room/spawn fields; world 0xFB instead writes the region and world cells at 0x8016F298/0x8016F29A. MAIN 0x8013E028 drives the stream. Field-pixel conversion is exactly source*8, independently consumed by existing field helpers.",
            "world_points": "export_world_travel.export reads MAIN region tables at the proof world_table addresses with 14-byte records. Original driver MAIN 0x801280C4 activates inclusive 2x2 bounds B(86..87,83..84) and C(59..60,36..37). B point5(86,83)->VB6 room0(33,43) half-cells and C point6(59,36)->room6(44,27) half-cells are distinct from field->world return coordinates (86,85) and (59,38).",
            "area_prefix": "Opcode41 handler writes the halfword at MAIN 0x80171C2C+2*selector through the area-index setter. Village->forest selector6C resolves 0x445; forest->village selector33 resolves 0x40C.",
            "world_prefix": "VB6 room0 entity1 writes scenario_0039 OR0x10 before inline03 region1(86,85). No port-authored boundary message or prototype flag is emitted.",
            "e7": "VB6 entity7 guard is scenario_0015&0x20 set and &0x40 clear. Its 12 ordered prefix effects end with scenario_0015 OR0x40 at 0x35181; inline03 at 0x35184 selects room6 half-cell(27,25). Reconstruction uses current story after those effects; continuation is ordinary source selection, never automatic E9.",
            "construction": "Accepted binder contract: construction classification is retained at the construction boundary. Current story changes alone do not reclassify objects; every field destination requires fresh construction, including E7 same-room reconstruction.",
        },
        "contract": {
            "identity": "content_sha256 is SHA-256 of canonical JSON with content_sha256 empty and a trailing newline.",
            "plan": "Explicit route_id + origin + typed trigger + host StoryState + event low-two-bit barrier. Planning never applies effects or mutates host state.",
            "effects": "Ordered source obligations. The owner executes/acknowledges them through its event/host boundary before reconstruction; area_index is not a room ID and selectors are not actor IDs.",
            "reconstruction": "Every field destination requires construction using current story after prefix effects. E7 additionally has same_room=true and ordinary_source_selection continuation.",
            "errors": "Malformed packets, unknown references and unsupported predicates are validation errors. RouteIneligible, RouteTriggerMismatch and TransitionBarrierBlocked describe valid routes whose current inputs do not permit a plan.",
            "implementation_limits": "Zig accepts at most 1 MiB JSON, 16 locations, 64 routes, 16 effects per route and world-cell coordinates 0..4096. These are implementation bounds, not asserted original-game limits.",
            "zig_api": {
                "load": "load(allocator, bytes) !std.json.Parsed(Packet); caller owns and deinitializes the parsed packet. Validation failure cleans up partial decode state.",
                "validate": "validate(packet) !void checks the complete packet before any plan is returned.",
                "plan": "plan(packet, story: *const event_runtime.StoryState, request: Request) !TransitionPlan. Request supplies route_id, origin_id, a typed field_rectangle/world_point/ordinary_event trigger and event_flags_low2.",
                "result": "TransitionPlan borrows route_id, destination, ordered effects, reconstruction and continuation from the validated packet. It does not allocate or own source data and must not outlive that packet.",
                "state": "StoryState is borrowed from the host's canonical progress adapter. The planner never creates a second story model, applies effects, reconstructs actors, writes saves or executes a transition.",
            },
            "limits": "Offline transitions only. No actor/event execution, live traversal, E9 acceptance, save migration, init8/init28 execution, interiors, encounters, rendering or integration is claimed.",
            "regeneration": "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B kit/tools/export_route_transitions.py; append --check for read-only comparison. --output-root may isolate all four logical outputs.",
        },
        "registry_rows": ["RTE01", "RTE02", "RTE03", "RTE04", "RTE05"],
    }
    registry = [
        {"id": "RTE01", "stage": "X_ROUTE_TRANSITION", "class": "script", "claim": "The packet preserves all 20 scoped VB6 room0..6 doorway records in source order with independent destinations, trigger rectangles, directional qualifications and prefix effects; null direction is unrestricted, while an explicit direction remains required; no reverse or shortcut edge is inferred.", "addr": "MAIN:0x8013DB6C;MAIN:0x8013BF94;MAIN:0x8013E028", "evidence": "proven", "source": "kit/tools/export_journey.py;kit/tools/export_route_transitions.py;kit/tests/test_route_transitions.py", "superseded_by": "", "note": "Multiple room2/room3 maze branches are distinct source routes."},
        {"id": "RTE02", "stage": "X_ROUTE_TRANSITION", "class": "script", "claim": "Region B/C entries use the original inclusive 2x2 world-point bounds, and proven VB6 returns retain independent field-spawn and world-return coordinates and units.", "addr": "MAIN:0x801280C4;MAIN:0x80170068;MAIN:0x8017006C;VB6:0x348B0;VB6:0x350FC", "evidence": "proven", "source": "kit/tools/export_world_travel.py;kit/tools/export_route_transitions.py;kit/data/reports/route_transitions.json", "superseded_by": "", "note": "B entry bounds are86..87/83..84 and return is86/85; C entry bounds are59..60/36..37 and return is59/38."},
        {"id": "RTE03", "stage": "X_ROUTE_TRANSITION", "class": "script", "claim": "VB6 entity7 is a guarded same-room reconstruction to half-cell27/25 after 12 ordered effects ending in scenario_0015 OR0x40, followed by ordinary source selection without automatic E9 chaining.", "addr": "VB6:0x350BC;VB6:0x35164;VB6:0x35181;VB6:0x35184;MAIN:0x8013BF94;MAIN:0x8012EF58", "evidence": "proven", "source": "kit/tools/export_route_transitions.py;kit/tools/event_vm_semantics.py;kit/tools/export_field_actor_bindings.py", "superseded_by": "", "note": "Construction consumes post-prefix current story; later story changes alone do not reconstruct."},
        {"id": "RTE04", "stage": "X_ROUTE_TRANSITION", "class": "script", "claim": "The pure Zig planner validates typed packets and returns borrowed TransitionPlan values without mutating gameplay, applying effects, executing transitions or selecting fallbacks.", "addr": "", "evidence": "proven", "source": "game/src/route_transitions.zig;game/tests/route_transitions.zig;game/tests/fixtures/route_transitions.json", "superseded_by": "", "note": "Malformed/unsupported data, ineligibility, trigger mismatch and dialogue barrier are distinct failures."},
        {"id": "RTE05", "stage": "X_ROUTE_TRANSITION", "class": "script", "claim": "Scene-bundle validation recomputes required external content identity and authorizes executable programs only for their exact source entity contract.", "addr": "", "evidence": "proven", "source": "kit/tools/export_scene_event_bundles.py;kit/tests/test_scene_event_bundles.py", "superseded_by": "", "note": "Local repair with 12 focused tests; independent acceptance remains pending."},
    ]
    return {"packet": packet, "fixtures": fixtures, "report": report, "registry": registry}


def output_bytes(exported: dict) -> dict[str, bytes]:
    return {
        "kit/data/reports/route_transitions.json": serialize(exported["report"]),
        "kit/data/registry/extract_route_transitions.jsonl": jsonl_bytes(exported["registry"]),
        "game/assets/routes/region_b_vb6_c.json": serialize(exported["packet"]),
        "game/tests/fixtures/route_transitions.json": serialize(exported["fixtures"]),
    }


def main(argv: list[str] | None = None) -> int:
    return run_exporter(
        argv,
        root=ROOT,
        description=__doc__,
        build_outputs=lambda: (exported := build(), output_bytes(exported)),
        summary=lambda _: "4 route outputs; routes 25; unresolved 0",
        error_types=(RouteError, ValueError, AssertionError, OSError),
        error_prefix="route transition export failed",
        output_root_help="root for the four logical outputs; may be temporary",
        check_help="recompute and compare all outputs without creating or repairing them",
    )


if __name__ == "__main__":
    raise SystemExit(main())
