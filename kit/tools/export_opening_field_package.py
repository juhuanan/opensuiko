#!/usr/bin/env python3
"""Export field events for the playable opening and its connected world route."""
from __future__ import annotations

import argparse
from collections import deque
import copy
from functools import cache
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import area_scene as scene
import opening_audience
from event_script_decode import decode_stream, switch_2f_targets
from export_first_room import area_room_walkable_grid, source
from export_scene_population import PAD_DIRECTION_MASKS, decode_predicate, convert_position, inherits_actor, interaction_actor_candidates, actor_allocation_order, ReservedActorPredicate
from room_battle_package import CURRENT_SCHEMA

SCHEMA = "suikoden-battle-field-events/21"
POPULATION_SCHEMA = "suikoden-scene-population/2"
CONTENT_SCHEMA = "suikoden-event-ir/1"
DIALOGUE_SCHEMA = "suikoden-field-dialogue/8"

AREA_DESCRIPTORS = (
    ("DATA/01_AREA.A/VAA.BIN", "/VAA.BIN", "Imperial Palace", (0, 2, 10), {0: "Imperial Palace", 1: "Gregminster Outskirts", 2: "Imperial Palace"}),
    ("DATA/01_AREA.A/VA1.BIN", "/VA1.BIN", "Gregminster", (0, 17), {3: "Inn", 4: "Inn 2F", 5: "Inn room", 6: "Gregminster Shops", 7: "Sonya's House", 8: "Gregminster Rune Shop", 9: "Milich's Mansion", 10: "Milich's Room", 11: "Gregminster Appraisal Shop", 16: "Kraze's mansion", 17: "Gregminster gate"}),
    ("DATA/01_AREA.A/VA2.BIN", "/VA2.BIN", "Rockland", (0,), {3: "Grady's mansion", 4: "Rockland Inn", 5: "Rockland Item Shop", 6: "Rockland Armory", 7: "Grady's mansion", 8: "Grady's mansion", 9: "Grady's mansion", 10: "Grady's dungeon"}),
    ("DATA/01_AREA.A/VA4.BIN", "/VA4.BIN", "Magician's Island", (0,), {}),
    ("DATA/01_AREA.A/VA7.BIN", "/VA7.BIN", "Mt. Seifu", (0,), {0: "Mt. Seifu Entrance"}),
    ("DATA/01_AREA.A/VA6.BIN", "/VA6.BIN", "Kwaba Fortress", (1, 2), {}),
    ("DATA/02_AREA.B/VB6.BIN", "/VB6.BIN", "Great Forest", (0,), {0: "Great Forest Entrance", 6: "Kobold Village", 10: "Great Forest Inn"}),
    ("DATA/01_AREA.A/VA3.BIN", "/VA3.BIN", "Lenankamp", (0,), {1: "Liberation Army Hideout", 2: "Keyaki Inn", 3: "Keyaki Inn"}),
    ("DATA/01_AREA.A/VA8.BIN", "/VA8.BIN", "Mt. Tigerwolf", (0, 9), {10: "Ledon's Inn"}),
    ("DATA/01_AREA.A/VA5.BIN", "/VA5.BIN", "Sarady", (0,), {1: "Sarady Inn", 2: "Sarady Shop", 3: "Sarady Back Room"}),
    ("DATA/02_AREA.B/VB1.BIN", "/VB1.BIN", "Seika", (0,), {5: "Seika School"}),
    ("DATA/02_AREA.B/VB2.BIN", "/VB2.BIN", "Kaku", (0,), {5: "Kaku Tavern", 6: "Kaku Tavern Basement"}),
    ("DATA/02_AREA.B/VB3.BIN", "/VB3.BIN", "Kouan", (0,), {2: "Kouan Inn", 11: "Lepant's Mansion", 12: "Lepant's Mansion", 13: "Lepant's Mansion", 14: "Lepant's Mansion", 15: "Lepant's Mansion", 20: "Lepant's Mansion"}),
    ("DATA/02_AREA.B/VB5.BIN", "/VB5.BIN", "Toran Ruins", (0,), {}),
    ("DATA/01_AREA.A/VAAD.BIN", "/VAAD.BIN", "Imperial Palace", (0,), {}),
    ("DATA/02_AREA.B/VB5G.BIN", "/VB5G.BIN", "Toran Castle", (1,), {}),
    ("DATA/02_AREA.B/VB7D.BIN", "/VB7D.BIN", "Toran Castle", (0, 1), {}),
    ("DATA/02_AREA.B/VB8.BIN", "/VB8.BIN", "Pirates' Hideout", (0,), {}),
    ("DATA/06_AREA.C/VC1.BIN", "/VC1.BIN", "Dwarves' Trail", (0,), {}),
    ("DATA/06_AREA.C/VC2.BIN", "/VC2.BIN", "Dwarves' Village", (0,), {}),
    ("DATA/06_AREA.C/VC3.BIN", "/VC3.BIN", "Dwarves' Vault", (0,), {}),
    ("DATA/06_AREA.C/VC4.BIN", "/VC4.BIN", "Pannu Yakuta", (0,), {}),
    ("DATA/06_AREA.C/VC5.BIN", "/VC5.BIN", "Great Forest", (0,), {}),
    ("DATA/06_AREA.C/VC6.BIN", "/VC6.BIN", "Neclord's Castle", (0,), {}),
    ("DATA/06_AREA.C/VCD.BIN", "/VCD.BIN", "Pannu Yakuta", (0,), {}),
    ("DATA/15_AREA.Z/VAC.BIN", "/VAC.BIN", "Gregminster", (0, 16), {}),
    ("DATA/15_AREA.Z/VAD.BIN", "/VAD.BIN", "Imperial Palace", (0,), {}),
    ("DATA/15_AREA.Z/VZ2.BIN", "/VZ2.BIN", "Rockland", (0,), {}),
    ("DATA/15_AREA.Z/VZ3.BIN", "/VZ3.BIN", "Lenankamp", (0,), {}),
    ("DATA/01_AREA.A/VA4B.BIN", "/VA4B.BIN", "Magician's Island", (0,), {}),
    ("DATA/01_AREA.A/VA9.BIN", "/VA9.BIN", "Mt. Tigerwolf", (0, 1), {}),
    ("DATA/02_AREA.B/VB4.BIN", "/VB4.BIN", "Kouan Harbor", (0,), {}),
    ("DATA/02_AREA.B/VB5A1.BIN", "/VB5A1.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5A2.BIN", "/VB5A2.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5AB.BIN", "/VB5AB.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5AG.BIN", "/VB5AG.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5B1.BIN", "/VB5B1.BIN", "Toran Castle", (0, 9), {}),
    ("DATA/02_AREA.B/VB5B2.BIN", "/VB5B2.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5B3.BIN", "/VB5B3.BIN", "Toran Castle", (0, 4), {}),
    ("DATA/02_AREA.B/VB5B4.BIN", "/VB5B4.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5BA.BIN", "/VB5BA.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5BB.BIN", "/VB5BB.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5BG.BIN", "/VB5BG.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5C1.BIN", "/VB5C1.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5C2.BIN", "/VB5C2.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5C3.BIN", "/VB5C3.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5C4.BIN", "/VB5C4.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5CA.BIN", "/VB5CA.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5CB.BIN", "/VB5CB.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5CC.BIN", "/VB5CC.BIN", "Toran Castle", (0, 3), {}),
    ("DATA/02_AREA.B/VB5CG.BIN", "/VB5CG.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB5I0.BIN", "/VB5I0.BIN", "Lake Toran", (0, 4, 5), {}),
    ("DATA/02_AREA.B/VB5I2.BIN", "/VB5I2.BIN", "Lake Toran", (0,), {}),
    ("DATA/02_AREA.B/VB5I3.BIN", "/VB5I3.BIN", "Lake Toran", (0,), {}),
    ("DATA/02_AREA.B/VB5I4.BIN", "/VB5I4.BIN", "Lake Toran", (0,), {}),
    ("DATA/02_AREA.B/VB7.BIN", "/VB7.BIN", "Toran Castle", (2, 3, 4, 5), {}),
    ("DATA/02_AREA.B/VB7A.BIN", "/VB7A.BIN", "Toran Castle", (0,), {}),
    ("DATA/02_AREA.B/VB9.BIN", "/VB9.BIN", "Lake Toran", (0,), {}),
    ("DATA/07_AREA.D/VD1.BIN", "/VD1.BIN", "Antei", (0,), {}),
    ("DATA/07_AREA.D/VD2.BIN", "/VD2.BIN", "Teien", (0,), {}),
    ("DATA/07_AREA.D/VD3.BIN", "/VD3.BIN", "Rikon", (0,), {}),
    ("DATA/07_AREA.D/VD4.BIN", "/VD4.BIN", "Liukan's Hermitage", (0,), {}),
    ("DATA/07_AREA.D/VD5.BIN", "/VD5.BIN", "Soniere Prison", (0,), {}),
    ("DATA/07_AREA.D/VD6.BIN", "/VD6.BIN", "Qlon", (0,), {}),
    ("DATA/07_AREA.D/VD7.BIN", "/VD7.BIN", "Cave of the Past", (0,), {}),
    ("DATA/08_AREA.E/VE1.BIN", "/VE1.BIN", "Kirov", (0,), {}),
    ("DATA/08_AREA.E/VE2.BIN", "/VE2.BIN", "Kalekka", (0,), {}),
    ("DATA/08_AREA.E/VE3.BIN", "/VE3.BIN", "Secret Factory", (0,), {}),
    ("DATA/08_AREA.E/VE4.BIN", "/VE4.BIN", "Lorimar", (0,), {}),
    ("DATA/08_AREA.E/VE5.BIN", "/VE5.BIN", "Warrior's Village", (0,), {}),
    ("DATA/08_AREA.E/VE6.BIN", "/VE6.BIN", "Neclord's Castle", (0,), {}),
    ("DATA/09_AREA.F/VF1.BIN", "/VF1.BIN", "Seek Valley", (0,), {}),
    ("DATA/09_AREA.F/VF2.BIN", "/VF2.BIN", "Dragon's Den", (0,), {}),
    ("DATA/09_AREA.F/VF3.BIN", "/VF3.BIN", "Dragon Knights' Fortress", (0,), {}),
    ("DATA/09_AREA.F/VF4.BIN", "/VF4.BIN", "Dragon Knights' Fortress", (0,), {}),
    ("DATA/10_AREA.G/VG1.BIN", "/VG1.BIN", "Northern Swallow Pass", (0,), {}),
    ("DATA/10_AREA.G/VG2.BIN", "/VG2.BIN", "Moravia Castle", (0, 1, 2, 3, 4, 5, 6), {}),
    ("DATA/10_AREA.G/VG3.BIN", "/VG3.BIN", "Moravia", (0,), {}),
    ("DATA/11_AREA.H/VH1.BIN", "/VH1.BIN", "Shasarazade", (0,), {}),
    ("DATA/11_AREA.H/VH2.BIN", "/VH2.BIN", "Shasarazade", (0,), {}),
    ("DATA/13_AREA.I/VI1.BIN", "/VI1.BIN", "Gregminster Siege", (0,), {}),
    ("DATA/13_AREA.I/VI2.BIN", "/VI2.BIN", "Imperial Palace", (0,), {}),
    ("DATA/14_AREA.S/VS1.BIN", "/VS1.BIN", "Ending Scene", (0, 1), {}),
    ("DATA/14_AREA.S/VS2.BIN", "/VS2.BIN", "Ending Scene", (0,), {}),
    ("DATA/15_AREA.Z/VZ1.BIN", "/VZ1.BIN", "Gregminster", (0,), {}),
    ("DATA/15_AREA.Z/VZ5.BIN", "/VZ5.BIN", "Sarady", (0,), {}),
)


def _bfs_local_warps(data: bytes, start_pc: int | None) -> list[int]:
    if start_pc is None:
        return []
    seen: set[int] = set()
    q = deque([start_pc])
    dests: list[int] = []
    while q:
        pc = q.popleft()
        if pc in seen or not (0 <= pc < len(data)):
            continue
        seen.add(pc)
        row = decode_stream(data, start=pc, max_insns=1)
        if not row:
            continue
        _, op, opnd, note = row[0]
        end = pc + 1 + len(opnd)
        if op == 0xFD or "UNKNOWN" in note or "NULL" in note:
            continue
        if op == 0x03:
            if len(opnd) == 3 and opnd[0] < 128:
                dests.append(opnd[0])
            if opnd and opnd[0] == 252:
                q.append(end)
            continue
        if op == 0x14:
            q.append(pc + 1 + opnd[0])
        elif op == 0x23:
            q.append(pc + 1 - opnd[0])
        elif op == 0x15:
            for d in (1, *opnd[1:]):
                q.append(pc + opnd[0] + d)
        elif op == 0x2F:
            for t in switch_2f_targets(data, pc).values():
                q.append(t)
        elif op == 0x2D:
            f = data.rfind(bytes(opnd), 0, pc + 1)
            if f >= 0:
                q.append(f + 1)
        elif op == 0x2E:
            f = data.find(bytes(opnd), pc + 2)
            if f >= 0:
                q.append(f + 1)
        else:
            q.append(end)
    return dests


def discover_area_entries(descriptors=AREA_DESCRIPTORS) -> tuple[tuple[str, str, int, str, str], ...]:
    """Follow source local-warp references from the supplied area seeds."""
    entries: list[tuple[str, str, int, str, str]] = []
    for disc_path, fname, default_title, seeds, title_overrides in descriptors:
        data, _ = source(fname)
        seen_rn: set[int] = set()
        q = deque(seeds)
        while q:
            rn = q.popleft()
            if rn in seen_rn:
                continue
            rec = scene.room_record(data, rn)
            if rec is None:
                continue
            seen_rn.add(rn)
            for ent in scene.entities(data, rec):
                for t_rn in _bfs_local_warps(data, ent["stream_offsets"][2]):
                    if t_rn not in seen_rn:
                        q.append(t_rn)
        prefix = fname[1:-4].lower()
        for rn in sorted(seen_rn):
            entries.append((disc_path, fname, rn, f"{prefix}_room_{rn}", title_overrides.get(rn, default_title)))
    return tuple(entries)


AREA_ENTRIES = discover_area_entries()
OPENING_ROOMS = tuple((fn, rn, rid) for _, fn, rn, rid, _ in AREA_ENTRIES)
AREA_ROOM_ID: dict[str, dict[int, str]] = {}
for _fn, _rn, _rid in OPENING_ROOMS:
    AREA_ROOM_ID.setdefault(_fn, {})[_rn] = _rid

ROOM_TO_SRC = {rid: (fn, rn) for fn, rn, rid in OPENING_ROOMS}

_SHARED_LEDGER = json.loads((ROOT / "game/assets/campaign_policies/item_shared_ledger.json").read_text(encoding="utf-8"))
RUNTIME_ITEM_BINDINGS = {
    row['source_item_id']: row['controller']['tag'] for row in _SHARED_LEDGER['items']
    if row['controller']['kind'] == 'items_enum'
}
SHARED_KEY_ITEM_IDS = frozenset(
    row['source_item_id'] for row in _SHARED_LEDGER['items'] if row['ownership'] == 'shared_key'
)
_MENU_ROSTER = json.loads((ROOT / "game/assets/combat_systems/menu_lists.json").read_text(encoding="utf-8"))["roster"]
_PARTY_CATALOGUE = json.loads((ROOT / "game/assets/party_session/catalogue.json").read_text(encoding="utf-8"))["characters"]


def materializable_party_ids(battle_data) -> frozenset[str]:
    """Return playable character IDs valid under both party catalogue and battle profile rules."""
    if battle_data is None:
        return frozenset(PARTY_JOIN_NAMES.values())
    trial = battle_data[0]
    profs = {m["id"]: m for m in trial.get("party", [])}
    systems = trial.get("systems", {})
    runes_by_name = {r["name"]: r for r in systems.get("runes", [])}
    equip_by_id = {e["id"]: e for e in systems.get("equipment", [])}
    valid = set()
    for ch in _PARTY_CATALOGUE:
        cid = ch["id"]
        if cid not in profs:
            continue
        prof = profs[cid]
        seed = ch["seed"]
        weapon = prof.get("weapon")
        if weapon is None or len(weapon.get("names", [])) != 16 or not all(bool(name) for name in weapon["names"]):
            continue
        if any(actual is not None and expected != actual for expected, actual in zip(weapon["names"], seed["weapon"]["names"])):
            continue
        rune_name = seed.get("rune_name")
        if rune_name and not seed.get("rune_unresolved"):
            rdef = runes_by_name.get(rune_name)
            if rdef is None:
                continue
            orig = prof.get("rune") == rdef["id"]
            if prof.get("rune_locked") and not orig:
                continue
            if not orig and rdef.get("allowed_members") is not None and cid not in rdef["allowed_members"]:
                continue
        if any(
            (edef := equip_by_id.get(it["id"])) is None
            or (edef.get("allowed_members") is not None and cid not in edef["allowed_members"])
            for it in seed.get("inventory", []) if it.get("slot")
        ):
            continue
        valid.add(cid)
    return frozenset(valid)

def cross_area_room(filename, area_index, room_number, file_slots):
    regions = {slot['region'] for slot in file_slots if slot.get('file', '').endswith(filename)}
    targets = {slot.get('file') for slot in file_slots
               if slot['region'] in regions and slot['index'] == area_index}
    if len(targets) != 1 or None in targets:
        return None
    stem = next(iter(targets)).rsplit('/', 1)[-1].removesuffix('.BIN').lower()
    if stem == 'vb9' and room_number == 1:
        # shortcut: share the existing cinematic room while both rooms use identical event records.
        data, _ = source('/VB9.BIN')
        records = []
        for index in (0, 1):
            room = scene.room_record(data, index)
            start = room['entity_off']
            records.append(data[start:start + room['entity_count'] * scene.ENTITY_STRIDE])
        if not records[0] or records[0] != records[1]:
            raise ValueError('Lake Toran cinematic room variants no longer share event records')
        room_number = 0
    return f'{stem}_room_{room_number}'


def explicit_world_target(operands, world_regions, grids):
    if len(operands) == 4 and operands[0] == 251:
        region, camera_x, camera_y = operands[1:]
    else:
        raise ValueError('expected an explicit world return')
    destination = world_regions.get(region)
    grid = grids.get((destination, 0))
    if grid is None:
        return None
    # Source foot anchor (160,128) uses 16-pixel tiles; exported field cells use 8 pixels.
    x, y = (camera_x + 10) * 8, (camera_y + 8) * 8
    width, height, _ = grid
    if not (0 <= x < width * 8 and 0 <= y < height * 8):
        return None
    return destination, (x, y)


def retained_world_return(operands, world_regions, grids, filename, file_slots):
    if len(operands) != 3 or operands[0] != 254:
        raise ValueError('expected a retained-region world return')
    worlds = {world_regions[slot['region']] for slot in file_slots
              if slot.get('file', '').endswith(filename) and slot['region'] in world_regions
              and (world_regions[slot['region']], 0) in grids}
    x, y = operands[1] + 10, operands[2] + 8
    if not worlds or any(not (x < grids[(world, 0)][0] and y < grids[(world, 0)][1]) for world in worlds):
        return None
    return dict(kind='world_transition', retain_world_region=True, x=x, y=y)


SPEAKER_NAMES = {
    3: "Camille",
    32: "Tai Ho",
    38: "Yam Koo",
    1: "Cleo",
    2: "Gremio",
    4: "Kirkis",
    6: "Pahn",
    9: "Sylvina",
    10: "Sonya",
    12: "Varkas",
    14: "Kuromimi",
    16: "Kasim",
    19: "Futch",
    26: "Luc",
    27: "Mathiu",
    28: "Milich",
    31: "Sydonia",
    35: "Viktor",
    40: "Kessler",
    78: "Ledon",
    36: "Valeria",
    46: "Marie",
    70: "Maas",
    75: "Stallion",
    97: "Viki",
    103: "Marco",
    105: "Chandler",
    108: "Ted",
    17: "Flik",
    115: "Sanchez",
    109: "Odessa",
    110: "Teo",
    111: "Barbarosa",
    112: "Windy",
    113: "Kraze",
    114: "Kanaan",
    116: "Grady",
    117: "Ain Gide",
    118: "Leknaat",
    120: "Soldier",
    124: "Soldier",
    125: "Soldier",
}

PARTY_JOIN_NAMES = {row["source_character_id"]: row["id"] for row in _MENU_ROSTER}

# VA4 R10 e10 0x1F slot table (VA4 0x800478f0 / section+0x20 order): [1,3,2,0] -> gremio, pahn, cleo, ted.
VA4_R10_REJOIN_SLOTS = {
    0: "ted",
    1: "gremio",
    2: "cleo",
    3: "pahn",
}

RUNE_GRANTS = {
    ("/VA1.BIN", 1, 8, 14): ("hero", "soul_eater"),
}

# Initial / dynamic placement overrides proven by room initializers / anchor counterparts.
PLACEMENT_OVERRIDES = {
    # shortcut: Sarady's night placements until scene actor tracks are bound.
    ("/VA5.BIN", 1, 6): (280, 280),
    ("/VA5.BIN", 1, 8): (344, 232),
    ("/VA5.BIN", 1, 9): (344, 152),
    ("/VA5.BIN", 1, 10): (280, 152),
    # shortcut: static post-tea setup (0x22E17..0x22E5B) until NPC tracks are bound.
    ("/VA8.BIN", 10, 7): (40, 88),
    ("/VA8.BIN", 10, 8): (136, 88),
    ("/VA8.BIN", 10, 9): (136, 168),
    ("/VA8.BIN", 10, 10): (40, 168),
    ("/VA8.BIN", 10, 11): (248, 176),
    ("/VA8.BIN", 10, 12): (288, 176),
}

# South-facing exits whose trigger starts beyond the walkable floor.
SOUTH_EXIT_APPROACH = {
    ("/VAA.BIN", 7, 0): 72,
    ("/VAA.BIN", 8, 0): 162,
    ("/VB3.BIN", 5, 0): 42,
}

# All previously forced-source-only entities are admitted to the shared compiler.
FORCE_SOURCE_ONLY: set[tuple[str, int, int]] = set()

