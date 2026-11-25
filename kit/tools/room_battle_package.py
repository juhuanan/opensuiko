"""Read and install room event packets shared by Journey's Python tools."""

import argparse
import filecmp
import hashlib
import json
import re
from collections import Counter
from pathlib import Path
from shutil import copyfile

PATH = 'battle/field_events.json'
SOUND_MANIFEST = 'audio/sfx/battle_sfx.json'
MAX_BYTES = 64 * 1024 * 1024
CURRENT_SCHEMA = 'suikoden-battle-field-events'
SCHEMAS = (*tuple(f'{CURRENT_SCHEMA}/{version}' for version in range(1, 53)), CURRENT_SCHEMA)
ROOM_CONDITIONS_SCHEMA = 'suikoden-room/12'
SCENERY_CONDITIONS_SCHEMA = 'suikoden-room/13'
PROP_SCHEMA = 'suikoden-room/14'
WHEEL_MAP_SCHEMA = 'suikoden-room/15'
WORLD_ENTRY_SCHEMA = 'suikoden-room/16'
SCENERY_MODEL_SCHEMA = 'suikoden-room/17'
SCENERY_DRAW_SCHEMA = 'suikoden-room/18'
SCENERY_MODEL_SCHEMAS = (SCENERY_MODEL_SCHEMA, SCENERY_DRAW_SCHEMA)
WORLD_ENTRY_SCHEMAS = (WORLD_ENTRY_SCHEMA, *SCENERY_MODEL_SCHEMAS)
SCENERY_SCHEMAS = ('suikoden-room/11', ROOM_CONDITIONS_SCHEMA, SCENERY_CONDITIONS_SCHEMA, PROP_SCHEMA, WHEEL_MAP_SCHEMA, WORLD_ENTRY_SCHEMA, SCENERY_MODEL_SCHEMA, SCENERY_DRAW_SCHEMA)
WAR_SCENARIO_IDS = (
    'pannu_yakuta',
    'garan',
    'scarleticia_pollen',
    'scarleticia_antidote',
    'teo_before_fire_spear',
    'teo_fire_spear',
    'northern_checkpoint',
    'shasarazade',
    'gregminster',
)
DUEL_IDS = ('pahn_teo', 'shu_kwanda', 'shu_teo')
ENDING_IDS = ('main',)


def validate_world_entries(package):
    rooms = {room['id']: room for room in package['rooms']}
    entries = object_rows(package.get('world_entries', []), 'world entries')
    enabled = package.get('schema') in WORLD_ENTRY_SCHEMAS
    if len(entries) > 2048 or (not enabled and (entries or package.get('initial_world_entry') is not None)):
        raise ValueError('world entries require room16')
    by_id, points = {}, set()
    for entry in entries:
        if (set(entry) != {'id', 'world_room', 'point', 'area', 'return_x', 'return_y'}
                or any(not isinstance(entry[key], str) or not 1 <= len(entry[key]) <= 96 for key in ('id', 'world_room', 'area'))
                or type(entry['point']) is not int or not 0 <= entry['point'] <= 255
                or entry['id'] in by_id or (entry['world_room'], entry['point']) in points):
            raise ValueError('invalid or duplicate world entry')
        target = rooms.get(entry['world_room'])
        if target is None or any(type(entry[key]) is not int or entry[key] < 0 or entry[key] % 8 or entry[key] >= target[axis]
                                 for key, axis in (('return_x', 'width'), ('return_y', 'height'))):
            raise ValueError('invalid world entry return position')
        by_id[entry['id']] = entry
        points.add((entry['world_room'], entry['point']))
    if package.get('initial_world_entry') is not None and package['initial_world_entry'] not in by_id:
        raise ValueError('unknown initial world entry')
    for room in rooms.values():
        if room.get('source_area') is not None and (not enabled or not isinstance(room['source_area'], str) or not 1 <= len(room['source_area']) <= 64):
            raise ValueError('invalid field source area')
        for exit in room.get('exits', []):
            if type(exit.get('source_arrival', False)) is not bool or (exit.get('source_arrival') and not enabled):
                raise ValueError('source exit arrival requires room16')
            if exit.get('world_entry') is not None:
                entry = by_id.get(exit['world_entry'])
                target = rooms.get(exit.get('room'))
                if entry is None or target is None or entry['world_room'] != room['id'] or entry['area'] != target.get('source_area'):
                    raise ValueError('invalid world entry exit binding')


def validate_room_scenery(room, schema):
    model = room.get('scenery_model')
    links = [draw.get('scenery_object') for draw in room.get('draws', []) if draw.get('scenery_object') is not None]
    if model is None:
        if links:
            raise ValueError('scenery draw requires a scenery model')
        return
    from field_scenery import validate_model
    if schema not in SCENERY_MODEL_SCHEMAS:
        raise ValueError('field scenery model requires room17')
    validate_model(model)
    if model['columns'] * 8 != room.get('width') or model['rows'] * 8 != room.get('height'):
        raise ValueError('field scenery model does not match room dimensions')
    if links and (schema != SCENERY_DRAW_SCHEMA or any(type(index) is not int or not 0 <= index < len(model['objects']) for index in links)):
        raise ValueError('scenery draw requires room18 and a defined scenery object')
    if any(draw.get('scenery_object') is not None and draw.get('prop') is not None for draw in room.get('draws', [])):
        raise ValueError('scenery draw cannot also be a prop')


def validate_wheel_map(room, schema):
    index = room.get('wheel_map')
    if index is None:
        return
    draws = room.get('draws', [])
    if (schema not in (WHEEL_MAP_SCHEMA, WORLD_ENTRY_SCHEMA, SCENERY_MODEL_SCHEMA, SCENERY_DRAW_SCHEMA) or type(index) is not int or not 0 <= index < min(4096, len(draws))
            or room.get('width', 0) < 320 or room.get('height', 0) < 240 or not valid_scenery_path(room.get('scenery_atlas'))):
        raise ValueError('wheel map requires room15, a full source viewport and a scenery draw')
    draw = draws[index]
    rect = draw.get('rect', {})
    if (draw.get('x', 0) != 0 or draw.get('y', 0) != 0 or draw.get('frames', [])
            or any(draw.get(key) is not None for key in ('prop', 'hidden_by', 'room_conditions'))
            or any(type(rect.get(axis)) is not int or not 0 < rect[axis] <= 4096 or rect[axis] % 16 for axis in ('w', 'h'))):
        raise ValueError('wheel map must be a stationary unguarded tile-aligned map draw')


def valid_scenery_path(path) -> bool:
    return isinstance(path, str) and re.fullmatch(r'field/[A-Za-z0-9_-]{1,64}\.png', path) is not None


def object_rows(value, name):
    if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
        raise ValueError(f'expected an array of objects for {name}')
    return value


def validate_room_queues(packet):
    if (not isinstance(packet, dict) or packet.get('schema') != 'suikoden-field-party-queue/2'
            or not isinstance(packet.get('content_sha256'), str)
            or re.fullmatch('[0-9a-f]{64}', packet['content_sha256']) is None):
        raise ValueError('invalid room party queue schema or identity')
    anchor = packet.get('anchor')
    if (not isinstance(anchor, dict) or set(anchor) != {'x', 'y'}
            or any(type(value) is not int or not 24 <= value <= 2016 or value % 8 for value in anchor.values())):
        raise ValueError('invalid room party anchor')
    tracks = object_rows(packet.get('tracks'), 'party queue tracks')
    if len(tracks) != 40:
        raise ValueError('party queue needs four facings of five spread and return tracks')
    for track in tracks:
        commands = object_rows(track.get('commands'), 'party queue commands')
        if not 1 <= len(commands) <= 64 or commands[-1] != {'kind': 'finish'}:
            raise ValueError('invalid party queue end')
        x = y = 0
        for command in commands[:-1]:
            if (set(command) != {'kind', 'direction', 'cells'} or command['kind'] != 'move'
                    or command['direction'] not in ('up', 'right', 'down', 'left')
                    or type(command['cells']) is not int or not 0 <= command['cells'] <= 3):
                raise ValueError('invalid party formation step')
            dx, dy = {'up': (0, -1), 'right': (1, 0), 'down': (0, 1), 'left': (-1, 0)}[command['direction']]
            x += dx * command['cells'] * 8
            y += dy * command['cells'] * 8
            if abs(x) > 24 or abs(y) > 24:
                raise ValueError('party formation exceeds its anchor bounds')


def validate_party_art(actors, atlas_size, *, expanded=False):
    if not 1 <= len(actors) <= (255 if expanded else 5):
        raise ValueError('room party art exceeds the admitted character library')
    characters, names = set(), set()
    for actor in actors:
        character, name = actor.get('character'), actor.get('id')
        if (type(character) is not int or not 0 <= character < 255 or character in characters
                or not isinstance(name, str) or re.fullmatch('[A-Za-z0-9_]{1,64}', name) is None or name in names):
            raise ValueError('invalid room party art identity')
        characters.add(character)
        names.add(name)
        validate_field_clips(actor.get('clips'), atlas_size)


def validate_field_clips(clips, atlas_size):
    clips = object_rows(clips, 'field clips')
    if len(clips) != 4:
        raise ValueError('party art needs four directional clips')
    for clip, direction in zip(clips, ('down', 'up', 'left', 'right')):
        frames = object_rows(clip.get('frames'), 'party frames')
        if (clip.get('direction') != direction or clip.get('idle_frame') != 1 or len(frames) != 4
                or type(clip.get('flags', 3)) is not int or not 0 <= clip.get('flags', 3) <= 3):
            raise ValueError('invalid room party animation')
        for frame in frames:
            rect = frame.get('rect')
            if (not isinstance(rect, dict) or any(type(rect.get(key)) is not int for key in ('x', 'y', 'w', 'h'))
                    or min(rect['x'], rect['y']) < 0 or not 1 <= rect['w'] <= 128 or not 1 <= rect['h'] <= 128
                    or type(frame.get('ticks')) is not int or not 1 <= frame['ticks'] <= 256
                    or any(type(frame.get(key)) is not int or not 0 <= frame[key] <= rect[extent]
                           for key, extent in (('anchor_x', 'w'), ('anchor_y', 'h')))):
                raise ValueError('invalid room party frame')
            width, height = atlas_size or (4096, 4096)
            if rect['x'] + rect['w'] > width or rect['y'] + rect['h'] > height:
                raise ValueError('room party frame is outside the atlas')

