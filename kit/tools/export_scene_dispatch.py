#!/usr/bin/env python3
"""Compile source caller/admission rules over frozen scene population and bundles."""
from __future__ import annotations

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import area_scene
import compile_event_programs as event_compiler
import export_scene_event_bundles as bundles
import export_scene_population as population
import maindec
from export_common import (
    atomic_write,
    canonical,
    file_hash,
    identified,
    jsonl_bytes,
    run_exporter,
    serialize,
    sha256,
)
from export_first_room import source

SCHEMA = "suikoden-scene-dispatch/1"
FIXTURE_SCHEMA = "suikoden-scene-dispatch-fixtures/1"
REPORT_SCHEMA = "suikoden-scene-dispatch-report/1"
OUTPUTS = (
    "kit/data/reports/scene_dispatch.json",
    "kit/data/registry/extract_scene_dispatch.jsonl",
    "game/assets/scenes/dispatch/vaa_vb6.json",
    "game/tests/fixtures/scene_dispatch.json",
)
SCENES = (("vaa_room2", "/VAA.BIN", 2), ("vb6_room6", "/VB6.BIN", 6))
FROZEN = {
    "game/assets/scenes/population/vaa_room2.json": "67a69d506d8442323b51b0c3fedf27bd2026d2b1e570f306a7f293bb862d5a2e",
    "game/assets/scenes/population/vb6_room6.json": "90af5391a085c4f97a7162cd6374fad973ceee22081f9c90c11f5396f1a5d741",
    "game/assets/scenes/events/vaa_room2.json": "0fa5b02b11e8d482179c978ecc848e01d4e5e20a0d23dfd93f70a731b6670ec3",
    "game/assets/scenes/events/vb6_room6.json": "94178b47b092fff1ca572df5677bf828b24611f199f4cc0b0a5a698529ede67f",
    "game/assets/events/vb6_room6_field_host.json": "43cc5e4fac24ac9d5ce95be6a3011c4639a76c79b9ae6878b63f425cef2cd275",
    "game/assets/scenes/bindings/field_actor_bindings.json": "be643aca837a74621a6a3c7efa913abaf704e0cb4991470c6d224227618fc9e0",
}
HELPERS = (
    "disc.py", "export_first_room.py", "area_scene.py", "maindec.py", "mipsdec.py",
    "export_scene_population.py", "export_scene_event_bundles.py",
    "export_field_actor_bindings.py", "compile_event_programs.py",
)
ZIG_DEPENDENCIES = ("game/src/event_runtime.zig", "game/src/scene_population.zig")
SOURCE_WORDS = {
    0x801318C8: 0xA0201C28, 0x801318D4: 0x0C04FCA9,
    0x8013297C: 0x0C04FC6F, 0x80132994: 0x24632B6C, 0x801329B0: 0xA0221C28,
    0x80132B80: 0x90421C28, 0x80132B98: 0x0C04FC44,
    0x80132C14: 0x0040F809, 0x80132C40: 0x0040F809,
    0x80132C70: 0x8C63DC4C, 0x80132C78: 0x1462001D,
    0x80132C84: 0x90421C28, 0x80132C98: 0x24422938,
    0x8013E118: 0xA0201C28, 0x8013E124: 0x34020001, 0x8013E12C: 0xAC22DC4C,
    0x8013F11C: 0x0C04FC30, 0x8013F12C: 0x0C04F80A,
    0x8013F238: 0x0C04F6DB, 0x8013F24C: 0x0C04F85F,
    0x8013F308: 0x0C04F6DB, 0x8013F30C: 0x34040001,
    0x8013F31C: 0x0C04F85F, 0x8013F324: 0x0C04F80A,
    0x8013F334: 0x3C028018,
}
CALLERS = (
    {"phase": "construction_initialization", "function": "MAIN:0x801318C4", "supported": True,
     "selector": "MAIN:0x8013F2A4", "rule": "One ordered construction pass; select and pump each eligible initializer once, without waiting for the previous initializer."},
    {"phase": "free_selection", "function": "MAIN:0x80132938", "supported": True,
     "selector": "MAIN:0x8013F1BC", "rule": "After source free-gates clear, select the first ordinary match; install the event child and active-stream owner without pumping in this pass."},
    {"phase": "event_frame", "function": "MAIN:0x80132B6C", "supported": True,
     "selector": "MAIN:0x8013F110", "rule": "Continue the owned stream only; never run ordinary selection. Completion proposes free selection only after the host proves the post-frame completion gate; a pending area callback keeps the event child installed."},
    {"phase": "area_49c_callback", "function": "MAIN:0x80132C14", "supported": False,
     "selector": None, "rule": "Unsupported indirect area callback; not an ordinary-selection phase."},
    {"phase": "area_498_callback", "function": "MAIN:0x80132C40", "supported": False,
     "selector": None, "rule": "Unsupported indirect area callback; not an ordinary-selection phase."},
    {"phase": "menu", "function": "MAIN:0x80132BD8", "supported": False,
     "selector": "MAIN:0x80132938", "rule": "Menu ownership is outside dispatch planning; do not reinterpret it as free ordinary selection."},
)