def sha256_canonical(obj: object) -> str:
    payload = (json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def story_id(index: int) -> str:
    return f"scenario_{index:04d}"


def _decode_nested_field_text(raw_bytes: bytes, offset: int) -> list[dict]:
    """Decode a text stream allowing control 0x06 (castle name) and 0x07 (2-byte formatted number)."""
    tokens: list[dict] = []
    pos = offset
    for _ in range(4096):
        code = raw_bytes[pos]
        pos += 1
        if code == 0:
            return tokens
        if code in (1, 3):
            tokens.append({"kind": "newline"})
        elif code == 2:
            tokens.append({"kind": "page"})
        elif code in (4, 5):
            tokens.append({"kind": {4: "pace", 5: "countdown"}[code], "value": raw_bytes[pos]})
            pos += 1
        elif code == 6:
            arg = raw_bytes[pos]
            pos += 1
            if arg == 0:
                tokens.append({"kind": "player_name"})
            elif arg == 1:
                tokens.append({"kind": "glyph", "text": "Toran"})
            else:
                raise ValueError("unsupported audience nested string")
        elif code == 7:
            arg0 = raw_bytes[pos]
            _arg1 = raw_bytes[pos + 1]
            pos += 2
            tokens.append({"kind": "glyph", "text": " ? " if arg0 == 0 else "?"})
        elif code in opening_audience.war_text.SUBST:
            tokens.append({"kind": "glyph", "text": opening_audience.war_text.SUBST[code]})
        else:
            raise ValueError(f"unsupported audience text control {code}")
    raise ValueError("unterminated audience text")


def decode_text_tokens(raw_bytes: bytes, offset: int, strip_for_choice: bool = False) -> list[dict]:
    """Decode raw Suikoden dialogue string at offset into runtime Token dicts."""
    tokens: list[dict] = []
    try:
        source_tokens, _ = opening_audience.text(raw_bytes, offset)
    except ValueError as exc:
        if str(exc) not in ("unsupported audience nested string", "unsupported audience text control 7"):
            raise
        source_tokens = _decode_nested_field_text(raw_bytes, offset)
    for token in source_tokens:
        if token["kind"] == "glyph":
            tokens.extend({"kind": "glyph", "text": ch} for ch in token["text"])
        elif token["kind"] != "page" or not strip_for_choice:
            tokens.append(token)
    while tokens and tokens[0]["kind"] == "newline":
        tokens.pop(0)
    while tokens and tokens[-1]["kind"] == "newline":
        tokens.pop()
    return tokens


def tokens_to_str_preview(tokens: list[dict]) -> str:
    parts = []
    for t in tokens:
        k = t["kind"]
        if k == "glyph":
            parts.append(t["text"])
        elif k == "newline":
            parts.append("\n")
        elif k == "page":
            parts.append("\f")
        elif k == "player_name":
            parts.append("{PLAYER}")
    return "".join(parts)


def make_speaker_tokens(name: str) -> list[dict]:
    return [{"kind": "glyph", "text": c} for c in name]


def normalize_choice_tokens(raw_groups: list[list[dict]], expected_options: int, is_inn: bool = False) -> list[dict]:
    """Merge 1..3 PS1 option strings into exactly `expected_options` newline-separated non-empty lines."""
    options_lines: list[list[dict]] = []
    if len(raw_groups) == 1:
        cur: list[dict] = []
        for t in raw_groups[0]:
            if t["kind"] == "newline":
                if cur:
                    options_lines.append(cur)
                    cur = []
            elif t["kind"] == "page":
                continue
            else:
                cur.append(t)
        if cur:
            options_lines.append(cur)
        if len(options_lines) > expected_options:
            merged_lines: list[list[dict]] = []
            for idx, line in enumerate(options_lines):
                if (merged_lines and merged_lines[-1][-1] == {"kind": "glyph", "text": " "}
                        and len(merged_lines) + (len(options_lines) - idx) > expected_options):
                    merged_lines[-1].extend(line)
                else:
                    merged_lines.append(line)
            options_lines = merged_lines
    else:
        for grp in raw_groups:
            cur = []
            for t in grp:
                if t["kind"] == "newline":
                    if cur and cur[-1] != {"kind": "glyph", "text": " "}:
                        cur.append({"kind": "glyph", "text": " "})
                elif t["kind"] == "page":
                    continue
                else:
                    cur.append(t)
            while cur and cur[-1] == {"kind": "glyph", "text": " "}:
                cur.pop()
            if cur:
                options_lines.append(cur)
    if is_inn and len(options_lines) == 3:
        options_lines = options_lines[:2]
    assert len(options_lines) == expected_options, (
        f"Expected {expected_options} choice rows, got {len(options_lines)}: "
        f"{[tokens_to_str_preview(o) for o in options_lines]}"
    )
    out: list[dict] = []
    for idx, line in enumerate(options_lines):
        if idx > 0:
            out.append({"kind": "newline"})
        out.extend(line)
    return out


def nearest_walkable(grid: tuple[int, int, str], x: int, y: int) -> tuple[int, int]:
    w, h, g = grid
    hx, hy = x // 8, y // 8
    if 0 <= hx < w and 0 <= hy < h and g[hy * w + hx] == "1":
        return x, y
    best = None
    for yy in range(h):
        for xx in range(w):
            if g[yy * w + xx] == "1":
                d = abs(xx - hx) + abs(yy - hy)
                if best is None or d < best[0]:
                    best = (d, xx * 8, yy * 8)
    assert best is not None
    return best[1], best[2]


def outside_box_walkable(grid: tuple[int, int, str], xs: list[int], ys: list[int]) -> tuple[int, int] | None:
    """Find a walkable half-cell immediately outside the coordinate_range box for safe align_hero."""
    if not xs and not ys:
        return None
    w, h, g = grid
    x0, x1 = (xs[0], xs[1]) if xs else (0, w - 1)
    y0, y1 = (ys[0], ys[1]) if ys else (0, h - 1)
    # Seed BFS from walkable cells INSIDE the trigger box to pick a directly adjacent walkable cell OUTSIDE.
    inside = [(xx, yy) for yy in range(max(0, y0), min(h, y1 + 1)) for xx in range(max(0, x0), min(w, x1 + 1)) if g[yy * w + xx] == "1"]
    if not inside:
        return None
    seen = set(inside)
    q = deque(inside)
    while q:
        cx, cy = q.popleft()
        for dx, dy in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            nx, ny = cx + dx, cy + dy
            if not (0 <= nx < w and 0 <= ny < h):
                continue
            if g[ny * w + nx] != "1":
                continue
            if not (x0 <= nx <= x1 and y0 <= ny <= y1):
                return nx * 8, ny * 8
            if (nx, ny) not in seen:
                seen.add((nx, ny))
                q.append((nx, ny))
    return None


class RoomTextPool:
    """Per-room deduplicated text and portrait registry enforcing prefix vs body separation."""

    def __init__(self, room_id: str, art: dict):
        self.room_id = room_id
        self.art = art
        self.prefix_texts: list[dict] = []
        self.prefix_map: dict[str, int] = {}
        self.body_texts: list[dict] = []
        self.body_map: dict[str, int] = {}
        self.images: list[dict] = []
        self.image_map: dict[int, int] = {}

    def fork(self):
        trial = copy.copy(self)
        for name in ('prefix_texts', 'prefix_map', 'body_texts', 'body_map', 'images', 'image_map'):
            setattr(trial, name, getattr(self, name).copy())
        return trial

    def get_image(self, cid: int) -> int | None:
        key = str(cid)
        if key not in self.art["portraits"]:
            return None
        if cid not in self.image_map:
            p = self.art["portraits"][key]
            idx = len(self.images)
            self.images.append({
                "id": p["id"],
                "character": int(p["character"]),
                "width": int(p["width"]),
                "height": int(p["height"]),
                "plane_sha256": p["plane_sha256"],
                "palette_sha256": p["palette_sha256"],
                "domain": "room",
                "resource": None,
                "atlas_rect": dict(p["rect"]),
            })
            self.image_map[cid] = idx
        return self.image_map[cid]

    def get_speaker_text(self, name: str, *, source_tokens: list[dict] | None = None) -> str:
        if name not in self.prefix_map:
            idx = len(self.prefix_texts)
            tid = f"{self.room_id}_spk_{idx}"
            self.prefix_texts.append({"id": tid, "tokens": make_speaker_tokens(name) if source_tokens is None else source_tokens})
            self.prefix_map[name] = idx
        elif source_tokens is not None and self.prefix_texts[self.prefix_map[name]]["tokens"] != source_tokens:
            raise ValueError("speaker prefix has conflicting source tokens")
        return self.prefix_texts[self.prefix_map[name]]["id"]

    def get_body_text(self, tokens: list[dict]) -> str:
        sig = json.dumps(tokens, separators=(",", ":"))
        if sig not in self.body_map:
            idx = len(self.body_texts)
            tid = f"{self.room_id}_txt_{idx}"
            self.body_texts.append({"id": tid, "tokens": tokens})
            self.body_map[sig] = idx
        return self.body_texts[self.body_map[sig]]["id"]

    def finalized_texts_and_index(self) -> tuple[list[dict], dict[str, int]]:
        combined = self.prefix_texts + self.body_texts
        assert len(combined) <= 1024, f"{self.room_id} exceeded 1024 texts: {len(combined)}"
        index_of = {entry["id"]: idx for idx, entry in enumerate(combined)}
        return combined, index_of


def normalize_event_predicate(ev: dict, ev_dbg: dict) -> dict:
    """Lower supported source selection operands without discarding unsupported terms."""
    out_terms = []
    unsup_iter = iter(t for t in ev_dbg["terms"] if t["kind"] == "unsupported")
    for t in ev["terms"]:
        if t["kind"] != "unsupported":
            out_terms.append(t)
            continue
        raw_term = next(unsup_iter)
        op = raw_term["opcode"]
        if op in (0x01, 0x02):
            first, last = raw_term["operands"]
            lo, hi = first + 1, last - 1
            if lo <= hi:
                out_terms.append({
                    "kind": "coordinate_range",
                    "coordinate": {"axis": "x" if op == 0x01 else "y", "first": lo, "last": hi},
                })
                continue
        elif op == 0x04:
            index = raw_term['operands'][0]
            if index < len(PAD_DIRECTION_MASKS):
                out_terms.append({'kind': 'pressed_mask', 'index': index, 'mask': PAD_DIRECTION_MASKS[index]})
                continue
        elif op in (0x09, 0x0A):
            index, mask = raw_term['operands']
            if index < 20 and mask:
                out_terms.append({'kind': 'room_mask_set' if op == 0x09 else 'room_mask_clear',
                                  'index': index, 'mask': mask})
                continue
        elif op == 0x0D:
            out_terms.append({'kind': 'money_at_least', 'amount': raw_term['operands'][0] * 100})
            continue
        elif op == 0x0E:
            character = raw_term['operands'][0]
            if character:
                out_terms.append({'kind': 'party_contains', 'character_id': character})
                continue
        elif op in (0x10, 0x11, 0x19):
            slot = raw_term['operands'][0]
            if slot < 108:
                kind = {0x10: 'recruit_present', 0x11: 'recruit_absent', 0x19: 'recruit_ever'}[op]
                out_terms.append({'kind': kind, 'slot': slot})
                continue
        elif op == 0x13:
            character, level = raw_term['operands']
            out_terms.append({'kind': 'level_at_least', 'character_id': character, 'level': level})
            continue
        elif op == 0x14:
            stage = raw_term['operands'][1]
            if stage < 5:
                out_terms.append({'kind': 'stage_at_least', 'stage': stage})
                continue
        elif op == 0x16 and raw_term['operands'][0] <= 108:
            out_terms.append({'kind': 'recruit_count_at_least', 'count': raw_term['operands'][0]})
            continue
        elif op in (0x17, 0x18):
            out_terms.append({'kind': 'has_item', 'item_id': raw_term['operands'][0], 'require_key': op == 0x18})
            continue
        elif op == 0x0F:
            out_terms.append({"kind": "party_absent", "index": raw_term["operands"][0]})
            continue
        out_terms.append(t)
    return {"pointer_state": ev["pointer_state"], "terms": out_terms}


def event_selection_term(term):
    kind = term['kind']
    if kind == 'coordinate_range':
        coordinate = term['coordinate']
        return {'kind': 'hero_x_inclusive' if coordinate['axis'] == 'x' else 'hero_y_inclusive',
                'min': coordinate['first'], 'max': coordinate['last']}
    if kind == 'pressed_mask':
        return {'kind': kind, 'mask': term['mask']}
    if kind == 'party_absent':
        return dict(term) if term['index'] != 0 else None
    if kind in ('room_mask_set', 'room_mask_clear', 'money_at_least'):
        return dict(term)
    if kind == 'party_contains':
        return {'kind': kind, 'index': term['character_id']}
    if kind in ('party_count_equals', 'recruit_count_at_least'):
        return {'kind': kind, 'index': term['count']}
    if kind in ('recruit_present', 'recruit_absent', 'recruit_ever'):
        return {'kind': kind, 'index': term['slot']}
    if kind == 'has_item':
        return {'kind': kind, 'index': term['item_id'], 'require_key': term['require_key']}
    if kind == 'level_at_least':
        return {'kind': kind, 'index': term['character_id'], 'min': term['level']}
    if kind == 'stage_at_least':
        return {'kind': kind, 'min': term['stage']}
    return None


def resolve_selection_and_conditions(fname: str, rn: int, ent_idx: int, e: dict, cl: dict, ev: dict, hw: int, hh: int) -> tuple[list[dict], list[dict], list[dict], str]:
    """Split entity terms into program.conditions (story), program.selection (coord/room), and entity classification."""
    # Base coordinates
    if (fname, rn, ent_idx) in PLACEMENT_OVERRIDES:
        px, py = PLACEMENT_OVERRIDES[(fname, rn, ent_idx)]
    else:
        px, py = e["x_half"] * 8, e["y_half"] * 8
    placed = 0 < px < hw * 8 and 0 < py < hh * 8

    # Extract story terms and coord terms from ev
    story_terms: list[dict] = []
    coord_terms: list[dict] = []
    party_absent_terms: list[int] = []
    other_selection_terms: list[dict] = []
    is_interaction = False
    for t in ev["terms"]:
        k = t["kind"]
        if k == "interaction":
            is_interaction = True
        elif k in ("story_mask_set", "story_mask_clear"):
            story_terms.append(t)
        elif k == "party_absent":
            party_absent_terms.append(t["index"])
        elif k in ('pressed_mask', 'room_mask_set', 'room_mask_clear', 'money_at_least', 'party_contains', 'party_count_equals',
                   'recruit_present', 'recruit_absent', 'recruit_ever', 'recruit_count_at_least', 'stage_at_least', 'level_at_least'):
            other_selection_terms.append(event_selection_term(t))
        elif k == 'has_item':
            other_selection_terms.append(event_selection_term(t))
        elif k == "coordinate_range":
            coord_terms.append(t["coordinate"])

    selection_terms: list[dict] = []
    for c in coord_terms:
        kind = "hero_x_inclusive" if c["axis"] == "x" else "hero_y_inclusive"
        selection_terms.append({"kind": kind, "min": c["first"], "max": c["last"]})
    for idx in party_absent_terms:
        selection_terms.append({"kind": "party_absent", "index": idx})
    selection_terms.extend(other_selection_terms)

    # Convert story_terms to runtime Condition list
    prog_conditions = [{"kind": t["kind"], "flag": t["flag"]} for t in story_terms]

    # Mutual exclusions from disc entity order where sprites or variants overlap
    extra_conds: list[dict] = []
    if (fname, rn, ent_idx) == ("/VA3.BIN", 1, 7):
        extra_conds.append({"kind": "story_mask_clear", "flag": {"id": story_id(7), "mask": 128}})
    elif (fname, rn, ent_idx) == ("/VAA.BIN", 0, 14):
        pass
    elif (fname, rn, ent_idx) == ("/VAA.BIN", 0, 9):
        # Futch e09 (1&64 & !(1&128) & !(2&64))
        extra_conds.append({"kind": "story_mask_clear", "flag": {"id": story_id(2), "mask": 64}})
    elif (fname, rn, ent_idx) == ("/VAA.BIN", 0, 12):
        # Default Futch before/other stages (when e09, e10, e11 aren't active)
        extra_conds.append({"kind": "story_mask_clear", "flag": {"id": story_id(1), "mask": 64}})
    elif (fname, rn, ent_idx) == ("/VA1.BIN", 3, 11):
        # Patron at (48, 136) before Viktor arrives (5&128)
        extra_conds.append({"kind": "story_mask_clear", "flag": {"id": story_id(5), "mask": 128}})
    prog_conditions.extend(extra_conds)
    if fname == "/VA5.BIN" and rn == 1 and ent_idx == 7:
        prog_conditions.extend([
            {"kind": "story_mask_set", "flag": {"id": story_id(9), "mask": 4}},
            {"kind": "story_mask_clear", "flag": {"id": story_id(9), "mask": 8}},
        ])
    if fname == "/VA8.BIN" and rn == 10 and 7 <= ent_idx <= 12:
        prog_conditions.extend([
            {"kind": "story_mask_set", "flag": {"id": story_id(8), "mask": 8}},
            {"kind": "story_mask_clear", "flag": {"id": story_id(8), "mask": 64}},
        ])

    # classification terms (character visibility & eligibility): only story_mask_set / story_mask_clear
    cl_terms = [{"kind": t["kind"], "flag": t["flag"]} for t in cl["terms"] if t["kind"] in ("story_mask_set", "story_mask_clear")]
    if (fname, rn) == ("/VB5A2.BIN", 0) or fname == "/VB3.BIN":
        cl_terms = list(cl['terms'])
    if fname == "/VB1.BIN" and rn == 0 and ent_idx in (13, 14):
        inherited = {"kind": "story_mask_clear", "flag": {"id": story_id(10), "mask": 32}}
        cl_terms = [inherited]
        if inherited not in prog_conditions:
            prog_conditions.append(inherited)
    if fname == "/VA5.BIN" and rn == 1 and 6 <= ent_idx <= 10:
        cl_terms.extend(prog_conditions)
        cl_terms.extend([
            {"kind": "story_mask_set", "flag": {"id": story_id(9), "mask": 2}},
            {"kind": "story_mask_clear", "flag": {"id": story_id(9), "mask": 16}},
        ])
    if fname == "/VA8.BIN" and rn == 10 and 7 <= ent_idx <= 12:
        cl_terms.extend(prog_conditions)
    # Synchronize cl_terms with prog_conditions on runtime-placed variants/characters where needed
    if not cl_terms and prog_conditions and placed and is_interaction and fname != "/VB3.BIN":
        cl_terms = list(prog_conditions)
    if (fname, rn) == ("/VB1.BIN", 5) and ent_idx in (3, 4, 5):
        cl_terms = []  # Child 3 owns the always-visible actor; 4/5 are dialogue variants.
    if (fname, rn) == ("/VB1.BIN", 5) and ent_idx in (15, 16):
        cl_terms = [{"kind": "story_mask_set", "flag": {"id": story_id(10), "mask": 32}},
                    {"kind": "story_mask_clear", "flag": {"id": story_id(12), "mask": 128}}]

    trigger = "interaction" if is_interaction else ("initialization" if (e["flags"] & 0x10) else "ordinary")
    return prog_conditions, selection_terms, cl_terms, trigger


def compile_dock_arrival(data, room_id, prog_id, pool, conditions, selection, trigger):
    """Lower each source dock opcode once, retaining its asynchronous waits."""
    import maindec
    from export_scripted_travel import outputs, dock_rows
    report, _ = outputs()
    dock = report["dock_arrival"]
    if trigger != "ordinary" or hashlib.sha256(data).hexdigest() != dock["source"]["sha256"]:
        raise ValueError("unsupported dock arrival context")
    rows = dock_rows(data)
    if rows[-1][0] + 1 != dock["stream_end"] or data[dock["stream_start"]:dock["stream_end"]] != bytes.fromhex(dock["stream_bytes"]):
        raise ValueError("dock arrival stream not fully consumed")
    ordinary = {0: f"{room_id}_actor_02_032", 1: f"{room_id}_actor_03_038"}
    def actor(selector):
        if selector == 0x80:
            return "hero"
        if 0x40 <= selector <= 0x43:
            return f"party_follower_{selector & 63}"
        if selector not in ordinary:
            raise ValueError("unbound dock actor selector")
        return ordinary[selector]
    speeches = {speech["source_offset"]: speech for speech in dock["dialogues"]}
    placements = {entry["offset"]: entry["command"] for entry in dock["placements"]}
    tracks = {entry["offset"]: ("vb5_room_0_arrival_cleo_track" if entry["selector"] == 0x41
                               else f"vb5_room_0_arrival_track_{entry['offset']:04x}") for entry in dock["tracks"]}
    commands, anchors, prefixes = [], [], []
    for offset, opcode, args, _ in rows:
        command_index = len(commands)
        if opcode == 9:
            command = {"kind": "story_or", "flag": {"id": story_id(args[0]), "mask": args[1]}}
        elif opcode == 0x10:
            command = {"kind": "align_hero", "x": args[0] * 8, "y": args[1] * 8,
                       "wait": {"kind": "alignment", "id": "alignment"}}
        elif opcode == 0x3b:
            command = {"kind": "request_area_party_prefix", "requested_prefix": list(args[1:]), "scope": "area_transient"}
        elif opcode in (0x36, 0x37, 0x38, 0x33, 0x46, 2):
            command = {"kind": {0x36: "queue_glyphs_a", 0x37: "queue_glyphs_b", 0x38: "wait_text_queue_drain_and_release",
                                0x33: "wait_tracks", 0x46: "wait_event_flags_low2", 2: "wait_for_accept"}[opcode]}
        elif opcode == 7:
            command = dict(placements[offset])
        elif opcode == 0x32:
            command = {"kind": "queue_track", "track": tracks[offset]}
        elif opcode == 0x11:
            if args[1] > 3:
                raise ValueError("unsupported dock direction")
            command = {"kind": "actor_transition", "actor": actor(args[0]), "transition": maindec.mword(0x80171b98 + args[1] * 4)}
        elif opcode in (0x0b, 0x17):
            box = 0 if opcode == 0x0b else 1
            target = actor(args[0])
            command = {"kind": "open_box", "box": box, "actor": target, "requires": {"kind": "box_closed", "id": f"box_{box}"}}
            anchor = {"program": prog_id, "command": command_index, "box": box}
            if target.startswith("party_follower_"):
                anchor["follower"] = args[0] & 63
            else:
                anchor["actor"] = target
            anchors.append(anchor)
        elif opcode == 0x12:
            speech = speeches[offset + 3]
            if (speech["box"], speech["character"]) != tuple(args):
                raise ValueError("dock prefix/speech pairing changed")
            box = args[0]
            text = pool.get_speaker_text(speech["speaker_name"], source_tokens=speech["prefix_tokens"])
            image = pool.get_image(speech["character"])
            if image is None:
                raise ValueError("dock portrait missing")
            command = {"kind": "start_or_wait_dialogue", "box": box, "code": args[1], "wait": {"kind": "speaker_prefix", "id": f"box_{box}"}}
            prefixes.append({"program": prog_id, "command": command_index, "box": box, "_text_id": text, "image": image})
        elif opcode == 0x1c:
            text = pool.get_body_text(speeches[offset]["tokens"])
            command = {"kind": "text", "box": args[0], "text": text, "wait": {"kind": "text", "id": text}}
        elif opcode in (1, 0x0c, 0x18):
            command = {"kind": "close_box", "box": args[0] if opcode == 1 else 0 if opcode == 0x0c else 1}
        elif opcode == 0x0a:
            command = {"kind": "delay", "updates": args[0] * 5, "wait": {"kind": "delay", "id": "delay"}}
        elif opcode in (0x3a, 0x41, 0):
            command = dict(dock[{0x3a: "release", 0x41: "audio", 0: "fixed_box"}[opcode]]["command"])
        elif opcode in (0x1f, 0x4b):
            command = dict(dock["roster_tail"]["commands"][0 if opcode == 0x1f else 1])
        elif opcode == 0xfd:
            command = {"kind": "end_stream", "requires": {"kind": "event_flags_low2", "id": "dialogue_flags"}}
        else:
            raise ValueError(f"unlowered dock opcode {opcode:#x}")
        commands.append(command)
    if len(commands) != len(rows) or len(anchors) != 6 or len(prefixes) != 7:
        raise ValueError("dock command/anchor/prefix inventory changed")
    return {"id": prog_id, "entry": "ordinary", "entity": 2, "trigger": "none", "conditions": conditions,
            "selection": selection, "commands": commands}, anchors, prefixes


def compile_kouan_start(data, rn, entity, room_id, prog_id, pool, conditions, selection, trigger, room_tracks):
    if rn == 28 and entity in (0, 1, 5):
        from export_scripted_travel import kouan_wheel
        wheel = kouan_wheel()
        if entity == 5:
            commands = [{'kind': 'story_or', 'flag': {'id': 'scenario_0044', 'mask': 1}}, {'kind': 'end_stream'}]
        else:
            door = next(d for d in wheel['doors'] if (d['room'], d['entity']) == (rn, entity))
            commands = [{'kind': 'field_music', 'music': 'stop'}, {'kind': 'field_music', 'music': 'mansion'},
                        {'kind': 'room_transition', 'destination': f"vb3_room_{door['destination']}",
                         'x': door['spawn_pixels'][0], 'y': door['spawn_pixels'][1]}]
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': entity, 'trigger': 'none',
                 'conditions': conditions, 'selection': selection, 'commands': commands}, [], [])
    if rn == 28 and entity in (2, 4):
        return compile_wheel_spin(data, entity, prog_id, pool, conditions, selection, trigger, room_tracks)
    if (rn, entity) == (28, 3):
        return compile_wheel_return(data, prog_id, conditions, selection, trigger, room_tracks)
    from export_scripted_travel import kouan_entry
    from export_scripted_travel import kouan_juppo
    juppo = kouan_juppo()
    if (rn, entity) == (20, 8):
        return compile_headquarters_scene(data, room_id, prog_id, pool, conditions, selection, trigger, room_tracks, juppo)
    door = next((row for row in juppo['doors'] if (row['room'], row['entity']) == (rn, entity)), None)
    if door is not None:
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': entity, 'trigger': 'none',
                 'conditions': conditions, 'selection': selection, 'commands': [door['command']]}, [], [])
    from export_scripted_travel import kouan_ladder
    ladder = kouan_ladder()
    row = next((row for row in ladder['entries'] if (row['room'], row['entity']) == (rn, entity)), None)
    if row is not None:
        commands = []
        for instruction in row['instructions']:
            pc, op, args = instruction['offset'], instruction['opcode'], instruction['operands']
            if op == 3:
                target, x, y = args
                commands.append({'kind': 'room_transition', 'destination': f'vb3_room_{target}', 'x': x * 8, 'y': y * 8})
            elif op == 0x42:
                if args != [25]: raise ValueError('unsupported ladder dispatch')
                commands.append(ladder['toggle']['command'])
            elif op == 0x32:
                track = next(row for row in ladder['choreography']['tracks'] if row['offset'] == pc)
                track_id = f'{room_id}_ladder_{entity}'
                room_tracks.append({'id': track_id, 'actor': 'hero', 'commands': track['commands']})
                commands.append({'kind': 'queue_track', 'track': track_id})
            elif op == 0x33:
                commands.append({'kind': 'wait_tracks'})
            elif op == 0x3e:
                if args != [0]: raise ValueError('unsupported ladder scenery')
                commands.append({'kind': 'show_prop', 'prop': 0})
            elif op in (0x30, 0x31):
                commands.append({'kind': 'continue_tick' if op == 0x30 else 'yield_tick'})
            elif op == 0xfd:
                if commands[-1]['kind'] != 'room_transition': commands.append({'kind': 'end_stream'})
            else:
                raise ValueError('unlowered ladder instruction')
        for mask in row['pressed_masks']:
            term = {'kind': 'pressed_mask', 'mask': mask}
            if term not in selection:
                selection = [*selection, term]
        return ({'id': prog_id, 'entry': 'initialization' if row['initialization'] else 'ordinary',
                 'entity': entity, 'trigger': 'none', 'conditions': conditions, 'selection': selection, 'commands': commands}, [], [])
    if rn == 2 and entity in (4, 5):
        return compile_krin_plan(data, entity, room_id, prog_id, pool, conditions, selection, trigger, room_tracks)
    if (rn, entity) == (0, 15):
        from export_scripted_travel import kouan_mansion_approach
        return compile_headquarters_scene(data, room_id, prog_id, pool, conditions, selection, trigger, room_tracks, kouan_mansion_approach())
    from export_scripted_travel import kouan_mansion_doors
    door = next((row for row in kouan_mansion_doors()['doors'] if (row['room'], row['entity']) == (rn, entity)), None)
    if door is not None:
        if door['pressed_mask'] is not None:
            selection = [*selection, {'kind': 'pressed_mask', 'mask': door['pressed_mask']}]
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': entity, 'trigger': 'none',
                 'conditions': conditions, 'selection': selection, 'commands': door['commands']}, [], [])
    if (rn, entity) == (0, 12):
        from export_scripted_travel import kouan_giovanni
        return compile_headquarters_scene(data, room_id, prog_id, pool, conditions, selection, trigger, room_tracks, kouan_giovanni())
    original = kouan_entry()
    if not any(row['room'] == rn and row['entity'] == entity for row in original['streams']):
        return None
    if (rn, entity) == (0, 1):
        # shortcut: the door's source prop animation/cue still needs binding before presentation acceptance.
        commands = [{'kind': 'actor_transition', 'actor': 'hero', 'transition': 1},
                    {'kind': 'delay', 'updates': 10, 'wait': {'kind': 'delay', 'id': 'delay'}},
                    {'kind': 'room_transition', 'destination': 'vb3_room_2', 'x': 248, 'y': 208}]
        selection = [*selection, {'kind': 'pressed_mask', 'mask': 0x1000}]
    elif (rn, entity) == (0, 6):
        commands = [{'kind': 'story_or', 'flag': {'id': story_id(39), 'mask': 4}},
                    {'kind': 'story_or', 'flag': {'id': story_id(47), 'mask': 128}},
                    {'kind': 'room_transition', 'destination': 'world_b', 'x': 592, 'y': 560}]
    elif (rn, entity) == (2, 0):
        commands = [{'kind': 'room_transition', 'destination': 'vb3_room_0', 'x': 368, 'y': 520}]
    else:
        actor = 'vb3_room_2_actor_03_015'
        if 'vb3_room_2_character_015' not in pool.art.get('actor_clips', {}):
            raise ValueError('Krin greeting requires verified field clips')
        image = pool.get_image(15)
        if image is None: raise ValueError('Krin greeting portrait missing')
        prefix = pool.get_speaker_text('Krin', source_tokens=original['krin']['speech']['prefix_tokens'])
        text = pool.get_body_text(original['krin']['dialogue']['tokens'])
        commands = [{'kind': 'open_box', 'box': 0, 'actor': actor, 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
                    {'kind': 'start_or_wait_dialogue', 'box': 0, 'code': 15, 'wait': {'kind': 'speaker_prefix', 'id': 'box_0'}},
                    {'kind': 'text', 'box': 0, 'text': text, 'wait': {'kind': 'text', 'id': text}},
                    {'kind': 'wait_for_accept'}, {'kind': 'close_box', 'box': 0}, {'kind': 'end_stream'}]
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': entity, 'trigger': 'interaction',
                 'conditions': conditions, 'selection': selection, 'commands': commands},
                [{'program': prog_id, 'command': 0, 'box': 0, 'actor': actor}],
                [{'program': prog_id, 'command': 1, 'box': 0, '_text_id': prefix, 'image': image}])
    return {'id': prog_id, 'entry': 'ordinary', 'entity': entity, 'trigger': 'none', 'conditions': conditions,
            'selection': selection, 'commands': commands}, [], []


def compile_krin_plan(data, entity, room_id, prog_id, pool, conditions, selection, trigger, room_tracks):
    from export_scripted_travel import krin_plan
    proof = krin_plan()
    original = next(row for row in proof['variants'] if row['entity'] == entity)
    if trigger != 'interaction' or hashlib.sha256(data).hexdigest() != proof['source']['sha256']:
        raise ValueError('unsupported Krin plan context')
    actor_ids = {2: proof['inherited_actor']['id'], 128: 'hero',
                 **{row['selector']: row['actor'] for row in original['scene_actors']}}
    speeches = {row['source_offset']: row for row in original['choreography']['dialogues']}
    speeches[original['refusal']['dialogue']['source_offset']] = original['refusal']['dialogue']
    transitions = {row['offset']: row['command'] for row in original['choreography']['facing']}
    tracks = {}
    for row in original['choreography']['tracks']:
        track_id = f'{room_id}_krin_{entity}_track_{row["offset"]:05x}'
        tracks[row['offset']] = track_id
        room_tracks.append({'id': track_id, 'actor': row['actor'], 'commands': row['commands']})
    commands, anchors, prefixes = [], [], []
    choice_rows = [row for row in original['choreography']['dialogues'] if row['index'] in (6, 8)]
    choice_tokens = normalize_choice_tokens([row['tokens'] for row in choice_rows], 2)
    def lower(rows):
        i = 0
        while i < len(rows):
            row = rows[i]
            pc, op, args = row['offset'], row['opcode'], row['operands']
            i += 1
            if op in (0xfc, 0xfe):
                continue
            if op in (0x0b, 0x17):
                box = 0 if op == 0x0b else 1
                actor = actor_ids[args[0]]
                anchors.append({'program': prog_id, 'command': len(commands), 'box': box, 'actor': actor})
                command = {'kind': 'open_box', 'box': box, 'actor': actor, 'requires': {'kind': 'box_closed', 'id': f'box_{box}'}}
            elif op == 0x12:
                speech = speeches[pc + 3]
                image = pool.get_image(args[1])
                if image is None: raise ValueError('Krin plan portrait missing')
                image_only = speech.get('image_only', False)
                prefix = None if image_only else pool.get_speaker_text(speech['speaker_name'], source_tokens=speech['prefix_tokens'])
                prefixes.append({'program': prog_id, 'command': len(commands), 'box': args[0], '_text_id': prefix, 'image': image})
                command = {'kind': 'start_or_wait_dialogue', 'box': args[0], 'code': args[1]}
                if not image_only: command['wait'] = {'kind': 'speaker_prefix', 'id': f'box_{args[0]}'}
            elif op == 0x1c:
                speech = speeches[pc]
                if speech['index'] == 8:
                    continue
                tokens = choice_tokens if speech['index'] == 6 else speech['tokens']
                text = pool.get_body_text(tokens)
                command = {'kind': 'text', 'box': args[0], 'text': text, 'wait': {'kind': 'text', 'id': text}}
            elif op == 5:
                if args != [0, 2, 1]: raise ValueError('unsupported Krin choice')
                command = {'kind': 'choice', 'box': 1, 'options': 2}
            elif op in (0x0c, 0x18):
                command = {'kind': 'close_box', 'box': 0 if op == 0x0c else 1}
            elif op in (2, 0x46, 0x33):
                command = {'kind': {2: 'wait_for_accept', 0x46: 'wait_event_flags_low2', 0x33: 'wait_tracks'}[op]}
            elif op == 7:
                following = rows[i]
                if args[1] != 1 or following['opcode'] != 7 or following['operands'][:2] != [args[0], 2]:
                    raise ValueError('unsupported Krin atomic placement')
                i += 1
                command = {'kind': 'place_hero' if args[0] == 128 else 'place_actor',
                           'x': args[2] * 8, 'y': following['operands'][2] * 8}
                if args[0] != 128: command['actor'] = actor_ids[args[0]]
            elif op == 0x34:
                if args != [3, 2, 3, 6, 12, 1, 1, 6, 18, 35, 1, 9, 18]:
                    raise ValueError('unsupported Krin companion construction')
                commands.extend({'kind': 'spawn_actor', 'actor': actor_ids[selector]} for selector in (64, 65, 66))
                continue
            elif op == 0x39:
                commands.extend({'kind': 'release_actor', 'actor': actor_ids[selector]} for selector in (64, 65, 66))
                continue
            elif op == 0x3b:
                if args != [4, 8, 2, 1, 35]: raise ValueError('unsupported Krin area party order')
                command = {'kind': 'request_area_party_prefix', 'requested_prefix': args[1:], 'scope': 'area_transient'}
            elif op == 0x11:
                command = dict(transitions[pc])
            elif op == 0x32:
                command = {'kind': 'queue_track', 'track': tracks[pc]}
            elif op == 0x3a:
                command = {'kind': 'release_actor', 'actor': actor_ids[args[0]]}
            elif op == 0x26:
                if original['camera'] != {'pixels': [0, 8], 'entry_flags': 3, 'transition_flag_write': False}:
                    raise ValueError('unsupported Krin camera context')
                command = {'kind': 'set_camera', 'x': args[0] * 8, 'y': args[1] * 8}
            elif op == 0x24:
                command = {'kind': 'fade_out', 'blend_mode': 2, 'draw_slot': 10, 'wait': {'kind': 'fade', 'id': 'fade'}}
            elif op == 0x25:
                command = {'kind': 'fade_in', 'wait': {'kind': 'fade', 'id': 'fade'}}
            elif op == 0x0a:
                command = {'kind': 'delay', 'updates': args[0] * 5, 'wait': {'kind': 'delay', 'id': 'delay'}}
            elif op in (9, 0x29):
                command = {'kind': 'story_or' if op == 9 else 'story_andnot', 'flag': {'id': story_id(args[0]), 'mask': args[1]}}
            elif op == 0x41:
                if args != [100]: raise ValueError('unsupported Krin music request')
                command = {'kind': 'field_music', 'music': 'infiltration'}
            elif op == 0xfd:
                command = {'kind': 'end_stream'}
            else:
                raise ValueError(f'unlowered Krin instruction {op:#x} at {pc:#x}')
            commands.append(command)
    rows = original['instructions']
    split = next(i for i, row in enumerate(rows) if row['opcode'] == 0x2f)
    lower(rows[:split])
    branch = len(commands)
    commands.extend([{'kind': 'branch_choice', 'target': branch + 2}, {'kind': 'jump', 'target': 0}])
    # All actor mutations follow the conditional prefix, preserving linear snapshot ownership.
    lower(original['refusal']['instructions'])
    commands[branch + 1]['target'] = len(commands)
    lower(rows[split + 1:])
    expected = 130 if entity == 5 else 121
    if (len(commands), len(anchors), len(prefixes)) != (expected, 17, 17):
        raise ValueError(f'Krin command/anchor/prefix inventory changed: {len(commands)}/{len(anchors)}/{len(prefixes)}')
    return {'id': prog_id, 'entry': 'ordinary', 'entity': entity, 'trigger': 'interaction',
            'owner_actor': proof['inherited_actor']['id'], 'conditions': conditions, 'selection': selection, 'commands': commands}, anchors, prefixes


def compile_headquarters_departure(room_id, prog_id, pool, conditions, selection, trigger):
    from export_scripted_travel import hq_departure
    original = hq_departure()
    if trigger != 'ordinary':
        raise ValueError('unsupported headquarters departure trigger')
    image = pool.get_image(8)
    if image is None:
        raise ValueError('headquarters departure needs Hero portrait')
    text = pool.get_body_text(normalize_choice_tokens([original['choice']['tokens']], 2))
    commands = [
        {'kind': 'open_box', 'box': 1, 'actor': 'hero', 'requires': {'kind': 'box_closed', 'id': 'box_1'}},
        {'kind': 'start_or_wait_dialogue', 'box': 1, 'code': 8},
        {'kind': 'text', 'box': 1, 'text': text, 'wait': {'kind': 'text', 'id': text}},
        {'kind': 'choice', 'box': 1, 'options': 2},
        {'kind': 'close_box', 'box': 1},
        {'kind': 'wait_boxes'},
        {'kind': 'branch_choice', 'target': 8},
        {'kind': 'jump', 'target': 9},
        {'kind': 'end_stream'},
        {'kind': 'world_mode', 'code': original['board']['world_mode_operand']},
        {'kind': 'world_transition', 'destination': 'world_j',
         'x': original['board']['camera'][0], 'y': original['board']['camera'][1]},
    ]
    return ({'id': prog_id, 'entry': 'ordinary', 'entity': 1, 'trigger': 'none',
             'conditions': conditions, 'selection': [*selection, {'kind': 'pressed_mask', 'mask': original['trigger']['pressed_mask']}],
             'commands': commands},
            [{'program': prog_id, 'command': 0, 'box': 1, 'actor': 'hero'}],
            [{'program': prog_id, 'command': 1, 'box': 1, '_text_id': None, 'image': image}])


def compile_wheel_spin(data, entity, prog_id, pool, conditions, selection, trigger, room_tracks, sound_ids=None):
    from export_scripted_travel import kouan_wheel
    wheel = kouan_wheel()
    if trigger != 'ordinary' or hashlib.sha256(data).hexdigest() != wheel['source']['sha256']:
        raise ValueError('unsupported wheel spin context')
    variant = next(v for v in wheel['variants'] if v['entity'] == entity)
    proxy = variant['actor']['id']
    rows = variant['instructions']
    choreography = variant['choreography']
    pans = {r['offset']: r['command'] for r in choreography['pans']}
    facing = {r['offset']: r['command'] for r in choreography['facing']}
    speeches = {r['source_offset']: r['tokens'] for r in choreography['dialogues']}
    fixed = {r['offset']: r['command'] for r in variant['fixed_boxes']}
    audio = {r['offset']: r['command'] for r in variant['audio']}
    rewards = {r['source_item_id']: r for r in wheel['item_rewards']}
    tracks = {}
    for row in choreography['tracks']:
        track_id = f'vb3_room_28_spin_{entity}_track_{row["offset"]:05x}'
        tracks[row['offset']] = track_id
        room_tracks.append({'id': track_id, 'actor': proxy, 'commands': row['commands']})
    commands, anchors, offsets, branches, full_bags = [], [], {}, [], []

    def acquired(reward):
        anchors.append({'program': prog_id, 'command': len(commands), 'box': 0, 'actor': 'hero'})
        commands.append({'kind': 'open_box', 'box': 0, 'actor': 'hero',
                         'requires': {'kind': 'box_closed', 'id': 'box_0'}})
        text = pool.get_body_text(reward['message_tokens'])
        commands.append({'kind': 'text', 'box': 0, 'text': text, 'wait': {'kind': 'text', 'id': text}})

    cursor, pending_reward = 0, None
    while cursor < len(rows):
        row = rows[cursor]
        cursor += 1
        pc, op, args = row['offset'], row['opcode'], row['operands']
        offsets[pc] = len(commands)
        if op == 0x10:
            command = {'kind': 'align_hero', 'x': args[0] * 8, 'y': args[1] * 8,
                       'wait': {'kind': 'alignment', 'id': 'alignment'}}
        elif op == 0x34:
            if args != [1, 8, 0, 21, 34]: raise ValueError('wheel spin Hero construction changed')
            command = {'kind': 'spawn_actor', 'actor': proxy}
        elif op == 0x3a:
            if args != [128]: raise ValueError('wheel spin release target changed')
            commands.append(dict(wheel['geometry']['projection']['aligned_camera_commands'][str(entity)]))
            command = {'kind': 'hide_hero'}
        elif op == 0x11:
            command = facing[pc]
        elif op == 0x0a:
            command = {'kind': 'delay', 'updates': args[0] * 5, 'wait': {'kind': 'delay', 'id': 'delay'}}
        elif op == 8:
            command = pans[pc]
        elif op == 0x22:
            if args not in ([0], [1], [3]): raise ValueError('unsupported wheel spin motion')
            command = {'kind': {0: 'wheel_spin', 1: 'wheel_restore', 3: 'wheel_align'}[args[0]]}
        elif op == 0x2f:
            if len(args) == 7:
                command = {'kind': 'branch_wheel', 'targets': [0] * 7}
                branches.append((len(commands), [r['offset'] for r in variant['branches']]))
            elif len(args) == 2 and pending_reward is not None:
                target = next(r['offset'] for r in rows[cursor:] if r['opcode'] == args[1])
                command = {'kind': 'jump', 'target': 0}
                branches.append((len(commands), [target]))
            else: raise ValueError('unsupported wheel result branch')
        elif op == 0x41:
            command = audio[pc]
            if sound_ids is not None and command['cue'] not in sound_ids:
                # shortcut: retain the branch entry until the matching cue is packaged.
                command = {'kind': 'label'}
        elif op == 7:
            following = rows[cursor]
            if args[1] != 1 or following['opcode'] != 7 or following['operands'][:2] != [args[0], 2]:
                raise ValueError('wheel spin atomic placement changed')
            cursor += 1
            command = {'kind': 'place_hero' if args[0] == 128 else 'place_actor',
                       'x': args[2] * 8, 'y': following['operands'][2] * 8}
            if args[0] != 128:
                command['actor'] = proxy if args[0] == 64 else wheel['monster_actor']['id'] if args[0] == 0 else None
                if command['actor'] is None: raise ValueError('unbound wheel placement actor')
        elif op == 0x32:
            command = {'kind': 'queue_track', 'track': tracks[pc]}
        elif op == 0x33:
            command = {'kind': 'wait_tracks'}
        elif op == 0x39:
            command = {'kind': 'release_actor', 'actor': proxy}
        elif op == 0:
            command = fixed[pc]
        elif op == 0x1c:
            text = pool.get_body_text(speeches[pc])
            command = {'kind': 'text', 'box': args[0], 'text': text, 'wait': {'kind': 'text', 'id': text}}
        elif op in (2, 0x46):
            command = {'kind': 'wait_for_accept' if op == 2 else 'wait_event_flags_low2'}
        elif op in (1, 0x0c):
            command = {'kind': 'close_box', 'box': args[0] if op == 1 else 0}
        elif op == 0x4b:
            if args not in ([3, 255], [4, 255]): raise ValueError('wheel experience operation changed')
            command = {'kind': 'party_gain_experience' if args[0] == 3 else 'party_lose_experience'}
        elif op == 0x47:
            if args != [0]: raise ValueError('wheel Monster selector changed')
            command = {'kind': 'battle', 'battle': 'vb3_wheel_monster', 'defeat_ends_run': True}
        elif op == 0x49:
            if args == [254]:
                if pending_reward is None: raise ValueError('wheel message lacks pending reward')
                acquired(pending_reward)
                continue
            pending_reward = rewards[args[0]]
            tail = rows[cursor:cursor + 7]
            if [(r['opcode'], r['operands']) for r in tail[:4]] != [(0x49, [254]), (2, []), (0x0c, []), (0x46, [])]:
                raise ValueError('wheel reward/message ordering changed')
            delay = tail[4]['operands'][0] * 5 if tail[4]['opcode'] == 0x0a else 0
            full_bags.append((len(commands), pending_reward, delay))
            command = {'kind': 'chest_grant', 'item_name': pending_reward['id'], 'failure_target': 0}
        elif op == 0x43:
            if args != [8, 0] or pending_reward is None: raise ValueError('wheel full-bag handoff changed')
            command = {'kind': 'item_overload', 'item_name': pending_reward['id']}
        elif op == 0xfd:
            command = {'kind': 'end_stream'}
        elif op in (0xfc, 0xfb, 0xfa, 0xf9, 0xf8, 0xf0):
            command = {'kind': 'label'}
        else:
            raise ValueError(f'unlowered wheel spin instruction {op:#x}')
        commands.append(command)
    for index, targets in branches:
        command = commands[index]
        command['targets' if command['kind'] == 'branch_wheel' else 'target'] = [offsets[p] for p in targets] if command['kind'] == 'branch_wheel' else offsets[targets[0]]
    for grant, reward, delay in full_bags:
        # The failed grant redirects to an identical message before the overload modal.
        commands[grant]['failure_target'] = len(commands)
        acquired(reward)
        commands.extend([{'kind': 'wait_for_accept'}, {'kind': 'close_box', 'box': 0}, {'kind': 'wait_event_flags_low2'}])
        if delay: commands.append({'kind': 'delay', 'updates': delay, 'wait': {'kind': 'delay', 'id': 'delay'}})
        commands.extend([{'kind': 'item_overload', 'item_name': reward['id']}, {'kind': 'end_stream'}])
    if len(rows) != 132 or len(anchors) != 4 or len(full_bags) != 2:
        raise ValueError('wheel spin lowering inventory changed')
    return ({'id': prog_id, 'entry': 'ordinary', 'entity': entity, 'trigger': 'none',
             'conditions': conditions, 'selection': selection, 'commands': commands}, anchors, [])


