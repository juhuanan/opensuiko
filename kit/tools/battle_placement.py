#!/usr/bin/env python3
"""List standard battle spawn positions from disc pointers, never shape scans.

MAIN.EXE: party writer 800DEBE8; enemy writer 800DEE44.
Area DATA base: 80080000. No projection or media generation.
"""
import argparse
import json
from pathlib import Path
import struct

from disc import extract

KIT = Path(__file__).resolve().parents[1]
AREA_BASE = 0x80080000


def read_file(name, image=None):
    records = json.loads((KIT / 'extracted/iso_files.json').read_text())
    record = next(r for r in records if r['path'] == name)
    return extract(record['lba'], record['size'], image), record


def word(data, offset):
    if not 0 <= offset <= len(data) - 4:
        raise ValueError(f'word outside area file: {offset:#x}')
    return struct.unpack_from('<I', data, offset)[0]


def pointer(data, offset, base):
    value = word(data, offset) - base
    if not 0 <= value < len(data):
        raise ValueError(f'pointer at {offset:#x} outside area file')
    return value


def scripted_directory(data, section, selector, base):
    """Opcode47's ordinary selector follows the section's character contexts."""
    if not 0 <= selector < 0xFE:
        raise ValueError('special forced-battle selector requires its own mode handler')
    count = word(data, section + 0x1C)
    if count > 255:
        raise ValueError('invalid section character context count')
    table = pointer(data, section + 0x20, base)
    return pointer(data, table + 4 * (count + selector), base)


def directory_encounters(data, directory, base):
    selectors = pointer(data, directory + 8, base)
    count = word(data, selectors)
    if not 1 <= count <= 255:
        raise ValueError(f'invalid encounter count: {count}')
    result = []
    for index in range(1, count + 1):
        encounter = pointer(data, selectors + 4 * index, base)
        auxiliary = pointer(data, encounter + 0x14, base)
        positions = pointer(data, auxiliary, base)
        roster = list(data[encounter + 4:encounter + 10])
        if len(roster) != 6 or sum(bool(x) for x in roster) != word(data, encounter):
            raise ValueError(f'encounter {index}: count disagrees with roster')
        slots = []
        for slot, enemy_id in enumerate(roster):
            if not enemy_id:
                continue
            triple = struct.unpack_from('<3h', data, positions + 6 * slot)
            stats = pointer(data, pointer(data, directory + 0x0c, base) + 4 * enemy_id, base)
            flags = struct.unpack_from('<H', data, stats + 0x26)[0]
            # 800DF054..064 subtracts ten Q12 units for flag 0x20.
            world = (triple[0] - 128, triple[1], triple[2] - (10 if flags & 0x20 else 0))
            slots.append(dict(slot=slot, enemy_id=enemy_id, triple=triple,
                              world=world, world_q12=[x << 12 for x in world],
                              stats_offset=stats, flags=flags))
        result.append(dict(index=index, descriptor_offset=encounter,
                           auxiliary_offset=auxiliary, positions_offset=positions,
                           roster=roster, slots=slots))
    return selectors, result


def directory_battlefield(data, directory, base):
    """Identify the source ground resources and optional scenery for one directory."""
    section = pointer(data, directory, base)
    across, down, pages, palettes = struct.unpack_from('<2H2B', data, section)
    if not (1 <= across <= 64 and 1 <= down <= 64 and pages and palettes):
        raise ValueError(f'invalid battlefield ground header at {section:#x}')

    page_table = pointer(data, section + 8, base)
    palette_table = pointer(data, section + 12, base)
    selector_table = pointer(data, section + 16, base)
    tile_map = pointer(data, section + 20, base)
    height_map = pointer(data, directory + 16, base)
    tile_codes = set(struct.unpack_from(f'<{across * down}H', data, tile_map))
    heights = struct.unpack_from(f'<{(across + 1) * (down + 1)}h', data, height_map)
    page_offsets = [pointer(data, page_table + 4 * i, base) for i in range(pages)]
    palette_slots = range(palette_table, palette_table + 4 * palettes, 4)
    palette_offsets = [pointer(data, offset, base) if word(data, offset) else None for offset in palette_slots]
    selector_offsets = [pointer(data, selector_table + 4 * i, base) for i in range(pages)]
    if (max(tile_codes) >= 16 * pages or any(offset + 16 > len(data) for offset in selector_offsets)
        or any(offset is not None and offset + 512 > len(data) for offset in palette_offsets)):
        raise ValueError(f'invalid battlefield tile or palette table at {section:#x}')
    used_palettes = sorted({data[selector_offsets[code >> 4] + (code & 15)] for code in tile_codes})
    if used_palettes[-1] >= palettes:
        raise ValueError(f'used battlefield palette outside table at {section:#x}')
    if any(palette_offsets[index] is None for index in used_palettes):
        raise ValueError(f'used battlefield palette is missing at {section:#x}')

    ground = dict(section_offset=section, across=across, down=down, page_offsets=page_offsets,
                  palette_offsets=palette_offsets, tile_palette_offsets=selector_offsets,
                  used_palettes=used_palettes, tile_map_offset=tile_map,
                  height_map_offset=height_map, height_range=[min(heights), max(heights)])
    scenery = None
    if word(data, directory + 4):
        scenery_section = pointer(data, directory + 4, base)
        records = pointer(data, directory + 20, base)
        count, = struct.unpack_from('<h', data, records)
        if count < 0 or records + 8 + count * 8 > len(data):
            raise ValueError(f'invalid battlefield scenery list at {records:#x}')
        placements = []
        for i in range(count):
            descriptor, x, y, z = struct.unpack_from('<4h', data, records + 8 + i * 8)
            placements.append(dict(descriptor=descriptor, world=[x, y, z]))
        scenery = dict(section_offset=scenery_section, records_offset=records, placements=placements)
    return dict(ground=ground, scenery=scenery)


def area_encounters(data):
    descriptor = pointer(data, 0, AREA_BASE)
    resources = pointer(data, descriptor + 0x0c, AREA_BASE)
    directory = pointer(data, resources, AREA_BASE)
    selectors, result = directory_encounters(data, directory, AREA_BASE)
    return dict(area_descriptor_offset=descriptor, resources_offset=resources,
                directory_offset=directory, selectors_offset=selectors,
                encounters=result)


def party_positions(raw):
    if raw[:8] != b'PS-X EXE':
        raise ValueError('MAIN.EXE lacks PS-X EXE header')
    base, size = struct.unpack_from('<II', raw, 0x18)
    image = raw[2048:2048 + size]
    if len(image) != size:
        raise ValueError('short MAIN.EXE image')
    origin = struct.unpack_from('<2i', image, 0x8016b80c - base)
    result = []
    for actor in range(1, 7):
        triple = struct.unpack_from('<3h', image, 0x8016b81c - base + actor * 6)
        world = (triple[0] + origin[0], triple[1] + origin[1], triple[2])
        result.append(dict(actor=actor, triple=triple, world=world,
                           world_q12=[x << 12 for x in world]))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--area', default='DATA/08_AREA.E/E_DATA.BIN')
    args = parser.parse_args()
    area, provenance = read_file(args.area)
    main, main_provenance = read_file('MAIN.EXE')
    print(json.dumps(dict(method='battle_placement/1: little-endian pointer chase',
                          area=provenance, main=main_provenance,
                          party=party_positions(main), enemies=area_encounters(area)),
                     indent=2))