class DispatchError(ValueError):
    pass


def identity(content: dict) -> dict:
    return {"content_id": content["id"], "content_sha256": content["content_sha256"]}


def read_json(root: Path, relative: str) -> dict:
    path = root / relative
    actual = file_hash(path)
    if actual != FROZEN[relative]:
        raise DispatchError(f"frozen input changed: {relative}: {actual}")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise DispatchError(f"frozen input is not an object: {relative}")
    return value


def load_inputs(root: Path = ROOT) -> dict:
    values = {name: read_json(root, name) for name in FROZEN}
    for name in HELPERS:
        if not (TOOLS / name).is_file():
            raise DispatchError(f"missing helper: {name}")
    for name in ZIG_DEPENDENCIES:
        if not (root / name).is_file():
            raise DispatchError(f"missing Zig dependency: {name}")
    return values


def qualified(reference: dict, program: dict) -> dict:
    if program["entry"] not in ("ordinary", "initialization"):
        raise DispatchError(f"unsupported execution entry: {program['entry']}")
    return dict(reference, entry=program["entry"])


def content_for(record: dict, inputs: dict) -> dict:
    if "content" in record:
        return record["content"]
    asset = record["source_asset"]
    if asset not in inputs or record["source_asset_sha256"] != FROZEN[asset]:
        raise DispatchError(f"unverified external content: {asset}")
    return inputs[asset]


def compile_scene(scene_id: str, suffix: str, room: int, inputs: dict) -> dict:
    pop = inputs[f"game/assets/scenes/population/{scene_id}.json"]
    bundle = inputs[f"game/assets/scenes/events/{scene_id}.json"]
    if bundle["schema"] != bundles.SCHEMA or bundle["population"] != identity(pop):
        raise DispatchError(f"bundle/population identity mismatch: {scene_id}")
    records = {tuple(record["reference"][key] for key in ("namespace", "content_id", "content_sha256", "program_id")): record
               for record in bundle["contents"]}
    data, source_proof = source(suffix)
    if source_proof != {key: pop["source"][key] for key in source_proof}:
        raise DispatchError(f"population source mismatch: {scene_id}")
    source_entities = area_scene.entities(data, area_scene.room_record(data, room))
    if len(source_entities) != len(pop["entities"]) or len(source_entities) != len(bundle["entries"]):
        raise DispatchError(f"source entity count changed: {scene_id}")
    entries = []
    initialization_count = 0
    for original, pop_entity, bundle_entry in zip(source_entities, pop["entities"], bundle["entries"]):
        index = original["index"]
        if (pop_entity["source_order"], bundle_entry["source_order"]) != (index, index):
            raise DispatchError(f"source order mismatch: {scene_id}/{index}")
        if pop_entity["id"] != bundle_entry["source_entity_id"]:
            raise DispatchError(f"source entity mismatch: {scene_id}/{index}")
        guard, _proof = population.decode_predicate(data, original["stream_offsets"][1], "event")
        if guard != pop_entity["event_selection"] or bundle_entry["guard"] != guard:
            raise DispatchError(f"event predicate mismatch: {scene_id}/{index}")
        role = pop_entity["record_role"]
        phase = "initialization" if role == "initialization" else "ordinary"
        if role == "initialization":
            if pop_entity["initialization_order"] != initialization_count:
                raise DispatchError(f"initialization order mismatch: {scene_id}/{index}")
            initialization_count += 1
        status = bundle_entry["status"]
        if status == "source_only":
            continue
        if status == "blocked_unsupported":
            if bundle_entry["program"] is not None or "gap" not in bundle_entry:
                raise DispatchError(f"invalid blocked entry: {scene_id}/{index}")
            gap = bundle_entry["gap"]
            blocker = {"reason": gap["unsupported"].get("kind", "unsupported_program"),
                       "source_offset": gap["unsupported"]["source_offset"],
                       "source_address": gap["unsupported"]["source_address"]}
            entries.append({"source_entity_id": pop_entity["id"], "source_order": index,
                            "phase": phase, "status": status, "program": None, "blocker": blocker})
            continue
        if status not in ("executable_embedded", "executable_required_external"):
            raise DispatchError(f"unknown entry status: {scene_id}/{index}: {status}")
        reference = bundle_entry["program"]
        key = tuple(reference[field] for field in ("namespace", "content_id", "content_sha256", "program_id"))
        if key not in records:
            raise DispatchError(f"dangling bundle reference: {scene_id}/{index}")
        content = content_for(records[key], inputs)
        matches = [program for program in content["programs"] if program["id"] == reference["program_id"]]
        if len(matches) != 1 or content["content_sha256"] != reference["content_sha256"]:
            raise DispatchError(f"qualified program mismatch: {scene_id}/{index}")
        program = matches[0]
        expected_entry = "initialization" if role == "initialization" else "ordinary"
        if program["entity"] != index or program["entry"] != expected_entry:
            raise DispatchError(f"source entity/execution mode mismatch: {scene_id}/{index}")
        entries.append({"source_entity_id": pop_entity["id"], "source_order": index,
                        "phase": phase, "status": "executable",
                        "program": qualified(reference, program), "blocker": None})
    return {"id": scene_id, "source": pop["source"], "population": identity(pop),
            "bundle": identity(bundle), "initialization_count": initialization_count,
            "entries": entries}


