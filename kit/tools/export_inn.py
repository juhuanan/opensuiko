#!/usr/bin/env python3
"""Export VB6 inn rules as tracked semantic metadata; leave reviewed art alone."""
from pathlib import Path
import argparse
import json

import area_scene as scene
from export_first_room import ROOT, source
from war_text import decode


def export():
    data, provenance = source("/VB6.BIN")
    root = scene.root(data)
    entry = scene.entities(data, scene.room_record(data, 7))[2]
    stream = entry["stream_offsets"][2]
    if data[stream:stream + 39] != bytes.fromhex(
            "17 00 1c 01 01 2c 02 18 17 80 12 01 08 1c 01 01 2e "
            "05 00 03 01 18 46 2f 83 fc fb 43 06 01 fd fc fd fb 43 07 ff fd 00"):
        raise ValueError("inn service script changed")
    # Opcode43 selector6 indexes the argument table at root+0x10, then +0x0C.
    arguments = scene.ptr_at(data, root + 16)
    context = scene.ptr_at(data, arguments + 12 + 4)
    rate = scene.ptr_at(data, context)
    failure = scene.ptr_at(data, context + 4)
    table = scene.ptr_at(data, scene.ptr_at(data, root + 20) + 4)
    choices_offset = scene.ptr_at(data, table + 46 * 4)
    choices, _ = decode(data, choices_offset)
    labels = choices.splitlines()
    if labels != ["Stay", "Don't stay", "Save"]:
        raise ValueError("unsupported inn choices")
    failure_text, _ = decode(data, failure)
    if any(token in failure_text for token in ("<", "\\x", "[---]")):
        raise ValueError("unsupported inn message control")
    rules = {"schema": "suikoden-inn/1", "room": "vb6_inn", "npc": "innkeeper",
             "price_per_member": data[rate] * data[rate + 1],
             "choices": labels[:2], "insufficient_funds": failure_text}
    proof = {"schema": "suikoden-inn-provenance/1", "source": provenance,
             "exporter": "export_inn.py v1", "text_decoder": "war_text.py",
             "script_offset": stream, "context_offset": context, "rate_offset": rate,
             "rate_factors": list(data[rate:rate + 2]), "choices_offset": choices_offset,
             "insufficient_funds_offset": failure,
             "consumers": ["0x801397D0", "0x800D9DEC", "0x800D9F2C", "0x800CA60C"],
             "port_choices": ["Save choice deferred to the save/load milestone",
                              "60 ticks at 60Hz for the rest fade; charge and heal on confirmation",
                              "authored demo start: one injured Hero and 350 bits; no story-state claim"]}
    return {"inn.json": rules, "inn.provenance.json": proof}


def write(output, verify=False):
    target = Path(output).resolve()
    accepted = ROOT / "kit/work/accepted"
    if not verify and accepted in (target, *target.parents):
        raise ValueError("semantic export must not write the accepted tree")
    for name, value in export().items():
        encoded = json.dumps(value, indent=2) + "\n"
        path = Path(output) / name
        if verify:
            if not path.is_file() or path.read_text() != encoded:
                raise ValueError(f"stale inn export: {path}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(encoded)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "game/assets")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    write(args.out, args.verify)
    print("Inn semantic export verified" if args.verify else "Inn semantic metadata exported; reviewed art unchanged")
