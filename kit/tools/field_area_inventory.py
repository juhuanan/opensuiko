"""Discover mode-2 field room candidates across every source loader slot."""
import argparse
import json
from pathlib import Path

import area_entity_probe
import area_scene
from event_script_reachability import loader_file_slots
from export_first_room import source


def inventory():
    _, slots, files = loader_file_slots()
    areas = []
    for filename in sorted(files):
        data, origin = source(filename)
        extent = area_entity_probe.room_source_bound(data)
        probe = {room['index']: room for room in area_entity_probe.room_records(data)}
        rooms = []
        for room in area_scene.room_records(data):
            if extent['upper_bound'] is not None and room['record_off'] + area_scene.ROOM_RECORD_SIZE > extent['upper_bound']:
                continue
            section = area_scene.section_off(data, room['section'])
            other = probe.get(room['index'])
            agrees = other is not None and all(other[key] == room[key] for key in ('record_off', 'section'))
            rooms.append({'id': f"{Path(filename).stem.lower()}_room_{room['index']}",
                          'room': room['index'], 'record_offset': room['record_off'],
                          'section_offset': section, 'width': area_scene.u16(data, section) * 16,
                          'height': area_scene.u16(data, section + 2) * 16,
                          'independent_header_agreement': agrees})
        areas.append({'source': origin, 'loader_slots': [{'region': slot['region'], 'index': slot['index']}
                                                        for slot in slots if slot.get('file') == filename],
                      'room_extent': extent, 'rooms': rooms,
                      'frontier': 'no recognized field rooms; loader/header contract remains open' if not rooms else
                                  'room extent remains open' if extent['upper_bound'] is None else None})
    return {'schema': 'suikoden-field-area-inventory/1', 'areas': areas,
            'scope': 'all nonnull mode-2 loader references; individually validated room candidates within the existing 64-slot probe; '
                     'physical bounds and independent header agreement do not prove room reachability, event support or playable admission'}


def descriptors(report):
    """Feed the shared script/room discovery utility without a filename list."""
    return tuple((area['source']['file'], '/' + Path(area['source']['file']).name,
                  Path(area['source']['file']).stem,
                  tuple(room['room'] for room in area['rooms'] if room['independent_header_agreement']), {})
                 for area in report['areas'] if area['rooms'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    report = inventory()
    payload = json.dumps(report, indent=2) + '\n'
    if args.out:
        args.out.write_text(payload)
        print(f"Discovered {sum(len(area['rooms']) for area in report['areas'])} room candidates across {len(report['areas'])} loader files")
    else:
        print(payload, end='')


if __name__ == '__main__':
    main()
