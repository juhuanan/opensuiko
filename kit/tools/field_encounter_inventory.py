"""Read ordinary field encounter settings and picker inputs from mode-2 rooms."""

from collections import Counter
from pathlib import Path

import area_scene
import battle_placement
from event_script_reachability import build, loader_source_census
from export_first_room import source
import maindec
from war_text import decode


def inventory():
    # Check the room-to-section loader, picker, ready flag, counter, and rate arithmetic.
    anchors = {
        0x8013209C: 0x90420005, 0x801320AC: 0x8C430000, 0x801320B4: 0x8C620038,
        0x801320BC: 0xA020159A, 0x801320C8: 0x1440000B,
        0x801320F8: 0x90420000, 0x80132104: 0xA022159D, 0x80132108: 0x90620002,
        0x80132118: 0xA022159C, 0x8013211C: 0x10600007, 0x80132124: 0x0C050717,
        0x80132128: 0x34040019, 0x8013212C: 0x14400003, 0x80132138: 0xA022159A,
        0x800C1B9C: 0x80141D4C, 0x80141D58: 0x904201BB, 0x80141D60: 0x30420040,
        0x80171718 + 4 * 0x42: 0x801398F8, 0x80139918: 0x0C050605,
        0x800C1B24: 0x80141BE8, 0x80141BF4: 0x906201BB, 0x80141BFC: 0x38420040,
        0x80141C04: 0xA06201BB, 0x80127A18: 0x908301BB, 0x80127A20: 0x30620040,
        0x80127A24: 0x10400002, 0x80127A28: 0x38620040, 0x80127A2C: 0xA08201BB,
        0x80139594: 0x0C04B2EF, 0x8012CBD0: 0x34420004, 0x8012CBD4: 0xA0620037,
        0x8012CC4C: 0x90620037, 0x8012CC54: 0x30420004, 0x8012CC58: 0x14400033,
        0x8012CC64: 0x9042159A, 0x8012CCD0: 0x0C04E1E7, 0x8012CD28: 0x0C04B2FD,
        0x8012CCA8: 0x0043102A, 0x8012CCE0: 0x304200FF,
        0x8012CD04: 0x8C440004, 0x8012CD08: 0x0C04988A, 0x8012CD60: 0xA0600036,
        0x80126258: 0x8E460008, 0x801262E4: 0x8C460000, 0x8012636C: 0x90420010,
        0x801387AC: 0x3403007F, 0x801387B0: 0x0043001A, 0x801387D8: 0x00001012,
        0x80131444: 0xA0600036, 0x80131480: 0xAC400030, 0x80132954: 0x14400079,
        0x8013295C: 0x0C04B30E, 0x8013296C: 0x0C04B2C4, 0x80132A64: 0x3042F000,
        0x80132A94: 0xA0620036, 0x80132AE8: 0x24630001, 0x80132B20: 0xACA30030,
        0x8012CC14: 0xAC400030,
    }
    for pc, word in anchors.items():
        if maindec.mword(pc) != word:
            raise ValueError(f'ordinary field encounter instruction changed at {pc:#x}')

    overlays = loader_source_census()['overlays']
    configurations, directories, rooms = {}, {}, []
    toggle_command = bytes((0x42, 0x19))
    toggle_candidates = {}
    for overlay in overlays:
        path = overlay['file']
        raw, provenance = source(path)
        if toggle_command in raw:
            toggle_candidates[path] = raw
        bound = overlay['room_source_bound']['upper_bound']
        for room in area_scene.room_records(raw):
            if bound is not None and room['record_off'] >= bound:
                continue
            section = area_scene.section_off(raw, room['section'])
            row = dict(source_file=path, room=room['index'], room_offset=room['record_off'],
                       section=room['section'], bound=bound, configuration=None)
            rooms.append(row)
            if not area_scene.in_file(raw, section + 0x38, 4):
                row['status'] = 'section_out_of_bounds'
                continue
            address = area_scene.u32(raw, section + 0x38)
            if address == 0:
                row['status'] = 'no_configuration'
                continue
            config_key = f'{path}#{address:08x}'
            row['configuration'] = config_key
            if config_key not in configurations:
                configurations[config_key] = configuration(raw, provenance, address, directories)
            row['status'] = configurations[config_key]['status']

    toggle_sites = []
    for graph in build([Path(path).name for path in toggle_candidates])['overlays']:
        raw = toggle_candidates[graph['file']]
        for node in graph['nodes']:
            offset = node['offset']
            if node.get('opcode') == 0x42 and raw[offset:offset + 2] == toggle_command:
                toggle_sites.append(dict(source_file=graph['file'], offset=offset))
    trigger_controls = dict(
        story_suppression=dict(scenario_byte=43, mask=0x40, ui_selector=0x19, sampled_on='room_load',
                               cleared_on='world_entry', candidate_toggle_sites=toggle_sites),
        explicit_battle=dict(opcode=0x47, operand='encounter_index', transition_mask=0x04,
                             skips_ordinary_picker=True),
    )
    counts = Counter(row['status'] for row in rooms)
    return dict(schema='suikoden-field-encounter-inventory/2',
                scope='Mode-2 loader overlays and structurally valid room records within available physical bounds. '
                      'Toggle sites come from bounded entry-rooted graphs. Gameplay feasibility and runtime admission remain open.',
                summary=dict(overlays=len(overlays), room_records=len(rooms), room_status=dict(sorted(counts.items())),
                             configurations=len(configurations), directories=len(directories),
                             formations=sum(len(row.get('formations', ())) for row in directories.values()),
                             unresolved_battlefields=sum('battlefield_error' in row for row in directories.values())),
                trigger_controls=trigger_controls, rooms=rooms, configurations=configurations, directories=directories)