def wheel_event_content():
    """Compile the retained wheel streams without admitting an unfinished room."""
    from export_scripted_travel import kouan_wheel
    raw, _ = source('/VB3.BIN')
    wheel = kouan_wheel()
    pool, tracks, programs = RoomTextPool('vb3_room_28', {}), [], []
    for variant in wheel['variants']:
        entity = variant['entity']
        conditions, selection = [], []
        for term in variant['selection']['terms']:
            if term['kind'] in ('story_mask_set', 'story_mask_clear'): conditions.append(term)
            elif term['kind'] == 'coordinate_range':
                coordinate = term['coordinate']
                selection.append({'kind': f"hero_{coordinate['axis']}_inclusive", 'min': coordinate['first'], 'max': coordinate['last']})
            else: raise ValueError('unsupported wheel program predicate')
        program_id = f'vb3_room_28_e{entity}'
        if entity == 3: program, _, _ = compile_wheel_return(raw, program_id, conditions, selection, 'ordinary', tracks)
        else: program, _, _ = compile_wheel_spin(raw, entity, program_id, pool, conditions, selection, 'ordinary', tracks)
        programs.append(program)
    programs.append({'id': 'vb3_room_28_reward_watch', 'entry': 'ordinary', 'entity': 5, 'trigger': 'none',
                     'conditions': [{'kind': 'story_mask_clear', 'flag': {'id': 'scenario_0044', 'mask': 1}}],
                     'selection': [{'kind': 'has_item', 'index': 80, 'require_key': False}],
                     'commands': [{'kind': 'story_or', 'flag': {'id': 'scenario_0044', 'mask': 1}}, {'kind': 'end_stream'}]})
    actors = [{'id': v['actor']['id']} for v in wheel['variants'] if 'actor' in v]
    actors.extend([{'id': wheel['return_scene']['actor']['id']}, {'id': wheel['monster_actor']['id']}])
    content = {'schema': 'suikoden-event-ir/25', 'id': 'vb3_room_28_wheel',
               'story_values': [{'id': 'scenario_0044', 'storage': 'scenario', 'byte_index': 44, 'initial': 0}],
               'actors': actors, 'texts': pool.body_texts, 'tracks': tracks, 'programs': programs}
    content['content_sha256'] = sha256_canonical(content)
    return content


def compile_wheel_return(data, prog_id, conditions, selection, trigger, room_tracks):
    from export_scripted_travel import kouan_wheel
    wheel = kouan_wheel()
    if trigger != 'ordinary' or hashlib.sha256(data).hexdigest() != wheel['source']['sha256']:
        raise ValueError('unsupported wheel return context')
    returning = wheel['return_scene']
    rows = next(v['instructions'] for v in wheel['variants'] if v['entity'] == 3)
    actor = returning['actor']['id']
    tracks = {}
    for row in returning['choreography']['tracks']:
        track_id = f'vb3_room_28_return_track_{row["offset"]:05x}'
        tracks[row['offset']] = track_id
        room_tracks.append({'id': track_id, 'actor': actor, 'commands': row['commands']})
    pans = {r['offset']: r['command'] for r in returning['choreography']['pans']}
    facing = {r['offset']: r['command'] for r in returning['choreography']['facing']}
    commands, cursor = [], 0
    while cursor < len(rows):
        row = rows[cursor]
        cursor += 1
        pc, op, args = row['offset'], row['opcode'], row['operands']
        if op == 0x10:
            command = {'kind': 'align_hero', 'x': args[0] * 8, 'y': args[1] * 8,
                       'wait': {'kind': 'alignment', 'id': 'alignment'}}
        elif op == 0x34:
            command = {'kind': 'spawn_actor', 'actor': actor}
        elif op == 0x11:
            command = facing[pc]
        elif op == 0x0a:
            command = {'kind': 'delay', 'updates': args[0] * 5, 'wait': {'kind': 'delay', 'id': 'delay'}}
        elif op == 0x3a:
            if args != [128]: raise ValueError('wheel return release target changed')
            commands.append(dict(wheel['geometry']['projection']['aligned_camera_commands']['3']))
            command = {'kind': 'hide_hero'}
        elif op == 8:
            command = pans[pc]
        elif op == 0x22:
            if args == [2, 90]: command = {'kind': 'wheel_turn', 'updates': 90}
            elif args == [1]: command = {'kind': 'wheel_restore'}
            else: raise ValueError('wheel return motion changed')
        elif op == 0x32:
            command = {'kind': 'queue_track', 'track': tracks[pc]}
        elif op == 0x33:
            command = {'kind': 'wait_tracks'}
        elif op in (0x30, 0x31):
            command = {'kind': 'continue_tick' if op == 0x30 else 'yield_tick'}
        elif op == 7:
            following = rows[cursor]
            if args[1] != 1 or following['opcode'] != 7 or following['operands'][:2] != [args[0], 2]:
                raise ValueError('wheel return atomic placement changed')
            cursor += 1
            command = {'kind': 'place_hero' if args[0] == 128 else 'place_actor',
                       'x': args[2] * 8, 'y': following['operands'][2] * 8}
            if args[0] != 128: command['actor'] = actor
        elif op == 0x39:
            command = {'kind': 'release_actor', 'actor': actor}
        elif op == 0xfd:
            command = {'kind': 'end_stream'}
        else:
            raise ValueError('unlowered wheel return instruction')
        commands.append(command)
    if len(commands) != 20 or len(tracks) != 2:
        raise ValueError('wheel return native command inventory changed')
    return ({'id': prog_id, 'entry': 'ordinary', 'entity': 3, 'trigger': 'none',
             'conditions': conditions, 'selection': selection, 'commands': commands}, [], [])


def compile_headquarters_scene(data, room_id, prog_id, pool, conditions, selection, trigger, room_tracks, original):
    expected_trigger = 'interaction' if original['entity'] in (8, 12, 13, 15) else 'ordinary'
    if trigger != expected_trigger or hashlib.sha256(data).hexdigest() != original['source']['sha256']:
        raise ValueError('unsupported headquarters scene context')
    actors = {entry['selector']: entry['native_actor_id'] for entry in original['actors']}
    def actor(selector):
        return 'hero' if selector == 128 else actors[selector]
    choreography = original['choreography']
    speeches = {speech['source_offset']: speech for speech in choreography['dialogues']}
    facing = {entry['offset']: entry['command'] for entry in choreography['facing']}
    pans = {entry['offset']: entry['command'] for entry in choreography['pans']}
    audio = {entry['offset']: entry for entry in original.get('audio_requests', [])}
    effects = {entry['offset']: entry['command'] for entry in original.get('effect_lowerings', [])}
    placements = {entry['offset']: entry for entry in original.get('atomic_placements', [])}
    tracks = {}
    for entry in choreography['tracks']:
        track_id = f'{room_id}_founding_track_{entry["offset"]:04x}'
        tracks[entry['offset']] = track_id
        room_tracks.append({'id': track_id, 'actor': entry['actor'], 'commands': entry['commands']})
    commands, anchors, prefixes = [], [], []
    skip_until = 0
    for row in original['instructions']:
        pc, opcode, args = row['offset'], row['opcode'], row['operands']
        if pc < skip_until:
            continue
        if pc in placements:
            placement = placements[pc]
            command = {'kind': 'place_actor', 'actor': actor(placement['selector']), **placement['position']}
            skip_until = placement['end']
        elif opcode == 0x10:
            command = {'kind': 'align_hero', 'x': args[0] * 8, 'y': args[1] * 8,
                       'wait': {'kind': 'alignment', 'id': 'alignment'}}
        elif opcode == 7:
            if args[1] not in (1, 2):
                raise ValueError('unsupported headquarters actor placement')
            command = {'kind': 'place_actor', 'actor': actor(args[0]),
                       ('x' if args[1] == 1 else 'y'): args[2] * 8}
        elif opcode == 0x34 and original['entity'] in (12, 15):
            if args != ([1, 35, 0, 31, 45] if original['entity'] == 15 else [1, 35, 0, 12, 53]):
                raise ValueError('unsupported Giovanni dynamic construction')
            command = {'kind': 'spawn_actor', 'actor': actor(64)}
        elif opcode == 0x39 and original['entity'] in (12, 15):
            command = {'kind': 'release_actor', 'actor': actor(64)}
        elif opcode == 0x0d and original['entity'] == 15:
            if args != [1, 0]: raise ValueError('unsupported approach prop')
            command = {'kind': 'show_prop', 'prop': 0}
        elif opcode == 0x3b and original['entity'] == 8:
            if args != [4, 8, 2, 1, 35]: raise ValueError('unsupported Juppo party prefix')
            command = {'kind': 'request_area_party_prefix', 'requested_prefix': args[1:], 'scope': 'area_transient'}
        elif opcode in (0x36, 0x37, 0x38) and original['entity'] == 8:
            command = {'kind': {0x36: 'queue_glyphs_a', 0x37: 'queue_glyphs_b', 0x38: 'wait_text_queue_drain_and_release'}[opcode]}
        elif opcode == 0x42 and original['entity'] == 8:
            if args != [25]: raise ValueError('unsupported Juppo dispatch')
            command = {'kind': 'world_mode', 'code': 25}
        elif opcode == 0x1f:
            if args not in ([255, 35], [255, 1]):
                raise ValueError('unsupported briefing party load')
            command = {'kind': 'party_load', 'character': {35: 'viktor', 1: 'cleo'}[args[1]]}
        elif opcode == 0x4a:
            if args not in ([0, 35], [0, 1]):
                raise ValueError('unsupported briefing auxiliary member')
            command = {'kind': 'area_action', 'area': {'kind': 'auxiliary_party_add', 'character': args[1]}}
        elif opcode == 0x43:
            if args != [255, 44]:
                raise ValueError('unsupported headquarters scene callback')
            for portrait in original['party_callback']['portraits']['portraits']:
                image = pool.get_image(portrait['source_character'])
                if image is not None:
                    decoded = pool.images[image]
                    if (decoded['plane_sha256'] != portrait['eject_plane_sha256']
                            or decoded['palette_sha256'] != portrait['palette_sha256']):
                        raise ValueError('selector portrait disagrees with existing decoded art')
            command = {'kind': 'party_select'}
        elif opcode == 0x0a:
            command = {'kind': 'delay', 'updates': args[0] * 5, 'wait': {'kind': 'delay', 'id': 'delay'}}
        elif opcode == 0x32:
            command = {'kind': 'queue_track', 'track': tracks[pc]}
        elif opcode in (0x33, 0x46, 2):
            command = {'kind': {0x33: 'wait_tracks', 0x46: 'wait_event_flags_low2', 2: 'wait_for_accept'}[opcode]}
        elif opcode == 0x11:
            command = dict(facing[pc])
        elif opcode in (0x0b, 0x17):
            box = 0 if opcode == 0x0b else 1
            target = actor(args[0])
            command = {'kind': 'open_box', 'box': box, 'actor': target,
                       'requires': {'kind': 'box_closed', 'id': f'box_{box}'}}
            anchor = {'program': prog_id, 'command': len(commands), 'box': box}
            if target.startswith('party_follower_'):
                anchor['follower'] = args[0] & 63
            else:
                anchor['actor'] = target
            anchors.append(anchor)
        elif opcode == 0x12:
            speech = speeches[pc + 3]
            if (speech['box'], speech['character']) != tuple(args):
                raise ValueError('founding prefix/speech pairing changed')
            image = pool.get_image(args[1])
            if image is None:
                raise ValueError('founding portrait missing from candidate art')
            prefix = pool.get_speaker_text(speech['speaker_name'], source_tokens=speech['prefix_tokens'])
            command = {'kind': 'start_or_wait_dialogue', 'box': args[0], 'code': args[1],
                       'wait': {'kind': 'speaker_prefix', 'id': f'box_{args[0]}'}}
            prefixes.append({'program': prog_id, 'command': len(commands), 'box': args[0], '_text_id': prefix, 'image': image})
        elif opcode == 0x1c:
            text = pool.get_body_text(decode_text_tokens(data, speeches[pc]['string_offset']))
            command = {'kind': 'text', 'box': args[0], 'text': text, 'wait': {'kind': 'text', 'id': text}}
        elif opcode in (0x0c, 0x18):
            command = {'kind': 'close_box', 'box': 0 if opcode == 0x0c else 1}
        elif opcode == 0x41:
            request = audio[pc]
            command = dict(request['command']) if 'command' in request else {'kind': 'play_sound', 'cue': request['request']}
        elif opcode == 0x4f:
            command = dict(effects[pc])
        elif opcode == 0x3a:
            command = {'kind': 'release_actor', 'actor': actor(args[0])}
        elif opcode == 0x45:
            character = 39 if original['entity'] == 8 else 26
            if args != [character]: raise ValueError('scene recruit toggle changed')
            command = {'kind': 'recruit_toggle', 'index': character}
        elif opcode == 0x4b:
            if original['entity'] == 8:
                if args != [0, 39, 9]: raise ValueError('Juppo growth changed')
                command = {'kind': 'advance_character', 'character': 'juppo', 'level_advances': 9}
            else:
                if args != [0, 26, 11]: raise ValueError('founding Luc growth changed')
                command = {'kind': 'advance_character', 'character': 'luc', 'level_advances': 11}
        elif opcode == 8:
            command = dict(pans[pc])
        elif opcode == 9:
            command = {'kind': 'story_or', 'flag': {'id': story_id(args[0]), 'mask': args[1]}}
        elif opcode == 0x24:
            command = {'kind': 'fade_out', 'blend_mode': 2, 'draw_slot': 10, 'wait': {'kind': 'fade', 'id': 'fade'}}
        elif opcode == 0x4c:
            command = dict(original['party_recovery']['command'])
        elif opcode == 0x20:
            command = dict(original['party_dismissal']['command'])
        elif opcode == 3:
            destination = original['transition'] if original['entity'] == 15 else original['terminal_handoff']
            command = {'kind': 'room_transition', 'destination': 'vb3_room_11' if original['entity'] == 15 else 'vb5a2_room_0',
                       'x': destination['spawn_pixels'][0], 'y': destination['spawn_pixels'][1]}
        elif opcode == 0xfd:
            if original['entity'] in (8, 12, 13):
                command = {'kind': 'end_stream'}
                commands.append(command)
            elif commands[-1]['kind'] != 'room_transition':
                raise ValueError('founding must end in the source headquarters handoff')
            break
        else:
            raise ValueError(f'unlowered founding instruction {opcode:#x} at {pc:#x}')
        commands.append(command)
    expected = (56, 8, 8) if original['entity'] == 8 else (44, 4, 4) if original['entity'] == 15 else (28, 3, 3) if original['entity'] == 12 else (45, 4, 4) if original['entity'] == 13 else (116, 12, 12)
    if (len(commands), len(anchors), len(prefixes)) != expected:
        raise ValueError('headquarters command/anchor/prefix inventory changed')
    return {'id': prog_id, 'entry': 'ordinary', 'entity': original['entity'],
            'trigger': 'interaction' if expected_trigger == 'interaction' else 'none', 'conditions': conditions,
            'selection': selection, 'commands': commands,
            **({'owner_actor': actor(2)} if original['entity'] == 13 else {})}, anchors, prefixes


def compile_headquarters_entry(data, room_id, prog_id, pool, conditions, selection, trigger, room_tracks):
    from export_scripted_travel import hq_auxiliary_party, outputs
    source_entry = hq_auxiliary_party()
    entry = source_entry['entry_program']
    if trigger != 'ordinary' or conditions != entry['conditions'] or hashlib.sha256(data).hexdigest() != source_entry['source']['sha256']:
        raise ValueError('unsupported headquarters entry context')
    actor = f'{room_id}_actor_08_002'
    if f'{room_id}_character_002' not in pool.art.get('actor_clips', {}):
        raise ValueError('headquarters entry needs verified Gremio clips')
    report, _ = outputs()
    speaker = next(speech for speech in report['dock_arrival']['dialogues'] if speech['character'] == 2)
    commands, anchors, prefixes = [], [], []
    track_ids = {}
    for track in entry['tracks']:
        track_id = f'{room_id}_entry_track_{track["offset"]:05x}'
        room_tracks.append({'id': track_id, 'actor': actor, 'commands': track['commands']})
        track_ids[track['offset']] = track_id
    for row in entry['instructions']:
        pc, opcode, args = row['offset'], row['opcode'], row['operands']
        if opcode == 0x32:
            command = {'kind': 'queue_track', 'track': track_ids[pc]}
        elif opcode == 0x33:
            command = {'kind': 'wait_tracks'}
        elif opcode == 0x0b:
            command = {'kind': 'open_box', 'box': 0, 'actor': actor, 'requires': {'kind': 'box_closed', 'id': 'box_0'}}
            anchors.append({'program': prog_id, 'command': len(commands), 'box': 0, 'actor': actor})
        elif opcode == 0x12:
            image = pool.get_image(2)
            if image is None:
                raise ValueError('headquarters Gremio portrait missing')
            prefix = pool.get_speaker_text(speaker['speaker_name'], source_tokens=speaker['prefix_tokens'])
            command = {'kind': 'start_or_wait_dialogue', 'box': 0, 'code': 2, 'wait': {'kind': 'speaker_prefix', 'id': 'box_0'}}
            prefixes.append({'program': prog_id, 'command': len(commands), 'box': 0, '_text_id': prefix, 'image': image})
        elif opcode == 0x1c:
            text = pool.get_body_text(entry['dialogue']['tokens'])
            command = {'kind': 'text', 'box': 0, 'text': text, 'wait': {'kind': 'text', 'id': text}}
        elif opcode == 2:
            command = {'kind': 'wait_for_accept'}
        elif opcode == 0x0c:
            command = {'kind': 'close_box', 'box': 0}
        elif opcode == 0x1f:
            command = dict(source_entry['load']['command'])
        elif opcode == 0x4a:
            command = dict(source_entry['command'])
        elif opcode == 0x3a:
            command = {'kind': 'release_actor', 'actor': actor}
        elif opcode == 9:
            command = {'kind': 'story_or', 'flag': {'id': story_id(args[0]), 'mask': args[1]}}
        elif opcode == 3:
            command = {'kind': 'room_transition', 'destination': room_id, 'x': 80, 'y': 224}
        elif opcode == 0xfd:
            if commands[-1]['kind'] != 'room_transition':
                raise ValueError('headquarters entry must finish with its source reentry')
            break
        else:
            raise ValueError('unlowered headquarters entry instruction')
        commands.append(command)
    if len(commands) != entry['native_command_count'] or len(anchors) != 1 or len(prefixes) != 1:
        raise ValueError('headquarters entry command inventory changed')
    return {'id': prog_id, 'entry': 'ordinary', 'entity': 3, 'trigger': 'none', 'conditions': conditions,
            'selection': selection, 'commands': commands}, anchors, prefixes


def scenery_swap(data, offset, model):
    move, selector, active, x, y, stage, hidden = data[offset:offset + 7]
    if ((move, selector, stage) != (0x40, 0xfe, 0x0f) or model is None or active == hidden
            or max(active, hidden) >= model['initial_count']):
        raise ValueError('unsupported scenery swap')
    position = (x * 8, y * 8)
    objects = model['objects']
    if (objects[hidden]['x'], objects[hidden]['y']) != position:
        raise ValueError('scenery swap does not replace the documented position')
    if (objects[active]['x'], objects[active]['y']) == position:
        replacement = {'kind': 'scenery_restore', 'scenery_object': active}
    else:
        relocated = dict(objects[active], x=position[0], y=position[1])
        index = next((i for i in range(model['initial_count'], len(objects)) if objects[i] == relocated), None)
        if index is None:
            raise ValueError('relocated scenery template is missing')
        replacement = {'kind': 'scenery_append', 'scenery_object': index}
    return [replacement, {'kind': 'scenery_stage', 'scenery_object': hidden}]


def compile_actor_initializer(data, entities, entity, conditions, scenery_templates=(), initial_scenery_count=0, *, conditional_staging=False):
    """Compile the complete supported first pump; the sweep does not arm its tail."""
    from maindec import mword
    order = actor_allocation_order(entities)
    commands = []
    pc = entity['stream_offsets'][2]
    if pc is None:
        return None
    for _ in range(64):
        rows = decode_stream(data, start=pc, max_insns=1)
        if len(rows) != 1:
            return None
        offset, opcode, args, note = rows[0]
        next_pc = offset + 1 + len(args)
        if 'UNKNOWN' in note or 'NULL' in note or 'truncat' in note.lower():
            return None
        if opcode == 0x30 and not commands:
            command = {'kind': 'continue_tick'}
        elif opcode in (0x07, 0x11, 0x3A):
            if not commands or commands[0]['kind'] != 'continue_tick':
                return None
            selector = args[0]
            if selector == 0x80:
                if opcode == 0x11 and len(args) == 2 and args[1] <= 3:
                    command = {'kind': 'actor_transition', 'actor': 'hero', 'transition': mword(0x80171B98 + 4 * args[1])}
                elif opcode == 0x07 and len(args) == 3 and args[1] == 1:
                    following = decode_stream(data, start=next_pc, max_insns=1)
                    if not following or following[0][1] != 0x07 or len(following[0][2]) != 3 or following[0][2][:2] != b'\x80\x02':
                        return None
                    command = {'kind': 'place_hero', 'x': args[2] * 8, 'y': following[0][2][2] * 8}
                    next_pc += 1 + len(following[0][2])
                else:
                    return None
                commands.append(command)
                pc = next_pc
                continue
            if selector >= 0x40 or selector >= len(order):
                return None
            source_entity = order[selector]
            constructor = entities[source_entity]
            if constructor['flags'] & ~7 or constructor['stream_offsets'][0] is None:
                return None
            try:
                predicate, _ = decode_predicate(data, constructor['stream_offsets'][0], 'classification', full=True)
            except ReservedActorPredicate:
                return None
            conditional = any(term not in conditions for term in predicate['terms'])
            if conditional and not (conditional_staging and (
                (opcode == 0x07 and args[1:] in (b'\x01\xfe', b'\x02\xfe'))
                or (entity['stream_offsets'][2] == 0x39ACC and opcode in (0x07, 0x11))
            )):
                return None
            if opcode == 0x3A:
                # The source stages a live descriptor; it does not release its graphics.
                if len(args) != 1 or (constructor['flags'] >> 2) & 1:
                    return None
                commands.append({'kind': 'place_actor', 'x': 2032, 'y': 2032, '_source_actor': source_entity})
                command = {'kind': 'actor_motion', 'value': 0}
            elif opcode == 0x07:
                if len(args) != 3:
                    return None
                if args[1] == 0:
                    # shortcut: retain constructor speed only; changed-speed persistence needs its own contract.
                    if args[2] != (constructor['flags'] >> 2) & 1:
                        return None
                    command = {'kind': 'actor_motion', 'value': args[2]}
                elif args[1] in (1, 2):
                    command = {'kind': 'place_actor', 'x' if args[1] == 1 else 'y': args[2] * 8}
                else:
                    return None
            else:
                if len(args) != 2 or args[1] > 3:
                    return None
                command = {'kind': 'actor_transition', 'transition': mword(0x80171B98 + 4 * args[1])}
            if conditional:
                command['if_actor_constructed'] = True
            command['_source_actor'] = source_entity
        elif opcode in (0x09, 0x29) and commands and commands[0]['kind'] == 'continue_tick':
            command = {'kind': 'story_or' if opcode == 0x09 else 'story_andnot',
                       'flag': {'id': story_id(args[0]), 'mask': args[1]}}
        elif opcode == 0x0F and commands and commands[0]['kind'] == 'continue_tick':
            if len(args) != 1 or args[0] >= initial_scenery_count + len(scenery_templates):
                return None
            command = {'kind': 'scenery_stage', 'scenery_object': args[0]}
        elif opcode == 0x3E and commands and commands[0]['kind'] == 'continue_tick':
            if len(args) != 1 or args[0] not in scenery_templates:
                return None
            command = {'kind': 'scenery_append', 'scenery_object': initial_scenery_count + scenery_templates.index(args[0])}
        elif opcode == 0x26 and commands and commands[0]['kind'] == 'continue_tick':
            if len(args) != 2:
                return None
            command = {'kind': 'set_camera', 'x': args[0] * 8, 'y': args[1] * 8}
        elif opcode == 0x31:
            if not commands or commands[0]['kind'] != 'continue_tick':
                return None
            # One continue command plus at most64 effects fit the native pump.
            if not 2 <= len(commands) <= 65:
                return None
            return commands + [{'kind': 'yield_tick'}, {'kind': 'end_stream'}]
        else:
            return None
        commands.append(command)
        pc = next_pc
    return None


def static_conversation(data, room_number, entity_index, room_id, program, art, half_width, half_height):
    """Qualify a complete dialogue against supported source predicates and construction."""
    if program['trigger'] != 'interaction' or any(command['kind'] not in
            ('open_box', 'wait_boxes', 'text', 'wait_for_accept', 'close_box', 'end_stream')
            for command in program['commands']):
        return False
    entities = scene.entities(data, scene.room_record(data, room_number))
    entity = entities[entity_index]
    if entity['flags'] & ~3:
        return False
    predicate, proof = decode_predicate(data, entity['stream_offsets'][1], 'event', coordinate_ranges=True)
    predicate = normalize_event_predicate(predicate, proof)
    if predicate['pointer_state'] != 'present' or not any(term['kind'] == 'interaction' for term in predicate['terms']):
        return False
    conditions, selection = [], []
    for term in predicate['terms']:
        if term['kind'] == 'interaction':
            continue
        if term['kind'] in ('story_mask_set', 'story_mask_clear'):
            conditions.append(term)
        elif (lowered := event_selection_term(term)) is not None:
            selection.append(lowered)
        else:
            return False
    ordered = lambda terms: sorted(json.dumps(term, sort_keys=True) for term in terms)
    if ordered(program['conditions']) != ordered(conditions) or ordered(program['selection']) != ordered(selection):
        return False
    inherited = inherits_actor(entity)
    owners = interaction_actor_candidates(data, entities, entity_index) if inherited else [entity_index]
    if not owners or len(owners) != 1:
        return False
    owner = entities[owners[0]]
    # shortcut: flags beyond quiet actor/interaction records need native movement/timing/mode hosts.
    if owner['flags'] & ~3 or not (0 < owner['x_half'] < half_width and 0 < owner['y_half'] < half_height):
        return False
    try:
        classification, _ = decode_predicate(data, owner['stream_offsets'][0], 'classification', full=True)
    except ReservedActorPredicate:
        return False
    supported = ('story_mask_set', 'story_mask_clear', 'recruit_present', 'recruit_absent', 'stage_at_least', 'party_excludes') if inherited else ('story_mask_set', 'story_mask_clear')
    if ((owner['flags'] & 0x101 and classification['pointer_state'] != 'present')
            or any(term['kind'] not in supported for term in classification['terms'])):
        return False
    if owner['flags'] & 0x101:
        clip = f"{room_id}_character_{owner['id']:03d}"
        section = scene.section_off(data, scene.room_record(data, room_number)['section'])
        if owner['id'] not in scene.character_bindings(data, section) or clip not in art['character_clips']:
            return False
    return True


def field_service_overlay(data: bytes, argument: int) -> dict | None:
    """Resolve field callback wrappers which load a group-zero service overlay."""
    table = scene.ptr_at(data, scene.root(data) + 16)
    callback = scene.ptr_at(data, table + argument * 4) if table is not None else None
    if callback is None or callback + 0x70 > len(data):
        return None
    if struct.unpack_from('<4I', data, callback) != (0x3C02801C, 0x8C429BC4, 0x3C03801C, 0x8C63B4B8):
        return None
    if struct.unpack_from('<2I', data, callback + 0x20) != (0x8C420004, 0x8C700000):
        return None
    descriptor, *load = struct.unpack_from('<5I', data, callback + 0x5C)
    if descriptor >> 16 != 0x8E04 or load != [0x8C620010, 0, 0x0040F809, 0x3C058008]:
        return None
    slot = descriptor & 0xFFFF
    if slot % 4 or slot >= 32:
        return None
    import maindec
    group = maindec.mword(0x8016B358)
    record = maindec.mword(group + slot)
    if not record:
        return None
    return {'callback_offset': callback, 'group_slot': slot // 4, 'record': record,
            'lba': maindec.mword(record + 4), 'size': maindec.mword(record)}


@cache
def service_extent(overlay: str) -> tuple[int, int]:
    data, proof = source(f'DATA/03_SHIRO/{overlay}.BIN')
    if overlay == 'BOOKS' and (
        struct.unpack_from('<9I', data, 0x3DCC) != (*range(106, 114), 0)
        or data[0x3DF0:0x3DF8] != bytes(1 << i for i in range(8))
    ):
        raise ValueError('Library book identities or collection masks changed')
    return proof['lba'], proof['size']


def teleport_callback(data: bytes) -> int | None:
    table = scene.ptr_at(data, scene.root(data) + 16)
    callback = scene.ptr_at(data, table + 12) if table is not None else None
    if callback is not None and data[callback:callback + 32] == bytes.fromhex(
            'e8ffbd271400bfaf1000b0af218080001c80033cc49b638c1b80023c00a04234'):
        return callback
    return None


