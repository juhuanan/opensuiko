#!/usr/bin/env python3
"""Export the VA2.BIN scripted Imperial Soldier battle (va2_s0_e11) into canonical/battle."""
from __future__ import annotations

import hashlib
import json
import os
import struct
import sys
from pathlib import Path
from PIL import Image

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import area_scene
import battle_placement
import export_battle_trial as ebt
import export_first_room as efr
import export_spell_scenes as ess
import field_encounter_inventory as fei
import journey_battle as jb
import lzss
import maindec
from war_text import decode as decode_text

VA2_DIR_VA = 0x80050604
KNOCKOUT_SCRIPT = [
    (15, (0, 1)), (30, (0,)), (35, (0, 3)), (14, (1,)), (4, (3,)),
    (6, (1,)), (3, (1,)), (3, (90,)), (8, (0,)), (6, (0,)),
    (3, (1,)), (30, (99,)), (16, (0, 1)), (16, (0, 255)),
]
AFFINITY_NAMES = {0: "neutral", 1: "weak", 2: "resistant", 3: "immune"}
EMPIRE_SOLDIER_SPECS = (
    (1, "empire_soldier_1", "any_row"),
    (2, "empire_soldier_2", "front_first"),
    (3, "empire_soldier_3", "front_first"),
)


def _strip_pack(image: Image.Image, entries: list[tuple[Image.Image, int, int]]) -> tuple[Image.Image, list[dict]]:
    """Append packed sprites below an existing RGBA atlas with 1px padding."""
    width = image.width
    x = 0
    y = image.height
    row_h = 0
    rects: list[dict] = []
    placed: list[tuple[Image.Image, int, int]] = []
    for sprite, _, _ in entries:
        sw, sh = sprite.size
        if sw > width:
            raise ValueError(f"sprite width {sw} exceeds atlas width {width}")
        if x + sw > width:
            x = 0
            y += row_h + 1
            row_h = 0
        rects.append({"x": x, "y": y, "w": sw, "h": sh})
        placed.append((sprite, x, y))
        x += sw + 1
        row_h = max(row_h, sh)
    new_height = image.height if not placed else y + row_h
    if new_height > 4096:
        raise ValueError(f"packed atlas height {new_height} exceeds 4096")
    out = Image.new("RGBA", (width, new_height), (0, 0, 0, 0))
    out.paste(image, (0, 0))
    for sprite, px, py in placed:
        out.paste(sprite, (px, py))
    return out, rects


def _pack_actor_poses(atlas_img: Image.Image, poses: list[tuple[Image.Image, int, int]]) -> tuple[Image.Image, list[dict]]:
    atlas_img, rects = _strip_pack(atlas_img, poses)
    packed = []
    for rect, (_, ax, ay) in zip(rects, poses, strict=True):
        packed.append({"rect": rect, "anchor_x": ax, "anchor_y": ay})
    return atlas_img, packed


def _va2_knockout_ticks(raw: bytes, atab_off: int, base: int) -> int:
    ptr = struct.unpack_from("<I", raw, atab_off + 7 * 4)[0] - base
    ops = jb.script_at(raw, ptr)
    if ops[:-1] != KNOCKOUT_SCRIPT or ops[-1][0] != 0:
        raise ValueError(f"VA2 enemy knockout script changed at {ptr:#x}: {ops}")
    rows = ops[:-1]
    return sum(args[0] for op, args in rows if op == 3) + sum(op == 30 for op, _ in rows)