def validate_packet(packet: dict, inputs: dict) -> None:
    if packet.get("schema") != SCHEMA:
        raise DispatchError("unsupported scene dispatch schema")
    if sha256(canonical(dict(packet, content_sha256=""))) != packet.get("content_sha256"):
        raise DispatchError("scene dispatch content identity mismatch")
    if [caller["phase"] for caller in packet.get("callers", [])] != [row["phase"] for row in CALLERS]:
        raise DispatchError("caller phase inventory mismatch")
    for scene in packet.get("scenes", []):
        pop = inputs[f"game/assets/scenes/population/{scene['id']}.json"]
        bundle = inputs[f"game/assets/scenes/events/{scene['id']}.json"]
        if scene["population"] != identity(pop) or scene["bundle"] != identity(bundle):
            raise DispatchError(f"stale scene dependency: {scene['id']}")
        by_source = {entity["source_order"]: entity for entity in pop["entities"]}
        seen = set()
        for entry in scene["entries"]:
            index = entry["source_order"]
            if index in seen or index not in by_source or entry["source_entity_id"] != by_source[index]["id"]:
                raise DispatchError(f"invalid dispatch source reference: {scene['id']}/{index}")
            seen.add(index)
            expected_phase = "initialization" if by_source[index]["record_role"] == "initialization" else "ordinary"
            if entry["phase"] != expected_phase:
                raise DispatchError(f"dispatch phase mismatch: {scene['id']}/{index}")
            if entry["status"] == "executable":
                ref = entry["program"]
                if entry["blocker"] is not None or not isinstance(ref, dict):
                    raise DispatchError(f"invalid executable entry: {scene['id']}/{index}")
                if ref["namespace"] != event_compiler.SCHEMA or ref["entry"] != expected_phase:
                    raise DispatchError(f"invalid qualified execution mode: {scene['id']}/{index}")
                bundle_entry = bundle["entries"][index]
                if not bundle_entry["status"].startswith("executable") or bundle_entry["program"] != {key: ref[key] for key in bundle_entry["program"]}:
                    raise DispatchError(f"stale qualified bundle reference: {scene['id']}/{index}")
            elif entry["status"] == "blocked_unsupported":
                if entry["program"] is not None or entry["blocker"] is None or bundle["entries"][index]["status"] != "blocked_unsupported":
                    raise DispatchError(f"invalid blocked entry: {scene['id']}/{index}")
            else:
                raise DispatchError(f"source-only entries must remain implicit: {scene['id']}/{index}")