def bind_field_rooms(candidate: Path, source: Path) -> str:
    """Install authored room rows and their scenery into an unpublished package."""
    room_limit = 64 * 1024 * 1024
    source_rooms = source / 'room.json'
    if source_rooms.is_symlink():
        raise ValueError('field room input cannot be a symlink')
    with source_rooms.open('rb') as stream:
        raw = stream.read(room_limit + 1)
    if len(raw) > room_limit:
        raise ValueError('field room input exceeds the 64 MiB runtime limit')
    fragment = json.loads(raw)
    if (not isinstance(fragment, dict) or set(fragment) != {'schema', 'rooms'}
            or fragment['schema'] not in (SCENERY_CONDITIONS_SCHEMA, PROP_SCHEMA, WHEEL_MAP_SCHEMA, WORLD_ENTRY_SCHEMA, SCENERY_MODEL_SCHEMA, SCENERY_DRAW_SCHEMA)):
        raise ValueError('field room input must contain schema suikoden-room/13,14 or15 and room rows')
    rows = object_rows(fragment['rooms'], 'authored field rooms')
    if not rows:
        raise ValueError('field room input must contain at least one room')

    path = candidate / 'room.json'
    if path.is_symlink():
        raise ValueError('candidate room table cannot be a symlink')
    package = json.loads(path.read_bytes())
    rooms = {room['id']: room for room in package['rooms']}
    previous_scenery = {room['scenery_atlas'] for room in rooms.values() if valid_scenery_path(room.get('scenery_atlas'))}
    seen = set()
    scenery = set()
    for room in rows:
        name = room.get('id')
        if not isinstance(name, str) or not name or name in seen:
            raise ValueError(f'invalid or duplicate field room ID {name!r}')
        seen.add(name)
        if (art := room.get('scenery_atlas')) is not None:
            if not valid_scenery_path(art):
                raise ValueError(f'invalid scenery atlas for field room {name!r}')
            scenery.add(art)
        validate_room_scenery(room, fragment['schema'])
        validate_wheel_map(room, fragment['schema'])
        rooms[name] = room

    package.update(schema=SCENERY_DRAW_SCHEMA if SCENERY_DRAW_SCHEMA in (package['schema'], fragment['schema']) else SCENERY_MODEL_SCHEMA if SCENERY_MODEL_SCHEMA in (package['schema'], fragment['schema']) else WORLD_ENTRY_SCHEMA if WORLD_ENTRY_SCHEMA in (package['schema'], fragment['schema']) else WHEEL_MAP_SCHEMA if WHEEL_MAP_SCHEMA in (package['schema'], fragment['schema']) else PROP_SCHEMA if PROP_SCHEMA in (package['schema'], fragment['schema']) else SCENERY_CONDITIONS_SCHEMA, rooms=list(rooms.values()))
    payload = (json.dumps(package, indent=2) + '\n').encode()
    if len(rooms) > 2048 or len(payload) > room_limit:
        raise ValueError('combined field rooms exceed the runtime package limits')
    retired = previous_scenery - {room.get('scenery_atlas') for room in rooms.values()}
    if (scenery or retired) and any((root / 'field').is_symlink() for root in (source, candidate)):
        raise ValueError('field scenery directory cannot be a symlink')
    for art in sorted(scenery):
        image, target = source / art, candidate / art
        if image.is_symlink() or not image.is_file():
            raise ValueError(f'missing regular field scenery file {art}')
        if target.is_symlink() or (target.exists() and not filecmp.cmp(image, target, shallow=False)):
            raise ValueError(f'conflicting field scenery file {art}')
    for art in sorted(scenery):
        target = candidate / art
        if not target.exists():
            target.parent.mkdir(exist_ok=True)
            copyfile(source / art, target)
    path.write_bytes(payload)
    for art in sorted(retired):
        (candidate / art).unlink(missing_ok=True)
    return hashlib.sha256(raw).hexdigest()


def combine_room_events(sources: list[Path]) -> bytes:
    """Combine room packets before checking their links against the full candidate."""
    def unique_fields(pairs):
        fields = dict(pairs)
        if len(fields) != len(pairs):
            raise ValueError('duplicate JSON field')
        return fields

    merged = {}
    room_ids = set()
    arrays = ('rooms', 'opening_battles', 'opening_world_exits')
    singletons = ('opening_route', 'opening_world_exit')
    for source in sources:
        with source.open('rb') as stream:
            raw = stream.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise ValueError(f'{source}: room event packet exceeds 16 MiB')
        if len(sources) == 1:
            return raw
        try:
            packet = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_fields)
        except (ValueError, RecursionError) as error:
            raise ValueError(f'{source}: {error}') from error
        if (not isinstance(packet, dict) or packet.get('schema') not in SCHEMAS
                or set(packet) - {'schema', *arrays, *singletons}):
            raise ValueError(f'{source}: invalid room event packet')
        if merged.setdefault('schema', packet['schema']) != packet['schema']:
            if {merged['schema'], packet['schema']} <= set(SCHEMAS[17:]):
                merged['schema'] = max((merged['schema'], packet['schema']), key=SCHEMAS.index)
            else:
                raise ValueError(f'{source}: room event packets must use the same schema')
        for room in object_rows(packet.get('rooms'), 'rooms'):
            name = room.get('room')
            if not isinstance(name, str) or not name:
                raise ValueError(f'{source}: missing room ID')
            if name in room_ids:
                raise ValueError(f'{source}: duplicate room {name!r} in supplied packets')
            room_ids.add(name)
        for key in arrays:
            if key in packet:
                merged.setdefault(key, []).extend(object_rows(packet[key], key))
        for key in singletons:
            if packet.get(key) is not None and merged.setdefault(key, packet[key]) != packet[key]:
                raise ValueError(f'{source}: conflicting room event metadata {key!r}')
    if not room_ids:
        raise ValueError('room event packets must contain at least one room binding')
    payload = (json.dumps(merged, separators=(',', ':')) + '\n').encode()
    if len(payload) > MAX_BYTES:
        raise ValueError('combined room event packet exceeds 16 MiB')
    return payload


def bind_room_events(candidate: Path, sources: list[Path]) -> str:
    """Install combined room events in an unpublished package."""
    payload = combine_room_events(sources)
    (candidate / PATH).write_bytes(payload)
    return hashlib.sha256(payload).hexdigest()


def room_battle_requests(root: Path, room_ids: set[str], encounter_ids: set[str],
                         *, atlas_size: tuple[int, int] | None = None) -> list[dict]:
    requests, _ = read_room_events(root, room_ids, encounter_ids, atlas_size=atlas_size)
    return requests


def read_room_events(root: Path, room_ids: set[str], encounter_ids: set[str],
                     *, atlas_size: tuple[int, int] | None = None) -> tuple[list[dict], bool]:
    """Check the room, owner, program and encounter links. Zig validates playback."""
    try:
        with (root / PATH).open('rb') as source:
            data = source.read(MAX_BYTES + 1)
    except FileNotFoundError:
        return [], False
    except OSError as error:
        raise ValueError(f'{PATH}: {error.strerror}') from error
    try:
        return _read_room_events(data, room_ids, encounter_ids, atlas_size, root)
    except (ValueError, OSError, RecursionError) as error:
        raise ValueError(f'{PATH}: {error}') from error