def _va2_attack_schedule(
    raw: bytes,
    atab_off: int,
    base: int,
    animations: list[list[tuple[int, int]]],
    packed_poses: list[dict],
) -> tuple[list[dict], dict]:
    """Decode an enemy atab[1]+atab[4] attack schedule into frames and motion."""
    frames: list[dict] = []
    clock = 0
    approach = None
    retreat = None
    impact = None
    ready = None
    has_approach = False
    for slot in (1, 4):
        ptr = struct.unpack_from("<I", raw, atab_off + slot * 4)[0] - base
        ops = jb.script_at(raw, ptr)
        selected = 0
        pending_ticks = 0
        for op, args in ops:
            if op in (0, 1):
                break
            if op in (9, 15, 16, 34):
                continue
            if op == 4:
                selected = args[0]
            elif op == 5:
                for pose_idx, ticks in animations[selected]:
                    dur = ticks or 256
                    frames.append({"pose": packed_poses[pose_idx], "ticks": dur, "source_pose": pose_idx})
                    clock += dur
            elif op == 3:
                pose_idx = animations[selected][-1][0]
                frames.append({"pose": packed_poses[pose_idx], "ticks": args[0], "source_pose": pose_idx})
                clock += args[0]
            elif op == 23:
                mode, duration, x, y, z, vx, vy, vz = args
                if mode not in (2, 3) or duration < 2:
                    raise ValueError(f"unsupported VA2 enemy leap {args}")
                move = {
                    "ticks": duration,
                    "acceleration_step": 1 / 4096,
                    "offset": {"x": x, "y": y, "z": z},
                    "velocity": {"x": vx / 2, "y": vy / 2, "z": vz / 2},
                }
                if mode == 2:
                    approach = (clock, move)
                    has_approach = True
                else:
                    retreat = (clock, move)
                pending_ticks = duration
            elif op == 21:
                pose_idx = animations[selected][-1][0]
                frames.append({"pose": packed_poses[pose_idx], "ticks": pending_ticks, "source_pose": pose_idx})
                clock += pending_ticks
            elif op == 26:
                if slot == 1 and args == (0, 2):
                    impact = clock
                elif slot == 1 and args == (0, 4):
                    ready = clock
            elif op in (24, 28):
                # Projectile spawn / signal wait in archer atab[1]; bow release occurs here.
                if op == 28 and args == (0, 2) and slot == 1 and impact is None:
                    impact = clock
            else:
                raise ValueError(f"unsupported VA2 enemy script op {(op, args)} at {atab_off:#x}")
    if not has_approach:
        # Archer stays in the back row and fires without an approach leap.
        if impact is None or impact < 2:
            raise ValueError(f"missing VA2 archer impact tick at {atab_off:#x}")
        approach = (
            0,
            {
                "ticks": 2,
                "acceleration_step": 1 / 4096,
                "offset": {"x": 0, "y": 0, "z": 0},
                "velocity": {"x": 0.0, "y": 0.0, "z": 0.0},
            },
        )
    if retreat is None or impact is None or ready is None:
        raise ValueError(f"missing VA2 enemy attack stages at {atab_off:#x}")
    if not (impact <= ready <= retreat[0]):
        raise ValueError(f"invalid VA2 enemy stage ordering: impact={impact}, ready={ready}, retreat={retreat[0]}")
    motion = {
        "approach_start": approach[0],
        "approach": approach[1],
        "impact_tick": impact,
        "ready_tick": ready,
        "return_start": retreat[0],
        "retreat": retreat[1],
        "duration": clock,
    }
    return frames, motion