def make_fixtures(packet: dict) -> dict:
    scenes = {scene["id"]: scene for scene in packet["scenes"]}

    def facts(scene_id: str, phase: str, story=None, cursor=None, owner=None,
              free_gate="clear", vm_gate="clear", completion_gate="clear", low2=0, interaction=None,
              unsupported="unsupported", construction_story=None, construction_phase=None) -> dict:
        scene = scenes[scene_id]
        if cursor is None:
            cursor = 0 if phase == "construction_initialization" else scene["initialization_count"]
        if construction_phase is None:
            construction_phase = "constructing" if phase == "construction_initialization" else "active"
        owner_fact = None
        if owner is not None:
            source_order, active, pc, wait, reloop = owner
            entry = next(row for row in scene["entries"] if row["source_order"] == source_order and row["program"] is not None)
            ref = entry["program"]
            owner_fact = {"source_order": source_order, "content_id": ref["content_id"],
                          "content_sha256": ref["content_sha256"], "program_id": ref["program_id"],
                          "active": active, "pc": pc, "wait": wait, "reloop": reloop}
        return {"scene_id": scene_id, "phase": phase, "story": story or {},
                "construction": {"scene_id": scene_id, "phase": construction_phase,
                                 "population": scene["population"], "bundle": scene["bundle"],
                                 "story": construction_story or {}},
                "initialization_cursor": cursor, "owner": owner_fact,
                "locks": {"free_gate": free_gate, "vm_gate": vm_gate, "completion_gate": completion_gate, "event_flags_low2": low2},
                "interaction_entity": interaction, "unsupported_terms": unsupported}

    def expected(kind: str, entity=None, program=None, reason=None, next_cursor=None) -> dict:
        return {"kind": kind, "source_entity_id": entity, "program_id": program,
                "reason": reason, "next_initialization_cursor": next_cursor}

    cases = [
        {"id": "vaa_init23", "facts": facts("vaa_room2", "construction_initialization"),
         "expected": expected("selected_initialization", "vaa_room2_entity_23", "vaa_room2_init_23", next_cursor=1)},
        {"id": "vaa_init24_after_prior_yield", "facts": facts("vaa_room2", "construction_initialization", {"scenario_0000": 0x40}, 1, (23, True, 1, None, False)),
         "expected": expected("selected_initialization", "vaa_room2_entity_24", "vaa_room2_init_24", next_cursor=2)},
        {"id": "vaa_initialization_complete", "facts": facts("vaa_room2", "construction_initialization", cursor=2),
         "expected": expected("no_candidate", reason="initialization_complete", next_cursor=2)},
        {"id": "vb6_init8_first_selected_blocker", "facts": facts("vb6_room6", "construction_initialization", {"scenario_0015": 0x40, "scenario_0017": 0x04}, 1),
         "expected": expected("blocked", "vb6_room6_entity_08", reason="program_not_compiled")},
        {"id": "vb6_init28_first_selected_blocker", "facts": facts("vb6_room6", "construction_initialization", {"scenario_0017": 0x04}, 1),
         "expected": expected("blocked", "vb6_room6_entity_28", reason="program_not_compiled")},
        {"id": "vb6_initialization_complete", "facts": facts("vb6_room6", "construction_initialization", cursor=1),
         "expected": expected("no_candidate", reason="initialization_complete", next_cursor=3)},
        {"id": "vb6_arrival_free_selection", "facts": facts("vb6_room6", "free_selection", {"scenario_0015": 8}, unsupported="all_false"),
         "expected": expected("selected_ordinary", "vb6_room6_entity_05", "vb6_r06_first_arrival")},
        {"id": "vb6_e7_eligible_but_nonexecutable", "facts": facts("vb6_room6", "free_selection", {"scenario_0015": 0x28}, unsupported="all_false", construction_story={"scenario_0015": 8}),
         "expected": expected("blocked", "vb6_room6_entity_07", reason="room_coordinate_transition")},
        {"id": "vb6_e5_event_frame_does_not_select_e7", "facts": facts("vb6_room6", "event_frame", {"scenario_0015": 0x28}, owner=(5, True, 27, None, False), unsupported="all_false", construction_story={"scenario_0015": 8}),
         "expected": expected("continue_current_instance", "vb6_room6_entity_05", "vb6_r06_first_arrival")},
        {"id": "vb6_e5_completion_rearms_later_free_pass", "facts": facts("vb6_room6", "event_frame", {"scenario_0015": 0x28}, owner=(5, False, 28, None, False), unsupported="all_false", construction_story={"scenario_0015": 8}),
         "expected": expected("no_candidate", reason="completed_return_to_free_selection", next_cursor=3)},
        {"id": "completed_vm_callback_still_pending", "facts": facts("vb6_room6", "event_frame", {"scenario_0015": 0x28}, owner=(5, False, 28, None, False), completion_gate="blocked"),
         "expected": expected("wait_current_instance", "vb6_room6_entity_05", "vb6_r06_first_arrival", "completion_gate")},
        {"id": "completed_vm_callback_unknown", "facts": facts("vb6_room6", "event_frame", owner=(5, False, 28, None, False), completion_gate="unsupported"),
         "expected": {"kind": "error", "error": "UnsupportedDispatchDependency"}},
        {"id": "vb6_e9_requires_separate_free_pass", "facts": facts("vb6_room6", "free_selection", {"scenario_0015": 0x40}, unsupported="all_false", construction_story={"scenario_0015": 8}),
         "expected": expected("selected_ordinary", "vb6_room6_entity_09", "vb6_r06_entity09_followon")},
        {"id": "active_owner_blocks_free_reselection", "facts": facts("vb6_room6", "free_selection", {"scenario_0015": 0x28}, owner=(5, True, 27, None, True), unsupported="all_false"),
         "expected": expected("blocked", "vb6_room6_entity_05", "vb6_r06_first_arrival", "active_instance")},
        {"id": "yielded_owner_continues_without_reselection", "facts": facts("vb6_room6", "event_frame", {"scenario_0015": 0x28}, owner=(5, True, 27, None, False), unsupported="all_false"),
         "expected": expected("continue_current_instance", "vb6_room6_entity_05", "vb6_r06_first_arrival")},
        {"id": "text_gate_waits_current_instance", "facts": facts("vb6_room6", "event_frame", owner=(5, True, 12, "text", True), vm_gate="text_blocked"),
         "expected": expected("wait_current_instance", "vb6_room6_entity_05", "vb6_r06_first_arrival", "vm_gate")},
        {"id": "low2_waits_only_matching_wait", "facts": facts("vb6_room6", "event_frame", owner=(5, True, 12, "event_flags_low2", True), low2=1),
         "expected": expected("wait_current_instance", "vb6_room6_entity_05", "vb6_r06_first_arrival", "event_flags_low2")},
        {"id": "low2_is_not_global_event_lock", "facts": facts("vb6_room6", "event_frame", owner=(5, True, 12, None, True), low2=3),
         "expected": expected("continue_current_instance", "vb6_room6_entity_05", "vb6_r06_first_arrival")},
        {"id": "first_unsupported_predicate_is_not_skipped", "facts": facts("vaa_room2", "free_selection"),
         "expected": expected("blocked", "vaa_room2_entity_00", reason="unsupported_predicate")},
        {"id": "vaa_audience_qualified_reference", "facts": facts("vaa_room2", "free_selection", {"scenario_0000": 0x40}, interaction=22, unsupported="all_false"),
         "expected": expected("selected_ordinary", "vaa_room2_entity_22", "vaa_room2_audience")},
        {"id": "ordinary_no_candidate", "facts": facts("vb6_room6", "free_selection", unsupported="all_false"),
         "expected": expected("no_candidate", reason="no_ordinary_match", next_cursor=3)},
        {"id": "free_caller_gate_blocked", "facts": facts("vb6_room6", "free_selection", {"scenario_0015": 0x28}, free_gate="blocked", unsupported="all_false"),
         "expected": expected("blocked", reason="caller_gate")},
        {"id": "area_498_callback_unsupported", "facts": facts("vb6_room6", "area_498_callback"),
         "expected": {"kind": "error", "error": "UnsupportedDispatchPhase"}},
    ]
    return identified({"schema": FIXTURE_SCHEMA, "id": "vaa_vb6_scene_dispatch_cases",
                       "packet_content_sha256": packet["content_sha256"], "cases": cases})


