#!/usr/bin/env python3
"""Append route enemies, hurt poses, battlefields, and encounters idempotently."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import struct
import sys

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import area_encounter_tables as aet  # noqa: E402
import area_scene  # noqa: E402
import battle_placement as bp  # noqa: E402
import exp_award  # noqa: E402
import export_battle_audio  # noqa: E402
import export_battle_trial as ebt  # noqa: E402
import export_spell_scenes as ess  # noqa: E402
import export_va2_battle as evb  # noqa: E402
import journey_battle as jb  # noqa: E402
import lzss  # noqa: E402
import maindec  # noqa: E402
from export_first_room import Atlas, source as disc_source  # noqa: E402
from war_text import decode as decode_text  # noqa: E402

AREA_BASE = 0x80010000
DATA_BASE = 0x80080000
HOLLY_BOY_ANIMS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12]

ENEMY_SPECS = (
    ("DATA/02_AREA.B/VB1.BIN", AREA_BASE, 0x80051F50, "vb1_soldier_1", None, "front_first"),
    ("DATA/02_AREA.B/VB1.BIN", AREA_BASE, 0x800530F0, "vb1_soldier_2", None, "front_first"),
    ("DATA/01_AREA.A/VA3.BIN", AREA_BASE, 0x800699B4, "va3_soldier_1", None, "any_row"),
    ("DATA/01_AREA.A/VA3.BIN", AREA_BASE, 0x8006AE08, "va3_soldier_2", None, "front_first"),
    ("DATA/01_AREA.A/VA3.BIN", AREA_BASE, 0x8006BFA8, "va3_soldier_3", None, "front_first"),
    ("DATA/01_AREA.A/VA8.BIN", AREA_BASE, 0x8004A5C4, "va8_slasher_rabbit", None, "front_first"),
    ("DATA/01_AREA.A/VA8.BIN", AREA_BASE, 0x8004BDE4, "va8_giant_snail", None, "front_first"),
    ("DATA/01_AREA.A/VA8.BIN", AREA_BASE, 0x80048CC8, "va8_killer_slime", None, "front_first"),
    ("DATA/01_AREA.A/VA2.BIN", AREA_BASE, 0x8005D220, "va2_captain", None, "front_first"),
    # (area_path, base, rec_va, stable_id, anim_indices, target_policy)
    ("DATA/01_AREA.A/VA4.BIN", AREA_BASE, 0x80076588, "va4_holly_boy", HOLLY_BOY_ANIMS, "front_first"),
    ("DATA/01_AREA.A/VA4.BIN", AREA_BASE, 0x80074A24, "va4_furfur", None, "front_first"),
    ("DATA/01_AREA.A/VA4.BIN", AREA_BASE, 0x800775DC, "va4_golem", None, "front_first"),
    ("DATA/01_AREA.A/VA7.BIN", AREA_BASE, 0x8006500C, "va7_soldier_ant", None, "front_first"),
    ("DATA/01_AREA.A/VA7.BIN", AREA_BASE, 0x8006632C, "va7_bandit_lv5a", None, "front_first"),
    ("DATA/01_AREA.A/VA7.BIN", AREA_BASE, 0x80067578, "va7_bandit_lv7", None, "front_first"),
    ("DATA/01_AREA.A/VA7.BIN", AREA_BASE, 0x80068A78, "va7_bandit_lv5b", None, "front_first"),
    ("DATA/01_AREA.A/VA7.BIN", AREA_BASE, 0x80069E8C, "va7_black_wild_boar", None, "front_first"),
    ("DATA/01_AREA.A/VA7.BIN", AREA_BASE, 0x8006BE68, "va7_queen_ant", None, "front_first"),
    ("DATA/01_AREA.A/VA7.BIN", AREA_BASE, 0x8006ED18, "va7_varkas", None, "front_first"),
    ("DATA/01_AREA.A/VA7.BIN", AREA_BASE, 0x8007005C, "va7_sydonia", None, "front_first"),
    ("DATA/02_AREA.B/VB6.BIN", AREA_BASE, 0x8006F3FC, "vb6_holly_spirit", None, "any_row"),
    ("DATA/02_AREA.B/VB6.BIN", AREA_BASE, 0x800716E0, "vb6_holly_boy", HOLLY_BOY_ANIMS, "front_first"),
    ("DATA/02_AREA.B/VB3.BIN", AREA_BASE, 0x80071FB4, "vb3_robot_soldier_1", None, "front_first"),
    ("DATA/02_AREA.B/VB3.BIN", AREA_BASE, 0x800734EC, "vb3_robot_soldier_2", None, "front_first"),
)

# Map (area_path, directory_off, local_id) -> stable enemy profile id
LOCAL_ENEMY_MAPS = {
    ("DATA/02_AREA.B/VB1.BIN", 0x3A2F8): {1: "vb1_soldier_1", 2: "vb1_soldier_2"},
    ("DATA/01_AREA.A/VA3.BIN", 0x51EF8): {1: "va3_soldier_1", 2: "va3_soldier_2", 3: "va3_soldier_3"},
    ("DATA/01_AREA.A/VA8.BIN", 0x2A8DC): {1: "va8_slasher_rabbit", 2: "va8_giant_snail", 3: "va8_killer_slime"},
    ("DATA/01_AREA.A/VA2.BIN", 0x405B0): {1: "empire_soldier_1", 2: "empire_soldier_2", 3: "empire_soldier_3", 4: "va2_captain"},
    ("DATA/01_AREA.A/VA2.BIN", 0x405E8): {1: "empire_soldier_1", 2: "empire_soldier_2", 3: "empire_soldier_3", 4: "va2_captain"},
    ("DATA/01_AREA.A/VA4.BIN", 0x5B5A8): {1: "va4_holly_boy", 2: "va4_furfur"},
    ("DATA/01_AREA.A/VA4.BIN", 0x67554): {1: "va4_golem"},
    ("DATA/01_AREA.A/VA7.BIN", 0x3422C): {
        1: "va7_soldier_ant", 2: "va7_bandit_lv5a", 3: "va7_bandit_lv7",
        4: "va7_bandit_lv5b", 5: "va7_black_wild_boar",
    },
    ("DATA/01_AREA.A/VA7.BIN", 0x34248): {
        1: "va7_soldier_ant", 2: "va7_bandit_lv5a", 3: "va7_bandit_lv7",
        4: "va7_bandit_lv5b", 5: "va7_black_wild_boar",
    },
    ("DATA/01_AREA.A/VA7.BIN", 0x5BDF8): {1: "va7_queen_ant", 2: "va7_soldier_ant"},
    ("DATA/01_AREA.A/VA7.BIN", 0x5BE14): {1: "va7_queen_ant"},
    ("DATA/01_AREA.A/VA7.BIN", 0x5BE4C): {5: "va7_bandit_lv5a", 6: "va7_bandit_lv7", 7: "va7_bandit_lv5b"},
    ("DATA/01_AREA.A/VA7.BIN", 0x5BE30): {3: "va7_varkas", 4: "va7_sydonia"},
    ("DATA/02_AREA.B/VB6.BIN", 0x63D1C): {
        1: "kobold_type_1", 2: "kobold_type_2", 3: "vb6_holly_spirit", 4: "vb6_holly_boy",
    },
    ("DATA/02_AREA.B/VB3.BIN", 0x67DC0): {1: "vb3_robot_soldier_1", 2: "vb3_robot_soldier_2"},
}

BATTLEFIELD_SPECS = (
    # shortcut: school scenery has unsupported sprite pointers; decode before visual acceptance.
    ("vb1_school", "DATA/02_AREA.B/VB1.BIN", 0x3A2F8, AREA_BASE, False, False),
    # shortcut: hideout scenery has unsupported sprite pointers; decode before visual acceptance.
    ("va3_raid", "DATA/01_AREA.A/VA3.BIN", 0x51EF8, AREA_BASE, False, False),
    ("va8_ord", "DATA/01_AREA.A/VA8.BIN", 0x2A8DC, AREA_BASE, False, False),
    # shortcut: mansion battle scenery needs its own decoder before visual acceptance.
    ("va2_rescue", "DATA/01_AREA.A/VA2.BIN", 0x405B0, AREA_BASE, False, False),
    # (field_id, area_path, dir_off, base, has_scenery, va4_single_pose_fix)
    ("world_b", "DATA/02_AREA.B/B_DATA.BIN", 0x16B0C, DATA_BASE, True, False),
    ("va4_ord", "DATA/01_AREA.A/VA4.BIN", 0x5B5A8, AREA_BASE, True, True),
    ("va7_ord1", "DATA/01_AREA.A/VA7.BIN", 0x3422C, AREA_BASE, False, False),
    ("va7_ord2", "DATA/01_AREA.A/VA7.BIN", 0x34248, AREA_BASE, False, False),
    ("va7_r9", "DATA/01_AREA.A/VA7.BIN", 0x5BDF8, AREA_BASE, False, False),
    ("vb6_ord", "DATA/02_AREA.B/VB6.BIN", 0x63D1C, AREA_BASE, False, False),
    # shortcut: resolve mansion scenery's external sprite references before presentation acceptance.
    ("vb3_wheel", "DATA/02_AREA.B/VB3.BIN", 0x67DC0, AREA_BASE, False, False),
)

ENCOUNTER_BATCHES = (
    ("DATA/02_AREA.B/VB1.BIN", 0x3A2F8, AREA_BASE, "vb1_school", "vb1_school", {}),
    ("DATA/01_AREA.A/VA3.BIN", 0x51EF8, AREA_BASE, "va3_raid", "va3_raid", {}),
    ("DATA/01_AREA.A/VA8.BIN", 0x2A8DC, AREA_BASE, "va8_ord", "va8_ord_", {}),
    ("DATA/01_AREA.A/VA2.BIN", 0x405B0, AREA_BASE, "va2_rescue", "va2_rescue_pair", {}),
    ("DATA/01_AREA.A/VA2.BIN", 0x405E8, AREA_BASE, "va2_rescue", "va2_rescue_squad", {}),
    # (area_path, dir_off, base, bf_id, id_prefix, extra_fields_by_index)
    ("DATA/01_AREA.A/VA4.BIN", 0x5B5A8, AREA_BASE, "va4_ord", "va4_ord_", {}),
    ("DATA/01_AREA.A/VA4.BIN", 0x67554, AREA_BASE, "va4_ord", "va4_golem", {1: {"title": "Golem"}}),
    ("DATA/01_AREA.A/VA7.BIN", 0x3422C, AREA_BASE, "va7_ord1", "va7_ord_r0_", {}),
    ("DATA/01_AREA.A/VA7.BIN", 0x34248, AREA_BASE, "va7_ord2", "va7_ord_", {}),
    ("DATA/01_AREA.A/VA7.BIN", 0x5BDF8, AREA_BASE, "va7_r9", "va7_r9_b0", {
        1: {"title": "Queen Ant", "reward_policy": "none", "experience_per_member": 0,
            "scripted_finish": {"after_round": 2, "wait_ticks": 12}},
    }),
    ("DATA/01_AREA.A/VA7.BIN", 0x5BE14, AREA_BASE, "va7_r9", "va7_r9_b1", {
        1: {"title": "Queen Ant (Soul Eater)", "reward_policy": "none", "experience_per_member": 0,
            "scripted_finish": {"after_round": 1, "wait_ticks": 60}},
    }),
    ("DATA/01_AREA.A/VA7.BIN", 0x5BE4C, AREA_BASE, "va7_ord1", "va7_r13_b0", {1: {"title": "Mountain Bandits"}}),
    ("DATA/01_AREA.A/VA7.BIN", 0x5BE30, AREA_BASE, "va7_ord1", "va7_r13_b1", {1: {"title": "Varkas & Sydonia"}}),
    ("DATA/02_AREA.B/VB6.BIN", 0x63D1C, AREA_BASE, "vb6_ord", "vb6_ord_", {}),
    ("DATA/02_AREA.B/VB3.BIN", 0x67DC0, AREA_BASE, "vb3_wheel", "vb3_wheel_monster", {}),
)


def scripted_encounter(data, section, selector, filename, battle_data):
    """Join a source-selected directory to an exported, qualified encounter."""
    if selector >= 0xFE or battle_data is None:
        return None
    try:
        directory = bp.scripted_directory(data, section, selector, AREA_BASE)
        _, formations = bp.directory_encounters(data, directory, AREA_BASE)
    except ValueError:
        return None
    # shortcut: qualify the forced picker before admitting multi-formation directories.
    if len(formations) != 1:
        return None
    batches = (*ENCOUNTER_BATCHES,
               ('DATA/01_AREA.A/VA2.BIN', evb.VA2_DIR_VA - AREA_BASE, AREA_BASE,
                'va2_s0', 'va2_s0_e11', {}))
    binding = next((batch for batch in batches
                    if '/' + batch[0].rsplit('/', 1)[-1] == filename and batch[1] == directory), None)
    trial, spells = battle_data
    enemies = {row['id']: row for row in trial['enemies']}
    hurt = {row['id'] for row in spells['hurt_poses']}
    slots = formations[0]['slots']
    if binding is None:
        disc_id = f"{filename[1:-4].lower()}_dir_{directory:x}_1"
        encounter = next((row for row in trial['encounters'] if row['id'] == disc_id), None)
        if encounter is None:
            return None
        if (encounter.get('battlefield') not in {row['id'] for row in trial.get('battlefields', [])}
                or any(enemy not in enemies or enemy not in hurt for enemy in encounter['enemies'])):
            return None
        sorted_slots = sorted(slots, key=lambda slot: slot['slot'])
        if (len(encounter['enemies']) != len(sorted_slots)
                or encounter.get('source_slots') != [slot['slot'] for slot in sorted_slots]
                or encounter['positions'] != [dict(zip('xyz', slot['world'])) for slot in sorted_slots]):
            return None
        return encounter['id']
    encounter = next((row for row in trial['encounters'] if row['id'] == binding[4]), None)
    if encounter is None:
        return None
    if (encounter.get('battlefield') not in {row['id'] for row in trial.get('battlefields', [])}
            or any(enemy not in enemies or enemy not in hurt for enemy in encounter['enemies'])):
        return None
    if encounter['battlefield'] != binding[3]:
        raise ValueError('scripted encounter battlefield disagrees with source export binding')
    local_map = LOCAL_ENEMY_MAPS.get((binding[0], directory))
    if local_map is None and filename == '/VA2.BIN' and directory == evb.VA2_DIR_VA - AREA_BASE:
        local_map = {local: identifier for local, identifier, _ in evb.EMPIRE_SOLDIER_SPECS}
    if local_map is None:
        return None
    if encounter['enemies'] != [local_map[slot['enemy_id']] for slot in slots]:
        raise ValueError('scripted encounter enemies disagree with exported source roster')
    if encounter.get('source_slots') != [slot['slot'] for slot in slots]:
        raise ValueError('scripted encounter source slots disagree with exported formation')
    if encounter['positions'] != [dict(zip('xyz', slot['world'])) for slot in slots]:
        raise ValueError('scripted encounter positions disagree with exported formation')
    return encounter['id']


def _knockout_ticks(raw: bytes, atab_off: int, base: int, animations: list | None = None) -> int:
    try:
        ptr = struct.unpack_from("<I", raw, atab_off + 7 * 4)[0] - base
        ops = jb.script_at(raw, ptr)
    except (ValueError, IndexError, struct.error):
        return 12
    total = 0
    selected = 3
    for op, args in ops:
        if op == 4 and args:
            selected = int(args[0])
        elif op == 5 and animations is not None and 0 <= selected < len(animations):
            total += sum(ticks or 256 for _, ticks in animations[selected])
        elif op == 3 and args:
            total += int(args[0])
        elif op == 23 and len(args) >= 2:
            total += int(args[1])
        elif op == 30:
            total += 1
    return max(3, total)


def _extract_attack(raw: bytes, atab_off: int, base: int, animations: list, packed_poses: dict[int, dict] | list[dict], allowed_anims: list[int] | None) -> tuple[list[dict], dict | None]:
    try:
        return evb._va2_attack_schedule(raw, atab_off, base, animations, packed_poses)
    except (ValueError, IndexError, KeyError):
        s1_ptr = struct.unpack_from("<I", raw, atab_off + 4)[0] - base
        ops = jb.script_at(raw, s1_ptr)
        allowed = set(allowed_anims) if allowed_anims is not None else None
        selected = next(
            (args[0] for op, args in ops if op == 4 and args and 0 <= args[0] < len(animations) and (allowed is None or args[0] in allowed) and animations[args[0]]),
            0,
        )
        frames = [
            {"pose": packed_poses[e], "ticks": ticks or 256, "source_pose": e}
            for e, ticks in (animations[selected] or animations[0])
        ]
        return frames, None


def _decode_enemy_art(
    raw: bytes,
    sec_off: int,
    atab_off: int,
    base: int,
    anim_indices: list[int] | None = None,
    palette_override: list[int] | tuple[int, ...] | None = None,
) -> tuple[list, list, dict]:
    try:
        return ebt.section_art(
            raw, sec_off, base,
            selected_poses_only=(anim_indices is not None),
            animation_indices=anim_indices,
            palette_override=palette_override,
        )
    except ValueError:
        used_anims = anim_indices
        if used_anims is None:
            nf = struct.unpack_from("<H", raw, sec_off + 2)[0]
            used = {0, 1, 3}
            for slot in (1, 4):
                try:
                    ptr = struct.unpack_from("<I", raw, atab_off + 4 * slot)[0] - base
                    for op, args in jb.script_at(raw, ptr):
                        if op == 4 and args and 0 <= args[0] < nf:
                            used.add(args[0])
                except (ValueError, IndexError, struct.error):
                    pass
            used_anims = sorted(a for a in used if 0 <= a < nf)
        try:
            return ebt.section_art(
                raw, sec_off, base,
                selected_poses_only=True,
                animation_indices=used_anims,
                palette_override=palette_override,
            )
        except ValueError:
            return ebt.section_art(
                raw, sec_off, base,
                selected_poses_only=True,
                animation_indices=used_anims,
                palette_override=palette_override,
                axis_aligned_packet=True,
            )


def _pack_shelf_poses(actor_atlas: Atlas, poses: list) -> dict[int, dict]:
    packed: dict[int, dict] = {}
    for i, pose in enumerate(poses):
        if pose is not None:
            image, ax, ay = pose
            packed[i] = {"rect": actor_atlas.add(image), "anchor_x": ax, "anchor_y": ay}
    return packed


def _build_hurt_pose_entry(
    raw: bytes,
    raw_origin: dict,
    base: int,
    identifier: str,
    rec_off: int,
    anim_indices: list[int] | None,
    flash_palettes: list,
    white: list,
    shock_palettes: list,
    add_bitmap,
) -> tuple[dict, dict]:
    section_off = struct.unpack_from("<I", raw, rec_off + 44)[0] - base
    atab_off = struct.unpack_from("<I", raw, rec_off + 40)[0] - base
    poses, animations, art_proof = _decode_enemy_art(raw, section_off, atab_off, base, anim_indices)
    if not animations[1] or not animations[3]:
        raise ValueError(f"{identifier} requires non-empty hurt and knockout tracks")
    hurt_idx = animations[1][0][0]
    idle_idx = animations[0][0][0]
    ko_idx = animations[3][-1][0]
    image, ax, ay = poses[hurt_idx]
    off = art_proof["poses"][hurt_idx]
    idle = art_proof["poses"][idle_idx]
    center = [raw[off + 2 + i] // 2 - (raw[off + 4 + i] - raw[off + 8 + i]) for i in range(2)]
    idle_center = [raw[idle + 2 + i] // 2 - (raw[idle + 4 + i] - raw[idle + 8 + i]) for i in range(2)]
    impact_offset = [((raw[off + 6 + i] - raw[off + 4 + i] + 128) % 256) - 128 for i in range(2)]
    source_attachment = [raw[off + 6 + i] - raw[off + 4 + i] for i in range(2)]
    entry_id = add_bitmap(image, ax, ay)

    flashes: list[int] = []
    idle_variants = []
    for palette in flash_palettes:
        variants, _, _ = _decode_enemy_art(raw, section_off, atab_off, base, anim_indices, palette_override=palette)
        idle_variants.append(variants)
        variant, vx, vy = variants[hurt_idx]
        if variant.size != image.size or (vx, vy) != (ax, ay):
            raise ValueError(f"{identifier} flash variant changed geometry")
        flashes.append(add_bitmap(variant, ax, ay))

    white_variants, _, _ = _decode_enemy_art(raw, section_off, atab_off, base, anim_indices, palette_override=white)
    wvar, wx, wy = white_variants[hurt_idx]
    white_id = add_bitmap(wvar, wx, wy)

    shocks: list[int] = []
    for palette in shock_palettes:
        variants, _, _ = _decode_enemy_art(raw, section_off, atab_off, base, anim_indices, palette_override=palette)
        variant, vx, vy = variants[hurt_idx]
        if variant.size != image.size or (vx, vy) != (ax, ay):
            raise ValueError(f"{identifier} shock variant changed geometry")
        shocks.append(add_bitmap(variant, vx, vy))

    ko_duration = _knockout_ticks(raw, atab_off, base, animations)
    dead, dx, dy = poses[ko_idx]
    ko_entry = add_bitmap(dead, dx, dy)

    anim0_flags = raw[art_proof["animations"][0] + 1]
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

    hurt_entry = {
        "id": identifier,
        "entry": entry_id,
        "center": center,
        "idle_center": idle_center,
        "sprite_height": raw[idle + 3],
        "impact_offset": impact_offset,
        "source_attachment": source_attachment,
        "white_entry": white_id,
        "flash_entries": flashes,
        "shock_entries": shocks,
        "knockout": {"entry": ko_entry, "duration": ko_duration},
        "idle_flash": idle_flash,
    }
    proof_entry = {
        "id": identifier,
        "source": raw_origin,
        "record_offset": rec_off,
        "section_offset": section_off,
        "atab_offset": atab_off,
        "knockout_ticks": ko_duration,
    }
    return hurt_entry, proof_entry


def _compact_spell_atlas(entries: list[dict], image: Image.Image) -> Image.Image:
    """Keep entry IDs and offsets while packing crops into the existing bounded atlas."""
    crops = []
    for entry in entries:
        x, y, w, h = (entry[key] for key in ("x", "y", "w", "h"))
        if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > image.width or y + h > image.height:
            raise ValueError("spell entry outside source atlas")
        crops.append(image.crop((x, y, x + w, y + h)))
    atlas = Atlas()
    atlas.image = Image.new("RGBA", (4096, 4096), (0, 0, 0, 0))
    positions = [None] * len(entries)
    for index in sorted(range(len(entries)), key=lambda i: (-crops[i].height, -crops[i].width, i)):
        positions[index] = atlas.add(crops[index])
    for entry, rect in zip(entries, positions, strict=True):
        entry.update(x=rect["x"], y=rect["y"])
    return atlas.image.crop((0, 0, atlas.image.width, atlas.y + atlas.row_height))


WORLD_DATA_FILES = (
    ("a", "DATA/01_AREA.A/A_DATA.BIN"),
    ("b", "DATA/02_AREA.B/B_DATA.BIN"),
    ("c", "DATA/06_AREA.C/C_DATA.BIN"),
    ("d", "DATA/07_AREA.D/D_DATA.BIN"),
    ("e", "DATA/08_AREA.E/E_DATA.BIN"),
    ("f", "DATA/09_AREA.F/F_DATA.BIN"),
    ("g", "DATA/10_AREA.G/G_DATA.BIN"),
    ("h", "DATA/11_AREA.H/H_DATA.BIN"),
    ("z", "DATA/15_AREA.Z/Z_DATA.BIN"),
)


def _discover_disc_encounters(get_source) -> dict:
    """Discover all disc-defined area and world random-encounter battle directories."""
    import export_opening_field_package as fpkg

    spec_enemies = {
        (p.rsplit("/", 1)[-1], rec_va - base): (stable_id, anim_indices, target_policy)
        for p, base, rec_va, stable_id, anim_indices, target_policy in ENEMY_SPECS
    }
    spec_bfs_by_ground: dict[tuple[str, int], str] = {}
    for bf_id, area_path, dir_off, base, _, _ in BATTLEFIELD_SPECS:
        raw, _ = get_source(area_path)
        g_sec = struct.unpack_from("<I", raw, dir_off)[0] - base
        spec_bfs_by_ground.setdefault((area_path.rsplit("/", 1)[-1], g_sec), bf_id)

    batch_enc_ids: dict[tuple[str, int], list[str]] = {}
    for area_path, dir_off, base, _, id_prefix, _ in ENCOUNTER_BATCHES:
        raw, _ = get_source(area_path)
        _, raw_encs = bp.directory_encounters(raw, dir_off, base)
        batch_enc_ids[(area_path.rsplit("/", 1)[-1], dir_off)] = [
            id_prefix if len(raw_encs) == 1 else f"{id_prefix}{enc['index']}"
            for enc in raw_encs
        ]

    dir_paths: dict[tuple[str, int], str] = {}
    room_entries: list[tuple[str, int, int, str, int]] = []
    for fname, rnum, rid in fpkg.OPENING_ROOMS:
        bname = fname.rsplit("/", 1)[-1]
        raw, origin = get_source(fname)
        canon_path = origin.get("file") or fname.lstrip("/")
        rec = area_scene.room_record(raw, rnum)
        sec_off = area_scene.section_off(raw, rec["section"])
        for ent in area_scene.entities(raw, rec):
            pc = ent["stream_offsets"][2]
            if pc is None:
                continue
            for _, op, opnd, _ in fpkg.decode_stream(raw, start=pc, max_insns=400):
                if op == 0x47 and opnd and opnd[0] < 0xFE:
                    try:
                        sdir = bp.scripted_directory(raw, sec_off, opnd[0], AREA_BASE)
                        if (
                            (bname, sdir) != ("VA2.BIN", evb.VA2_DIR_VA - AREA_BASE)
                            and sdir + 4 <= len(raw)
                            and AREA_BASE <= struct.unpack_from("<I", raw, sdir)[0] < AREA_BASE + len(raw)
                        ):
                            dir_paths.setdefault((bname, sdir), canon_path)
                    except ValueError:
                        pass
        if sec_off + 0x3C > len(raw):
            continue
        cfg_ptr = struct.unpack_from("<I", raw, sec_off + 0x38)[0]
        if not (AREA_BASE <= cfg_ptr < AREA_BASE + len(raw) - 8):
            continue
        cfg_off = cfg_ptr - AREA_BASE
        rate, thr = raw[cfg_off], raw[cfg_off + 2]
        dir_ptr = struct.unpack_from("<I", raw, cfg_off + 4)[0]
        if not (AREA_BASE <= dir_ptr < AREA_BASE + len(raw)):
            continue
        dir_off = dir_ptr - AREA_BASE
        dir_paths.setdefault((bname, dir_off), canon_path)
        if rate > 0:
            room_entries.append((rid, rate, thr, bname, dir_off))
    # Golden Hydra lives in standalone battle overlay VZV.BIN (dir 0x800294D8, anchored in export_scripted_travel).
    dir_paths.setdefault(("VZV.BIN", 0x194D8), "DATA/15_AREA.Z/VZV.BIN")

    world_battlefields = []
    for letter, wpath in WORLD_DATA_FILES:
        if letter in ("a", "b"):
            continue
        raw, _ = get_source(wpath)
        _, _, d, _ = aet.chain(raw)
        world_battlefields.append((f"world_{letter}", wpath, d - DATA_BASE, DATA_BASE, False, False))

    area_battlefields = []
    enemies = []
    seen_enemy_keys = set(spec_enemies)
    batches = []
    skipped = []
    dir_enc_ids = dict(batch_enc_ids)

    for (bname, dir_off), fpath in sorted(dir_paths.items()):
        if (bname, dir_off) in batch_enc_ids:
            continue
        raw, _ = get_source(fpath)
        stem = bname.removesuffix(".BIN").lower()
        try:
            _, raw_encs = bp.directory_encounters(raw, dir_off, AREA_BASE)
            evb._build_ground(raw, dir_off, AREA_BASE)
        except (ValueError, struct.error, KeyError) as exc:
            skipped.append({"file": fpath, "directory": f"0x{dir_off:x}", "reason": str(exc)})
            continue

        candidate_enemies: list[tuple[int, str, list[int] | None, str]] = []
        local_map: dict[int, str] = {}
        ok = True
        for raw_enc in raw_encs:
            for slot in raw_enc["slots"]:
                rec_off = slot["stats_offset"]
                if slot["enemy_id"] in local_map:
                    continue
                ekey = (bname, rec_off)
                if ekey in spec_enemies:
                    sid, anims_idx, tpol = spec_enemies[ekey]
                    local_map[slot["enemy_id"]] = sid
                    continue
                existing_cand = next((c for c in candidate_enemies if c[0] == rec_off), None)
                if existing_cand is not None:
                    local_map[slot["enemy_id"]] = existing_cand[1]
                    continue
                try:
                    raw_rec = raw[rec_off : rec_off + 64]
                    name, _ = decode_text(raw_rec, length=16)
                    lvl = raw_rec[16]
                    max_hp = struct.unpack_from("<H", raw_rec, 18)[0]
                    money_enc = struct.unpack_from("<h", raw_rec, 52)[0]
                    money = int(money_enc / 10) * 100 if money_enc & 1 else money_enc
                    if not name.strip() or not 1 <= lvl <= 99 or not 1 <= max_hp <= 32767 or not 0 <= money <= 999999:
                        raise ValueError("invalid enemy stats")
                    atab_off = struct.unpack_from("<I", raw_rec, 40)[0] - AREA_BASE
                    sec_off = struct.unpack_from("<I", raw_rec, 44)[0] - AREA_BASE
                    poses, animations, _ = _decode_enemy_art(raw, sec_off, atab_off, AREA_BASE)
                    if not animations[0] or not animations[1] or not animations[3]:
                        raise ValueError("missing core enemy idle/hurt/ko animation")
                    idle_pose = poses[animations[0][0][0]]
                    if idle_pose is None or idle_pose[0].getchannel("A").getbbox() is None:
                        raise ValueError("empty enemy idle sprite")
                    dummy_packed = {
                        idx: {"rect": {"x": 0, "y": 0, "w": p[0].width, "h": p[0].height}, "anchor_x": p[1], "anchor_y": p[2]}
                        for idx, p in enumerate(poses) if p is not None
                    }
                    attack_frames, _ = _extract_attack(raw, atab_off, AREA_BASE, animations, dummy_packed, None)
                    if not attack_frames:
                        raise ValueError("empty enemy attack frames")
                    slug = re.sub(r"[^a-z0-9]+", "_", name.strip().lower()).strip("_") or "enemy"
                    sid = f"{stem}_{slug}_{rec_off:x}"
                    local_map[slot["enemy_id"]] = sid
                    candidate_enemies.append((rec_off, sid, None, "front_first"))
                except (ValueError, IndexError, KeyError, struct.error) as exc:
                    skipped.append({
                        "file": fpath,
                        "directory": f"0x{dir_off:x}",
                        "enemy": f"0x{rec_off:x}",
                        "reason": str(exc),
                    })
                    ok = False
                    break
            if not ok:
                break
        if not ok:
            continue

        g_sec = struct.unpack_from("<I", raw, dir_off)[0] - AREA_BASE
        bf_id = spec_bfs_by_ground.get((bname, g_sec))
        if bf_id is None:
            bf_id = f"{stem}_bf_{dir_off:x}"
            spec_bfs_by_ground[(bname, g_sec)] = bf_id
            area_battlefields.append((bf_id, fpath, dir_off, AREA_BASE, False, False))

        for rec_off, sid, anims_idx, tpol in candidate_enemies:
            ekey = (bname, rec_off)
            if ekey not in seen_enemy_keys:
                seen_enemy_keys.add(ekey)
                enemies.append((fpath, AREA_BASE, AREA_BASE + rec_off, sid, anims_idx, tpol))

        prefix = f"{stem}_dir_{dir_off:x}_"
        enc_ids = [f"{prefix}{enc['index']}" for enc in raw_encs]
        dir_enc_ids[(bname, dir_off)] = enc_ids
        batches.append((fpath, dir_off, AREA_BASE, bf_id, prefix, {}, local_map, True))

    covered_rooms = {room for grp in FIELD_ENCOUNTER_GROUPS for room in grp["rooms"]}
    grouped_rooms: dict[tuple[int, int, tuple[str, ...]], list[str]] = {}
    for rid, rate, thr, bname, dir_off in room_entries:
        if rid in covered_rooms:
            continue
        enc_ids = dir_enc_ids.get((bname, dir_off))
        if not enc_ids:
            continue
        grouped_rooms.setdefault((rate, thr, tuple(enc_ids)), []).append(rid)

    room_groups = [
        {"rooms": rids, "rate": rate, "counter_threshold": thr, "encounters": list(enc_ids)}
        for (rate, thr, enc_ids), rids in sorted(grouped_rooms.items(), key=lambda kv: kv[1][0])
    ]
    return {
        "world_battlefields": world_battlefields,
        "area_battlefields": area_battlefields,
        "enemies": enemies,
        "batches": batches,
        "skipped": skipped,
        "room_groups": room_groups,
    }


TORAN_INTRUDER = "toran_intruder"


def bind_toran_intruder(trial, spells, provenance) -> bool:
    """Bind the solo Toran encounter to existing actor and battlefield art."""
    donor_id = "vh1_ninja_63074"
    donor = next((row for row in trial["enemies"] if row["id"] == donor_id), None)
    hurt = next((row for row in spells["hurt_poses"] if row["id"] == donor_id), None)
    battlefield = "va3_raid"
    if donor is None or hurt is None or not any(row["id"] == battlefield for row in trial["battlefields"]):
        return False
    path = "DATA/02_AREA.B/VB5A2.BIN"
    data, origin = disc_source(path)
    room = area_scene.room_record(data, 4)
    section = area_scene.section_off(data, room["section"])
    entry = area_scene.entities(data, room)[15]["stream_offsets"][2]
    if entry != 0x40870 or data[0x40896:0x4089C] != bytes.fromhex("09 13 20 47 00 fd"):
        raise ValueError("Toran solo encounter caller changed")
    directory = bp.scripted_directory(data, section, 0, AREA_BASE)
    _, formations = bp.directory_encounters(data, directory, AREA_BASE)
    formation, = formations
    slot, = formation["slots"]
    offset = slot["stats_offset"]
    level, hp = data[offset + 16], struct.unpack_from("<H", data, offset + 18)[0]
    attack, skill, defense, speed = struct.unpack_from("<4H", data, offset + 20)
    magic, luck = data[offset + 28:offset + 30]
    flags = struct.unpack_from("<H", data, offset + 38)[0]
    callback = struct.unpack_from("<I", data, offset + 48)[0]
    round_check = struct.unpack_from("<3I", data, callback - AREA_BASE + 0x148)
    if (directory, slot["slot"], slot["enemy_id"], callback, round_check) != (
        0x6DA34, 0, 1, 0x8001789C, (0x8E420004, 0, 0x28420003),
    ):
        raise ValueError("Toran intruder formation or withdrawal threshold changed")
    affinity = {element: evb.AFFINITY_NAMES.get(data[offset + 32 + index], "neutral")
                for index, element in enumerate(("fire", "water", "earth", "lightning", "wind"))}
    profile = {key: donor[key] for key in ("sprite", "foot_offset_y", "attack", "motion") if key in donor}
    profile.update(id=TORAN_INTRUDER, name="Intruder", max_hp=hp, level=level, money=0,
                   stats=dict(attack=attack, skill=skill, defense=defense, speed=speed, magic=magic, luck=luck),
                   affinities=affinity, fire_affinity=affinity["fire"],
                   other_affinity=evb.AFFINITY_NAMES.get(data[offset + 37], "neutral"),
                   death_immune=bool(flags & 0x4000), airborne=bool(flags & 32),
                   target_policy="front_first", action_policy="attack")
    encounter = dict(id=TORAN_INTRUDER, title="Castle Intruder", enemies=[TORAN_INTRUDER],
                     experience_per_member=0, positions=[dict(zip("xyz", slot["world"]))],
                     enemy_rows=["front"], source_slots=[0], escape_allowed=False, battlefield=battlefield,
                     reward_policy="none", scripted_finish={"after_round": 3, "wait_ticks": 12}, music="normal")
    additions = []
    for rows, row in ((trial["enemies"], profile), (trial["encounters"], encounter),
                      (spells["hurt_poses"], dict(hurt, id=TORAN_INTRUDER))):
        previous = next((item for item in rows if item["id"] == TORAN_INTRUDER), None)
        if previous is None:
            additions.append((rows, row))
        elif previous != row:
            raise ValueError("conflicting Toran intruder binding")
    proof = dict(source=origin, room=4, entity=15, directory_offset=directory, record_offset=offset,
                 decision_callback=callback, art_donor=donor_id, battlefield=battlefield,
                 timing="prototype: withdrawal at the end of round three")
    changed = bool(additions)
    for rows, row in additions:
        rows.append(row)
    if provenance.get(TORAN_INTRUDER) != proof:
        provenance[TORAN_INTRUDER] = proof
        changed = True
    return changed


def append_route_battles(battle_dir: Path) -> bool:
    """Append source-bound route and disc-wide battlefields, enemies, hurt poses, and encounters idempotently."""
    from export_scripted_travel import kouan_wheel
    wheel_monster = json.loads(json.dumps(kouan_wheel()['monster']))
    trial_path = battle_dir / "trial.json"
    spells_path = battle_dir / "spells.json"
    actors_path = battle_dir / "actors.png"
    ground_path = battle_dir / "ground.png"
    spell_img_path = battle_dir / "spell_effects.png"
    proof_path = battle_dir / "provenance.json"

    trial = json.loads(trial_path.read_text())
    spells = json.loads(spells_path.read_text())
    provenance = json.loads(proof_path.read_text())

    needed_enemies = {spec[3] for spec in ENEMY_SPECS}
    needed_fields = {"world_a"} | {spec[0] for spec in BATTLEFIELD_SPECS}
    existing_enemies = {e["id"] for e in trial.get("enemies", [])}
    existing_hurt = {h["id"] for h in spells.get("hurt_poses", [])}
    existing_fields = {f["id"] for f in trial.get("battlefields", [])}
    existing_encs = {e["id"] for e in trial.get("encounters", [])}
    disc_meta = provenance.get("disc_encounters") or {}

    if (
        trial.get("schema") == "suikoden-battle-trial/46"
        and needed_enemies <= existing_enemies
        and needed_enemies <= existing_hurt
        and needed_fields <= existing_fields
        and "vb6_ord_8" in existing_encs
        and "va7_r9_b1" in existing_encs
        and "va3_raid" in existing_encs
        and "vb1_school" in existing_encs
        and "lenankamp_raid" in provenance
        and "seika_school" in provenance
        and "vb3_wheel_monster" in existing_encs
        and "kouan_wheel" in provenance
        and provenance['kouan_wheel'].get('selection_consumer') == wheel_monster
        and disc_meta.get("schema") == "suikoden-disc-encounters/2"
        and {"ve1_dir_57450_1", "ve3_dir_8ddac_1", "vs1_dir_69554_1", "vs1_dir_69570_1", "vzv_dir_194d8_1"} <= existing_encs
        and set(disc_meta.get("battlefields", [])) <= existing_fields
        and set(disc_meta.get("enemies", [])) <= existing_enemies
        and set(disc_meta.get("enemies", [])) <= existing_hurt
        and set(disc_meta.get("encounters", [])) <= existing_encs
    ):
        changed = bind_toran_intruder(trial, spells, provenance)
        if changed:
            trial_path.write_text(json.dumps(trial, separators=(",", ":")) + "\n")
            spells_path.write_text(json.dumps(spells, separators=(",", ":")) + "\n")
            proof_path.write_text(json.dumps(provenance, indent=2) + "\n")
        return changed

    area_cache: dict[str, tuple[bytes, dict]] = {}

    def get_source(path: str) -> tuple[bytes, dict]:
        if path not in area_cache:
            raw, origin = disc_source(path)
            if path.rsplit("/", 1)[-1] == "VC6.BIN":
                raw = raw + disc_source("DATA/06_AREA.C/VC61.BIN")[0]
            area_cache[path] = (raw, origin)
        return area_cache[path]

    disc_info = _discover_disc_encounters(get_source)

    with Image.open(actors_path) as a_im:
        actors_img = a_im.convert("RGBA")
    with Image.open(ground_path) as g_im:
        ground_img = g_im.convert("RGB")
    with Image.open(spell_img_path) as s_im:
        spell_img = s_im.convert("RGBA")

    actor_atlas = Atlas()
    actor_atlas.image = Image.new("RGBA", (4096, 4096), (0, 0, 0, 0))
    actor_atlas.image.paste(actors_img, (0, 0))
    actor_atlas.y = actors_img.height + 1
    actor_atlas.x = 0
    actor_atlas.row_height = 0

    # 1. Battlefields (route + world + discovered area directories)
    trial.setdefault("battlefields", [])
    if "world_a" not in existing_fields and trial.get("ground"):
        trial["battlefields"].append({
            "id": "world_a",
            "ground": trial["ground"],
            "ground_atlas": {"x": 0, "y": 0, "w": 512, "h": 512},
            "scenery": trial.get("scenery", []),
        })
        existing_fields.add("world_a")

    ground_strips: list[tuple[dict, Image.Image]] = []
    all_bf_specs = (*BATTLEFIELD_SPECS, *disc_info["world_battlefields"], *disc_info["area_battlefields"])
    for bf_id, area_path, dir_off, base, has_scenery, fix_va4 in all_bf_specs:
        if bf_id in existing_fields:
            continue
        raw, _ = get_source(area_path)
        strip_img, bf_ground = evb._build_ground(raw, dir_off, base)
        bf_scenery: list[dict] = []
        if has_scenery:
            bf = bp.directory_battlefield(raw, dir_off, base)
            if bf.get("scenery"):
                sc_sec = struct.unpack_from("<I", raw, dir_off + 4)[0] - base
                sec_data = raw
                if fix_va4:
                    buf = bytearray(raw)
                    struct.pack_into("<H", buf, sc_sec, 1)
                    sec_data = bytes(buf)
                sc_poses, sc_clips, _ = ebt.section_art(sec_data, sc_sec, base)
                packed_sc = _pack_shelf_poses(actor_atlas, sc_poses)
                for pl in bf["scenery"]["placements"]:
                    anim_idx = pl["descriptor"]
                    pose_idx = sc_clips[anim_idx][0][0]
                    bf_scenery.append({
                        "sprite": packed_sc[pose_idx],
                        "position": ebt.world_position(pl["world"]),
                    })
        bf_entry = {
            "id": bf_id,
            "ground": bf_ground,
            "ground_atlas": {"x": 0, "y": 0, "w": strip_img.width, "h": strip_img.height},
            "scenery": bf_scenery,
        }
        ground_strips.append((bf_entry, strip_img))
        trial["battlefields"].append(bf_entry)
        existing_fields.add(bf_id)

    if ground_strips:
        atlas_w = max(ground_img.width, 2048)
        gx = 0
        gy = ((ground_img.height + 31) // 32) * 32
        row_h = 0
        placed_strips: list[tuple[Image.Image, int, int]] = []
        for bf_entry, st in ground_strips:
            if gx + st.width > atlas_w:
                gx = 0
                gy += ((row_h + 31) // 32) * 32
                row_h = 0
            if gy + st.height > 4096:
                raise ValueError(f"battle/ground.png height {gy + st.height} exceeds 4096")
            bf_entry["ground_atlas"] = {"x": gx, "y": gy, "w": st.width, "h": st.height}
            placed_strips.append((st, gx, gy))
            gx += ((st.width + 31) // 32) * 32
            row_h = max(row_h, st.height)
        total_h = ((gy + row_h + 31) // 32) * 32
        merged_ground = Image.new("RGB", (atlas_w, total_h))
        merged_ground.paste(ground_img, (0, 0))
        for st, px, py in placed_strips:
            merged_ground.paste(st, (px, py))
        ground_img = merged_ground

    # 2. Enemies & Hurt poses (route + discovered area enemies)
    flash_palettes = ess.reaction_palettes()
    white = struct.unpack_from("<32H", maindec.body(), 0x8016B8A8 - maindec.MBASE)
    shock_palettes = ess.reaction_palettes((4, 5, 6))
    new_spell_images: list[tuple[Image.Image, int, int]] = []
    base_spell_count = len(spells["entries"])
    added_spell_entries: list[dict] = []

    def add_spell_bitmap(img: Image.Image, ax: int, ay: int) -> int:
        idx = base_spell_count + len(added_spell_entries)
        new_spell_images.append((img, -ax, -ay))
        added_spell_entries.append({"dx": -ax, "dy": -ay, "w": img.width, "h": img.height})
        return idx

    all_enemy_specs = (*ENEMY_SPECS, *disc_info["enemies"])
    for area_path, base, rec_va, stable_id, anim_indices, target_policy in all_enemy_specs:
        raw, origin = get_source(area_path)
        rec_off = rec_va - base
        if stable_id not in existing_enemies:
            raw_rec = raw[rec_off : rec_off + 64]
            name, _ = decode_text(raw_rec, length=16)
            lvl = raw_rec[16]
            max_hp, atk, skl, defn, spd = struct.unpack_from("<5H", raw_rec, 18)
            mgc, lck = raw_rec[28], raw_rec[29]
            flags = struct.unpack_from("<H", raw_rec, 38)[0]
            atab_off = struct.unpack_from("<I", raw_rec, 40)[0] - base
            sec_off = struct.unpack_from("<I", raw_rec, 44)[0] - base
            money_enc = struct.unpack_from("<h", raw_rec, 52)[0]
            money = int(money_enc / 10) * 100 if money_enc & 1 else money_enc
            aff_bytes = raw_rec[32:38]
            aff_map = {
                element: evb.AFFINITY_NAMES.get(aff_bytes[idx], "neutral")
                for idx, element in enumerate(("fire", "water", "earth", "lightning", "wind"))
            }
            poses, animations, _ = _decode_enemy_art(raw, sec_off, atab_off, base, anim_indices)
            packed_poses = _pack_shelf_poses(actor_atlas, poses)
            idle_idx = animations[0][0][0]
            attack_frames, motion = _extract_attack(raw, atab_off, base, animations, packed_poses, anim_indices)
            foot_y = ebt.foot_offset_y(poses[idle_idx])
            profile = {
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
                "fire_affinity": aff_map["fire"],
                "affinities": aff_map,
                "other_affinity": evb.AFFINITY_NAMES.get(aff_bytes[5], "neutral"),
                "death_immune": bool(flags & 0x4000),
                "airborne": bool(flags & 32),
                "target_policy": target_policy,
                "action_policy": "attack",
                "dodges_attacks": False,
                "unavoidable_attack": False,
            }
            if motion is not None:
                profile["motion"] = motion
            trial["enemies"].append(profile)
            existing_enemies.add(stable_id)

        if stable_id not in existing_hurt:
            hurt_entry, _ = _build_hurt_pose_entry(
                raw, origin, base, stable_id, rec_off, anim_indices,
                flash_palettes, white, shock_palettes, add_spell_bitmap,
            )
            spells["hurt_poses"].append(hurt_entry)
            existing_hurt.add(stable_id)

    if actor_atlas.x > 0 or actor_atlas.row_height > 0:
        actors_height = actor_atlas.y + actor_atlas.row_height
        if actors_height > 4096:
            raise ValueError(f"packed actors.png height {actors_height} exceeds 4096")
        actors_img = actor_atlas.image.crop((0, 0, 4096, actors_height))

    if new_spell_images:
        spells["entries"].extend(added_spell_entries)
        x = 0
        y = spell_img.height
        row_h = 0
        placed_spell: list[tuple[Image.Image, int, int]] = []
        for idx, (img, _, _) in enumerate(new_spell_images):
            if x + img.width > spell_img.width:
                x = 0
                y += row_h
                row_h = 0
            placed_spell.append((img, x, y))
            spells["entries"][base_spell_count + idx]["x"] = x
            spells["entries"][base_spell_count + idx]["y"] = y
            x += img.width
            row_h = max(row_h, img.height)
        new_spell_img = Image.new("RGBA", (spell_img.width, y + row_h), (0, 0, 0, 0))
        new_spell_img.paste(spell_img, (0, 0))
        for img, px, py in placed_spell:
            new_spell_img.paste(img, (px, py))
        spell_img = new_spell_img
        if spell_img.height > 4096:
            spell_img = _compact_spell_atlas(spells["entries"], spell_img)
        if spell_img.height > 4096:
            raise ValueError(f"spell_effects.png height {spell_img.height} exceeds 4096")

    # 3. Bind all world encounters (area_a..z, world_c_encounter_*) to world_<letter>
    for enc in trial["encounters"]:
        if enc.get("battlefield") is not None:
            continue
        if enc["id"].startswith("world_c_encounter_"):
            enc["battlefield"] = "world_c"
        else:
            for letter, _ in WORLD_DATA_FILES:
                if enc["id"].startswith(f"area_{letter}_"):
                    enc["battlefield"] = f"world_{letter}"
                    break

    # 4. Append route and discovered area encounters
    enemy_by_id = {e["id"]: e for e in trial["enemies"]}
    all_batches = [
        (*row, LOCAL_ENEMY_MAPS[(row[0], row[1])], False) for row in ENCOUNTER_BATCHES
    ] + disc_info["batches"]
    disc_enc_ids: list[str] = []
    for area_path, dir_off, base, bf_id, id_prefix, extras, local_map, always_indexed in all_batches:
        raw, _ = get_source(area_path)
        _, raw_encs = bp.directory_encounters(raw, dir_off, base)
        for raw_enc in raw_encs:
            idx = raw_enc["index"]
            enc_id = f"{id_prefix}{idx}" if (always_indexed or len(raw_encs) != 1) else id_prefix
            if always_indexed:
                disc_enc_ids.append(enc_id)
            if enc_id in existing_encs:
                continue
            slots = sorted(raw_enc["slots"], key=lambda s: s["slot"])
            roster = [local_map[s["enemy_id"]] for s in slots]
            levels = [enemy_by_id[eid]["level"] for eid in roster]
            exp = exp_award.award_pool([5] * 6, [0] * 6, levels)[1]
            fl_word = struct.unpack_from("<I", raw, raw_enc["descriptor_offset"] + 12)[0]
            title = " / ".join(dict.fromkeys(enemy_by_id[eid]["name"] for eid in roster))
            enc_obj = {
                "id": enc_id,
                "title": title,
                "enemies": roster,
                "experience_per_member": exp,
                "positions": [dict(zip("xyz", s["world"])) for s in slots],
                "enemy_rows": ["front" if s["slot"] < 3 else "back" for s in slots],
                "escape_allowed": not bool(fl_word & 0x80000000),
                "source_slots": [s["slot"] for s in slots],
                "battlefield": bf_id,
                **export_battle_audio.encounter_music(fl_word),
            }
            if "music" not in enc_obj:
                enc_obj["music"] = "normal"
            if idx in extras:
                enc_obj.update(extras[idx])
            trial["encounters"].append(enc_obj)
            existing_encs.add(enc_id)

    trial["schema"] = "suikoden-battle-trial/46"
    for key, area_path, directory in (("lenankamp_raid", "DATA/01_AREA.A/VA3.BIN", 0x51EF8),
                                       ("seika_school", "DATA/02_AREA.B/VB1.BIN", 0x3A2F8),
                                       ("kouan_wheel", "DATA/02_AREA.B/VB3.BIN", 0x67DC0)):
        raw, origin = get_source(area_path)
        _, formations = bp.directory_encounters(raw, directory, AREA_BASE)
        provenance[key] = {
            "source": origin,
            "exporter": "export_route_battles.py",
            "codec": f"lzss.py/{lzss.__version__}; export_battle_trial.section_art",
            "directory_offset": directory,
            "enemies": [{"id": spec[3], "record_offset": spec[2] - AREA_BASE}
                        for spec in ENEMY_SPECS if spec[0] == area_path],
            "formations": formations,
            "battlefield": bp.directory_battlefield(raw, directory, AREA_BASE),
            "scenery_status": "not exported: battle sprite pointer outside source",
            "media_acceptance": "pending",
        }
        if key == 'kouan_wheel':
            provenance[key]['selection_consumer'] = wheel_monster

    provenance["disc_encounters"] = {
        "schema": "suikoden-disc-encounters/2",
        "battlefields": [b[0] for b in (*disc_info["world_battlefields"], *disc_info["area_battlefields"])],
        "enemies": [e[3] for e in disc_info["enemies"]],
        "encounters": disc_enc_ids,
        "skipped": disc_info["skipped"],
        "room_groups": disc_info["room_groups"],
    }
    bind_toran_intruder(trial, spells, provenance)
    ground_img.save(ground_path)
    actors_img.save(actors_path)
    spell_img.save(spell_img_path)
    trial_path.write_text(json.dumps(trial, separators=(",", ":")) + "\n")
    spells_path.write_text(json.dumps(spells, separators=(",", ":")) + "\n")
    proof_path.write_text(json.dumps(provenance, indent=2) + "\n")
    return True


FIELD_ENCOUNTER_GROUPS = [
    {"rooms": [f"va8_room_{i}" for i in (0, 1, 3, 6, 8, 9)], "rate": 2, "counter_threshold": 60,
     "encounters": [f"va8_ord_{i}" for i in range(1, 6)]},
    {"rooms": [f"va8_room_{i}" for i in (2, 4, 7)], "rate": 3, "counter_threshold": 60,
     "encounters": [f"va8_ord_{i}" for i in range(1, 6)]},
    {
        "rooms": ["va4_room_1", "va4_room_2", "va4_room_3", "va4_room_12"],
        "rate": 4,
        "counter_threshold": 50,
        "encounters": [f"va4_ord_{i}" for i in range(1, 10)],
    },
    {
        "rooms": ["va7_room_0", "va7_room_12"],
        "rate": 2,
        "counter_threshold": 60,
        "encounters": [f"va7_ord_r0_{i}" for i in range(1, 6)],
    },
    {
        "rooms": [f"va7_room_{i}" for i in range(1, 12)],
        "rate": 2,
        "counter_threshold": 60,
        "encounters": [f"va7_ord_{i}" for i in range(1, 6)],
    },
    {
        "rooms": [f"vb6_room_{i}" for i in range(1, 6)],
        "rate": 2,
        "counter_threshold": 60,
        "encounters": [f"vb6_ord_{i}" for i in range(1, 9)],
    },
    {
        "rooms": ["world_a"],
        "rate": 8,
        "counter_threshold": 4,
        "encounters": [f"area_a_{i}" for i in range(1, 10)],
    },
    {
        "rooms": ["world_b"],
        "rate": 8,
        "counter_threshold": 4,
        "encounters": [f"area_b_{i}" for i in range(1, 9)],
    },
]


def append_field_encounters(canonical: Path) -> bool:
    """Populate canonical journey.json field_encounters (suikoden-field-movement-encounters/3) idempotently."""
    journey_path = canonical / "journey.json"
    room_path = canonical / "room.json"
    trial_path = canonical / "battle/trial.json"
    if not (journey_path.is_file() and room_path.is_file() and trial_path.is_file()):
        return False

    import assemble_battle_review

    journey = json.loads(journey_path.read_text())
    package = json.loads(room_path.read_text())
    trial = json.loads(trial_path.read_text())

    groups = [dict(grp) for grp in FIELD_ENCOUNTER_GROUPS]
    covered_rooms = {r for grp in groups for r in grp["rooms"]}
    known_rooms = {r["id"] for r in package["rooms"]}
    existing_encs = {e["id"] for e in trial["encounters"]}

    for letter, _ in WORLD_DATA_FILES:
        world_room = f"world_{letter}"
        if world_room in covered_rooms or world_room not in known_rooms:
            continue
        prefix = "world_c_encounter_" if letter == "c" else f"area_{letter}_"
        enc_ids = sorted(
            (e["id"] for e in trial["encounters"] if e["id"].startswith(prefix)),
            key=lambda name: int(name.rsplit("_", 1)[1]),
        )
        if enc_ids:
            groups.append({"rooms": [world_room], "rate": 8, "counter_threshold": 4, "encounters": enc_ids})
            covered_rooms.add(world_room)

    proof_path = canonical / "battle/provenance.json"
    room_groups = None
    if proof_path.is_file():
        proof = json.loads(proof_path.read_text())
        room_groups = (proof.get("disc_encounters") or {}).get("room_groups")
    if room_groups is None:
        area_cache: dict[str, tuple[bytes, dict]] = {}

        def get_source(path: str) -> tuple[bytes, dict]:
            if path not in area_cache:
                raw, origin = disc_source(path)
                if path.rsplit("/", 1)[-1] == "VC6.BIN":
                    raw = raw + disc_source("DATA/06_AREA.C/VC61.BIN")[0]
                area_cache[path] = (raw, origin)
            return area_cache[path]

        room_groups = _discover_disc_encounters(get_source)["room_groups"]

    for grp in room_groups:
        rids = [rid for rid in grp["rooms"] if rid in known_rooms and rid not in covered_rooms]
        if rids and grp["encounters"] and all(eid in existing_encs for eid in grp["encounters"]):
            groups.append({
                "rooms": rids,
                "rate": grp["rate"],
                "counter_threshold": grp["counter_threshold"],
                "encounters": list(grp["encounters"]),
            })
            covered_rooms.update(rids)

    compiled = assemble_battle_review.compile_field_encounter_groups(
        {
            "schema": "suikoden-field-encounter-groups/1",
            "suppress_when": {
                "kind": "story_mask_set",
                "flag": {"id": "scenario_0043", "mask": 64},
            },
            "clear_suppression_on_world_entry": True,
            "groups": groups,
        },
        package,
        trial,
    )
    if journey.get("field_encounters") == compiled:
        return False
    journey["field_encounters"] = compiled
    journey_path.write_text(json.dumps(journey, separators=(",", ":")) + "\n")
    return True
