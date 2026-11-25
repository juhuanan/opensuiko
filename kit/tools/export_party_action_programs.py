#!/usr/bin/env python3
"""Compile ordinary-party attack scripts into named semantic action programs.

The original actor VM advances scripts 1 (attack) and 4 (return) for an
ordinary strike.  The trial exporter only accepted melee programs containing a
jump in both scripts; that is a trial-model limit, not a property of the
original scripts.  This module keeps the source update order and emits typed
programs for the stationary/ranged families as well.

What is compiled
----------------
The actor action VM is ``0x800E3820`` with handler table ``0x8016BABC``.  The
source opcode lengths come from the handler advance itself (``actor_script``).
This module does not reimplement the battle coordinator: target choice, hit,
damage, target reaction and round ownership stay in the caller.

For each owner it emits:

* attack script 1 events, with animation and movement waits sharing a clock;
* an auxiliary track when opcode 24 is reachable, including the auxiliary's
  own script (normally table slot 9) and its owner-mask signals;
* return script 4 events, anchored after the owner-ready mask;
* absolute boundaries (impact, auxiliary contact/release, owner ready,
  return release) plus explicit caller-owned target-reaction and round gates.

Original offsets, pointer values and raw op traces are retained only in the
proof report.  Runtime data uses stable IDs, named operations and update units.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from actor_script import OP_LEN_HW  # noqa: E402
from export_first_room import ROOT, source  # noqa: E402

SCHEMA = "suikoden-party-action-programs/1"
PROOF_SCHEMA = "suikoden-party-action-programs-proof/1"
DEFAULT_CHARACTERS = (
    "kirkis", "eileen", "lorelai", "krin", "sylvina", "meg", "kage",
    "fuma", "sarah", "clive", "rubi", "quincy", "tengaar", "hero",
    "gremio", "pahn",
)
BASELINE = ("hero", "gremio", "pahn")
DEFAULT_CATALOGUE = ROOT / "game/assets/party_session/catalogue.json"
C_PACKAGE_COMMIT = "73399f809a55dc64ef774e575424e83a83d504d2"
# The preserved C report's exact-file hash; it is supplied read-only by the
# integrator and is not present in every checkout.
C_PACKAGE_REPORT_SHA256 = "6accfeb5be8ede1a0d2c1abe1eb4fa9c8bf35cae00ac983bbc43bcb25f15d71f"


class ProgramError(ValueError):
    def __init__(self, code: str, detail: str, *, character: str | None = None,
                 address: int | None = None):
        self.code = code
        self.detail = detail
        self.character = character
        self.address = address
        prefix = f"{character}: " if character else ""
        suffix = f" at 0x{address:08x}" if address is not None else ""
        super().__init__(f"{prefix}{code}: {detail}{suffix}")


@dataclass
class Event:
    tick: int
    kind: str
    data: dict[str, Any] = field(default_factory=dict)


@dataclass
class Track:
    name: str
    start_from: str
    start_ticks: int
    events: tuple[Event, ...]
    animations: tuple[int, ...] = ()
    motions: tuple[int, ...] = ()
    masks: tuple[tuple[int, int], ...] = ()
    external_calls: tuple[int, ...] = ()
    auxiliary: dict[str, Any] | None = None


@dataclass
class Program:
    character_id: str
    family: str
    attack: Track
    auxiliary: Track | None
    return_: Track
    impact_tick: int | None
    owner_ready_tick: int | None
    auxiliary_spawn_tick: int | None
    auxiliary_contact_tick: int | None
    auxiliary_release_tick: int | None
    return_release_tick: int | None
    target_release_delay: int | None
    source: dict[str, Any]


def _u8(data: bytes, off: int, label: str, character: str | None = None) -> int:
    if not 0 <= off < len(data):
        raise ProgramError("truncated_source", label, character=character, address=off)
    return data[off]


def _u16(data: bytes, off: int, label: str, character: str | None = None) -> int:
    if not 0 <= off + 2 <= len(data):
        raise ProgramError("truncated_source", label, character=character, address=off)
    return struct.unpack_from("<H", data, off)[0]


def _u32(data: bytes, off: int, label: str, character: str | None = None) -> int:
    if not 0 <= off + 4 <= len(data):
        raise ProgramError("truncated_source", label, character=character, address=off)
    return struct.unpack_from("<I", data, off)[0]


def _script(data: bytes, table: int, index: int, character: str) -> tuple[list[tuple[int, tuple[int, ...], int]], int]:
    if not 0 <= table + 4 * index + 4 <= len(data):
        raise ProgramError("script_table_short", f"slot {index}", character=character, address=table)
    cursor = _u32(data, table + 4 * index, f"script[{index}]", character)
    if not 0 < cursor < len(data):
        raise ProgramError("script_pointer_outside_source", f"slot {index} -> 0x{cursor:08x}",
                           character=character, address=table + 4 * index)
    rows: list[tuple[int, tuple[int, ...], int]] = []
    seen: set[int] = set()
    for _ in range(512):
        if cursor in seen:
            raise ProgramError("script_cycle", f"slot {index}", character=character, address=cursor)
        seen.add(cursor)
        op = _u16(data, cursor, f"script[{index}] opcode", character)
        if op in (0, 1):
            return rows, cursor
        length = OP_LEN_HW.get(op)
        if length is None or length <= 0:
            raise ProgramError("unsupported_script_operation", f"slot {index} op={op}",
                               character=character, address=cursor)
        if cursor + 2 * length > len(data):
            raise ProgramError("truncated_script", f"slot {index} op={op}",
                               character=character, address=cursor)
        args = tuple(struct.unpack_from("<" + "h" * (length - 1), data, cursor + 2))
        rows.append((op, args, cursor))
        cursor += 2 * length
    raise ProgramError("runaway_script", f"slot {index}", character=character, address=cursor)


def _animation(data: bytes, frames: int, index: int, character: str) -> tuple[int, tuple[tuple[int, int], ...]]:
    if not 0 <= index < 64:
        raise ProgramError("animation_index_out_of_range", str(index), character=character)
    if not 0 <= frames + 4 * index + 4 <= len(data):
        raise ProgramError("animation_table_short", str(index), character=character, address=frames)
    off = _u32(data, frames + 4 * index, f"animation[{index}]", character)
    count = _u8(data, off, f"animation[{index}] count", character)
    if off + 4 + 2 * count > len(data):
        raise ProgramError("truncated_animation", f"animation[{index}] count={count}",
                           character=character, address=off)
    if data[off + 1] & 2:
        raise ProgramError("looping_attack_animation", f"animation[{index}]", character=character, address=off)
    pairs = tuple((data[off + 4 + 2 * k], data[off + 5 + 2 * k]) for k in range(count))
    return sum(ticks or 256 for _, ticks in pairs), pairs


def _at(tick: int) -> dict[str, int]:
    return {"from": "track_start", "ticks": tick}


def _compile_track(name: str, data: bytes, table: int, frames: int, index: int,
                   character: str, *, start_from: str = "dispatch",
                   external_contact_tick: int | None = None) -> Track:
    ops, end = _script(data, table, index, character)
    clock = 0
    animation_end = 0
    movement_end = 0
    current_animation: int | None = None
    events: list[Event] = []
    animations: list[int] = []
    motions: list[int] = []
    masks: list[tuple[int, int]] = []
    calls: list[int] = []
    auxiliary: dict[str, Any] | None = None

    def add(kind: str, **kw: Any) -> None:
        events.append(Event(clock, kind, kw))

    for op, args, address in ops:
        if op == 3:
            ticks = args[0]
            if ticks < 0:
                raise ProgramError("negative_timer", f"slot {index}", character=character, address=address)
            add("timer", ticks=ticks)
            clock += ticks
        elif op == 4:
            animation = args[0]
            duration, pairs = _animation(data, frames, animation, character)
            current_animation = animation
            animation_end = clock + duration
            animations.append(animation)
            add("animation_request", animation=animation, duration=duration,
                frames=[{"pose": pose, "ticks": ticks or 256} for pose, ticks in pairs])
        elif op == 5:
            if current_animation is None:
                raise ProgramError("wait_without_animation", f"slot {index}", character=character, address=address)
            add("wait_animation", animation=current_animation)
            clock = max(clock, animation_end)
        elif op in (23, 33):
            if op == 23:
                mode, duration, x, y, z, vx, vy, vz = args
            else:
                mode, duration, x, y, z = args
                vx = vy = vz = 0
            if duration < 0:
                raise ProgramError("negative_motion", f"slot {index}", character=character, address=address)
            if mode not in (1, 2, 3):
                raise ProgramError("unsupported_motion_mode", f"slot {index} mode={mode}", character=character, address=address)
            movement_end = clock + duration
            motions.append(duration)
            add("motion", mode={2: "approach", 3: "return", 1: "local"}.get(mode, f"mode_{mode}"),
                duration=duration, offset={"x": x, "y": y, "z": z},
                velocity={"x": vx, "y": vy, "z": vz})
        elif op == 21:
            add("wait_movement")
            clock = max(clock, movement_end)
        elif op == 24:
            slot, graphic, script, x, y, z = args
            auxiliary = {"slot": slot, "graphic": graphic, "script": script,
                         "offset": {"x": x, "y": y, "z": z}, "spawn_tick": clock}
            add("auxiliary_spawn", **auxiliary)
        elif op == 26:
            mode, mask = args
            masks.append((mode, mask))
            add("set_action_mask", target="owner" if mode == 1 else "self", mask=mask)
        elif op == 28:
            mode, mask = args
            add("wait_action_mask", target="owner" if mode == 1 else "self", mask=mask)
            if mask == 2 and external_contact_tick is not None:
                if external_contact_tick < clock:
                    raise ProgramError("invalid_contact_clock", f"slot {index}", character=character, address=address)
                clock = external_contact_tick
        elif op == 29:
            mode, mask = args
            add("wait_action_mask_clear", target="owner" if mode == 1 else "self", mask=mask)
        elif op == 34:
            call = args[0]
            calls.append(call)
            add("external_call", id=call)
        elif op == 35:
            add("auxiliary_mode", mode=args[0], value=args[1])
        elif op == 30:
            add("set_shared_value", slot=args[0])
        elif op == 31:
            add("wait_shared_value", slot=args[0])
        elif op in (9, 10):
            add("flag_set" if op == 9 else "flag_clear", selector=args[0])
        elif op in (13, 14):
            add("record_flag_set" if op == 13 else "record_flag_clear",
                mask=args[0])
        elif op in (15, 16):
            add("highlight_set" if op == 15 else "highlight_clear", index=args[0], mask=args[1])
        elif op == 2:
            add("teardown")
        elif op == 38:
            add("reset_draw_records")
        elif op == 39:
            add("reset_draw_records_alt")
        elif op == 25:
            add("sync_animation_offsets", args=list(args))
        elif op == 43:
            add("copy_animation_offsets", args=list(args))
        elif op == 22:
            add("move_home", mode=args[0])
        elif op == 40:
            add("battle_subobject", args=list(args))
        else:
            raise ProgramError("unsupported_script_operation", f"slot {index} op={op}",
                               character=character, address=address)
    return Track(name=name, start_from=start_from, start_ticks=0, events=tuple(events),
                 animations=tuple(animations), motions=tuple(motions), masks=tuple(masks),
                 external_calls=tuple(calls), auxiliary=auxiliary)


def _baseline_timing(data: bytes, table: int, frames: int, character: str) -> tuple[int, int, int, int]:
    """The already-admitted melee clock, kept bit-for-bit with party_attack_timing."""
    clock = animation = movement = 0
    impact = returned = released = None
    for index in (1, 4):
        ops, _ = _script(data, table, index, character)
        for op, args, _ in ops:
            if op == 4:
                duration, _ = _animation(data, frames, args[0], character)
                animation = clock + duration
            elif op == 5:
                clock = max(clock, animation)
            elif op == 3:
                clock += args[0]
            elif op == 23:
                movement = clock + args[1]
            elif op == 21:
                clock = max(clock, movement)
            elif op == 26 and args == (0, 2):
                impact = clock
            elif op == 26 and args == (0, 4):
                returned = clock
            elif op == 16 and args == (0, 1):
                released = clock - 1
    hurt, _ = _script(data, table, 2, character)
    hurt_clock = hurt_movement = 0
    for op, args, _ in hurt:
        if op == 3:
            hurt_clock += args[0]
        elif op == 23:
            hurt_movement = max(1, hurt_clock) + args[1]
        elif op == 21:
            hurt_clock = max(hurt_clock, hurt_movement)
        elif op == 22:
            hurt_movement = hurt_clock
    if impact is None or returned is None or released is None or not 0 < impact < returned <= released:
        raise ProgramError("invalid_baseline_clock", "", character=character)
    return impact + 1, returned + 1, released + 1, hurt_clock


def _program(character_id: str, row: dict, data: bytes) -> tuple[Program, dict[str, Any]]:
    table = _u32(data, 32, "script table", character_id)
    section = _u32(data, 36, "sprite section", character_id)
    frames = _u32(data, section + 20, "animation table", character_id)
    attack_probe = _compile_track("attack", data, table, frames, 1, character_id)
    return_track = _compile_track("return", data, table, frames, 4, character_id,
                                  start_from="owner_ready")
    # The auxiliary is created by the attack track.  Compile its script first
    # when opcode 24 proved one, then recompile the attack with the auxiliary
    # contact as the wait boundary.  Never infer a projectile from an
    # animation id.
    aux_request = attack_probe.auxiliary
    auxiliary: Track | None = None
    aux_contact = None
    aux_release = None
    if aux_request is not None:
        aux_script = aux_request["script"]
        if not 0 <= aux_script < 32:
            raise ProgramError("auxiliary_script_out_of_range", str(aux_script), character=character_id)
        auxiliary = _compile_track("auxiliary", data, table, frames, aux_script, character_id,
                                   start_from="auxiliary_spawn")
        contact = next((event for event in auxiliary.events
                        if event.kind == "set_action_mask" and event.data.get("mask") == 2), None)
        teardown = next((event for event in auxiliary.events if event.kind == "teardown"), None)
        if contact is None or teardown is None:
            raise ProgramError("auxiliary_missing_contact_or_teardown",
                               "auxiliary script must set mask2 and tear down", character=character_id)
        aux_contact = contact.tick
        aux_release = teardown.tick
        contact_tick = aux_request["spawn_tick"] + aux_contact
        attack = _compile_track("attack", data, table, frames, 1, character_id,
                                external_contact_tick=contact_tick)
    else:
        attack = attack_probe
    # Determine impact and owner-ready masks.  A stationary auxiliary sets
    # mask2 on its owner; the attack script itself only sets mask4.
    if not any(mask == 4 for _, mask in attack.masks):
        raise ProgramError("missing_ready_mask",
                           "attack script must set action mask 4", character=character_id)
    attack_events = list(attack.events)
    ready_event = next(event for event in attack_events
                       if event.kind == "set_action_mask" and event.data.get("mask") == 4)
    if aux_request is not None:
        impact_tick = aux_request["spawn_tick"] + aux_contact
    else:
        if not any(mask == 2 for _, mask in attack.masks):
            raise ProgramError("missing_impact_mask",
                               "attack script must set action mask 2", character=character_id)
        impact_event = next(event for event in attack_events
                            if event.kind == "set_action_mask" and event.data.get("mask") == 2)
        impact_tick = impact_event.tick
    owner_ready_tick = ready_event.tick
    # Return is a separate track anchored at owner-ready.  The source release
    # is the opcode16(0,1) highlight clear; recovery animation12 can continue
    # after the lock is released and is not the release boundary.
    release_event = next((event for event in return_track.events
                          if event.kind == "highlight_clear" and event.data.get("index") == 0
                          and event.data.get("mask") == 1), None)
    if release_event is None:
        raise ProgramError("missing_return_release", "return script lacks release boundary", character=character_id)
    release_tick = owner_ready_tick + release_event.tick
    # The target's hurt/release track is coordinator-owned.  Only the
    # already-admitted melee baselines have an independently measured delay;
    # do not reinterpret an arbitrary script slot as a target reaction.
    target_delay = None
    if character_id in BASELINE:
        impact_tick, owner_ready_tick, release_tick, target_delay = _baseline_timing(
            data, table, frames, character_id)
    boundary = {
        "initial_command": {"from": "dispatch", "ticks": 0},
        "auxiliary_spawn": ({"from": "dispatch", "ticks": aux_request["spawn_tick"]}
                            if aux_request else None),
        "impact": {"from": "dispatch", "ticks": impact_tick},
        "target_reaction": ({"from": "impact", "ticks": target_delay} if target_delay is not None else None),
        "auxiliary_contact": ({"from": "dispatch", "ticks": (aux_request["spawn_tick"] + aux_contact)}
                              if aux_request else None),
        "auxiliary_release": ({"from": "dispatch", "ticks": (aux_request["spawn_tick"] + aux_release)}
                              if aux_request else None),
        "owner_ready": {"from": "dispatch", "ticks": owner_ready_tick},
        "return_start": {"from": "owner_ready", "ticks": 0},
        "return_release": {"from": "dispatch", "ticks": release_tick},
    }
    family = ("stationary_auxiliary" if aux_request is not None
              else ("melee" if any(event.data.get("mode") in ("approach", "return")
                                   for event in attack.events if event.kind == "motion")
                    else "ranged_sequence"))
    program = Program(character_id=character_id, family=family, attack=attack,
                      auxiliary=auxiliary, return_=return_track,
                      impact_tick=impact_tick, owner_ready_tick=owner_ready_tick,
                      auxiliary_spawn_tick=(aux_request["spawn_tick"] if aux_request else None),
                      auxiliary_contact_tick=(aux_request["spawn_tick"] + aux_contact if aux_request else None),
                      auxiliary_release_tick=(aux_request["spawn_tick"] + aux_release if aux_request else None),
                      return_release_tick=release_tick, target_release_delay=target_delay,
                      source={"script_table": table, "section": section, "frames": frames})
    return program, boundary


def _event_json(event: Event) -> dict[str, Any]:
    return {"at": _at(event.tick), "kind": event.kind, **event.data}


def _track_json(track: Track) -> dict[str, Any]:
    return {
        "start": {"from": track.start_from, "ticks": 0},
        "events": [_event_json(event) for event in track.events],
        "animations": list(track.animations),
        "motions": list(track.motions),
        "action_masks": [{"target": "owner" if mode == 1 else "self", "mask": mask}
                          for mode, mask in track.masks],
        "external_calls": list(track.external_calls),
    }


def _program_json(program: Program, boundary: dict[str, Any], row: dict) -> dict[str, Any]:
    aux = None
    if program.auxiliary is not None:
        aux = {
            "slot": program.attack.auxiliary["slot"],
            "graphic": program.attack.auxiliary["graphic"],
            "script": program.attack.auxiliary["script"],
            "offset": program.attack.auxiliary["offset"],
            "spawn": boundary["auxiliary_spawn"],
            "contact": boundary["auxiliary_contact"],
            "release": boundary["auxiliary_release"],
            "track": _track_json(program.auxiliary),
        }
    unresolved = []
    if program.character_id not in BASELINE:
        unresolved.append({"kind": "target_release_timing", "required": True,
                           "note": "target reaction/down duration is caller-owned; only the impact trigger is exported"})
    if program.auxiliary is not None:
        unresolved.append({"kind": "visual_reference", "reference": f"auxiliary_graphic_{program.attack.auxiliary['graphic']}",
                           "required": True,
                           "note": "source-proved graphic id; no art is invented or sampled by this packet"})
    for track in (program.attack, program.auxiliary, program.return_):
        if track is None:
            continue
        for call in track.external_calls:
            unresolved.append({"kind": "external_effect", "reference": f"call_{call}", "track": track.name,
                               "required": True,
                               "note": "handler 0x800E5AFC calls 0x800C3104; no effect identity is guessed"})
    return {
        "id": program.character_id,
        "resource": row["resource"],
        "resource_sha256": row["resource_sha256"],
        "family": program.family,
        "status": "incomplete" if unresolved else "candidate",
        "clock": {"origin": "ordinary_attack_dispatch", "units": "updates"},
        "preconditions": {
            "target_selection": "caller_owned_combat_coordinator",
            "requires_live_target": True,
            "owner_lock": "ordinary_action_lock",
            "target_lock": "target_slot_lock",
            "requires_free_auxiliary_slot": program.auxiliary is not None,
            "random_draws": "none in this program; caller owns hit/damage/target RNG",
        },
        "tracks": {
            "attack": _track_json(program.attack),
            "auxiliary": (_track_json(program.auxiliary) if program.auxiliary is not None else None),
            "return": _track_json(program.return_),
        },
        "boundaries": boundary,
        "auxiliary": aux,
        "unresolved": unresolved,
    }


def require_runtime_admission(character: dict[str, Any]) -> None:
    """Reject an unbound candidate; existing battle profiles use their own path."""
    blockers = []
    reaction = character.get("boundaries", {}).get("target_reaction")
    if not isinstance(reaction, dict) or not isinstance(reaction.get("ticks"), int) or reaction["ticks"] <= 0:
        blockers.append("target_release_timing")
    auxiliary = character.get("auxiliary")
    if auxiliary is not None:
        blockers.append(f"auxiliary_graphic_{auxiliary.get('graphic')}")
    tracks = character.get("tracks", {})
    for name in ("attack", "auxiliary", "return"):
        track = tracks.get(name)
        if not isinstance(track, dict):
            if name != "auxiliary":
                blockers.append(f"missing_{name}_track")
            continue
        for call in track.get("external_calls", []):
            blockers.append(f"{name}:call_{call}")
        for event in track.get("events", []):
            if event.get("kind") == "external_call":
                blockers.append(f"{name}:call_{event.get('id')}")
            if event.get("kind") == "motion" and event.get("mode") not in ("approach", "return", "local"):
                blockers.append(f"{name}:unsupported_motion")
    for item in character.get("unresolved", []):
        if item.get("required"):
            blockers.append(item.get("reference", item.get("kind", "unknown_dependency")))
    if blockers:
        raise ProgramError("unresolved_runtime_dependencies", ", ".join(sorted(set(blockers))),
                           character=character.get("id"))
    raise ProgramError("runtime_adapter_unavailable", "no current coordinator adapter consumes this schema",
                       character=character.get("id"))


def _canonical(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def _load_catalogue(path: Path) -> tuple[dict[str, Any], str, str]:
    raw = path.read_bytes()
    catalogue = json.loads(raw)
    if catalogue.get("schema") != "suikoden-party-source-facts/1":
        raise ProgramError("catalogue_schema", str(catalogue.get("schema")))
    characters = catalogue.get("characters")
    if not isinstance(characters, list) or len(characters) != 78:
        raise ProgramError("catalogue_count", f"expected 78, got {len(characters or [])}")
    ids = [row.get("id") for row in characters]
    if len(set(ids)) != 78 or any(not isinstance(name, str) or not name for name in ids):
        raise ProgramError("catalogue_ids", "expected 78 unique stable IDs")
    exact = hashlib.sha256(raw).hexdigest()
    canonical = hashlib.sha256(json.dumps(catalogue, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return catalogue, exact, canonical


def _select(catalogue: dict[str, Any], requested: str | None) -> list[str]:
    known = [row["id"] for row in catalogue["characters"]]
    if requested is None or requested.strip().lower() == "all":
        return known
    ids = [name.strip() for name in requested.split(",") if name.strip()]
    if not ids:
        raise ProgramError("empty_selection", "")
    unknown = [name for name in ids if name not in known]
    if unknown:
        raise ProgramError("unknown_character", ", ".join(unknown))
    if len(set(ids)) != len(ids):
        raise ProgramError("duplicate_character", "")
    return ids


def export(characters: str | None = None, *, catalogue_path: Path = DEFAULT_CATALOGUE,
           out: Path | None = None, report: Path | None = None) -> dict[str, Any]:
    catalogue_path = Path(catalogue_path).resolve()
    catalogue, catalogue_sha, catalogue_canonical = _load_catalogue(catalogue_path)
    ids = _select(catalogue, characters)
    by_id = {row["id"]: row for row in catalogue["characters"]}
    programs: list[dict[str, Any]] = []
    proofs: list[dict[str, Any]] = []
    failed: list[dict[str, str]] = []
    for character_id in sorted(ids):
        row = by_id[character_id]
        try:
            data, provenance = source("/" + row["resource"])
            digest = hashlib.sha256(data).hexdigest()
            if digest != row["resource_sha256"]:
                raise ProgramError("resource_digest_mismatch",
                                   f"catalogue={row['resource_sha256']} actual={digest}",
                                   character=character_id)
            program, boundary = _program(character_id, row, data)
            programs.append(_program_json(program, boundary, row))
            proofs.append({
                "id": character_id,
                "source_character_id": row.get("source_character_id"),
                "resource": row["resource"],
                "resource_sha256": digest,
                "resource_provenance": provenance,
                "script_table": program.source["script_table"],
                "section": program.source["section"],
                "frames": program.source["frames"],
                "script_offsets": {
                    "1": _u32(data, program.source["script_table"] + 4, "script1", character_id),
                    "4": _u32(data, program.source["script_table"] + 16, "script4", character_id),
                    "aux": (program.attack.auxiliary["script"] if program.attack.auxiliary else None),
                },
                "family": program.family,
                "impact_tick": program.impact_tick,
                "owner_ready_tick": program.owner_ready_tick,
                "auxiliary_contact_tick": program.auxiliary_contact_tick,
                "auxiliary_release_tick": program.auxiliary_release_tick,
                "return_release_tick": program.return_release_tick,
                "target_release_delay": program.target_release_delay,
                "raw_operations": {
                    "attack": [{"op": op, "args": list(args), "offset": off}
                               for op, args, off in _script(data, program.source["script_table"], 1, character_id)[0]],
                    "return": [{"op": op, "args": list(args), "offset": off}
                               for op, args, off in _script(data, program.source["script_table"], 4, character_id)[0]],
                    "auxiliary": ([{"op": op, "args": list(args), "offset": off}
                                   for op, args, off in _script(data, program.source["script_table"],
                                                                program.attack.auxiliary["script"], character_id)[0]]
                                  if program.attack.auxiliary else []),
                },
                "unresolved": next(p for p in programs if p["id"] == character_id)["unresolved"],
            })
        except ProgramError as exc:
            failed.append({"id": character_id, "code": exc.code, "detail": exc.detail})
        except (KeyError, IndexError, struct.error) as exc:
            failed.append({"id": character_id, "code": "program_parse_error", "detail": str(exc)})
    if failed:
        raise ProgramError("character_export_failed", json.dumps(failed, sort_keys=True))

    coverage = {
        "requested": sorted(ids),
        "exported": sorted(p["id"] for p in programs),
        "baseline": [name for name in BASELINE if name in ids],
        "failures": [],
        "families": {family: sorted(p["id"] for p in programs if p["family"] == family)
                     for family in sorted({p["family"] for p in programs})},
    }
    controls = {
        "simultaneous": {
            "fixture": "game/tests/fixtures/world_c_party_distinct_misses.json",
            "expectation": "same update 189, party impact order actor0 then actor1",
        },
        "blocked_or_no_live_target": {
            "fixture": "game/tests/fixtures/world_c_party_all_commands.json",
            "expectation": "actor3 has no attack command; no actor3 party impact; coordinator advances without inventing a strike",
        },
        "baseline_reaction_distinction": {
            "hero": 36, "gremio": 36, "pahn": 49,
            "source": "export_world_travel.party_attack_timing",
        },
    }
    manifest = {
        "schema": SCHEMA,
        "catalogue": {"sha256": catalogue_sha, "canonical_sha256": catalogue_canonical,
                       "characters": 78},
        "characters": sorted(programs, key=lambda row: row["id"]),
        "coverage": coverage,
        "controls": controls,
    }
    manifest_bytes = _canonical(manifest)
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
    proof = {
        "schema": PROOF_SCHEMA,
        "exporter": {"path": "kit/tools/export_party_action_programs.py", "version": "1.0.0"},
        "input": {
            "catalogue_path": str(catalogue_path.relative_to(ROOT)) if catalogue_path.is_relative_to(ROOT) else catalogue_path.name,
            "catalogue_file_sha256": catalogue_sha,
            "catalogue_canonical_sha256": catalogue_canonical,
            "c_report_commit": C_PACKAGE_COMMIT,
            "c_report_sha256": C_PACKAGE_REPORT_SHA256,
            "hash_convention": "file sha256 is exact bytes; canonical sha256 is UTF-8 JSON with sort_keys and compact separators",
        },
        "source_contract": {
            "dispatcher": "0x800E3820",
            "handler_table": "0x8016BABC",
            "attack_script": 1,
            "return_script": 4,
            "auxiliary_script": "the script index named by opcode 24, normally 9",
            "impact_mask": 2,
            "ready_mask": 4,
            "clock": "source update counts; animation wait5 and movement wait21 advance concurrently, timer3 is additive",
            "target_reaction": "started by the caller-owned coordinator on impact; this packet supplies the boundary and does not pre-roll hit/damage/RNG",
        },
        "coverage": coverage,
        "characters": sorted(proofs, key=lambda row: row["id"]),
        "controls": controls,
        "frontier": [
            {"kind": "target_reaction_release", "detail": "target reaction timing/down is caller-owned; only the impact trigger is exported"},
            {"kind": "visual_references", "detail": "auxiliary graphic ids and external effect ids are named, not decoded into art"},
            {"kind": "runtime_admission", "detail": "C's PartyStrike/Effect adapter and live battle admission are integrator-owned"},
        ],
        "outputs": {"manifest_sha256": manifest_sha},
        "media": {"status": "not applicable; no media generated", "promoted": False},
    }
    if out is not None:
        _publish(Path(out), manifest_bytes, manifest, proof)
        proof["outputs"]["manifest_path"] = "party_action_programs.json"
    if report is not None:
        report = Path(report)
        report.parent.mkdir(parents=True, exist_ok=True)
        tmp = report.with_name(f".{report.name}.{os.getpid()}.tmp")
        tmp.write_bytes(_canonical(proof))
        os.replace(tmp, report)
    return manifest


def _publish(out: Path, manifest_bytes: bytes, manifest: dict[str, Any], proof: dict[str, Any]) -> None:
    out = out.resolve()
    accepted = (ROOT / "kit/work/accepted").resolve()
    if accepted in (out, *out.parents):
        raise ProgramError("accepted_output", str(out))
    out.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".party-action-stage-", dir=out))
    try:
        (stage / "party_action_programs.json").write_bytes(manifest_bytes)
        staged = json.loads((stage / "party_action_programs.json").read_text())
        if staged.get("schema") != SCHEMA or not staged.get("characters"):
            raise ProgramError("staged_manifest_invalid", "")
        os.replace(stage / "party_action_programs.json", out / "party_action_programs.json")
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--characters", default=",".join(DEFAULT_CHARACTERS),
                        help="comma-separated stable IDs, or 'all'")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--catalogue", type=Path, default=DEFAULT_CATALOGUE)
    args = parser.parse_args(argv)
    result = export(args.characters, catalogue_path=args.catalogue, out=args.out, report=args.report)
    print(f"exported {len(result['characters'])} ordinary action programs; families={result['coverage']['families']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