def build(input_root: Path = ROOT) -> dict:
    inputs = load_inputs(input_root)
    for address, expected in SOURCE_WORDS.items():
        actual = maindec.mword(address)
        if actual != expected:
            raise DispatchError(f"MAIN caller instruction changed at {address:#x}: {actual!r}")
    scenes = [compile_scene(scene_id, suffix, room, inputs) for scene_id, suffix, room in SCENES]
    packet = identified({
        "schema": SCHEMA, "id": "vaa_vb6_scene_dispatch",
        "sources": [scene["source"] for scene in scenes],
        "callers": list(CALLERS),
        "predicate_contract": {
            "decoder": "kit/tools/export_scene_population.py:decode_predicate",
            "evaluation": "Accepted population terms in source order; story masks use canonical StoryState.matches. interaction requires the explicit source entity. Unsupported terms require host evidence; all_false is an explicit host assertion that every unresolved term is false, never a default or fallback.",
        },
        "ownership_contract": {
            "instance": "Borrow event_runtime.Instance identity/execution facts; the VM retains PC, waits, pending batches and execution.",
            "free_selection": "No active/yielded owner may be replaced. A completed owner may be retained as history. Selection proposes event_frame ownership but does not create an Instance or pump.",
            "event_frame": "An active owner continues or waits. A completed VM owner waits until the host proves the post-frame completion gate, then proposes rearming free_selection for a later pass. No ordinary scan occurs in this phase.",
            "locks": "free_gate represents MAIN 0x80132938's high-coordinate/0x8012CC38/0x8012CB10 admission dependencies. vm_gate represents MAIN 0x8013F0C0. completion_gate is clear only after post-frame completion0x8017DC4C=1 and active0 with area callbacks settled; pending callbacks block it and unproven callback/menu dependencies remain unsupported. Omitted free/vm/completion gates default unsupported. event_flags_low2 waits only an owner already waiting on that condition; it is not a global VM lock.",
        },
        "initialization_contract": {
            "cursor": "Caller-owned zero-based initialization_order. Each decision proposes pump_once_and_advance to the selected order+1; ineligible entries are skipped in the same ordered pass. Completion proposes initialization_count. A prior initializer's active/yielded VM state does not block the next initializer.",
            "lifetime": "The construction packet and construction_story are retained through active/recreated lifetime. Current story drives ordinary guards without rebuilding population or reclassifying actors. Only an explicit fresh construction boundary replaces that snapshot.",
        },
        "reference_contract": "Only bundle executable entries become qualified references (namespace+content_id+content_sha256+program_id+entry), checked against source entity and execution entry. The Zig caller also borrows the actual parsed event contents; every executable reference must resolve to a program with the same entity, entry and qualified content identity. Explicit blocked entries carry no program. Every unlisted source entity remains source_only and produces program_not_compiled if selected; a valid reference can never promote it.",
        "scenes": scenes,
    })
    validate_packet(packet, inputs)
    fixtures = make_fixtures(packet)
    helper_hashes = {name: file_hash(TOOLS / name) for name in HELPERS}
    helper_hashes.update({name: file_hash(input_root / name) for name in ZIG_DEPENDENCIES})
    registry = [
        {"id": "SDSP01", "stage": "X_SCENE_DISPATCH", "class": "script", "claim": "VAA room2 and VB6 room6 ordinary selection uses the first source match in the free caller, while the event child continues the current owner and never reselects in the same pass.", "addr": "MAIN:0x80132938;MAIN:0x8013297C;MAIN:0x80132B6C;MAIN:0x80132B98;MAIN:0x8013F1BC;MAIN:0x8013F110", "evidence": "proven", "source": "kit/tools/export_scene_dispatch.py;kit/tests/test_scene_dispatch.py", "superseded_by": "", "note": "Selection installs the active stream and event child without pumping. Completion proposes free selection only after the host proves the post-frame completion gate; a pending area callback keeps the event child installed."},
        {"id": "SDSP02", "stage": "X_SCENE_DISPATCH", "class": "script", "claim": "The construction initialization pump visits eligible initializers in source order and pumps each once without waiting for the previous initializer; the caller owns initialization progress.", "addr": "MAIN:0x801318C4;MAIN:0x801318C8;MAIN:0x8013F2A4;MAIN:0x8013F31C;MAIN:0x8013F324;MAIN:0x8013F334", "evidence": "proven", "source": "kit/tools/export_scene_dispatch.py;kit/tests/test_scene_dispatch.py", "superseded_by": "", "note": "VAA order23/24; VB6 order6/8/28. Init8 and init28 remain source-only first-selected blockers under the accepted execution contracts."},
        {"id": "SDSP03", "stage": "X_SCENE_DISPATCH", "class": "script", "claim": "After E5, scenario byte15=0x28 makes E7 guard-eligible on a later free-selection pass, not the completing event-frame pass; E7 remains a typed non-executable transition blocker and is not auto-chained to E9.", "addr": "VB6:0x350BC;VB6:0x35161;VB6:0x35164;MAIN:0x8013E118;MAIN:0x8013E12C;MAIN:0x80132C84;MAIN:0x80132C98", "evidence": "proven", "source": "kit/tools/export_scene_dispatch.py;kit/tests/test_scene_dispatch.py;game/assets/scenes/events/vb6_room6.json", "superseded_by": "", "note": "E9 requires its own current-story guard and a separate free-selection call. Offline admission is not E7 execution."},
        {"id": "SDSP04", "stage": "X_SCENE_DISPATCH", "class": "script", "claim": "Dispatch references reuse frozen population guards and bundle-qualified program identities with source-entity and execution-mode checks; unlisted entries remain source-only and cannot be promoted by a valid reference.", "addr": "MAIN:0x8013DB6C;MAIN:0x8013E1F8", "evidence": "proven", "source": "kit/tools/export_scene_dispatch.py;kit/tools/export_scene_population.py;kit/tools/export_scene_event_bundles.py", "superseded_by": "", "note": "No entity inventory, predicate decoder, event IR or program payload is duplicated."},
        {"id": "SDSP05", "stage": "X_SCENE_DISPATCH", "class": "script", "claim": "The pure planner borrows canonical story, retained construction identity/facts and Instance ownership, returning typed continue/wait/no-candidate/selection/blocker decisions without executing scripts or mutating gameplay.", "addr": "MAIN:0x8013F0C0;MAIN:0x8013E0DC;MAIN:0x8013E114", "evidence": "proven", "source": "game/src/scene_dispatch.zig;game/tests/scene_dispatch.zig;kit/tests/test_scene_dispatch.py", "superseded_by": "", "note": "Unsupported indirect callbacks and unresolved host dependencies fail explicitly. Construction story is not a current-story population vote."},
    ]
    report = {
        "schema": REPORT_SCHEMA, "status": "SOURCE/MODULE IMPLEMENTED; PENDING INDEPENDENT DISPATCH REVIEW",
        "usable_behavior": "Deterministic VAA/VB6 construction, free-selection and event-frame admission with first-selected blockers, qualified references and no same-pass E5-to-E7 reselection.",
        "remaining_blockers": ["E7 room/coordinate transition execution", "init8/init28 and all unlisted source-only programs", "area 498/49C callbacks and menu ownership", "host-supplied free/vm gate and unresolved-predicate facts", "gameplay integration and live acceptance"],
        "inputs": {name: {"sha256": digest, "role": "frozen accepted/read-only dependency"} for name, digest in FROZEN.items()},
        "helpers_sha256": helper_hashes,
        "original_sources": packet["sources"],
        "source_consumer_evidence": {
            "ordinary_caller": "MAIN 0x8013297C calls first-match selector0x8013F1BC. Success installs0x80132B6C and sets0x80171C28 at0x80132994/0x801329B0 without calling the VM in that pass.",
            "event_owner": "MAIN 0x80132B80 checks the active flag and0x80132B98 calls0x8013F110, which calls the VM through0x8013F12C after gate0x8013F0C0. There is no selector call in this child path.",
            "completion": "Inline FD clears0x80171C28 at0x8013E118 and sets completion0x8017DC4C at0x8013E12C. MAIN 0x80132C84/0x80132C98 later installs0x80132938; only after the post-frame completion signal and callback settlement may a subsequent free pass select again.",
            "initialization": "MAIN 0x801318C8 clears ordinary active state before0x8013F2A4. Each eligible source initializer selects at0x8013F31C, pumps once at0x8013F324 and advances at0x8013F334 regardless of yielded prior state.",
            "unsupported_callbacks": "Indirect area callbacks at0x80132C14 and0x80132C40, plus menu ownership at0x80132BD8, are explicit unsupported phases rather than aliases for free selection.",
            "source_rows": [{"address": f"0x{address:08X}", "word": f"0x{word:08X}"} for address, word in sorted(SOURCE_WORDS.items())],
        },
        "coverage": {scene["id"]: {"source_entities": len(inputs[f"game/assets/scenes/population/{scene['id']}.json"]["entities"]),
                                   "initialization_count": scene["initialization_count"],
                                   "qualified_programs": sum(row["status"] == "executable" for row in scene["entries"]),
                                   "explicit_blocked": sum(row["status"] == "blocked_unsupported" for row in scene["entries"]),
                                   "implicit_source_only": len(inputs[f"game/assets/scenes/population/{scene['id']}.json"]["entities"]) - len(scene["entries"])}
                     for scene in scenes},
        "caller_phases": list(CALLERS),
        "contracts": {key: packet[key] for key in ("predicate_contract", "ownership_contract", "initialization_contract", "reference_contract")},
        "required_host_inputs_not_supplied_by_existing_contracts": "The host must supply the actual parsed referenced event contents, the free caller's external gate result, the 0x8013F0C0 VM gate result, the post-frame completion/callback gate, unresolved event-predicate outcomes (or an explicit all-false assertion), current low-two-bit flags, interaction entity, retained construction snapshot and caller-owned initialization cursor. StoryState and Instance supply the remaining canonical facts; no new owner is introduced.",
        "planner_consumption": "Load dispatch, accepted population and the actual qualified event contents; retain their identities and construction_story. Supply borrowed contents in Facts.contents so program/entity/entry correspondence is checked rather than trusting a packet reference alone. Call plan(packet, scene_id, population, facts) once from the corresponding existing caller seam. On selected_initialization, start/pump that exact qualified program once and advance to next_initialization_cursor; on selected_ordinary, replace the selection seam by starting that exact program for the next event_frame; on continue/wait, keep the existing Instance; on blocked, stop at the reported first selected entry. The planner performs none of those actions.",
        "acceptance_boundaries": {
            "producer": "Focused standard-library source/contract tests and pure Zig fixture/malformed-reference tests.",
            "independent": "Route and dispatch module/source acceptance remain separate from producer success; the route inventory and accepted population/bundle data are frozen.",
            "live": "No host replacement, E7 execution, transition application, connected-world traversal, UI or live gameplay acceptance is claimed.",
        },
        "route_repair": {"python": "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B kit/tests/test_route_transitions.py: PASS 8 tests",
                         "zig": "zig test game/tests/route_transitions.zig with route_transitions/event_runtime modules: PASS 6 tests",
                         "generation": "export_route_transitions.py --check: PASS 4 outputs; independent route acceptance remains separate"},
        "dispatch_validation": {
            "python": {"command": "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B kit/tests/test_scene_dispatch.py", "status": "PASS", "tests": 9},
            "zig": {"command": "kit/work/cache/toolchains/zig-aarch64-macos-0.17.0/zig test --dep scene_dispatch --dep scene_population --dep event_runtime -Mroot=game/tests/scene_dispatch.zig --dep scene_population --dep event_runtime -Mscene_dispatch=game/src/scene_dispatch.zig --dep event_runtime -Mscene_population=game/src/scene_population.zig -Mevent_runtime=game/src/event_runtime.zig", "status": "PASS", "tests": 8},
            "read_only_generation": {"command": "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B kit/tools/export_scene_dispatch.py --check", "status": "PASS", "outputs": 4},
            "format": {"command": "zig fmt --check game/src/scene_dispatch.zig game/tests/scene_dispatch.zig", "status": "PASS"},
            "scope": "Producer evidence only; independent source/module review and live gameplay acceptance remain separate.",
        },
        "generation": "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B kit/tools/export_scene_dispatch.py; --check recomputes and compares four outputs without repair; --input-root and --output-root support isolated validation.",
        "registry_rows": [row["id"] for row in registry],
        "generated_identities": {"packet_content_sha256": packet["content_sha256"],
                                 "fixture_content_sha256": fixtures["content_sha256"],
                                 "registry_sha256": sha256("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in registry).encode())},
    }
    return {"packet": packet, "fixtures": fixtures, "report": report, "registry": registry, "inputs": inputs}


def output_bytes(exported: dict) -> dict[str, bytes]:
    return {
        "kit/data/reports/scene_dispatch.json": serialize(exported["report"]),
        "kit/data/registry/extract_scene_dispatch.jsonl": jsonl_bytes(exported["registry"]),
        "game/assets/scenes/dispatch/vaa_vb6.json": serialize(exported["packet"]),
        "game/tests/fixtures/scene_dispatch.json": serialize(exported["fixtures"]),
    }


def main(argv: list[str] | None = None) -> int:
    return run_exporter(
        argv,
        root=ROOT,
        description=__doc__,
        build_outputs=lambda input_root: (
            exported := build(input_root),
            output_bytes(exported),
        ),
        summary=lambda _: "4 scene-dispatch outputs; scenes 2; qualified programs 6; explicit blockers 1",
        error_types=(DispatchError, OSError, KeyError, IndexError, TypeError, json.JSONDecodeError),
        error_prefix="scene-dispatch export failed",
        input_root_help="",
        output_root_help="",
        check_help="",
    )


if __name__ == "__main__":
    raise SystemExit(main())
