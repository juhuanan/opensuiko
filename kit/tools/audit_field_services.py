#!/usr/bin/env python3
"""Inventory service requests in unresolved interactions and named field facilities."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct

from build_script_corpus import data_ranges, load_dialogue
from event_script_reachability import entry_roots, walk
from export_common import atomic_write, serialize
from export_first_room import source
from export_opening_field_package import ROOM_TO_SRC, field_service_overlay, scene, teleport_callback

ROOT = Path(__file__).resolve().parents[2]
PACKET = ROOT / 'game/assets/campaign/opening/field_events.json'
OPTIONAL_GAMES = ROOT / 'game/assets/hq/optional_games.json'
VIKI = ROOT / 'game/assets/travel/viki.json'
DISC_FILES = ROOT / 'kit/data/catalogs/extracted/iso_files.json'


def read_module_table(catalogue):
    data, provenance = source('MAIN.EXE')
    table = catalogue['core']['module_table']
    load_address, = struct.unpack_from('<I', data, 0x18)
    def file_offset(address):
        return 2048 + address - load_address
    modules = {}
    for row in table['entries']:
        selector = row['selector']
        pointer, = struct.unpack_from('<I', data, file_offset(table['va_number']) + selector * table['slot_stride'])
        size, lba = struct.unpack_from('<II', data, file_offset(pointer))
        if (size, lba) != (row['size'], row['lba']):
            raise ValueError(f'stale special-content module at selector {selector}')
        modules[selector] = {'file': row['path'], 'lba': lba, 'size': size}
    return modules, provenance


def catalogued_entries(rooms, families):
    entries = []
    for family in families:
        callers = []
        for caller in family['callers']:
            file, number = caller['path'], caller['room']
            data, provenance = source('/' + Path(file).name)
            site, operands = caller['site'], bytes.fromhex(caller['opcode_hex'])
            if (provenance['file'], provenance['sha256'], data[site:site + len(operands)]) != (file, caller['sha256'], operands):
                raise ValueError(f'stale {family["game"]} entry at {file}:{site:#x}')
            entity_root = scene.entities(data, scene.room_record(data, number))[caller['entity']]['stream_offsets'][2]
            if entity_root != caller['stream_offset']:
                raise ValueError(f'stale {family["game"]} event root at {file}:{site:#x}')
            binding = rooms.get((file, number))
            entity = None if binding is None else binding['population']['entities'][caller['entity']]
            callers.append({
                'source': provenance, 'source_room': number, 'entity': caller['entity'],
                'site': site, 'opcode_hex': caller['opcode_hex'],
                'package_room': None if binding is None else binding['room'],
                'package_event_status': None if entity is None else entity['event']['status'],
            })
        entries.append({'game': family['game'], 'runtime_ledger_status': family['entry_status'], 'callers': callers})

    admission = json.loads(VIKI.read_bytes())['admission']
    file, number = admission['source'], admission['room']
    data, provenance = source('/' + Path(file).name)
    transition = admission['transition']
    site = int(transition['offset'], 16)
    operands = bytes((0x43, transition['selector'], transition['index']))
    if provenance['file'] != file or data[site:site + len(operands)] != operands:
        raise ValueError('stale teleport entry')
    binding = rooms.get((file, number))
    teleport_callers = []
    for target in rooms.values():
        for program in target['content']['programs']:
            if not any(command.get('facility') == 'teleport' for command in program['commands']):
                continue
            area, room = ROOM_TO_SRC[target['room']]
            overlay, origin = source(area)
            entity = scene.entities(overlay, scene.room_record(overlay, room))[program['entity']]
            start = entity['stream_offsets'][2]
            offset = overlay.index(b'\x43\xff\x03\xfd', start, start + 40)
            callback = teleport_callback(overlay)
            if callback is None or entity['id'] != 97:
                raise ValueError(f'stale teleport callback for {target["room"]}')
            teleport_callers.append({
                'room': target['room'], 'entity': program['entity'], 'source': origin,
                'entry_offset': start, 'site': offset, 'callback_offset': callback,
            })
    return entries, {
        'source': provenance, 'source_room': number, 'site': site, 'opcode_hex': operands.hex(' '),
        'entity_indices': [actor['entity'] for actor in admission['actors']],
        'package_room': None if binding is None else binding['room'],
        'callers': teleport_callers,
    }


def audit(packet_bytes):
    packet = json.loads(packet_bytes)
    rooms = {(room['population']['source']['file'], room['population']['source']['room']): room for room in packet['rooms']}
    catalogue = json.loads(OPTIONAL_GAMES.read_bytes())
    modules, module_source = read_module_table(catalogue)
    minigames, teleport = catalogued_entries(rooms, catalogue['families'])
    dialogue = load_dialogue()
    disc_paths = {(row['lba'], row['size']): row['path'] for row in json.loads(DISC_FILES.read_bytes())}
    overlays = {}
    interactions = []
    for room in packet['rooms']:
        facilities = {
            program['entity']: command['facility']
            for program in room['content']['programs'] for command in program['commands']
            if command.get('facility') is not None
        }
        pending = [
            entity for entity in room['population']['entities']
            if entity['trigger'] == 'interaction'
            and entity['position']['placement'] == 'placed'
            and (entity['event']['status'] == 'source_only' or entity['source_order'] in facilities)
        ]
        if not pending:
            continue
        file, number = ROOM_TO_SRC[room['room']]
        if file not in overlays:
            data, provenance = source(file)
            overlays[file] = data, provenance, data_ranges(data, Path(file).name, dialogue)
        data, provenance, contexts = overlays[file]
        entities = scene.entities(data, scene.room_record(data, number))
        for entity in pending:
            index = entity['source_order']
            entry = entities[index]['stream_offsets'][2]
            graph = walk(data, [entry], contexts) if entry is not None else {'nodes': [], 'frontier': []}
            requests, special_content = [], []
            for node in graph['nodes']:
                offset = node['offset']
                if node.get('stop') or node.get('end') != offset + 3:
                    continue
                if node.get('opcode') == 0x43:
                    selector, argument = data[offset + 1:offset + 3]
                    request = {'offset': offset, 'selector': selector, 'argument': argument}
                    if selector == 0x80 and (overlay := field_service_overlay(data, argument)) is not None:
                        request['overlay'] = dict(overlay, file=disc_paths[overlay['lba'], overlay['size']])
                    requests.append(request)
                elif data[offset:offset + 2] == b'\x47\xff':
                    selector = data[offset + 2]
                    special_content.append({'offset': offset, 'selector': selector, 'module': modules.get(selector)})
            if special_content:
                root, = (root for root in entry_roots(data) if root['room'] == number and root['entry'] == index)
                if root['offset'] != entry:
                    raise ValueError(f'conflicting interaction pointers for {file} room {number} entity {index}')
            interactions.append({
                'room': room['room'], 'entity': index, 'file': provenance['file'],
                'facility': facilities.get(index),
                'entry_offset': entry, 'requests': requests, 'frontier': graph['frontier'],
                **({'special_content': special_content} if special_content else {}),
            })
    sources = [provenance for _, provenance, _ in overlays.values()]
    counts = Counter((request['selector'], request['argument'])
                     for interaction in interactions for request in interaction['requests'])
    return {
        'schema': 'suikoden-field-service-inventory/1',
        'scope': 'Placed source-only interactions and interactions bound to named facilities. Requests are statically possible and unresolved continuations are listed as frontiers. Catalogued minigame and teleport entries are also checked, including callers outside this placed-interaction set.',
        'packet_sha256': hashlib.sha256(packet_bytes).hexdigest(),
        'sources': sources,
        'interaction_count': len(interactions),
        'interactions_with_named_facilities': sum(row['facility'] is not None for row in interactions),
        'interactions_without_entry': sum(row['entry_offset'] is None for row in interactions),
        'interactions_with_requests': sum(bool(row['requests']) for row in interactions),
        'interactions_with_special_content': sum('special_content' in row for row in interactions),
        'interactions_with_frontiers': sum(bool(row['frontier']) for row in interactions),
        'request_counts': [{'selector': selector, 'argument': arg, 'count': count}
                           for (selector, arg), count in sorted(counts.items())],
        'interactions': [row for row in interactions if row['facility'] is not None or row['requests']
                         or 'special_content' in row or row['frontier'] or row['entry_offset'] is None],
        'special_content_module_source': module_source,
        'catalogued_minigames': minigames,
        'catalogued_teleport': teleport,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packet', type=Path, default=PACKET)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.packet.read_bytes())
    atomic_write(args.out, serialize(report))
    print(f"Audited {report['interaction_count']} interactions, with requests in {report['interactions_with_requests']}")


if __name__ == '__main__':
    main()
