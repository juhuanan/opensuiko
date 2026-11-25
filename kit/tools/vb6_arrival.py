#!/usr/bin/env python3
"""Disc-derived VB6 room 6 arrival stream and actor inventory extractor."""
from __future__ import annotations

import hashlib
from pathlib import Path
import struct

import area_scene
import disc
import event_script_decode
import export_first_room
import maindec
import opening_audience

TOOLS = Path(__file__).resolve().parent
BASE = 0x80010000
ROOM = 6
ARRIVAL_ENTITY = 5
CHARACTER_INDICES = (
    7, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
    23, 24, 25, 26, 27, 29, 30, 31, 32, 33, 34, 35,
)
DESCRIPTOR_PARAMETERS = (1, 3, 0, 2)
PREDICATE_OPERANDS = {
    1: 1, 2: 2, 3: 1, 4: 2, 5: 0, 7: 2, 8: 2, 9: 2, 10: 2, 11: 0,
    12: 0, 13: 2, 14: 2, 15: 2, 16: 2, 17: 2, 18: 0, 19: 2, 20: 2,
    21: 2, 22: 2, 23: 0, 24: 0,
}
HELPERS = (
    "disc.py",
    "export_first_room.py",
    "area_scene.py",
    "event_script_decode.py",
    "maindec.py",
    "war_text.py",
    "opening_audience.py",
)
CONSUMERS = {
    "classification": "MAIN.EXE:0x8013D8E0 (success 0, rejected/reserved 2, null 1)",
    "event_selection": "MAIN.EXE:0x8013DB6C (success 1, rejection 0)",
    "ordinary_first_match": "MAIN.EXE:0x8013F1BC",
    "command_tick": "MAIN.EXE:0x8013E028",
    "story_or": "MAIN.EXE:0x8013CBBC writes gs+0x190+index",
    "area_party_prefix": (
        "MAIN.EXE:0x80139CAC/0x80139D20/0x80139DF4 clears six transient slots "
        "at area-state+0x89 to FF, prefixes requested IDs, then backfills unlisted "
        "saved IDs in prior order only within the logical active count at *(0x8017C164)+3"
    ),
    "event_flags_low2": (
        "MAIN.EXE word 0x8017C028 mask 0x0003; opcode 0x46 handler 0x80139798 rewinds "
        "while nonzero. Dialogue helpers 0x8013B0C8 and 0x8013B2F4 set mask 1 for slot 0 "
        "or mask 2 for slot 1; sprite manager 0x8013E220 clears the corresponding mask "
        "at 0x8013E354 or 0x8013E3F4 after closure"
    ),
    "descriptor_flag_updates": (
        "MAIN.EXE:0x8013CE08 indexes table 0x80171B98 = [1,3,0,2], then "
        "0x8013CCF0 applies parameter 2 as flags AND 0x01 and parameter 3 as flags OR 0x02"
    ),
    "stream_end": "MAIN.EXE:0x8013E114 clears active-stream byte 0x80171C28",
}


def decode_pages(data: bytes, offset: int) -> list[str]:
    """Decode a room text entry into dialogue pages with trailing whitespace stripped."""
    tokens, _ = opening_audience.text(data, offset)
    pages: list[str] = []
    buf: list[str] = []
    for token in tokens:
        kind = token["kind"]
        if kind == "page":
            pages.append("".join(buf).rstrip())
            buf = []
        elif kind == "newline":
            buf.append("\n")
        elif kind == "glyph":
            buf.append(token["text"])
    if buf or not pages:
        pages.append("".join(buf).rstrip())
    return pages


def text_reference(data: bytes, table: int, index: int) -> dict:
    """Resolve and decode a text table entry from VB6 room 6."""
    record_off = area_scene.room_record(data, ROOM)["record_off"]
    table_ptr = struct.unpack_from("<I", data, record_off + 0x80 + 4 * table)[0]
    table_offset = table_ptr - BASE
    if not area_scene.in_file(data, table_offset + 4 * index + 3):
        raise ValueError(f"invalid VB6 text reference ({table}, {index})")
    text_ptr = struct.unpack_from("<I", data, table_offset + 4 * index)[0]
    text_offset = text_ptr - BASE
    if not area_scene.in_file(data, text_offset):
        raise ValueError(f"out-of-range VB6 text offset {text_offset:#x}")
    return {
        "table": table,
        "index": index,
        "pages": decode_pages(data, text_offset),
        "provenance": {"table_offset": table_offset, "text_offset": text_offset},
    }


