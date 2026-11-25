#!/usr/bin/env python3
"""Add source-backed opening party profiles to the canonical package."""
from __future__ import annotations

import json
import argparse
import subprocess
import sys
from pathlib import Path

from PIL import Image
import character_table
import export_first_room
import export_route_battles
import export_va2_battle
import journey_battle
import journey_magic
import preparation
import export_party_ranged_actors
import export_physical_runes

ROOT = Path(__file__).resolve().parents[2]
CANONICAL = ROOT / "kit/work/build/canonical"


def reaction_animations(actors: dict) -> dict[str, set[int]]:
    programs = {program['id']: program for program in actors.get('programs', {}).get('programs', [])}
    counter = actors.get('counter', {})
    result = {}
    for reaction in (*counter.get('melee', {}).get('party_reactions', ()), *counter.get('defenders', ())):
        animations = result.setdefault(reaction['id'], {1})
        for key in ('response_program', 'return_program', 'strike_program'):
            if program := reaction.get(key):
                animations.update(instruction['command']['animation'] for instruction in programs[program]['instructions']
                                  if 'animation' in instruction.get('command', {}))
    return result


def bind_reaction_poses(trial: dict, section: dict, atlas_y: int, animations: set[int]) -> None:
    graphics = trial.setdefault("unite_graphics", [])
    actor = next((row for row in graphics if row["id"] == section["id"] and row.get("record") is None), None)
    if actor is None:
        actor = {"id": section["id"], "poses": []}
        graphics.append(actor)
    bound = {pose["id"] for pose in actor["poses"]}
    required = {frame['pose'] for animation in animations for frame in section['animations'][animation]['pairs']}
    for index in sorted(required - bound):
        pose = section["poses"][index]
        rect = dict(pose["rect"], y=pose["rect"]["y"] + atlas_y)
        sprite = {"rect": rect, "anchor_x": pose["anchor"]["x"], "anchor_y": pose["anchor"]["y"]}
        actor["poses"].append({"id": index, "sprite": sprite})


def write_trial(trial_path: Path, trial: dict) -> None:
    catalogue = json.loads((ROOT / "game/assets/party_session/catalogue.json").read_text())
    for character in catalogue["characters"]:
        profile = next((p for p in trial["party"] if p["id"] == character["id"]), None)
        if profile is None:
            continue
        seed_rune = character["seed"].get("rune_name")
        if seed_rune:
            rune = next((r for r in trial["systems"]["runes"] if r["name"] == seed_rune), None)
            if rune is not None:
                if profile.get("rune") is None:
                    profile["rune"] = rune["id"]
                allowed = rune.get("allowed_members")
                if allowed is not None and character["id"] not in allowed:
                    allowed.append(character["id"])
        equipped = {item["id"] for item in character["seed"]["inventory"] if item.get("slot") is not None}
        for equipment in trial["systems"]["equipment"]:
            allowed = equipment.get("allowed_members")
            if equipment["id"] in equipped and allowed is not None and character["id"] not in allowed:
                allowed.append(character["id"])
    rune_proof = journey_magic.bind_story_rune(trial["systems"])
    payload = json.dumps(trial, separators=(",", ":")) + "\n"
    if len(payload.encode()) > 4 * 1024 * 1024:
        raise ValueError("opening profiles exceed the native battle content limit")
    proof_path = trial_path.with_name("provenance.json")
    provenance = json.loads(proof_path.read_text())
    provenance["story_rune"] = rune_proof
    trial_path.write_text(payload)
    proof_path.write_text(json.dumps(provenance, indent=2) + "\n")


