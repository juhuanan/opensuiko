#!/usr/bin/env python3
"""Three source-defined encounters in an authored, isolated battle trial."""
from pathlib import Path
import argparse
import hashlib
import json
import struct
from export_battle_audio import encounter_music

from PIL import Image
import area_encounter_tables as encounters
import battle_mock as visuals
import enemy_sprites
import exp_award
import maindec
import battle_placement
from actor_script import OP_LEN_HW
from lzss import decode_strict
from psx_vram import rgb555_to_rgb888
from export_first_room import ROOT, source, Atlas
from war_text import decode


def section_art(data, section, base=0, *, palette_override=None, animation_indices=None, selected_poses_only=False, axis_aligned_packet=False, pose_table_end=None, individual_pieces=False, animation_table_end=None):
    """Compose battle e-records and f-records, never infer a sprite grid."""
    def pointer(offset):
        target = struct.unpack_from('<I', data, offset)[0] - base
        if not 0 <= target < len(data):
            raise ValueError('battle sprite pointer outside source')
        return target
    ne, nf, nc, flags = struct.unpack_from('<HHBB', data, section)
    declared_nf=nf
    if animation_table_end is not None:
        ft=pointer(section+20)
        if type(animation_table_end) is not int or not ft+4*nf<=animation_table_end<=len(data) or (animation_table_end-ft)%4 or (animation_table_end-ft)//4>256:
            raise ValueError('invalid proven animation table extent')
        nf=(animation_table_end-ft)//4
    selected = list(range(nf)) if animation_indices is None else list(animation_indices)
    if any(type(i) is not int or not 0 <= i < nf for i in selected):
        raise ValueError('battle animation selection outside source')
    selected = set(selected)
    ct, dt, et, ft = [pointer(section + offset) for offset in (8, 12, 16, 20)]
    declared_ne = ne
    if pose_table_end is not None:
        if type(pose_table_end) is not int or not et+4*ne <= pose_table_end <= len(data) or (pose_table_end-et)%4 or (pose_table_end-et)//4 > 256:
            raise ValueError('invalid proven pose table extent')
        ne = (pose_table_end-et)//4
    planes = []
    for index in range(nc):
        blob = pointer(ct + 4 * index)
        length = struct.unpack_from('<I', data, blob)[0]
        raw = decode_strict(data[blob + 4:blob + 4 + length])
        if len(raw) != 16384:
            raise ValueError('battle sprite page is not 128x128')
        planes.append(raw)
    words = 32 if flags & 0xC0 else 256
    palettes = [struct.unpack_from('<' + 'H' * words, data, pointer(dt + 4 * i))
                for i in range(flags & 63)]
    if palette_override is not None:
        if len(palette_override) != words or any(not 0 <= value <= 65535 for value in palette_override):
            raise ValueError('invalid battle palette override')
        palettes = [palette_override for _ in palettes]
    used_poses = None
    if selected_poses_only:
        used_poses = set()
        for animation in selected:
            frame = pointer(ft + 4 * animation)
            used_poses.update(data[frame + 4 + 2 * k] for k in range(data[frame] or 1))
    poses, proof = [], []
    for index in range(ne):
        offset = pointer(et + 4 * index)
        if used_poses is not None and index not in used_poses:
            poses.append(None)
            proof.append(offset)
            continue
        count, _, width, height, ax, ay = data[offset:offset + 6]
        pieces = [tuple(data[offset + 8 + k * 8:offset + 16 + k * 8]) for k in range(count)]
        extra = 0 if axis_aligned_packet else 1
        width = max([width] + [p[0] + p[4] + extra for p in pieces])
        height = max([height] + [p[1] + p[5] + extra for p in pieces])
        image = Image.new('RGBA', (width, height))
        piece_images = []
        for k in range(count):
            x, y, page, tile, wm, hm, pal, flip = data[offset + 8 + k * 8:offset + 16 + k * 8]
            if axis_aligned_packet and (flip or wm == 0 or hm == 0):
                raise ValueError('unsupported packet footprint')
            u, v, w, h = (tile & 15) * 8, (tile >> 4) * 8, wm + extra, hm + extra
            if (page >= len(planes) or pal >= len(palettes) or flip & ~3 or
                    u + w > 128 or v + h > 128 or x + w > width or y + h > height):
                raise ValueError('unsupported battle piece sampling')
            part = Image.new('RGBA', (w, h))
            for py in range(h):
                for px in range(w):
                    word = palettes[pal][planes[page][(v + py) * 128 + u + px]]
                    part.putpixel((px, py), (*rgb555_to_rgb888(word), 255 if word else 0))
            if flip & 2:
                part = part.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
            if flip & 1:
                part = part.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
            piece_images.append((part, ax-x, ay-y))
            image.alpha_composite(part, (x, y))
        poses.append(piece_images if individual_pieces else (image, ax, ay))
        proof.append(offset)
    animations = []
    for i in range(nf):
        # Unused F records may reference absent poses; selected art must stand on its own evidence.
        if i not in selected:
            animations.append([])
            continue
        offset = pointer(ft + 4 * i)
        count = data[offset]
        pairs = [tuple(data[offset + 4 + k * 2:offset + 6 + k * 2]) for k in range(count)]
        if any(e >= ne for e, _ in pairs):
            raise ValueError('battle animation references missing pose')
        animations.append(pairs)
    details = {'section': section, 'poses': proof,
               'animations': [pointer(ft + i * 4) if i in selected else None for i in range(nf)]}
    if pose_table_end is not None:details.update(declared_pose_count=declared_ne,pose_table_end=pose_table_end)
    if animation_table_end is not None:details.update(declared_animation_count=declared_nf,animation_table_end=animation_table_end)
    return poses, animations, details