def _decode_predicate(data: bytes, offset: int | None) -> tuple[list[dict], int]:
    """Decode a predicate bytecode chain into selection/visibility terms and byte size."""
    if offset is None:
        return [], 0
    cursor = offset
    terms: list[dict] = []
    for _ in range(64):
        if not area_scene.in_file(data, cursor):
            raise ValueError(f"truncated VB6 predicate at {offset:#x}")
        opcode = data[cursor]
        cursor += 1
        if opcode == 0x06:
            terms.append({"kind": "accept"})
            return terms, cursor - offset
        if opcode not in PREDICATE_OPERANDS:
            raise ValueError(f"unsupported VB6 predicate opcode {opcode:#x} at {cursor - 1:#x}")
        count = PREDICATE_OPERANDS[opcode]
        args = data[cursor:cursor + count]
        if len(args) != count:
            raise ValueError(f"truncated VB6 predicate operand at {cursor:#x}")
        cursor += count
        if opcode in (0x07, 0x08):
            kind = "story_mask_set" if opcode == 0x07 else "story_mask_clear"
            terms.append({"kind": kind, "byte_index": args[0], "mask": args[1]})
        elif opcode == 0x05:
            terms.append({"kind": "interaction"})
        else:
            terms.append({"kind": f"predicate_{opcode:02x}", "operands": list(args)})
    raise ValueError(f"unterminated VB6 predicate at {offset:#x}")


def compile_arrival(data: bytes, start: int) -> tuple[list[dict], list[dict]]:
    """Decode the bounded VB6 room 6 arrival event stream into actions and instruction spans."""
    actions: list[dict] = []
    spans: list[dict] = []
    for offset, opcode, args, _ in event_script_decode.decode_stream(data, start):
        spans.append({"offset": offset, "opcode": opcode, "operands": args.hex()})
        if opcode == 0x10:
            actions.append({"kind": "align_hero", "cell_x": args[0], "cell_y": args[1]})
        elif opcode == 0x3B:
            prefix_len = args[0]
            if len(args) != 1 + prefix_len:
                raise ValueError(f"malformed prefix length at {offset:#x}")
            actions.append({"kind": "request_area_party_prefix", "requested_prefix": list(args[1 : 1 + prefix_len])})
        elif opcode == 0x36:
            actions.append({"kind": "queue_glyphs_a"})
        elif opcode == 0x33:
            actions.append({"kind": "wait_text_queue_empty"})
        elif opcode in (0x0B, 0x17):
            actions.append({"kind": "open_dialogue_box", "slot": 0 if opcode == 0x0B else 1, "layout": args[0]})
        elif opcode in (0x0C, 0x18):
            actions.append({"kind": "close_dialogue_box", "slot": 0 if opcode == 0x0C else 1})
        elif opcode == 0x12:
            actions.append({"kind": "start_or_wait_dialogue", "slot": args[0], "code": args[1]})
        elif opcode == 0x1C:
            ref = text_reference(data, args[1], args[2])
            actions.append({
                "kind": "dialogue",
                "speaker_slot": args[0],
                "table": args[1],
                "index": args[2],
                "pages": ref["pages"],
            })
        elif opcode == 0x02:
            actions.append({"kind": "wait_for_accept"})
        elif opcode == 0x46:
            actions.append({"kind": "wait_event_flags_low2_clear"})
        elif opcode == 0x11:
            parameter = DESCRIPTOR_PARAMETERS[args[1]]
            kind = "descriptor_flags_and" if parameter in (1, 2) else "descriptor_flags_or"
            mask = 1 if parameter in (1, 2) else 2
            actions.append({"kind": kind, "selector": args[0], "parameter": parameter, "mask": mask})
        elif opcode == 0x37:
            actions.append({"kind": "queue_glyphs_b"})
        elif opcode == 0x38:
            actions.append({"kind": "wait_text_queue_drain_and_release"})
        elif opcode == 0x09:
            actions.append({"kind": "story_or", "byte_index": args[0], "mask": args[1]})
        elif opcode == 0xFD:
            actions.append({"kind": "end_stream"})
            break
        else:
            raise ValueError(f"unsupported VB6 arrival opcode {opcode:#x} at {offset:#x}")
    if not actions or actions[-1]["kind"] != "end_stream":
        raise ValueError("VB6 arrival stream did not terminate cleanly at end_stream")
    return actions, spans