def export(canonical: Path, work: Path) -> int:
    canonical = Path(canonical).resolve()
    work = Path(work).resolve()
    accepted = (ROOT / "kit/work/accepted").resolve()
    if accepted in (canonical, *canonical.parents) or accepted in (work, *work.parents):
        raise ValueError("opening profiles are candidates; accepted promotion is separate")
    trial_path = canonical / "battle/trial.json"
    if not trial_path.is_file():
        print(f"ERROR: canonical battle content is missing: {trial_path}", file=sys.stderr)
        return 1
    if not (canonical / "battle/actors.png").is_file():
        print("ERROR: canonical battle atlas is missing", file=sys.stderr)
        return 1
    trial = json.loads(trial_path.read_text())
    catalogue = json.loads((ROOT / "game/assets/party_session/catalogue.json").read_text())
    existing = {profile["id"] for profile in trial["party"]}
    to_add = [entry for entry in catalogue["characters"] if entry["id"] not in existing]
    if not to_add:
        write_trial(trial_path, trial)
        export_va2_battle.append_va2_battle(canonical / "battle")
        export_route_battles.append_route_battles(canonical / "battle")
        export_route_battles.append_field_encounters(canonical)
        print("Opening party profiles are already present; atlas unchanged")
        return 0
    binding_path = canonical / 'battle/unites.json'
    reactions = reaction_animations(json.loads(binding_path.read_bytes())) if binding_path.is_file() else {}
    work.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        str(ROOT / ".venv/bin/python"), str(ROOT / "kit/tools/export_battle_sprite_sections.py"),
        "--characters", ",".join(entry["id"] for entry in to_add), "--out", str(work), "--report", str(work / "report.json"),
        "--axis-aligned-fallback",
    ], check=True)
    manifest = json.loads((work / "battle_sprite_sections.json").read_text())
    weapons = json.loads((ROOT / "game/assets/profiles/character_weapons.json").read_text())
    weapon_costs = {entry["id"]: entry["upgrade_costs"] for entry in weapons["characters"]}
    weapon_ranges = {entry["id"]: entry["range_name"] for entry in weapons["characters"]}
    families = json.loads((ROOT / "game/assets/combat_systems/pose_families.json").read_text())
    attack_scripts = {}
    for actor in families["actors"]:
        binding = next((b for b in actor["bindings"] if b["family"] == "attack" and b["state"] == "supported"), None)
        if binding is not None:
            attack_scripts[actor["id"]] = binding["animations"]
    sections = {entry["id"]: entry for entry in manifest["characters"]}
    report = json.loads((work / 'report.json').read_text())
    for character in to_add:
        proof = next(row for row in report['characters'] if row['id'] == character['id'])
        if character['id'] not in attack_scripts:
            section = sections[character['id']]
            scripts = proof.get('scripts', {})
            derived = []
            for slot in ('1', '4'):
                for anim_index in scripts.get(slot, []):
                    if anim_index not in derived and section['animations'][anim_index]['pairs']:
                        derived.append(anim_index)
            if derived:
                attack_scripts[character['id']] = derived
        used = {0, 1, 2, 3, 13, 14, 15, *attack_scripts.get(character['id'], [])} | reactions.get(character['id'], {1})
        if any(issue.get('animation') not in range(256) or issue['animation'] in used for issue in proof.get('unresolved', [])):
            raise ValueError(f"unresolved pose used by opening profile {character['id']}")
    actors = trial["party"]
    atlas = Image.open(canonical / "battle/actors.png").convert("RGBA")
    source = Image.open(work / "battle_sprite_sections.png").convert("RGBA")
    offset = atlas.height
    size = (max(atlas.width, source.width), atlas.height + source.height)
    if size[0] > 4096 or size[1] > 4096:
        raise ValueError("opening battle profiles exceed the runtime atlas")
    combined = Image.new("RGBA", size)
    combined.paste(atlas, (0, 0))
    combined.paste(source, (0, offset))
    actor_atlas = export_first_room.Atlas()
    actor_atlas.image = Image.new("RGBA", (4096, 4096))
    actor_atlas.image.paste(combined, (0, 0))
    actor_atlas.y = combined.height + 1
    source_records = {row['id']: row for row in character_table.records()}
    added_sources = []
    for character in to_add:
        section = sections[character["id"]]
        seed = character["seed"]
        pose = section["poses"][0]
        rect = dict(pose["rect"])
        rect["y"] += offset
        attack = []
        for animation_index in attack_scripts.get(character["id"], []):
            for pair in section["animations"][animation_index]["pairs"]:
                pose_entry = section["poses"][pair["pose"]]
                pose_rect = dict(pose_entry["rect"])
                pose_rect["y"] += offset
                attack.append({"pose": {"rect": pose_rect, "anchor_x": pose_entry["anchor"]["x"], "anchor_y": pose_entry["anchor"]["y"]}, "ticks": pair["ticks"]})
        duration = max(4, sum(frame["ticks"] for frame in attack))
        # shortcut: packages without ranged actor bindings use prototype motion; require those bindings for canonical admission.
        motion = {
            "approach_start": 0,
            "approach": {"ticks": 2, "acceleration_step": 0, "offset": {"x": 0, "y": 0, "z": 0}, "velocity": {"x": 0, "y": 0, "z": 0}},
            "impact_tick": 2,
            "ready_tick": 2,
            "return_start": duration - 2,
            "retreat": {"ticks": 2, "acceleration_step": 0, "offset": {"x": 0, "y": 0, "z": 0}, "velocity": {"x": 0, "y": 0, "z": 0}},
            "duration": duration,
            "stages": [],
        }
        profile = {
            "id": character["id"],
            "name": character["name"],
            "max_hp": seed["max_hp"],
            "level": seed["level"],
            "stats": {
                "attack": seed["stats"][0] + seed["weapon"]["powers"][seed["weapon"]["level"] - 1],
                "skill": seed["stats"][1],
                "defense": seed["stats"][2],
                "speed": seed["stats"][3],
                "magic": seed["stats"][4],
                "luck": seed["stats"][5],
            },
            "sprite": {"rect": rect, "anchor_x": pose["anchor"]["x"], "anchor_y": pose["anchor"]["y"]},
            "foot_offset_y": 0,
            "attack": attack,
            "motion": motion,
            "weapon_range": weapon_ranges[character["source_character_id"]],
            "growth": list(character["growth"]),
            "rune_locked": seed["rune_locked"],
            "weapon": {
                "initial_level": seed["weapon"]["level"],
                "names": seed["weapon"]["names"],
                "powers": seed["weapon"]["powers"],
                "upgrade_costs": weapon_costs[character["source_character_id"]],
            },
        }
        raw, source_proof = export_first_room.source('/' + source_records[character['source_character_id']]['sprite_file'])
        element = preparation.weapon_element(source_records[character['source_character_id']])
        if element is not None:
            profile['weapon']['element'] = element
        profile['revival_art'] = journey_battle.revival_art(raw, actor_atlas)
        reaction_clips = reactions.get(character['id'], {1})
        bind_reaction_poses(trial, section, offset, reaction_clips)
        seed_record = source_records[character['source_character_id']]
        weapon = preparation.main.mword(0x80165890 + 4 * seed_record['weapon_id'])
        added_sources.append(dict(id=character['id'], source=source_proof, reaction_animations=sorted(reaction_clips),
                                  revival='journey_battle.revival_art: source animations 3/2',
                                  weapon_element=dict(source='MAIN.EXE', lba=preparation.main.EXE_LBA,
                                      offset=preparation.main.EXE_HEADER + weapon - preparation.main.MBASE + 0x55,
                                      code=preparation.main.body()[weapon - preparation.main.MBASE + 0x55], element=element)))
        for slot_item in ("tunic", "circlet", "robe"):
            for equipment in trial["systems"]["equipment"]:
                if equipment["id"] == slot_item and equipment.get("allowed_members") is not None and character["id"] not in equipment["allowed_members"]:
                    equipment["allowed_members"].append(character["id"])
        if character["id"] == "ted":
            profile["rune"] = "masked_rune_32"
            runes = trial["systems"]["runes"]
            if "masked_rune_32" not in {rune["id"] for rune in runes}:
                runes.append({
                    "id": "masked_rune_32", "name": "??????", "spell_names": ["??????"] * 4,
                    "spells": [None] * 4, "allowed_members": ["ted"],
                })
        actors.append(profile)
    ranged, ranged_proof = export_party_ranged_actors.build()
    added_ids = {entry["id"] for entry in to_add}
    ranged_ids = added_ids & {entry["id"] for entry in ranged["bindings"]}
    roots = [(row["id"], row[key]) for row in ranged["bindings"] if row["id"] in ranged_ids
             for key in ("attack_program", "return_program")]
    resources = {"resources": [row["resource"] for row in ranged_proof["characters"] + ranged_proof["targets"]]}
    graphics, ranged_art_proof = export_physical_runes.graphics(
        ranged, resources, actor_atlas, ranged_ids, roots, trial["unite_graphics"])
    for incoming in graphics:
        existing_graphic = next((row for row in trial["unite_graphics"]
                                 if row["id"] == incoming["id"] and row.get("record") is None), None)
        if existing_graphic is None:
            trial["unite_graphics"].append(incoming)
        else:
            pose_ids = {pose["id"] for pose in existing_graphic["poses"]}
            existing_graphic["poses"].extend(pose for pose in incoming["poses"] if pose["id"] not in pose_ids)
    item_proof = journey_battle.append_item_art(trial, actor_atlas)
    actor_atlas.save(canonical / "battle/actors.png")
    preparation.bind_weapon_elements(trial)
    (work / 'opening_additions.json').write_text(json.dumps(dict(
        status='candidate; media review pending', characters=added_sources, item_art=item_proof, ranged_art=ranged_art_proof,
        medicine='export_world_travel.medicine_timings',
        limitation='Packages without ranged actor bindings use prototype ranged-attack motion; media review remains open.'), indent=2) + '\n')
    write_trial(trial_path, trial)
    export_va2_battle.append_va2_battle(canonical / "battle")
    export_route_battles.append_route_battles(canonical / "battle")
    export_route_battles.append_field_encounters(canonical)
    print(f"added {sorted(added_ids)} profiles at atlas y={offset}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=CANONICAL)
    parser.add_argument("--work", type=Path, default=ROOT / "kit/work/build/profile_export")
    args = parser.parse_args()
    return export(args.out, args.work)


if __name__ == "__main__":
    raise SystemExit(main())
