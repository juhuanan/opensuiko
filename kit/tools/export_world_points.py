"""Export source world-entry identities, activation rectangles and return positions."""
from pathlib import Path
import struct

import maindec
from area_data_select import area_table
from event_script_reachability import loader_file_slots
from export_first_room import source


def bind_river_navigation(room, codes):
    # Region 10's boat predicate checks the rapids before ordinary water.
    anchors = {0x80127040: 0x3402000A, 0x80127080: 0x2482FECE, 0x80127088: 0x2C420008,
               0x80127094: 0x90A20251, 0x8012709C: 0x30420004, 0x801271B0: 0x2A020015,
               0x80126ED0: 0x34420040, 0x80126ED4: 0xA0620251}
    if (room['id'] != 'world_k' or len(codes) != 19200
            or any(maindec.mword(address) != word for address, word in anchors.items())):
        raise ValueError('Region K boat movement contract changed')
    room['boat_walkable'] = ''.join('1' if code < 21 else '2' if 306 <= code <= 313 else '0' for code in codes)
    room['boat_rapids'] = {
        'requires': {'id': 'scenario_0193', 'mask': 4},
        'warned': {'id': 'scenario_0193', 'mask': 64},
        'pages': ['The current is too strong for this boat. Head back to Rikon.'],
    }


def world_points(package):
    rooms = {room['id']: room for room in package['rooms']}
    _, slots, _ = loader_file_slots()
    files = {(slot['region'], slot['index']): slot['file'] for slot in slots if slot.get('file')}
    entries, placements = [], []
    for region in area_table():
        world = 'world_' + Path(region['path']).name.removesuffix('_DATA.BIN').lower()
        if world not in rooms:
            continue
        table = maindec.mword(0x80170064 + 4 * region['index']) - maindec.MBASE
        for point in range(64):
            offset = table + point * 14
            if not 0 <= offset <= len(maindec.body()) - 14:
                raise ValueError('world point table outside MAIN image')
            kind, field_room, x, y, spawn_x, spawn_y = struct.unpack_from('<BBHHBB', maindec.body(), offset)
            if kind == 8:
                break
            filename = files.get((region['index'], point))
            if filename is None:
                continue
            area = Path(filename).stem.lower()
            target = f'{area}_room_{field_room}'
            entry = dict(id=f'{world}_point_{point}', world_room=world, point=point, area=area,
                         return_x=(x + 10) * 8, return_y=(y + 10) * 8)
            if not (entry['return_x'] < rooms[world]['width'] and entry['return_y'] < rooms[world]['height']):
                continue
            entries.append(entry)
            if kind not in (0, 2) or (x == 0 and y == 0) or target not in rooms:
                continue
            spawn_x, spawn_y = spawn_x * 8, spawn_y * 8
            room = rooms[target]
            if not (0 <= spawn_x < room['width'] and 0 <= spawn_y < room['height']):
                raise ValueError('world point spawn outside exported field room')
            exit = dict(x=(x + 10) * 8, y=(y + 8) * 8, w=16, h=16, room=target,
                        spawn_x=spawn_x, spawn_y=spawn_y, world_entry=entry['id'])
            if kind == 2:
                # MAIN 0x80128740 admits this entrance before the overlapping fallback while scenario[17] bit 0 is clear.
                exit['conditions'] = [{'kind': 'story_mask_clear', 'flag': {'id': 'scenario_0017', 'mask': 1}}]
            if room['walkable'][(spawn_y // 8) * (room['width'] // 8) + spawn_x // 8] != '1':
                exit['source_arrival'] = True
            placements.append((world, exit))
        else:
            raise ValueError('world point table has no terminator')
    return entries, placements


def bind_world_points(package):
    entries, placements = world_points(package)
    from room_battle_package import SCENERY_MODEL_SCHEMA, SCENERY_DRAW_SCHEMA, WORLD_ENTRY_SCHEMA
    package['schema'] = SCENERY_DRAW_SCHEMA if any(draw.get('scenery_object') is not None for room in package['rooms'] for draw in room.get('draws', [])) else SCENERY_MODEL_SCHEMA if any(room.get('scenery_model') is not None for room in package['rooms']) else WORLD_ENTRY_SCHEMA
    package['world_entries'] = entries
    _, slots, _ = loader_file_slots()
    areas = {Path(slot['file']).stem.lower() for slot in slots if slot.get('file')}
    for room in package['rooms']:
        area = room['id'].split('_room_', 1)[0]
        if area in areas:
            room['source_area'] = area
        if any(entry['world_room'] == room['id'] for entry in entries):
            room['exits'] = [exit for world, exit in placements if world == room['id']]
    raw, _ = source('SLUS_002.92')
    base, size = struct.unpack_from('<II', raw, 24)
    if base != 0x80010000:
        raise ValueError('unexpected boot image base')
    image = raw[2048:2048 + size]
    point, _, region = image[0x32FE0:0x32FE3]
    world = next(row for row in area_table() if row['index'] == region)
    identifier = 'world_' + Path(world['path']).name.removesuffix('_DATA.BIN').lower() + f'_point_{point}'
    start = next(room for room in package['rooms'] if room['id'] == package['start_room'])
    package['initial_world_entry'] = next((entry['id'] for entry in entries
                                            if entry['id'] == identifier and entry['area'] == start.get('source_area')), None)