def pack_pose(atlas, pose):
    image, ax, ay = pose
    return {'rect': atlas.add(image), 'anchor_x': ax, 'anchor_y': ay}


def foot_offset_y(pose):
    image, _, anchor_y = pose
    bounds = image.getchannel('A').getbbox()
    if bounds is None:
        raise ValueError('empty battle idle pose')
    return bounds[3] - 1 - anchor_y


def attack_schedule(data, poses, animations, atlas):
    table = struct.unpack_from('<I', data, 32)[0]
    frames, clock, approach, retreat, impact, ready = [], 0, None, None, None, None
    for script_index in (1, 4):
        cursor = struct.unpack_from('<I', data, table + script_index * 4)[0]
        selected, pending_ticks = 0, 0
        for _ in range(128):
            op = struct.unpack_from('<H', data, cursor)[0]
            if op in (0, 1):
                break
            length = OP_LEN_HW[op]
            if not length:
                raise ValueError('unsupported trial action script')
            args = struct.unpack_from('<' + 'h' * (length - 1), data, cursor + 2)
            if op == 4:
                selected = args[0]
            elif op == 5:
                for e, ticks in animations[selected]:
                    frames.append({'pose': pack_pose(atlas, poses[e]), 'ticks': ticks or 256, 'source_pose': e})
                    clock += ticks or 256
            elif op == 3:
                frames.append({'pose': pack_pose(atlas, poses[animations[selected][-1][0]]), 'ticks': args[0], 'source_pose': animations[selected][-1][0]})
                clock += args[0]
            elif op == 23:
                mode, duration, x, y, z, vx, vy, vz = args
                if mode not in (2, 3) or duration < 2:
                    raise ValueError('unsupported trial leap')
                move = {'ticks': duration, 'acceleration_step': 1/4096, 'offset': dict(zip(('x', 'y', 'z'), (x, y, z))),
                        'velocity': dict(zip(('x', 'y', 'z'), (vx / 2, vy / 2, vz / 2)))}
                if mode == 2:
                    approach = (clock, move)
                else:
                    retreat = (clock, move)
                pending_ticks = duration
            elif op == 21:
                frames.append({'pose': pack_pose(atlas, poses[animations[selected][-1][0]]), 'ticks': pending_ticks, 'source_pose': animations[selected][-1][0]})
                clock += pending_ticks
            elif op == 26 and args == (0, 2):
                impact = clock
            elif op == 26 and args == (0, 4) and script_index == 1:
                ready = clock
            cursor += length * 2
        else:
            raise ValueError('unterminated trial action script')
    if approach is None or retreat is None or impact is None or ready is None or not impact <= ready <= retreat[0]:
        raise ValueError('missing trial attack stages')
    return frames, {'approach_start': approach[0], 'approach': approach[1], 'impact_tick': impact, 'ready_tick': ready,
                    'return_start': retreat[0], 'retreat': retreat[1], 'duration': clock}