def _read_room_events(data, room_ids, encounter_ids, atlas_size, root):
    if len(data) > MAX_BYTES:
        raise ValueError('file exceeds 4 MiB')
    packet = json.loads(data.decode('utf-8'))
    if not isinstance(packet, dict) or packet.get('schema') not in SCHEMAS:
        raise ValueError('unsupported room battle schema')
    schema = packet['schema']
    rooms = object_rows(packet.get('rooms'), 'rooms')
    if any(binding.get('content', {}).get('schema') in ('suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') for binding in rooms) and schema not in SCHEMAS[49:]:
        raise ValueError('conditional actor owners require packet50')
    if any(binding.get('content', {}).get('schema') in ('suikoden-event-ir/28', 'suikoden-event-ir/29') for binding in rooms) and schema not in SCHEMAS[50:]:
        raise ValueError('camera pushes require packet51')
    if any(binding.get('content', {}).get('schema') == 'suikoden-event-ir/29' for binding in rooms) and schema not in SCHEMAS[51:]:
        raise ValueError('scenery mutations require packet52')
    if not rooms:
        raise ValueError('rooms must contain at least one binding')
    world_package = None
    if any(command.get('return_to_entry') or command.get('retain_world_region') or command.get('world_point') is not None or command.get('world_entry') is not None for binding in rooms for program in binding.get('content', {}).get('programs', []) for command in program.get('commands', [])):
        if schema not in SCHEMAS[48:]:
            raise ValueError('world entries require packet49')
        world_package = json.loads((root / 'room.json').read_bytes()) if root is not None else {}
        if world_package.get('schema') not in WORLD_ENTRY_SCHEMAS:
            raise ValueError('world entries require room16')
        validate_world_entries(world_package)
    if schema not in SCHEMAS[42:] and any(command.get('kind') in ('party_gain_experience', 'party_lose_experience') for room in rooms for program in room.get('content', {}).get('programs', []) for command in program.get('commands', [])):
        raise ValueError('party experience requires packet43')
    route = packet.get('opening_route')
    if route is not None:
        checkpoints = {'dungeon', 'palace', 'first_town'}
        if (schema not in SCHEMAS[12:] or not isinstance(route, dict)
                or set(route) != checkpoints | {'initial_party'}
                or any(not isinstance(route[key], str) or route[key] not in room_ids for key in checkpoints)):
            raise ValueError('invalid opening route checkpoints')
        members = route['initial_party']
        if (not isinstance(members, list) or len(members) > 6
                or any(not isinstance(member, str) or not member for member in members)
                or len(set(members)) != len(members)):
            raise ValueError('invalid opening party requirements')
    world_exit = packet.get('opening_world_exit')
    world_exits = object_rows(packet.get('opening_world_exits', []), 'opening world exits')
    if world_exit is not None and (schema not in SCHEMAS[6:] or world_exits or not isinstance(world_exit, dict)):
        raise ValueError('invalid opening world exit')
    if world_exits and schema not in SCHEMAS[7:]:
        raise ValueError('opening world exits require room battle schema 8 or later')
    if world_exit is not None:
        world_exits = [world_exit]
    if any(set(ref) != {'room', 'program'} or not all(isinstance(value, str) and value for value in ref.values())
           for ref in world_exits):
        raise ValueError('invalid opening world exit')
    if len({(ref['room'], ref['program']) for ref in world_exits}) != len(world_exits):
        raise ValueError('duplicate opening world exit')
    opening_battles = object_rows(packet.get('opening_battles', []), 'opening battles')
    if opening_battles and (schema not in SCHEMAS[6:] or any(
            set(ref) != {'room', 'program'} or not all(isinstance(value, str) and value for value in ref.values())
            for ref in opening_battles)):
        raise ValueError('invalid opening battle reference')
    requests = []
    sound_ids = set()
    seen = set()
    for binding in rooms:
        room = binding.get('room')
        if not isinstance(room, str) or room not in room_ids:
            raise ValueError(f'unknown room {room!r}')
        if room in seen:
            raise ValueError(f'duplicate room {room!r}')
        seen.add(room)
        if schema != CURRENT_SCHEMA and any(
                'if_actor_constructed' in command
                for program in binding.get('content', {}).get('programs', []) for command in program.get('commands', [])):
            raise ValueError('constructor guards require the current field-event format')
        if schema != CURRENT_SCHEMA and any(
                'facility' in command
                for program in binding.get('content', {}).get('programs', []) for command in program.get('commands', [])):
            raise ValueError('named services require the current field-event format')
        if schema != CURRENT_SCHEMA and any(
                command.get('kind') == 'branch_party'
                for program in binding.get('content', {}).get('programs', []) for command in program.get('commands', [])):
            raise ValueError('party branches require the current field-event format')
        if binding.get('queues') is not None:
            if schema not in SCHEMAS[22:]:
                raise ValueError('room party queues require room battle schema 23')
            validate_room_queues(binding['queues'])
        party_art = object_rows(binding.get('party_actors', []), 'room party art')
        if party_art:
            if schema not in SCHEMAS[23:] or binding.get('queues') is None:
                raise ValueError('room party art requires packet24 and room-owned queues')
            validate_party_art(party_art, atlas_size, expanded=schema in SCHEMAS[41:])
        if schema not in SCHEMAS[40:] and any(command.get('kind') == 'field_music' and command.get('music') == 'area_b' for program in binding.get('content', {}).get('programs', []) for command in program.get('commands', [])):
            raise ValueError('ordinary World B music requires packet41')
        if schema not in SCHEMAS[38:] and any(command.get('kind') == 'fade_in' for program in binding.get('content', {}).get('programs', []) for command in program.get('commands', [])):
            raise ValueError('fade-in requires packet39')
        prop_commands = [command for program in binding.get('content', {}).get('programs', [])
                         for command in program.get('commands', []) if command.get('kind') == 'show_prop']
        if prop_commands:
            room_package = json.loads((root / 'room.json').read_bytes())
            draws = next(row['draws'] for row in room_package['rooms'] if row['id'] == room)
            if schema not in SCHEMAS[39:] or room_package.get('schema') not in (PROP_SCHEMA, WHEEL_MAP_SCHEMA, WORLD_ENTRY_SCHEMA, SCENERY_MODEL_SCHEMA, SCENERY_DRAW_SCHEMA) or any(not any(draw.get('prop') == command.get('prop') for draw in draws) for command in prop_commands):
                raise ValueError('scenery prop requires packet40 and a defined room prop')
        dialogue = binding.get('dialogue')
        if isinstance(dialogue, dict) and dialogue.get('schema') == 'suikoden-field-dialogue/10':
            if schema not in SCHEMAS[49:] or binding.get('content', {}).get('schema') not in ('suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29'):
                raise ValueError('interaction dialogue requires packet50 and IR27')
            owner_programs = {program['id']: program for program in binding['content']['programs']}
            for anchor in object_rows(dialogue.get('anchors'), 'interaction dialogue anchors'):
                if anchor.get('interaction_actor') is None:
                    continue
                program = owner_programs.get(anchor.get('program'), {})
                index = anchor.get('command')
                commands = program.get('commands', [])
                if (anchor['interaction_actor'] is not True or not (program.get('owner_actors') or program.get('owner_actor'))
                        or type(index) is not int or not 0 <= index < len(commands)
                        or commands[index].get('kind') != 'open_box' or commands[index].get('box') != anchor.get('box')
                        or any(anchor.get(key) is not None for key in ('point', 'actor', 'follower'))):
                    raise ValueError('invalid interaction dialogue anchor')
        if isinstance(dialogue, dict) and dialogue.get('schema') in ('suikoden-field-dialogue/9', 'suikoden-field-dialogue/10'):
            follower_bindings = (bool(dialogue.get('descriptor_changes'))
                                 or any(anchor.get('follower') is not None for anchor in object_rows(dialogue.get('anchors'), 'dialogue anchors')))
            if ((binding.get('queues') is None and (schema not in SCHEMAS[31:] or follower_bindings))
                    or binding.get('content', {}).get('schema') not in ('suikoden-event-ir/7', 'suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')):
                raise ValueError('party dialogue requires event IR7 and room-owned queues')
            for anchor in object_rows(dialogue.get('anchors'), 'party dialogue anchors'):
                follower = anchor.get('follower')
                if follower is not None and (type(follower) is not int or not 0 <= follower < 5):
                    raise ValueError('invalid party dialogue follower')
        if schema == SCHEMAS[0] and dialogue is not None:
            raise ValueError(f'{room}: dialogue requires room battle schema 2 or later')
        try:
            blend = binding.get('field_effect_blend')
            render_content = binding.get('content')
            if blend is not None and (schema not in SCHEMAS[35:] or blend != 'half' or not isinstance(render_content, dict) or render_content.get('schema') not in ('suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')):
                raise ValueError('field effect rendering requires packet36 and an explicit supported blend')
            actors = object_rows(binding.get('actors', []), 'room actors')
            if actors and (schema not in SCHEMAS[17:] or len(actors) > 64):
                raise ValueError('room actors require schema 18 and at most 64 entries')
            for actor in actors:
                if actor.get('speed') is not None and (schema not in SCHEMAS[37:] or type(actor['speed']) is not int or actor['speed'] not in (0, 1)):
                    raise ValueError('resident motion requires packet38 and speed0/1')
                scene_actor = actor.get('scene_actor')
                if scene_actor is not None:
                    if (schema not in SCHEMAS[37:] or binding.get('content', {}).get('schema') not in ('suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                            or not isinstance(scene_actor, dict) or set(scene_actor) != {'character', 'x', 'y'}
                            or type(scene_actor.get('character')) is not int or not 1 <= scene_actor['character'] <= 254
                            or any(type(scene_actor.get(axis)) is not int or not 0 <= scene_actor[axis] <= 2040 or scene_actor[axis] % 8 for axis in ('x', 'y'))
                            or actor.get('clips') is None or actor.get('entry_placement') is not None or actor.get('required_party_graphic') is not None):
                        raise ValueError('invalid scene-owned actor; requires packet38/IR16')
                required = actor.get('required_party_graphic')
                if required is not None:
                    actor_population = binding.get('population')
                    if not isinstance(actor_population, dict):
                        raise ValueError('invalid party graphics population')
                    entities = object_rows(actor_population.get('entities'), 'population entities')
                    entity_index = actor.get('entity')
                    if (schema not in SCHEMAS[34:] or type(required) is not int or not 1 <= required <= 254 or actor.get('clips') is None
                            or type(entity_index) is not int or not 0 <= entity_index < len(entities)
                            or entities[entity_index].get('source_character_id') != required
                            or entities[entity_index].get('resource_domain') != 'area_character_context'):
                        raise ValueError('invalid party graphics resource; requires packet35')
                placement = actor.get('entry_placement')
                if placement is not None:
                    if (schema not in SCHEMAS[31:] or actor.get('clips') is None or not isinstance(placement, dict)
                            or set(placement) != {'conditions', 'x', 'y'}
                            or any(type(placement[axis]) is not int or not 0 <= placement[axis] <= 2040 or placement[axis] % 8 for axis in ('x', 'y'))):
                        raise ValueError('invalid conditional actor entry placement; requires packet32')
                    conditions = object_rows(placement['conditions'], 'entry placement conditions')
                    if not 1 <= len(conditions) <= 16:
                        raise ValueError('invalid actor entry placement conditions')
                    for condition in conditions:
                        flag = condition.get('flag')
                        if (set(condition) != {'kind', 'flag'} or condition['kind'] not in ('story_mask_set', 'story_mask_clear')
                                or not isinstance(flag, dict) or set(flag) != {'id', 'mask'}
                                or not isinstance(flag['id'], str) or len(flag['id']) != 13 or not flag['id'].startswith('scenario_')
                                or not flag['id'][9:].isascii() or not flag['id'][9:].isdigit() or int(flag['id'][9:]) >= 240
                                or type(flag['mask']) is not int or not 1 <= flag['mask'] <= 255):
                            raise ValueError('invalid actor entry placement flag')
                poses = object_rows(actor.get('poses'), 'actor poses')
                if len(poses) != 4:
                    raise ValueError('room actor needs down, up, left and right poses')
                if actor.get('clips') is not None:
                    if schema not in SCHEMAS[24:]:
                        raise ValueError('ordinary actor clips require packet25')
                    validate_field_clips(actor['clips'], atlas_size)
                    if poses != [clip['frames'][clip['idle_frame']] for clip in actor['clips']]:
                        raise ValueError('ordinary poses differ from clip idle frames')
                for pose in poses:
                    rect = pose.get('rect')
                    if (not isinstance(rect, dict) or any(type(rect.get(axis)) is not int for axis in ('x', 'y', 'w', 'h'))
                            or min(rect['x'], rect['y']) < 0 or not 1 <= rect['w'] <= 128 or not 1 <= rect['h'] <= 128):
                        raise ValueError(f'invalid room actor rectangle for {actor.get("id")!r}')
                    width, height = atlas_size or (4096, 4096)
                    if rect['x'] + rect['w'] > width or rect['y'] + rect['h'] > height:
                        raise ValueError(f'room actor {actor.get("id")!r} is outside the field atlas')
            if isinstance(dialogue, dict) and dialogue.get('schema') in ('suikoden-field-dialogue/8', 'suikoden-field-dialogue/9', 'suikoden-field-dialogue/10'):
                if schema not in SCHEMAS[3:]:
                    raise ValueError('portraits require room battle schema 4 or later')
                for image in object_rows(dialogue.get('images'), 'dialogue.images'):
                    rect = image.get('atlas_rect')
                    if (not isinstance(rect, dict) or any(type(rect.get(axis)) is not int for axis in ('x', 'y', 'w', 'h'))
                            or rect['w'] != 64 or rect['h'] != 64 or min(rect['x'], rect['y']) < 0):
                        raise ValueError(f'invalid rectangle for portrait {image.get("id")!r}')
                    if atlas_size and (rect['x'] + 64 > atlas_size[0] or rect['y'] + 64 > atlas_size[1]):
                        raise ValueError(f'portrait {image.get("id")!r} is outside the field atlas')
            exit_programs = {ref['program'] for ref in world_exits if ref['room'] == room}
            requests.extend(_room_requests(binding, encounter_ids, schema in SCHEMAS[4:],
                                           room_ids if schema in SCHEMAS[5:] else None, exit_programs, schema in SCHEMAS[6:],
                                           schema in SCHEMAS[8:], schema in SCHEMAS[9:], schema in SCHEMAS[10:],
                                           schema in SCHEMAS[11:], sound_ids, with_arrival_facing=schema in SCHEMAS[12:],
                                           with_shared_items=schema in SCHEMAS[13:], with_fade=schema in SCHEMAS[14:],
                                           with_game_over=schema in SCHEMAS[15:], with_room_flags=schema in SCHEMAS[16:],
                                           with_actors=schema in SCHEMAS[17:], with_campaign=schema in SCHEMAS[18:],
                                           with_rune_progression=schema in SCHEMAS[19:], with_recruit_loading=schema in SCHEMAS[20:],
                                   with_dice=schema in SCHEMAS[21:], with_party_select=schema in SCHEMAS[36:], world_package=world_package))
            for program in binding.get('content', {}).get('programs', []):
                for command in program.get('commands', []):
                    if command.get('kind') == 'item_overload' and schema not in SCHEMAS[45:]:
                        raise ValueError('item overload requires packet46')
                    if binding['content']['schema'] in ('suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') and schema not in SCHEMAS[47:]:
                        raise ValueError('branch history requires packet48')
                    if command.get('kind') == 'hide_hero' and schema not in SCHEMAS[46:]:
                        raise ValueError('Hero visibility requires packet47')
                    if command.get('kind') in ('wheel_spin', 'wheel_restore', 'wheel_turn', 'wheel_align', 'branch_wheel') and schema not in SCHEMAS[44:]:
                        raise ValueError('wheel controls require packet45')
                    if (((command.get('kind') == 'field_music' and command.get('music') == 'founding')
                         or (command.get('kind') == 'play_sound' and command.get('cue') == 0x813)) and schema not in SCHEMAS[33:]):
                        raise ValueError('founding audio requires packet34')
                    if (command.get('kind') == 'place_actor' and command.get('x') is not None and command.get('y') is not None
                            and schema not in SCHEMAS[32:]):
                        raise ValueError('atomic actor placement requires packet33')
                    if (command.get('kind') == 'field_music' and command.get('music') == 'headquarters'
                            and program.get('entry') == 'ordinary' and schema not in SCHEMAS[32:]):
                        raise ValueError('ordinary headquarters music requires packet33')
                    if (command.get('kind') == 'area_action' and command.get('area', {}).get('kind') in ('auxiliary_party_add', 'auxiliary_party_remove')
                            and schema not in SCHEMAS[30:]):
                        raise ValueError('auxiliary party edits require packet31')
                    if command.get('kind') == 'party_dismiss' and schema not in SCHEMAS[29:]:
                        raise ValueError('party dismissal requires packet30')
                    if command.get('kind') in ('field_effect', 'wait_field_effect', 'party_restore') and schema not in SCHEMAS[28:]:
                        raise ValueError('field effects require packet29')
                    if 'source_arrival' in command and (schema not in SCHEMAS[26:]
                            or binding['content'].get('schema') not in ('suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                            or command.get('kind') != 'room_transition' or command['source_arrival'] is not True):
                        raise ValueError('invalid source arrival placement')
        except ValueError as error:
            raise ValueError(f'{room}: {error}') from error
    if any(ref['room'] not in seen for ref in world_exits):
        raise ValueError('opening world exit references an unbound room')
    if opening_battles:
        counts = Counter((request['room'], request['program']) for request in requests)
        for ref in opening_battles:
            if counts[ref['room'], ref['program']] != 1:
                raise ValueError(f'opening battle {ref["program"]!r} in {ref["room"]!r} must bind exactly one encounter')
    if sound_ids:
        with (root / SOUND_MANIFEST).open('rb') as stream:
            manifest = stream.read(256 * 1024 + 1)
        if len(manifest) > 256 * 1024:
            raise ValueError('sound manifest exceeds 256 KiB')
        packet = json.loads(manifest)
        if not isinstance(packet, dict):
            raise ValueError('invalid sound manifest')
        packaged_ids = {cue['id'] for cue in object_rows(packet.get('cues'), 'sound cues') if type(cue.get('id')) is int}
        missing = sound_ids - packaged_ids
        if missing:
            raise ValueError(f'missing packaged field sounds {sorted(missing)}')
    if any(command.get('kind') == 'field_music' for binding in rooms
           for program in binding['content']['programs'] for command in program['commands']):
        if schema not in SCHEMAS[25:]:
            raise ValueError('field music requires room packet26')
        if schema not in SCHEMAS[26:] and any(command.get('kind') == 'field_music' and command.get('music') == 'fade' for binding in rooms for program in binding['content']['programs'] for command in program['commands']):
            raise ValueError('queued field fade requires room packet27')
        field_manifest = root / 'audio/field.json'
        if field_manifest.stat().st_size > 4096:
            raise ValueError('field music manifest exceeds 4096 bytes')
        music = json.loads(field_manifest.read_bytes())
        if not isinstance(music, dict):
            raise ValueError('invalid field music manifest')
        tracks = object_rows(music.get('tracks'), 'field music tracks')
        names = {'area_b', 'ruins', 'lakeshore'}
        if music.get('schema') in ('suikoden-field-audio/2', 'suikoden-field-audio/3', 'suikoden-field-audio/4', 'suikoden-field-audio/5', 'suikoden-field-audio/6'): names.add('headquarters')
        if music.get('schema') in ('suikoden-field-audio/3', 'suikoden-field-audio/4', 'suikoden-field-audio/5', 'suikoden-field-audio/6'): names.add('founding')
        if music.get('schema') in ('suikoden-field-audio/4', 'suikoden-field-audio/5', 'suikoden-field-audio/6'): names.add('infiltration')
        if music.get('schema') in ('suikoden-field-audio/5', 'suikoden-field-audio/6'): names.add('mansion')
        if music.get('schema') == 'suikoden-field-audio/6': names.add('wheel')
        if (music.get('schema') not in ('suikoden-field-audio/1', 'suikoden-field-audio/2', 'suikoden-field-audio/3', 'suikoden-field-audio/4', 'suikoden-field-audio/5', 'suikoden-field-audio/6') or len(tracks) != len(names)
                or any(not isinstance(track.get('id'), str) for track in tracks) or {track['id'] for track in tracks} != names):
            raise ValueError('invalid field music manifest')
        if any(command.get('kind') == 'field_music' and command.get('music') == 'headquarters' for binding in rooms for program in binding['content']['programs'] for command in program['commands']):
            if schema not in SCHEMAS[27:] or 'headquarters' not in names:
                raise ValueError('headquarters initializer requires packet28 and field audio2')
        if any(command.get('kind') == 'field_music' and command.get('music') == 'founding' for binding in rooms for program in binding['content']['programs'] for command in program['commands']):
            if schema not in SCHEMAS[33:] or 'founding' not in names:
                raise ValueError('founding music requires packet34 and field audio3')
        if any(command.get('kind') == 'field_music' and command.get('music') == 'mansion' for binding in rooms for program in binding['content']['programs'] for command in program['commands']):
            if schema not in SCHEMAS[40:] or 'mansion' not in names:
                raise ValueError('mansion music requires packet41 and field audio5')
        if any(command.get('kind') == 'field_music' and command.get('music') == 'infiltration' for binding in rooms for program in binding['content']['programs'] for command in program['commands']):
            if schema not in SCHEMAS[38:] or 'infiltration' not in names:
                raise ValueError('infiltration music requires packet39 and field audio4')
        if any(command.get('kind') == 'field_music' and command.get('music') == 'wheel' for binding in rooms for program in binding['content']['programs'] for command in program['commands']):
            if schema not in SCHEMAS[43:] or 'wheel' not in names:
                raise ValueError('wheel music requires packet44 and field audio6')
        for track in tracks:
            name, frames, rate, loop, volume = (track.get(key) for key in ('id', 'frames', 'sample_rate', 'loop_start_frame', 'volume'))
            restart = track.get('restart_after_ticks')
            if name == 'founding':
                if type(restart) is not int or (restart, frames, rate, loop, volume) != (7249, 4632768, 37800, 0, 127):
                    raise ValueError('invalid founding CD-XA counter restart')
            elif restart is not None:
                raise ValueError('counter restart on an ordinary field stream')
            if (track.get('path') != name + '.wav' or any(type(value) is not int for value in (frames, rate, loop, volume))
                    or not 8000 <= rate <= 48000 or not 1 <= frames <= 48000 * 600 or not 0 <= loop < frames or not 0 <= volume <= 127):
                raise ValueError('invalid field music track')
            path = root / 'audio' / track['path']
            if path.stat().st_size != 44 + frames * 4 or hashlib.sha256(path.read_bytes()).hexdigest() != track.get('sha256'):
                raise ValueError('field music resource mismatch')
    return requests, bool(world_exits)


def actor_initialization(content, program):
    commands = program.get('commands', [])
    if not (content['schema'] in ('suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') and program.get('entry') == 'initialization'
            and 4 <= len(commands) <= 67 and commands[0].get('kind') == 'continue_tick'
            and commands[-2].get('kind') == 'yield_tick' and commands[-1].get('kind') == 'end_stream'):
        return False
    for command in commands[1:-2]:
        if command.get('wait') is not None or command.get('requires') is not None:
            return False
        kind = command.get('kind')
        if 'if_actor_constructed' in command and (
                content['schema'] != 'suikoden-event-ir/29' or command['if_actor_constructed'] is not True
                or kind not in ('place_actor', 'actor_motion', 'actor_transition') or command.get('actor') == 'hero'):
            return False
        if kind in ('place_hero', 'story_or', 'story_andnot', 'set_camera') or kind == 'actor_transition' and command.get('actor') == 'hero':
            continue
        if kind in ('scenery_stage', 'scenery_append'):
            if content['schema'] != 'suikoden-event-ir/29':
                return False
            continue
        if (kind not in ('place_actor', 'actor_transition', 'actor_motion')
                or kind == 'actor_motion' and (type(command.get('value')) is not int or not 0 <= command['value'] <= 1)
                or command.get('actor') == 'hero' or command.get('actor', '').startswith('party_follower_')
                or not any(actor['id'] == command.get('actor') for actor in content.get('actors', []))):
            return False
    return True


def forward_graph(content):
    for program in object_rows(content.get('programs'), 'content.programs'):
        for index, command in enumerate(object_rows(program.get('commands'), 'program.commands')):
            targets = command.get('targets') or []
            if not isinstance(targets, list):
                raise ValueError('invalid event branch targets')
            inventory = command.get('inventory') or {}
            if not isinstance(inventory, dict):
                raise ValueError('invalid event inventory branch')
            targets = targets + [command[key] for key in ('target', 'escape_target', 'defeat_target', 'failure_target') if command.get(key) is not None]
            if inventory.get('failure_target') is not None:
                targets.append(inventory['failure_target'])
            if any(type(target) is not int for target in targets):
                raise ValueError('invalid event branch target')
            if any(target <= index for target in targets):
                return False
    return True


def _validate_forward_actor_paths(content, program):
    commands = program['commands']
    for pc, command in enumerate(commands):
        targets = list(command.get('targets', []))
        targets.extend(command[k] for k in ('target', 'escape_target', 'defeat_target', 'failure_target') if command.get(k) is not None)
        if command.get('inventory') is not None: targets.append(command['inventory']['failure_target'])
        if any(type(t) is not int or not pc < t < len(commands) for t in targets):
            raise ValueError('branch-history events require forward targets')
    tracks = {t['id']: t['actor'] for t in content.get('tracks', [])}
    spawned = {c['actor'] for c in commands if c.get('kind') == 'spawn_actor'}
    ordinary = {a['id'] for a in content.get('actors', [])} - spawned
    work = [(0, ordinary, set(), set(), True, 0)]
    while work:
        pc, active, released, queued, visible, edges = work.pop()
        while pc < len(commands):
            command = commands[pc]
            kind = command['kind']
            if kind == 'hide_hero' and (program.get('entry') != 'ordinary' or set(command) != {'kind'}):
                raise ValueError('Hero visibility requires an ordinary isolated shape')
            actor = tracks.get(command.get('track')) if kind == 'queue_track' else command.get('actor')
            if actor in ordinary | spawned:
                if kind == 'spawn_actor':
                    if actor in active | released: raise ValueError('scene actor created twice on one path')
                    active = active | {actor}
                else:
                    if actor not in active: raise ValueError('scene actor used outside its selected lifetime')
                    if kind in ('place_actor', 'release_actor') and actor in queued:
                        raise ValueError('scene actor placement/release precedes track completion')
                    if kind == 'release_actor':
                        active = active - {actor}
                        released = released | {actor}
                    if kind == 'queue_track': queued = queued | {actor}
            if kind == 'hide_hero': visible = False
            if kind == 'place_hero': visible = True
            if kind == 'wait_tracks': queued = set()
            if kind in ('end_stream', 'room_transition', 'world_transition'):
                if not visible or active & spawned: raise ValueError('scene ends with an unreleased actor or hidden Hero')
                break
            branching = kind in ('jump', 'branch_choice', 'branch_wheel', 'branch_castle_tier', 'branch_party')
            if branching:
                targets = list(command.get('targets', [command.get('target')]))
                if kind == 'branch_choice': targets.append(pc + 1)
            else:
                targets = [command[k] for k in ('escape_target', 'defeat_target', 'failure_target') if command.get(k) is not None]
                if command.get('inventory') is not None: targets.append(command['inventory']['failure_target'])
            if any(type(t) is not int or not pc < t < len(commands) for t in targets):
                raise ValueError('branch-history events require forward targets')
            if targets and edges == 8: raise ValueError('branch history exceeds eight decisions')
            for target in targets[1:] if branching else targets:
                if len(work) == 32: raise ValueError('scene exceeds branch path work limit')
                work.append((target, set(active), set(released), set(queued), visible, edges + 1))
            if branching: pc, edges = targets[0], edges + 1
            else: pc += 1


def _room_requests(binding, encounter_ids, with_choices, transition_rooms, exit_programs, with_party_edits, with_escape, with_defeat, with_party_leave, with_sound, sound_ids, *, with_arrival_facing, with_shared_items, with_fade, with_game_over, with_room_flags, with_actors, world_package, with_campaign=False, with_rune_progression=False, with_recruit_loading=False, with_dice=False, with_party_select=False):
    content = binding.get('content')
    population = binding.get('population')
    if not isinstance(content, dict) or not isinstance(population, dict):
        raise ValueError('expected content and population objects')
    if content.get('schema') != 'suikoden-event-ir/1' and not (
            with_campaign and content.get('schema') in ('suikoden-event-ir/2', 'suikoden-event-ir/3', 'suikoden-event-ir/4', 'suikoden-event-ir/5', 'suikoden-event-ir/6', 'suikoden-event-ir/7', 'suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')):
        raise ValueError('unsupported event program schema')
    if population.get('schema') not in ('suikoden-scene-population/1', 'suikoden-scene-population/2') and not (
            with_campaign and population.get('schema') in ('suikoden-scene-population/3', 'suikoden-scene-population/4')):
        raise ValueError('unsupported population schema')
    if content['schema'] in ('suikoden-event-ir/28', 'suikoden-event-ir/29') and population['schema'] not in ('suikoden-scene-population/3', 'suikoden-scene-population/4'):
        raise ValueError('camera pushes require extended population programs')
    if content['schema'] in ('suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') and (type(content.get('forward_branches')) is not bool or content['forward_branches'] != forward_graph(content)):
        raise ValueError('invalid actor-owner graph classification')
    tracks = object_rows(content.get('tracks', []), 'content.tracks')
    track_ids = set()
    actors = binding.get('actors', [])
    for track in tracks:
        name, actor = track.get('id'), track.get('actor')
        temporary = (content['schema'] in ('suikoden-event-ir/6', 'suikoden-event-ir/7', 'suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') and binding.get('queues') is not None
                     and actor in tuple(f'party_follower_{index}' for index in range(5)))
        if actor in tuple(f'party_follower_{index}' for index in range(5)) and not temporary:
            raise ValueError('temporary party tracks require event IR6 and room-owned queues')
        if (not with_actors or not isinstance(name, str) or not name or name in track_ids
                or not isinstance(actor, str) or (not temporary and actor != 'hero' and not any(actor == entry.get('id') for entry in actors))):
            raise ValueError('invalid room actor track or actor reference')
        commands = object_rows(track.get('commands'), 'track.commands')
        if (not 1 <= len(commands) <= 64 or commands[-1].get('kind') != 'finish'
                or any(commands[-1].get(key) is not None for key in ('direction', 'cells', 'motion', 'updates'))):
            raise ValueError(f'invalid end of room actor track {name!r}')
        has_direction = False
        for command in commands[:-1]:
            kind = command.get('kind')
            direction, cells, motion = (command.get(key) for key in ('direction', 'cells', 'motion'))
            updates = command.get('updates')
            if kind != 'hold' and updates is not None:
                raise ValueError(f'unexpected hold duration in room actor track {name!r}')
            valid = (
                kind == 'move' and direction in ('up', 'down', 'left', 'right')
                and type(cells) is int and 0 <= cells <= 255 and motion is None
                or kind == 'advance' and has_direction and direction is None
                and type(cells) is int and 1 <= cells <= 255 and motion is None
                or kind == 'set_motion' and direction is None and cells is None
                and type(motion) is int and 0 <= motion < 255
                or kind == 'hop' and content['schema'] in ('suikoden-event-ir/5', 'suikoden-event-ir/6', 'suikoden-event-ir/7', 'suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                and direction is None and cells is None and motion is None
                or kind == 'hold' and content['schema'] in ('suikoden-event-ir/4', 'suikoden-event-ir/5', 'suikoden-event-ir/6', 'suikoden-event-ir/7', 'suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                and direction is None and cells is None and motion is None
                and type(updates) is int and 0 < updates <= 1275 and updates % 5 == 0
            )
            if not valid:
                raise ValueError(f'invalid movement in room actor track {name!r}')
            has_direction |= kind == 'move'
        track_ids.add(name)
    programs = {}
    for program in object_rows(content.get('programs'), 'content.programs'):
        program_id = program.get('id')
        if not isinstance(program_id, str) or not program_id or program_id in programs:
            raise ValueError(f'invalid or duplicate program {program_id!r}')
        selection = object_rows(program.get('selection', []), 'program.selection')
        trigger = program.get('trigger')
        if len(selection) > 16 or (selection and (
                transition_rooms is None or program.get('entry') != 'ordinary' or trigger not in ('none', 'interaction'))):
            raise ValueError(f'program {program_id!r} has unsupported room selection')
        for term in selection:
            kind = term.get('kind')
            if trigger == 'interaction' and kind not in ('party_absent', 'party_contains') and not (
                    with_campaign and kind in ('hero_x_inclusive', 'hero_y_inclusive', 'hero_x_strict', 'hero_y_strict', 'room_mask_set', 'room_mask_clear', 'recruit_present', 'recruit_absent', 'recruit_ever', 'recruit_count_at_least', 'stage_at_least', 'money_at_least', 'level_at_least', 'has_item', 'party_count_equals')):
                raise ValueError(f'program {program_id!r} has an unsupported interaction selection predicate')
            mask = term.get('mask')
            if kind == 'pressed_mask' and type(mask) is int and mask in (0x1000, 0x2000, 0x4000, 0x8000):
                continue
            if with_room_flags and kind in ('room_mask_set', 'room_mask_clear'):
                offset = term.get('index', 0)
                if type(offset) is int and 0 <= offset < 20 and type(mask) is int and 1 <= mask <= 255:
                    continue
            if kind in ('hero_x_inclusive', 'hero_y_inclusive', 'hero_x_strict', 'hero_y_strict'):
                low, high = term.get('min', 0), term.get('max', 0)
                if type(low) is int and type(high) is int and 0 <= low <= high <= 255:
                    continue
            if kind in ('party_absent', 'party_contains'):
                index = term.get('index', 0)
                if type(index) is int and 1 <= index <= 255:
                    continue
            if with_campaign and kind == 'party_count_equals':
                if type(term.get('index')) is int and 0 <= term['index'] <= 6 and set(term) == {'kind', 'index'}:
                    continue
            if with_campaign and kind == 'money_at_least':
                if type(term.get('amount')) is int and 0 <= term['amount'] <= 0xffffffff and set(term) == {'kind', 'amount'}:
                    continue
            if with_campaign and kind in ('recruit_present', 'recruit_absent', 'recruit_ever'):
                if type(term.get('index')) is int and 0 <= term['index'] < 108 and set(term) == {'kind', 'index'}:
                    continue
            if with_campaign and kind == 'recruit_count_at_least':
                if type(term.get('index')) is int and 0 <= term['index'] <= 108 and set(term) == {'kind', 'index'}:
                    continue
            if with_campaign and kind == 'level_at_least':
                if (type(term.get('index')) is int and 0 <= term['index'] <= 255
                        and type(term.get('min')) is int and 0 <= term['min'] <= 255
                        and set(term) == {'kind', 'index', 'min'}):
                    continue
            if with_campaign and kind == 'stage_at_least':
                if type(term.get('min')) is int and 0 <= term['min'] < 5 and set(term) == {'kind', 'min'}:
                    continue
            if kind == 'has_item' and content['schema'] in ('suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29'):
                if (program.get('entry') == 'ordinary' and trigger in ('none', 'interaction')
                        and type(term.get('index')) is int and 0 <= term['index'] <= 255
                        and type(term.get('require_key', False)) is bool
                        and set(term) <= {'kind', 'index', 'require_key'}):
                    continue
            raise ValueError(f'program {program_id!r} has an unsupported room selection predicate')
        battles = []
        commands = object_rows(program.get('commands'), 'program.commands')
        owner = program.get('owner_actor')
        owners = program.get('owner_actors')
        if owners is not None and (content['schema'] not in ('suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or owner is not None
                                   or program.get('entry') != 'ordinary' or trigger != 'interaction'
                                   or not isinstance(owners, list) or len(owners) != 1
                                   or any(not isinstance(candidate, str) for candidate in owners)
                                   or len(set(owners)) != len(owners)
                                   or any(not any(actor.get('id') == candidate and actor.get('scene_actor') is None for actor in actors) for candidate in owners)):
            raise ValueError('invalid fixed interaction owner')
        if owners is not None:
            order = [next(actor['entity'] for actor in actors if actor['id'] == candidate) for candidate in owners]
            if order[0] >= program['entity'] or any(current >= previous for previous, current in zip(order, order[1:])):
                raise ValueError('invalid conditional interaction owner order')
        if owner is not None and (content['schema'] not in ('suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or program.get('entry') != 'ordinary' or trigger != 'interaction' or not any(actor.get('id') == owner and actor.get('scene_actor') is None for actor in actors)):
            raise ValueError('invalid inherited interaction owner')
        actor_suffix = next((i for i, command in enumerate(commands) if command.get('kind') in ('spawn_actor', 'place_actor', 'release_actor', 'queue_track')), len(commands))
        branched = content['schema'] in ('suikoden-event-ir/25', 'suikoden-event-ir/26') or content['schema'] in ('suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') and (
            content['forward_branches'] or any(command.get('kind') in ('branch_castle_tier', 'branch_party') for command in commands))
        def invalid_actor_flow():
            if branched: return False
            for i, other in enumerate(commands):
                if any(other.get(key) is not None for key in ('escape_target', 'defeat_target', 'failure_target', 'inventory')):
                    return True
                if other.get('kind') in ('jump', 'branch_choice', 'branch_wheel', 'branch_castle_tier', 'branch_party'):
                    targets = other.get('targets') if other.get('targets') is not None else [other.get('target')]
                    if content['schema'] not in ('suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or i >= actor_suffix or any(type(target) is not int or target > actor_suffix for target in targets):
                        return True
            return False
        for index, command in enumerate(commands):
            kind = command.get('kind')
            if 'facility' in command and (
                    not with_campaign or kind != 'service'
                    or command['facility'] not in ('save_point', 'storage', 'cup_game', 'card_game', 'teleport', 'bathhouse', 'tablet', 'library', 'window_styles', 'sound_themes', 'music_player')
                    or set(command) != {'kind', 'facility'} or program.get('entry') != 'ordinary'
                    or trigger != 'interaction' or index + 1 == len(commands)
                    or commands[index + 1].get('kind') != 'end_stream'):
                raise ValueError('invalid named field service')
            guarded = 'if_actor_constructed' in command
            if guarded:
                actor = next((actor for actor in actors if actor.get('id') == command.get('actor')), None)
                if (not 0 < index < len(commands) - 2 or not actor_initialization(content, program)
                        or actor is None or actor.get('scene_actor') is not None
                        or kind == 'actor_motion' and command['value'] != (actor.get('speed') or 0)):
                    raise ValueError('invalid constructor-guarded actor command')
            if command.get('push') is not None and kind != 'camera_push':
                raise ValueError('push payload requires a camera push command')
            if kind in ('scenery_stage', 'scenery_restore', 'scenery_append'):
                scenery_object = command.get('scenery_object')
                limit = 1280 if kind == 'scenery_append' else 1024
                if (content['schema'] != 'suikoden-event-ir/29' or transition_rooms is None
                        or kind == 'scenery_restore' and program.get('entry') != 'ordinary'
                        or (program.get('entry') != 'ordinary' and not actor_initialization(content, program))
                        or set(command) != {'kind', 'scenery_object'} or type(scenery_object) is not int
                        or not 0 <= scenery_object < limit):
                    raise ValueError('invalid scenery mutation command')
            if kind == 'sequence_input':
                flag = command.get('flag')
                if (content['schema'] != 'suikoden-event-ir/29' or transition_rooms is None
                        or program.get('entry') != 'ordinary'
                        or set(command) != {'kind', 'flag', 'parameter', 'value'}
                        or not isinstance(flag, dict) or set(flag) != {'id', 'mask'}
                        or type(flag['mask']) is not int or flag['mask'] != 255
                        or not any(flag['id'] == value['id'] for value in content['story_values'])
                        or type(command['parameter']) is not int or not 0 <= command['parameter'] <= 255
                        or type(command['value']) is not int or command['value'] not in (0, 1)):
                    raise ValueError('invalid sequence input command')
            if kind == 'camera_push':
                push = command.get('push')
                if (not with_campaign or content['schema'] not in ('suikoden-event-ir/28', 'suikoden-event-ir/29')
                        or program.get('entry') != 'ordinary' or transition_rooms is None
                        or set(command) != {'kind', 'push', 'wait'}
                        or command['wait'] != {'kind': 'camera_push', 'id': 'camera_push'}
                        or not isinstance(push, dict) or set(push) != {'dx', 'dy', 'updates', 'repeats'}
                        or any(type(value) is not int for value in push.values())
                        or push['dx'] not in (-16, -8, 8, 16) or push['dy'] not in (-8, 8)
                        or push['updates'] != 8 or not 1 <= push['repeats'] <= 256
                        or any(other.get('kind') == 'continue_tick' for other in commands)):
                    raise ValueError('invalid ordinary camera push')
            elif any(isinstance(command.get(key), dict) and command[key].get('kind') == 'camera_push' for key in ('wait', 'requires')):
                raise ValueError('camera push wait requires its issuing command')
            if command.get('prop') is not None and kind != 'show_prop':
                raise ValueError('prop identity requires a show_prop command')
            if kind == 'actor_motion':
                actor = next((actor for actor in binding.get('actors', []) if actor['id'] == command.get('actor')), None)
                if (not actor_initialization(content, program) or actor is None
                        or set(command) != {'kind', 'actor', 'value'}
                        or type(command.get('value')) is not int or command['value'] != actor.get('speed', 0)):
                    raise ValueError('initializer motion must retain constructor speed')
            if kind == 'show_prop' and (content['schema'] not in ('suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or set(command) != {'kind', 'prop'} or type(command['prop']) is not int or not 0 <= command['prop'] < 64):
                raise ValueError('invalid scenery prop command')
            if kind == 'fade_in' and (not with_campaign or content['schema'] not in ('suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or program.get('entry') != 'ordinary' or set(command) != {'kind', 'wait'} or command['wait'] != {'kind': 'fade', 'id': 'fade'} or any(other.get('kind') == 'continue_tick' for other in commands)):
                raise ValueError('fade-in requires event IR17')
            if kind != 'field_effect' and command.get('effect') is not None:
                raise ValueError('effect identity requires a field effect command')
            if kind == 'party_dismiss' and (content['schema'] not in ('suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or not with_campaign or transition_rooms is None or program.get('entry') != 'ordinary'
                    or set(command) != {'kind'}):
                raise ValueError('invalid party dismissal command')
            if kind == 'party_restore' and (content['schema'] not in ('suikoden-event-ir/2', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or not with_campaign or transition_rooms is None or program.get('entry') != 'ordinary'
                    or (set(command) != {'kind'} and not (set(command) == {'kind', 'hp_only'} and command['hp_only'] is True))):
                raise ValueError('invalid party recovery command')
            if 'hp_only' in command and kind != 'party_restore':
                raise ValueError('HP-only recovery requires a party recovery command')
            if kind in ('field_effect', 'wait_field_effect'):
                expected = {'kind', 'effect', 'x', 'y'} if kind == 'field_effect' else {'kind'}
                if (content['schema'] not in ('suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or transition_rooms is None
                        or program.get('entry') != 'ordinary' or set(command) != expected
                        or kind == 'field_effect' and (command.get('effect') not in ('appearance', 'disappearance')
                            or any(type(command.get(axis)) is not int or not 0 <= command[axis] <= 2040
                                   or command[axis] % 8 for axis in ('x', 'y')))):
                    raise ValueError('invalid field effect command')
            if command.get('actor') in tuple(f'party_follower_{slot}' for slot in range(5)):
                party_dialogue = binding.get('dialogue')
                if (kind not in ('actor_transition', 'open_box') or content['schema'] not in ('suikoden-event-ir/7', 'suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                        or binding.get('queues') is None or not isinstance(party_dialogue, dict)
                        or party_dialogue.get('schema') not in ('suikoden-field-dialogue/9', 'suikoden-field-dialogue/10')):
                    raise ValueError('named party actor commands require IR7 and party dialogue')
                if kind == 'actor_transition' and (type(command.get('transition')) is not int or not 0 <= command['transition'] <= 3):
                    raise ValueError('invalid named party actor facing')
            if kind in ('request_area_party_prefix', 'queue_glyphs_a', 'queue_glyphs_b', 'wait_text_queue_empty', 'wait_text_queue_drain_and_release') and binding.get('queues') is None and not (kind == 'request_area_party_prefix' and owner is not None):
                raise ValueError('party formation command needs room-owned queue data')
            if kind in ('set_camera', 'set_hero_display') and (
                    content['schema'] not in ('suikoden-event-ir/3', 'suikoden-event-ir/4', 'suikoden-event-ir/5', 'suikoden-event-ir/6', 'suikoden-event-ir/7', 'suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or (program.get('entry') != 'initialization' and not (kind == 'set_camera' and content['schema'] in ('suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') and program.get('entry') == 'ordinary'))
                    or any(type(command.get(axis)) is not int or not 0 <= command[axis] <= 2040 for axis in ('x', 'y'))):
                raise ValueError(f'program {program_id!r} has an invalid scene view command')
            if kind == 'party_select' and (
                    not with_party_select or content['schema'] not in ('suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or program.get('entry') != 'ordinary'):
                raise ValueError('party selection requires packet37, IR15 and an ordinary source event')
            if kind == 'party_select' and set(command) != {'kind'}:
                keys = set(command)
                required = command.get('required_party')
                requested = command.get('index')
                if (type(command.get('parameter')) is not int or command['parameter'] != 5
                        or keys != {'kind', 'parameter'} and not (
                            keys == {'kind', 'parameter', 'index', 'required_party'}
                            and isinstance(required, list) and 1 <= len(required) <= 5
                            and all(type(member) is int and 1 <= member < 108 for member in required)
                            and len(set(required)) == len(required)
                            and type(requested) is int and requested in required)):
                    raise ValueError('invalid party selection operands')
            if kind == 'fixed_dice' and (
                    not with_dice or content['schema'] not in ('suikoden-event-ir/2', 'suikoden-event-ir/3', 'suikoden-event-ir/4', 'suikoden-event-ir/5', 'suikoden-event-ir/6', 'suikoden-event-ir/7', 'suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or set(command) != {'kind'}):
                raise ValueError('fixed dice requires campaign schema 22')
            if kind == 'recruit_mark_loaded' and (
                    not with_recruit_loading or content['schema'] not in ('suikoden-event-ir/2', 'suikoden-event-ir/3', 'suikoden-event-ir/4', 'suikoden-event-ir/5', 'suikoden-event-ir/6', 'suikoden-event-ir/7', 'suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or type(command.get('index')) is not int or not 0 <= command['index'] < 108
                    or set(command) != {'kind', 'index'}):
                raise ValueError('recruit loading requires campaign schema 21 and a valid character index')
            if kind == 'recruit_toggle' and (
                    not with_campaign or content['schema'] not in ('suikoden-event-ir/2', 'suikoden-event-ir/3', 'suikoden-event-ir/4', 'suikoden-event-ir/5', 'suikoden-event-ir/6', 'suikoden-event-ir/7', 'suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or type(command.get('index')) is not int or not 0 <= command['index'] < 108
                    or set(command) - {'kind', 'index', 'mask'}
                    or type(command.get('mask', 0)) is not int or not 0 <= command.get('mask', 0) <= 255):
                raise ValueError('invalid campaign recruitment command')
            if kind == 'soul_eater_advance' and (not with_rune_progression or set(command) != {'kind'}):
                raise ValueError('Soul Eater progression requires campaign schema 20 and no operands')
            if kind in ('queue_track', 'wait_tracks'):
                track = command.get('track')
                if (not track_ids or command.get('wait') is not None or command.get('requires') is not None
                        or (kind == 'queue_track' and (not isinstance(track, str) or track not in track_ids))):
                    raise ValueError(f'program {program_id!r} has an invalid room actor track command')
            if kind == 'area_action':
                action = command.get('area')
                auxiliary = isinstance(action, dict) and action.get('kind') in ('auxiliary_party_add', 'auxiliary_party_remove')
                if auxiliary:
                    if (not with_campaign or transition_rooms is None or content['schema'] not in ('suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                            or program.get('entry') != 'ordinary' or set(command) != {'kind', 'area'}
                            or set(action) != {'kind', 'character'} or type(action['character']) is not int or not 0 <= action['character'] <= 255):
                        raise ValueError(f'program {program_id!r} has an invalid auxiliary party edit')
                elif (not with_room_flags or not isinstance(action, dict) or action.get('kind') != 'room_flag'
                        or type(action.get('id', 0)) is not int or not 0 <= action.get('id', 0) < 20
                        or type(action.get('bits')) is not int or not 1 <= action['bits'] <= 255
                        or command.get('wait') is not None or command.get('requires') is not None):
                    raise ValueError(f'program {program_id!r} has an invalid room flag write')
            facing = command.get('arrival_facing')
            if facing is not None and (not with_arrival_facing or kind not in ('room_transition', 'world_transition')
                                       or facing not in ('up', 'right', 'down', 'left')):
                raise ValueError(f'program {program_id!r} has an invalid arrival direction')
            if program.get('entry') == 'initialization' and (
                    transition_rooms is None or command.get('wait') is not None or command.get('requires') is not None
                    or (kind not in ('continue_tick', 'yield_tick', 'label', 'jump', 'story_or', 'story_andnot', 'end_stream', 'set_camera', 'set_hero_display', 'field_music', 'show_prop')
                        and not (kind in ('place_actor', 'place_hero', 'actor_transition', 'actor_motion', 'scenery_stage', 'scenery_append') and actor_initialization(content, program)))):
                raise ValueError(f'program {program_id!r} has an unsupported room initializer command')
            for outcome, allowed in (('escape', with_escape), ('defeat', with_defeat)):
                target = command.get(f'{outcome}_target')
                if target is not None and (not allowed or kind != 'battle' or type(target) is not int or not 0 <= target < len(commands)):
                    raise ValueError(f'program {program_id!r} has an invalid battle {outcome} branch')
            game_over = command.get('defeat_ends_run', False)
            if type(game_over) is not bool or (game_over and (not with_game_over or kind != 'battle'
                                                             or command.get('defeat_target') is not None)):
                raise ValueError(f'program {program_id!r} has an invalid game-over policy')
            if kind in ('choice', 'branch_choice') and (not with_choices or binding.get('dialogue') is None):
                raise ValueError(f'program {program_id!r} uses a choice without schema-5 dialogue support')
            if kind == 'choice':
                opts = command.get('options')
                if type(opts) is not int or not 2 <= opts <= 4:
                    raise ValueError(f'program {program_id!r} has invalid choice option count')
            if content['schema'] in ('suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29'):
                target = next((track.get('actor') for track in tracks if track.get('id') == command.get('track')), None) if kind == 'queue_track' else command.get('actor')
                if not branched and target is not None and any(prior.get('kind') == 'release_actor' and prior.get('actor') == target for prior in commands[:index]):
                    raise ValueError('released actor cannot receive later scene commands')
            if kind == 'spawn_actor':
                actor = next((entry for entry in actors if entry.get('id') == command.get('actor')), None)
                if (content['schema'] not in ('suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or actor is None or actor.get('scene_actor') is None
                        or program.get('entry') != 'ordinary' or set(command) != {'kind', 'actor'}
                        or invalid_actor_flow()):
                    raise ValueError('invalid scene actor creation')
                if not branched and sum(other.get('kind') == 'release_actor' and other.get('actor') == actor['id'] for other in commands[index + 1:]) != 1:
                    raise ValueError('scene actor must be released once')
                for prior in commands[:index]:
                    target = next((track.get('actor') for track in tracks if track.get('id') == prior.get('track')), None) if prior.get('kind') == 'queue_track' else prior.get('actor')
                    if not branched and target == actor['id']:
                        raise ValueError('scene actor used before creation')
            if kind == 'release_actor':
                actor = next((entry for entry in actors if entry.get('id') == command.get('actor')), None)
                if (content['schema'] not in ('suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or program.get('entry') != 'ordinary'
                        or actor is None or actor.get('clips') is None or set(command) != {'kind', 'actor'}
                        or invalid_actor_flow()):
                    raise ValueError('invalid ordinary actor release')
            if kind == 'place_actor':
                actor = next((entry for entry in actors if entry.get('id') == command.get('actor')), None)
                axes = [axis for axis in ('x', 'y') if command.get(axis) is not None]
                if (content['schema'] not in ('suikoden-event-ir/8', 'suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or (program.get('entry') != 'ordinary' and not actor_initialization(content, program))
                        or actor is None or (actor.get('clips') is None and not actor_initialization(content, program) and not (content['schema'] == 'suikoden-event-ir/29' and actor.get('scene_actor') is None)) or len(axes) not in (1, 2)
                        or len(axes) == 2 and content['schema'] not in ('suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                        or set(command) != {'kind', 'actor', *axes, *(['if_actor_constructed'] if guarded else [])}
                        or any(type(command[axis]) is not int or not 0 <= command[axis] <= 2040 or command[axis] % 8 for axis in axes)
                        or invalid_actor_flow()
                        or not branched and any(other.get('kind') == 'queue_track' and next(
                            (track.get('actor') for track in tracks if track.get('id') == other.get('track')), None) == command['actor']
                               and not (content['schema'] == 'suikoden-event-ir/24' and any(c.get('kind') == 'wait_tracks' for c in commands[prior + 1:index]))
                               for prior, other in enumerate(commands[:index]))):
                    raise ValueError('invalid ordinary actor axis position')
            if kind == 'open_fixed_box':
                if (content['schema'] not in ('suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or binding.get('dialogue') is None or program.get('entry') != 'ordinary'
                        or set(command) != {'kind', 'box', 'x', 'y', 'width', 'height', 'requires'}
                        or command.get('requires') != {'kind': 'box_closed', 'id': f"box_{command.get('box')}"}
                        or any(type(command.get(key)) is not int for key in ('box', 'x', 'y', 'width', 'height'))
                        or command['box'] not in (0, 1) or command['x'] < 8 or command['y'] < 8
                        or not 16 <= command['width'] <= 248 or command['width'] % 8
                        or not 12 <= command['height'] <= 228 or command['height'] % 12
                        or command['x'] + command['width'] > 312 or command['y'] + command['height'] > 232
                        or not branched and any(other.get('kind') in ('jump', 'branch_choice', 'branch_wheel', 'branch_castle_tier', 'choice') or any(other.get(key) is not None
                               for key in ('escape_target', 'defeat_target', 'failure_target', 'inventory')) for other in commands)):
                    raise ValueError('invalid fixed dialogue rectangle')
            if kind == 'place_hero' and (not with_actors or command.get('wait') is not None
                                         or any(type(v) is not int or not 0 <= v <= 2040 or v % 8
                                                for v in (command.get('x'), command.get('y')))):
                raise ValueError(f'program {program_id!r} has an invalid Hero placement')
            if kind == 'inn_stay':
                amount = command.get('amount')
                if (not with_choices or transition_rooms is None or type(amount) is not int or not 0 <= amount <= 65535
                        or command.get('wait') is not None):
                    raise ValueError(f'program {program_id!r} has an invalid inn stay')
            if kind == 'branch_choice':
                targets = command.get('targets')
                target = command.get('target')
                if targets is not None:
                    if target is not None or not isinstance(targets, list) or not 1 <= len(targets) <= 3:
                        raise ValueError(f'program {program_id!r} has invalid branch_choice targets')
                    if any(type(t) is not int or not 0 <= t < len(commands) for t in targets):
                        raise ValueError(f'program {program_id!r} has out-of-range branch_choice target')
                elif type(target) is not int or not 0 <= target < len(commands):
                    raise ValueError(f'program {program_id!r} has invalid branch_choice target')
            if kind == 'branch_castle_tier':
                destinations = command.get('targets')
                if (not branched or program.get('entry') != 'ordinary' or set(command) != {'kind', 'targets'}
                        or not isinstance(destinations, list) or len(destinations) != 3
                        or any(type(t) is not int or not index < t < len(commands) for t in destinations)):
                    raise ValueError(f'program {program_id!r} has invalid castle tier branches')
            if kind == 'branch_party':
                destinations = command.get('targets')
                member = command.get('index')
                if (not branched or program.get('entry') != 'ordinary' or trigger not in ('none', 'interaction')
                        or set(command) != {'kind', 'index', 'targets'} or type(member) is not int or not 0 <= member < 108
                        or not isinstance(destinations, list) or len(destinations) != 2
                        or any(type(t) is not int or not index < t < len(commands) for t in destinations)):
                    raise ValueError(f'program {program_id!r} has invalid party branches')
            if content['schema'] in ('suikoden-event-ir/9', 'suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') and kind in ('open_box', 'open_fixed_box'):
                sound_ids.add(0x501)
            if kind == 'play_sound':
                cue = command.get('cue')
                timed = cue == 0x813 and content['schema'] in ('suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') and set(command) == {'kind', 'cue'}
                if not with_sound or type(cue) is not int or (not 0x500 <= cue <= 0x5ff and not timed) or command.get('wait') is not None:
                    raise ValueError(f'program {program_id!r} has an invalid packaged sound effect')
                sound_ids.add(cue)
            if kind in ('wheel_spin', 'wheel_restore', 'wheel_turn', 'wheel_align', 'branch_wheel'):
                if not with_campaign or content['schema'] not in ('suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or program.get('entry') != 'ordinary':
                    raise ValueError('wheel controls require ordinary IR22')
                if kind == 'wheel_turn':
                    valid = set(command) == {'kind', 'updates'} and type(command['updates']) is int and 0 <= command['updates'] <= 255
                elif kind == 'branch_wheel':
                    targets = command.get('targets')
                    valid = (set(command) == {'kind', 'targets'} and isinstance(targets, list) and len(targets) == 7
                             and all(type(target) is int and 0 <= target < len(commands) for target in targets))
                else:
                    valid = set(command) == {'kind'}
                if not valid:
                    raise ValueError('invalid wheel control')
            if kind == 'hide_hero' and not branched:
                restoration = next((c.get('kind') for c in commands[index + 1:] if c.get('kind') in ('place_hero', 'end_stream', 'room_transition', 'world_transition')), None)
                if (content['schema'] != 'suikoden-event-ir/24'
                        or program.get('entry') != 'ordinary' or set(command) != {'kind'}
                        or restoration != 'place_hero'
                        or any(c.get('kind') in ('jump', 'branch_choice', 'branch_wheel', 'branch_castle_tier', 'choice')
                               or any(c.get(k) is not None for k in ('escape_target', 'defeat_target', 'failure_target', 'inventory')) for c in commands)):
                    raise ValueError('Hero visibility requires packet47 and a linear IR24 restoration')
            if kind == 'item_overload':
                if (not with_campaign or content['schema'] not in ('suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or program.get('entry') != 'ordinary'
                        or set(command) != {'kind', 'item_name'} or not isinstance(command['item_name'], str) or not command['item_name']):
                    raise ValueError('item overload requires named ordinary IR23')
            if kind == 'chest_grant':
                if (not with_campaign or not isinstance(command.get('item_name'), str) or not command['item_name']
                        or set(command) - {'kind', 'item_name', 'flag', 'failure_target'}
                        or type(command.get('failure_target')) is not int or not 0 <= command['failure_target'] < len(commands)):
                    raise ValueError('item grant requires a named item and failure continuation')
            if kind in ('party_gain_experience', 'party_lose_experience'):
                if content['schema'] not in ('suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or set(command) != {'kind'} or program.get('entry') != 'ordinary':
                    raise ValueError('party experience requires ordinary IR20')
            if kind == 'field_music' and (content['schema'] not in ('suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or set(command) != {'kind', 'music'} or command['music'] not in ('stop', 'fade', 'area_b', 'ruins', 'lakeshore', 'headquarters', 'founding', 'infiltration', 'mansion', 'wheel')
                    or command['music'] == 'wheel' and content['schema'] not in ('suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or command['music'] in ('area_b', 'mansion') and content['schema'] not in ('suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or command['music'] == 'infiltration' and content['schema'] not in ('suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or command['music'] == 'founding' and content['schema'] not in ('suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or command['music'] == 'fade' and content['schema'] not in ('suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                    or (command['music'] == 'headquarters' and (
                        content['schema'] not in ('suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                        or program.get('entry') not in ('ordinary', 'initialization')
                        or program.get('entry') == 'ordinary' and content['schema'] not in ('suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                        or program.get('entry') == 'initialization' and commands != [{'kind': 'field_music', 'music': 'headquarters'}, {'kind': 'end_stream'}]))
                    or (command['music'] != 'headquarters' and program.get('entry') != 'ordinary') or any(other.get('kind') == 'continue_tick' for other in commands)):
                raise ValueError('invalid field music request')
            if kind == 'chest_grant':
                if (not with_campaign or not isinstance(command.get('item_name'), str) or not command['item_name']
                        or set(command) - {'kind', 'item_name', 'flag', 'failure_target'}
                        or type(command.get('failure_target')) is not int or not 0 <= command['failure_target'] < len(commands)):
                    raise ValueError('item grant requires a named item and failure continuation')
            if kind in ('party_gain_experience', 'party_lose_experience'):
                if content['schema'] not in ('suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or set(command) != {'kind'} or program.get('entry') != 'ordinary':
                    raise ValueError('party experience requires ordinary IR20')
            if kind == 'field_music' and command['music'] in ('headquarters', 'founding') and program.get('entry') == 'ordinary' and any(
                    other.get('kind') in ('jump', 'branch_choice', 'branch_wheel', 'branch_castle_tier', 'choice') or any(other.get(key) is not None
                    for key in ('escape_target', 'defeat_target', 'failure_target', 'inventory')) for other in commands):
                raise ValueError('ordinary headquarters music requires a linear program')
            if kind == 'fade_out':
                wait = command.get('wait')
                if (not with_fade or command.get('blend_mode') != 2 or command.get('draw_slot') != 10
                        or command.get('updates') is not None or not isinstance(wait, dict)
                        or wait.get('kind') != 'fade' or wait.get('id') != 'fade'):
                    raise ValueError(f'program {program_id!r} has an invalid fade')
            if kind in ('party_load', 'advance_character'):
                name = command.get('character')
                expected = {'kind', 'character'} | ({'level_advances'} if kind == 'advance_character' else set())
                if kind == 'advance_character' and command.get('add_hero_level') is True:
                    expected.add('add_hero_level')
                if (content['schema'] not in ('suikoden-event-ir/10', 'suikoden-event-ir/11', 'suikoden-event-ir/12', 'suikoden-event-ir/13', 'suikoden-event-ir/14', 'suikoden-event-ir/15', 'suikoden-event-ir/16', 'suikoden-event-ir/17', 'suikoden-event-ir/18', 'suikoden-event-ir/19', 'suikoden-event-ir/20', 'suikoden-event-ir/21', 'suikoden-event-ir/22', 'suikoden-event-ir/23', 'suikoden-event-ir/24', 'suikoden-event-ir/25', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or not with_campaign or set(command) != expected
                        or program.get('entry') != 'ordinary' or any(other.get('kind') == 'continue_tick' for other in commands)
                        or not isinstance(name, str) or re.fullmatch('[A-Za-z0-9_]{1,96}', name) is None
                        or kind == 'advance_character' and (type(command.get('level_advances')) is not int or not 1 <= command['level_advances'] <= 99)):
                    raise ValueError('invalid character load/growth effect')
            if kind in ('party_join', 'party_leave', 'rune_grant', 'inventory_edit', 'warehouse_deposit', 'shared_inventory_edit'):
                member = command.get('character')
                permitted = {'party_join': transition_rooms is not None, 'party_leave': with_party_leave,
                             'shared_inventory_edit': with_shared_items}.get(kind, with_party_edits)
                valid_member = member is None if kind == 'shared_inventory_edit' else (
                    isinstance(member, str) and 1 <= len(member) <= 96 and member.isascii() and member.replace('_', 'a').isalnum())
                if not permitted or not valid_member or command.get('wait') is not None:
                    raise ValueError(f'program {program_id!r} has an invalid {kind.replace("_", " ")}')
                if kind == 'party_join':
                    adv = command.get('level_advances')
                    if adv is not None and (type(adv) is not int or not 1 <= adv <= 99):
                        raise ValueError(f'program {program_id!r} has invalid level_advances')
                if kind == 'party_leave' and 'value' in command and (type(command['value']) is not int or command['value'] != 1):
                    raise ValueError(f'program {program_id!r} has an invalid optional departure')
                if kind == 'rune_grant':
                    rune = command.get('rune')
                    if not isinstance(rune, str) or not 1 <= len(rune.encode('utf-8')) <= 96:
                        raise ValueError(f'program {program_id!r} has an invalid rune ID')
                if kind == 'warehouse_deposit' and (set(command) != {'kind', 'character'} or program.get('entry') != 'ordinary'):
                    raise ValueError(f'program {program_id!r} has an invalid warehouse deposit')
                if kind in ('inventory_edit', 'shared_inventory_edit'):
                    edit = command.get('inventory')
                    if not isinstance(edit, dict) or set(edit) - {'give', 'take', 'failure_target'}:
                        raise ValueError(f'program {program_id!r} has an invalid inventory edit')
                    items = [edit[name] for name in ('give', 'take') if edit.get(name) is not None]
                    failure = edit.get('failure_target')
                    if (not items or type(failure) is not int or not 0 <= failure < len(commands)
                            or any(not isinstance(item, str) or not 1 <= len(item) <= 96
                                   or not item.isascii() or not item.replace('_', 'a').isalnum() for item in items)):
                        raise ValueError(f'program {program_id!r} has an invalid inventory edit')
            retained = command.get('return_to_entry', False)
            retained_region = command.get('retain_world_region', False)
            if ('return_to_entry' in command and (retained is not True or kind != 'world_transition' or content['schema'] not in ('suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29'))):
                raise ValueError('invalid retained world return')
            if 'retain_world_region' in command and (retained_region is not True or retained or kind != 'world_transition'
                                                       or content['schema'] not in ('suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or command.get('destination') is not None):
                raise ValueError('invalid retained-region world return')
            if 'world_point' in command and (content['schema'] not in ('suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29') or kind != 'room_transition'
                                              or type(command['world_point']) is not int or not 0 <= command['world_point'] <= 255):
                raise ValueError('invalid field world point')
            if 'world_entry' in command:
                if (world_package is None or content['schema'] not in ('suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29')
                        or kind != 'room_transition' or 'world_point' in command):
                    raise ValueError('invalid explicit room world entry')
                destination = next((room for room in world_package['rooms'] if room['id'] == command.get('destination')), {})
                if not any(entry['id'] == command['world_entry'] and entry['area'] == destination.get('source_area')
                           for entry in world_package['world_entries']):
                    raise ValueError('explicit world entry does not match destination area')
            if kind in ('room_transition', 'world_transition'):
                if index + 1 != len(program['commands']):
                    if (kind != 'room_transition' or not with_campaign or not with_choices
                            or commands[index + 1].get('kind') != 'end_stream'
                            or not any(c.get('kind') in ('branch_choice', 'branch_castle_tier') for c in commands[:index])):
                        raise ValueError('room transition must be terminal in its branch')
                if retained:
                    if any(command.get(key) is not None for key in ('destination', 'x', 'y')):
                        raise ValueError('retained world return cannot contain a fixed destination')
                else:
                    destination = command.get('destination')
                    if not retained_region and (transition_rooms is None or not isinstance(destination, str) or destination not in transition_rooms):
                        raise ValueError(f'program {program_id!r} has an invalid room transition destination {destination!r}')
                    limit = 255 if kind == 'world_transition' else 2040
                    if any(type(value) is not int or not 0 <= value <= limit or (kind == 'room_transition' and value % 8)
                           for value in (command.get('x'), command.get('y'))):
                        raise ValueError(f'program {program_id!r} has an invalid room transition spawn')
                    if retained_region:
                        source_area = next((row.get('source_area') for row in world_package['rooms'] if row['id'] == binding['room']), None)
                        worlds = {entry['world_room'] for entry in world_package['world_entries'] if entry['area'] == source_area}
                        if not worlds or any(command['x'] * 8 >= row['width'] or command['y'] * 8 >= row['height']
                                             for row in world_package['rooms'] if row['id'] in worlds):
                            raise ValueError('invalid retained-region world return bounds')
                if kind == 'world_transition' and not with_campaign:
                    raise ValueError('world transition requires campaign schema 19')
            if kind != 'battle':
                continue
            encounter = command.get('battle')
            if not isinstance(encounter, str) or (
                encounter not in encounter_ids
                and not (encounter.startswith('war:') and encounter[4:] in WAR_SCENARIO_IDS)
                and not (encounter.startswith('duel:') and encounter[5:] in DUEL_IDS)
                and not (encounter.startswith('ending:') and encounter[7:] in ENDING_IDS)
            ):
                raise ValueError(f'program {program_id!r} references unknown encounter {encounter!r}')
            battles.append((index, encounter))
        if not battles and transition_rooms is None:
            raise ValueError(f'program {program_id!r} has no battle command')
        if branched: _validate_forward_actor_paths(content, program)
        programs[program_id] = program, battles

    references = set()
    for reference in object_rows(population.get('programs'), 'population.programs'):
        program_id = reference.get('id')
        if (not isinstance(program_id, str) or program_id not in programs
                or reference.get('content_id') != content.get('id') or reference.get('namespace') != content['schema']):
            raise ValueError(f'population references unknown program {program_id!r}')
        references.add(program_id)

    entities = object_rows(population.get('entities'), 'population.entities')
    if not entities and population.get('schema') not in ('suikoden-scene-population/3', 'suikoden-scene-population/4'):
        raise ValueError('population has no entities')
    for source_order, entity in enumerate(entities):
        owner = entity.get('id')
        event = entity.get('event')
        selection = entity.get('event_selection')
        if not isinstance(owner, str) or not isinstance(event, dict) or not isinstance(selection, dict):
            raise ValueError('invalid room event owner')
        trigger = entity.get('trigger')
        interaction = transition_rooms is not None and trigger == 'interaction'
        arrival = transition_rooms is not None and trigger == 'area_entry'
        initialization = transition_rooms is not None and trigger == 'initialization'
        if (trigger != 'ordinary' and not (interaction or arrival or initialization)) or selection.get('pointer_state') == 'null':
            if event.get('status') == 'resolved':
                raise ValueError(f'{owner!r} has an unsupported event trigger')
            continue
        if transition_rooms is not None and event.get('status') == 'source_only' and event.get('program_id') is None:
            continue
        if interaction:
            inherited_program = programs.get(event.get('program_id'), ({},))[0]
            inherited = inherited_program.get('owner_actors') is not None or inherited_program.get('owner_actor') is not None
            position = entity.get('position')
            classification = entity.get('classification')
            prop = (population.get('schema') == 'suikoden-scene-population/4' and entity.get('record_role') == 'event'
                    and entity.get('population_candidate') is False
                    and all(entity.get(key) is None for key in ('source_character_id', 'resource_id', 'resource_domain')))
            if not inherited and ((entity.get('population_candidate') is not True and not prop) or not isinstance(position, dict)
                    or position.get('placement') != 'placed' or not isinstance(classification, dict)
                    or classification.get('pointer_state') != 'present'):
                raise ValueError(f'{owner!r} has no placed interaction actor')
            if any(term.get('kind') not in (('story_mask_set', 'story_mask_clear', 'recruit_present', 'recruit_absent', 'stage_at_least', 'party_excludes') if with_campaign else ('story_mask_set', 'story_mask_clear'))
                   for term in object_rows(classification.get('terms'), 'classification.terms')):
                raise ValueError(f'{owner!r} has an unsupported interaction condition')
        program_id = event.get('program_id')
        if (selection.get('pointer_state') != 'present' or event.get('status') != 'resolved'
                or not isinstance(program_id, str) or program_id not in references):
            raise ValueError(f'{owner!r} references an unresolved program {program_id!r}')
        program, battles = programs[program_id]
        expected_trigger = trigger if interaction or arrival else 'none'
        if (program.get('entry') != ('initialization' if initialization else 'ordinary')
                or program.get('trigger') != expected_trigger
                or entity.get('source_order') != source_order or program.get('entity') != source_order):
            raise ValueError(f'{owner!r} does not own program {program_id!r}')
        if program_id in exit_programs:
            commands = program['commands']
            if not commands or commands[-1].get('kind') not in ('room_transition', 'world_transition') or commands[-1].get('destination') == binding['room']:
                raise ValueError('opening world exit must end in a transition to another room')
            exit_programs.remove(program_id)
        for index, encounter in battles:
            yield dict(room=binding['room'], owner=owner, program=program_id, command=index, encounter=encounter)
    if exit_programs:
        raise ValueError('opening world exit references an unowned program')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Install room event packets in a staged package')
    parser.add_argument('candidate', type=Path)
    parser.add_argument('sources', type=Path, nargs='+')
    args = parser.parse_args()
    bind_room_events(args.candidate, args.sources)
