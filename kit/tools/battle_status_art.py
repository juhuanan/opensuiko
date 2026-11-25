"""Source party status symbols and body-pose attachments for the shared atlas."""
import hashlib
import struct

import battle_bin
import character_table
import export_battle_trial as art
import maindec
import preparation
from export_first_room import source

NAMES = ('poison', 'balloon_one', 'balloon_two', 'balloon_three',
         'accuracy_reduced', 'sleep', 'rune_blocked', 'recovery')


def build():
    selected = []
    for index in range(8):
        target = maindec.mword(0x800C11B4 + 4*index)
        for pc in range(target, target + 64, 4):
            if maindec.mword(pc) != 0x08038189:  # Shared party graphic allocation.
                continue
            word = maindec.mword(pc + 4)
            if word >> 16 != 0x3407:
                raise ValueError('status symbol animation selection changed')
            selected.append(word & 65535)
            break
        else:
            raise ValueError('unresolved status symbol selector')
    if maindec.mword(0x800C11D4) != 0x800E05DC:
        raise ValueError('Copper Flesh mask-only setter changed')
    sections, _, errors, raw = battle_bin.parse()
    if errors:
        raise ValueError(errors)
    section = sections[0]
    if maindec.mword(0x800F2F18) != 0x34050005:
        raise ValueError('Needle balloon burst selector changed')
    poses, animations, details = art.section_art(raw, section['header_offset'], battle_bin.LOAD_BASE,
        animation_indices=selected+[5], selected_poses_only=True, axis_aligned_packet=True)
    images = []; entries = []; mapping = {}
    symbol_poses = {pose for animation in selected for pose, _ in animations[animation]}
    for pose in sorted(symbol_poses) + sorted({pose for pose, _ in animations[5]} - symbol_poses):
        image, ax, ay = poses[pose]
        mapping[pose] = len(entries)
        entries.append(dict(pose=pose, dx=-ax, dy=-ay, w=image.width, h=image.height,
            source_offset=details['poses'][pose], rgba_sha256=hashlib.sha256(image.tobytes()).hexdigest()))
        images.append(image)
    icons = []; clips = []
    for name, animation in zip(NAMES, selected, strict=True):
        offset = details['animations'][animation]
        if raw[offset+1] != 3 or not animations[animation]:
            raise ValueError('status symbol must advance and loop')
        icons.append(dict(status=name, frames=[dict(entry=mapping[pose], ticks=ticks or 256)
            for pose, ticks in animations[animation]]))
        clips.append(dict(status=name, animation=animation, source_offset=offset, flags=3))
    if raw[details['animations'][5]+1] != 1 or animations[5] != [(29,4),(30,6)]:
        raise ValueError('Needle balloon burst animation changed')
    needle = [dict(entry=mapping[pose], ticks=ticks) for pose, ticks in animations[5]]
    anchors = []; actor_sources = []
    for record in character_table.records():
        actor, origin = source('/' + record['sprite_file'])
        section_offset = struct.unpack_from('<I', actor, 36)[0]
        count = struct.unpack_from('<H', actor, section_offset)[0]
        et, ft = struct.unpack_from('<II', actor, section_offset+16)
        offsets = []; source_offsets = []
        for index in range(count):
            offset = struct.unpack_from('<I', actor, et + 4*index)[0]
            if offset + 8 > len(actor):
                raise ValueError('status body attachment outside actor file')
            offsets.append([actor[offset+6]-actor[offset+4], actor[offset+7]-actor[offset+5]])
            source_offsets.append(offset)
        neutral, hurt = [actor[struct.unpack_from('<I', actor, ft + 4*index)[0]+4] for index in (0, 1)]
        if max(neutral, hurt) >= count:
            raise ValueError('status body attachment references absent pose')
        identifier = preparation.stable_id(record['name'])
        anchors.append(dict(id=identifier, idle_pose=neutral, hurt_pose=hurt, offsets=offsets))
        actor_sources.append(dict(id=identifier, source=origin, section=section_offset, poses=source_offsets))
    lba, size = battle_bin.battle_bin_lba()
    proof = dict(producer='battle-status-art/2', source=dict(file=battle_bin.DISC_PATH,
        lba=lba, size=size, sha256=hashlib.sha256(raw).hexdigest(), decoder=battle_bin.DECODER_ID,
        section=section['header_offset']), selectors=clips, entries=entries, actors=actor_sources,
        setter='0x800E04DC', updater='0x800E02CC', attachment='current pose bytes6/7 minus4/5',
        needle_burst=dict(animation=5, source_offset=details['animations'][5], flags=1, frames=[dict(frame) for frame in needle]),
        scope='Eight looping party symbols and the two-frame Needle burst; Copper Flesh and enemy setters do not allocate these symbols. '
              'Axis-aligned packet footprint, independent per-status clocks and current body attachment; candidate media.')
    return dict(icons=icons, anchors=anchors, needle_burst=needle), images, proof