def append_story_dialogue(commands, anchors, program, pool, lines, *, choice=False):
    tokens = []
    for line in lines:
        if tokens:
            tokens.append({'kind': 'newline'})
        tokens.extend(make_speaker_tokens(line))
    text = pool.get_body_text(tokens)
    anchors.append({'program': program, 'command': len(commands), 'box': 0, 'actor': 'hero'})
    commands.extend([
        {'kind': 'open_box', 'box': 0, 'actor': 'hero', 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
        {'kind': 'wait_boxes'}, {'kind': 'text', 'box': 0, 'text': text, 'wait': {'kind': 'text', 'id': text}},
        {'kind': 'choice', 'box': 0, 'options': len(lines)} if choice else {'kind': 'wait_for_accept'},
        {'kind': 'close_box', 'box': 0}, {'kind': 'wait_boxes'},
    ])


def compile_program(
    fname: str,
    rn: int,
    ent_idx: int,
    e: dict,
    data: bytes,
    rt_off: int,
    t_arr_off: int,
    grids: dict,
    room_id: str,
    prog_id: str,
    pool: RoomTextPool,
    prog_conditions: list[dict],
    selection_terms: list[dict],
    trigger: str,
    hw: int,
    hh: int,
    room_tracks: list[dict],
    *, with_crossing: bool = False, battle_data=None, combat_party=None, file_slots=(), world_regions=None, world_entries=(), movable_entities=frozenset(), entities=None, wheel_sounds=None, scenery_model=None,
) -> tuple[dict, list[dict], list[dict]] | None:
    """Compile entity script starting at e['stream_offsets'][2] into EventIR commands."""
    key = (fname, rn, ent_idx)
    vault_conveyor = (fname, rn) == ('/VC3.BIN', 15)
    vault_lock = (fname, rn) == ('/VC3.BIN', 21)
    hq_entry = key == ("/VB5A2.BIN", 0, 3)
    hq_briefing = key == ("/VB5A2.BIN", 0, 13)
    hq_morning = key == ("/VB5A2.BIN", 0, 6)
    duel_return_site = {3: 0xc247, 5: 0xc2e3}.get(ent_idx) if (fname, rn) == ('/VB7D.BIN', 0) else None
    final_dock_return = key == ('/VB5BG.BIN', 0, 19)
    antidote_muster = {
        ('/VB5B3.BIN', 0, 51): 0x2edac,
        ('/VB5B3.BIN', 0, 52): 0x2ee01,
        ('/VB5C4.BIN', 0, 61): 0x3c950,
        ('/VB5C4.BIN', 0, 62): 0x3c9a8,
    }.get(key)
    if antidote_muster is not None and not data.startswith(
            bytes.fromhex('20 ff 1f ff 23 4a 00 23 1f ff 11 4a 00 11'), antidote_muster):
        raise ValueError('Scarleticia antidote muster changed')
    gregminster_muster = 0x41380 if key == ('/VAC.BIN', 0, 15) else None
    if gregminster_muster is not None and not data.startswith(
            bytes.fromhex('20 ff 1f ff 23 1f ff 11 4a 00 23 4a 00 11 09 19 01 43 ff 07 fd'), gregminster_muster):
        raise ValueError('Gregminster assault muster changed')
    milich_release = {('/VD6.BIN', 0, 0): 0x47BD3, ('/VD6.BIN', 0, 1): 0x47F5E}.get(key)
    if milich_release is not None and not data.startswith(bytes.fromhex('4a 01 23 4a 01 11'), milich_release):
        raise ValueError('Scarleticia party release changed')
    valeria_recruit = key == ('/VC4.BIN', 0, 5)
    if valeria_recruit:
        section = scene.section_off(data, scene.room_record(data, rn)['section'])
        if (scene.character_bindings(data, section)[36]['index'] != 0
                or not data.startswith(bytes.fromhex('42 05 42 06 1f 00 4b 01 24 02 4a 00 24'), 0x27085)):
            raise ValueError('Valeria recruitment sequence changed')
    kasumi_dismiss = {('/VB5B3.BIN', 0, 84): 0x2F22C, ('/VB5C4.BIN', 0, 95): 0x3CDC4}.get(key)
    if kasumi_dismiss is not None and not data.startswith(b'\x20\xff', kasumi_dismiss):
        raise ValueError('Kasumi briefing party setup changed')
    kouan_welcome = key == ("/VB5A1.BIN", 0, 15) and not with_crossing
    hq_selector = {
        ('/VB5A2.BIN', 0, 13): (0x3FE8B, 0x371C),
        ('/VB5A2.BIN', 0, 15): (0x3FEB5, 0x371C),
        ('/VB5B3.BIN', 0, 16): (0x2E701, 0x1B4),
        ('/VB5C4.BIN', 0, 20): (0x3C269, 0x2F94),
    }.get(key)
    boarding_mode_site = {('/VB5AG.BIN', 0, 1): 0x46291, ('/VB2.BIN', 0, 8): 0x2C1D9,
                          ('/VB5BG.BIN', 0, 10): 0x48F59, ('/VB5BG.BIN', 0, 11): 0x48F59,
                          ('/VB5CG.BIN', 0, 19): 0x49809, ('/VB5CG.BIN', 0, 20): 0x49809,
                          ('/VD3.BIN', 0, 0): 0x44691, ('/VD3.BIN', 0, 7): 0x44931,
                          ('/VD4.BIN', 0, 6): 0x413FD}.get(key)
    flight = {
        ('/VF3.BIN', 0, 1): (0x47EB5, bytes.fromhex('42 0d 4e 00 03 fe 43 2b')),
        ('/VF3.BIN', 0, 3): (0x47F5D, bytes.fromhex('42 0d 4e 00 03 fe 43 2b')),
        ('/VF2.BIN', 0, 1): (0x3DFC1, bytes.fromhex('42 0d 4e 01 03 fe 0e 3c')),
    }.get(key)
    if flight is not None and not data.startswith(flight[1], flight[0]):
        raise ValueError('Dragon flight departure changed')
    dragon_return = key == ('/VF3.BIN', 0, 2)
    start_pc = e["stream_offsets"][2]
    dock_upgrade = {
        ('/VB5BG.BIN', 0, 1): (0x48DE0, 0x48E22, 0x48E59, 0x1080, 0x120C,
                              '71e9c62e80b5ed9078353c9757d82494ab43182a38f8730d4d4c7bb7cc391fb2'),
        ('/VB5CG.BIN', 0, 2): (0x49574, 0x495B7, 0x495EE, 0xBC4, 0xD50,
                              '9387fc74f9dcdc461e051f68758c9363b275e422fef6d443b2508150fcaa21dd'),
    }.get(key)
    if dock_upgrade is not None:
        entry, offer, departure, callback, callback_end, digest = dock_upgrade
        table = scene.ptr_at(data, scene.root(data) + 16)
        if (trigger != 'interaction' or start_pc != entry or e['id'] != 20
                or scene.ptr_at(data, table + 13 * 4) != callback
                or hashlib.sha256(data[callback:callback_end]).hexdigest() != digest
                or not data.startswith(bytes.fromhex('2f 82 fc 3d 03 20 2f 02 f8 09 e7 20 09 c7 01 45 43 45 14 4a 00 20'), offer)
                or not data.startswith(bytes.fromhex('42 0c 03 fb 09 64 4b'), departure - 2)
                or not data.startswith(bytes.fromhex('3d 03 20 2f 02 ff'), switch_2f_targets(data, offer)[1] + 1)):
            raise ValueError('Toran dock upgrade source changed')
        commands, anchors = [], []

        append_story_dialogue(commands, anchors, prog_id, pool, ('Gen and Kamandol are ready to', 'test the upgraded boat.'))
        append_story_dialogue(commands, anchors, prog_id, pool, ('Take the boat out', 'Leave it at the dock'), choice=True)
        choice = {'kind': 'branch_choice', 'target': 0}
        pilot = {'kind': 'branch_party', 'index': 32, 'targets': [0, 0]}
        commands.extend([choice, pilot])
        pilot['targets'][0] = len(commands)
        append_story_dialogue(commands, anchors, prog_id, pool, ('Bring Tai Ho along to pilot', 'the new boat.'))
        commands.append({'kind': 'end_stream'})
        choice['target'] = len(commands)
        append_story_dialogue(commands, anchors, prog_id, pool, ('The boat will be here when', 'you are ready.'))
        commands.append({'kind': 'end_stream'})
        pilot['targets'][1] = len(commands)
        append_story_dialogue(commands, anchors, prog_id, pool, ('Tai Ho has the helm.', 'Ready to launch.'))
        commands.extend([
            {'kind': 'story_or', 'flag': {'id': story_id(231), 'mask': 32}},
            {'kind': 'story_or', 'flag': {'id': story_id(199), 'mask': 1}},
            {'kind': 'recruit_toggle', 'index': 67}, {'kind': 'recruit_toggle', 'index': 20},
            {'kind': 'area_action', 'area': {'kind': 'auxiliary_party_add', 'character': 32}},
            {'kind': 'world_mode', 'code': 12},
            {'kind': 'world_transition', 'destination': 'world_j', 'x': 100, 'y': 75},
        ])
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'interaction',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': commands}, anchors, [])

    if key == ('/VG3.BIN', 1, 2):
        if (trigger != 'interaction' or e['id'] != 5 or start_pc != 0x15858
                or not data.startswith(bytes.fromhex('09 c7 20'), start_pc)
                or not data.startswith(bytes.fromhex('41 96 50 00 58'), 0x158CD)):
            raise ValueError('Fire Spear grant source changed')
        commands, anchors = [], []
        append_story_dialogue(commands, anchors, prog_id, pool, ('The Fire Spears are ready.', 'Ask Kun To about shipping them.'))
        grant = {'kind': 'shared_inventory_edit', 'inventory': {'give': RUNTIME_ITEM_BINDINGS[0x58], 'failure_target': 0}}
        commands.extend([grant, {'kind': 'story_or', 'flag': {'id': story_id(199), 'mask': 32}}])
        append_story_dialogue(commands, anchors, prog_id, pool, ('Received the Fire Spears.',))
        commands.append({'kind': 'end_stream'})
        grant['inventory']['failure_target'] = len(commands)
        append_story_dialogue(commands, anchors, prog_id, pool, ('There is no room for the cargo.',))
        commands.append({'kind': 'end_stream'})
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'interaction',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': commands}, anchors, [])

    if key == ('/VG1.BIN', 0, 43):
        if (trigger != 'ordinary' or start_pc != 0x29C08
                or not data.startswith(bytes.fromhex('2f 82 fb 42 0c 03 fb 09 2f 0d fb fd'), 0x29C1A)):
            raise ValueError('Region G harbor departure source changed')
        commands, anchors = [], []
        append_story_dialogue(commands, anchors, prog_id, pool, ('Set sail', 'Stay ashore'), choice=True)
        commands.extend([
            {'kind': 'branch_choice', 'target': len(commands) + 2},
            {'kind': 'jump', 'target': len(commands) + 3},
            {'kind': 'end_stream'},
            {'kind': 'world_mode', 'code': 12},
            {'kind': 'world_transition', 'destination': 'world_j', 'x': data[0x29C22], 'y': data[0x29C23]},
        ])
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'none',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': commands}, anchors, [])

    if key == ('/VD5.BIN', 1, 0):
        if start_pc != 0x4aa04 or data[start_pc:start_pc + 3] != b'\x09\xc4\x04' or any(
            not data.startswith(bytes.fromhex(operands), site) for site, operands in (
                (0x4ae4c, '50 02 02 20 fe 02 42 0f 20 ff'),
                (0x4ae56, '45 ff 01 45 ff 06 45 ff 23 45 ff 03 45 ff 11 42 14'),
                (0x4ae69, '3d 17 2f 04 fb fc f9'),
            )
        ):
            raise ValueError('Soniere escape handoff changed')
        # Use an authored exchange before the existing inventory and campaign effects.
        text = pool.get_body_text([*make_speaker_tokens('Gremio stays to hold the door.'), {'kind': 'newline'},
                                   *make_speaker_tokens('You lead Liukan to safety.')])
        cmds = [
            {'kind': 'open_box', 'box': 0, 'actor': 'hero', 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
            {'kind': 'wait_boxes'},
            {'kind': 'text', 'box': 0, 'text': text, 'wait': {'kind': 'text', 'id': text}},
            {'kind': 'wait_for_accept'}, {'kind': 'close_box', 'box': 0}, {'kind': 'wait_boxes'},
            {'kind': 'fade_out', 'blend_mode': 2, 'draw_slot': 10, 'wait': {'kind': 'fade', 'id': 'fade'}},
            {'kind': 'warehouse_deposit', 'character': 'gremio'},
            {'kind': 'party_leave', 'character': 'gremio', 'value': 1},
            {'kind': 'recruit_toggle', 'index': 2, 'mask': 2},
            {'kind': 'soul_eater_advance'},
            {'kind': 'party_dismiss'},
            *({'kind': 'recruit_toggle', 'index': character, 'mask': 1} for character in (1, 6, 35, 3, 17)),
            {'kind': 'story_or', 'flag': {'id': story_id(38), 'mask': 8}},
            {'kind': 'story_or', 'flag': {'id': story_id(196), 'mask': 4}},
        ]
        targets = []
        cmds.append({'kind': 'branch_castle_tier', 'targets': targets})
        for site in (0x4ae73, 0x4ae7f, 0x4ae8b):
            opcode, fmt, region, area, room, x, y = data[site:site + 7]
            if (opcode, fmt) != (0x03, 0xfa):
                raise ValueError('Soniere escape destination changed')
            file, = (slot['file'] for slot in file_slots if slot['region'] == region and slot['index'] == area)
            dest = f'{Path(file).stem.lower()}_room_{room}'
            x, y = nearest_walkable(grids[ROOM_TO_SRC[dest]], x * 8, y * 8)
            targets.append(len(cmds))
            cmds.append({'kind': 'room_transition', 'destination': dest, 'x': x, 'y': y})
            cmds.append({'kind': 'end_stream'})
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'none',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': cmds},
                [{'program': prog_id, 'command': 0, 'box': 0, 'actor': 'hero'}], [])

    customization = {
        ('/VB5CA.BIN', 3, 5): (0x2A720, 0x2A73A, '2f82fc2447ff0cfdfcfd', 'window_styles', 'Change window appearance'),
        ('/VB5CA.BIN', 3, 4): (0x2A6F8, 0x2A712, '2f82fc2447ff0dfdfcfd', 'sound_themes', 'Choose a sound theme'),
        ('/VB5BA.BIN', 3, 4): (0x2A6AC, 0x2A6C6, '2f82fc41062447ff0dfdfcfd', 'sound_themes', 'Choose a sound theme'),
        ('/VB5A1.BIN', 1, 2): (0x3AC4C, 0x3AC66, '2f82fc462447ff0efdfcfd', 'music_player', 'Browse the music'),
    }.get(key)
    if customization is not None:
        entry, branch, signature, facility, option = customization
        if facility == 'window_styles':
            selector, _ = source('DATA/03_SHIRO/WIN_SEL.BIN')
            sets_match = tuple(struct.iter_unpack('<HBB', selector[0x3DC8:0x3DD8])) == tuple((95 + i, 36, i) for i in range(4))
        elif facility == 'sound_themes':
            selector, _ = source('DATA/03_SHIRO/MEL_SEL.BIN')
            sets_match = (tuple(struct.iter_unpack('<HBB', selector[0x3D1C:0x3D2C])) == tuple((91 + i, 36, 4 + i) for i in range(4))
                          and struct.unpack_from('<5H', selector, 0x3D54) == (0x21, 0x22, 0x23, 0x24, 0x4D))
        else:
            from jukebox_music import playlist_indices
            sets_match = len(playlist_indices()) == 16
        if trigger != 'interaction' or start_pc != entry or not data.startswith(bytes.fromhex(signature), branch) or not sets_match:
            raise ValueError(f'Headquarters customization caller changed: {key}')
        text_id = pool.get_body_text(normalize_choice_tokens([
            make_speaker_tokens(option), make_speaker_tokens('Leave'),
        ], 2))
        commands = [
            {'kind': 'open_box', 'box': 0, 'actor': 'hero', 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
            {'kind': 'wait_boxes'}, {'kind': 'text', 'box': 0, 'text': text_id, 'wait': {'kind': 'text', 'id': text_id}},
            {'kind': 'choice', 'box': 0, 'options': 2}, {'kind': 'close_box', 'box': 0}, {'kind': 'wait_boxes'},
            {'kind': 'branch_choice', 'target': 8}, {'kind': 'service', 'facility': facility}, {'kind': 'end_stream'},
        ]
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'interaction',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': commands},
                [{'program': prog_id, 'command': 0, 'box': 0, 'actor': 'hero'}], [])
    closed_inn = {
        ('/VA3.BIN', 2, 10): (0x2A7EC, 10), ('/VA3.BIN', 2, 26): (0x2A7EC, 10),
        ('/VA3.BIN', 2, 27): (0x2A7EC, 10), ('/VZ3.BIN', 2, 4): (0x29030, 1),
    }.get(key)
    if closed_inn is not None:
        entry, box_actor = closed_inn
        if trigger != 'interaction' or start_pc != entry or not data.startswith(
                bytes((0x17, box_actor, 0x04, 1, 31, 2, 0x18, 0x46, 0x43, 7, 255, 0xfd)), entry):
            raise ValueError('Closed inn interaction changed')
        text_id = pool.get_body_text(make_speaker_tokens('No rooms are available tonight.'))
        commands = [
            {'kind': 'open_box', 'box': 0, 'actor': 'hero', 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
            {'kind': 'wait_boxes'}, {'kind': 'text', 'box': 0, 'text': text_id, 'wait': {'kind': 'text', 'id': text_id}},
            {'kind': 'wait_for_accept'}, {'kind': 'close_box', 'box': 0}, {'kind': 'wait_boxes'}, {'kind': 'end_stream'},
        ]
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'interaction',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': commands},
                [{'program': prog_id, 'command': 0, 'box': 0, 'actor': 'hero'}], [])
    field_recovery = {
        ('/VF3.BIN', 1, 4): (0x480E4, 0x480FA, 0x480FF, 0x4810A, ('Rest', 'Leave', 'Save')),
        ('/VH1.BIN', 1, 5): (0x4978C, 0x497A3, 0x497AF, 0x497AA, ('Leave', 'Save', 'Rest')),
    }.get(key)
    if field_recovery is not None:
        entry, branch, recover, save, options = field_recovery
        if (trigger != 'interaction' or start_pc != entry or not data.startswith(b'\x2f\x83\xfc\xfb', branch)
                or not data.startswith(b'\x4c\x02\x00', recover) or not data.startswith(b'\x43\x07\xff\xfd', save)):
            raise ValueError('Field recovery and save offer changed')
        text_id = pool.get_body_text(normalize_choice_tokens([make_speaker_tokens(option) for option in options], 3))
        targets = []
        commands = [
            {'kind': 'open_box', 'box': 0, 'actor': 'hero', 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
            {'kind': 'wait_boxes'}, {'kind': 'text', 'box': 0, 'text': text_id, 'wait': {'kind': 'text', 'id': text_id}},
            {'kind': 'choice', 'box': 0, 'options': 3}, {'kind': 'close_box', 'box': 0}, {'kind': 'wait_boxes'},
            {'kind': 'branch_choice', 'targets': targets},
        ]
        for index, option in enumerate(options):
            if index:
                targets.append(len(commands))
            if option == 'Rest':
                commands.append({'kind': 'party_restore'})
            elif option == 'Save':
                commands.append({'kind': 'service', 'facility': 'save_point'})
            commands.append({'kind': 'end_stream'})
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'interaction',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': commands},
                [{'program': prog_id, 'command': 0, 'box': 0, 'actor': 'hero'}], [])
    if key == ('/VD4.BIN', 0, 0):
        if (trigger != 'interaction' or start_pc != 0x411A0
                or not data.startswith(b'\x09\xc2\x01', start_pc)
                or not data.startswith(b'\x1c\x01\x00\x0c', 0x41336)
                or not data.startswith(b'\x1c\x00\x00\x11', 0x413D0)):
            raise ValueError('Liukan abduction handoff changed')
        text_id = pool.get_body_text([
            *make_speaker_tokens('Milich took Liukan to prison.'), {'kind': 'newline'},
            *make_speaker_tokens('We should tell Mathiu before'), {'kind': 'newline'},
            *make_speaker_tokens('we attempt a rescue.'),
        ])
        commands = [
            {'kind': 'open_box', 'box': 0, 'actor': 'hero', 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
            {'kind': 'wait_boxes'},
            {'kind': 'text', 'box': 0, 'text': text_id, 'wait': {'kind': 'text', 'id': text_id}},
            {'kind': 'wait_for_accept'}, {'kind': 'close_box', 'box': 0}, {'kind': 'wait_boxes'},
            {'kind': 'story_or', 'flag': {'id': story_id(194), 'mask': 1}},
            {'kind': 'end_stream'},
        ]
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'interaction',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': commands},
                [{'program': prog_id, 'command': 0, 'box': 0, 'actor': 'hero'}], [])
    if key == ('/VB4.BIN', 0, 1):
        required = [35, 17, 2]
        if (trigger != 'ordinary' or start_pc != 0x1ABD8
                or not data.startswith(b'\x09\xc6\x08', start_pc)
                or not data.startswith(b'\x09\xc6\x02', 0x1AE74)
                or any(not data.startswith(bytes((0x3D, 3, member)), site)
                       for site, member in zip((0x1AC0F, 0x1AC77, 0x1ADD0), required, strict=True))):
            raise ValueError('Scarleticia scouting party handoff changed')
        text_id = pool.get_body_text([
            *make_speaker_tokens('We need a way past the pollen.'), {'kind': 'newline'},
            *make_speaker_tokens('Viktor, Flik, and Gremio will'), {'kind': 'newline'},
            *make_speaker_tokens('join the scouting party.'),
        ])
        commands = [
            {'kind': 'story_or', 'flag': {'id': story_id(198), 'mask': 8}},
            {'kind': 'open_box', 'box': 0, 'actor': 'hero', 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
            {'kind': 'wait_boxes'},
            {'kind': 'text', 'box': 0, 'text': text_id, 'wait': {'kind': 'text', 'id': text_id}},
            {'kind': 'wait_for_accept'}, {'kind': 'close_box', 'box': 0}, {'kind': 'wait_boxes'},
        ]
        for member in required:
            commands.extend([
                {'kind': 'party_select', 'parameter': 5, 'index': member, 'required_party': required},
                {'kind': 'party_load', 'character': PARTY_JOIN_NAMES[member]},
            ])
        commands.extend([
            {'kind': 'story_or', 'flag': {'id': story_id(198), 'mask': 2}},
            {'kind': 'end_stream'},
        ])
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'none',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': commands},
                [{'program': prog_id, 'command': 1, 'box': 0, 'actor': 'hero'}], [])
    if key == ('/VB6.BIN', 6, 15):
        if start_pc != 0x351DC or data[0x353E1:0x353EE] != bytes.fromhex('4B 02 0E 02 4A 00 0E 09 11 04 09 11 08'):
            raise ValueError('Kobold Village recruitment and war handoff changed')
        text_id = pool.get_body_text([
            *make_speaker_tokens('Enemy troops are at the fortress.'), {'kind': 'newline'},
            *make_speaker_tokens('Kuromimi and the village guard'), {'kind': 'newline'},
            *make_speaker_tokens('will join your army.'),
        ])
        commands = [
            {'kind': 'open_box', 'box': 0, 'actor': 'hero', 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
            {'kind': 'wait_boxes'},
            {'kind': 'text', 'box': 0, 'text': text_id, 'wait': {'kind': 'text', 'id': text_id}},
            {'kind': 'wait_for_accept'}, {'kind': 'close_box', 'box': 0}, {'kind': 'wait_boxes'},
            {'kind': 'recruit_mark_loaded', 'index': 14},
            {'kind': 'story_or', 'flag': {'id': story_id(17), 'mask': 12}},
            {'kind': 'end_stream'},
        ]
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'none',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': commands},
                [{'program': prog_id, 'command': 0, 'box': 0, 'actor': 'hero'}], [])
    if key == ('/VC6.BIN', 14, 4):
        if (trigger != 'interaction' or start_pc != 0x3E3F8
                or data[0x3E4A3:0x3E4A6] != bytes((9, 19, 8))
                or data[0x3E50C:0x3E50F] != bytes((9, 33, 2))
                or data[0x3E69D:0x3E6A3] != bytes.fromhex('45 19 4B 00 19 1D')):
            raise ValueError('Kwanda resolution and recruitment changed')
        prog_conditions.append({'kind': 'story_mask_set', 'flag': {'id': story_id(19), 'mask': 4}})
        commands, anchors = [], []
        for lines, options in ((('The Black Rune is broken.', 'What will you do with me?'), 0),
                               (('Execute Kwanda', 'Recruit Kwanda'), 2)):
            text_id = pool.get_body_text([*make_speaker_tokens(lines[0]), {'kind': 'newline'}, *make_speaker_tokens(lines[1])])
            anchors.append({'program': prog_id, 'command': len(commands), 'box': 0, 'actor': 'hero'})
            commands.extend([
                {'kind': 'open_box', 'box': 0, 'actor': 'hero', 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
                {'kind': 'wait_boxes'},
                {'kind': 'text', 'box': 0, 'text': text_id, 'wait': {'kind': 'text', 'id': text_id}},
                {'kind': 'choice', 'box': 0, 'options': options} if options else {'kind': 'wait_for_accept'},
                {'kind': 'close_box', 'box': 0}, {'kind': 'wait_boxes'},
            ])
        branch = len(commands)
        x, y = nearest_walkable(grids[(fname, 0)], 248, 384)
        commands.extend([
            {'kind': 'branch_choice', 'target': branch + 3},
            {'kind': 'story_or', 'flag': {'id': story_id(33), 'mask': 2}},
            {'kind': 'jump', 'target': branch + 6},
            {'kind': 'recruit_toggle', 'index': 25},
            {'kind': 'party_load', 'character': 'kwanda'},
            {'kind': 'advance_character', 'character': 'kwanda', 'level_advances': 29},
            {'kind': 'story_or', 'flag': {'id': story_id(19), 'mask': 8}},
            {'kind': 'room_transition', 'destination': AREA_ROOM_ID[fname][0], 'x': x, 'y': y},
        ])
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'interaction',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': commands}, anchors, [])
    is_elevator = (trigger == "ordinary" and fname.startswith("/VB5") and start_pc is not None
                   and data.startswith(b"\x42\x1b\x11\x80\x02", start_pc))
    if trigger == "interaction" and start_pc is not None:
        game = {
            ("/VA2.BIN", 0, 42): (16, b"\x47\xff\x0b", "cup_game"),
            ("/VB5C3.BIN", 0, 11): (13, b"\x47\xff\x0f\xfd", "card_game"),
            ("/VB5C3.BIN", 0, 12): (13, b"\x47\xff\x0b\xfd", "cup_game"),
        }.get(key)
        if game is not None:
            offset, request, facility = game
            if not data.startswith(request, start_pc + offset):
                raise ValueError(f"stale optional-game caller: {key}")
            return ({"id": prog_id, "entry": "ordinary", "entity": ent_idx, "trigger": "interaction",
                     "conditions": prog_conditions, "selection": selection_terms,
                     "commands": [{"kind": "service", "facility": facility}, {"kind": "end_stream"}]}, [], [])
    # Standalone save requests can use Journey's existing save flow. Dialogue and inn callers keep their own flow.
    if (trigger == "interaction" and e["flags"] == 2 and e["id"] == 0 and key not in FORCE_SOURCE_ONLY
            and 0 < e["x_half"] < hw and 0 < e["y_half"] < hh and start_pc is not None
            and data.startswith((b"\x43\x07\xff\xfd", b"\x46\x43\x07\xff\xfd",
                                 b"\x17\x80\x12\x01\x08\x04\x01\x02\x02\x18\x46\x43\x07\xff\xfd"), start_pc)):
        return ({"id": prog_id, "entry": "ordinary", "entity": ent_idx, "trigger": "interaction",
                 "conditions": prog_conditions, "selection": selection_terms,
                 "commands": [{"kind": "service", "facility": "save_point"}, {"kind": "end_stream"}]}, [], [])
    if fname == '/VB3.BIN' and (with_crossing or (rn == 14 and ent_idx in (3, 4))):
        return compile_kouan_start(data, rn, ent_idx, room_id, prog_id, pool, prog_conditions, selection_terms, trigger, room_tracks)
    if (fname, rn) == ('/VB3.BIN', 28) and wheel_sounds is not None:
        if ent_idx in (2, 4):
            return compile_wheel_spin(data, ent_idx, prog_id, pool, prog_conditions, selection_terms, trigger, room_tracks, wheel_sounds)
        if ent_idx == 3:
            return compile_wheel_return(data, prog_id, prog_conditions, selection_terms, trigger, room_tracks)
    if with_crossing and fname in ('/VB5A2.BIN', '/VB5A1.BIN', '/VB5AG.BIN'):
        if (fname, rn, ent_idx) == ('/VB5A2.BIN', 0, 3):
            return compile_headquarters_entry(data, room_id, prog_id, pool, prog_conditions, selection_terms, trigger, room_tracks)
        if (fname, rn, ent_idx) == ('/VB5A2.BIN', 0, 13):
            from export_scripted_travel import hq_mathiu_briefing
            return compile_headquarters_scene(data, room_id, prog_id, pool, prog_conditions, selection_terms,
                                              trigger, room_tracks, hq_mathiu_briefing())
        if (fname, rn, ent_idx) == ('/VB5AG.BIN', 0, 1):
            return compile_headquarters_departure(room_id, prog_id, pool, prog_conditions, selection_terms, trigger)
        from export_scripted_travel import founded_door
        door = founded_door(data, fname, rn, ent_idx)
        if door is None:
            return None
        command = {'kind': 'room_transition', 'destination': door['destination_room'],
                   'x': door['spawn_pixels'][0], 'y': door['spawn_pixels'][1]}
        if not door['target_walkable']:
            command['source_arrival'] = True
        return {'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'none',
                'conditions': prog_conditions, 'selection': selection_terms, 'commands': [command]}, [], []
    gated = key in FORCE_SOURCE_ONLY and key != ("/VB2.BIN", 0, 21)
    if with_crossing and key == ("/VB2.BIN", 0, 21):
        from export_scripted_travel import outputs
        # shortcut: qualify absent boarding-participant queue lifecycles before canonical admission.
        outputs()  # Pin the full source boarding sequence and its compact actor references.
    if with_crossing and key == ("/VB5.BIN", 0, 2):
        if (len(pool.art.get("party_actors", {}).get(room_id, [])) != 4
                or any(f"{room_id}_character_{cid:03d}" not in pool.art.get("actor_clips", {}) for cid in (32, 38))):
            return None
        return compile_dock_arrival(data, room_id, prog_id, pool, prog_conditions, selection_terms, trigger)
    if with_crossing and key == ("/VB7.BIN", 4, 3):
        from export_scripted_travel import hq_entry_music
        entry = hq_entry_music()
        program = dict(entry['program'], id=prog_id, conditions=prog_conditions, selection=selection_terms)
        return program, [], []
    if with_crossing and key == ("/VB7.BIN", 4, 4):
        if any(f'{room_id}_character_{character:03d}' not in pool.art.get('actor_clips', {})
               for character in (27, 32, 3, 35, 1, 2, 118, 26, 38)):
            return None
        from export_scripted_travel import hq_founding
        return compile_headquarters_scene(data, room_id, prog_id, pool, prog_conditions, selection_terms,
                                          trigger, room_tracks, hq_founding())
    if with_crossing and fname in ("/VB5.BIN", "/VB7.BIN"):
        from export_scripted_travel import ruins_door
        door = ruins_door(data, rn, ent_idx, fname)
        if door is None:
            return None
        audio = [request['command'] for request in door['audio_requests']]
        program = {"id": prog_id, "entry": "ordinary", "entity": ent_idx, "trigger": "none",
                   "conditions": prog_conditions, "selection": selection_terms,
                   "commands": [*audio, {"kind": "room_transition", "destination": f"{door['destination_file'][1:-4].lower()}_room_{door['destination']}",
                                 "x": door['spawn_pixels'][0], "y": door['spawn_pixels'][1]}]}
        if not door['target_walkable']:
            program['commands'][-1]['source_arrival'] = True
        return program, [], []
    if with_crossing and fname == "/VB7.BIN":
        return None
    if fname == "/VB5I0.BIN" and rn == 0 and ent_idx in (0, 1):
        import maindec
        from export_scripted_travel import initial_island

        arrival = initial_island(lambda address, size: maindec.body()[address - maindec.MBASE:address - maindec.MBASE + size], maindec.mword)
        expected_trigger = "initialization" if ent_idx == 0 else "ordinary"
        if hashlib.sha256(data).hexdigest() != arrival["source"]["sha256"] or trigger != expected_trigger:
            raise ValueError("unsupported initial island event context")
        program = dict(arrival["initialization_program" if ent_idx == 0 else "ordinary_program"], id=prog_id,
                       conditions=prog_conditions, selection=selection_terms)
        return program, [], []
    is_init = trigger == "initialization"
    if is_init:
        if start_pc is None or selection_terms:
            return None
        if key == ("/VA1.BIN", 0, 41):
            if not data.startswith(b"\x30\x09\x05\x40", start_pc):
                raise ValueError("stale Gregminster escape initializer")
            # shortcut: arm the escape's inn scene while leaving resident staging to the field model.
            return ({"id": prog_id, "entry": "initialization", "entity": ent_idx, "trigger": "none",
                     "conditions": prog_conditions, "selection": [],
                     "commands": [{"kind": "story_or", "flag": {"id": story_id(5), "mask": 64}},
                                  {"kind": "end_stream"}]}, [], [])
        init_cmds = []
        pc_walk = start_pc
        for _ in range(16):
            row = decode_stream(data, start=pc_walk, max_insns=1)
            if not row:
                return None
            _, op, opnd, _ = row[0]
            if op in (0x09, 0x29):
                init_cmds.append({"kind": "story_or" if op == 0x09 else "story_andnot", "flag": {"id": story_id(opnd[0]), "mask": opnd[1]}})
                pc_walk += 1 + len(opnd)
            elif op == 0xFD and init_cmds:
                init_cmds.append({"kind": "end_stream"})
                return ({"id": prog_id, "entry": "initialization", "entity": ent_idx, "trigger": "none",
                         "conditions": prog_conditions, "selection": [], "commands": init_cmds}, [], [])
            else:
                return None
        return None
    if trigger == "interaction" and not inherits_actor(e) and ent_idx not in movable_entities and key not in PLACEMENT_OVERRIDES and not (0 < e["x_half"] < hw and 0 < e["y_half"] < hh):
        return None

    # Default box anchor point
    if key in PLACEMENT_OVERRIDES:
        ax, ay = PLACEMENT_OVERRIDES[key]
    elif 0 < e["x_half"] < hw and 0 < e["y_half"] < hh:
        ax, ay = e["x_half"] * 8, e["y_half"] * 8
    else:
        xs = [t["min"] for t in selection_terms if t["kind"] == "hero_x_inclusive"]
        xs_hi = [t["max"] for t in selection_terms if t["kind"] == "hero_x_inclusive"]
        ys = [t["min"] for t in selection_terms if t["kind"] == "hero_y_inclusive"]
        ys_hi = [t["max"] for t in selection_terms if t["kind"] == "hero_y_inclusive"]
        if xs and ys:
            ax = max(0, min((hw - 1) * 8, ((xs[0] + min(xs_hi[0], hw - 1)) // 2) * 8))
            ay = max(0, min((hh - 1) * 8, ((ys[0] + min(ys_hi[0], hh - 1)) // 2) * 8))
        else:
            ax = max(0, min((hw - 1) * 8, (hw // 2) * 8))
            ay = max(0, min((hh - 1) * 8, (hh // 2) * 8))

    fixed_dice = (fname, rn) == ("/VB2.BIN", 8) and ent_idx in (0, 1)
    from event_script_reachability import callback_cursor

    if fixed_dice:
        if not data.startswith(bytes((0x3D, 0x12, 0x03, 0x02, ent_idx + 1, 0x04, 0x3D, 0x14)), start_pc):
            return None

    # Walk reachable instructions from start_pc
    insns: dict[int, tuple[int, bytes, str, int]] = {}
    party_checks: dict[int, int] = {}
    q = deque([start_pc])
    while q:
        pc = q.popleft()
        if pc in insns or not (0 <= pc < len(data)):
            continue
        row = decode_stream(data, start=pc, max_insns=1)
        if not row:
            continue
        _, op, opnd, note = row[0]
        if op == 0x3D:
            cursor = callback_cursor(data, pc)
            if cursor is not None:
                opnd = data[pc + 1:pc + 2 + cursor['operands']]
                if cursor['target'] == 0x80010394 and len(opnd) == 2:
                    party_checks[pc + 1 + len(opnd)] = opnd[1]
            elif fixed_dice:
                return None
        end = pc + 1 + len(opnd)
        insns[pc] = (op, opnd, note, end)
        if op == 0xFD or "UNKNOWN" in note or "NULL" in note:
            continue
        if op == 0x03:
            if key == ("/VA8.BIN", 10, 3) and opnd == bytes((10, 255, 28)):
                # The off-map reload selects initializer 4 and ordinary scene 5.
                q.append(scene.entities(data, scene.room_record(data, 10))[5]["stream_offsets"][2])
            if opnd and opnd[0] == 252:
                q.append(end)
            continue
        if op == 0x14:
            q.append(pc + 1 + opnd[0])
        elif op == 0x23:
            q.append(pc + 1 - opnd[0])
        elif op == 0x15:
            n = opnd[0]
            for d in (1, *opnd[1:]):
                q.append(pc + n + d)
        elif op == 0x2F:
            if key == ("/VA4.BIN", 10, 10):
                continue
            for t in switch_2f_targets(data, pc).values():
                q.append(t)
        elif op == 0x2D:
            f = data.rfind(bytes(opnd), 0, pc + 1)
            if f >= 0:
                q.append(f + 1)
        elif op == 0x2E:
            f = data.find(bytes(opnd), pc + 2)
            if f >= 0:
                q.append(f + 1)
        else:
            q.append(end)

    if not insns:
        return None
    if len(insns) == 1 and next(iter(insns.values()))[0] == 0xFD:
        return None
    has_camera_push = any(op == 0x21 for op, _, _, _ in insns.values())
    if has_camera_push and any(op == 0x30 for op, _, _, _ in insns.values()):
        return None
    has_stay_6 = any(op == 0x43 and opnd and opnd[0] == 6 for op, opnd, _, _ in insns.values())
    has_save_7 = any(op == 0x43 and opnd == b"\x07\xff" for op, opnd, _, _ in insns.values())
    is_inn = has_stay_6 or (has_save_7 and any(op == 0x09 for op, _, _, _ in insns.values()))
    if has_save_7 and not is_inn:
        return None
    from export_route_battles import scripted_encounter
    war_scenario_ids = (
        "pannu_yakuta",
        "garan",
        "scarleticia_pollen",
        "scarleticia_antidote",
        "teo_before_fire_spear",
        "teo_fire_spear",
        "northern_checkpoint",
        "shasarazade",
        "gregminster",
    )
    battle_ids = {}
    section = scene.section_off(data, scene.room_record(data, rn)["section"])
    battle_source = data
    if fname == "/VC6.BIN" and any(op == 0x47 and opnd and opnd[0] < 0xFE for op, opnd, _, _ in insns.values()):
        vc61_data, _ = source("DATA/06_AREA.C/VC61.BIN")
        battle_source = data + vc61_data
    for pc, (op, operands, _, _) in insns.items():
        if op != 0x47:
            continue
        if operands[0] >= 0xFE:
            # shortcut: only the existing dragon-flight transition adapter and MAIN selector 0..8 war battles are qualified.
            if list(operands) == [0xFF, 9]:
                continue
            if len(operands) == 2 and operands[0] == 0xFF and operands[1] < len(war_scenario_ids):
                battle_ids[pc] = f"war:{war_scenario_ids[operands[1]]}"
                continue
            return None
        encounter = scripted_encounter(battle_source, section, operands[0], fname, battle_data)
        if encounter is None:
            return None
        battle_ids[pc] = encounter
    if combat_party is None:
        combat_party = materializable_party_ids(battle_data)
    for op, opnd, _, _ in insns.values():
        if op == 0x3C and opnd and PARTY_JOIN_NAMES.get(opnd[0]) not in combat_party:
            return None
        if op == 0x4B and len(opnd) >= 2 and opnd[0] == 0 and PARTY_JOIN_NAMES.get(opnd[1]) not in combat_party:
            return None
        if op == 0x20 and not (with_crossing and key == ("/VB7.BIN", 4, 4) and opnd == b"\xff") and opnd:
            cid = opnd[1] if opnd[0] in (0xFC, 0xFE) and len(opnd) >= 2 else opnd[0]
            if cid in PARTY_JOIN_NAMES and PARTY_JOIN_NAMES[cid] not in combat_party:
                return None
    for op, opnd, _, _ in insns.values():
        if op != 0x49:
            continue
        if not opnd:
            return None
        if opnd[0] == 0xFD:
            if len(opnd) != 2 or opnd[1] not in SHARED_KEY_ITEM_IDS or opnd[1] not in RUNTIME_ITEM_BINDINGS:
                return None
        elif opnd[0] < 0xFD and opnd[0] not in RUNTIME_ITEM_BINDINGS:
            return None

    ordered_pcs = sorted(insns)
    # Pre-scan direct warp and special opcodes
    has_unexported_warp = False
    for pc in ordered_pcs:
        op, opnd, _, _ = insns[pc]
        if op == 0x03:
            if len(opnd) == 3 and opnd[0] < 128 and opnd[0] not in AREA_ROOM_ID[fname]:
                has_unexported_warp = True
            elif len(opnd) == 5 and opnd[0] == 252:
                if (key == ("/VAC.BIN", 15, 0) and opnd == bytes((252, 9, 0, 0, 0))) or (
                    key == ("/VAD.BIN", 9, 8) and opnd == bytes((252, 12, 0, 29, 18))
                ) or (
                    final_dock_return and pc == 0x49030 and opnd == b'\xfc\x1a\x05\xff\xff'
                ):
                    continue
                dest = cross_area_room(fname, opnd[1], opnd[2], file_slots)
                if dest not in ROOM_TO_SRC or (
                    world_entries and not is_elevator and not (fname == "/VI1.BIN" and dest == "vi2_room_0" and opnd[1] == 1) and not any(
                        entry['area'] == dest.split('_room_', 1)[0] and entry['point'] == opnd[1]
                        for entry in world_entries
                    )
                ):
                    has_unexported_warp = True
            elif opnd and opnd[0] == 255:
                if not any(entry['area'] == fname[1:-4].lower() for entry in world_entries):
                    has_unexported_warp = True
            elif opnd and opnd[0] == 254:
                if retained_world_return(opnd, world_regions or {}, grids, fname, file_slots) is None:
                    has_unexported_warp = True
            elif opnd and opnd[0] == 251 and key != ("/VB2.BIN", 0, 21):
                if explicit_world_target(opnd, world_regions or {}, grids) is None:
                    has_unexported_warp = True
    if has_unexported_warp and not kouan_welcome:
        return None

    def clamped_spawn_xy(dest_room: str, rx: int, ry: int) -> tuple[int, int]:
        grid = grids[ROOM_TO_SRC[dest_room]]
        w, h, _ = grid
        px = w * 4 if rx >= 254 else rx * 8
        py = h * 4 if ry >= 254 else ry * 8
        return nearest_walkable(grid, px, py)

    def castle_tier_fd_targets(opnd: bytes) -> list[tuple[str, int, int, int]] | None:
        if len(opnd) != 5 or opnd[0] != 0xFD or not file_slots:
            return None
        import maindec
        delta, room, x, y = opnd[1:]
        stage_bases = maindec.mword(0x801716D8).to_bytes(4, 'little')
        resolved: list[tuple[str, int, int, int]] = []
        for base in stage_bases[1:3]:
            point = base + delta
            matches = [slot['file'] for slot in file_slots if slot['region'] == 1 and slot['index'] == point]
            if len(matches) != 1:
                return None
            destination = f'{Path(matches[0]).stem.lower()}_room_{room}'
            if destination not in ROOM_TO_SRC or ROOM_TO_SRC[destination] not in grids:
                return None
            resolved.append((destination, point, x, y))
        return resolved

    fa_dests: set[str] = set()
    fa_valid = False
    if kasumi_dismiss is None and duel_return_site is None and file_slots:
        fa_ops = [opnd for pc in ordered_pcs for op, opnd, _, _ in (insns[pc],) if op == 0x03 and len(opnd) == 6 and opnd[0] == 0xFA]
        if fa_ops:
            fa_valid = True
            for opnd in fa_ops:
                region, point, room = opnd[1], opnd[2], opnd[3]
                matches = [slot['file'] for slot in file_slots if slot['region'] == region and slot['index'] == point]
                if len(matches) != 1 or region not in (world_regions or {}):
                    fa_valid = False
                    break
                dest = f'{Path(matches[0]).stem.lower()}_room_{room}'
                if dest not in ROOM_TO_SRC or ROOM_TO_SRC[dest] not in grids:
                    fa_valid = False
                    break
                fa_dests.add(dest)
            if len(fa_dests) != 1:
                fa_valid = False
    fa_single_dest = next(iter(fa_dests)) if fa_valid else None

    # Calculate fallback align_hero if this program has a non-advancing coordinate_range exit
    coord_xs = []
    coord_ys = []
    for t in selection_terms:
        if t["kind"] == "hero_x_inclusive":
            coord_xs = [t["min"], t["max"]]
        elif t["kind"] == "hero_y_inclusive":
            coord_ys = [t["min"], t["max"]]
    # A flag-only event that closes its own gate can leave the party in place.
    closes_gate = all(op in (0x09, 0xFD) for op, _, _, _ in insns.values()) and any(
        condition['kind'] == 'story_mask_clear' and condition['flag']['id'] == story_id(operands[0])
        and condition['flag']['mask'] & operands[1]
        for op, operands, _, _ in insns.values() if op == 0x09
        for condition in prog_conditions
    )
    safe_escape_xy = None
    # The Region C audience and Lorimar gatehouse scenes already close their gates inside the courtyard.
    if closes_gate or has_camera_push or vault_conveyor or (vault_lock and 5 <= ent_idx <= 14) or (battle_ids and fname != "/VA2.BIN") or key in (("/VC4.BIN", 11, 4), ("/VE4.BIN", 0, 0), ("/VE4.BIN", 0, 5)):
        safe_escape_xy = None
    elif key in (("/VI2.BIN", 0, 0), ("/VE2.BIN", 22, 4)):
        # These scenes move the hero clear of the trigger before returning control.
        offset, placement = ((0x41763, '07 80 01 2c 07 80 02 1e') if fname == '/VI2.BIN'
                             else (0x46FC3, '10 13 2a 10 13 2a'))
        if not data.startswith(bytes.fromhex(placement), offset):
            raise ValueError('Scripted hero relocation changed')
    elif (fname, rn) == ('/VB5B4.BIN', 3) and ent_idx in (6, 7, 8):
        # The briefing hands off at the bed and the morning scene moves the hero to the door.
        offset, placement = {
            6: (0x2A031, b'\x10\x17\x0c'),
            7: (0x2A0DC, bytes.fromhex('07 80 01 05 07 80 02 0b')),
            8: (0x2A104, bytes.fromhex('07 80 01 05 07 80 02 0b')),
        }[ent_idx]
        if not data.startswith(placement, offset):
            raise ValueError('Moravia briefing hero placement changed')
    elif key == ("/VA6.BIN", 0, 3):
        safe_escape_xy = (248, 136)
    elif key == ("/VA6.BIN", 0, 4):
        safe_escape_xy = (248, 184)
    elif fname != "/VA3.BIN" and key not in (("/VA8.BIN", 10, 3), ("/VA5.BIN", 1, 0)) and (coord_xs or coord_ys):
        safe_escape_xy = outside_box_walkable(grids[(fname, rn)], coord_xs, coord_ys)

    # Identify jump targets for labels
    jump_targets: set[int] = set()
    for pc in ordered_pcs:
        op, opnd, _, _ = insns[pc]
        if op == 0x14:
            jump_targets.add(pc + 1 + opnd[0])
        elif op == 0x23:
            jump_targets.add(pc + 1 - opnd[0])
        elif op == 0x15:
            for d in (1, *opnd[1:]):
                jump_targets.add(pc + opnd[0] + d)
        elif op == 0x2F:
            jump_targets.update(switch_2f_targets(data, pc).values())
        elif op == 0x2D:
            f = data.rfind(bytes(opnd), 0, pc + 1)
            if f >= 0:
                jump_targets.add(f + 1)
        elif op == 0x2E:
            f = data.find(bytes(opnd), pc + 2)
            if f >= 0:
                jump_targets.add(f + 1)

    # Group consecutive opcode patterns cleanly by walking ordered_pcs index
    cmds: list[dict] = []
    anchors: list[dict] = []
    prefixes: list[dict] = []
    pc_to_cmd_idx: dict[int, int] = {}
    pending_jumps: list[tuple[int, int, str]] = []  # (cmd_idx, target_pc, field)
    pending_transition_tails: list[int] = []  # commands that terminate via shared room_transition at end

    speaker_cid: int | None = None
    pending_choice_texts: list[tuple[int, list[dict], int | None]] = []
    pending_chest_grants: list[tuple[int, str, int]] = []  # (cmd_idx, runtime_id, source_id)
    pending_chest_flag: dict | None = None
    active_overload_item: str | None = None
    acquisition_messages: dict[int, int] = {}
    failure_messages: dict[int, int] = {}

    def emit_dialogue(tokens: list[dict], spk_cid: int | None, is_choice: int | None = None, *, anchor_actor: str | None = None) -> None:
        anchor_idx = len(cmds)
        cmds.append({"kind": "open_box", "box": 0, **({"actor": anchor_actor} if anchor_actor else {"layout": 0}),
                     "requires": {"kind": "box_closed", "id": "box_0"}})
        anchors.append({"program": prog_id, "command": anchor_idx, "box": 0,
                        **({"actor": anchor_actor} if anchor_actor else {"point": {"x": ax, "y": ay}})})
        cmds.append({"kind": "wait_boxes"})
        img_idx = pool.get_image(spk_cid) if (spk_cid is not None and spk_cid != 8) else None
        spk_name = SPEAKER_NAMES.get(spk_cid) if spk_cid is not None else None
        if img_idx is not None or spk_name is not None:
            spk_cmd_idx = len(cmds)
            spk_text_id = pool.get_speaker_text(spk_name) if spk_name else None
            # Defer prefix text numeric resolution until pool finalized (store text_id tag on temporary field)
            cmd_obj: dict = {"kind": "start_or_wait_dialogue", "box": 0, "code": spk_cid or 0}
            if spk_text_id is not None:
                cmd_obj["wait"] = {"kind": "speaker_prefix", "id": "box_0"}
            cmds.append(cmd_obj)
            pfx = {"program": prog_id, "command": spk_cmd_idx, "box": 0, "_text_id": spk_text_id}
            if img_idx is not None:
                pfx["image"] = img_idx
            else:
                pfx["absent_character"] = 255
            prefixes.append(pfx)
        text_id = pool.get_body_text(tokens)
        cmds.append({"kind": "text", "box": 0, "text": text_id, "wait": {"kind": "text", "id": text_id}})
        if is_choice is not None:
            cmds.append({"kind": "choice", "box": 0, "options": is_choice})
            cmds.append({"kind": "close_box", "box": 0})
            cmds.append({"kind": "wait_boxes"})
        else:
            cmds.append({"kind": "wait_for_accept"})
            cmds.append({"kind": "close_box", "box": 0})
            cmds.append({"kind": "wait_boxes"})

    def emit_acquisition(source_id: int) -> None:
        import item_tables
        emit_dialogue(decode_text_tokens(item_tables.acquisition_message(source_id), 0), None, anchor_actor="hero")

    def flush_pending_choices(n_opts: int | None = None) -> None:
        if not pending_choice_texts:
            return
        if n_opts is None:
            for _, toks, cid in pending_choice_texts:
                if toks:
                    emit_dialogue(toks, cid, None)
        else:
            last_cid = pending_choice_texts[-1][2] or speaker_cid
            merged = normalize_choice_tokens(
                [toks for _, toks, _ in pending_choice_texts],
                n_opts,
                is_inn=is_inn,
            )
            emit_dialogue(merged, last_cid, n_opts)
        pending_choice_texts.clear()

    def align_hero_cmd(xy: tuple[int, int]) -> dict:
        return {"kind": "align_hero", "x": xy[0], "y": xy[1], "wait": {"kind": "alignment", "id": "alignment"}}

    if (fname, rn) == ('/VD5.BIN', 1) and ent_idx in (13, 14):
        opening = ent_idx == 13
        sites = (0x4aee9, 0x4aef4) if opening else (0x4af0c, 0x4af17)
        # Finish the southbound crossing before closing the passage behind the party.
        if not opening:
            cmds.append(align_hero_cmd((72, 456)))
        cmds.extend([{'kind': 'continue_tick'},
                     {'kind': 'story_or' if opening else 'story_andnot',
                      'flag': {'id': story_id(196), 'mask': 8}}])
        for site in sites:
            cmds.extend(scenery_swap(data, site, scenery_model))
        cmds.extend([{'kind': 'yield_tick'}, {'kind': 'end_stream'}])
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx, 'trigger': 'none',
                 'conditions': prog_conditions, 'selection': selection_terms, 'commands': cmds}, anchors, prefixes)

    if vault_lock and ent_idx in (2, 5, 10, 15):
        solution = (0, 1, 1, 0, 1, 0, 0, 1)
        if ent_idx == 2:
            clue = []
            for start in (0, 4):
                if clue:
                    clue.append({'kind': 'newline'})
                clue.extend(make_speaker_tokens(' '.join(('Left', 'Right')[plate] for plate in solution[start:start + 4])))
            clue.extend([{'kind': 'newline'}, *make_speaker_tokens('A wrong step resets the lock.')])
            emit_dialogue(clue, None, anchor_actor='hero')
        else:
            cmds.append({'kind': 'continue_tick'})
            if ent_idx in (5, 10):
                cmds.append({'kind': 'sequence_input', 'flag': {'id': story_id(23), 'mask': 255},
                             'parameter': sum(plate << step for step, plate in enumerate(solution)), 'value': int(ent_idx == 10)})
                mask = 2
            else:
                if scenery_model is None:
                    raise ValueError('Vault sequence lock requires the room scenery model')
                gate = scenery_model['initial_count'] + 10
                assert gate < len(scenery_model['objects'])
                cmds.append({'kind': 'scenery_stage', 'scenery_object': gate})
                mask = 4
            cmds.append({'kind': 'story_or', 'flag': {'id': story_id(22), 'mask': mask}})
        cmds.append({'kind': 'end_stream'})
        return ({'id': prog_id, 'entry': 'ordinary', 'entity': ent_idx,
                 'trigger': 'interaction' if ent_idx == 2 else 'none', 'conditions': prog_conditions,
                 'selection': selection_terms, 'commands': cmds}, anchors, prefixes)

    if kouan_welcome:
        # The welcome takes place in the existing hall. Its later encounter owns the roster change.
        if start_pc != 0x3A92C or data[0x3AA17:0x3AA1C] != bytes.fromhex("09 13 10 20 ff"):
            raise ValueError("post-Kouan welcome state changed")
        emit_dialogue(make_speaker_tokens("Our new allies are here. Shall we welcome them over dinner?"), 27,
                      anchor_actor="hero")
        options = normalize_choice_tokens([make_speaker_tokens("Let's celebrate."),
                                           make_speaker_tokens("Is this a good time?")], 2)
        emit_dialogue(options, None, 2, anchor_actor="hero")
        cmds.extend([
            {"kind": "story_or", "flag": {"id": story_id(19), "mask": 16}},
            {"kind": "end_stream"},
        ])
        return ({"id": prog_id, "entry": "ordinary", "entity": ent_idx, "trigger": "none",
                 "conditions": prog_conditions, "selection": selection_terms, "commands": cmds}, anchors, prefixes)

    idx_in_order = 0
    while idx_in_order < len(ordered_pcs):
        pc = ordered_pcs[idx_in_order]
        op, opnd, note, end = insns[pc]
        if pc in jump_targets:
            flush_pending_choices(None)
            pc_to_cmd_idx[pc] = len(cmds)
            cmds.append({"kind": "label"})
        else:
            pc_to_cmd_idx[pc] = len(cmds)

        if pc in failure_messages:
            emit_acquisition(failure_messages[pc])

        if op == 0x07 and len(opnd) == 3 and opnd[:2] == b"\x80\x01" and end in insns:
            next_op, next_args, _, _ = insns[end]
            if next_op == 0x07 and len(next_args) == 3 and next_args[:2] == b"\x80\x02":
                hx, hy = opnd[2], next_args[2]
                # shortcut: keep the flight's grounded arrival until the landing has playable movement.
                landing = key == ("/VAA.BIN", 0, 25)
                if not landing and 0 <= hx < hw and 0 <= hy < hh and grids[(fname, rn)][2][hy * hw + hx] == "1":
                    flush_pending_choices(None)
                    cmds.append({"kind": "place_hero", "x": hx * 8, "y": hy * 8})
        elif (fname, rn) == ('/VD5.BIN', 7) and pc == {
            0: 0x4b004, 2: 0x4b067, 5: 0x4b0a3, 8: 0x4b0df, 11: 0x4b11b,
        }.get(ent_idx):
            cmds.extend(scenery_swap(data, pc, scenery_model))
        elif (fname, rn) == ('/VE4.BIN', 0) and ent_idx == 0 and pc == 0x2BBDA:
            cmds.extend(scenery_swap(data, pc, scenery_model))
        elif key == ('/VE3.BIN', 5, 3) and pc == 0x5BEE0:
            cmds.extend(scenery_swap(data, pc, scenery_model))
        elif op == 0x0F and key == ("/VE2.BIN", 0, 0) and pc == 0x468E1:
            if opnd != b'\x00' or scenery_model is None or scenery_model['initial_count'] == 0:
                raise ValueError('Cave gate scenery staging changed')
            cmds.append({'kind': 'scenery_stage', 'scenery_object': opnd[0]})
        elif has_camera_push and op == 0x11 and len(opnd) == 2 and opnd[0] == 0x80 and opnd[1] <= 3:
            from maindec import mword
            cmds.append({'kind': 'actor_transition', 'actor': 'hero', 'transition': mword(0x80171B98 + 4 * opnd[1])})
        elif op == 0x21:
            from field_camera_push import request, VERIFIED_RECORDS
            if len(opnd) != 2 or opnd[0] >= VERIFIED_RECORDS:
                return None
            cmds.append({'kind': 'camera_push', 'push': request(opnd[0], opnd[1]),
                         'wait': {'kind': 'camera_push', 'id': 'camera_push'}})
        elif key == ("/VB2.BIN", 0, 21) and op == 0x32:
            actor = {3: "vb2_room_0_actor_21_032", 4: "vb2_room_0_actor_22_038", 128: "hero"}[opnd[0]]
            track_id = f"{prog_id}_boarding_{opnd[0]}"
            room_tracks.append({"id": track_id, "actor": actor, "commands": opening_audience.track(opnd[1:])})
            cmds.append({"kind": "queue_track", "track": track_id})
        elif key == ("/VB2.BIN", 0, 21) and op == 0x33:
            cmds.append({"kind": "wait_tracks"})
        elif op == 0x0a and len(opnd) == 1:
            flush_pending_choices(None)
            if opnd[0] > 0:
                cmds.append({"kind": "delay", "updates": opnd[0] * 5, "wait": {"kind": "delay", "id": "delay"}})
        elif op == 0x24:
            flush_pending_choices(None)
            cmds.append({"kind": "fade_out", "blend_mode": 2, "draw_slot": 10, "wait": {"kind": "fade", "id": "fade"}})
        elif op == 0x25:
            flush_pending_choices(None)
            cmds.append({"kind": "fade_in", "wait": {"kind": "fade", "id": "fade"}})
        elif op == 0x4e and (key == ("/VB2.BIN", 0, 21) or (flight is not None and pc == flight[0] + 2)):
            cmds.append({"kind": "auto_route", "value": opnd[0]})
        elif gregminster_muster is not None and op == 0x32 and opnd[0] == 0x80:
            # The arrival track starts south of the walkable map and crosses its boundary.
            init = entities[14]['stream_offsets'][2]
            placement = data[init + 1:init + 9]
            if (placement[:3] != b'\x07\x80\x01' or placement[4:7] != b'\x07\x80\x02'
                    or len(opnd) != 4 or opnd[1] != 0 or opnd[3] != 5):
                raise ValueError('Gregminster arrival staging changed')
            x, y = placement[3] * 8, (placement[7] - opnd[2]) * 8
            if nearest_walkable(grids[(fname, rn)], x, y) != (x, y):
                raise ValueError('Gregminster arrival track must finish on the street')
            cmds.append(align_hero_cmd((x, y)))
        elif op == 0x32 and opnd[0] == 0x80 and (vault_conveyor or fname == "/VA3.BIN" and rn in (1, 2)):
            track_id = f"{prog_id}_hero_track_{pc:05x}"
            room_tracks.append({"id": track_id, "actor": "hero", "commands": opening_audience.track(opnd[1:])})
            cmds.extend([{"kind": "queue_track", "track": track_id}, {"kind": "wait_tracks"}])
        elif op == 0x10 and len(opnd) == 2:
            # shortcut: the last step into the clock needs the moving scenery collision.
            if (key != ("/VA3.BIN", 2, 9) or opnd != bytes((56, 8))) and 0 <= opnd[0] < hw and 0 <= opnd[1] < hh and grids[(fname, rn)][2][opnd[1] * hw + opnd[0]] == "1":
                flush_pending_choices(None)
                cmds.append(align_hero_cmd((opnd[0] * 8, opnd[1] * 8)))
        elif (op == 0x07 and len(opnd) == 3 and opnd[0] < 0x40 and opnd[1] == 1 and entities is not None
              and (key == ("/VA1.BIN", 1, 32)
                   or (key == ("/VB3.BIN", 9, 8) and pc in (0x42A74, 0x42A7C))
                   or (key == ("/VI1.BIN", 0, 4) and pc == 0x39769))):
            next_op, next_args, _, _ = insns[end]
            assert next_op == 0x07 and next_args[:2] == bytes((opnd[0], 2))
            actor_idx = actor_allocation_order(entities)[opnd[0]]
            actor_cid = entities[actor_idx]["id"]
            cmds.append({"kind": "place_actor", "actor": f"{room_id}_actor_{actor_idx:02d}_{actor_cid:03d}", "x": opnd[2] * 8, "y": next_args[2] * 8})
        elif op == 0x12:
            speaker_cid = opnd[1]
            if speaker_cid == 0:
                speaker_cid = None
        elif op in (0x0B, 0x17):
            # Look ahead cleanly: 0x0B/0x17 without 0x12 before text might reset speaker if not Soldier
            if opnd[0] == 128:
                speaker_cid = None
        elif op in (0x04, 0x1C):
            if op == 0x04:
                if rt_off is None:
                    return None
                ptr = scene.ptr_at(data, rt_off + 4 * opnd[1])
            else:
                if t_arr_off is None:
                    return None
                tp = scene.ptr_at(data, t_arr_off + 4 * opnd[1])
                ptr = scene.ptr_at(data, tp + 4 * opnd[2]) if tp is not None else None
            if ptr is None:
                return None
            # Peek forward to see if a 0x05 choice follows before control flow
            look = idx_in_order + 1
            is_choice_option = False
            while look < len(ordered_pcs):
                npc = ordered_pcs[look]
                if npc in jump_targets:
                    break
                nop = insns[npc][0]
                if nop in (0x04, 0x1C, 0x0B, 0x17, 0x12):
                    look += 1
                    continue
                if nop == 0x05:
                    is_choice_option = True
                break
            try:
                toks = decode_text_tokens(data, ptr, strip_for_choice=is_choice_option)
            except ValueError as ex:
                if "unsupported audience " in str(ex):
                    return None
                raise
            if toks:
                if is_choice_option:
                    pending_choice_texts.append((opnd[0], toks, speaker_cid))
                else:
                    flush_pending_choices(None)
                    emit_dialogue(toks, speaker_cid, None)
        elif op == 0x05:
            n_opts = min(opnd[1], 2) if is_inn else opnd[1]
            if pending_choice_texts and not (1 <= n_opts <= 4):
                return None
            flush_pending_choices(None if n_opts == 1 else n_opts)
        elif op == 0x2F:
            flush_pending_choices(None)
            if key == ("/VA4.BIN", 10, 10):
                cmds.append({"kind": "end_stream"})
                break
            targets = switch_2f_targets(data, pc)
            ordered_modes = sorted(targets)
            if dragon_return and pc == 0x47EF1:
                cursor = callback_cursor(data, pc - 2)
                if cursor is None or cursor['target'] != 0x80012008 or ordered_modes != [1, 2, 3, 4]:
                    raise ValueError('Dragon return castle-tier check changed')
                branch = len(cmds)
                cmds.append({'kind': 'branch_castle_tier', 'targets': [0, 0, 0]})
                pending_jumps.extend((branch, targets[mode], f'targets:{slot}')
                                     for slot, mode in enumerate((2, 3, 4)))
                idx_in_order += 1
                continue
            if pc in party_checks:
                if ordered_modes != [1, 2]:
                    return None
                branch = len(cmds)
                cmds.append({'kind': 'branch_party', 'index': party_checks[pc], 'targets': [0, 0]})
                pending_jumps.extend((branch, targets[mode], f'targets:{slot}')
                                     for slot, mode in enumerate((2, 1)))
                idx_in_order += 1
                continue
            if pending_chest_grants and ordered_modes != [0, 1]:
                return None
            if pending_chest_grants and len(ordered_modes) == 2 and ordered_modes == [0, 1]:
                grant_idx, grant_id, _ = pending_chest_grants.pop()
                active_overload_item = grant_id
                if grant_idx in acquisition_messages:
                    item_id = acquisition_messages[grant_idx]
                    if targets[0] in failure_messages and failure_messages[targets[0]] != item_id:
                        return None
                    # Both grant outcomes show the source message before testing UI result.
                    if targets[0] <= pc:
                        return None
                    failure_messages[targets[0]] = item_id
                pending_jumps.append((grant_idx, targets[0], "failure_target"))
                j_idx = len(cmds)
                cmds.append({"kind": "jump", "target": 0})
                pending_jumps.append((j_idx, targets[1], "target"))
                idx_in_order += 1
                continue
            if is_inn:
                arm_pcs = [targets[ordered_modes[0]], targets[ordered_modes[1]]]
            else:
                arm_pcs = [targets[m] for m in ordered_modes]
            if not (2 <= len(arm_pcs) <= 4):
                return None
            # Emit branch_choice + fallthrough jump to arm 0
            bc_idx = len(cmds)
            if len(arm_pcs) == 2:
                cmds.append({"kind": "branch_choice", "target": 0})
                pending_jumps.append((bc_idx, arm_pcs[1], "target"))
            else:
                cmds.append({"kind": "branch_choice", "targets": [0] * (len(arm_pcs) - 1)})
                for slot, apc in enumerate(arm_pcs[1:]):
                    pending_jumps.append((bc_idx, apc, f"targets:{slot}"))
            if end != arm_pcs[0]:
                j_idx = len(cmds)
                cmds.append({"kind": "jump", "target": 0})
                pending_jumps.append((j_idx, arm_pcs[0], "target"))
        elif op == 0x2E:
            flush_pending_choices(None)
            tpc = data.find(bytes(opnd), pc + 2) + 1
            j_idx = len(cmds)
            cmds.append({"kind": "jump", "target": 0})
            pending_jumps.append((j_idx, tpc, "target"))
        elif op == 0x2D:
            flush_pending_choices(None)
            tpc = data.rfind(bytes(opnd), 0, pc + 1) + 1
            j_idx = len(cmds)
            cmds.append({"kind": "jump", "target": 0})
            pending_jumps.append((j_idx, tpc, "target"))
        elif op == 0x14:
            flush_pending_choices(None)
            j_idx = len(cmds)
            cmds.append({"kind": "jump", "target": 0})
            pending_jumps.append((j_idx, pc + 1 + opnd[0], "target"))
        elif op == 0x23:
            flush_pending_choices(None)
            j_idx = len(cmds)
            cmds.append({"kind": "jump", "target": 0})
            pending_jumps.append((j_idx, pc + 1 - opnd[0], "target"))
        elif op == 0x09:
            flush_pending_choices(None)
            next_pc = end
            # The sound request does not change the pending item or scenario mask.
            if next_pc in insns and insns[next_pc][0] == 0x41 and e["flags"] & 0x20:
                flag = {"id": story_id(opnd[0]), "mask": opnd[1]}
                try:
                    classification, _ = decode_predicate(data, e['stream_offsets'][0], 'classification', full=True)
                except ReservedActorPredicate:
                    return None
                closed = {"kind": "story_mask_clear", "flag": flag}
                if closed in prog_conditions and closed in classification['terms']:
                    next_pc = insns[next_pc][3]
            next_op = insns[next_pc][0] if next_pc in insns else None
            if next_op == 0x49 and insns[next_pc][1][0] < 253:
                pending_chest_flag = {"id": story_id(opnd[0]), "mask": opnd[1]}
            else:
                cmds.append({"kind": "story_or", "flag": {"id": story_id(opnd[0]), "mask": opnd[1]}})
        elif op == 0x29:
            flush_pending_choices(None)
            cmds.append({"kind": "story_andnot", "flag": {"id": story_id(opnd[0]), "mask": opnd[1]}})
        elif op == 0x3F and (fname, rn) == ('/VC3.BIN', 5) and 2 <= ent_idx <= 7 and opnd[0] < 11 and opnd[1] in (0, 1):
            if scenery_model is None:
                return None
            flush_pending_choices(None)
            cmds.append({'kind': 'scenery_stage' if opnd[1] else 'scenery_restore',
                         'scenery_object': scenery_model['initial_count'] + opnd[0]})
        elif op == 0x3C:
            flush_pending_choices(None)
            member = PARTY_JOIN_NAMES[opnd[0]]
            cmds.append({"kind": "party_join", "character": member})
        elif op == 0x45 and len(opnd) == 1 and opnd[0] < 108:
            flush_pending_choices(None)
            cmds.append({"kind": "recruit_toggle", "index": opnd[0]})
        elif op == 0x45 and (
            (key in (('/VB5B3.BIN', 0, 24), ('/VB5C4.BIN', 0, 29)) and opnd in (b'\xff\x43', b'\xff\x14'))
            or (key == ('/VF3.BIN', 2, 9) and pc == 0x4860F and opnd == b'\xff\x1d')
        ):
            flush_pending_choices(None)
            cmds.append({'kind': 'recruit_toggle', 'index': opnd[1], 'mask': 1})
        elif op == 0x4B:
            # shortcut: qualify each legacy load boundary before replacing its combined join/growth lowering with IR10.
            flush_pending_choices(None)
            if valeria_recruit and pc == 0x2708B:
                cmds.append({'kind': 'advance_character', 'character': 'valeria',
                             'level_advances': opnd[2], 'add_hero_level': True})
            elif opnd[0] == 0:
                member = PARTY_JOIN_NAMES[opnd[1]]
                growth = {
                    ('/VB3.BIN', 9, 1, 0x42C3F): b'\x00\x0c\x0f',
                    ('/VB3.BIN', 9, 1, 0x42C45): b'\x00\x1f\x0d',
                    ('/VB3.BIN', 9, 3, 0x42B58): b'\x00\x00\x0c',
                    ('/VB3.BIN', 9, 3, 0x42B60): b'\x00\x0f\x06',
                    ('/VB3.BIN', 20, 8, 0x432D6): b'\x00\x27\x09',
                    ('/VB4.BIN', 0, 12, 0x1AF7F): b'\x00\x44\x15',
                    ('/VB5.BIN', 0, 2, 0x1B25): b'\x00\x20\x09',
                    ('/VB5G.BIN', 1, 2, 0x2D85): b'\x00\x26\x08',
                    ('/VB7.BIN', 4, 4, 0x229): b'\x00\x1a\x0b',
                    ('/VD1.BIN', 1, 0, 0x4B14D): b'\x00\x2d\x10',
                    ('/VB5B3.BIN', 0, 51, 0x2ED85): b'\x00\x07\x12',
                    ('/VB5C4.BIN', 0, 61, 0x3C929): b'\x00\x07\x12',
                    ('/VD6.BIN', 0, 0, 0x47B65): b'\x00\x1c\x1f',
                    ('/VD6.BIN', 0, 1, 0x47EF0): b'\x00\x1c\x1f',
                    ('/VE2.BIN', 1, 0, 0x46B16): b'\x00\x12\x12',
                    ('/VB5B3.BIN', 0, 84, 0x2F261): b'\x00\x17\x25',
                    ('/VB5C4.BIN', 0, 95, 0x3CDF9): b'\x00\x17\x25',
                }.get((*key, pc))
                reserve_growth = {
                    ('/VB6.BIN', 6, 10, 0x356C2): b'\x00\x15\x16',
                    ('/VC6.BIN', 0, 8, 0x3D66F): b'\x00\x09\x0b',
                    ('/VC6.BIN', 0, 8, 0x3D675): b'\x00\x4b\x0f',
                    ('/VB7D.BIN', 1, 3, 0xC74E): b'\x00\x30\x1c',
                    ('/VB7D.BIN', 1, 3, 0xC754): b'\x00\x31\x1c',
                    ('/VG1.BIN', 0, 0, 0x2999F): b'\x00\x05\x16',
                    ('/VG1.BIN', 0, 0, 0x299C6): b'\x00\x0d\x1a',
                    ('/VE6.BIN', 0, 0, 0x429D9): b'\x00\x3f\x25',
                    ('/VE6.BIN', 0, 22, 0x42D01): b'\x00\x21\x29',
                    ('/VF3.BIN', 2, 13, 0x488CA): b'\x00\x13\x12',
                    ('/VH1.BIN', 5, 2, 0x499B8): b'\x00\x10\x2c',
                    ('/VH1.BIN', 5, 2, 0x499BE): b'\x00\x2a\x1b',
                    ('/VH1.BIN', 5, 3, 0x49A0D): b'\x00\x10\x2c',
                    ('/VH1.BIN', 5, 3, 0x49A13): b'\x00\x2a\x1b',
                    ('/VH1.BIN', 13, 2, 0x49CEA): b'\x00\x25\x27',
                }.get((*key, pc))
                river_join = {
                    ('/VD2.BIN', 1, 2, 0x45E4B): (20, 0x45E2C),
                    ('/VD2.BIN', 1, 3, 0x45F34): (20, 0x45F15),
                    ('/VD2.BIN', 2, 0, 0x4607D): (67, 0x4605E),
                }.get((*key, pc))
                if river_join is not None:
                    requested, check = river_join
                    if opnd[1] != requested or not data.startswith(b'\x3d\x01\x05', check):
                        raise ValueError('Teien full-party handoff changed')
                    cmds.append({'kind': 'party_select', 'parameter': 5, 'index': requested,
                                 'required_party': [2, 17, 20, 35, 67]})
                if opnd == reserve_growth:
                    # A mandatory recruit goes to the reserves if all six field slots are occupied.
                    cmds.append({'kind': 'party_load', 'character': member})
                    kind = 'advance_character'
                else:
                    kind = "advance_character" if opnd == growth else "party_join"
                cmd = {"kind": kind, "character": member}
                if opnd[2] > 0:
                    cmd["level_advances"] = opnd[2]
                cmds.append(cmd)
        elif op == 0x20:
            flush_pending_choices(None)
            if pc in (antidote_muster, kasumi_dismiss, gregminster_muster):
                cmds.append({"kind": "party_dismiss"})
            elif key == ("/VB7.BIN", 4, 4) and opnd == b"\xff":
                from export_scripted_travel import hq_party_dismissal
                dismissal = hq_party_dismissal()
                assert pc == dismissal["offset"]
                cmds.append(dict(dismissal["command"]))
            else:
                cid = opnd[1] if opnd[0] in (0xFC, 0xFE) else opnd[0]
                if cid in PARTY_JOIN_NAMES and PARTY_JOIN_NAMES[cid] in combat_party:
                    command = {"kind": "party_leave", "character": PARTY_JOIN_NAMES[cid]}
                    if opnd[0] == 0xFE or (key == ('/VF3.BIN', 2, 9) and pc == 0x4860D and opnd == b'\x1d'):
                        # The handler skips removal when none of the six active slots match.
                        command["value"] = 1
                    cmds.append(command)
        elif op == 0x1F:
            flush_pending_choices(None)
            if valeria_recruit and pc == 0x27089:
                cmds.append({'kind': 'party_load', 'character': 'valeria'})
            elif (hq_entry or hq_briefing or hq_morning
                  or (antidote_muster is not None and pc - antidote_muster in (2, 8))
                  or (gregminster_muster is not None and pc - gregminster_muster in (2, 5))) and len(opnd) == 2 and opnd[0] == 0xFF:
                cmds.append({"kind": "party_load", "character": PARTY_JOIN_NAMES[opnd[1]]})
            elif key == ("/VB2.BIN", 5, 3):
                assert opnd == b"\x00"
                binds = scene.character_bindings(data, scene.section_off(data, scene.room_record(data, rn)["section"]))
                assert binds[3]["index"] == 0
                cmds.append({"kind": "recruit_mark_loaded", "index": 3})
            elif key == ('/VB5.BIN', 0, 2) and pc == 0x1B23:
                binds = scene.character_bindings(data, scene.section_off(data, scene.room_record(data, rn)['section']))
                if opnd != b'\x00' or binds[32]['index'] != 0 or not data.startswith(b'\x4b\x00\x20\x09', pc + 2):
                    raise ValueError('Toran arrival pilot load changed')
                cmds.append({'kind': 'party_load', 'character': PARTY_JOIN_NAMES[32]})
            if key == ("/VA3.BIN", 1, 38) and opnd[0] == 2:
                cmds.append({"kind": "party_join", "character": "viktor"})
            elif (fname, rn) == ("/VA4.BIN", 10) and opnd[0] in VA4_R10_REJOIN_SLOTS:
                cmds.append({"kind": "party_join", "character": VA4_R10_REJOIN_SLOTS[opnd[0]]})
        elif op == 0x4A and (hq_entry or hq_briefing or (valeria_recruit and pc == 0x2708F)
                                or (antidote_muster is not None and pc - antidote_muster in (5, 11))
                                or (gregminster_muster is not None and pc - gregminster_muster in (8, 11))) and len(opnd) == 2 and opnd[0] == 0:
            flush_pending_choices(None)
            cmds.append({"kind": "area_action", "area": {"kind": "auxiliary_party_add", "character": opnd[1]}})
        elif op == 0x4A and milich_release is not None and pc - milich_release in (0, 3):
            flush_pending_choices(None)
            cmds.append({"kind": "area_action", "area": {"kind": "auxiliary_party_remove", "character": opnd[1]}})
        elif op == 0x3D and fixed_dice:
            if pc == start_pc:
                cmds.append({"kind": "fixed_dice"})
            elif opnd != b"\x14":
                return None
        elif op == 0x42:
            flush_pending_choices(None)
            grant = RUNE_GRANTS.get((fname, rn, ent_idx, opnd[0]))
            if key == ("/VB5A2.BIN", 0, 19) and pc == 0x40046 and opnd == b"\x06":
                cmds.append({"kind": "party_select", "parameter": 5})
            elif key == ("/VB2.BIN", 0, 21) or (pc == boarding_mode_site and opnd == b"\x0c") or (flight is not None and pc == flight[0]):
                cmds.append({"kind": "world_mode", "code": opnd[0]})
            elif (key, pc, opnd) in ((("/VB5G.BIN", 1, 2), 0x2D89, b"\x02"),
                                     (("/VB5G.BIN", 1, 2), 0x2D92, b"\x14"),
                                     (("/VB3.BIN", 20, 8), 0x432D2, b"\x19"),
                                     (("/VB5CC.BIN", 3, 1), 0x105DF, b"\x14"),
                                     (("/VB5BG.BIN", 0, 19), 0x49029, b"\x14")):
                cmds.append({"kind": "world_mode", "code": opnd[0]})
            elif grant:
                cmds.append({"kind": "rune_grant", "character": grant[0], "rune": grant[1]})
            elif key == ("/VA3.BIN", 1, 39) or (key == ("/VB7D.BIN", 1, 3) and pc == 0xC728):
                assert opnd == bytes((15,))
                cmds.append({"kind": "soul_eater_advance"})
        elif op == 0x50 and len(opnd) == 2 and opnd[0] in (0, 1) and opnd[1] in RUNTIME_ITEM_BINDINGS:
            flush_pending_choices(None)
            action = "give" if opnd[0] == 0 else "take"
            cmds.append({"kind": "shared_inventory_edit", "inventory": {action: RUNTIME_ITEM_BINDINGS[opnd[1]], "failure_target": len(cmds) + 1}})
        elif op == 0x46:
            flush_pending_choices(None)
            cmds.append({"kind": "wait_event_flags_low2"})
        elif op == 0x43 and gregminster_muster is not None and pc == gregminster_muster + 17:
            arguments = scene.ptr_at(data, scene.root(data) + 16)
            callback = scene.ptr_at(data, arguments + 7 * 4)
            if (callback != 0x7C or data[0x90:0xB0] != bytes.fromhex(
                    'e8004224 980482ac c41b628c 00000000 4800428c 00000000 09f84000 5c000434')
                    or data[0x230:0x23C] != bytes.fromhex('0580053c 602ba524 09f84000')):
                raise ValueError('Gregminster party selector callback changed')
            flush_pending_choices(None)
            cmds.append({'kind': 'party_select'})
        elif op == 0x43 and hq_selector is not None and opnd == b"\xff\x2c":
            call_site, callback = hq_selector
            arguments = scene.ptr_at(data, scene.root(data) + 16)
            if (pc != call_site or scene.ptr_at(data, arguments + 44 * 4) != callback
                    or data[callback + 0x18:callback + 0x34] != bytes.fromhex('980482ac c41b628c 00000000 4800428c 00000000 09f84000 5c000434')):
                raise ValueError("headquarters party selector callback changed")
            flush_pending_choices(None)
            cmds.append({"kind": "party_select"})
        elif op == 0x43 and is_inn and opnd[0] == 6:
            flush_pending_choices(None)
            arguments = scene.ptr_at(data, scene.root(data) + 16)
            context = scene.ptr_at(data, arguments + 12 + 4 * opnd[1])
            rate = scene.ptr_at(data, context)
            assert rate is not None and rate + 1 < len(data), f"Invalid inn rate at {key} @{pc:#x}"
            cmds.append({"kind": "inn_stay", "amount": data[rate] * data[rate + 1]})
        elif op == 0x43 and opnd == b"\xff\x03" and trigger == "interaction" and e["id"] == 97:
            if rn != 2 or fname not in ("/VB5AG.BIN", "/VB5BG.BIN", "/VB5CG.BIN") or teleport_callback(data) is None:
                return None
            flush_pending_choices(None)
            cmds.append({"kind": "service", "facility": "teleport"})
        elif op == 0x43 and opnd[0] == 8 and opnd[1] == 0 and active_overload_item is not None:
            flush_pending_choices(None)
            if with_crossing:
                cmds.append({"kind": "item_overload", "item_name": active_overload_item})
            else:
                tokens = [{"kind": "glyph", "text": ch} for ch in "Carrying too many items."]
                anchor_idx = len(cmds)
                cmds.append({"kind": "open_box", "box": 0, "layout": 0, "requires": {"kind": "box_closed", "id": "box_0"}})
                anchors.append({"program": prog_id, "command": anchor_idx, "box": 0, "point": {"x": ax, "y": ay}})
                cmds.append({"kind": "wait_boxes"})
                text_id = pool.get_body_text(tokens)
                cmds.append({"kind": "text", "box": 0, "text": text_id, "wait": {"kind": "text", "id": text_id}})
                cmds.append({"kind": "wait_for_accept"})
                cmds.append({"kind": "close_box", "box": 0})
                cmds.append({"kind": "wait_boxes"})
            active_overload_item = None
        elif op == 0x43 and len(opnd) >= 2 and opnd[0] == 0x80:
            overlay = field_service_overlay(data, opnd[1])
            if trigger == "interaction" and overlay is not None and data[end] == 0xFD:
                extent = overlay['lba'], overlay['size']
                for name, facility in (('AZUKARI', 'storage'), ('STONE', 'tablet'), ('BOOKS', 'library')):
                    if extent == service_extent(name):
                        flush_pending_choices(None)
                        cmds.append({"kind": "service", "facility": facility})
                        break
            duel_spec = {
                ("/VB7D.BIN", 3): ("duel:pahn_teo", False),
                ("/VB7D.BIN", 4): ("duel:shu_teo", True),
                ("/VC6.BIN", 3): ("duel:shu_kwanda", True),
            }.get((fname, opnd[1]))
            if duel_spec is not None:
                flush_pending_choices(None)
                if duel_spec[0] in ("duel:shu_kwanda", "duel:shu_teo"):
                    pool.get_image(8)
                cmds.append({"kind": "battle", "battle": duel_spec[0], "defeat_ends_run": duel_spec[1]})
        elif op == 0x43 and opnd[0] in (2, 3, 4, 5):
            flush_pending_choices(None)
            idx = opnd[1]
            if opnd[0] == 3:
                arguments = scene.ptr_at(data, scene.root(data) + 16)
                context = scene.ptr_at(data, arguments + 12 + 4 * idx) if arguments is not None else None
                limit_off = scene.ptr_at(data, context) if context is not None else None
                if limit_off is None or limit_off >= len(data) or data[limit_off] == 0:
                    return None
                idx = data[limit_off]
            cmd = {"kind": "service", "selector": opnd[0], "index": idx}
            if opnd[0] == 2:
                arguments = scene.ptr_at(data, scene.root(data) + 16)
                context = scene.ptr_at(data, arguments + 12 + 4 * opnd[1])
                stock_off = scene.ptr_at(data, context)
                assert stock_off is not None, f"Invalid shop stock at {key} @{pc:#x}"
                raw_ids = list(data[stock_off:data.index(0, stock_off)])
                cmd["shop_items"] = [RUNTIME_ITEM_BINDINGS[iid] for iid in raw_ids if iid in RUNTIME_ITEM_BINDINGS]
            cmds.append(cmd)
        elif op == 0x49:
            flush_pending_choices(None)
            if opnd[0] == 0xFD:
                # The FD arm compares item IDs and calls the bag removal wrapper.
                cmds.append({"kind": "shared_inventory_edit", "inventory": {
                    "take": RUNTIME_ITEM_BINDINGS[opnd[1]], "failure_target": len(cmds) + 1}})
            elif opnd[0] < 0xFD:
                item_slug = RUNTIME_ITEM_BINDINGS[opnd[0]]
                pending_chest_grants.append((len(cmds), item_slug, opnd[0]))
                grant_cmd = {"kind": "chest_grant", "item_name": item_slug, "failure_target": 0}
                if pending_chest_flag is not None:
                    grant_cmd["flag"] = pending_chest_flag
                    pending_chest_flag = None
                cmds.append(grant_cmd)
            elif opnd[0] in (254, 255):
                if not pending_chest_grants:
                    return None
                grant_idx, _, source_id = pending_chest_grants[-1]
                if grant_idx in acquisition_messages:
                    return None
                acquisition_messages[grant_idx] = source_id
                emit_acquisition(source_id)
        elif op == 0x4C and key == ("/VB7.BIN", 4, 4) and opnd == b"\x02\x00":
            from export_scripted_travel import hq_party_recovery
            recovery = hq_party_recovery()
            assert pc == recovery["offset"]
            cmds.append(dict(recovery["command"]))
        elif op == 0x4C and key in (("/VA8.BIN", 10, 6), ("/VA5.BIN", 1, 4), ("/VA5.BIN", 1, 5)):
            from export_scripted_travel import free_party_recoveries
            recovery = next(row for row in free_party_recoveries()
                            if (row["module"], row["room"], row["entity"]) == key)
            assert pc == recovery["offset"] and opnd == bytes((2, 255))
            cmds.append(dict(recovery["command"]))
        elif op == 0x4C and len(opnd) == 4 and opnd[0] == 3:
            flush_pending_choices(None)
            amount = opnd[1] + 100 * opnd[2] + 10000 * opnd[3]
            cmds.append({"kind": "money_edit", "parameter": 3, "amount": amount})
            emit_dialogue([{"kind": "glyph", "text": ch} for ch in f"{amount} bits acquired!"], None, None)
        elif op == 0x47:
            flush_pending_choices(None)
            # Mode9 uses the existing dragon-flight transition adapter.
            enc = battle_ids.get(pc)
            if enc:
                if key == ("/VE1.BIN", 0, 5) and pc == 0x389ED:
                    from battle_placement import directory_encounters, scripted_directory
                    from campaign_coverage import boss_encounter_finish
                    from spell_scene_source import Image
                    base = scene.RAM_BASE
                    section = scene.section_off(data, scene.room_record(data, rn)["section"])
                    directory = scripted_directory(data, section, opnd[0], base)
                    _, (formation,) = directory_encounters(data, directory, base)
                    finish = boss_encounter_finish(Image(data, base), base + formation["descriptor_offset"])
                    if finish["kind"] != "restores_boss_hp_and_clears_defeat_on_teardown":
                        raise ValueError("Village encounter teardown changed")
                    cmds.append({"kind": "battle", "battle": enc, "defeat_target": len(cmds) + 1})
                    cmds.append({"kind": "party_restore", "hp_only": True})
                else:
                    cmds.append({"kind": "battle", "battle": enc, "defeat_ends_run": True})
                war_returns = {
                    'war:teo_before_fire_spear': 'first_teo_war_return',
                    'war:teo_fire_spear': 'second_teo_war_return',
                    'war:northern_checkpoint': 'northern_checkpoint_war_return',
                    'war:shasarazade': 'shasarazade_war_return',
                    'war:gregminster': 'gregminster_war_return',
                }
                if enc in war_returns:
                    import export_scripted_travel
                    region, point, room, x, y = getattr(export_scripted_travel, war_returns[enc])()
                    file, = (slot['file'] for slot in file_slots if slot['region'] == region and slot['index'] == point)
                    destination = f'{Path(file).stem.lower()}_room_{room}'
                    px, py = clamped_spawn_xy(destination, x, y)
                    transition = {'kind': 'room_transition', 'destination': destination, 'x': px, 'y': py}
                    wid = f'{world_regions[region]}_point_{point}'
                    if not world_entries or any(entry['id'] == wid and entry['area'] == destination.split('_room_', 1)[0] for entry in world_entries):
                        transition['world_entry'] = wid
                    cmds.append(transition)
                elif key == ("/VA4.BIN", 3, 3):
                    cmds.append(align_hero_cmd((160, 160)))
                elif key == ("/VA7.BIN", 9, 2):
                    cmds.append(align_hero_cmd((320, 176)))
                elif key == ("/VA7.BIN", 9, 3):
                    for kind, char_id in (
                        ("party_join", "hero"),
                        ("party_leave", "ted"),
                        ("party_join", "gremio"),
                        ("party_join", "pahn"),
                        ("party_join", "cleo"),
                        ("party_join", "ted"),
                    ):
                        cmds.append({"kind": kind, "character": char_id})
                    cmds.append(align_hero_cmd((248, 184)))
                elif key == ("/VA7.BIN", 13, 1):
                    cmds.append(align_hero_cmd((216, 232)))
                elif key == ("/VA7.BIN", 13, 3):
                    cmds.append(align_hero_cmd((216, 216)))
        elif op == 0x03:
            flush_pending_choices(None)
            if final_dock_return:
                # shortcut: fold the staging-only room into the dock until its presentation is supported.
                staging = cross_area_room(fname, opnd[1], opnd[2], file_slots)
                if pc != 0x49030 or opnd != b'\xfc\x1a\x05\xff\xff' or staging != 'vb5b2_room_5':
                    raise ValueError('Final dock staging destination changed')
                staged, _ = source('/VB5B2.BIN')
                first, second = scene.entities(staged, scene.room_record(staged, 5))[1:3]
                if (staged[first['stream_offsets'][1]:first['stream_offsets'][1] + 7] != b'\x07\x20\x20\x14\xff\x03\x06'
                        or staged[second['stream_offsets'][1]:second['stream_offsets'][1] + 4] != b'\x07\x20\x20\x06'
                        or staged[0x38870:0x3893F] != staged[0x38948:0x38A17]):
                    raise ValueError('Final council return branches changed')
                targets = []
                cmds.append({'kind': 'branch_castle_tier', 'targets': targets})
                for offset, expected in ((0x38A17, b'\x03\xfc\x1b\x00\x14\x14\xfd'),
                                         (0x3893F, b'\x03\xfc\x14\x00\x14\x14\xfd')):
                    raw = staged[offset:offset + len(expected)]
                    if raw != expected:
                        raise ValueError('Final council return destination changed')
                    point, room, rx, ry = raw[2:6]
                    destination = cross_area_room('/VB5B2.BIN', point, room, file_slots)
                    x, y = clamped_spawn_xy(destination, rx, ry)
                    targets.append(len(cmds))
                    cmds.extend([{'kind': 'room_transition', 'destination': destination, 'x': x, 'y': y,
                                  'world_point': point}, {'kind': 'end_stream'}])
                targets.append(targets[-1])
                idx_in_order += 1
                continue
            if dragon_return:
                if opnd not in (b'\xfa\x01\x18\x00\x10\x2b', b'\xfa\x01\x10\x00\x10\x2b'):
                    raise ValueError('Dragon return destination changed')
                region, point, room, rx, ry = opnd[1:]
                file, = (slot['file'] for slot in file_slots if slot['region'] == region and slot['index'] == point)
                destination = f'{Path(file).stem.lower()}_room_{room}'
                x, y = clamped_spawn_xy(destination, rx, ry)
                cmds.extend([{'kind': 'room_transition', 'destination': destination, 'x': x, 'y': y,
                              'world_entry': f'world_b_point_{point}'}, {'kind': 'end_stream'}])
                idx_in_order += 1
                continue
            fd_targets = castle_tier_fd_targets(opnd) if (len(opnd) == 5 and opnd[0] == 0xFD) else None
            if pc == duel_return_site or fd_targets is not None:
                if len(opnd) != 5 or opnd[0] != 0xFD or fd_targets is None:
                    raise ValueError('Duel return destination format changed')
                targets = []
                cmds.append({'kind': 'branch_castle_tier', 'targets': targets})
                for destination, point, x, y in fd_targets:
                    px, py = clamped_spawn_xy(destination, x, y)
                    targets.append(len(cmds))
                    cmds.extend([{'kind': 'room_transition', 'destination': destination, 'x': px, 'y': py,
                                  'world_point': point}, {'kind': 'end_stream'}])
                targets.append(targets[-1])  # The loader uses the same base for tiers three and four.
                idx_in_order += 1
                continue
            if key == ("/VB2.BIN", 0, 21):
                assert opnd == bytes((251, 9, 119, 75))
                cmds.append({"kind": "world_transition", "destination": "world_j", "x": 119, "y": 75})
                break
            if boarding_mode_site is not None and pc == boarding_mode_site + 2 and opnd[:2] == b"\xfb\x09":
                cmds.append({"kind": "world_transition", "destination": "world_j", "x": opnd[2], "y": opnd[3]})
                idx_in_order += 1
                continue
            if kasumi_dismiss is not None:
                point, dock = (24, 'vb5bg_room_0') if fname == '/VB5B3.BIN' else (16, 'vb5cg_room_0')
                if opnd != bytes((0xfa, 1, point, 0, 0xfe, 0xfe)):
                    raise ValueError('Kasumi briefing exit changed')
                dock_x, dock_y = nearest_walkable(grids[ROOM_TO_SRC[dock]], 128, 344)
                cmds.append({'kind': 'room_transition', 'destination': dock, 'x': dock_x, 'y': dock_y,
                             'world_point': point})
                break
            if key == ("/VA8.BIN", 10, 3) and opnd == bytes((10, 255, 28)):
                scene_pc = scene.entities(data, scene.room_record(data, 10))[5]["stream_offsets"][2]
                pending_jumps.append((len(cmds), scene_pc, "target"))
                cmds.append({"kind": "jump", "target": 0})
                idx_in_order += 1
                continue
            # Determine warp destination
            dest_room = None
            dest_xy = None
            if len(opnd) == 3 and opnd[0] < 128:
                t_rn, hx, hy = opnd[0], opnd[1], opnd[2]
                dest_room = AREA_ROOM_ID.get(fname, {}).get(t_rn)
                target_grid = grids.get((fname, t_rn))
                if dest_room is None or target_grid is None:
                    return None
                dest_xy = nearest_walkable(target_grid, hx * 8, hy * 8)
                if (fname, rn) == ("/VA8.BIN", 5) and ent_idx in (2, 5, 6, 7) and t_rn == 10 and (hx, hy) == (23, 38):
                    # Fold initializer 2's Hero position into the room entry.
                    init = scene.entities(data, scene.room_record(data, 10))[2]["stream_offsets"][2]
                    position = data[init + 33:init + 41]
                    assert position[:3] == b"\x07\x80\x01" and position[4:7] == b"\x07\x80\x02"
                    dest_xy = (position[3] * 8, position[7] * 8)
            elif len(opnd) == 5 and opnd[0] == 252:
                if key == ("/VAC.BIN", 15, 0) and opnd == bytes((252, 9, 0, 0, 0)):
                    cmds.append({"kind": "battle", "battle": "ending:main", "defeat_ends_run": False})
                    cmds.append({"kind": "end_stream"})
                    break
                if key == ("/VAD.BIN", 9, 8) and opnd == bytes((252, 12, 0, 29, 18)):
                    from export_scripted_travel import golden_hydra_battle_return
                    region, point, room, rx, ry = golden_hydra_battle_return()
                    if (region, point, room) != (11, 8, 9):
                        raise ValueError('Golden Hydra battle return destination changed')
                    cmds.append({"kind": "battle", "battle": "vzv_dir_194d8_1", "defeat_ends_run": True})
                    cmds.append(align_hero_cmd(nearest_walkable(grids[("/VAD.BIN", 9)], rx * 8, ry * 8)))
                    cmds.append({"kind": "end_stream"})
                    break
                dest_room = cross_area_room(fname, opnd[1], opnd[2], file_slots)
                target_grid = grids.get(ROOM_TO_SRC.get(dest_room))
                if target_grid is None:
                    return None
                dest_xy = nearest_walkable(target_grid, opnd[3] * 8, opnd[4] * 8)
            elif opnd and opnd[0] == 255:
                cmds.append({'kind': 'world_transition', 'return_to_entry': True})
                idx_in_order += 1
                continue
            elif opnd and opnd[0] == 254:
                cmds.append(retained_world_return(opnd, world_regions or {}, grids, fname, file_slots))
                idx_in_order += 1
                continue
            elif opnd and opnd[0] == 251:
                target = explicit_world_target(opnd, world_regions or {}, grids)
                if target is not None:
                    dest_room, dest_xy = target
            elif len(opnd) == 6 and opnd[0] == 0xFA and fa_single_dest is not None:
                dest_room = fa_single_dest
                dest_xy = clamped_spawn_xy(dest_room, opnd[4], opnd[5])

            # These scenes reload the room so its actors are initialized under the new story flags.
            reload_room = (key, pc, opnd) in (
                (("/VE1.BIN", 1, 0), 0x38FC7, bytes((1, 20, 24))),
                (("/VI1.BIN", 0, 5), 0x3982A, bytes((0, 22, 55))),
            )
            if (dest_room == room_id and dest_xy is not None and opnd[0] not in (252, 0xFA)
                    and key != ("/VA1.BIN", 2, 14) and not reload_room):
                cmds.append(align_hero_cmd(dest_xy))
                cmds.append({"kind": "end_stream"})
                # Self-align inside same room ends stream cleanly
            elif dest_room is not None and dest_xy is not None:
                transition = {"kind": "room_transition", "destination": dest_room, "x": dest_xy[0], "y": dest_xy[1], "_transition_id": (dest_room, dest_xy)}
                if opnd[0] == 0xFA and fa_single_dest is not None:
                    wid = f'{world_regions[opnd[1]]}_point_{opnd[2]}'
                    if world_entries and any(entry['id'] == wid and entry['area'] == dest_room.split('_room_', 1)[0] for entry in world_entries):
                        transition['world_entry'] = wid
                    elif not world_entries:
                        transition['world_point'] = opnd[2]
                elif opnd[0] == 252 and not is_elevator:
                    if not world_entries or any(
                        entry['area'] == dest_room.split('_room_', 1)[0] and entry['point'] == opnd[1]
                        for entry in world_entries
                    ):
                        transition['world_point'] = opnd[1]
                cmds.append(transition)
            else:
                if safe_escape_xy is not None:
                    cmds.append(align_hero_cmd(safe_escape_xy))
                cmds.append({"kind": "end_stream"})
        elif op == 0xFD:
            flush_pending_choices(None)
            if key == ("/VC6.BIN", 0, 9) and pc == 0x3D534:
                # Use the existing chamber entry for the duel after the briefing.
                # Otherwise the party must pass the later castle boss to get there.
                target = AREA_ROOM_ID[fname][14]
                x, y = nearest_walkable(grids[(fname, 14)], 288, 16)
                cmds.append({"kind": "room_transition", "destination": target, "x": x, "y": y})
                idx_in_order += 1
                continue
            if (trigger == "interaction" and fname in ("/VB5A2.BIN", "/VB5B2.BIN", "/VB5C2.BIN")
                    and e["id"] == 95 and rn == 0
                    and any(opcode == 0x12 and args == b"\x00\x5f" for opcode, args, _, _ in insns.values())):
                cmds.append({"kind": "service", "facility": "bathhouse"})
            # Check VA2 R00 e35/e36/e37 declining arm or any coordinate-range trap without mutation
            if key == ("/VA9.BIN", 0, 0) and pc == 0x152D8:
                # shortcut: use the scene's terrace floor until dragon arrival has elevation.
                departure_xy = data[0x15301:0x15304]
                if departure_xy != b'\x10\x17\x25':
                    raise ValueError('Tigerwolf terrace staging changed')
                x, y = (cell * 8 for cell in departure_xy[1:])
                if nearest_walkable(grids[(fname, rn)], x, y) != (x, y):
                    raise ValueError('Tigerwolf terrace staging is blocked')
                cmds.append({"kind": "place_hero", "x": x, "y": y})
            elif key in (("/VF2.BIN", 0, 0), ("/VF2.BIN", 0, 2)):
                from maindec import mword

                # Return control at the entry's floor position after off-map landing staging.
                point = mword(0x80170064 + 4 * 5) + 14
                if (mword(point), mword(point + 4)) != (0x000E0000, 0x0A13003E):
                    raise ValueError('Seek Valley landing point changed')
                x, y = 19 * 8, 10 * 8
                if nearest_walkable(grids[(fname, rn)], x, y) != (x, y):
                    raise ValueError('Seek Valley landing point is blocked')
                cmds.append({"kind": "place_hero", "x": x, "y": y})
            elif not has_camera_push and key in (("/VA4.BIN", 0, 9), ("/VA4.BIN", 0, 12)):
                cmds.append(align_hero_cmd((184, 144)))
            elif safe_escape_xy is not None and cmds:
                # Emit align_hero only when this branch actually performed an action/dialogue inside the trap
                cmds.append(align_hero_cmd(safe_escape_xy))
            if cmds:
                cmds.append({"kind": "end_stream"})

        idx_in_order += 1

    flush_pending_choices(None)
    if not cmds or all(c["kind"] == "end_stream" for c in cmds):
        return None
    if cmds[-1]["kind"] not in ("end_stream", "room_transition", "world_transition"):
        if safe_escape_xy is not None:
            cmds.append(align_hero_cmd(safe_escape_xy))
        cmds.append({"kind": "end_stream"})

    # Resolve all jump targets
    for c_idx, tpc, field in pending_jumps:
        if tpc not in pc_to_cmd_idx:
            return None
        target_cmd = pc_to_cmd_idx[tpc]
        if field in ("target", "failure_target"):
            cmds[c_idx][field] = target_cmd
        else:
            slot = int(field.split(":")[1])
            cmds[c_idx]["targets"][slot] = target_cmd

    # Join identical terminal requests after the branches that produce them.
    trans_indices = [i for i, c in enumerate(cmds) if c['kind'] in ('room_transition', 'world_transition')]
    if trans_indices and not is_elevator and not any(c['kind'] == 'branch_castle_tier' for c in cmds):
        transitions = [{k: v for k, v in cmds[i].items() if k != '_transition_id'} for i in trans_indices]
        if len({json.dumps(command, sort_keys=True) for command in transitions}) != 1:
            return None
        if len(trans_indices) > 1 or trans_indices[0] != len(cmds) - 1:
            final_idx = len(cmds)
            cmds.append(transitions[0])
            for tidx in trans_indices:
                cmds[tidx] = {'kind': 'jump', 'target': final_idx}
        else:
            cmds[-1].pop('_transition_id', None)

    # Clean temp key if single transition remained
    for c in cmds:
        c.pop("_transition_id", None)
        if c["kind"] == "room_transition" and (c["destination"], 0) in grids:
            width, height, cells = grids[(c["destination"], 0)]
            assert 0 <= c["x"] < width * 8 and 0 <= c["y"] < height * 8 and c["x"] % 8 == c["y"] % 8 == 0, c
            if cells[(c["y"] // 8) * width + c["x"] // 8] == "0":
                c.update(kind="world_transition", x=c["x"] // 8, y=c["y"] // 8)

    # VA1 R02 e21 Dinner -> sleep puts Hero in bed at (184, 96) right on e13 morning cutscene?
    # Keep VA1 R02 e21 ending with align_hero to (80, 272) (just north of e21 box, letting player walk upstairs)
    for c in cmds:
        if c["kind"] == "shared_inventory_edit" and c["inventory"]["failure_target"] >= len(cmds):
            c["inventory"]["failure_target"] = len(cmds) - 1
    assert len(cmds) <= 512, f"{prog_id} exceeds 512 commands: {len(cmds)}"

    program = {
        "id": prog_id,
        "entry": "ordinary",
        "entity": ent_idx,
        "trigger": trigger if trigger in ("interaction", "area_entry") else "none",
        "conditions": prog_conditions,
        "selection": selection_terms,
        "commands": cmds,
    }
    if gated and not static_conversation(data, rn, ent_idx, room_id, program, pool.art, hw, hh):
        return None
    return program, anchors, prefixes


def toran_evening(room_id, entity, pool, grids, battle_data):
    """Use the existing Toran interior for the solo encounter and overnight rest."""
    from export_route_battles import TORAN_INTRUDER

    if room_id not in ("vb5a1_room_0", "vb5a2_room_0") or battle_data is None or ("/VB5A2.BIN", 0) not in grids:
        return None
    trial, spells = battle_data
    if (not any(row["id"] == TORAN_INTRUDER for row in trial["encounters"])
            or not any(row["id"] == TORAN_INTRUDER for row in spells["hurt_poses"])):
        return None

    def flag(kind, index, mask):
        return {"kind": kind, "flag": {"id": story_id(index), "mask": mask}}

    ambush = room_id == "vb5a1_room_0"
    scene_name = "intruder" if ambush else "overnight"
    program_id = f"{room_id}_{scene_name}"
    conditions = [flag("story_mask_set", 19, 16 if ambush else 64),
                  flag("story_mask_clear", 19 if ambush else 15, 32 if ambush else 2)]
    selection = [{"kind": "hero_x_inclusive", "min": 8, "max": 74},
                 {"kind": "hero_y_inclusive", "min": 12, "max": 49}] if ambush else []
    field_terms = [dict(term) for term in conditions]
    for term in selection:
        axis = "x" if term["kind"] == "hero_x_inclusive" else "y"
        field_terms.append({"kind": "coordinate_range", "coordinate":
                            {"axis": axis, "first": term["min"], "last": term["max"]}})
    if not ambush:
        field_terms.append({"kind": "interaction"})
    x, y = (0, 0) if ambush else (80, 224)
    width, _, grid = grids[("/VB5A2.BIN", 0)]
    if not all(grid[cy * width + 10] == "1" for cy in (28, 30)):
        raise ValueError("Toran rest needs a walkable approach")

    def dialogue(message, choices=None):
        tokens = [{"kind": "newline"} if char == "\n" else {"kind": "glyph", "text": char} for char in message]
        text_id = pool.get_body_text(tokens)
        anchors.append({"program": program_id, "command": len(commands), "box": 0, "actor": "hero"})
        commands.extend([
            {"kind": "open_box", "box": 0, "actor": "hero", "requires": {"kind": "box_closed", "id": "box_0"}},
            {"kind": "wait_boxes"},
            {"kind": "text", "box": 0, "text": text_id, "wait": {"kind": "text", "id": text_id}},
            {"kind": "choice", "box": 0, "options": choices} if choices else {"kind": "wait_for_accept"},
            {"kind": "close_box", "box": 0},
            {"kind": "wait_boxes"},
        ])

    anchors, commands = [], []
    if ambush:
        dialogue("The hall has emptied. Someone steps out of the shadows.")
        commands.extend([
            {"kind": "party_dismiss"},
            {"kind": "battle", "battle": TORAN_INTRUDER, "defeat_ends_run": True},
        ])
        dialogue("The intruder is gone. Rest upstairs while we keep watch.")
        commands.extend([
            flag("story_or", 19, 32 | 64),
            {"kind": "room_transition", "destination": "vb5a2_room_0", "x": 80, "y": 240},
        ])
    else:
        dialogue("Rest for the night?")
        dialogue("Rest now\nLater", 2)
        decline = {"kind": "branch_choice", "target": 0}
        commands.extend([
            decline,
            {"kind": "fade_out", "blend_mode": 2, "draw_slot": 10, "wait": {"kind": "fade", "id": "fade"}},
            {"kind": "party_restore"},
            flag("story_or", 19, 128),
            flag("story_or", 15, 2),
            {"kind": "fade_in", "wait": {"kind": "fade", "id": "fade"}},
        ])
        decline["target"] = len(commands)
        commands.append({"kind": "end_stream"})

    event = {"id": f"{program_id}_trigger", "source_order": entity, "record_role": "event",
             "position": {"source_x": x // 8, "source_y": y // 8, "x": x, "y": y,
                          "placement": "not_applicable" if ambush else "placed"},
             "population_candidate": False, "source_character_id": None, "resource_id": None,
             "resource_domain": None, "classification": {"pointer_state": "null" if ambush else "present",
                                                          "terms": [] if ambush else conditions},
             "event_selection": {"pointer_state": "present", "terms": field_terms},
             "trigger": "ordinary" if ambush else "interaction", "initialization_order": None,
             "event": {"reference": f"{program_id}_authored", "status": "resolved", "program_id": program_id}}
    program = {"id": program_id, "entry": "ordinary", "entity": entity,
               "trigger": "none" if ambush else "interaction", "conditions": conditions,
               "selection": selection, "commands": commands}
    return event, program, anchors, (15, 19)


def toran_prison_briefing(room_id, entity, actor, pool, step):
    name, prerequisite, mask, item, lines = step
    program_id = f'{room_id}_{name}'
    completion = {'id': story_id(230), 'mask': mask}
    conditions = [{'kind': 'story_mask_set', 'flag': prerequisite},
                  {'kind': 'story_mask_clear', 'flag': completion}]
    commands, anchors = [], []

    def say(lines):
        tokens = [{'kind': 'newline'} if c == '\n' else {'kind': 'glyph', 'text': c} for c in '\n'.join(lines)]
        text_id = pool.get_body_text(tokens)
        anchors.append({'program': program_id, 'command': len(commands), 'box': 0, 'actor': actor})
        commands.extend([
            {'kind': 'open_box', 'box': 0, 'actor': actor, 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
            {'kind': 'wait_boxes'},
            {'kind': 'text', 'box': 0, 'text': text_id, 'wait': {'kind': 'text', 'id': text_id}},
            {'kind': 'wait_for_accept'}, {'kind': 'close_box', 'box': 0}, {'kind': 'wait_boxes'},
        ])

    say(lines)
    grant = {'give': item, 'failure_target': 0}
    commands.extend([{'kind': 'shared_inventory_edit', 'inventory': grant},
                     {'kind': 'story_or', 'flag': completion}, {'kind': 'end_stream'}])
    grant['failure_target'] = len(commands)
    say(('Make room for the papers,', 'then come see me again.'))
    commands.append({'kind': 'end_stream'})
    event = {'id': f'{program_id}_trigger', 'source_order': entity, 'record_role': 'event',
             'position': {'source_x': 0, 'source_y': 0, 'x': 0, 'y': 0, 'placement': 'not_applicable'},
             'population_candidate': False, 'source_character_id': None, 'resource_id': None, 'resource_domain': None,
             'classification': {'pointer_state': 'null', 'terms': []},
             'event_selection': {'pointer_state': 'present', 'terms': [*conditions, {'kind': 'interaction'}]},
             'trigger': 'interaction', 'initialization_order': None,
             'event': {'reference': f'{program_id}_authored', 'status': 'resolved', 'program_id': program_id}}
    program = {'id': program_id, 'entry': 'ordinary', 'entity': entity, 'trigger': 'interaction',
               'conditions': conditions, 'selection': [], 'commands': commands, 'owner_actors': [actor]}
    return event, program, anchors


def build_package(art_path: Path, rooms=OPENING_ROOMS, *, with_crossing=False) -> dict:
    if with_crossing:
        from export_scripted_travel import RUINS_ROOMS, HQ_ROOMS, FOUNDED_ROOMS, KOUAN_ROOMS
        rooms = tuple(dict.fromkeys((*rooms, ("/VB5I0.BIN", 0, "vb5i0_room_0"),
                 *(("/VB5.BIN", room, f"vb5_room_{room}") for room in RUINS_ROOMS),
                 *(("/VB7.BIN", room, f"vb7_room_{room}") for room in HQ_ROOMS),
                 *((file, room, f'{file[1:-4].lower()}_room_{room}') for file, indices in FOUNDED_ROOMS.items() for room in indices),
                 *(('/VB3.BIN', room, f'vb3_room_{room}') for room in KOUAN_ROOMS))))
    from event_script_reachability import loader_file_slots
    from area_data_select import area_table
    _, file_slots, _ = loader_file_slots()
    world_regions = {row['index']: 'world_' + Path(row['path']).name.removesuffix('_DATA.BIN').lower()
                     for row in area_table() if row['path'] is not None}
    art = json.loads(art_path.read_text(encoding="utf-8"))
    battle_data = None
    for candidate in (ROOT / "kit/work/build/canonical/battle", ROOT / "kit/work/build/journey/battle"):
        if all((candidate / name).is_file() for name in ('trial.json', 'spells.json', 'actors.png', 'ground.png', 'spell_effects.png')):
            battle_data = (json.loads((candidate / 'trial.json').read_text()),
                           json.loads((candidate / 'spells.json').read_text()))
            break
    combat_party = materializable_party_ids(battle_data)

    # Resolve destination grids before compiling room transitions.
    file_cache: dict[str, tuple[bytes, dict]] = {}
    grids: dict[tuple[str, int], tuple[int, int, str]] = {}
    for fname, rn, _ in rooms:
        if fname not in file_cache:
            file_cache[fname] = source(fname)
        data, _ = file_cache[fname]
        sec = scene.section_off(data, scene.room_record(data, rn)["section"])
        grids[(fname, rn)] = area_room_walkable_grid(data, sec, fname, rn)

    world_package = json.loads((ROOT / "kit/work/build/canonical/room.json").read_text()) if rooms == OPENING_ROOMS or with_crossing else {}
    world_rooms = world_package.get('rooms', [])
    world_entries = world_package.get('world_entries', [])
    wheel_clips = world_package.get('player_clips') if not with_crossing and any(
        room['id'] == 'vb3_room_28' and room.get('wheel_map') is not None for room in world_rooms) else None
    wheel_sounds = None
    if wheel_clips:
        sound_manifest = ROOT / 'kit/work/build/canonical/audio/sfx/battle_sfx.json'
        wheel_sounds = {cue['id'] for cue in json.loads(sound_manifest.read_bytes())['cues']} if sound_manifest.is_file() else set()
    world_grids = {r["id"]: (r["width"] // 8, r["height"] // 8, r["walkable"])
                   for r in world_rooms if r["id"].startswith("world_")}

    grids.update({(room, 0): grid for room, grid in world_grids.items()})
    room_bindings = []
    for fname, rn, room_id in rooms:
        standard_wheel = room_id == 'vb3_room_28' and wheel_sounds is not None
        content_schema = "suikoden-event-ir/13" if with_crossing and fname in ("/VB3.BIN", "/VB5.BIN", "/VB7.BIN", "/VB5A2.BIN", "/VB5A1.BIN", "/VB5AG.BIN") else "suikoden-event-ir/3" if fname == "/VB5I0.BIN" else "suikoden-event-ir/2" if fname in ("/VB1.BIN", "/VB2.BIN") else CONTENT_SCHEMA
        data, proof = file_cache[fname]
        rec = scene.room_record(data, rn)
        sec = scene.section_off(data, rec["section"])
        hw, hh, _ = grids[(fname, rn)]
        ents = scene.entities(data, rec)
        inherited = {i: interaction_actor_candidates(data, ents, i) for i, entity in enumerate(ents) if inherits_actor(entity)}
        owner_entities = {owner for owners in inherited.values() if owners for owner in owners}
        binds = scene.character_bindings(data, sec)
        actor_initializers = {}
        from field_scenery import room_templates
        scenery_templates = room_templates(data, rn)
        scenery_model = next((r.get("scenery_model") for r in world_rooms if r["id"] == room_id), None)
        initial_scenery_count = scenery_model["initial_count"] if scenery_model else 0
        for i, entity in enumerate(ents):
            if not entity['flags'] & 0x10:
                continue
            conditional_staging = (fname, rn, i) in (
                ('/VB5B3.BIN', 0, 97), ('/VB5B3.BIN', 0, 98), ('/VB5B3.BIN', 0, 99), ('/VB5B3.BIN', 0, 100), ('/VB5B3.BIN', 0, 109),
                ('/VB5B3.BIN', 0, 111), ('/VB5B3.BIN', 0, 112), ('/VB5B3.BIN', 0, 113), ('/VB5B3.BIN', 0, 114), ('/VB5B3.BIN', 0, 115), ('/VB5B3.BIN', 0, 116), ('/VB5B3.BIN', 0, 117),
                ('/VB5C4.BIN', 0, 109), ('/VB5C4.BIN', 0, 110), ('/VB5C4.BIN', 0, 111), ('/VB5C4.BIN', 0, 112), ('/VB5C4.BIN', 0, 122),
                ('/VB5C4.BIN', 0, 124), ('/VB5C4.BIN', 0, 125), ('/VB5C4.BIN', 0, 126), ('/VB5C4.BIN', 0, 127), ('/VB5C4.BIN', 0, 128), ('/VB5C4.BIN', 0, 129), ('/VB5C4.BIN', 0, 130),
                ('/VB5B3.BIN', 0, 110), ('/VB5C4.BIN', 0, 123),
                ('/VB5BG.BIN', 0, 12), ('/VB5CG.BIN', 0, 15), ('/VI1.BIN', 0, 20),
            )
            event, debug = decode_predicate(data, entity['stream_offsets'][1], 'event', coordinate_ranges=True)
            event = normalize_event_predicate(event, debug)
            if (event['pointer_state'] != 'present'
                    or any(term['kind'] not in ('story_mask_set', 'story_mask_clear', 'coordinate_range',
                                                'recruit_present', 'recruit_absent', 'recruit_ever',
                                                'stage_at_least', 'money_at_least', 'level_at_least',
                                                'has_item', 'party_contains')
                           and not (conditional_staging and term['kind'] == 'party_absent') for term in event['terms'])):
                continue
            conditions = [term for term in event['terms'] if term['kind'] in ('story_mask_set', 'story_mask_clear')]
            if (fname, rn) == ('/VD5.BIN', 7) and 17 <= i <= 26:
                start = entity['stream_offsets'][2]
                if data[start] != 0x30 or data[start + 8:start + 10] != b'\x31\xfd':
                    raise ValueError('Soniere prison door initializer changed')
                # Each visit starts with all original scenery instances active.
                _, stage = scenery_swap(data, start + 1, scenery_model)
                commands = [{'kind': 'continue_tick'}, stage, {'kind': 'yield_tick'}, {'kind': 'end_stream'}]
            elif (fname, rn) == ('/VE4.BIN', 0) and i in (25, 26):
                start = entity['stream_offsets'][2]
                if data[start] != 0x30 or data[start + 8:start + 10] != b'\x31\xfd':
                    raise ValueError('Lorimar gatehouse initializer changed')
                _, stage = scenery_swap(data, start + 1, scenery_model)
                commands = [{'kind': 'continue_tick'}, stage, {'kind': 'yield_tick'}, {'kind': 'end_stream'}]
            elif (fname, rn, i) == ('/VE3.BIN', 5, 4):
                start = entity['stream_offsets'][2]
                if start != 0x5BEF8 or data[start:start + 10] != bytes.fromhex('30 40 fe 01 14 02 0f 00 31 fd'):
                    raise ValueError('Castle doorway initializer changed')
                commands = [{'kind': 'continue_tick'}, *scenery_swap(data, start + 1, scenery_model),
                            {'kind': 'yield_tick'}, {'kind': 'end_stream'}]
            elif (fname, rn) == ('/VB5A2.BIN', 0) and i in (41, 42):
                # The inherited departure and retry prompts need their staged officers on the council floor.
                cursor = entity['stream_offsets'][2]
                order = actor_allocation_order(ents)
                if (cursor != (0x405AC if i == 41 else 0x405FC) or order[13] != 31 or order[17] != 38
                        or data[0x405CD:0x405D5] != bytes.fromhex('07 0D 01 3C 07 0D 02 12')
                        or data[0x40605:0x4060D] != bytes.fromhex('07 11 01 3C 07 11 02 0D')):
                    raise ValueError('Toran Garan briefing actors changed')
                officers = [(31, 432, 152), (38, 464, 152)] if i == 41 else [(38, 464, 152)]
                commands = [{'kind': 'continue_tick'}]
                for actor, x, y in officers:
                    if nearest_walkable(grids[(fname, rn)], x, y) != (x, y):
                        raise ValueError('Toran council position must be walkable')
                    commands.append({'kind': 'place_actor', 'x': x, 'y': y, '_source_actor': actor})
                commands.extend([{'kind': 'yield_tick'}, {'kind': 'end_stream'}])
            else:
                commands = compile_actor_initializer(data, ents, entity, conditions, scenery_templates=scenery_templates,
                                                     initial_scenery_count=initial_scenery_count, conditional_staging=conditional_staging)
            if commands and all(
                (ents[sa]['id'] in binds or (with_crossing and fname == '/VB7.BIN' and rn == 4 and sa in (6, 7, 8, 9)))
                and f"{room_id}_character_{ents[sa]['id']:03d}" in art['character_clips']
                for cmd in commands if (sa := cmd.get('_source_actor')) is not None
            ):
                actor_initializers[i] = commands
                owner_entities.update(command['_source_actor'] for command in commands if '_source_actor' in command)
        movable_entities = {command['_source_actor'] for commands in actor_initializers.values()
                            for command in commands if command['kind'] == 'place_actor'}
        hdr0 = scene.ptr_at(data, 0)
        rt_off = scene.ptr_at(data, rec["record_off"] + 12)
        t_arr_off = scene.ptr_at(data, hdr0 + 4 * 5)

        pool = RoomTextPool(room_id, art)
        pop_entities = []
        pop_programs = []
        ir_programs = []
        all_anchors = []
        all_prefixes = []
        room_actors = []
        room_tracks = []
        ir_actors = []
        story_indices: set[int] = set()
        init_order = 0
        occupied_sprite_keys: set[tuple[int, int, tuple[str, ...]]] = set()

        content_id = f"{room_id}_field_events"

        for i, e in enumerate(ents):
            key = (fname, rn, i)
            try:
                cl, _ = decode_predicate(data, e["stream_offsets"][0], "classification", full=True)
                reserved_cl = False
            except ReservedActorPredicate:
                cl = {"pointer_state": "null", "terms": []}
                reserved_cl = True
            if with_crossing and fname == '/VB3.BIN' and rn == 2 and i in (4, 5):
                from export_scripted_travel import krin_plan
                cl = krin_plan()['inherited_actor']['classification']
            if with_crossing and key == ("/VB5A2.BIN", 0, 8):
                from export_scripted_travel import hq_auxiliary_party
                cl = hq_auxiliary_party()['actor']['classification']
            if with_crossing and fname == '/VB5A2.BIN' and rn == 0 and i in (10, 12, 33):
                from export_scripted_travel import hq_mathiu_briefing
                cl = next(actor for actor in hq_mathiu_briefing()['actors'] if actor['entity'] == i)['classification']
            ev_raw, ev_dbg = decode_predicate(data, e["stream_offsets"][1], "event", coordinate_ranges=True)
            ev = normalize_event_predicate(ev_raw, ev_dbg)
            if key == ("/VB5A2.BIN", 0, 19):
                full, _ = decode_predicate(data, e["stream_offsets"][1], "event", coordinate_ranges=True, full=True)
                if {"kind": "party_count_equals", "count": 6} not in full["terms"]:
                    raise ValueError("Kirkis's full-party event lost its party size predicate")
                ev = full
            if key == ('/VB4.BIN', 0, 1):
                # The incomplete briefing could set this bit in an older save.
                started = {'kind': 'story_mask_clear', 'flag': {'id': story_id(198), 'mask': 8}}
                ev['terms'].remove(started)
            if key in (('/VB5B3.BIN', 0, 84), ('/VB5C4.BIN', 0, 95)):
                # Approach the council to meet Kasumi while her interaction actor is off map.
                ev['terms'].remove({'kind': 'story_mask_set', 'flag': {'id': story_id(233), 'mask': 64}})
                ev['terms'].extend({'kind': 'coordinate_range', 'coordinate': {'axis': axis, 'first': low, 'last': high}}
                                   for axis, low, high in (('x', 55, 57), ('y', 22, 24)))
            approach = SOUTH_EXIT_APPROACH.get(key)
            if approach is not None:
                for term in ev["terms"]:
                    if term["kind"] == "coordinate_range" and term["coordinate"]["axis"] == "y":
                        coordinate = term["coordinate"]
                        assert coordinate["first"] == approach + 1, key
                        coordinate["first"] = approach

            prog_conditions, selection_terms, cl_terms, trigger = resolve_selection_and_conditions(fname, rn, i, e, cl, ev, hw, hh)
            inherited_interaction = trigger == 'interaction' and i in inherited
            if i in owner_entities:
                cl, _ = decode_predicate(data, e['stream_offsets'][0], 'classification', full=True)
                cl_terms = list(cl['terms'])
            if inherited_interaction:
                cl = {'pointer_state': 'null', 'terms': []}
                cl_terms = []
                prog_conditions = [term for term in ev['terms'] if term['kind'] in ('story_mask_set', 'story_mask_clear')]
            if key == ("/VA3.BIN", 1, 38):
                prog_conditions.extend(cl_terms)
            prog_id = f"{room_id}_e{i:02d}_{trigger}"

            unbound_predicates = (
                reserved_cl
                or any(term.get('semantics') in ('event_predicate_09', 'event_predicate_0a', 'event_predicate_0e', 'event_predicate_10', 'event_predicate_11', 'event_predicate_13', 'event_predicate_14', 'event_predicate_16', 'event_predicate_19')
                       for term in ev['terms'] if term['kind'] == 'unsupported')
                or (trigger == 'interaction' and not inherited_interaction
                    and any(term['kind'] not in ('story_mask_set', 'story_mask_clear', 'recruit_present', 'recruit_absent', 'stage_at_least', 'party_excludes')
                            for term in cl_terms))
            )
            trial_pool = pool.fork()
            trial_tracks = list(room_tracks)
            compiled = None if unbound_predicates else compile_program(
                fname, rn, i, e, data, rt_off, t_arr_off, grids, room_id, prog_id,
                trial_pool, prog_conditions, selection_terms, trigger, hw, hh, trial_tracks,
                with_crossing=with_crossing, battle_data=battle_data, combat_party=combat_party, file_slots=file_slots, world_regions=world_regions, world_entries=world_entries, movable_entities=movable_entities, entities=ents,
                wheel_sounds=wheel_sounds if standard_wheel else None,
                scenery_model=scenery_model,
            )
            if compiled is not None:
                pool, room_tracks = trial_pool, trial_tracks

            if compiled is None and i in actor_initializers and trigger == 'initialization':
                compiled = ({'id': prog_id, 'entry': 'initialization', 'entity': i, 'trigger': 'none',
                             'conditions': prog_conditions, 'selection': [],
                             'commands': [dict(command) for command in actor_initializers[i]]}, [], [])

            # Determine coordinate placement
            if key in PLACEMENT_OVERRIDES and not inherited_interaction:
                px, py = PLACEMENT_OVERRIDES[key]
                x_h, y_h = px // 8, py // 8
            else:
                x_h, y_h = e["x_half"], e["y_half"]
                px, py = x_h * 8, y_h * 8

            placed = 0 < x_h < hw and 0 < y_h < hh
            raw_cid = e["id"]
            is_char_record = bool(raw_cid)
            if inherited_interaction:
                is_char_record = False
            if trigger == "interaction" and not (e["flags"] & 0x101):
                is_char_record = False
            pop_cand = is_char_record and (bool(e["flags"] & 0x101) or (compiled is not None and trigger == "interaction"))
            if compiled is not None and trigger == "interaction":
                assert placed or inherited_interaction or i in movable_entities, f"{key} interaction not placed: ({px},{py})"

            if is_char_record:
                role = "character"
                src_cid = raw_cid
                res_domain = "active_party_character" if (e["flags"] & 0x200) else "area_character_context"
                res_id = f"{fname[1:4].lower()}_character_{src_cid:03d}"
                placement = "placed" if placed else ("unpositioned" if (x_h == 0 and y_h == 0) else "off_map_staging")
            else:
                role = "initialization" if (e["flags"] & 0x10) else "event"
                src_cid = None
                res_domain = None
                res_id = None
                placement = "placed" if trigger == "interaction" and placed and not inherited_interaction else "not_applicable"

            init_ord = None
            if role == "initialization":
                init_ord = init_order
                init_order += 1
                trigger = "initialization"

            cl_out = {
                "pointer_state": "present" if (cl["pointer_state"] == "present" or (compiled is not None and trigger == "interaction" and not inherited_interaction) or cl_terms) else "null",
                "terms": cl_terms if (cl["pointer_state"] == "present" or (compiled is not None and trigger == "interaction") or cl_terms) else [],
            }
            ev_terms_out = []
            for t in ev["terms"]:
                if t['kind'] == 'party_absent' and trigger == 'initialization' and i in actor_initializers:
                    ev_terms_out.append({'kind': 'party_excludes', 'character_id': t['index']})
                elif t["kind"] not in ("unsupported", "party_absent"):
                    ev_terms_out.append(t)
            for cond in prog_conditions[len([t for t in ev["terms"] if t["kind"] in ("story_mask_set", "story_mask_clear")]):]:
                ev_terms_out.append({"kind": cond["kind"], "flag": cond["flag"]})
            if trigger == "interaction" and not any(t["kind"] == "interaction" for t in ev_terms_out):
                ev_terms_out.append({"kind": "interaction"})
            ev_out = {
                "pointer_state": "present" if (compiled is not None or ev_terms_out) else ev["pointer_state"],
                "terms": ev_terms_out,
            }

            for cond in cl_out["terms"] + prog_conditions:
                if 'flag' in cond:
                    story_indices.add(int(cond["flag"]["id"][9:]))

            if compiled is not None:
                prog, anchs, pfxs = compiled
                for c in prog["commands"]:
                    if c.get("flag"):
                        story_indices.add(int(c["flag"]["id"][9:]))
                ir_programs.append(prog)
                pop_programs.append({"id": prog_id, "namespace": content_schema, "content_id": content_id})
                all_anchors.extend(anchs)
                all_prefixes.extend(pfxs)
                ev_ref = {"reference": f"{room_id}_entity_{i:02d}_stream", "status": "resolved", "program_id": prog_id}
            else:
                ev_ref = {"reference": f"{room_id}_entity_{i:02d}_stream", "status": "source_only", "program_id": None}

            pop_entities.append({
                "id": f"{room_id}_entity_{i:02d}",
                "source_order": i,
                "record_role": role,
                "population_candidate": bool(pop_cand),
                "source_character_id": src_cid,
                "resource_id": res_id,
                "resource_domain": res_domain,
                "position": {"source_x": x_h, "source_y": y_h, "x": px, "y": py, "placement": placement},
                "classification": cl_out,
                "event_selection": ev_out,
                "trigger": trigger,
                "initialization_order": init_ord,
                "event": ev_ref,
            })

            # Visible actors require a character identity and an exported clip.
            party_graphic = with_crossing and fname == '/VB7.BIN' and rn == 4 and i in (6, 7, 8, 9)
            sprite_cid = raw_cid if (is_char_record and (raw_cid in binds or party_graphic)) else None
            clip_key = f"{room_id}_character_{sprite_cid:03d}" if sprite_cid is not None else None
            clips = art.get("actor_clips", {}).get(clip_key)
            staged = (placement == 'off_map_staging' and clip_key in art['character_clips'] and (i in owner_entities or (standard_wheel and i == 6))) or (with_crossing and placement == 'off_map_staging' and clips
                      and ((fname == '/VB5.BIN' and rn == 0 and i == 2)
                           or (fname == '/VB7.BIN' and rn == 4 and i in (10, 11))
                           or (fname == '/VB5A2.BIN' and rn == 0 and i == 33)
                           or (fname == '/VB3.BIN' and rn == 2 and i in (1, 2))
                           or (fname == '/VB3.BIN' and rn == 28 and i == 6)))
            inherited_owner = compiled is not None and compiled[0].get('owner_actor') is not None
            if pop_cand and not inherited_owner and (placed or staged) and sprite_cid is not None and cl_out["pointer_state"] == "present":
                if clip_key in art["character_clips"] and len(room_actors) < 64:
                    cond_sig = tuple(sorted(json.dumps(t, sort_keys=True, separators=(',', ':')) for t in cl_out['terms']))
                    if staged or (px, py, cond_sig) not in occupied_sprite_keys:
                        occupied_sprite_keys.add((px, py, cond_sig))
                        actor_id = f"{room_id}_actor_{i:02d}_{sprite_cid:03d}"
                        room_actors.append({
                            "id": actor_id,
                            "entity": i,
                            "facing": "down",
                            "poses": art["character_clips"][clip_key],
                        })
                        if clips:
                            room_actors[-1]["clips"] = clips
                        if with_crossing and fname == '/VB3.BIN':
                            from export_scripted_travel import kouan_entry, kouan_wheel
                            resident = kouan_wheel()['monster_actor'] if rn == 28 else next(row for row in kouan_entry()['residents'] if (row['room'], row['entity']) == (rn, i))
                            if resident['character'] != sprite_cid or resident['position_pixels'] != [px, py]:
                                raise ValueError('Kouan resident identity changed')
                            room_actors[-1]['facing'] = resident['facing']
                            room_actors[-1]['speed'] = resident['speed']
                        if with_crossing and fname == '/VB7.BIN' and rn == 4:
                            from export_scripted_travel import hq_founding
                            original = next(actor for actor in hq_founding()['actors'] if actor['entity'] == i)
                            if original['character'] != sprite_cid or original['appearance']['speed'] != 0 or original['appearance']['auto_animate']:
                                raise ValueError('unsupported founding ordinary actor setup')
                            if staged and (original['initial_pixels'] != [2040, 2040] or [px, py] != original['initial_pixels']):
                                raise ValueError('founding staged actor coordinates changed')
                            room_actors[-1]['facing'] = original['appearance']['facing']
                            if party_graphic:
                                if original['resource_lookup'] != {'kind': 'party', 'required_party_graphic': sprite_cid} or sprite_cid in binds:
                                    raise ValueError('founding party resource fallback disagrees with area table')
                                room_actors[-1]['required_party_graphic'] = sprite_cid
                        if with_crossing and key == ("/VB5A2.BIN", 0, 8):
                            from export_scripted_travel import hq_auxiliary_party
                            room_actors[-1]['entry_placement'] = hq_auxiliary_party()['actor']['entry_placement']
                        if with_crossing and fname == '/VB5A2.BIN' and rn == 0 and i in (10, 12, 33):
                            from export_scripted_travel import hq_mathiu_briefing
                            original = next(actor for actor in hq_mathiu_briefing()['actors'] if actor['entity'] == i)
                            if original['character'] != sprite_cid or original['initial_pixels'] != [px, py] or original['appearance']['speed'] != 0 or original['appearance']['auto_animate']:
                                raise ValueError('unsupported briefing actor setup')
                            room_actors[-1]['facing'] = original['appearance']['facing']
                        ir_actors.append({"id": actor_id})

        if with_crossing and (fname, rn) == ('/VB3.BIN', 0):
            from export_scripted_travel import kouan_giovanni
            original = kouan_giovanni()
            key = 'vb3_room_0_character_035'
            if key not in art.get('actor_clips', {}):
                raise ValueError('Giovanni scene needs verified Viktor clips')
            actor_id = original['viktor']['actor']
            room_actors.append({'id': actor_id, 'entity': 12, 'facing': original['viktor']['facing'],
                                'poses': art['character_clips'][key], 'clips': art['actor_clips'][key],
                                'scene_actor': {'character': 35, 'x': 96, 'y': 424}})
            ir_actors.append({'id': actor_id})

        if with_crossing and (fname, rn) == ('/VB3.BIN', 0):
            key = 'vb3_room_0_character_035'
            actor_id = 'vb3_room_0_approach_viktor'
            room_actors.append({'id': actor_id, 'entity': 15, 'facing': 'down',
                                'poses': art['character_clips'][key], 'clips': art['actor_clips'][key],
                                'scene_actor': {'character': 35, 'x': 248, 'y': 360}})
            ir_actors.append({'id': actor_id})

        if with_crossing and (fname, rn) == ('/VB3.BIN', 2):
            from export_scripted_travel import krin_plan
            for variant in krin_plan()['variants']:
                for actor in variant['scene_actors']:
                    key = f"vb5a2_room_0_character_{actor['character']:03d}"
                    if key not in art.get('actor_clips', {}): raise ValueError('Krin scene companion clips missing')
                    x, y = actor['spawn_pixels']
                    room_actors.append({'id': actor['actor'], 'entity': variant['entity'],
                                        'facing': ('down', 'up', 'left', 'right')[actor['direction_operand']],
                                        'poses': art['character_clips'][key], 'clips': art['actor_clips'][key],
                                        'scene_actor': {'character': actor['character'], 'x': x, 'y': y}})
                    ir_actors.append({'id': actor['actor']})

        if (with_crossing or standard_wheel) and (fname, rn) == ('/VB3.BIN', 28):
            from export_scripted_travel import kouan_wheel
            wheel = kouan_wheel()
            key = 'vb3_room_28_character_008'
            clips = wheel_clips if standard_wheel else art.get('actor_clips', {}).get(key)
            if not clips: raise ValueError('wheel scene Hero clips missing')
            poses = [clip['frames'][clip['idle_frame']] for clip in clips]
            for actor in [wheel['return_scene']['actor'], *(v['actor'] for v in wheel['variants'] if 'actor' in v)]:
                x, y = actor['spawn_pixels']
                room_actors.append({'id': actor['id'], 'entity': actor['entity'], 'facing': 'down',
                                    'poses': poses, 'clips': clips,
                                    'scene_actor': {'character': 8, 'x': x, 'y': y}})
                ir_actors.append({'id': actor['id']})

        evening = None if with_crossing else toran_evening(room_id, len(pop_entities), pool, grids, battle_data)
        if evening is not None:
            event, program, anchors, indices = evening
            pop_entities.append(event)
            ir_programs.append(program)
            pop_programs.append({"id": program["id"], "namespace": content_schema, "content_id": content_id})
            all_anchors.extend(anchors)
            story_indices.update(indices)

        if room_id == 'vb5a2_room_0' and not with_crossing and '/VB5B3.BIN' in file_cache:
            later_council = file_cache['/VB5B3.BIN'][0]
            if any(not later_council.startswith(bytes.fromhex(operands), site) for site, operands in (
                (0x2EC58, '09 e6 40'), (0x2ECAB, '50 00 5a'), (0x2ECC4, '09 e6 80'), (0x2ED21, '50 00 57'),
            )):
                raise ValueError('Toran prison briefing and order grants changed')
            # Reuse the council staging point so party selection remains available at the other station.
            council = next(program for program in ir_programs if program['entity'] == 42)
            program_id = f'{room_id}_rescue_council'
            entity = len(pop_entities)
            prerequisite = {'id': story_id(194), 'mask': 1}
            conditions = [{'kind': 'story_mask_set', 'flag': prerequisite},
                          {'kind': 'story_mask_clear', 'flag': {'id': story_id(230), 'mask': 128}}]
            pop_entities.append({**pop_entities[42], 'id': f'{program_id}_trigger', 'source_order': entity,
                                 'event_selection': {'pointer_state': 'present', 'terms': conditions},
                                 'initialization_order': init_order,
                                 'event': {'reference': f'{program_id}_authored', 'status': 'resolved', 'program_id': program_id}})
            ir_programs.append({**council, 'id': program_id, 'entity': entity, 'conditions': conditions,
                                'commands': [command.copy() for command in council['commands']]})
            pop_programs.append({'id': program_id, 'namespace': content_schema, 'content_id': content_id})
        council_actor = {'vb5a2_room_0': 38, 'vb5b3_room_0': 12, 'vb5c4_room_0': 12}.get(room_id)
        if council_actor is not None and not with_crossing and '/VB5B3.BIN' in file_cache:
            prerequisite = {'id': story_id(194), 'mask': 1}
            advisor, = (actor for actor in room_actors if actor['entity'] == council_actor)
            expanded = room_id != 'vb5a2_room_0'
            mathiu = f'{room_id}_rescue_advisor' if expanded else advisor['id']
            for step in (
                ('rescue_briefing', prerequisite, 64, 'mathiu_s_letter__source_90',
                 ('Take my letter to Antei.', 'Kimberly and Tesla can help us', 'get inside Soniere Prison.')),
                ('prison_orders', {'id': story_id(195), 'mask': 8}, 128, 'fake_orders',
                 ('The forged orders are ready.', 'Show them to the prison guard.')),
            ):
                event, program, anchors = toran_prison_briefing(room_id, len(pop_entities), mathiu, pool, step)
                if expanded and step[0] == 'rescue_briefing':
                    # The resident advisor is outside the connected council floor during the rescue.
                    resident = pop_entities[council_actor]
                    event.update({key: resident[key] for key in (
                        'record_role', 'population_candidate', 'source_character_id', 'resource_id', 'resource_domain')})
                    event['position'] = {'source_x': 58, 'source_y': 19, 'x': 464, 'y': 152, 'placement': 'placed'}
                    event['classification'] = {'pointer_state': 'present', 'terms': [
                        {'kind': 'story_mask_set', 'flag': prerequisite},
                        {'kind': 'story_mask_clear', 'flag': {'id': story_id(230), 'mask': 128}},
                    ]}
                    program.pop('owner_actors')
                    program['owner_actor'] = mathiu
                    room_actors.append({**advisor, 'id': mathiu, 'entity': event['source_order']})
                    ir_actors.append({'id': mathiu})
                pop_entities.append(event)
                ir_programs.append(program)
                pop_programs.append({'id': program['id'], 'namespace': content_schema, 'content_id': content_id})
                all_anchors.extend(anchors)
            story_indices.update((194, 195, 230))
            if expanded:
                conditions = [{'kind': 'story_mask_set', 'flag': {'id': story_id(230), 'mask': 64}},
                              {'kind': 'story_mask_clear', 'flag': {'id': story_id(195), 'mask': 8}}]
                program_id = f'{room_id}_rescue_party'
                entity = len(pop_entities)
                pop_entities.append({**event, 'id': f'{program_id}_trigger', 'source_order': entity,
                                     'event_selection': {'pointer_state': 'present', 'terms': [*conditions, {'kind': 'interaction'}]},
                                     'event': {'reference': f'{program_id}_authored', 'status': 'resolved', 'program_id': program_id}})
                ir_programs.append({**program, 'id': program_id, 'entity': entity, 'conditions': conditions,
                                    'commands': [{'kind': 'party_select'}, {'kind': 'end_stream'}]})
                pop_programs.append({'id': program_id, 'namespace': content_schema, 'content_id': content_id})

        actors_by_entity = {actor['entity']: actor['id'] for actor in room_actors if actor.get('scene_actor') is None}
        rejected = set()
        for program in ir_programs:
            if any('_source_actor' in command for command in program['commands']):
                if any(command['_source_actor'] not in actors_by_entity for command in program['commands'] if '_source_actor' in command):
                    rejected.add(program['id'])
                    continue
                for command in program['commands']:
                    if '_source_actor' in command:
                        command['actor'] = actors_by_entity[command.pop('_source_actor')]
            if program['trigger'] != 'interaction' or program['entity'] not in inherited:
                continue
            owners = inherited[program['entity']]
            if program.get('owner_actor') is None:
                if not owners or len(owners) > 64 or any(owner not in actors_by_entity for owner in owners):
                    rejected.add(program['id'])
                    continue
                program['owner_actors'] = [actors_by_entity[owner] for owner in owners]
                for anchor in all_anchors:
                    if anchor['program'] == program['id'] and 'point' in anchor:
                        del anchor['point']
                        anchor['interaction_actor'] = True
        placed_actors = {command.get('actor') for program in ir_programs if program['id'] not in rejected
                         for command in program['commands'] if command['kind'] == 'place_actor'}
        active_program_entities = {program['entity'] for program in ir_programs if program['entry'] == 'initialization' and program['id'] not in rejected}
        movable_entities = {command['_source_actor'] for init_idx, commands in actor_initializers.items()
                            if init_idx in active_program_entities for command in commands if command['kind'] == 'place_actor'}
        for program in ir_programs:
            if program['trigger'] != 'interaction' or program['entity'] not in movable_entities or program['entity'] in inherited:
                continue
            actor = actors_by_entity.get(program['entity'])
            if actor not in placed_actors:
                rejected.add(program['id'])
                continue
            program.setdefault('owner_actor', actor)
            for anchor in all_anchors:
                if anchor['program'] == program['id'] and 'point' in anchor:
                    del anchor['point']
                    anchor['interaction_actor'] = True
        if rejected:
            ir_programs = [program for program in ir_programs if program['id'] not in rejected]
            pop_programs = [program for program in pop_programs if program['id'] not in rejected]
            all_anchors = [anchor for anchor in all_anchors if anchor['program'] not in rejected]
            all_prefixes = [prefix for prefix in all_prefixes if prefix['program'] not in rejected]
            for entity in pop_entities:
                if entity['event']['program_id'] in rejected:
                    entity['event'].update(status='source_only', program_id=None)

        if (not ir_programs or len(ir_programs) > 64) and content_schema == CONTENT_SCHEMA:
            content_schema = "suikoden-event-ir/2"
            for program in pop_programs:
                program["namespace"] = content_schema
        assert len(ir_programs) <= 255, f"{room_id} exceeded 255 programs: {len(ir_programs)}"

        if with_crossing and fname == "/VB5.BIN" and rn == 0:
            from export_scripted_travel import outputs
            dock, _ = outputs()
            for speech in dock["dock_arrival"]["dialogues"]:
                pool.get_body_text(speech["tokens"])
                prefix = pool.get_speaker_text(speech["speaker_name"], source_tokens=speech["prefix_tokens"])
                if next(text["tokens"] for text in pool.prefix_texts if text["id"] == prefix) != speech["prefix_tokens"]:
                    raise ValueError("native speaker prefix disagrees with source name/control")
                if pool.get_image(speech["character"]) is None:
                    raise ValueError("dock portrait missing from candidate art")
                portrait = pool.images[pool.image_map[speech["character"]]]
                if any(portrait[key] != speech["portrait"][key] for key in ("plane_sha256", "palette_sha256")):
                    raise ValueError("dock portrait disagrees with loaded character portrait")

        texts_list, text_idx_map = pool.finalized_texts_and_index()
        resolved_prefixes = []
        for p in all_prefixes:
            p_copy = dict(p)
            tid = p_copy.pop("_text_id")
            if tid is not None:
                p_copy["text"] = text_idx_map[tid]
            else:
                p_copy["text"] = None
            resolved_prefixes.append(p_copy)

        assert len(all_anchors) <= 1024, f"{room_id} anchors > 1024"
        assert len(resolved_prefixes) <= 1024, f"{room_id} prefixes > 1024"
        assert len(pool.images) <= 64, f"{room_id} images > 64"

        if (fname, rn) == ('/VB3.BIN', 28) and any(command['kind'] == 'branch_wheel' for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/25'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(command['kind'] == 'hide_hero' for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/24'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(command['kind'] == 'item_overload' for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/23'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(command['kind'] in ('wheel_spin', 'wheel_restore', 'wheel_turn', 'wheel_align', 'branch_wheel') for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/22'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(command['kind'] == 'field_music' and command['music'] == 'wheel' for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/21'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(command['kind'] in ('party_gain_experience', 'party_lose_experience') for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/20'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(command['kind'] == 'field_music' and command['music'] in ('area_b', 'mansion') for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/19'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(command['kind'] == 'show_prop' for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/18'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(program.get('owner_actor') is not None for program in ir_programs) or any(command['kind'] == 'fade_in' for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/17'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(command['kind'] == 'spawn_actor' for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/16'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(command['kind'] == 'party_select' for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/15'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(command["kind"] in ("field_effect", "wait_field_effect", "party_dismiss")
               or (command['kind'] == 'area_action' and command['area']['kind'] in ('auxiliary_party_add', 'auxiliary_party_remove'))
               or (command['kind'] == 'place_actor' and command.get('x') is not None and command.get('y') is not None)
               or (program['entry'] == 'ordinary' and command['kind'] == 'field_music' and command['music'] in ('headquarters', 'founding'))
               or (command['kind'] == 'play_sound' and command.get('cue') == 0x813)
               for program in ir_programs for command in program["commands"]):
            content_schema = "suikoden-event-ir/14"
            for program in pop_programs:
                program["namespace"] = content_schema
        elif any(command['kind'] in ('party_load', 'advance_character') for program in ir_programs for command in program['commands']):
            if int(content_schema.rsplit('/', 1)[1]) < 10:
                content_schema = 'suikoden-event-ir/10'
                for program in pop_programs:
                    program['namespace'] = content_schema
        elif any(
            command["kind"] in ("party_restore", "service", "chest_grant", "money_edit", "room_flag_clear", "world_mode", "recruit_toggle", "recruit_mark_loaded", "fixed_dice")
            for program in ir_programs for command in program["commands"]
        ) or any(sum(command["kind"] == "room_transition" for command in program["commands"]) > 1
                 for program in ir_programs):
            # Recovery and service interactions use campaign effects without enabling newer scene presentation.
            if content_schema == CONTENT_SCHEMA:
                content_schema = "suikoden-event-ir/2"
                for program in pop_programs:
                    program["namespace"] = content_schema

        if any(anchor.get('actor') == 'hero' for anchor in all_anchors) and int(content_schema.rsplit('/', 1)[1]) < 8:
            has_recovery = any(command['kind'] == 'party_restore' for program in ir_programs for command in program['commands'])
            content_schema = 'suikoden-event-ir/14' if has_recovery else 'suikoden-event-ir/8'
            for program in pop_programs:
                program['namespace'] = content_schema

        if any(command.get('return_to_entry') or command.get('retain_world_region') or command.get('world_point') is not None or command.get('world_entry') is not None
               for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/26'
            for program in pop_programs:
                program['namespace'] = content_schema

        from room_battle_package import forward_graph
        if (content_schema in ('suikoden-event-ir/25', 'suikoden-event-ir/26')
                and not forward_graph({'programs': ir_programs})):
            content_schema = 'suikoden-event-ir/27'
            for program in pop_programs:
                program['namespace'] = content_schema

        story_values_pop = [{"id": story_id(idx), "storage": "scenario", "byte_index": idx} for idx in sorted(story_indices)]
        if any(term['kind'] == 'has_item' for program in ir_programs for term in program['selection']) or any(program.get('owner_actors') or (program['entry'] == 'initialization' and any(command['kind'] in ('place_actor', 'place_hero', 'actor_transition', 'set_camera') for command in program['commands'])) for program in ir_programs) or any(pop_entities[actor['entity']]['position']['placement'] == 'off_map_staging' for actor in room_actors if actor.get('scene_actor') is None):
            content_schema = 'suikoden-event-ir/27'
            for program in pop_programs:
                program['namespace'] = content_schema
        if (any(command['kind'] in ('scenery_stage', 'scenery_restore', 'scenery_append') or command.get('if_actor_constructed')
                for program in ir_programs for command in program['commands'])
                or any(command['kind'] == 'place_actor' and program['entry'] == 'ordinary'
                       and next((a.get('clips') is None for a in room_actors if a['id'] == command.get('actor')), False)
                       for program in ir_programs for command in program['commands'])):
            content_schema = 'suikoden-event-ir/29'
            for program in pop_programs:
                program['namespace'] = content_schema
        elif any(command['kind'] == 'camera_push' for program in ir_programs for command in program['commands']):
            content_schema = 'suikoden-event-ir/28'
            for program in pop_programs:
                program['namespace'] = content_schema
        story_values_ir = [{"id": story_id(idx), "storage": "scenario", "byte_index": idx, "initial": 0} for idx in sorted(story_indices)]

        population_obj = {
            "schema": "suikoden-scene-population/4" if any(e["record_role"] == "event" and e["position"]["placement"] == "placed" for e in pop_entities) else "suikoden-scene-population/3" if content_schema != CONTENT_SCHEMA or any(term['kind'] not in ('story_mask_set', 'story_mask_clear', 'unsupported', 'interaction', 'coordinate_range') for entity in pop_entities for predicate in ('classification', 'event_selection') for term in entity[predicate]['terms']) else POPULATION_SCHEMA,
            "id": f"{room_id}_population",
            "source": {
                "file": proof["file"],
                "lba": proof["lba"],
                "size": proof["size"],
                "sha256": proof["sha256"],
                "room": rn,
            },
            "coordinate_contract": {
                "source_units": "half_cell",
                "pixel_units": "pixel",
                "source_to_pixel": "pixel = source * 8",
                "axes": "x_right_y_down",
                "origin": "room_top_left",
                "source_coordinate_max": 255,
                "pixel_coordinate_max": 2040,
                "room_half_width": hw,
                "room_half_height": hh,
            },
            "duplicate_policy": "preserve_source_records",
            "story_values": story_values_pop,
            "programs": pop_programs,
            "entities": pop_entities,
        }
        population_obj["content_sha256"] = sha256_canonical(population_obj)

        if with_crossing and fname == "/VB5.BIN" and rn == 0:
            from export_scripted_travel import outputs
            travel, _ = outputs()
            room_tracks.extend(travel["dock_arrival"]["temporary_tracks"])
            if art.get("actor_clips"):
                room_tracks.extend(travel["dock_arrival"]["ordinary_tracks"])

        content_obj = {
            "schema": content_schema,
            "id": content_id,
            "story_values": story_values_ir,
            "actors": ir_actors,
            "texts": texts_list,
            "tracks": room_tracks,
            "programs": ir_programs,
        }
        if content_schema in ('suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29'):
            from room_battle_package import forward_graph
            content_obj['forward_branches'] = forward_graph(content_obj)
        content_obj["content_sha256"] = sha256_canonical(content_obj)

        dialogue_obj = {
            "schema": "suikoden-field-dialogue/9" if any(anchor.get('actor') == 'hero' for anchor in all_anchors) or with_crossing and (
                fname == '/VB3.BIN' or
                (fname in ("/VB5.BIN", "/VB5A2.BIN", "/VB5AG.BIN") and rn == 0) or
                (fname == '/VB7.BIN' and rn == 4 and any(program['entity'] == 4 for program in ir_programs))) else DIALOGUE_SCHEMA,
            "allow_pages": True,
            "allow_substitution": True,
            "default_speed": "normal",
            "configuration": [{"normal_pace": 3, "pressed_pace": 1}] * 3,
            "anchors": all_anchors,
            "texts": texts_list,
            "prefixes": resolved_prefixes,
            "images": pool.images,
            "descriptor_changes": [],
        }
        if any(anchor.get("interaction_actor") for anchor in all_anchors):
            dialogue_obj["schema"] = "suikoden-field-dialogue/10"
        dialogue_obj["content_sha256"] = sha256_canonical(dialogue_obj)

        room_bindings.append({
            "room": room_id,
            "population": population_obj,
            "content": content_obj,
            "dialogue": dialogue_obj,
            "actors": room_actors,
        })
        if with_crossing and (fname, rn) == ('/VB7.BIN', 4) and any(
                command['kind'] == 'field_effect' for program in ir_programs for command in program['commands']):
            from export_scripted_travel import hq_founding
            room_bindings[-1]['field_effect_blend'] = hq_founding()['field_effect_blend']
        if with_crossing and (fname, rn) == ('/VB3.BIN', 20):
            from export_scripted_travel import kouan_juppo
            room_bindings[-1]['queues'] = kouan_juppo()['formation']
            room_bindings[-1]['party_actors'] = art['party_actors'][room_id]
        if with_crossing and fname == "/VB5.BIN" and rn == 0:
            from export_scripted_travel import outputs
            travel, _ = outputs()
            room_bindings[-1]["queues"] = travel["dock_arrival"]["formation"]
            party_art = art.get("party_actors", {}).get(room_id, [])
            if party_art:
                room_bindings[-1]["party_actors"] = party_art

    kinds = {command["kind"] for room in room_bindings
             for program in room["content"]["programs"] for command in program["commands"]}
    packet_schema = SCHEMA
    if (any(room['content']['schema'] == 'suikoden-event-ir/29' for room in room_bindings)
            or any(command.get('facility') is not None for room in room_bindings
                   for program in room['content']['programs'] for command in program['commands'])):
        packet_schema = CURRENT_SCHEMA
    elif any(room['content']['schema'] == 'suikoden-event-ir/28' for room in room_bindings):
        packet_schema = 'suikoden-battle-field-events/51'
    elif any(room['content']['schema'] == 'suikoden-event-ir/27' for room in room_bindings):
        packet_schema = 'suikoden-battle-field-events/50'
    elif any(room['content']['schema'] in ('suikoden-event-ir/26', 'suikoden-event-ir/27') for room in room_bindings):
        packet_schema = 'suikoden-battle-field-events/49'
    elif any(room['content']['schema'] == 'suikoden-event-ir/25' for room in room_bindings):
        packet_schema = 'suikoden-battle-field-events/48'
    elif 'hide_hero' in kinds:
        packet_schema = 'suikoden-battle-field-events/47'
    elif 'item_overload' in kinds:
        packet_schema = 'suikoden-battle-field-events/46'
    elif kinds & {'wheel_spin', 'wheel_restore', 'wheel_turn', 'wheel_align', 'branch_wheel'}:
        packet_schema = 'suikoden-battle-field-events/45'
    elif any(command['kind'] == 'field_music' and command['music'] == 'wheel' for room in room_bindings for program in room['content']['programs'] for command in program['commands']):
        packet_schema = 'suikoden-battle-field-events/44'
    elif kinds & {'party_gain_experience', 'party_lose_experience'}:
        packet_schema = 'suikoden-battle-field-events/43'
    elif any(len(room.get('party_actors', [])) > 5 for room in room_bindings):
        packet_schema = 'suikoden-battle-field-events/42'
    elif any(command['kind'] == 'field_music' and command['music'] in ('area_b', 'mansion') for room in room_bindings for program in room['content']['programs'] for command in program['commands']):
        packet_schema = 'suikoden-battle-field-events/41'
    elif 'show_prop' in kinds:

        packet_schema = 'suikoden-battle-field-events/40'
    elif 'fade_in' in kinds or any(program.get('owner_actor') is not None for room in room_bindings for program in room['content']['programs']):
        packet_schema = 'suikoden-battle-field-events/39'
    elif 'spawn_actor' in kinds:

        packet_schema = 'suikoden-battle-field-events/38'
    elif 'party_select' in kinds:

        packet_schema = 'suikoden-battle-field-events/37'
    elif any(room.get('field_effect_blend') is not None for room in room_bindings):
        packet_schema = "suikoden-battle-field-events/36"
    elif any(actor.get('required_party_graphic') is not None for room in room_bindings for actor in room['actors']):
        packet_schema = "suikoden-battle-field-events/35"
    elif any((command['kind'] == 'field_music' and command['music'] == 'founding') or (command['kind'] == 'play_sound' and command.get('cue') == 0x813)
           for room in room_bindings for program in room['content']['programs'] for command in program['commands']):
        packet_schema = "suikoden-battle-field-events/34"
    elif any((program['entry'] == 'ordinary' and command['kind'] == 'field_music' and command['music'] == 'headquarters')
           or (command['kind'] == 'place_actor' and command.get('x') is not None and command.get('y') is not None)
           for room in room_bindings for program in room['content']['programs'] for command in program['commands']):
        packet_schema = "suikoden-battle-field-events/33"
    elif any(actor.get('entry_placement') is not None for room in room_bindings for actor in room['actors']):
        packet_schema = "suikoden-battle-field-events/32"
    elif any(command['kind'] == 'area_action' and command['area']['kind'] in ('auxiliary_party_add', 'auxiliary_party_remove')
           for room in room_bindings for program in room['content']['programs'] for command in program['commands']):
        packet_schema = "suikoden-battle-field-events/31"
    elif "party_dismiss" in kinds:
        packet_schema = "suikoden-battle-field-events/30"
    elif kinds & {"party_restore", "field_effect", "wait_field_effect"}:
        packet_schema = "suikoden-battle-field-events/29"
    elif with_crossing:
        if "field_music" in kinds:
            packet_schema = "suikoden-battle-field-events/28"
        elif any(actor.get("clips") for room in room_bindings for actor in room["actors"]):
            packet_schema = "suikoden-battle-field-events/25"
        elif any(room.get("party_actors") for room in room_bindings):
            packet_schema = "suikoden-battle-field-events/24"
        else:
            packet_schema = "suikoden-battle-field-events/23"
    if rooms != OPENING_ROOMS and not with_crossing:
        return {"schema": packet_schema, "rooms": room_bindings}
    return {
        "schema": packet_schema,
        "opening_route": {
            "dungeon": "vaa_room_1",
            "palace": "vaa_room_0",
            "first_town": "va1_room_0",
            "initial_party": ["cleo", "ted"],
        },
        "opening_battles": [
            {"room": "va2_room_0", "program": "va2_room_0_e35_ordinary"},
            {"room": "va2_room_0", "program": "va2_room_0_e36_ordinary"},
            {"room": "va2_room_0", "program": "va2_room_0_e37_ordinary"},
            {"room": "va4_room_3", "program": "va4_room_3_e03_ordinary"},
            {"room": "va7_room_9", "program": "va7_room_9_e02_ordinary"},
            {"room": "va7_room_9", "program": "va7_room_9_e03_ordinary"},
            {"room": "va7_room_13", "program": "va7_room_13_e01_ordinary"},
            {"room": "va7_room_13", "program": "va7_room_13_e03_ordinary"},
        ],
        "opening_world_exits": [
            {"room": "vb2_room_0", "program": "vb2_room_0_e00_ordinary"},
            {"room": "vb2_room_0", "program": "vb2_room_0_e01_ordinary"},
            {"room": "vb1_room_0", "program": "vb1_room_0_e00_ordinary"},
            {"room": "va1_room_0", "program": "va1_room_0_e00_ordinary"},
            {"room": "va1_room_0", "program": "va1_room_0_e43_ordinary"},
            {"room": "va1_room_0", "program": "va1_room_0_e44_ordinary"},
            {"room": "va2_room_0", "program": "va2_room_0_e00_ordinary"},
            {"room": "va2_room_0", "program": "va2_room_0_e01_ordinary"},
            {"room": "va2_room_0", "program": "va2_room_0_e02_ordinary"},
            {"room": "va8_room_0", "program": "va8_room_0_e01_ordinary"},
            {"room": "va8_room_9", "program": "va8_room_9_e02_ordinary"},
            {"room": "va5_room_0", "program": "va5_room_0_e00_ordinary"},
            {"room": "va3_room_0", "program": "va3_room_0_e00_ordinary"},
            {"room": "va3_room_0", "program": "va3_room_0_e01_ordinary"},
            {"room": "va7_room_0", "program": "va7_room_0_e01_ordinary"},
            {"room": "va6_room_1", "program": "va6_room_1_e00_ordinary"},
            {"room": "va6_room_1", "program": "va6_room_1_e01_ordinary"},
            {"room": "va6_room_1", "program": "va6_room_1_e02_ordinary"},
            {"room": "va6_room_2", "program": "va6_room_2_e00_ordinary"},
            {"room": "va6_room_2", "program": "va6_room_2_e01_ordinary"},
            {"room": "va6_room_2", "program": "va6_room_2_e02_ordinary"},
            {"room": "vb6_room_0", "program": "vb6_room_0_e01_ordinary"},
        ],
        "rooms": room_bindings,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--art", type=Path, default=ROOT / "kit/work/build/opening/canonical_field_art.json")
    parser.add_argument("--out", type=Path, default=ROOT / "game/assets/campaign/opening/field_events.json")
    parser.add_argument("--include-crossing", action="store_true", help="include the boat departure and initial island in a separate candidate export")
    args = parser.parse_args()

    if args.include_crossing and args.out.resolve() == (ROOT / "game/assets/campaign/opening/field_events.json").resolve():
        parser.error("--include-crossing requires a separate candidate --out")
    packet = build_package(args.art, with_crossing=args.include_crossing)
    payload = (json.dumps(packet, separators=(",", ":")) + "\n").encode("utf-8")
    assert len(payload) <= 64 * 1024 * 1024, f"Packet exceeds 64 MiB: {len(payload)}"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(payload)

    prog_count = sum(len(r["content"]["programs"]) for r in packet["rooms"])
    text_count = sum(len(r["content"]["texts"]) for r in packet["rooms"])
    actor_count = sum(len(r["actors"]) for r in packet["rooms"])
    print(f"Exported {len(packet['rooms'])} rooms, {prog_count} programs, {text_count} unique texts, {actor_count} actors ({len(payload)} bytes) -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