def _build_ground(va2: bytes, directory_off: int, base: int) -> tuple[Image.Image, dict]:
    bf = battle_placement.directory_battlefield(va2, directory_off, base)
    ground_info = bf["ground"]
    across = ground_info["across"]
    down = ground_info["down"]
    if (across, down) != (16, 16):
        raise ValueError(f"unexpected VA2 ground dimensions {(across, down)}")
    pages = []
    for poff in ground_info["page_offsets"]:
        ln = struct.unpack_from("<I", va2, poff)[0]
        raw_page = lzss.decode_strict(va2[poff + 4 : poff + 4 + ln])
        if len(raw_page) != 16384:
            raise ValueError(f"VA2 ground page {poff:#x} decoded to {len(raw_page)} bytes")
        pages.append(raw_page)
    palettes: dict[int, tuple[int, ...]] = {}
    for pi, poff in enumerate(ground_info["palette_offsets"]):
        if poff is not None:
            palettes[pi] = struct.unpack_from("<256H", va2, poff)
    selectors = [list(va2[soff : soff + 16]) for soff in ground_info["tile_palette_offsets"]]
    tiles = list(struct.unpack_from(f"<{across * down}H", va2, ground_info["tile_map_offset"]))
    used_tiles = set(tiles)
    heights = list(struct.unpack_from(f"<{(across + 1) * (down + 1)}h", va2, ground_info["height_map_offset"]))

    rows = max(4, len(pages))
    strip = Image.new("RGB", (512, rows * 32), (0, 0, 0))
    for code in range(rows * 16):
        page_idx = code >> 4
        tile_idx = code & 15
        if page_idx >= len(pages):
            continue
        pal_idx = selectors[page_idx][tile_idx]
        if pal_idx not in palettes:
            if code not in used_tiles:
                continue
            raise KeyError(pal_idx)
        pal = palettes[pal_idx]
        dst_x = (code % 16) * 32
        dst_y = (code // 16) * 32
        src_x = (tile_idx & 3) * 32
        src_y = (tile_idx >> 2) * 32
        page_bytes = pages[page_idx]
        for y in range(32):
            for x in range(32):
                pix = page_bytes[(src_y + y) * 128 + src_x + x]
                strip.putpixel((dst_x + x, dst_y + y), ebt.rgb555_to_rgb888(pal[pix]))

    step_x = 1024.0 / float(across)
    step_y = 1024.0 / float(down)
    start_x = -512.0 - 64.0
    start_y = -512.0 - 64.0
    vertices = []
    for row in range(down + 1):
        for col in range(across + 1):
            z = heights[row * (across + 1) + col]
            vertices.append(
                {"x": int(round(start_x + col * step_x)), "y": int(round(start_y + row * step_y)), "z": int(z)}
            )
    return strip, {"across": across, "down": down, "vertices": vertices, "tiles": tiles}


def _append_hurt_poses(
    va2: bytes,
    va2_origin: dict,
    base: int,
    records: dict[int, tuple[str, int, str]],
    spells: dict,
    spell_img: Image.Image,
) -> tuple[dict, Image.Image, list[dict]]:
    white = struct.unpack_from("<32H", maindec.body(), 0x8016B8A8 - maindec.MBASE)
    flash_palettes = ess.reaction_palettes()
    shock_palettes = ess.reaction_palettes((4, 5, 6))
    new_images: list[tuple[Image.Image, int, int]] = []
    base_count = len(spells["entries"])
    added_entries: list[dict] = []
    added_hurt_poses: list[dict] = []
    proof_entries: list[dict] = []

    def add_bitmap(img: Image.Image, ax: int, ay: int) -> int:
        idx = base_count + len(added_entries)
        new_images.append((img, -ax, -ay))
        added_entries.append({"dx": -ax, "dy": -ay, "w": img.width, "h": img.height})
        return idx

    for _, (identifier, record_off, _) in sorted(records.items()):
        section_off = struct.unpack_from("<I", va2, record_off + 44)[0] - base
        atab_off = struct.unpack_from("<I", va2, record_off + 40)[0] - base
        poses, animations, art_proof = ebt.section_art(va2, section_off, base)
        if len(animations[1]) != 1 or len(animations[3]) != 1:
            raise ValueError(f"{identifier} requires single-frame hurt and knockout tracks")
        hurt_idx = animations[1][0][0]
        idle_idx = animations[0][0][0]
        ko_idx = animations[3][0][0]
        image, ax, ay = poses[hurt_idx]
        off = art_proof["poses"][hurt_idx]
        idle = art_proof["poses"][idle_idx]
        center = [va2[off + 2 + i] // 2 - (va2[off + 4 + i] - va2[off + 8 + i]) for i in range(2)]
        idle_center = [va2[idle + 2 + i] // 2 - (va2[idle + 4 + i] - va2[idle + 8 + i]) for i in range(2)]
        impact_offset = [((va2[off + 6 + i] - va2[off + 4 + i] + 128) % 256) - 128 for i in range(2)]
        source_attachment = [va2[off + 6 + i] - va2[off + 4 + i] for i in range(2)]
        entry_id = add_bitmap(image, ax, ay)

        flashes: list[int] = []
        idle_variants = []
        for palette in flash_palettes:
            variants, _, _ = ebt.section_art(va2, section_off, base, palette_override=palette)
            idle_variants.append(variants)
            variant, vx, vy = variants[hurt_idx]
            if variant.size != image.size or (vx, vy) != (ax, ay):
                raise ValueError(f"{identifier} flash variant changed geometry")
            flashes.append(add_bitmap(variant, ax, ay))

        white_variants, _, _ = ebt.section_art(va2, section_off, base, palette_override=white)
        wvar, wx, wy = white_variants[hurt_idx]
        white_id = add_bitmap(wvar, wx, wy)

        shocks: list[int] = []
        for palette in shock_palettes:
            variants, _, _ = ebt.section_art(va2, section_off, base, palette_override=palette)
            variant, vx, vy = variants[hurt_idx]
            if variant.size != image.size or (vx, vy) != (ax, ay):
                raise ValueError(f"{identifier} shock variant changed geometry")
            shocks.append(add_bitmap(variant, vx, vy))

        ko_duration = _va2_knockout_ticks(va2, atab_off, base)
        dead, dx, dy = poses[ko_idx]
        ko_entry = add_bitmap(dead, dx, dy)

        anim0_flags = va2[art_proof["animations"][0] + 1]
        by_pose: dict[int, tuple[list[int], int]] = {}
        for sp_idx, _ in animations[0]:
            if sp_idx in by_pose:
                continue
            v_ids = []
            for variants in idle_variants:
                vimg, vax, vay = variants[sp_idx]
                v_ids.append(add_bitmap(vimg, vax, vay))
            nimg, nax, nay = poses[sp_idx]
            norm_id = add_bitmap(nimg, nax, nay)
            by_pose[sp_idx] = (v_ids, norm_id)
        advances = bool(anim0_flags & 1)
        idle_flash = {
            "advances": advances,
            "loop": bool(anim0_flags & 2) if advances else False,
            "frames": [
                {"ticks": ticks, "entries": by_pose[sp_idx][0], "normal": by_pose[sp_idx][1]}
                for sp_idx, ticks in animations[0]
            ],
        }

        added_hurt_poses.append(
            {
                "id": identifier,
                "entry": entry_id,
                "center": center,
                "idle_center": idle_center,
                "sprite_height": va2[idle + 3],
                "impact_offset": impact_offset,
                "source_attachment": source_attachment,
                "white_entry": white_id,
                "flash_entries": flashes,
                "shock_entries": shocks,
                "knockout": {"entry": ko_entry, "duration": ko_duration},
                "idle_flash": idle_flash,
            }
        )
        proof_entries.append(
            {
                "id": identifier,
                "source": va2_origin,
                "record_offset": record_off,
                "section_offset": section_off,
                "atab_offset": atab_off,
                "knockout_ticks": ko_duration,
            }
        )

    packed_spell_img, rects = _strip_pack(spell_img, new_images)
    for entry, rect in zip(added_entries, rects, strict=True):
        entry["x"] = rect["x"]
        entry["y"] = rect["y"]
    spells["entries"].extend(added_entries)
    spells["hurt_poses"].extend(added_hurt_poses)
    return spells, packed_spell_img, proof_entries


def append_va2_battle(battle_dir: Path) -> bool:
    """Append VA2 Imperial Soldier encounter va2_s0_e11 and battlefield va2_s0 idempotently."""
    trial_path = battle_dir / "trial.json"
    actors_path = battle_dir / "actors.png"
    ground_path = battle_dir / "ground.png"
    spells_path = battle_dir / "spells.json"
    spell_img_path = battle_dir / "spell_effects.png"
    prov_path = battle_dir / "provenance.json"
    spells_prov_path = battle_dir / "spells.provenance.json"

    trial = json.loads(trial_path.read_text())
    spells = json.loads(spells_path.read_text())
    needed_enemies = {row[1] for row in EMPIRE_SOLDIER_SPECS}
    existing_enemies = {row["id"] for row in trial.get("enemies", [])}
    existing_fields = {row["id"] for row in trial.get("battlefields", [])}
    existing_encounters = {row["id"] for row in trial.get("encounters", [])}
    existing_hurt = {row["id"] for row in spells.get("hurt_poses", [])}
    if (
        "va2_s0_e11" in existing_encounters
        and "va2_s0" in existing_fields
        and needed_enemies <= existing_enemies
        and needed_enemies <= existing_hurt
    ):
        return False

    va2, va2_origin = efr.source("/VA2.BIN")
    base = area_scene.RAM_BASE
    directory_off = VA2_DIR_VA - base
    info = fei.read_directory(va2, "/VA2.BIN", VA2_DIR_VA)
    if info.get("status") != "resolved" or len(info.get("formations", [])) != 1:
        raise ValueError("VA2 battle directory 0x80050604 did not resolve a single formation")
    formation = info["formations"][0]
    _, raw_encounters = battle_placement.directory_encounters(va2, directory_off, base)
    raw_enc = raw_encounters[0]

    # 1. Ground mesh and atlas tile bank
    with Image.open(ground_path) as g_im:
        ground_img = g_im.convert("RGB")
    va2_strip, va2_ground = _build_ground(va2, directory_off, base)
    if ground_img.width < va2_strip.width:
        raise ValueError(f"ground.png width {ground_img.width} smaller than 512")
    ground_atlas = {"x": 0, "y": ground_img.height, "w": 512, "h": 128}
    new_ground = Image.new("RGB", (ground_img.width, ground_img.height + va2_strip.height), (0, 0, 0))
    new_ground.paste(ground_img, (0, 0))
    new_ground.paste(va2_strip, (0, ground_img.height))

    # 2. Enemy sprites and profiles
    with Image.open(actors_path) as a_im:
        actors_img = a_im.convert("RGBA")
    record_by_local: dict[int, tuple[str, int, str]] = {}
    slots_table = struct.unpack_from("<I", va2, directory_off + 12)[0] - base
    spec_by_local = {local_id: (stable_id, target_pol) for local_id, stable_id, target_pol in EMPIRE_SOLDIER_SPECS}
    enemy_profiles: dict[str, dict] = {}
    enemy_proofs: list[dict] = []

    for local_id, (stable_id, target_policy) in sorted(spec_by_local.items()):
        rec_off = struct.unpack_from("<I", va2, slots_table + 4 * local_id)[0] - base
        record_by_local[local_id] = (stable_id, rec_off, target_policy)
        raw_rec = va2[rec_off : rec_off + 64]
        name, _ = decode_text(raw_rec, length=16)
        lvl, max_hp = struct.unpack_from("<2H", raw_rec, 16)
        atk, skl, defn, spd, mgc, lck = struct.unpack_from("<6H", raw_rec, 20)
        flags = struct.unpack_from("<H", raw_rec, 38)[0]
        atab_off = struct.unpack_from("<I", raw_rec, 40)[0] - base
        sec_off = struct.unpack_from("<I", raw_rec, 44)[0] - base
        money = struct.unpack_from("<H", raw_rec, 52)[0]
        aff_bytes = raw_rec[32:38]
        aff_map = {
            element: AFFINITY_NAMES.get(aff_bytes[idx], "neutral")
            for idx, element in enumerate(("fire", "water", "earth", "lightning", "wind"))
        }

        poses, animations, art_proof = ebt.section_art(va2, sec_off, base)
        actors_img, packed_poses = _pack_actor_poses(actors_img, poses)
        idle_idx = animations[0][0][0]
        attack_frames, motion = _va2_attack_schedule(va2, atab_off, base, animations, packed_poses)
        foot_y = ebt.foot_offset_y(poses[idle_idx])
        enemy_profiles[stable_id] = {
            "id": stable_id,
            "name": name.strip(),
            "max_hp": max_hp,
            "level": lvl,
            "money": money,
            "stats": {
                "attack": atk,
                "defense": defn,
                "skill": skl,
                "speed": spd,
                "magic": mgc,
                "luck": lck,
            },
            "sprite": packed_poses[idle_idx],
            "foot_offset_y": foot_y,
            "attack": attack_frames,
            "motion": motion,
            "fire_affinity": aff_map["fire"],
            "affinities": aff_map,
            "other_affinity": AFFINITY_NAMES.get(aff_bytes[5], "neutral"),
            "death_immune": False,
            "airborne": bool(flags & 32),
            "target_policy": target_policy,
            "action_policy": "attack",
            "dodges_attacks": False,
            "unavoidable_attack": False,
        }
        enemy_proofs.append(
            {
                "id": stable_id,
                "local_id": local_id,
                "record_offset": rec_off,
                "section_offset": sec_off,
                "atab_offset": atab_off,
                "source": va2_origin,
                "art": art_proof,
            }
        )

    # 3. Hurt / knockout poses for check_strike_reactions
    with Image.open(spell_img_path) as s_im:
        spell_img = s_im.convert("RGBA")
    spells, new_spell_img, hurt_proofs = _append_hurt_poses(va2, va2_origin, base, record_by_local, spells, spell_img)

    # 4. Assemble updated trial entries + encounter
    for _, stable_id, _ in EMPIRE_SOLDIER_SPECS:
        trial["enemies"] = [row for row in trial["enemies"] if row["id"] != stable_id]
        trial["enemies"].append(enemy_profiles[stable_id])

    trial.setdefault("battlefields", [])
    trial["battlefields"] = [row for row in trial["battlefields"] if row["id"] != "va2_s0"]
    trial["battlefields"].append(
        {"id": "va2_s0", "ground": va2_ground, "ground_atlas": ground_atlas, "scenery": []}
    )

    slots = sorted(raw_enc["slots"], key=lambda s: s["slot"])
    va2_encounter = {
        "id": "va2_s0_e11",
        "title": "Imperial Patrol",
        "enemies": [spec_by_local[s["enemy_id"]][0] for s in slots],
        "experience_per_member": 0,
        "positions": [dict(zip("xyz", s["world"])) for s in slots],
        "enemy_rows": ["front" if s["slot"] < 3 else "back" for s in slots],
        "escape_allowed": bool(formation["escape_allowed"]),
        "source_slots": [s["slot"] for s in slots],
        "music": "normal",
        "battlefield": "va2_s0",
    }
    trial["encounters"] = [row for row in trial["encounters"] if row["id"] != "va2_s0_e11"]
    trial["encounters"].append(va2_encounter)
    trial["schema"] = "suikoden-battle-trial/44"

    # Save assets and update provenance
    new_ground.save(ground_path)
    actors_img.save(actors_path)
    new_spell_img.save(spell_img_path)
    trial_path.write_text(json.dumps(trial, separators=(",", ":")) + "\n")
    spells_path.write_text(json.dumps(spells, separators=(",", ":")) + "\n")

    if prov_path.is_file():
        prov = json.loads(prov_path.read_text())
        prov["va2_s0_battle"] = {
            "source": va2_origin,
            "directory_va": hex(VA2_DIR_VA),
            "directory_offset": directory_off,
            "ground_atlas": ground_atlas,
            "enemies": enemy_proofs,
            "encounter": {
                "id": "va2_s0_e11",
                "descriptor_offset": raw_enc["descriptor_offset"],
                "escape_allowed": formation["escape_allowed"],
                "roster": raw_enc["roster"],
            },
            "va2_sha256": hashlib.sha256(va2).hexdigest(),
        }
        prov_path.write_text(json.dumps(prov, indent=2) + "\n")

    if spells_prov_path.is_file():
        sprov = json.loads(spells_prov_path.read_text())
        sprov["va2_s0_hurt_poses"] = hurt_proofs
        spells_prov_path.write_text(json.dumps(sprov, indent=2) + "\n")

    return True


def main() -> int:
    battle_dir = ROOT / "kit/work/build/canonical/battle"
    changed = append_va2_battle(battle_dir)
    print(f"{'Appended' if changed else 'Already up-to-date'} va2_s0_e11 in {battle_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