def configuration(raw, provenance, address, directories):
    path = provenance['file']
    result = dict(source=provenance, address=hex(address))
    offset = area_scene.to_file(raw, address)
    if offset is None or not area_scene.in_file(raw, offset, 8):
        return dict(result, status='external_configuration')
    rate, threshold = raw[offset], raw[offset + 2]
    directory = area_scene.u32(raw, offset + 4)
    key = f'{path}#{directory:08x}'
    result.update(rate=rate, counter_threshold=threshold, directory=key, source_offset=offset)
    if key not in directories:
        directories[key] = read_directory(raw, path, directory)
    status = 'zero_rate' if rate == 0 else directories[key]['status']
    return dict(result, status=status)


def read_directory(raw, path, address):
    result = dict(source_file=path, address=hex(address))
    directory = area_scene.to_file(raw, address)
    if directory is None or not area_scene.in_file(raw, directory, 24):
        return dict(result, status='external_directory')
    base = area_scene.RAM_BASE
    selectors, formations = battle_placement.directory_encounters(raw, directory, base)
    enemies = {}
    for formation in formations:
        for slot in formation['slots']:
            offset = slot['stats_offset']
            if slot['enemy_id'] not in enemies:
                enemies[slot['enemy_id']] = dict(id=slot['enemy_id'], offset=offset, level=raw[offset + 0x10],
                                                   name=decode(raw[offset:offset + 16], length=16)[0].strip())
        formation['enemy_level_sum'] = sum(enemies[slot['enemy_id']]['level'] for slot in formation['slots'])
        flags = area_scene.u32(raw, formation['descriptor_offset'] + 0x0C)
        formation['archive'] = 'boss' if flags & 0x40000000 else 'standard'
        formation['escape_allowed'] = not bool(flags & 0x80000000)
    result.update(status='resolved', selectors_offset=selectors, formations=formations,
                  enemies=[enemies[id] for id in sorted(enemies)])
    try:
        result['battlefield'] = battle_placement.directory_battlefield(raw, directory, base)
    except ValueError as error:
        result['battlefield_error'] = str(error)
    return result