def _main_provenance() -> dict:
    raw_main = disc.extract(maindec.EXE_LBA, maindec.EXE_SIZE)
    body = maindec.body()
    return {
        "file": "MAIN.EXE",
        "lba": maindec.EXE_LBA,
        "size_including_header": maindec.EXE_SIZE,
        "sha256_including_header": hashlib.sha256(raw_main).hexdigest(),
        "header_bytes": maindec.EXE_HEADER,
        "image_base": maindec.MBASE,
        "image_sha256": hashlib.sha256(body).hexdigest(),
    }


def export() -> dict:
    """Extract VB6 room 6 arrival actions, actor inventory and provenance from disc."""
    data, source_proof = export_first_room.source("/VB6.BIN")
    rec = area_scene.room_record(data, ROOM)
    entries = scene_entities = area_scene.entities(data, rec)
    detected_indices = tuple(i for i, row in enumerate(scene_entities) if row["interactive"])
    if detected_indices != CHARACTER_INDICES:
        raise ValueError(f"VB6 room 6 interactive index mismatch: {detected_indices}")

    arrival_entry = entries[ARRIVAL_ENTITY]
    selection_terms, _ = _decode_predicate(data, arrival_entry["stream_offsets"][1])
    actions, spans = compile_arrival(data, arrival_entry["stream_offsets"][2])
    texts = [
        {**text_reference(data, action["table"], action["index"])["provenance"],
         "table": action["table"], "index": action["index"]}
        for action in actions if action["kind"] == "dialogue"
    ]

    entity_rows = []
    entity_proofs = []
    for index in CHARACTER_INDICES:
        entry = entries[index]
        vis_terms, vis_size = _decode_predicate(data, entry["stream_offsets"][0])
        _, evt_size = _decode_predicate(data, entry["stream_offsets"][1])
        stable_id = f"vb6_r06_e{index:02d}_char_{entry['id']:03d}"
        entity_rows.append({
            "id": stable_id,
            "entity_index": index,
            "source_character_id": entry["id"],
            "position": {"half_cell_x": entry["x_half"], "half_cell_y": entry["y_half"]},
            "visibility": {"all": vis_terms},
            "event_stream": "inventory_only",
        })
        entity_proofs.append({
            "id": stable_id,
            "entity_index": index,
            "entry_offset": entry["offset"],
            "classification_offset": entry["stream_offsets"][0],
            "classification_size": vis_size,
            "event_predicate_offset": entry["stream_offsets"][1],
            "event_predicate_size": evt_size,
            "event_stream_offset": entry["stream_offsets"][2],
        })

    provenance = {
        "schema": "suikoden-kobold-arrival-provenance/1",
        "source": source_proof,
        "main": _main_provenance(),
        "room": {
            "record_offset": rec["record_off"],
            "entity_array_offset": rec["entity_off"],
            "entity_stride": 24,
            "entity_count": rec["entity_count"],
            "section_index": rec["section"],
        },
        "entities": entity_proofs,
        "arrival": {
            "entry_offset": arrival_entry["offset"],
            "predicate_offset": arrival_entry["stream_offsets"][1],
            "stream_offset": arrival_entry["stream_offsets"][2],
            "instructions": spans,
            "texts": texts,
        },
        "consumers": CONSUMERS,
        "helpers_sha256": {
            name: hashlib.sha256((TOOLS / name).read_bytes()).hexdigest()
            for name in HELPERS
        },
    }
    return {
        "provenance": provenance,
        "entities": entity_rows,
        "first_arrival": {
            "selection": {"all": selection_terms},
            "ordered_actions": actions,
            "state_writes": [{
                "preserves_unlisted_existing_members": True,
                "active_count_source": "MAIN:*(0x8017C164)+3",
                "backfill_bound": "logical_active_count",
                "unused_slot_sentinel": 255,
            }],
        },
    }
