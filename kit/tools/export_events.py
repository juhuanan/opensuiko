#!/usr/bin/env python3
"""Export two bounded source programs to suikoden-event-ir/1.

VAA reuses opening_audience/opening_events. VB6 reuses the reviewed scratch
packet without changing it; absence of that packet is an explicit dependency,
not permission to substitute another branch.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys

def repository_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        if (parent / "kit/tools/opening_audience.py").is_file():
            return parent
    raise RuntimeError("cannot locate repository helpers")


ROOT = repository_root()
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import area_scene as scene
import opening_audience
import opening_events
import vb6_arrival
from export_common import canonical, file_hash, identified
from export_first_room import source

SCHEMA = "suikoden-event-ir/1"
HELPERS = (
    "disc.py", "export_first_room.py", "area_scene.py", "maindec.py",
    "character_table.py", "war_text.py", "event_script_decode.py",
    "event_vm_semantics.py", "event_script_reachability.py",
    "opening_audience.py", "opening_events.py", "vb6_arrival.py",
)
COMMAND_FIELDS = (
    "actor", "character", "box", "image", "name", "text", "track",
    "transition", "x", "y", "updates", "cue", "dx", "dy", "variant",
    "value", "options", "target",
)


def story_id(index: int) -> str:
    return f"scenario_{index:04d}"


def story_value(index: int, initial: int) -> dict:
    return {"id": story_id(index), "storage": "scenario", "byte_index": index, "initial": initial}


def flag(index: int, mask: int) -> dict:
    return {"id": story_id(index), "mask": mask}


def condition(kind: str, index: int, mask: int) -> dict:
    return {"kind": kind, "flag": flag(index, mask)}


def copied(command: dict) -> dict:
    return {key: command[key] for key in COMMAND_FIELDS if key in command}


def wait(kind: str, ident: str) -> dict:
    return {"kind": kind, "id": ident}


def convert_vaa_command(command: dict) -> dict:
    result = copied(command)
    kind = command["kind"]
    if kind == "complete_audience":
        result = {"kind": "story_or", "flag": flag(0, 64)}
    elif kind == "finish":
        result = {"kind": "end_stream", "requires": wait("event_flags_low2", "dialogue_flags")}
    else:
        result["kind"] = kind
    if kind == "align_hero":
        result["wait"] = wait("alignment", "alignment")
    elif kind == "open_box":
        result["requires"] = wait("box_closed", f"box_{command['box']}")
    elif kind == "speaker":
        result["wait"] = wait("speaker_prefix", f"box_{command['box']}")
    elif kind == "text":
        result["wait"] = wait("text", command["text"])
    elif kind == "delay":
        result["wait"] = wait("delay", "delay")
    elif kind == "pan":
        result["wait"] = wait("pan", "pan")
    elif kind == "wait_variant":
        result["requires"] = wait("variant", command["actor"])
    elif kind == "wait_confirm":
        result["kind"] = "wait_for_accept"
    return result


def convert_init_command(command: dict) -> dict:
    kind = command["kind"]
    result = {"kind": kind}
    if kind == "select_cue":
        result = {"kind": "cue", "cue": command["cue"]}
    elif kind == "release_actor":
        result = {"kind": "release_actor", "actor": command["actor"].replace("descriptor_", "scene_actor_")}
    elif kind == "end_stream":
        result["requires"] = wait("event_flags_low2", "dialogue_flags")
    return result


def export_vaa() -> tuple[dict, dict]:
    audience, audience_proof = opening_audience.export()
    initializers, initializer_proof = opening_events.export()
    data, source_proof = source("/VAA.BIN")
    entries = scene.entities(data, scene.room_record(data, 2))
    ordinary = entries[22]
    if ordinary["stream_offsets"][2] != 0x50D80:
        raise ValueError("VAA audience entry changed")
    if data[ordinary["stream_offsets"][0]:ordinary["stream_offsets"][0] + 4] != bytes.fromhex("08 00 40 06"):
        raise ValueError("VAA audience classification changed")
    if data[ordinary["stream_offsets"][1]:ordinary["stream_offsets"][1] + 2] != bytes.fromhex("05 06"):
        raise ValueError("VAA audience interaction predicate changed")
    programs = [{
        "id": "vaa_room2_audience", "entry": "ordinary", "entity": 22,
        "trigger": "interaction",
        "conditions": [condition("story_mask_clear", 0, 64)],
        "commands": [convert_vaa_command(command) for command in audience["commands"]],
    }]
    for program, proof in zip(initializers["programs"], initializer_proof["programs"], strict=True):
        programs.append({
            "id": program["id"], "entry": "initialization", "entity": proof["entity"],
            "trigger": "none",
            "conditions": [] if program["condition"] == "always" else [condition("story_mask_set", 0, 64)],
            "commands": [convert_init_command(command) for command in program["commands"]],
        })
    content = identified({
        "schema": SCHEMA, "id": "vaa_audience_choice",
        "story_values": [story_value(0, initializers["initial_flags"]["story_0006"] * 64)],
        "actors": audience["actors"], "texts": audience["texts"], "tracks": audience["tracks"],
        "programs": programs,
    })
    proof = {
        "source": source_proof, "audience": audience_proof, "initializers": initializer_proof,
        "entry": {"entity": 22, "classification_offset": ordinary["stream_offsets"][0],
                  "event_predicate_offset": ordinary["stream_offsets"][1], "stream_offset": 0x50D80},
        "semantics": {
            "existing_not_generalized": "opening_audience.py named actions, TextState/TrackState consumers, initialization one-pump scheduler",
            "required_unsupported": "none in the bounded VAA export",
            "unexported_content": "other VAA entities/streams and all presentation assets remain outside this IR",
        },
    }
    return content, proof


def convert_vb6_action(action: dict) -> dict:
    kind = action["kind"]
    result = {"kind": kind}
    for key in ("layout", "code", "speaker_slot", "table", "index", "requested_prefix",
                "selector", "parameter", "mask"):
        if key in action:
            result[key] = action[key]
    if kind == "align_hero":
        result.update(x=action["cell_x"] * 8, y=action["cell_y"] * 8, wait=wait("alignment", "alignment"))
    elif kind == "request_area_party_prefix":
        result["scope"] = "area_transient"
    elif kind == "open_dialogue_box":
        result.update(kind="open_box", box=action["slot"], requires=wait("box_closed", f"box_{action['slot']}"))
    elif kind == "close_dialogue_box":
        result.update(kind="close_box", box=action["slot"])
    elif kind == "start_or_wait_dialogue":
        result["box"] = action["slot"]
        result["wait"] = wait("speaker_prefix", f"box_{action['slot']}")
    elif kind == "dialogue":
        result.update(kind="text", box=action["speaker_slot"], text=f"vb6_text_{action['table']}_{action['index']}",
                      wait=wait("text", f"vb6_text_{action['table']}_{action['index']}"))
    elif kind == "wait_event_flags_low2_clear":
        result.update(kind="wait_event_flags_low2")
    elif kind in ("descriptor_flags_and", "descriptor_flags_or"):
        result["kind"] = "descriptor_flags"
    elif kind == "story_or":
        result["flag"] = flag(action["byte_index"], action["mask"])
    elif kind == "end_stream":
        result["requires"] = wait("event_flags_low2", "dialogue_flags")
    return result


def export_vb6() -> tuple[dict, dict]:
    exported = vb6_arrival.export()
    arrival = exported["first_arrival"]
    conditions = []
    for term in arrival["selection"]["all"]:
        if term["kind"] == "accept":
            continue
        if term["kind"] not in ("story_mask_set", "story_mask_clear"):
            raise ValueError("unexported VB6 arrival predicate")
        conditions.append(condition(term["kind"], term["byte_index"], term["mask"]))
    actors = []
    for entity in exported["entities"]:
        visibility = []
        for term in entity["visibility"]["all"]:
            if term["kind"] == "accept":
                continue
            if term["kind"] not in ("story_mask_set", "story_mask_clear"):
                raise ValueError("unexported VB6 visibility predicate")
            visibility.append(condition(term["kind"], term["byte_index"], term["mask"]))
        actors.append({
            "id": entity["id"], "character": entity["source_character_id"],
            "x": entity["position"]["half_cell_x"] * 8,
            "y": entity["position"]["half_cell_y"] * 8,
            "attached": False, "conditions": visibility,
        })
    texts = []
    for action in arrival["ordered_actions"]:
        if action["kind"] == "dialogue":
            texts.append({"id": f"vb6_text_{action['table']}_{action['index']}",
                          "tokens": [{"kind": "glyph", "text": page} for page in action["pages"]]})
    content = identified({
        "schema": SCHEMA, "id": "vb6_room6_arrival",
        "story_values": [story_value(15, 0), story_value(19, 0)],
        "actors": actors, "texts": texts, "tracks": [],
        "programs": [{
            "id": "vb6_r06_first_arrival", "entry": "ordinary", "entity": 5,
            "trigger": "area_entry", "conditions": conditions,
            "commands": [convert_vb6_action(action) for action in arrival["ordered_actions"]],
        }],
    })
    proof = {
        "packet": exported["provenance"],
        "source_tool_sha256": file_hash(TOOLS / "vb6_arrival.py"),
        "source_test_sha256": file_hash(ROOT / "kit/tests/test_event_runtime_sources.py"),
        "semantics": {
            "existing_not_generalized": "reviewed packet's 28 arrival actions and conditional actor inventory",
            "required_unsupported": "runtime dialogue/glyph/alignment hosts are fixture boundaries; no field runtime binding is claimed",
            "unexported_content": "all 26 character streams, entities 7/9 follow-on streams, and all other VB6 entities remain inventory-only",
        },
    }
    return content, proof


def export() -> tuple[dict, dict, dict]:
    vaa, vaa_proof = export_vaa()
    vb6, vb6_proof = export_vb6()
    report = {
        "schema": "suikoden-event-runtime-report/1",
        "status": "FIXED IN THIS HANDOFF; PENDING INDEPENDENT REVIEW",
        "target": "Suikoden US v1.1 SLUS_002.92",
        "helpers_sha256": {name: file_hash(TOOLS / name) for name in HELPERS},
        "address_conversion": {
            "VAA/VB6": "overlay file offset + 0x80010000; no PS-X header",
            "MAIN.EXE": "file offset 2048 + (VA - 0x800C0800); header excluded from image addresses",
        },
        "vaa": vaa_proof, "vb6": vb6_proof,
        "host_atomicity": "applied-batch receipt + actor/inventory mutations + StoryState + Instance must be captured in one atomic snapshot",
        "limitations": [
            "MODULE/SOURCE VERIFIED only; not playable or integrated",
            "only evidenced commands in these two slices; not all 82 opcodes",
            "VB6 exporter requires the reviewed scratch packet until its owner promotes it",
            "real-caller switch, Progress/story adaptation and real save transactions remain with the main gameplay owner",
        ],
    }
    return vaa, vb6, report


def write_tree(root: Path = ROOT) -> None:
    vaa, vb6, report = export()
    outputs = {
        root / "game/assets/events/vaa_audience_choice.json": vaa,
        root / "game/assets/events/vb6_room6_arrival.json": vb6,
        root / "kit/data/reports/event_runtime.json": report,
    }
    catalog = {"schema": "suikoden-event-catalog/1", "programs": [
        {"id": value["id"], "path": f"events/{value['id']}.json", "content_sha256": value["content_sha256"]}
        for value in (vaa, vb6)
    ]}
    outputs[root / "game/assets/events/catalog.json"] = catalog
    for path, value in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2) + "\n")


if __name__ == "__main__":
    destination = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT
    write_tree(destination)
    print("Exported VAA audience/initializers and VB6 arrival through suikoden-event-ir/1")