def world_position(world):
    return dict(zip(('x', 'y', 'z'), world))


def screen_position(world):
    x, y, depth = visuals.project_point(world, H=visuals.PROJ_H * 0.8)
    y += 17
    # Crop the original scene to leave space for the prototype command panels.
    return {'x': round(x * 2, 3), 'y': round((y - 36) * 2, 3), 'depth': depth}


def ground_tiles(data, directory):
    """800E7C3C..68 selects a palette per page and tile, via section+0x10."""
    pointer = lambda off: struct.unpack_from('<I', data, off)[0] - encounters.BASE
    pages, _, meta = visuals.battle_ground_atlas(data, entry=0, palette=0)
    section, count, flags, _, width, height, tilemap = meta
    if len(pages) != count or not tilemap:
        raise ValueError('partial battle ground export')
    dt, pt = pointer(section + 12), pointer(section + 16)
    words = 32 if flags & 0xC0 else 256
    palettes = [struct.unpack_from('<' + 'H' * words, data, pointer(dt + 4 * i))
                for i in range(flags & 63)]
    selectors = [list(data[pointer(pt + i * 4):pointer(pt + i * 4) + 16]) for i in range(count)]
    floor = Image.new('RGB', (width * 32, height * 32))
    for cell, code in enumerate(tilemap):
        page, tile = code >> 4, code & 15
        palette = palettes[selectors[page][tile]]
        for y in range(32):
            for x in range(32):
                index = pages[page][((tile >> 2) * 32 + y) * 128 + (tile & 3) * 32 + x]
                floor.putpixel(((cell % width) * 32 + x, (cell // width) * 32 + y), rgb555_to_rgb888(palette[index]))
    return floor, {'section': section, 'palette_selectors': selectors, 'metadata': meta}


def enemy_profile(data, table, local_id, stable_id, atlas, by_offset):
    u32 = lambda address: struct.unpack_from('<I', data, address - encounters.BASE)[0]
    address = u32(table + 4 * local_id)
    offset = address - encounters.BASE
    raw = data[offset:offset + 64]
    name, _ = decode(raw, length=16)
    hp, attack, skill, defense, speed = struct.unpack_from('<5H', raw, 18)
    section = by_offset[u32(address + 44) - encounters.BASE]
    poses, animations, art_proof = section_art(data, section['header_offset'], encounters.BASE)
    pose = poses[animations[0][0][0]]
    encoded = struct.unpack_from('<h', raw, 52)[0]
    money = int(encoded / 10) * 100 if encoded & 1 else encoded
    if money < 0:
        raise ValueError('negative trial reward')
    profile = {'id': stable_id, 'name': name, 'max_hp': hp,
                    'level': raw[16], 'money': money,
                    'stats': {'attack': attack, 'defense': defense, 'skill': skill, 'speed': speed},
                    'sprite': pack_pose(atlas, pose), 'attack': []}
    proof = {'id': stable_id, 'local_id': local_id, 'record_offset': offset,
                  'section_offset': section['header_offset'], 'art': art_proof, 'idle_animation': 0}
    return profile, proof


def export(output):
    output = Path(output).resolve()
    if ROOT / 'kit/work/accepted' in (output, *output.parents):
        raise ValueError('battle trial export must not write accepted content')
    output.mkdir(parents=True, exist_ok=True)
    data, provenance = source('/A_DATA.BIN')
    _, _, directory, selectors = encounters.chain(data)
    u32 = lambda address: struct.unpack_from('<I', data, address - encounters.BASE)[0]
    table = u32(directory + 12)
    _, selected = encounters.selectors_table(data, selectors)
    sections, errors = enemy_sprites.parse_sections(data)
    if errors:
        raise ValueError(errors)
    by_offset = {s['header_offset']: s for s in sections}
    atlas = Atlas()
    enemies, proof = [], []
    for local_id, stable_id in ((1, 'bonbon'), (4, 'wild_boar')):
        profile, origin = enemy_profile(data, table, local_id, stable_id, atlas, by_offset)
        enemies.append(profile)
        proof.append(origin)
    party, party_proof = [], []
    sources = [provenance]
    for code, id, name, hp, attack, defense, skill, speed in (
            ('SHU', 'hero', 'Hero', 100, 35, 23, 28, 24),
            ('GRE', 'gremio', 'Gremio', 120, 31, 27, 24, 20)):
        character, origin = source('/' + code + '.BIN')
        sources.append(origin)
        section = struct.unpack_from('<I', character, 0x24)[0]
        poses, animations, art_proof = section_art(character, section)
        neutral = poses[animations[0][0][0]]
        attack_frames, motion = attack_schedule(character, poses, animations, atlas)
        party_proof.append({'id': id, **art_proof, 'idle_animation': 0,
                            'attack_scripts': [1, 4]})
        party.append({'id': id, 'name': name, 'max_hp': hp, 'level': 5,
                      'stats': {'attack': attack, 'defense': defense, 'skill': skill, 'speed': speed},
                      'sprite': pack_pose(atlas, neutral), 'foot_offset_y': foot_offset_y(neutral),
                      'attack': attack_frames, 'motion': motion})
    placements = battle_placement.area_encounters(data)
    runs = []
    for number, title in ((1, 'First contact'), (2, 'Three BonBons'), (5, 'Wild boar')):
        address = selected[number - 1]
        ids = [v for v in data[address - encounters.BASE + 4:address - encounters.BASE + 10] if v]
        if any(v not in (1, 4) for v in ids):
            raise ValueError('unsupported trial roster')
        roster = ['bonbon' if v == 1 else 'wild_boar' for v in ids]
        levels = [next(e['level'] for e in enemies if e['id'] == id) for id in roster]
        award = exp_award.award_pool([5, 5], [0, 0], levels)[1:]
        if award[0] != award[1]:
            raise ValueError('trial experience differs between equal-level members')
        runs.append({'id': f'area_a_{number}', 'title': title, 'enemies': roster,
                     'experience_per_member': award[0],
                     **encounter_music(u32(address+12)),
                     'positions': [world_position(slot['world']) for slot in placements['encounters'][number - 1]['slots']],
                     'source_slots': [slot['slot'] for slot in placements['encounters'][number - 1]['slots']]})
    floor, ground_proof = ground_tiles(data, directory)
    vertices, across, down, tiles = visuals.battle_ground_mesh(data)
    ground, mask = visuals.render_ground(floor, vertices, across, down, tiles, H=visuals.PROJ_H * 0.8, screen_offset=(0, 17))
    background = Image.new('RGB', visuals.SCREEN)
    background.paste(ground, (0, 0), mask)
    background.save(output / 'floor.png')
    floor.save(output / 'ground.png')
    pointer = lambda address: u32(address) - encounters.BASE
    scenery_section = pointer(directory + 4)
    scenery_poses, scenery_clips, scenery_proof = section_art(data, scenery_section, encounters.BASE)
    packed_scenery = [pack_pose(atlas, pose) for pose in scenery_poses]
    records = pointer(directory + 20)
    count = struct.unpack_from('<h', data, records)[0]
    scenery = []
    for i in range(count):
        animation, x, y, z = struct.unpack_from('<4h', data, records + 8 + i * 8)
        pose = scenery_clips[animation][0][0]
        scenery.append({'sprite': packed_scenery[pose], 'position': world_position((x, y, z))})
    atlas.save(output / 'actors.png')
    content = {'schema': 'suikoden-battle-trial/2', 'atlas': 'actors.png', 'background': 'floor.png',
               'party': party, 'enemies': enemies, 'encounters': runs,
               'party_positions': [world_position(p) for p in visuals.party_world_positions()[:2]],
               'formation_slots': [world_position(p) for p in visuals.party_world_positions()],
               'sprite_scale': visuals.battle_scale_q12() / 4096 * 1.6, 'scenery': scenery,
               'ground': {'across': across, 'down': down,
                          'vertices': [world_position(v) for v in vertices], 'tiles': [int(v) for v in tiles]},
               'camera': {'transform': [[v / 4096 for v in visuals.battle_camera()[0][i * 3:i * 3 + 3]] + [visuals.battle_camera()[1][i]] for i in range(3)],
                          'focal_length': visuals.PROJ_H * 1.6, 'center_x': 320, 'center_y': 202}}
    origin = {'schema': 'suikoden-battle-trial-provenance/1', 'sources': sources,
              'exporter': 'export_battle_trial.py v5', 'codec': 'lzss.py v2.0.0 strict',
              'visuals': 'battle descriptors: S1 neutral animation0; attack/return scripts1/4; enemy animation0; native per-tile ground palettes and scenery placements',
              'enemies': proof, 'party': party_proof, 'encounter_indices': [1, 2, 5], 'ground': ground_proof, 'scenery': {**scenery_proof, 'records': records, 'count': count},
              'presentation': {'camera_block': visuals.BATTLE_CAM_BLOCKS[visuals.BATTLE_CAM_STATE],
                               'source_crop': [0, 36, 320, 168], 'scale': 2, 'framing_zoom': 0.8, 'framing_offset_y': 17,
                               'spawn_positions': placements['encounters']},
              'main_source': {'file': 'MAIN.EXE', 'lba': maindec.EXE_LBA, 'size': maindec.EXE_SIZE,
                              'image_sha256': hashlib.sha256(maindec.body()).hexdigest()},
              'port_choices': ['authored trial order, party level5/stats/HP and two Medicine bundles per member',
                               'descriptor-composed source poses and timed party attack/return tracks; sound, flags and inter-actor synchronization are reduced to trial semantics',
                               'fixed camera and cropped scene framing; billboards scale with projected depth during motion as a port presentation policy, not an original sprite-scale claim',
                               'party foot_offset_y is the lowest opaque idle-pose row relative to its source anchor; ground-only ellipses are port presentation, not decoded original shadow geometry',
                               'enemy basic attacks with live party targets; full enemy decision/action scripts deferred',
                               'HP/items, money and earned EXP carry between fights; no field save is read or written; shared field Medicine policy is used for consumption',
                               'money/EXP rewards only; equipment drops, leveling, spells and unite deferred']}
    for name, value in [('trial.json', content), ('provenance.json', origin)]:
        (output / name).write_text(json.dumps(value, indent=2) + '\n')
    review = background.crop((0, 36, 320, 204)).resize((640, 336), Image.Resampling.NEAREST).convert('RGBA')
    entries = [(entry['sprite'], entry['position']) for entry in scenery]
    entries += [(party[i]['sprite'], content['party_positions'][i]) for i in range(2)]
    entries += [(enemies[0]['sprite'], position) for position in runs[1]['positions']]
    entries = [(sprite, screen_position(tuple(position[k] for k in ('x', 'y', 'z')))) for sprite, position in entries]
    for sprite, position in sorted(entries, key=lambda item: -item[1]['depth']):
        rect = sprite['rect']
        pose = atlas.image.crop((rect['x'], rect['y'], rect['x'] + rect['w'], rect['y'] + rect['h']))
        scale = content['sprite_scale']
        pose = pose.resize((round(pose.width * scale), round(pose.height * scale)), Image.Resampling.NEAREST)
        review.alpha_composite(pose, (round(position['x'] - sprite['anchor_x'] * scale),
                                     round(position['y'] - sprite['anchor_y'] * scale)))
    review.convert('RGB').save(output / 'review.png')
    return content


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'kit/work/build/battle_trial')
    args = parser.parse_args()
    result = export(args.out)
    print(f'Exported {len(result["encounters"])} trial battles; candidate art only')
