#!/usr/bin/env python3
"""Headless sanity check for a runtime journey package.

Validates the files the Zig launcher loads before opening a window: the room
package, journey config, battle data, and every atlas rectangle.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import wave
from functools import partial
from pathlib import Path

from PIL import Image

from room_battle_package import (
    ROOM_CONDITIONS_SCHEMA, SCENERY_CONDITIONS_SCHEMA, PROP_SCHEMA, WHEEL_MAP_SCHEMA, WORLD_ENTRY_SCHEMA, SCENERY_MODEL_SCHEMA, SCENERY_DRAW_SCHEMA, WORLD_ENTRY_SCHEMAS, SCENERY_SCHEMAS, validate_room_scenery, read_room_events, valid_scenery_path, validate_wheel_map, validate_world_entries,
)

REQUIRED = (
    "room.json",
    "journey.json",
    "atlas.png",
    "battle/trial.json",
    "battle/actors.png",
    "battle/floor.png",
    "party/catalogue.json",
    "party/ownership_bindings.json",
    "ui.json",
)


PLACEHOLDERS = ("placeholder", "lorem ipsum", "tbd", "todo")


def text_ok(value: str) -> bool:
    lowered = (value or "").lower()
    return not any(marker in lowered for marker in PLACEHOLDERS)


def rect_ok(rect: dict, width: int, height: int) -> bool:
    return (
        rect["x"] >= 0
        and rect["y"] >= 0
        and rect["w"] > 0
        and rect["h"] > 0
        and rect["w"] <= width
        and rect["h"] <= height
        and rect["x"] <= width - rect["w"]
        and rect["y"] <= height - rect["h"]
    )


def dialogue_page_problem(page: str) -> str | None:
    if len(page) > 4096:
        return "page is too long"
    lines = page.splitlines()
    if len(lines) > 8:
        return "page has more than 8 lines"
    if any(len(line) > 60 for line in lines):
        return "page line exceeds 60 characters"
    return None


def check_ui(root: Path, atlas, errors: list[str]) -> None:
    ui = json.loads((root / "ui.json").read_text())
    if ui.get("schema") != "suikoden-ui-font/1":
        errors.append("ui.json schema is not suikoden-ui-font/1")
        return
    glyphs = ui.get("glyphs", [])
    pieces = ui.get("window", [])
    if not glyphs or len(glyphs) > 128:
        errors.append("ui.json glyph count is invalid")
    if len(pieces) != 9:
        errors.append("ui.json must have 9 window pieces")
    seen_chars: set[str] = set()
    for glyph in glyphs:
        character = glyph.get("character")
        if not isinstance(character, str) or len(character) != 1:
            errors.append("ui.json glyph character is invalid")
            continue
        if character in seen_chars:
            errors.append(f"ui.json duplicate glyph {character!r}")
        seen_chars.add(character)
        advance = glyph.get("advance", 0)
        if not 1 <= advance <= 8:
            errors.append(f"ui.json glyph {character!r} advance is invalid")
        rect = glyph.get("rect")
        if rect is None:
            if character != " ":
                errors.append(f"ui.json glyph {character!r} has no rectangle")
        elif not rect_ok(rect, *atlas.size):
            errors.append(f"ui.json glyph {character!r} rectangle is outside the atlas")
    roles = set()
    for piece in pieces:
        role = piece.get("role")
        if role in roles:
            errors.append(f"ui.json duplicate window role {role}")
        roles.add(role)
        if not rect_ok(piece["rect"], *atlas.size):
            errors.append(f"ui.json window {role} is outside the atlas")
    expected = {"center", "top_left", "top_right", "bottom_left", "bottom_right", "top", "bottom", "left", "right"}
    if roles != expected:
        errors.append(f"ui.json window roles are incomplete: {sorted(expected - roles)}")


def check_meta(package: dict, journey: dict, errors: list[str]) -> None:
    if not journey.get("title"):
        errors.append("journey.json has no title")
    elif not text_ok(journey["title"]):
        errors.append("journey.json title is placeholder text")
    if journey.get("schema") != "suikoden-journey/3":
        errors.append("journey.json schema is not suikoden-journey/3")
    if not 1 <= len(package.get("rooms", [])) <= 2048:
        errors.append("room.json must contain 1 to 2048 rooms")
    journey_room_ids = [entry.get("room") for entry in journey.get("rooms", [])]
    package_room_ids = {room.get("id") for room in package.get("rooms", [])}
    for room_id in journey_room_ids:
        if room_id not in package_room_ids:
            errors.append(f"journey.json references missing room {room_id}")


def check_media(atlas, actors, floor, errors: list[str]) -> None:
    if floor.size != (320, 240):
        errors.append(f"battle/floor.png is {floor.size}, expected 320x240")
    for name, image in (("atlas.png", atlas), ("battle/actors.png", actors)):
        if image.width > 4096 or image.height > 4096:
            errors.append(f"{name} exceeds the 4096x4096 runtime atlas limit")


def check_clips(package: dict, atlas, errors: list[str]) -> None:
    expected_directions = ["down", "up", "left", "right"]
    for index, clip in enumerate(package.get("player_clips", [])):
        if clip.get("direction") != expected_directions[index]:
            errors.append("player clips are not in down/up/left/right order")
        if not clip.get("frames") or len(clip["frames"]) > 32:
            errors.append(f"player clip {index} has an invalid frame count")
        if not 0 <= clip.get("idle_frame", -1) < len(clip.get("frames", [])):
            errors.append(f"player clip {index} has an invalid idle frame")
    for clip in package.get("player_clips", []):
        for frame in clip.get("frames", []):
            if not rect_ok(frame["rect"], *atlas.size):
                errors.append(f"player clip outside atlas: {frame['rect']}")
            if frame.get("ticks", 0) <= 0:
                errors.append("player clip frame has zero ticks")
            anchor_x, anchor_y = frame.get("anchor_x", 0), frame.get("anchor_y", 0)
            if not (0 <= anchor_x <= frame["rect"]["w"] and 0 <= anchor_y <= frame["rect"]["h"]):
                errors.append("player clip frame anchor is outside its rectangle")


def valid_story_condition(condition) -> bool:
    if not isinstance(condition, dict) or set(condition) != {'kind', 'flag'}:
        return False
    if condition['kind'] not in ('story_mask_set', 'story_mask_clear'):
        return False
    flag = condition['flag']
    if not isinstance(flag, dict) or set(flag) != {'id', 'mask'}:
        return False
    identifier, mask = flag['id'], flag['mask']
    return (type(mask) is int and 1 <= mask <= 255
            and isinstance(identifier, str) and len(identifier) == 13 and identifier.startswith('scenario_')
            and identifier[9:].isascii() and identifier[9:].isdecimal() and int(identifier[9:]) < 240)


def valid_room_condition(condition) -> bool:
    return (isinstance(condition, dict) and set(condition) == {'kind', 'index', 'mask'}
            and condition['kind'] in ('room_mask_set', 'room_mask_clear')
            and type(condition['index']) is int and 0 <= condition['index'] < 20
            and type(condition['mask']) is int and 1 <= condition['mask'] <= 255)


def check_crossing_view(root: Path, room: dict, errors: list[str]) -> None:
    try:
        with (root / "travel/crossing.json").open("rb") as stream:
            raw = stream.read(256 * 1024 + 1)
        with (root / "travel/crossing.png").open("rb") as stream:
            png = stream.read(4 * 1024 * 1024 + 1)
        if len(raw) > 256 * 1024 or len(png) > 4 * 1024 * 1024:
            raise ValueError("crossing resource exceeds its native limit")
        model = json.loads(raw)
        if not isinstance(model, dict):
            raise ValueError("crossing viewport must be an object")
        if (model.get("schema") != "suikoden-crossing-art/1" or model.get("region") != "region_j"
                or model.get("atlas") != "travel/crossing.png"
                or model.get("atlas_sha256") != hashlib.sha256(png).hexdigest()
                or (model.get("atlas_width"), model.get("atlas_height")) != (256, 352)
                or len(model.get("cells", [])) != 19200 or len(model.get("tiles", [])) != 320
                or len(model.get("poses", [])) != 12
                or (room.get("width"), room.get("height")) != (1280, 960)
                or len(room.get("boat_walkable", "")) != 19200):
            raise ValueError("invalid dedicated crossing viewport")
        with Image.open(root / "travel/crossing.png") as image:
            if image.size != (256, 352):
                raise ValueError("crossing atlas dimensions do not match")
    except (OSError, ValueError, TypeError, Image.DecompressionBombError) as error:
        errors.append(f"world_j: {error}")


def check_rooms(package: dict, journey: dict, atlas, root: Path, canonical: bool, errors: list[str],
                *, has_opening_world_exit: bool = False) -> None:
    start_room = next((room for room in package["rooms"] if room["id"] == package.get("start_room")), None)
    supports_scenery = package.get('schema') in SCENERY_SCHEMAS
    supports_arrival_facing = package.get('schema') == 'suikoden-room/10' or supports_scenery
    supports_world_exits = package.get('schema') == 'suikoden-room/9' or supports_arrival_facing
    if canonical:
        canonical_rooms = {"vaa_room_2", "vaa_room_1", "vaa_room_0", "vaa_room_10", "va1_room_0", "va1_room_1", "va1_room_2"}
        has_walked_world_exit = supports_world_exits and any(
            exit.get('world_exit') is True for room in package['rooms'] for exit in room.get('exits', [])
        )
        room_ids_present = {room["id"] for room in package["rooms"]}
        if "world_a" in room_ids_present or (not has_opening_world_exit and not has_walked_world_exit):
            canonical_rooms.add("world_a")
            patrol = next((entry for entry in journey.get("encounters", []) if entry.get("id") == "world_patrol"), None)
            if patrol is None or patrol.get("room") != "world_a" or patrol.get("encounter") != "area_a_1":
                errors.append("canonical package is missing the derived area_a_1 world patrol")
        missing = canonical_rooms - {room["id"] for room in package["rooms"]}
        if missing:
            errors.append(f"canonical package is missing rooms: {sorted(missing)}")
        if package.get("start_room") != "vaa_room_2":
            errors.append("canonical package does not start in vaa_room_2")
        for name in ("audio/audio.json", "audio/palace.wav", "audio/audience.wav"):
            if not (root / name).is_file():
                errors.append(f"canonical package is missing {name}")
    if start_room is None:
        errors.append(f"start room {package.get('start_room')} is missing")
    elif not start_room.get("draws"):
        errors.append(f"start room {start_room['id']} has no draws")
    try:
        validate_world_entries(package)
    except (ValueError, KeyError, TypeError) as error:
        errors.append(str(error))
    room_ids = {room["id"] for room in package["rooms"]}
    for room in package["rooms"]:
        if not room.get("title"):
            errors.append(f"{room['id']} has no title")
        elif not text_ok(room["title"]):
            errors.append(f"{room['id']} title is placeholder text")
        if set(room.get("walkable", "")) - {"0", "1"}:
            errors.append(f"{room['id']} walkable contains characters other than 0/1")
        if room["width"] <= 0 or room["height"] <= 0 or room["width"] % 8 or room["height"] % 8:
            errors.append(f"{room['id']} dimensions are not positive multiples of 8")
        elif len(room.get("walkable", "")) != (room["width"] // 8) * (room["height"] // 8):
            errors.append(f"{room['id']} walkable length does not match its grid")
        water, rapids = room.get('boat_walkable'), room.get('boat_rapids')
        if water is not None and (not isinstance(water, str) or len(water) != len(room.get('walkable', ''))
                                  or set(water) - set('012' if rapids is not None else '01')):
            errors.append(f"{room['id']} has an invalid boat grid")
        if rapids is not None and (not isinstance(water, str) or '2' not in water or not isinstance(rapids, dict)
                or set(rapids) != {'requires', 'warned', 'pages'}
                or not all(valid_story_condition({'kind': 'story_mask_set', 'flag': rapids[flag]}) for flag in ('requires', 'warned'))
                or not isinstance(rapids['pages'], list) or not 1 <= len(rapids['pages']) <= 4
                or any(not isinstance(page, str) or not text_ok(page) or len(page.encode()) > 512 for page in rapids['pages'])):
            errors.append(f"{room['id']} has invalid rapids data")
    if len(room_ids) != len(package["rooms"]):
        errors.append("room IDs are not unique")
    if start_room is not None:
        sx, sy, sw, sh = package.get("start_x", 0), package.get("start_y", 0), start_room["width"], start_room["height"]
        if sx < 0 or sy < 0 or sx >= sw or sy >= sh or sx % 8 or sy % 8:
            errors.append("start position is outside or misaligned")
        else:
            index = (sy // 8) * (sw // 8) + (sx // 8)
            if index >= len(start_room["walkable"]) or start_room["walkable"][index] != "1":
                errors.append("start position is not walkable")
    scenery_sizes = {}
    for room in package["rooms"]:
        if not room.get("draws"):
            if room['id'] == 'world_j':
                check_crossing_view(root, room, errors)
            else:
                errors.append(f"{room['id']} has no draws")
        for exit in room.get("exits", []):
            if exit["room"] not in room_ids:
                errors.append(f"{room['id']} exit targets missing room {exit['room']}")
            if exit.get("room") == room["id"]:
                errors.append(f"{room['id']} exit targets itself")
            if exit.get("direction") not in (None, "down", "up", "left", "right"):
                errors.append(f"{room['id']} exit has an invalid direction")
            arrival = exit.get('arrival_facing')
            if arrival is not None and (not supports_arrival_facing or arrival not in ('down', 'up', 'left', 'right')):
                errors.append(f"{room['id']} exit has an invalid arrival facing")
            world_exit = exit.get('world_exit', False)
            if type(world_exit) is not bool or (world_exit and not supports_world_exits):
                errors.append(f"{room['id']} exit has an invalid world exit marker")
            conditions = exit.get('conditions')
            if conditions is not None and ((package.get('schema') != 'suikoden-room/8' and not supports_world_exits)
                                           or not isinstance(conditions, list)
                                           or any(not valid_story_condition(condition) for condition in conditions)):
                errors.append(f"{room['id']} exit has invalid story conditions")
            local = exit.get('room_conditions')
            if local is not None and (package.get('schema') not in (ROOM_CONDITIONS_SCHEMA, SCENERY_CONDITIONS_SCHEMA, PROP_SCHEMA, WHEEL_MAP_SCHEMA, WORLD_ENTRY_SCHEMA, SCENERY_MODEL_SCHEMA, SCENERY_DRAW_SCHEMA) or not isinstance(local, list)
                                      or any(not valid_room_condition(condition) for condition in local)):
                errors.append(f"{room['id']} exit has invalid room conditions")
            if exit["w"] <= 0 or exit["h"] <= 0 or exit["x"] < 0 or exit["y"] < 0 or exit["x"] + exit["w"] > room["width"] or exit["y"] + exit["h"] > room["height"]:
                errors.append(f"{room['id']} exit rectangle is outside the room")
            target = next((entry for entry in package["rooms"] if entry["id"] == exit["room"]), None)
            if target is not None:
                tx, ty = exit["spawn_x"], exit["spawn_y"]
                if tx < 0 or ty < 0 or tx >= target["width"] or ty >= target["height"] or tx % 8 or ty % 8:
                    errors.append(f"{room['id']} exit spawn is outside {exit['room']}")
                else:
                    ti = (ty // 8) * (target["width"] // 8) + (tx // 8)
                    if (ti >= len(target["walkable"]) or target["walkable"][ti] != "1") and not (package.get("schema") in WORLD_ENTRY_SCHEMAS and exit.get("source_arrival") is True):
                        errors.append(f"{room['id']} exit spawn is not walkable in {exit['room']}")
        npc_ids = [npc.get("id") for npc in room.get("npcs", [])]
        if len(npc_ids) != len(set(npc_ids)):
            errors.append(f"{room['id']} NPC IDs are not unique")
        event_ids = [event.get("id") for event in room.get("events", [])]
        if len(event_ids) != len(set(event_ids)):
            errors.append(f"{room['id']} event IDs are not unique")
        for npc in room.get("npcs", []):
            if not npc.get("id") or not npc.get("name"):
                errors.append(f"{room['id']} NPC has an empty ID or name")
            elif not text_ok(npc.get("name", "")):
                errors.append(f"{room['id']} NPC name is placeholder text")
            if npc["x"] < 0 or npc["y"] < 0 or npc["x"] >= room["width"] or npc["y"] >= room["height"]:
                errors.append(f"{room['id']} NPC {npc.get('id')} is outside the room")
            if not npc.get("pages"):
                errors.append(f"{room['id']} NPC {npc.get('id')} has no pages")
            for page in npc.get("pages", []):
                if not page:
                    errors.append(f"{room['id']} NPC {npc.get('id')} has an empty page")
                elif not text_ok(page):
                    errors.append(f"{room['id']} NPC {npc.get('id')} page is placeholder text")
                elif (problem := dialogue_page_problem(page)) is not None:
                    errors.append(f"{room['id']} NPC {npc.get('id')} {problem}")
                else:
                    try:
                        page.encode("utf-8").decode("utf-8")
                    except UnicodeError:
                        errors.append(f"{room['id']} NPC {npc.get('id')} page is not valid UTF-8")
        for event in room.get("events", []):
            if not event.get("id") or not event.get("name"):
                errors.append(f"{room['id']} event has an empty ID or name")
            if event["x"] < 0 or event["y"] < 0 or event["x"] + event["w"] > room["width"] or event["y"] + event["h"] > room["height"]:
                errors.append(f"{room['id']} event {event.get('id')} is outside the room")
            if not event.get("pages"):
                errors.append(f"{room['id']} event {event.get('id')} has no pages")
            for page in event.get("pages", []):
                if not page:
                    errors.append(f"{room['id']} event {event.get('id')} has an invalid page")
                elif (problem := dialogue_page_problem(page)) is not None:
                    errors.append(f"{room['id']} event {event.get('id')} {problem}")
                elif not text_ok(page):
                    errors.append(f"{room['id']} event {event.get('id')} page is placeholder text")
        size = atlas.size
        try:
            validate_room_scenery(room, package.get('schema'))
        except ValueError as error:
            errors.append(f"room {room.get('id')}: {error}")
        scenery = room.get('scenery_atlas')
        if scenery is not None:
            if not supports_scenery or not valid_scenery_path(scenery):
                errors.append(f"{room['id']} has an invalid scenery atlas path")
                continue
            if scenery not in scenery_sizes:
                try:
                    with Image.open(root / scenery) as image:
                        if image.format != 'PNG' or max(image.size) > 4096:
                            raise ValueError('expected PNG dimensions of at most 4096×4096')
                        scenery_sizes[scenery] = image.size
                except (OSError, ValueError, Image.DecompressionBombError) as error:
                    errors.append(f"{room['id']} cannot load scenery atlas {scenery}: {error}")
                    continue
            size = scenery_sizes[scenery]
        try:
            validate_wheel_map(room, package.get('schema'))
        except (ValueError, TypeError) as error:
            errors.append(f"{room['id']}: {error}")
        for draw in room.get("draws", []):
            if draw.get('prop') is not None and (package.get('schema') not in (PROP_SCHEMA, WHEEL_MAP_SCHEMA, WORLD_ENTRY_SCHEMA, SCENERY_MODEL_SCHEMA, SCENERY_DRAW_SCHEMA) or type(draw['prop']) is not int or not 0 <= draw['prop'] < 64):
                errors.append(f"{room['id']} draw has invalid prop ID")
            local = draw.get('room_conditions')
            if local is not None and (package.get('schema') not in (SCENERY_CONDITIONS_SCHEMA, PROP_SCHEMA, WHEEL_MAP_SCHEMA, WORLD_ENTRY_SCHEMA, SCENERY_MODEL_SCHEMA, SCENERY_DRAW_SCHEMA) or not isinstance(local, list)
                                      or len(local) > 16 or any(not valid_room_condition(condition) for condition in local)):
                errors.append(f"{room['id']} draw has invalid room conditions")
            if not rect_ok(draw["rect"], *size):
                errors.append(f"{room['id']} draw outside atlas: {draw['rect']}")
            if not isinstance(draw.get("depth", 0), int):
                errors.append(f"{room['id']} draw depth is not an integer")
            for frame in draw.get("frames", []):
                if not rect_ok(frame["rect"], *size):
                    errors.append(f"{room['id']} frame outside atlas: {frame['rect']}")
                if frame.get("ticks", 0) <= 0:
                    errors.append(f"{room['id']} draw frame has zero ticks")


def check_party(root: Path, errors: list[str]) -> None:
    catalogue = json.loads((root / "party/catalogue.json").read_text())
    bindings = json.loads((root / "party/ownership_bindings.json").read_text())
    if catalogue.get("schema") != "suikoden-party-source-facts/1" or len(catalogue.get("characters", [])) != 78:
        errors.append("party/catalogue.json has the wrong schema or character count")
    catalogue_ids = {entry.get("id") for entry in catalogue.get("characters", [])}
    if not {"cleo", "ted"} <= catalogue_ids:
        errors.append("party catalogue is missing Cleo or Ted")
    if bindings.get("schema") != "suikoden-magic-ownership-bindings/1":
        errors.append("party/ownership_bindings.json has the wrong schema")
    ted_binding = bindings.get("ted", {})
    if ted_binding.get("character_id") != "ted" or ted_binding.get("rune_id") != "masked_rune_32" or not ted_binding.get("locked"):
        errors.append("Ted ownership binding is incomplete")


def ranged_attackers(trial: dict, library: dict, size: tuple[int, int]) -> set[str]:
    """Require the actor binding and atlas poses when no flattened attack exists."""
    bindings = (((library.get('counter') or {}).get('ranged') or {}).get('attackers') or [])
    programs = {row.get('id') for row in (library.get('programs') or {}).get('programs', [])}
    resources = {row.get('id') for row in (library.get('animations') or {}).get('resources', [])}
    graphics = {row.get('id'): row for row in trial.get('unite_graphics', [])}
    result = set()
    for binding in bindings:
        identifier = binding.get('id')
        graphic = graphics.get(identifier) or {}
        poses = graphic.get('poses') or []
        required = [binding.get(key) for key in ('attack_program', 'return_program', 'hurt_program')]
        if binding.get('critical_hurt_program'):
            required.append(binding['critical_hurt_program'])
        if not identifier or identifier not in resources or not poses or any(not name or name not in programs for name in required):
            continue
        samples = [sprite for pose in poses for sprite in [pose.get('sprite'), pose.get('ordinary'), *pose.get('pieces', [])] if sprite is not None]
        if not samples or any(not sprite.get('rect') or not rect_ok(sprite['rect'], *size) for sprite in samples):
            continue
        result.add(identifier)
    return result


def check_battle(package: dict, journey: dict, trial: dict, actors, ranged: set[str], errors: list[str]) -> None:
    encounter_ids = {entry.get("id") for entry in trial.get("encounters", [])}
    rooms_by_id = {room["id"]: room for room in package["rooms"]}
    flags = [entry.get("flag") for entry in journey.get("encounters", [])]
    if len(flags) != len(set(flags)):
        errors.append("journey encounter flags are not unique")
    for entry in journey.get("encounters", []):
        if entry.get("w", 0) <= 0 or entry.get("h", 0) <= 0:
            errors.append(f"journey encounter {entry.get('id')} has an invalid size")
        if entry.get("x", 0) % 8 or entry.get("y", 0) % 8 or entry.get("w", 0) % 8 or entry.get("h", 0) % 8:
            errors.append(f"journey encounter {entry.get('id')} is not cell-aligned")
        target = rooms_by_id.get(entry.get("room"))
        if target is not None:
            covered = False
            for y in range(entry.get("y", 0), min(target["height"], entry.get("y", 0) + entry.get("h", 0)), 8):
                for x in range(entry.get("x", 0), min(target["width"], entry.get("x", 0) + entry.get("w", 0)), 8):
                    if target["walkable"][(y // 8) * (target["width"] // 8) + x // 8] == "1":
                        covered = True
            if not covered:
                errors.append(f"journey encounter {entry.get('id')} covers no walkable cell")
        if target is not None and (entry.get("x", 0) < 0 or entry.get("y", 0) < 0 or entry.get("x", 0) + entry.get("w", 0) > target["width"] or entry.get("y", 0) + entry.get("h", 0) > target["height"]):
            errors.append(f"journey encounter {entry.get('id')} is outside its room")
        if entry.get("room") not in {room["id"] for room in package["rooms"]}:
            errors.append(f"journey encounter {entry.get('id')} targets a missing room")
        if entry.get("source_slots") is not None:
            slots = entry["source_slots"]
            if len(slots) != len(entry.get("positions") or []) or any(not isinstance(s, int) or not 0 <= s < 6 for s in slots) or slots != sorted(set(slots)):
                errors.append(f"journey encounter {entry.get('id')} has invalid source slots")
        if entry.get("encounter") not in encounter_ids:
            errors.append(f"journey encounter {entry.get('id')} references missing battle content")
        if not entry.get("flag"):
            errors.append(f"journey encounter {entry.get('id')} has no flag")
    for encounter in trial.get("encounters", []):
        reward_policy = encounter.get("reward_policy", "standard")
        schema = trial.get("schema")
        if reward_policy not in ("standard", "none") or reward_policy == "none" and schema not in ("suikoden-battle-trial/45", "suikoden-battle-trial/46"):
            errors.append(f"battle encounter {encounter.get('id')} has an invalid reward policy")
        finish = encounter.get("scripted_finish")
        if finish is not None and (
                schema != "suikoden-battle-trial/46" or reward_policy != "none"
                or not isinstance(finish, dict) or set(finish) != {"after_round", "wait_ticks"}
                or type(finish["after_round"]) is not int or not 1 <= finish["after_round"] <= 65535
                or type(finish["wait_ticks"]) is not int or not 1 <= finish["wait_ticks"] <= 4096):
            errors.append(f"battle encounter {encounter.get('id')} has an invalid scripted finish")
        slots = encounter.get("source_slots")
        if slots is not None and (len(slots) != len(encounter.get("positions") or []) or any(not isinstance(s, int) or not 0 <= s < 6 for s in slots) or slots != sorted(set(slots))):
            errors.append(f"battle encounter {encounter.get('id')} has invalid source slots")
    ground = trial.get("ground")
    if ground is not None:
        across, down = ground.get("across", 0), ground.get("down", 0)
        vertices, tiles = ground.get("vertices") or [], ground.get("tiles") or []
        if not (1 <= across <= 32 and 1 <= down <= 32):
            errors.append("battle ground dimensions are invalid")
        if len(vertices) != (across + 1) * (down + 1):
            errors.append("battle ground vertex count does not match its grid")
        if len(tiles) != across * down:
            errors.append("battle ground tile count does not match its grid")
        for vertex in vertices:
            if not all(isinstance(vertex.get(axis), (int, float)) for axis in ("x", "y", "z")):
                errors.append("battle ground vertex is not numeric")
                break
        if any(not isinstance(tile, int) or not 0 <= tile < 256 for tile in tiles):
            errors.append("battle ground tile index is outside the 16x16 bank")
    for actor in trial.get("actors", []):
        rect = actor.get("rect")
        if rect and not rect_ok(rect, *actors.size):
            errors.append(f"battle actor outside actors atlas: {rect}")
    rune_ids = {rune.get("id") for rune in (trial.get("systems") or {}).get("runes", [])}
    party_ids = [profile["id"] for profile in trial.get("party", [])]
    for member in trial.get("initial_party") or []:
        if member not in party_ids:
            errors.append(f"initial party member {member} has no profile")
    if len(party_ids) != len(set(party_ids)):
        errors.append("battle party profile IDs are not unique")
    for profile in trial.get("party", []):
        if not profile.get("id") or not profile.get("name"):
            errors.append("battle profile has an empty ID or name")
        if profile.get("max_hp", 0) <= 0 or profile.get("level", 0) <= 0:
            errors.append(f"{profile.get('id')} has invalid HP or level")
        if len(profile.get("growth") or []) != 6:
            errors.append(f"{profile.get('id')} growth is not six values")
        if (profile.get("stats") or {}).get("attack", 0) <= 0:
            errors.append(f"{profile.get('id')} has no attack stat")
        if not profile.get("attack") and profile['id'] not in ranged:
            errors.append(f"{profile['id']} has no attack frames")
        weapon = profile.get("weapon")
        if weapon is None:
            errors.append(f"{profile['id']} has no weapon")
        else:
            if len(weapon.get("names", [])) != 16 or len(weapon.get("powers", [])) != 16:
                errors.append(f"{profile['id']} weapon tables are not 16 entries")
            if any(power <= 0 for power in weapon.get("powers", [])):
                errors.append(f"{profile['id']} weapon has a zero power")
        sprite = profile.get("sprite")
        if sprite and not rect_ok(sprite["rect"], *actors.size):
            errors.append(f"battle sprite outside actors atlas: {sprite['rect']}")
        for frame in profile.get("attack", []):
            pose = frame.get("pose") or {}
            rect = pose.get("rect")
            if not rect or not rect_ok(rect, *actors.size):
                errors.append(f"{profile['id']} attack frame is malformed or outside actors atlas")


def check_battle_audio(root: Path, errors: list[str]) -> None:
    folder = root / "audio"
    names = ("battle.json", "battle.wav", "boss.wav", "victory.wav", "battle_provenance.json")
    if not any((folder / name).exists() for name in names):
        return
    if not all((folder / name).is_file() for name in names):
        errors.append("incomplete battle audio candidate")
        return
    from export_battle_audio import validate
    try:
        validate(folder, json.loads((folder / "battle.json").read_text()))
    except (ValueError, OSError) as error:
        errors.append(f"battle audio: {error}")


def check_defeat_audio(root: Path, errors: list[str]) -> None:
    folder = root / "audio"
    names = ("defeat.json", "defeat.wav", "defeat_provenance.json")
    if not any((folder / name).exists() for name in names):
        return
    if not all((folder / name).is_file() for name in names):
        errors.append("incomplete defeat audio candidate")
        return
    from export_defeat_audio import validate
    try:
        validate(folder, json.loads((folder / "defeat.json").read_text()))
    except (ValueError, OSError) as error:
        errors.append(f"defeat audio: {error}")


def check_battle_sfx(root: Path, errors: list[str]) -> None:
    folder = root / "audio/sfx"
    if not folder.exists():
        return
    from export_battle_sfx import validate
    try:
        validate(folder, json.loads((folder / "battle_sfx.json").read_text()))
    except (ValueError, OSError) as error:
        errors.append(f"battle sounds: {error}")


def check_region_bgm(root: Path, package: dict, errors: list[str]) -> None:
    manifest = root / "audio/region_bgm.json"
    if not manifest.is_file():
        return
    try:
        data = json.loads(manifest.read_text())
    except (OSError, ValueError) as error:
        errors.append(f"region BGM manifest: {error}")
        return
    if data.get("schema") != "suikoden-region-bgm/1" or not isinstance(data.get("tracks"), list) or not isinstance(data.get("rooms"), list):
        errors.append("region BGM manifest: invalid schema or structure")
        return
    track_ids = set()
    audio_root = (root / "audio").resolve()
    for track in data["tracks"]:
        tid = track.get("id")
        rel = track.get("path")
        if not isinstance(tid, str) or not tid or not isinstance(rel, str) or not rel:
            errors.append("region BGM track missing id or path")
            continue
        track_ids.add(tid)
        wav = (root / "audio" / rel).resolve()
        if not wav.is_relative_to(audio_root) or not wav.is_file():
            errors.append(f"region BGM file missing: {rel}")
            continue
        if authored := track.get("authored"):
            try:
                if hashlib.sha256(wav.read_bytes()).hexdigest() != authored["sha256"]:
                    raise ValueError("checksum mismatch")
                with wave.open(str(wav), "rb") as audio:
                    if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getnframes()) != (
                        2, 2, track["sample_rate"], track["frames"],
                    ):
                        raise ValueError("WAV metadata mismatch")
            except (OSError, ValueError, KeyError, TypeError, EOFError, wave.Error) as error:
                errors.append(f"region BGM authored track {tid}: {error}")
    if "jukebox" in data:
        jukebox = data["jukebox"]
        if (not isinstance(jukebox, list) or len(jukebox) != 16
                or any(not isinstance(tid, str) or tid not in track_ids for tid in jukebox)
                or len(set(jukebox)) != len(jukebox)):
            errors.append("region BGM jukebox must reference 16 distinct tracks")
    known_rooms = {r["id"] for r in package.get("rooms", [])}
    for entry in data["rooms"]:
        room = entry.get("room")
        tid = entry.get("track")
        if tid not in track_ids:
            errors.append(f"region BGM room {room!r} references unknown track {tid!r}")
        if room not in known_rooms:
            errors.append(f"region BGM references unknown room {room!r}")


def check_duel_presentation(root: Path, errors: list[str]) -> None:
    metadata, image = root / "duel/presentation.json", root / "duel/atlas.png"
    if not metadata.exists() and not image.exists():
        return
    try:
        packet = json.loads(metadata.read_bytes())
        if packet["schema"] != "suikoden-duel-presentation/1":
            raise ValueError("unknown schema")
        origin = packet.get("art_origin")
        if origin == "authored-duel-art/1":
            raise ValueError("authored preview art is excluded from runtime packages")
        if origin != "disc-extracted-duel-art/1":
            raise ValueError("missing or unsupported duel art origin")
        if hashlib.sha256(image.read_bytes()).hexdigest() != packet["atlas_sha256"]:
            raise ValueError("atlas checksum mismatch")
        with Image.open(image) as atlas:
            for scene in packet["scenes"]:
                if not isinstance(scene, dict):
                    raise ValueError("invalid duel scene")
                gauges = scene.get("gauges")
                if gauges is not None and (not isinstance(gauges, list) or len(gauges) != 2 or any(
                    not rect_ok(rect, *atlas.size) or (rect["w"], rect["h"]) != (128, 32) for rect in gauges
                )):
                    raise ValueError("invalid gauge bands")
            atlas.verify()
    except (OSError, ValueError, KeyError, TypeError) as error:
        errors.append(f"duel presentation: {error}")


def check_actor_impacts(root: Path, actors: dict, errors: list[str]) -> None:
    needed = {i['command']['child']['animation']
              for p in actors.get('programs', {}).get('programs', [])
              for i in p['instructions']
              if i.get('command', {}).get('child', {}).get('resource') == 'shared_impacts'}
    if not needed:return
    path = root/'battle/spells.json'
    if not path.is_file():
        errors.append('missing spell art for shared actor animations')
        return
    available = {clip['id'] for clip in json.loads(path.read_text()).get('unite_impacts', [])}
    for animation in sorted(needed-available):
        errors.append(f'missing shared actor animation {animation}')


def check_strike_reactions(root: Path, trial: dict, actors: dict, errors: list[str]) -> None:
    counter = actors.get('counter') or {}
    if all(counter.get(kind) is None for kind in ('party_melee', 'ranged')):
        return
    path = root / 'battle/spells.json'
    scenes = json.loads(path.read_text()) if path.is_file() else {}
    covered = {pose['id'] for pose in scenes.get('hurt_poses', [])
               if pose.get('impact_offset') is not None and pose.get('knockout') is not None
               and (pose.get('unite_white_entry') is not None or pose.get('white_entry') is not None)}
    enemies = {enemy for encounter in trial.get('encounters', []) for enemy in encounter['enemies']}
    for enemy in sorted(enemies - covered):
        errors.append(f"battle/spells.json: MissingCounterKnockout for enemy '{enemy}'")


def check_battlefield_assets(root: Path, trial: dict, errors: list[str]) -> None:
    fields = trial.get('battlefields') or []
    ids = {field['id'] for field in fields}
    for encounter in trial.get('encounters', []):
        battlefield = encounter.get('battlefield')
        if battlefield is not None and battlefield not in ids:
            errors.append(f"battle encounter {encounter['id']} references unknown battlefield {battlefield}")
    if not fields:
        return
    path = root / 'battle/ground.png'
    if not path.is_file():
        errors.append('missing battle/ground.png for encounter battlefields')
        return
    with Image.open(path) as ground:
        for field in fields:
            rect = field['ground_atlas']
            if not rect_ok(rect, *ground.size) or any(rect[axis] % 32 for axis in ('x', 'y', 'w', 'h')):
                errors.append(f"battlefield {field['id']} has an invalid ground atlas region")
                continue
            tile_count = (rect['w'] // 32) * (rect['h'] // 32)
            if any(not isinstance(tile, int) or not 0 <= tile < min(256, tile_count) for tile in field['ground']['tiles']):
                errors.append(f"battlefield {field['id']} tile is outside its ground atlas region")


def movement_encounter_level_sums(trial: dict) -> dict[str, int]:
    levels = {row['id']: row['level'] for row in trial['enemies']}
    return {row['id']: sum(levels[enemy] for enemy in row['enemies'])
            for row in trial['encounters'] if all(enemy in levels for enemy in row['enemies'])}


def check_movement_encounters(journey: dict, package: dict, trial: dict, errors: list[str]) -> None:
    packet = journey.get('field_encounters')
    if packet is None:
        return
    schemas = tuple(f'suikoden-field-movement-encounters/{version}' for version in (1, 2, 3))
    if not isinstance(packet, dict) or packet.get('schema') not in schemas:
        errors.append('invalid movement encounter schema')
        return
    condition = packet.get('suppress_when')
    if condition is not None and (packet['schema'] == schemas[0] or not valid_story_condition(condition)):
        errors.append('invalid movement encounter suppression condition')
        return
    reset = packet.get('clear_suppression_on_world_entry', False)
    if type(reset) is not bool or (reset and (packet['schema'] != schemas[2] or condition is None
                                             or condition['kind'] != 'story_mask_set')):
        errors.append('invalid movement encounter world-entry reset')
        return
    rooms = packet.get('rooms')
    if not isinstance(rooms, list) or not rooms:
        errors.append('missing movement encounter rooms')
        return
    room_ids = {row['id'] for row in package['rooms']}
    level_sums = movement_encounter_level_sums(trial)
    seen = set()
    for entry in rooms:
        room = entry.get('room') if isinstance(entry, dict) else None
        if not isinstance(room, str) or room not in room_ids or room in seen:
            errors.append(f'invalid or duplicate movement encounter room {room!r}')
            continue
        seen.add(room)
        rate, threshold, candidates = (entry.get(name) for name in ('rate', 'counter_threshold', 'candidates'))
        if (type(rate) is not int or not 1 <= rate <= 255 or type(threshold) is not int
                or not 0 <= threshold <= 255 or not isinstance(candidates, list) or not 1 <= len(candidates) <= 64):
            errors.append(f'invalid movement encounter settings in {room}')
            continue
        for candidate in candidates:
            identifier = candidate.get('id') if isinstance(candidate, dict) else None
            level_sum = level_sums.get(identifier) if isinstance(identifier, str) else None
            if level_sum is None:
                errors.append(f'unknown movement encounter {identifier!r} in {room}')
                continue
            declared = candidate.get('enemy_level_sum')
            if type(declared) is not int or declared != level_sum:
                errors.append(f'invalid movement encounter level sum for {identifier!r} in {room}')


def check_movies(root: Path, errors: list[str]) -> None:
    path = root / "video/movies.json"
    if not path.is_file():
        return
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        errors.append(f"video/movies.json: {error}")
        return
    if not isinstance(data, dict) or data.get("schema") != "suikoden-movies/1":
        errors.append("video/movies.json: unsupported schema")
        return
    if data.get("media_accepted") is not False:
        errors.append("video/movies.json: media_accepted must remain false until human review")
    movies = data.get("movies")
    if not isinstance(movies, list) or [m.get("id") for m in movies if isinstance(m, dict)] != ["logo", "opening", "attract"]:
        errors.append("video/movies.json: expected logo, opening, and attract entries")
        return
    for entry in movies:
        if (type(entry.get("frames")) is not int or entry["frames"] <= 0
                or entry.get("fps") != 15
                or type(entry.get("duration_ms")) is not int or entry["duration_ms"] <= 0
                or entry.get("media_accepted") is not False):
            errors.append(f"video/movies.json: invalid metadata for {entry.get('id')!r}")
            continue
        vpath = entry.get("video_path")
        apath = entry.get("audio_path")
        if vpath is not None:
            full_v = root / vpath
            if not full_v.is_file() or hashlib.sha256(full_v.read_bytes()).hexdigest() != entry.get("video_sha256"):
                errors.append(f"video/movies.json: invalid video file/hash for {entry.get('id')!r}")
            elif full_v.read_bytes()[:4] != b"SJV1":
                errors.append(f"video/movies.json: {vpath} missing SJV1 header")
        if apath is not None:
            full_a = root / apath
            if not full_a.is_file() or hashlib.sha256(full_a.read_bytes()).hexdigest() != entry.get("audio_sha256"):
                errors.append(f"video/movies.json: invalid audio file/hash for {entry.get('id')!r}")


def check(root: Path, canonical: bool = False) -> list[str]:
    missing = [name for name in REQUIRED if not (root / name).is_file()]
    errors = [f"missing {name}" for name in missing]
    if 'battle/trial.json' in missing:
        return errors
    trial = json.loads((root / "battle/trial.json").read_text())
    check_battlefield_assets(root, trial, errors)
    actor_path = root / 'battle/unites.json'
    actor_library = json.loads(actor_path.read_text()) if actor_path.is_file() else {}
    check_strike_reactions(root, trial, actor_library, errors)
    if missing:
        return errors
    for name, limit in (("room.json", 64 * 1024 * 1024), ("journey.json", 2 * 1024 * 1024)):
        if (root / name).stat().st_size > limit:
            return [*errors, f"{name} exceeds its {limit // (1024 * 1024)} MiB runtime limit"]
    package = json.loads((root / "room.json").read_text())
    journey = json.loads((root / "journey.json").read_text())
    check_movement_encounters(journey, package, trial, errors)
    atlas = Image.open(root / "atlas.png")
    has_opening_world_exit = False
    try:
        _, has_opening_world_exit = read_room_events(root, {room['id'] for room in package['rooms']},
                                                     {encounter['id'] for encounter in trial['encounters']}, atlas_size=atlas.size)
    except ValueError as error:
        errors.append(str(error))
    actors = Image.open(root / "battle/actors.png")
    floor = Image.open(root / "battle/floor.png")
    rules = (
        partial(check_meta, package, journey),
        partial(check_media, atlas, actors, floor),
        partial(check_clips, package, atlas),
        partial(check_ui, root, atlas),
        partial(check_rooms, package, journey, atlas, root, canonical, has_opening_world_exit=has_opening_world_exit),
        partial(check_party, root),
        partial(check_battle_audio, root),
        partial(check_defeat_audio, root),
        partial(check_battle_sfx, root),
        partial(check_region_bgm, root, package),
        partial(check_duel_presentation, root),
        partial(check_actor_impacts, root, actor_library),
        partial(check_movies, root),
        partial(check_battle, package, journey, trial, actors, ranged_attackers(trial, actor_library, actors.size)),
    )
    for rule in rules:
        rule(errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, nargs="?")
    parser.add_argument("--canonical", action="store_true", help="require the canonical world segment")
    parser.add_argument("--list-required", action="store_true", help="print the required runtime files")
    args = parser.parse_args()
    if args.list_required:
        for name in REQUIRED:
            print(name)
        return 0
    if args.root is None:
        parser.error("root is required unless --list-required is used")
    errors = check(args.root, args.canonical)
    for error in errors:
        print(f"ERROR: {error}")
    if errors:
        return 1
    print(f"OK: {args.root} is a valid runtime journey package")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
