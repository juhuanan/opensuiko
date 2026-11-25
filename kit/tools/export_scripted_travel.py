#!/usr/bin/env python3
"""Export source world auto-routes, Kaku's first crossing and headquarters progression."""
from pathlib import Path
from functools import cache
import hashlib
import json
import struct

import area_scene as scene
import maindec
from export_common import run_exporter, serialize
from export_first_room import source
from export_scene_population import decode_predicate
from event_script_decode import decode_stream

ROOT = Path(__file__).resolve().parents[2]
DIRECTIONS = ('north', 'east', 'south', 'west')
MAIN_SHA256 = '439a166609dab8cde26249bd7661a835e4d55e79bb37a964761c981524e89d95'
VB2_SHA256 = 'cff3f996221e90b6b2571570e8ecda957ed24f4153e438bd255dcf879db0d442'
RUINS_ROOMS = (0, *range(9, 20))
HQ_ROOMS = (2, 4, 5)
KOUAN_ROOMS = (0, 2, 11, 12, 13, 14, 15, 20)
FOUNDED_ROOMS = {'/VB5A2.BIN': (0, 3), '/VB5A1.BIN': (0, 6, 7), '/VB5AG.BIN': (0, 1, 7)}
CASTLE_SOURCES = {'/VB5.BIN': 'bcbec83e79544720ff347e426dbbb2353d9594cdffe2da7e51c55b08a488d127',
                  '/VB7.BIN': '856d167cc3e07de83136d1356dc5a51e95d3287bb6034b4ccb384a6395834521',
                  '/VB5A2.BIN': '809159ba5816345f3314a3dec50c2a1e4cedd54f1086ed412ea5530a18d423d3',
                  '/VB5A1.BIN': 'd395ea052942a878faac6fa10c23985792fb0b0a8cd803d397ace03448c65e0c',
                  '/VB5AG.BIN': '23713bd10a536e6ac0cbf0832e9bcd80af64fc27b690da973a216caa9f2dd52d'}


@cache
def first_teo_war_return():
    """Region, area, room and arrival cells set by Teo's first war completion."""
    raw, proof = source('/WAR_TEO1.BIN')

    def word(address):
        return struct.unpack_from('<I', raw, address - 0x80010000)[0]

    anchors = {
        0x80010004: 0x80010368, 0x8001002C: 0x800104B8, 0x800104A8: 0x0C00961E,
        0x800258AC: 0x242102FC, 0x8001033C: 0x8002620C,
        0x800261F8: 0x34020010, 0x80026200: 0xAC228B04,
        0x8002627C: 0x8C63DB24, 0x80026284: 0xA0620002,
        0x8002628C: 0x8C63DB24, 0x80026294: 0xA0620000,
        0x8002629C: 0x8C42DB24, 0x800262A4: 0xA0400001,
        0x800262AC: 0x8C63DB24, 0x800262B0: 0x34020009, 0x800262B8: 0xAC228B44,
        0x800262C0: 0xA4620004, 0x800262C4: 0x080098CC, 0x800262C8: 0xA4620006,
    }
    if any(word(address) != expected for address, expected in anchors.items()):
        raise ValueError(f"{proof['file']}: battle return instructions changed")
    values = [word(address) for address in (0x80026280, 0x80026290, 0x800262BC)]
    if any(value >> 16 != 0x3402 for value in values):
        raise ValueError('Teo battle return operands are no longer immediate')
    region, area, cell = (value & 0xFFFF for value in values)
    return region, area, 0, cell, cell


def _overlay_return_operands(path: str, anchors: dict[int, int], ori_checks: dict[int, int]):
    """Verify overlay return instructions and decode ``ori`` immediate operands."""
    raw, proof = source(path)

    def word(address: int) -> int:
        return struct.unpack_from('<I', raw, address - 0x80010000)[0]

    if any(word(address) != expected for address, expected in anchors.items()):
        raise ValueError(f"{proof['file']}: battle return instructions changed")
    out = {}
    for address, expected_opcode in ori_checks.items():
        value = word(address)
        if value >> 16 != expected_opcode:
            raise ValueError(f"{proof['file']}: return operand at {address:#x} changed")
        out[address] = value & 0xFFFF
    return out


@cache
def second_teo_war_return():
    """Region, area, room and arrival cells set by Teo's second war completion."""
    ops = _overlay_return_operands(
        '/WAR_TEO2.BIN',
        {
            0x80026458: 0x3C028018, 0x8002645C: 0x8C42DB24,
            0x80026464: 0xA0440002, 0x8002646C: 0x8C63DB24,
            0x80026474: 0xA0620000, 0x80026484: 0xA0440001,
            0x800264A0: 0xA4620004, 0x800264A8: 0xA4620006,
        },
        {0x80026460: 0x3404, 0x80026470: 0x3402, 0x8002649C: 0x3402},
    )
    region_and_room = ops[0x80026460]
    return region_and_room, ops[0x80026470], region_and_room, ops[0x8002649C], ops[0x8002649C]


@cache
def northern_checkpoint_war_return():
    """Region, area, room and arrival cells set by the Northern Checkpoint war."""
    ops = _overlay_return_operands(
        '/WAR_KITA.BIN',
        {
            0x80026CD0: 0x8C63DB24, 0x80026CD8: 0xA0620002,
            0x80026CE0: 0x8C63DB24, 0x80026CE8: 0xA0620000,
            0x80026CF8: 0xA0400001, 0x80026D14: 0xA4620004,
            0x80026D20: 0xA4620006,
        },
        {0x80026CD4: 0x3402, 0x80026CE4: 0x3402, 0x80026D10: 0x3402, 0x80026D18: 0x3402},
    )
    return ops[0x80026CD4], ops[0x80026CE4], 0, ops[0x80026D10], ops[0x80026D18]


@cache
def shasarazade_war_return():
    """Region, area, room and arrival cells set by the Shasarazade war."""
    ops = _overlay_return_operands(
        '/WAR_SHAS.BIN',
        {
            0x80026CD0: 0x8C63DB24, 0x80026CD8: 0xA0620002,
            0x80026CE8: 0xA0400000, 0x80026CF8: 0xA0400001,
            0x80026D14: 0xA4620004, 0x80026D20: 0xA4620006,
        },
        {0x80026CD4: 0x3402, 0x80026D10: 0x3402, 0x80026D18: 0x3402},
    )
    return ops[0x80026CD4], 0, 0, ops[0x80026D10], ops[0x80026D18]


@cache
def gregminster_war_return():
    """Region, area, room and arrival cells set by the final Gregminster war."""
    ops = _overlay_return_operands(
        '/WAR_LAST.BIN',
        {
            0x80026CD0: 0x8C42DB24, 0x80026CD8: 0xA0400002,
            0x80026CE0: 0x8C63DB24, 0x80026CE8: 0xA0620000,
            0x80026CF8: 0xA0620001, 0x80026D14: 0xA4620004,
            0x80026D1C: 0xA4620006,
        },
        {0x80026CE4: 0x3402, 0x80026CF4: 0x3402, 0x80026D10: 0x3402},
    )
    return 0, ops[0x80026CE4], ops[0x80026CF4], ops[0x80026D10], ops[0x80026D10]


@cache
def golden_hydra_battle_return():
    """Region, area, room and arrival cells set after defeating Golden Hydra."""
    ops = _overlay_return_operands(
        '/VZV.BIN',
        {
            0x800101D8: 0x3C05801B, 0x800101EC: 0x34A58000,
            0x80010200: 0xA0228002, 0x80010208: 0xA0A20000,
            0x80010214: 0xA0228001, 0x80010220: 0xA4228004,
            0x8001022C: 0xA4228006, 0x800102C4: 0x3C038003,
            0x800102C8: 0x246394D8,
        },
        {
            0x800101F8: 0x3402, 0x80010204: 0x3402, 0x8001020C: 0x3402,
            0x80010218: 0x3402, 0x80010224: 0x3402,
        },
    )
    return ops[0x800101F8], ops[0x80010204], ops[0x8001020C], ops[0x80010218], ops[0x80010224]


@cache
def ruins_audio_requests():
    main, origin = source('MAIN.EXE')
    if origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported ruins audio source identity')
    base = struct.unpack_from('<I', main, 24)[0]
    result = {}
    for selector, expected, kind in ((6, 0x14, 'queued_stop'), (7, 0x15, 'global_stop'), (53, 0x40e, 'stream'),
                                      (96, 0x439, 'stream'), (117, 0x508, 'sound')):
        address = 0x80171c2c + selector * 2
        request = struct.unpack_from('<H', main, 2048 + address - base)[0]
        independent = maindec.mword(address & ~3) >> ((address & 3) * 8) & 65535
        if request != expected or request != independent:
            raise ValueError('ruins audio table readers disagree')
        result[selector] = {'selector': selector, 'table_address': address,
                            'request': request, 'kind': kind}
        if kind == 'sound':
            descriptor = struct.unpack_from('<HBB', main, 2048 + 0x801651dc - base)
            if descriptor != (0, 32, 20) or maindec.mword(0x801651dc) != 0x14200000:
                raise ValueError('ruins passage sound descriptor changed')
            result[selector]['command'] = {'kind': 'play_sound', 'cue': request}
        else:
            result[selector]['command'] = {'kind': 'field_music', 'music': {
                'queued_stop': 'fade', 'global_stop': 'stop', 'stream': 'ruins' if request == 0x40e else 'lakeshore'}[kind]}
    words = {0x80142460: 0x10830015, 0x80142470: 0x2c420245,
             0x80142480: 0xa4251e22, 0x80142494: 0x2c420002,
             0x801424ac: 0xa4231e22, 0x800c5548: 0x34050004,
             0x800c554c: 0x0c031a80, 0x800c5554: 0x0c0321f9,
             0x800c557c: 0x0c031439, 0x800c5598: 0x0c0322dc,
             0x800c6a8c: 0x0044102a, 0x800c6ab4: 0x18400050,
             0x800c6afc: 0x00621023, 0x800c6be4: 0x92620002,
             0x800c6bec: 0x0202102a, 0x800c6bf0: 0x1440ffba,
             0x800c08d4: 0x800c51f8, 0x800c08d8: 0x800c538c,
             0x800c520c: 0x34050004, 0x800c5210: 0x0c031a80,
             0x800c5218: 0x0c0321f9, 0x800c5240: 0x080314e6}
    for address, expected in words.items():
        if struct.unpack_from('<I', main, 2048 + address - base)[0] != expected or maindec.mword(address) != expected:
            raise ValueError('ruins music cache/stop consumer changed')
    return result


def ruins_door(data, room, entity_index, file='/VB5.BIN'):
    from export_first_room import area_room_walkable_grid
    if file not in CASTLE_SOURCES or hashlib.sha256(data).hexdigest() != CASTLE_SOURCES[file]:
        raise ValueError('unsupported ruins identity')
    table = scene.room_table(data)
    upper = scene.ptr_at(data, scene.root(data) + 20)
    if (file == '/VB5.BIN' and (upper - table != 20 * 16 or room not in RUINS_ROOMS)
            or file == '/VB7.BIN' and (table != 0x74 or room not in HQ_ROOMS)):
        raise ValueError('ruins room table bound changed')
    entity = scene.entities(data, scene.room_record(data, room))[entity_index]
    if entity['flags'] != 0:
        return None
    rows = []
    for row in decode_stream(data, entity['stream_offsets'][2], max_insns=8):
        rows.append(row)
        if row[1] == 0xfd:
            break
    if len(rows) < 2 or rows[-1][1] != 0xfd or rows[-2][1] != 3 or any(row[1] != 0x41 for row in rows[:-2]):
        return None
    warp = rows[-2][2]
    destination_file = file
    if len(warp) == 3:
        destination, x, y = warp
    elif len(warp) == 5 and warp[0] == 0xfc and warp[1] in (4, 6):
        destination_file = {4: '/VB5.BIN', 6: '/VB7.BIN'}[warp[1]]
        destination, x, y = warp[2:]
        target_data, origin = source(destination_file)
        for region in (1, 9):
            descriptor = maindec.mword(maindec.mword(0x8016f67c + region * 4) + warp[1] * 4)
            if struct.unpack_from('<II', maindec.body(), descriptor - maindec.MBASE) != (origin['size'], origin['lba']):
                raise ValueError('cross-module passage descriptor disagrees with extraction')
    else:
        return None
    if destination not in (RUINS_ROOMS if destination_file == '/VB5.BIN' else HQ_ROOMS):
        return None
    cursor = entity['stream_offsets'][2]
    music = []
    while data[cursor] == 0x41:
        music.append(data[cursor + 1])
        cursor += 2
    end = cursor + 1 + len(warp)
    if data[cursor] != 3 or data[cursor + 1:end] != warp or data[end] != 0xfd or end != rows[-1][0] or music != [row[2][0] for row in rows[:-2]]:
        raise ValueError('independent literal-door decode disagrees or leaves bytes')
    target_data = data if destination_file == file else target_data
    if hashlib.sha256(target_data).hexdigest() != CASTLE_SOURCES[destination_file]:
        raise ValueError('passage destination identity changed')
    target = scene.room_record(target_data, destination)
    width, height, cells = area_room_walkable_grid(target_data, scene.section_off(target_data, target['section']), destination_file, destination)
    if not (0 <= x < width and 0 <= y < height):
        raise ValueError('source doorway spawn is outside its destination; do not snap it')
    target_walkable = cells[y * width + x] == '1'
    predicate, _ = decode_predicate(data, entity['stream_offsets'][1], 'event', coordinate_ranges=True)
    if {term['kind'] for term in predicate['terms']} != {'coordinate_range'}:
        raise ValueError('ruins doorway selection changed')
    return {'room': room, 'entity': entity_index, 'stream_offset': entity['stream_offsets'][2],
            'consumed': rows[-1][0] + 1 - entity['stream_offsets'][2],
            'source_music_selectors': [row[2][0] for row in rows[:-2]],
            'audio_requests': [dict(ruins_audio_requests()[row[2][0]], offset=row[0]) for row in rows[:-2]],
            'selection': predicate['terms'], 'destination': destination, 'destination_file': destination_file,
            'target_walkable': target_walkable,
            'spawn_pixels': [x * 8, y * 8]}


def founded_door(data, file, room, entity_index):
    if file not in FOUNDED_ROOMS or room not in FOUNDED_ROOMS[file] or hashlib.sha256(data).hexdigest() != CASTLE_SOURCES[file]:
        raise ValueError('unsupported founded headquarters doorway source')
    entity = scene.entities(data, scene.room_record(data, room))[entity_index]
    if entity['flags'] != 0 or entity['stream_offsets'][2] is None:
        return None
    start = entity['stream_offsets'][2]
    rows = decode_stream(data, start, max_insns=2)
    if len(rows) != 2 or rows[0][1] != 3 or rows[1][1] != 0xfd:
        return None
    args = rows[0][2]
    destination_file = file
    descriptor_reads = []
    if len(args) == 3 and args[0] < 128:
        target_room, x, y = args
    elif len(args) == 5 and args[0] == 252 and args[1] in (32, 33, 34):
        destination_file = {32: '/VB5AG.BIN', 33: '/VB5A1.BIN', 34: '/VB5A2.BIN'}[args[1]]
        target_room, x, y = args[2:]
        main, origin = source('MAIN.EXE')
        if origin['sha256'] != MAIN_SHA256:
            raise ValueError('unsupported founded headquarters loader identity')
        base = struct.unpack_from('<I', main, 24)[0]
        def word(address):
            value = struct.unpack_from('<I', main, 2048 + address - base)[0]
            if value != maindec.mword(address):
                raise ValueError('independent headquarters descriptor readers disagree')
            return value
        _, target_origin = source(destination_file)
        for region in (1, 9):
            table = word(0x8016f67c + region * 4)
            descriptor = word(table + args[1] * 4)
            if (word(descriptor), word(descriptor + 4)) != (target_origin['size'], target_origin['lba']):
                raise ValueError('founded headquarters doorway resolves to a different file')
            descriptor_reads.append({'region': region, 'table': table, 'descriptor': descriptor})
    else:
        return None
    if target_room not in FOUNDED_ROOMS[destination_file]:
        return None
    end = start + 1 + len(args)
    if data[start:end + 1] != bytes([3]) + args + b'\xfd' or rows[1][0] != end:
        raise ValueError('independent headquarters doorway operand walk disagrees')
    predicate, _ = decode_predicate(data, entity['stream_offsets'][1], 'event', coordinate_ranges=True)
    if not predicate['terms'] or any(term['kind'] != 'coordinate_range' for term in predicate['terms']):
        return None
    target, target_origin = source(destination_file)
    if target_origin['sha256'] != CASTLE_SOURCES[destination_file]:
        raise ValueError('founded headquarters destination identity changed')
    from export_first_room import area_room_walkable_grid
    record = scene.room_record(target, target_room)
    width, height, cells = area_room_walkable_grid(target, scene.section_off(target, record['section']), destination_file, target_room)
    if x >= width or y >= height:
        raise ValueError('headquarters doorway spawn is outside its destination')
    return {'source': source(file)[1], 'room': room, 'entity': entity_index, 'offset': start,
            'end': end + 1, 'bytes': data[start:end + 1].hex(), 'selection': predicate['terms'],
            'destination_source': target_origin, 'destination_file': destination_file, 'destination': target_room,
            'destination_room': f'{destination_file[1:-4].lower()}_room_{target_room}',
            'spawn_pixels': [x * 8, y * 8], 'target_walkable': cells[y * width + x] == '1',
            'descriptors': descriptor_reads}


def hq_entry_music():
    data, origin = source('/VB7.BIN')
    if origin['sha256'] != CASTLE_SOURCES['/VB7.BIN']:
        raise ValueError('unsupported headquarters initializer identity')
    entity = scene.entities(data, scene.room_record(data, 4))[3]
    start = entity['stream_offsets'][2]
    fragment = bytes.fromhex('30 41 2a 31 fd')
    if entity['flags'] != 16 or start != 0x14c or data[start:start + 5] != fragment:
        raise ValueError('headquarters music initializer changed')
    rows = list(decode_stream(data, start, max_insns=4))
    if [(pc - start, op, args) for pc, op, args, _ in rows] != [(0, 0x30, b''), (1, 0x41, b'\x2a'), (3, 0x31, b''), (4, 0xfd, b'')]:
        raise ValueError('independent initializer boundary check disagrees')
    main, main_origin = source('MAIN.EXE')
    base = struct.unpack_from('<I', main, 24)[0]
    address = 0x80171c2c + 42 * 2
    request = struct.unpack_from('<H', main, 2048 + address - base)[0]
    if main_origin['sha256'] != MAIN_SHA256 or request != 0x403 or maindec.mword(address) & 65535 != request:
        raise ValueError('headquarters music request readers disagree')
    return {'source': origin, 'room': 4, 'entity': 3, 'offset': start, 'bytes': fragment.hex(),
            'consumed': len(fragment), 'selector': 42, 'request': request, 'stream': 3,
            'program': {'entry': 'initialization', 'entity': 3, 'trigger': 'none',
                        'commands': [{'kind': 'field_music', 'music': 'headquarters'}, {'kind': 'end_stream'}]},
            'scope': 'one initializer pump; named field selection; original loader cadence and playback remain unqualified'}


def hq_effect_callbacks():
    from export_spell_scenes import effect_sine
    main, origin = source('MAIN.EXE')
    if origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported founding effect source identity')
    base = struct.unpack_from('<I', main, 24)[0]
    spans = ((0x801352e8, 0x80135534, 'f5ef0d34a27643d23130daa45476362796eab3cff4bb7dc6bbda8371c22b5bd1'),
             (0x801355ec, 0x80135884, '073508948fa3cf13f48be05191b769b55674a890000733ef804dd3e16947de31'),
             (0x80135884, 0x80135b20, '35b2b0a109c9e767cbddc11f78cf801d12081a809e773b6047025ae1aefcfb6d'),
             (0x80135534, 0x801355ec, 'c87f892ad684a8a1f2aeabf0b44cde1ee95856f62b6b91794c87b4bb144d519e'),
             (0x8014e194, 0x8014e254, '4b95da0b7625e0df788d94cfdfacf8060a6465fffa4232532dc6e89f3b2a7eb5'),
             (0x8014c850, 0x8014c8e4, 'e895d5fb7b209168b58dda5241ad74875286e14638c4e199c78ba3cb546dd100'),
             (0x80150810, 0x8015099c, 'a5b336611796e248eddc735d0a600902a12d12ee8039c77f63ba70b6135414ee'),
             (0x8014aeb0, 0x8014aec4, '31ff5a88a5ad8974879601f71f5f1d0defd5ee35ba90a87b07149060fa7a4457'),
             (0x8014b4ec, 0x8014b6b0, '30d2584af5b91b6ecc9744ad62a2c6dc16b4ab98c29e6b8c9e4d76c147d77293'),
             (0x800c4044, 0x800c4080, '70e097b0bd0c7719004aef3e870f97d3c5e6d992cf4d453b40c1d157e2e85712'),
             (0x8014ab0c, 0x8014abd4, '3a88772c86d58b79f83f1c9835f9a44ee1981e57ca7e95120f28a82325679023'),
             (0x80146030, 0x801465b0, '2e0d4c6df7499fa221edc31cba3e39205db13c689b9d006a0fb963fcf973da66'),
             (0x801465b0, 0x80146934, '391c5e47074513e9c1e5550c41190461ee57aca23278fdee0b4df92250102843'),
             (0x80144e8c, 0x80145194, '8e6cb2f57664df41bdb0cd5362efb96cba336946dcb225de59ec6f6869d00985'),
             (0x8013f4b8, 0x8013f6b4, '71f3b8a7686e665d8525ced40ff162fa71460fa4961e7374535473194cab4a94'),
             (0x8014bdf4, 0x8014bf6c, 'd3f5914417dd165311c1d9a40bdcfccab4f4df1bbaca9d9b1920ebcd657c85b0'),
             (0x8014c8e4, 0x8014ce80, 'cf4b9f1f6172e68c5f23691063787c693fd1ad61f301a88b2395e68c57b6275e'))
    bodies = []
    for start, end, digest in spans:
        raw = main[2048 + start - base:2048 + end - base]
        independent = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(start, end, 4))
        if raw != independent or hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError('independent founding callback body reads disagree')
        bodies.append({'start': start, 'end': end, 'sha256': digest})
    words = {0x801716bc: 0x8013584c, 0x801716c4: 0x80135ae8,
             0x80135324: 0xa4400000, 0x80135328: 0xa4500002, 0x8013532c: 0xa4510004,
             0x80135690: 0x2c620015, 0x80135814: 0x2442ffeb,
             0x80135818: 0x00021040, 0x80135810: 0x34030080,
             0x80135824: 0x0c04d4d1, 0x80135980: 0x2c620014,
             0x80135a14: 0x14620015, 0x801359fc: 0x3402000f,
             0x80135a80: 0x2c420010, 0x80135abc: 0xa4800000,
             0x80135ac4: 0x24425900, 0x80135934: 0x2c420004,
             0x80135940: 0x0c04d4d1,
             0x80132b98: 0x0c04fc44, 0x8013f12c: 0x0c04f80a,
             0x8013f148: 0x0c04fb5b, 0x8013f168: 0x0c04fe58,
             0x80132c04: 0x8c62049c, 0x80132c14: 0x0040f809,
             0x80138a2c: 0x30428000, 0x80138a30: 0x10400014, 0x80138a34: 0x2462ffff}
    words.update({0x801357ac: 0x00003021, 0x801359c4: 0x00003021,
                  0x8014e1c0: 0xa0820004, 0x8014e1cc: 0xa0820005,
                  0x8014e1d0: 0x00031743, 0x8014e1d4: 0x30420002,
                  0x8014e1dc: 0x34420040, 0x8014e1e0: 0xa0820007,
                  0x8014e22c: 0x34070003, 0x8014e234: 0x0c053214,
                  0x801358e8: 0x0c052d3b, 0x801358ec: 0x00003021,
                  0x8014aeb8: 0x34020038, 0x8014aec0: 0xa0820007,
                  0x8014b690: 0x0c053214, 0x8014c8ac: 0x8c640000,
                  0x8014c8b4: 0xae040000, 0x8014c8bc: 0xac700000,
                  0x800c4044: 0x00002821, 0x800c4074: 0x0c052ac3})
    words.update({0x801461a0: 0xafa00010, 0x80146680: 0xafa00010,
                  0x80146280: 0x00002821, 0x80146728: 0x00002821,
                  0x80144fa0: 0x00002821, 0x80144fb0: 0xa6020016,
                  0x8013f524: 0x3c030100, 0x8013f528: 0xac430000,
                  0x8013f4a0: 0x0c053239, 0x8013f4a4: 0x34060001,
                  0x8014be40: 0x000c25c2, 0x8014be44: 0x30840060,
                  0x8014c9b4: 0x001115c2, 0x8014c9b8: 0x30420060})
    for address, expected in words.items():
        actual = struct.unpack_from('<I', main, 2048 + address - base)[0]
        if actual != expected or maindec.mword(address) != actual:
            raise ValueError(f'founding effect boundary changed at {address:08x}')
    quarter_bytes = main[2048 + 0x801765bc - base:2048 + 0x80176dbe - base]
    quarter_hash = hashlib.sha256(quarter_bytes).hexdigest()
    if quarter_hash != 'bab3b71ba7f79dfb2b5cebb71f8382a79606a958d72031bc11b88066c36033bd':
        raise ValueError('founding quarter-wave table changed')
    quarter = struct.unpack('<1025h', quarter_bytes)
    rays = []
    for index in range(180):
        angle = index * 4096 // 360
        pair = [quarter[min(angle, 2048 - angle)],
                quarter[1024 - angle] if angle <= 1024 else -quarter[angle - 1024]]
        if pair != [effect_sine(angle), effect_sine(angle + 1024)]:
            raise ValueError('independent founding trigonometry disagrees')
        rays.append(pair)
    return {'source': origin, 'bodies': bodies,
            'quarter_wave': {'address': 0x801765bc, 'size': len(quarter_bytes), 'sha256': quarter_hash},
            'rays_q12': rays,
            'scatter': {'selector': 0, 'draw_ages': [0, 84], 'spread_ages': [0, 20],
                        'fade_ages': [21, 84], 'completion_invocation': 85},
            'collapse': {'selector': 2, 'draw_ages': [0, 19], 'flash_start_age': 15,
                         'flash_narrowing_ages': [16, 19], 'handoff_age': 20,
                         'tail_ages': [0, 3], 'completion_invocation': 25},
            'geometry': {'ray_count': 180, 'ray_center_offset': [8, -8],
                         'scatter_radius': 25, 'scatter_horizontal_step': 32,
                         'scatter_vertical_origin': -82, 'scatter_vertical_split': 90,
                         'collapse_radius_start': 25, 'collapse_radius_step': -1,
                         'flash_offset_from_ray_center': [-8, -16], 'flash_size': [16, 240],
                         'flash_widths': [14, 12, 10, 8, 6, 4, 2, 0],
                         'ray_submission_order': 'ascending; shared ordering-table bucket reverses submissions',
                         'flash': 'opaque white, submitted after rays on collapse ages16..19 and therefore drawn before them; no draw on handoff',
                         'semi_transparency': 'scatter ages21..84 and all collapse rays; draw-mode blend is qualified per caller'},
            'gpu_submission': {'ordering_index': 0, 'line_codes': [0x40, 0x42], 'line_words': 3,
                               'line_color': 'one flat RGB value copied from descriptor bytes12..14',
                               'flash_code': 0x38, 'flash_words': 8, 'flash_color': [255, 255, 255],
                               'gpu_order': 'flash when present, then rays179..0; shared bucket insertion prepends each packet',
                               'normal_field_sprite_blend_selector': 0,
                               'normal_dialogue_writers': {'glyph_descriptor_flags': 0, 'border_blend_selector': 0,
                                                           'portrait_descriptor_flags': 0x01000000,
                                                           'portrait_ordering_index': 1,
                                                           'descriptor_blend_bits': 'flags bits28..29; E1 bits5..6'},
                               'native_renderer': {'packet': 36, 'requires': 'explicit field_effect_blend=half on IR14 room data',
                                                   'scope': 'flash first; reverse ray order; half source plus half destination with canvas alpha retained; normal founding caller declares half blending'},
                               'blend_scope': 'line/flash packets retain inherited draw mode; hq_founding qualifies the bounded normal field caller separately'},
            'driver_order': 'script pump, scroll/motion and text callback inside8013F110, then area callback at80132C14; a new effect advances in its installation update',
            'scope': 'callback invocation boundaries and geometry with a gated runtime owner; normal founding rendering is bound separately; native output remains unverified'}


@cache
def party_recovery_rules():
    main, main_origin = source('MAIN.EXE')
    base = struct.unpack_from('<I', main, 24)[0]
    if main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported party recovery identity')
    bodies = []
    for start, end, digest in (
            (0x80138ce0, 0x80138d74, '179135210e54356514d5c7ea88e89c297d0fde487e5d257354d6f364904e7bc7'),
            (0x800ca60c, 0x800ca66c, 'f5a794b04475ec1950161a1d51091722633c6c188a11fe7ee010f3d45f290972'),
            (0x8016a60c, 0x8016a630, '45680a1d5fd9597e60e2d2d0273f2a916aa78500f8d103185714d13d90d5cbe8')):
        raw = main[2048 + start - base:2048 + end - base]
        independent = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(start, end, 4))
        if raw != independent or hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError('independent recovery source readers disagree')
        bodies.append({'start': start, 'end': end, 'sha256': digest})
    thresholds = list(main[2048 + 0x8016a60c - base:2048 + 0x8016a630 - base])
    tiers = [thresholds[tier * 9:(tier + 1) * 9] for tier in range(4)]
    for magic in range(256):
        for row in tiers:
            index = 8
            while index >= 0 and row[index] >= magic:
                index -= 1
            if index + 1 != sum(magic > threshold for threshold in row):
                raise ValueError('recovery refill comparisons disagree')
    return {'main': main_origin, 'bodies': bodies, 'thresholds': tiers}


def hq_party_recovery():
    data, origin = source('/VB7.BIN')
    if origin['sha256'] != CASTLE_SOURCES['/VB7.BIN'] or data[0x26d:0x270] != bytes.fromhex('4c 02 00'):
        raise ValueError('founding party recovery changed')
    rows = list(decode_stream(data, 0x26d, max_insns=1))
    if [(pc, op, args) for pc, op, args, _ in rows] != [(0x26d, 0x4c, b'\x02\x00')]:
        raise ValueError('independent party recovery boundary disagrees')
    return {'source': origin, 'offset': 0x26d, 'bytes': '4c0200', 'consumed': 3,
            **party_recovery_rules(), 'command': {'kind': 'party_restore'},
            'scope': 'active-party HP, status and four spell tiers; no reserve recovery, payment or added rest clock; complete founding scene binds in candidate36; native execution remains unverified'}


@cache
def free_party_recoveries():
    party_recovery_rules()
    result = []
    for file, room, index, start, offset, end, digest in (
            ('/VA8.BIN', 10, 6, 0x22f08, 0x22fb3, 0x22fbd, 'bd3e692a0338223fa75c6a53c8190fb74b2746ff6236f6289a4754f38740adcf'),
            ('/VA5.BIN', 1, 4, 0x13e84, 0x13f80, 0x13f87, '75ada5e80f6951ee173971de98dfdf2c0a1092125bfc979cf8ad84574a69d618'),
            ('/VA5.BIN', 1, 5, 0x13e84, 0x13f80, 0x13f87, '75ada5e80f6951ee173971de98dfdf2c0a1092125bfc979cf8ad84574a69d618')):
        data, origin = source(file)
        entity = scene.entities(data, scene.room_record(data, room))[index]
        literal_start = struct.unpack_from('<I', data, entity['offset'] + 20)[0] - 0x80010000
        if origin['sha256'] != digest or entity['stream_offsets'][2] != start or literal_start != start:
            raise ValueError('free party recovery source changed')
        rows = []
        for row in decode_stream(data, start, max_insns=220):
            rows.append(row)
            if row[1] == 0xfd:
                break
        calls = [(pc, args) for pc, op, args, _ in rows if op == 0x4c]
        if rows[-1][0] + 1 != end or rows[-1][1] != 0xfd or calls != [(offset, b'\x02\xff')] or data[offset:offset + 3] != bytes.fromhex('4c 02 ff'):
            raise ValueError('free party recovery boundaries disagree')
        result.append({'source': origin, 'module': file, 'room': room, 'entity': index, 'stream_offset': start,
                       'stream_end': end, 'stream_sha256': hashlib.sha256(data[start:end]).hexdigest(),
                       'offset': offset, 'bytes': '4c02ff', 'consumed': 3,
                       'command': {'kind': 'party_restore'}})
    return result


def hq_party_dismissal():
    data, origin = source('/VB7.BIN')
    main, main_origin = source('MAIN.EXE')
    base = struct.unpack_from('<I', main, 24)[0]
    if origin['sha256'] != CASTLE_SOURCES['/VB7.BIN'] or main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported founding dismissal identity')
    rows = list(decode_stream(data, 0x270, max_insns=1))
    if data[0x270:0x272] != b'\x20\xff' or [(pc, op, args) for pc, op, args, _ in rows] != [(0x270, 0x20, b'\xff')]:
        raise ValueError('independent founding dismissal boundary disagrees')
    bodies = []
    for start, end, digest in (
            (0x8013a0c0, 0x8013a1d4, '1e9a2bfcf197bb449804532cd3bd74e2866a328a3c1357be9dc9f52c6b4fedec'),
            (0x8013a1d4, 0x8013a344, '9a0f8afe54cb7771dd626db37f92c06db02e2be2198be7fda53b58b1c46d64cf'),
            (0x800c4afc, 0x800c4b94, '3d5eac65e5999716536f69547e951df3497b6a186c1b721a767283ff62f0e946'),
            (0x8013a038, 0x8013a080, 'f3be2dfdae308bf556106ef68bcd6b63b5094650a6d061e6f3fa2f8a66166871'),
            (0x80139e10, 0x80139e94, '72b650ae9afe898fdac002c4dcf087781aee8ade3836c3c06f2e41fb8a0f2f50')):
        raw = main[2048 + start - base:2048 + end - base]
        independent = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(start, end, 4))
        if raw != independent or hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError('independent dismissal source readers disagree')
        bodies.append({'start': start, 'end': end, 'sha256': digest})
    checked = 0
    for count in range(1, 7):
        for hero in range(-1, count):
            initial = list(range(16, 16 + count))
            if hero >= 0:
                initial[hero] = 8
            active, removed, cursor = initial.copy(), [], 0
            while len(active) > 1 and cursor < len(active):
                if active[cursor] == 8:
                    cursor += 1
                else:
                    removed.append(active.pop(cursor))
                    cursor = 0
            keep = hero if hero >= 0 else count - 1
            if active != [initial[keep]] or removed != [member for index, member in enumerate(initial) if index != keep]:
                raise ValueError('dismissal logical plan disagrees with restart/compact loop')
            checked += 1
    return {'source': origin, 'offset': 0x270, 'bytes': '20ff', 'consumed': 2,
            'main': main_origin, 'bodies': bodies, 'decision_classes_checked': checked,
            'command': {'kind': 'party_dismiss'},
            'scope': 'remove active companions in source order, preserving owned records; keep Hero when present, otherwise the final member; count below2 is unchanged; complete founding scene binds in candidate36; native execution remains unverified'}


@cache
def hq_auxiliary_party():
    data, origin = source('/VB5A2.BIN')
    main, main_origin = source('MAIN.EXE')
    if (origin['sha256'] != '809159ba5816345f3314a3dec50c2a1e4cedd54f1086ed412ea5530a18d423d3'
            or main_origin['sha256'] != MAIN_SHA256):
        raise ValueError('unsupported headquarters auxiliary-party source')
    entry = scene.entities(data, scene.room_record(data, 0))[3]
    if entry['stream_offsets'][2] != 0x3fd30:
        raise ValueError('headquarters ordinary entry pointer changed')
    actor = scene.entities(data, scene.room_record(data, 0))[8]
    classification, classification_proof = decode_predicate(data, actor['stream_offsets'][0], 'classification', full=True)
    expected_presence = [{'kind': 'recruit_present', 'slot': 2}, {'kind': 'party_excludes', 'character_id': 2}]
    if (actor['id'], actor['flags'], actor['x_half'], actor['y_half'], actor['stream_offsets'][0]) != (2, 3, 12, 28, 0x3fb18) or data[0x3fb18:0x3fb1d] != bytes.fromhex('10 02 0f 02 06') or classification_proof['size'] != 5 or classification != {'pointer_state': 'present', 'terms': expected_presence}:
        raise ValueError('independent headquarters actor presence reads disagree')
    entities = scene.entities(data, scene.room_record(data, 0))
    initializer = entities[2]
    entry_conditions, _ = decode_predicate(data, initializer['stream_offsets'][1], 'event')
    expected_conditions = [{'kind': 'story_mask_set', 'flag': {'id': 'scenario_0012', 'mask': 128}},
                           {'kind': 'story_mask_clear', 'flag': {'id': 'scenario_0035', 'mask': 2}}]
    initializer_rows = list(decode_stream(data, 0x3fd24, max_insns=5))
    if (initializer['stream_offsets'][2] != 0x3fd24 or initializer['flags'] != 16
            or any(e['flags'] & 0x101 for e in entities[:8])
            or any(e['flags'] & 16 for e in entities[:2])
            or entry_conditions != {'pointer_state': 'present', 'terms': expected_conditions}
            or data[0x3fd24:0x3fd2f] != bytes.fromhex('30 07 00 01 2b 07 00 02 1f 31 fd')
            or [(pc, op, args) for pc, op, args, _ in initializer_rows] != [
                (0x3fd24, 0x30, b''), (0x3fd25, 7, b'\x00\x01\x2b'),
                (0x3fd29, 7, b'\x00\x02\x1f'), (0x3fd2d, 0x31, b''), (0x3fd2e, 0xfd, b'')]):
        raise ValueError('independent headquarters entry placement reads disagree')
    entry_rows = []
    for row in decode_stream(data, 0x3fd30, max_insns=24):
        entry_rows.append(row)
        if row[1] == 0xfd:
            break
    entry_bytes = bytes.fromhex('32 00 03 21 00 00 05 33 0b 00 12 00 02 1c 00 04 1d 02 0c 1f ff 02 4a 00 02 32 00 00 03 05 33 3a 00 09 23 02 03 00 0a 1c fd')
    cursor = 0x3fd30
    spans = [(0x32, 6), (0x33, 0), (0x0b, 1), (0x12, 2), (0x1c, 3), (2, 0), (0x0c, 0),
             (0x1f, 2), (0x4a, 2), (0x32, 4), (0x33, 0), (0x3a, 1), (9, 2), (3, 3), (0xfd, 0)]
    if len(entry_rows) != len(spans):
        raise ValueError('headquarters entry instruction count changed')
    for (pc, op, args, _), span in zip(entry_rows, spans, strict=True):
        if pc != cursor or (op, len(args)) != span or data[pc:pc + 1 + len(args)] != bytes([op]) + args:
            raise ValueError('headquarters entry instruction boundary disagrees')
        cursor += 1 + len(args)
    if len(entry_rows) != 15 or cursor != 0x3fd59 or data[0x3fd30:cursor] != entry_bytes:
        raise ValueError('headquarters entry inventory leaves bytes')
    from export_opening_field_package import decode_text_tokens, tokens_to_str_preview
    from war_text import decode as independent_text
    import opening_audience
    tables = scene.ptr_at(data, scene.root(data) + 20)
    text_at = scene.ptr_at(data, scene.ptr_at(data, tables + 4 * 4) + 29 * 4)
    tokens, text_end = opening_audience.text(data, text_at)
    text, used = independent_text(data[text_at:])
    body_tokens = decode_text_tokens(data, text_at)
    if text_at != 0x44a68 or text_end - text_at != 218 or used != 218 or tokens_to_str_preview(body_tokens) != text.replace('\n[---]\n', '\f'):
        raise ValueError('independent headquarters entry text decoders disagree')
    rows = list(decode_stream(data, 0x3fd46, max_insns=1))
    if data[0x3fd46:0x3fd49] != bytes.fromhex('4a 00 02') or [(pc, op, args) for pc, op, args, _ in rows] != [(0x3fd46, 0x4a, b'\x00\x02')]:
        raise ValueError('independent headquarters auxiliary-party operand reads disagree')
    base = struct.unpack_from('<I', main, 24)[0]
    start, end = 0x80139220, 0x801392d0
    body = main[2048 + start - base:2048 + end - base]
    independent = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(start, end, 4))
    digest = hashlib.sha256(body).hexdigest()
    if body != independent or digest != 'e1bea9c64b4e4e6e9e55ece440bffd14f8897d34d4d47141e7492d9fc1472f29':
        raise ValueError('independent auxiliary-party handler reads disagree')
    resident, resident_origin = source('SLUS_002.92')
    import character_table
    resident_base = struct.unpack_from('<I', resident, 24)[0]
    resident_image = character_table.image()
    def boot_word(address):
        value = struct.unpack_from('<I', resident, 2048 + address - resident_base)[0]
        if value != struct.unpack_from('<I', resident_image, address - resident_base)[0]:
            raise ValueError('independent auxiliary boot readers disagree')
        return value
    boot_words = {0x800420c0: 0x801b8000, 0x80017628: 0x340500ff,
                  0x8001763c: 0x3c028004, 0x80017640: 0x8c4220c0,
                  0x80017648: 0x00441021, 0x8001764c: 0xa0450028,
                  0x80017650: 0x24840001, 0x80017654: 0x28820006,
                  0x80017658: 0x1440fff8}
    for address, expected in boot_words.items():
        if boot_word(address) != expected:
            raise ValueError('auxiliary new-game initialization changed')
    boot_first, boot_last = 0x80017544, 0x80017660
    boot_body = resident[2048 + boot_first - resident_base:2048 + boot_last - resident_base]
    if (boot_body != resident_image[boot_first - resident_base:boot_last - resident_base]
            or hashlib.sha256(boot_body).hexdigest() != '80bb0c83bc0a1122f9fd051a4f631c6372cd5d7b7c5649412a4e9bff7d655058'):
        raise ValueError('auxiliary boot initialization body changed')
    prefix_first, prefix_last = 0x80139cac, 0x80139e10
    prefix_body = main[2048 + prefix_first - base:2048 + prefix_last - base]
    if (prefix_body != b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(prefix_first, prefix_last, 4))
            or hashlib.sha256(prefix_body).hexdigest() != '99f2caff1ff028d0a4543db1f506e8e989eae9c9773d15eeff70fbb2c63302b6'
            or maindec.mword(0x80139ce4) != 0x90420089
            or maindec.mword(0x80139d00) != 0xa0450089
            or maindec.mword(0x80139d70) != 0xa0430089):
        raise ValueError('independent transient follower order readers disagree')
    load_rows = list(decode_stream(data, 0x3fd43, max_insns=1))
    if data[0x3fd43:0x3fd46] != bytes.fromhex('1f ff 02') or [(pc, op, args) for pc, op, args, _ in load_rows] != [(0x3fd43, 0x1f, b'\xff\x02')]:
        raise ValueError('independent headquarters direct character-load reads disagree')
    load_bodies = []
    for first, last, expected in (
            (0x80139e94, 0x80139fbc, '3b4a8ef66446eac299e3d348f5c637f5ede478efce7ee93e116f62bffc11851b'),
            (0x800c4864, 0x800c48d4, 'ecd0c776961024fa517eef93c7acc916266e7d4f4a90ba2ac83e647633dd5b89'),
            (0x800c48d4, 0x800c4954, 'f0c5d696d0130486393f56b59d22f16cc7bea831c44feda46495e9987f30ec41'),
            (0x800c4954, 0x800c49b8, 'c868ee945e564f89a579066eb01b07d66304ffa667355f5afccca78cb7045722'),
            (0x800c49b8, 0x800c4afc, 'da2609647aac27d5e7a75c2313fa8ee337533cd41801ecc34ba99a64a44b4ff3'),
            (0x801395fc, 0x801396e0, 'dd814c01c002b33251dc8dadab04828b431a98454348936c07548ffc694b752b')):
        raw = main[2048 + first - base:2048 + last - base]
        independent = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(first, last, 4))
        if raw != independent or hashlib.sha256(raw).hexdigest() != expected:
            raise ValueError('independent character-load source bodies disagree')
        load_bodies.append({'start': first, 'end': last, 'sha256': expected})
    presence_bodies = []
    for first, last, expected in (
            (0x8013d8e0, 0x8013db6c, '50e2ed023ff810a38121677f0a538cd6f36e04370b95e63116b90bfe36aa88a5'),
            (0x8013d330, 0x8013d3cc, 'bd28052c7e78a54a109a4d78944abc00c3a42cf66d031edd883564eed1fbd145')):
        raw = main[2048 + first - base:2048 + last - base]
        independent = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(first, last, 4))
        if raw != independent or hashlib.sha256(raw).hexdigest() != expected:
            raise ValueError('independent actor presence source bodies disagree')
        presence_bodies.append({'start': first, 'end': last, 'sha256': expected})
    for address, expected in ((0x800c19d4, 0x8013d9a0), (0x800c19d8, 0x8013d9c0), (0x8012ef58, 0x0c04f638)):
        if struct.unpack_from('<I', main, 2048 + address - base)[0] != expected or maindec.mword(address) != expected:
            raise ValueError('actor classification dispatch/constructor changed')
    return {'source': origin, 'room': 0, 'entity': 3, 'offset': 0x3fd46, 'bytes': '4a0002', 'consumed': 3,
            'actor': {'entity': 8, 'character': 2, 'classification_offset': 0x3fb18, 'classification_bytes': '10020f0206',
                      'classification': classification, 'initial_pixels': [96, 224],
                      'source_selector': 0,
                      'entry_placement': {'conditions': expected_conditions, 'x': 344, 'y': 248},
                      'initializer': {'entity': 2, 'offset': 0x3fd24, 'end': 0x3fd2f, 'consumed': 11, 'instruction_count': 5,
                                      'bytes': '300700012b0700021f31fd',
                                      'lowering': 'first initializer; both axis writes execute in one continue/yield pump; export a conditional entry placement before the ordinary scene'},
                      'presence_bodies': presence_bodies,
                      'scope': 'Gremio must be recruited/present and outside the active party at construction; conditional single-pump entry placement and complete morning program are bound in candidate32; native playback remains unverified'},
            'main': main_origin, 'handler': {'start': start, 'end': end, 'sha256': digest},
            'new_game': {'source': resident_origin, 'start': boot_first, 'end': boot_last,
                         'initial_auxiliary_party': [255] * 6,
                         'body_sha256': hashlib.sha256(boot_body).hexdigest(),
                         'words': {hex(address): hex(value) for address, value in boot_words.items()}},
            'transient_follower_order': {'start': prefix_first, 'end': prefix_last,
                                         'body_sha256': hashlib.sha256(prefix_body).hexdigest(),
                                         'storage': 'room context bytes89..8E; opcode3B prefix/remainder order, separate from saved GS28..2D auxiliary membership'},
            'load': {'offset': 0x3fd43, 'bytes': '1fff02', 'consumed': 3, 'bodies': load_bodies,
                     'command': {'kind': 'party_load', 'character': 'gremio'},
                     'scope': 'direct character2 load sets its loaded bit before capacity check, appends combat membership when a slot is available and refreshes recruitment tier; auxiliary list retains its prior order until the following4A edit'},
            'entry_program': {'offset': 0x3fd30, 'end': cursor, 'consumed': len(entry_bytes), 'instruction_count': 15,
                              'native_command_count': 14, 'terminal': 'room transition owns completion; trailing sourceFD retained in inventory, not emitted after the terminal command',
                              'bytes': entry_bytes.hex(), 'conditions': expected_conditions,
                              'instructions': [{'offset': pc, 'opcode': op, 'operands': list(args)} for pc, op, args, _ in entry_rows],
                              'tracks': [{'offset': pc, 'commands': opening_audience.track(args[1:])} for pc, op, args, _ in entry_rows if op == 0x32],
                              'dialogue': {'offset': 0x3fd3d, 'table': 4, 'entry': 29, 'character': 2,
                                           'string_offset': text_at, 'consumed': used, 'tokens': body_tokens},
                              'return': {'room': 0, 'spawn_pixels': [80, 224]},
                              'scope': 'complete bounded morning entry; room reentry is a transition, not an in-place Hero alignment; broader headquarters events remain source-only'},
            'command': {'kind': 'area_action', 'area': {'kind': 'auxiliary_party_add', 'character': 2}},
            'scope': 'mode0 writes the first empty auxiliary slot; other modes clear the first matching slot; holes and duplicates remain; distinct from scene follower order. Native field ownership and save32 preserve this list across rooms/scenes; legacy saves retain unknown membership rather than infer it from active members. Complete source scene playback remains unverified'}


def kouan_entry():
    from opening_audience import text
    from export_first_room import area_room_walkable_grid
    import war_text
    data, origin = source('/VB3.BIN')
    if origin['sha256'] != '67c548a5e5e7047da175e37c98c61506ec60da40ef9a990d63c93f8a464d3410':
        raise ValueError('unsupported Kouan identity')
    main, main_origin = source('MAIN.EXE')
    if main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported Kouan world table')
    base = struct.unpack_from('<I', main, 24)[0]
    def read(address, size):
        raw = main[2048 + address - base:2048 + address - base + size]
        independent = maindec.body()[address - maindec.MBASE:address - maindec.MBASE + size]
        if raw != independent: raise ValueError('independent Kouan MAIN reads disagree')
        return raw
    def word(address): return int.from_bytes(read(address, 4), 'little')
    table = word(0x80170068)
    point_at = table + 2 * 14
    point = read(point_at, 14)
    descriptor = word(word(0x8016f680) + 2 * 4)
    if point != bytes.fromhex('000040003c001d4a0c0435000000') or struct.unpack('<II', read(descriptor, 8)) != (origin['size'], origin['lba']):
        raise ValueError('Kouan entrance/descriptor changed')
    if word(0x80131df8) != 0x24420002:
        raise ValueError('source point-return south offset changed')
    streams = []
    for room, entity, start, literal in (
            (0, 1, 0x411f0, '1180000e0a0203021f1afd'),
            (0, 6, 0x41230, '092704092f8003fffd'),
            (2, 0, 0x416e8, '03002e41fd'),
            (2, 3, 0x416f0, '0b0212000f1c000004020cfd')):
        record = scene.entities(data, scene.room_record(data, room))[entity]
        raw = bytes.fromhex(literal)
        if record['stream_offsets'][2] != start or data[start:start + len(raw)] != raw:
            raise ValueError('Kouan entry stream changed')
        rows = []
        for row in decode_stream(data, start, max_insns=16):
            rows.append(row)
            if row[1] == 0xfd: break
        cursor = start
        for pc, op, args, _ in rows:
            count = {0x11: 2, 0x0e: 0, 0x0a: 1, 9: 2, 0x0b: 1, 0x12: 2, 0x1c: 3, 2: 0, 0x0c: 0, 0xfd: 0}.get(op, len(args))
            if pc != cursor or data[pc + 1:pc + 1 + count] != args: raise ValueError('independent Kouan operand walk disagrees')
            cursor += 1 + count
        if cursor != start + len(raw): raise ValueError('Kouan stream not fully consumed')
        streams.append({'room': room, 'entity': entity, 'offset': start, 'end': cursor, 'bytes': literal,
                        'instructions': [{'offset': pc, 'opcode': op, 'operands': list(a)} for pc, op, a, _ in rows]})
    tables = scene.ptr_at(data, scene.root(data) + 20)
    pointer = scene.ptr_at(data, scene.ptr_at(data, tables) + 4 * 4)
    tokens, end = text(data, pointer); plain, used = war_text.decode(data, pointer)
    decoded = ''.join(v['text'] if v['kind'] == 'glyph' else '\n[---]\n' if v['kind'] == 'page' else '\n' for v in tokens)
    if decoded != plain or used != end - pointer or "Lepant's mansion" not in plain:
        raise ValueError('independent Krin greeting text disagrees')
    krin = scene.entities(data, scene.room_record(data, 2))[3]
    krin_classification, _ = decode_predicate(data, krin['stream_offsets'][0], 'classification', full=True)
    setup = data[krin['stream_offsets'][0]:krin['stream_offsets'][0] + 6]
    if (krin['id'], krin['x_half'], krin['y_half'], krin['flags'], setup.hex()) != (15, 24, 19, 3, '080d0406ed00'):
        raise ValueError('Kouan Krin appearance changed')
    greeting = hq_choreography(data, rows, [{'native_actor_id': 'vb3_room_2_actor_01_030'},
                                          {'native_actor_id': 'vb3_room_2_actor_02_044'},
                                          {'native_actor_id': 'vb3_room_2_actor_03_015'}], word, (1, 0, []))['dialogues'][0]
    if greeting['speaker_name'] != 'Krin' or greeting['character'] != 15:
        raise ValueError('independent Krin speaker identity changed')
    for room, x, y in ((0, 232, 592), (0, 368, 520), (2, 248, 208)):
        w, h, cells = area_room_walkable_grid(data, scene.section_off(data, scene.room_record(data, room)['section']), '/VB3.BIN', room)
        if not (0 <= x < w * 8 and 0 <= y < h * 8 and cells[y // 8 * w + x // 8] == '1'):
            raise ValueError('Kouan source arrival is blocked')
    residents = []
    for room, indexes in ((0, (10, 11, 12, 15, 18, 19)), (2, (1, 2, 3, 7, 10, 12, 14)), (20, (8,))):
        for index in indexes:
            entry = scene.entities(data, scene.room_record(data, room))[index]
            classification, predicate = decode_predicate(data, entry['stream_offsets'][0], 'classification', full=True)
            at = entry['stream_offsets'][0] + predicate['size']
            setup = data[at:at + 2]
            expected = bytes.fromhex('ed00' if room == 2 and index in (3, 14) else 'ff01' if (room, index) == (0, 18) else 'ff00')
            x, y, flags, character = struct.unpack_from('<4H', data, entry['offset'])
            if setup != expected or (x, y, flags, character) != (entry['x_half'], entry['y_half'], entry['flags'], entry['id']) or flags != (7 if (room, index) == (0, 19) else 3):
                raise ValueError('independent Kouan resident setup reads disagree')
            residents.append({'room': room, 'entity': index, 'character': character, 'record': entry['offset'],
                              'classification': classification, 'setup_offset': at, 'setup_bytes': setup.hex(),
                              'position_pixels': [x * 8, y * 8], 'facing': ('down', 'up', 'left', 'right')[setup[1]],
                              'speed': (flags >> 2) & 1, 'auto_animate': bool(flags & 0x200)})
    return {'source': origin, 'main': main_origin, 'world_point': {'region': 1, 'index': 2, 'address': point_at, 'bytes': point.hex(), 'descriptor': descriptor,
            'camera': [64, 60], 'hero_rect': {'x': 592, 'y': 544, 'w': 16, 'h': 16}, 'spawn_pixels': [232, 592], 'return_pixels': [592, 560]},
            'rooms': list(KOUAN_ROOMS), 'streams': streams, 'residents': residents,
            'krin': {'entity': 3, 'character': 15, 'position': [192, 152], 'facing': 'down', 'classification': krin_classification, 'speech': greeting,
                     'dialogue': {'offset': pointer, 'consumed': used, 'tokens': tokens}},
            'scope': 'town/inn entry, return and initial Krin greeting; Giovanni and the later Krin mission branches remain separate; source inn-door prop interaction is not yet presented'}


def kouan_giovanni():
    from export_field_actor_bindings import source_inventory, require_original_instructions
    data, origin = source('/VB3.BIN')
    if origin['sha256'] != '67c548a5e5e7047da175e37c98c61506ec60da40ef9a990d63c93f8a464d3410':
        raise ValueError('unsupported Giovanni source identity')
    entries = scene.entities(data, scene.room_record(data, 0))
    entry = entries[12]
    start, end = 0x41268, 0x412ad
    literal = bytes.fromhex('100c351180001102020b0212002c1c000000020c46340123000c35324001030000053317801201231c01000102180b0212002c1c000002020c4632400303053339090d01fd')
    if (entry['id'], entry['stream_offsets'][2], data[start:end]) != (44, start, literal):
        raise ValueError('Giovanni stream identity changed')
    rows = []
    for row in decode_stream(data, start, max_insns=32):
        rows.append(row)
        if row[1] == 0xfd: break
    cursor = start
    lengths = {0x10: 2, 0x11: 2, 0x0b: 1, 0x12: 2, 0x1c: 3, 2: 0,
               0x0c: 0, 0x46: 0, 0x33: 0, 0x17: 1, 0x18: 0, 0x39: 0, 9: 2, 0xfd: 0}
    for pc, op, args, _ in rows:
        if op == 0x34:
            count = 1 + 4 * data[cursor + 1]
        elif op == 0x32:
            stop = cursor + 2
            while data[stop] != 5:
                if data[stop] not in range(4): raise ValueError('unsupported Giovanni movement')
                stop += 2
            count = stop - cursor
        else:
            count = lengths[op]
        if pc != cursor or data[pc + 1:pc + 1 + count] != args:
            raise ValueError('independent Giovanni operand walk disagrees')
        cursor += count + 1
    if cursor != end or len(rows) != 28:
        raise ValueError('Giovanni stream not fully consumed')
    main, main_origin = source('MAIN.EXE')
    base = struct.unpack_from('<I', main, 24)[0]
    words = {0x8013aa70: 0x90930001, 0x8013aacc: 0x90820002, 0x8013aad4: 0xa2420000,
             0x8013aaf0: 0x90620000, 0x8013aaf8: 0xa222ffed, 0x8013ab04: 0x34020002,
             0x8013ab08: 0xa222fff1, 0x8013ab5c: 0x0c04e9dc, 0x8013aba4: 0x0c04ba90,
             0x8013abb0: 0x0c04d0ed}
    if main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported dynamic actor constructor source')
    for address, expected in words.items():
        if struct.unpack_from('<I', main, 2048 + address - base)[0] != expected or maindec.mword(address) != expected:
            raise ValueError('independent dynamic actor constructor reads disagree')
    selectors, lifetimes = source_inventory(data, entries, 12, 'vb3_room_0_e12_interaction', 'vb3_room_0', False)
    consumers = require_original_instructions()
    choreography = hq_choreography(data, rows, {
        2: {'native_actor_id': 'vb3_room_0_actor_12_044'},
        0x40: {'native_actor_id': 'vb3_room_0_giovanni_viktor'},
    }, maindec.mword, (3, 2, []))
    if [speech['speaker_name'] for speech in choreography['dialogues']] != ['Giovanni', 'Viktor', 'Giovanni']:
        raise ValueError('Giovanni speaker identities changed')
    if [(v['kind'], v['count']) for v in lifetimes] != [('dynamic_opcode_34', 1), ('dynamic_free', 0)]:
        raise ValueError('Giovanni dynamic actor lifetime changed')
    return {'source': origin, 'room': 0, 'entity': 12, 'offset': start, 'end': end,
            'bytes': literal.hex(), 'consumed': end - start,
            'instructions': [{'offset': pc, 'opcode': op, 'operands': list(args)} for pc, op, args, _ in rows],
            'classification': decode_predicate(data, entry['stream_offsets'][0], 'classification', full=True)[0],
            'selection': decode_predicate(data, entry['stream_offsets'][1], 'event', coordinate_ranges=True)[0],
            'choreography': choreography, 'selectors': selectors, 'lifetimes': lifetimes,
            'selector_consumers': consumers, 'constructor_words': {hex(a): hex(w) for a, w in words.items()},
            'actors': [{'selector': 2, 'native_actor_id': 'vb3_room_0_actor_12_044'}, {'selector': 64, 'native_actor_id': 'vb3_room_0_giovanni_viktor'}],
            'viktor': {'character': 35, 'actor': 'vb3_room_0_giovanni_viktor', 'spawn_pixels': [96, 424],
                       'direction_operand': 0, 'facing': 'down', 'speed': 2, 'auto_animate': False,
                       'domain': 'scene-owned dynamic actor, not a transient party follower'},
            'story_result': {'offset': 0x412a9, 'scenario': 13, 'or_mask': 1},
            'scope': 'complete source inventory; candidate38 lowers the complete scene including scene-owned actor construction/release; connected playback and media acceptance remain unfinished; no story flag is supplied'}


def kouan_juppo():
    from export_field_party_queue import export as party_queues
    from export_first_room import area_room_walkable_grid
    from opening_audience import track
    data, origin = source('/VB3.BIN')
    if origin['sha256'] != '67c548a5e5e7047da175e37c98c61506ec60da40ef9a990d63c93f8a464d3410':
        raise ValueError('unsupported Juppo source')
    entry = scene.entities(data, scene.room_record(data, 20))[8]
    start, end = 0x4325c, 0x432db
    literal = bytes.fromhex('10151d1180001100020b001200271c00001c020c3b0408020123363317421201231c01001d02180b001200271c00001e020c17411201011c01001f02180b001200271c000020020c17401201021c01002102180b421200231c000022020c17001201271c01002302183200011805333a003738090d08421945274b002709fd')
    if (entry['id'], entry['x_half'], entry['y_half'], entry['flags'], entry['stream_offsets'][2], data[start:end]) != (39, 21, 27, 3, start, literal):
        raise ValueError('Juppo record or stream changed')
    raw_rows, cursor = [], start
    for pc, op, args, note in decode_stream(data, start, max_insns=64):
        if op == 0x3b:
            count = 1 + data[pc + 1]
        elif op == 0x32:
            stop = pc + 2
            while data[stop] != 5:
                if data[stop] not in range(4):
                    raise ValueError('unsupported Juppo movement')
                stop += 2
            count = stop - pc
        else:
            count = {0x10: 2, 0x11: 2, 0xb: 1, 0x12: 2, 0x1c: 3, 2: 0, 0xc: 0, 0x36: 0,
                     0x33: 0, 0x17: 1, 0x18: 0, 0x3a: 1, 0x37: 0, 0x38: 0, 9: 2, 0x42: 1, 0x45: 1, 0x4b: 3, 0xfd: 0}[op]
        if pc != cursor or bytes(args) != data[pc + 1:pc + 1 + count]:
            raise ValueError('independent Juppo operand walk disagrees')
        cursor += 1 + count
        raw_rows.append((pc, op, args, note))
        if op == 0xfd:
            break
    if cursor != end or len(raw_rows) != 56:
        raise ValueError('Juppo stream not fully consumed')
    actors = {0: {'native_actor_id': 'vb3_room_20_actor_08_039'},
              **{64 + i: {'native_actor_id': f'party_follower_{i}'} for i in range(3)}}
    choreography = hq_choreography(data, raw_rows, actors, maindec.mword, (8, 1, []))
    if [speech['speaker_name'] for speech in choreography['dialogues']] != ['Juppo', 'Viktor', 'Juppo', 'Cleo', 'Juppo', 'Gremio', 'Viktor', 'Juppo']:
        raise ValueError('Juppo scene speaker identities changed')
    prefix = next(list(args) for _, op, args, _ in raw_rows if op == 0x3b)
    if prefix != [4, 8, 2, 1, 35]:
        raise ValueError('Juppo transient party order changed')
    main, main_origin = source('MAIN.EXE')
    if main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported Juppo party table source')
    base = struct.unpack_from('<I', main, 24)[0]
    formation, formation_proof = party_queues()
    for decoded, proof in zip(formation['tracks'], formation_proof['tracks'], strict=True):
        raw = bytes.fromhex(proof['bytes'])
        if main[2048 + proof['pointer'] - base:2048 + proof['pointer'] - base + len(raw)] != raw or track(raw) != decoded['commands']:
            raise ValueError('independent Juppo spread/return tables disagree')
    formation.pop('content_sha256')
    formation.update(schema='suikoden-field-party-queue/2', anchor={'x': 168, 'y': 232})
    formation['content_sha256'] = hashlib.sha256(json.dumps(formation, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    doors = []
    for room, entity, offset, literal in ((13, 4, 0x42fc4, '03144b1efd'), (20, 0, 0x431a0, '030d2d23fd'), (20, 2, 0x431a8, '03000c31fd')):
        source_entry = scene.entities(data, scene.room_record(data, room))[entity]
        raw = bytes.fromhex(literal)
        if source_entry['stream_offsets'][2] != offset or data[offset:offset + 5] != raw:
            raise ValueError('Juppo-room passage changed')
        target, x, y = raw[1:4]
        width, height, cells = area_room_walkable_grid(data, scene.section_off(data, scene.room_record(data, target)['section']), '/VB3.BIN', target)
        if not (x < width and y < height and cells[y * width + x] == '1'):
            raise ValueError('Juppo-room source arrival blocked')
        doors.append({'room': room, 'entity': entity, 'offset': offset, 'bytes': literal,
                      'command': {'kind': 'room_transition', 'destination': f'vb3_room_{target}', 'x': x * 8, 'y': y * 8}})
    return {'source': origin, 'room': 20, 'entity': 8, 'offset': start, 'end': end, 'bytes': data[start:end].hex(),
            'consumed': end - start, 'instructions': [{'offset': pc, 'opcode': op, 'operands': list(args)} for pc, op, args, _ in raw_rows],
            'actors': [{'selector': key, **value} for key, value in actors.items()], 'choreography': choreography,
            'formation': formation, 'formation_proof': formation_proof, 'doors': doors,
            'classification': decode_predicate(data, entry['stream_offsets'][0], 'classification', full=True)[0],
            'recruit': {'character': 39, 'id': 'juppo', 'level_advances': 9},
            'scope': 'complete source scene and three passages; candidate42 lowers the formation, dialogue, release and roster effects; native scene execution, fresh-process continuation and media acceptance remain unverified; no story flag is supplied'}


def item_overload():
    """Qualify the selector8 pending-item handoff and discard policy."""
    from opening_audience import text
    import war_text
    import item_tables
    main, origin = source('MAIN.EXE')
    base = struct.unpack_from('<I', main, 24)[0]
    start, end = 0x800dc650, 0x800dda50
    raw = main[2048 + start - base:2048 + end - base]
    independent = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(start, end, 4))
    if raw != independent or hashlib.sha256(raw).hexdigest() != 'db618c36b51cd09a84c2ead8ef7d5f4e709e12afef932428a3b3059c22d3be49':
        raise ValueError('item overload body changed')
    for lo, hi, digest in ((0x8013bc28, 0x8013bcb4, '381746c4df3e24c7572dff45f46c426efc601cbf160b56b9498a636a3d9aa405'),
                           (0x800ca38c, 0x800ca408, '6e130f849639cfef23dac79cfc99bcbabe54fc5f5692e61007ae4f3baa85a599')):
        direct = main[2048 + lo - base:2048 + hi - base]
        words = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(lo, hi, 4))
        if direct != words or hashlib.sha256(direct).hexdigest() != digest:
            raise ValueError('event item constructor/append body changed')
    for address, expected in {0x8013bc48: 0xa0400476, 0x800dbbd0: 0x30427000,
                              0x800dbbdc: 0x80620002, 0x800dbbe4: 0x14400033}.items():
        if maindec.mword(address) != expected or struct.unpack_from('<I', main, 2048 + address - base)[0] != expected:
            raise ValueError('event item appraisal marker contract changed')
    for address, expected in {0x80133048: 0x0c037194, 0x8013304c: 0x24840474,
                              0x800dd6c0: 0x0c032902, 0x800dd6e8: 0x0c0328e3,
                              0x800dd730: 0xac620008, 0x800dd7d4: 0xa4600000}.items():
        if maindec.mword(address) != expected or struct.unpack_from('<I', main, 2048 + address - base)[0] != expected:
            raise ValueError('overload handoff/commit consumer changed')
    labels = {}
    for index, name in ((0, 'overloaded'), (2, 'gave_up'), (3, 'choose_item'), (4, 'equipped'),
                        (8, 'drop'), (9, 'keep'), (10, 'give_up'), (11, 'continue_selecting')):
        pointer = struct.unpack_from('<I', main, 2048 + 0x8016b2f8 - base + index * 4)[0]
        if pointer != maindec.mword(0x8016b2f8 + index * 4): raise ValueError('overload label pointer readers disagree')
        decoded, _ = war_text.decode(main, 2048 + pointer - base)
        tokens, _ = text(main, 2048 + pointer - base)
        if decoded != ''.join(token.get('text', '') for token in tokens if token['kind'] == 'glyph'):
            raise ValueError('overload label text readers disagree')
        labels[name] = decoded
    catalogue = json.loads((ROOT / 'game/assets/campaign_policies/item_shared_ledger.json').read_text())['items']
    checked = []
    for source_item, native in zip(item_tables.items(), catalogue, strict=True):
        item_id = source_item['id']
        pointer = struct.unpack_from('<I', main, 2048 + 0x80167658 - base + item_id * 4)[0]
        price = struct.unpack_from('<I', main, 2048 + pointer - base + 24)[0]
        flags = struct.unpack_from('<H', main, 2048 + pointer - base + 28)[0]
        if source_item['addr'] != pointer or source_item['price'] != price or native['source_item_id'] != item_id or native['price'] != price or bool(flags & 0x7000) != (native['ownership'] == 'appraisal'):
            raise ValueError('overload item policy readers disagree')
        if native['controller']['kind'] == 'items_enum' and native['controller']['tag'] != native['id']:
            raise ValueError('overload native identity requires explicit resolution')
        checked.append({'id': native['id'], 'ordinary_discardable': bool(flags & 0x7000) or price != 0})
    # Separate decision-tree and expression views of all flag/price/marker classes.
    for appraisal in (False, True):
        for price in (0, 1):
            for marker in (0, 1, 127, 128, 255):
                denied = False if appraisal else True if marker & 128 else price == 0
                if denied != (not appraisal and (bool(marker & 128) or price == 0)):
                    raise ValueError('overload discard predicate disagrees')
    for address, expected in {0x800c9bf4: 0x90421b7e, 0x800c9bfc: 0x00021040,
                              0x800c9c04: 0x24215884, 0x800c9c0c: 0x84240000,
                              0x800c9c10: 0x0c030c41}.items():
        if maindec.mword(address) != expected or struct.unpack_from('<I', main, 2048 + address - base)[0] != expected:
            raise ValueError('overload common sound bank selection changed')
    if struct.unpack_from('<5H', main, 2048 + 0x80165884 - base) != (0x21, 0x22, 0x23, 0x24, 0x4d):
        raise ValueError('overload common sound bank table changed')
    return {'source': origin, 'start': start, 'end': end, 'sha256': hashlib.sha256(raw).hexdigest(),
            'labels': labels, 'item_policies': checked, 'settle_updates': 30, 'cues': [0x502, 0x503, 0x504, 0x505],
            'entry': 'selector8 uses area pending item at+474 directly; unrelated parameter table is not the pending item',
            'flow': 'Overloaded notice; default Dont give up/Give up; party and item selection; equipped item gets Drop/Do not drop confirmation; ordinary eligible item commits directly; give-up acknowledgement returns without inventory edits',
            'discard_policy': 'appraisal-family items allowed; others reject negative item marker or zero price; positive marker means equipped and adds confirmation',
            'commit': 'remove selected slot, append pending item with its uses, show updated list for30 updates or confirm, clear pending item id and return',
            'incoming_appraisal': 'event49 zeros pending marker; append copies the complete record; appraisal-family items therefore enter unidentified, including overload replacement',
            'sound_bank_selection': {'index_address': 0x800c9bf4, 'table': 0x80165884,
                                     'requests': list(struct.unpack_from('<5H', main, 2048 + 0x80165884 - base))},
            'scope': 'source policy/labels/commit qualified statically; native modal and connected wheel acceptance remain separate'}


def kouan_wheel():
    """Qualify all wheel branches before admitting its unsupported field mode."""
    from opening_audience import text
    from export_first_room import area_room_walkable_grid
    import war_text
    import battle_placement
    data, origin = source('/VB3.BIN')
    main, main_origin = source('MAIN.EXE')
    if origin['sha256'] != '67c548a5e5e7047da175e37c98c61506ec60da40ef9a990d63c93f8a464d3410' or main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported mansion wheel source')
    base = struct.unpack_from('<I', main, 24)[0]
    def word(address):
        direct = struct.unpack_from('<I', main, 2048 + address - base)[0]
        if direct != maindec.mword(address):
            raise ValueError('independent wheel MAIN readers disagree')
        return direct
    # The ordered unsigned interval tests include the branch-delay-slot result.
    intervals = []
    for address, expected in ((0x801403e8, (164, 32, 0)), (0x80140408, (15, 28, 1)),
                              (0x80140414, (196, 34, 1)), (0x80140424, (43, 29, 2)),
                              (0x80140434, (230, 31, 2)), (0x80140444, (72, 29, 3)),
                              (0x80140454, (261, 29, 3)), (0x80140464, (320, 27, 3)),
                              (0x80140474, (101, 32, 4)), (0x80140484, (290, 30, 4)),
                              (0x80140494, (133, 31, 5))):
        if address == 0x80140408:
            subtract, compare, result = word(0x801403f4), word(address), word(address + 8)
        else:
            subtract, compare, result = word(address), word(address + 4), word(address + (20 if expected[2] == 0 else 12))
        first = -struct.unpack('<h', struct.pack('<H', subtract & 65535))[0]
        width, outcome = compare & 65535, 0 if result == 0xa020bd6c else result & 65535
        if (first, width, outcome) != expected:
            raise ValueError('wheel angle interval changed')
        intervals.append({'first_degree': first, 'last_degree': first + width - 1, 'outcome': outcome})
    if word(0x801404a4) != 0x34020006 or word(0x801404ac) != 0xa022bd6c:
        raise ValueError('wheel default outcome/branch selector changed')
    # Pin startup, deceleration, finish and continued-rotation consumers.
    expected_words = {0x801404e0: 0x9462044e, 0x801404ec: 0x24420001,
                      0x801404f0: 0xa462044e, 0x8014051c: 0x34020012, 0x8014059c: 0x0c051f8e,
                      0x801405a4: 0x3403005a, 0x801405a8: 0x0043001a,
                      0x801405d0: 0x00001012, 0x801405e0: 0x8483044e, 0x801405e8: 0x28630006,
                      0x801405ec: 0x24420001, 0x801405f4: 0xa482044a,
                      0x801405f8: 0x0c051f8e, 0x80140614: 0x24420438,
                      0x80140740: 0x00641821, 0x80140748: 0x00451023,
                      0x80140758: 0x284202d1, 0x80140770: 0x00431021,
                      0x8014078c: 0x2c42003c, 0x80140798: 0xa0600443,
                      0x801407b0: 0x2442ffff, 0x801407d4: 0x0c0500f5,
                      0x80140814: 0x2c420168, 0x80140824: 0xa4600448,
                      0x8014068c: 0x24420002, 0x801406b8: 0x2c420168,
                      0x80140644: 0x0c0500d1, 0x80140354: 0x84620002,
                      0x80140364: 0x0c030b70, 0x80140388: 0xa4620002,
                      0x80140398: 0x00431021, 0x8014039c: 0x0c05005c,
                      0x80140690: 0x30630001, 0x80140694: 0x10600016,
                      0x8014069c: 0x0c05005c, 0x801406f8: 0x2442fffe,
                      0x80140704: 0x1c40004a, 0x8014071c: 0x0c05005c,
                      0x80140988: 0x2c6300b4, 0x80140990: 0x34020001,
                      0x801409a8: 0x2402ffff, 0x801409b8: 0x2442ff4c,
                      0x8013156c: 0xa440044e, 0x8013d304: 0x00042040,
                      0x8013d300: 0x0c050222, 0x801408a8: 0xa0620441,
                      0x801408b8: 0xa0400443, 0x801408c8: 0xa0620444,
                      0x801408dc: 0xa4600448, 0x801408e0: 0xa4600446,
                      0x801408e4: 0xa444044c,
                      0x8013f0f8: 0x3042fffc, 0x8013f124: 0x14400004,
                      0x8013f12c: 0x0c04f80a, 0x8013f150: 0x0c050782,
                      0x80141e20: 0x0c05018a,
                      0x80147e38: 0x240a00a0, 0x80147e40: 0x2409002f}
    if any(word(address) != value for address, value in expected_words.items()):
        raise ValueError('wheel startup/tick/RNG consumer changed')
    spans = ((2, 0x40e38, 0x40f7d, '66ff60e88e67b74172e11f3b21cc5759a61a7a04ce10b89b5993505a2d88371b'),
             (3, 0x40f80, 0x40fbb, 'f8ade325e768996c1fecbf164084980c164faf46c68f7d41df46caf6cca17096'),
             (4, 0x40fbc, 0x41101, 'fa9d4f7083147accea871c5b903cc535de0657e0724b681aa532e7a17a34191a'))
    entries = scene.entities(data, scene.room_record(data, 28))
    variants = []
    for entity, start, end, digest in spans:
        if entries[entity]['stream_offsets'][2] != start or hashlib.sha256(data[start:end]).hexdigest() != digest:
            raise ValueError('wheel complete script identity changed')
        rows, cursor = [], start
        while cursor < end:
            pc, op, args, _ = next(iter(decode_stream(data, cursor, max_insns=1)))
            if op == 0x34:
                count = 1 + 4 * data[pc + 1]
            elif op == 0x32:
                stop = pc + 2
                while data[stop] != 5:
                    if data[stop] not in range(4):
                        raise ValueError('unsupported wheel movement')
                    stop += 2
                count = stop - pc
            elif op == 0x2f:
                count = data[pc + 1] & 63
            else:
                count = {0x10: 2, 0x3a: 1, 0x11: 2, 0x0a: 1, 8: 2, 0x22: 2 if data[pc + 1] == 2 else 1,
                         0x41: 1, 7: 3, 0x33: 0, 0x39: 0, 0xfd: 0, 0xfc: 0, 0xfb: 0, 0xfa: 0, 0xf9: 0,
                         0xf8: 0, 0xf0: 0, 0: 5, 0x1c: 3, 2: 0, 1: 1, 0x46: 0, 0x4b: 2,
                         0x47: 1, 0x49: 2 if data[pc + 1] == 0xfd else 1, 0xfe: 0, 0xc: 0, 0x43: 2, 0x30: 0, 0x31: 0}[op]
            if pc != cursor or bytes(args) != data[pc + 1:pc + 1 + count]:
                raise ValueError('independent complete wheel operand walk disagrees')
            rows.append({'offset': pc, 'opcode': op, 'operands': list(args)})
            cursor += count + 1
        if cursor != end:
            raise ValueError('wheel script consumption mismatch')
        branches = []
        if entity != 3:
            switch = next(row for row in rows if row['opcode'] == 0x2f)
            if switch['operands'] != [0x87, 0xfc, 0xfb, 0xfa, 0xf9, 0xf8, 0xf0]:
                raise ValueError('wheel seven-way branch header changed')
            branch_base = switch['offset'] + 1 + len(switch['operands'])
            branches = [{'outcome': mode, 'offset': branch_base if mode == 0 else data.index(label, branch_base + 1, end)}
                        for mode, label in enumerate([b'', *(bytes([v]) for v in switch['operands'][1:])])]
            alternate = data[start:end]
            original = data[spans[0][1]:spans[0][2]]
            if entity == 4 and [(i, a, b) for i, (a, b) in enumerate(zip(original, alternate, strict=True)) if a != b] != [(233, 80, 79)]:
                raise ValueError('wheel repeat reward differs beyond source item80->79')
        variants.append({'entity': entity, 'offset': start, 'end': end, 'consumed': end - start,
                         'sha256': digest, 'instructions': rows, 'branches': branches,
                         'selection': decode_predicate(data, entries[entity]['stream_offsets'][1], 'event', coordinate_ranges=True, full=True)[0]})
    angles = [next((row['outcome'] for row in intervals if row['first_degree'] <= angle <= row['last_degree']), 6) for angle in range(360)]
    if [angles.count(outcome) for outcome in range(7)] != [32, 62, 60, 85, 62, 31, 28]:
        raise ValueError('wheel interval coverage mismatch')
    # Independent phase arithmetic: each slower speed lasts ceil(60/speed) updates.
    samples = []
    for roll in (0, 89, 90, 12960, 16384, 29160, 32767):
        distance, angle, updates = 1081 + roll // 90, 0, 0
        flat = (distance - 721) // 18
        phases = [(18, flat), *((speed, (60 + speed - 1) // speed) for speed in range(18, 0, -1))]
        for phase, (speed, count) in enumerate(phases):
            for update in range(count):
                angle += speed
                distance -= speed
                updates += 1
                if angle >= 360 and (phase != len(phases) - 1 or update != count - 1):
                    angle = 0
        samples.append({'roll': roll, 'updates': updates, 'angle': angle, 'distance': distance, 'outcome': angles[angle] if angle < 360 else 6})
    text_table = scene.ptr_at(data, scene.ptr_at(data, scene.root(data) + 20))
    dialogues = []
    for index in range(132, 137):
        pointer = scene.ptr_at(data, text_table + index * 4)
        tokens, end = text(data, pointer)
        plain, used = war_text.decode(data, pointer)
        independent = ''.join(token['text'] if token['kind'] == 'glyph' else '\n' for token in tokens)
        if independent != plain or used != end - pointer:
            raise ValueError('independent wheel outcome text readers disagree')
        dialogues.append({'index': index, 'offset': pointer, 'consumed': used, 'text': plain, 'tokens': tokens})
    import item_tables
    item_catalogue = {row['id']: row for row in item_tables.items()}
    rewards = []
    for item_id, stable_id, expected_name, expected_uses in ((25, 'medicine', 'Medicine', 6),
            (79, 'fortune_rune_piece', 'Fortune rune piece', 1),
            (80, 'dragon_seal_incense', 'Dragon seal incense', 0)):
        pointer = word(0x80167658 + item_id * 4)
        record = main[2048 + pointer - base:2048 + pointer - base + 36]
        name, _ = war_text.decode(record, 0)
        uses = record[30] if struct.unpack_from('<H', record, 28)[0] & 12 else 0
        if (name, uses) != (expected_name, expected_uses) or item_catalogue[item_id]['addr'] != pointer or item_catalogue[item_id]['name'] != name:
            raise ValueError('independent wheel item identities/uses disagree')
        rewards.append({'source_item_id': item_id, 'id': stable_id, 'label': name, 'uses': uses, 'record_address': pointer})
    for address, expected in {0x8013b97c: 0x24820001, 0x8013b99c: 0x2c420002,
                              0x8013b9a0: 0x1040006e, 0x8013bb64: 0x14620030,
                              0x8013bb6c: 0x24820002, 0x8013bc44: 0xa4500474,
                              0x8013bc8c: 0x0c0328bc, 0x8013bc94: 0x14400005,
                              0x8013bca0: 0xa020bd6c, 0x8013bcb0: 0xa022bd6c,
                              0x800ca320: 0x9042000e, 0x800ca348: 0x2c420009,
                              0x800ca354: 0x0c0328e3, 0x800ca35c: 0x080328df,
                              0x800ca360: 0x2402ffff, 0x800ca378: 0x00001021}.items():
        if word(address) != expected:
            raise ValueError('wheel item selector/bag/result consumer changed')
    item_suffix, _ = war_text.decode(main, 2048 + word(0x80171c1c) - base)
    if item_suffix != '\nacquired!':
        raise ValueError('wheel item message suffix changed')
    from opening_audience import text
    suffix_at = 2048 + word(0x80171c1c) - base
    suffix = main[suffix_at:main.index(0, suffix_at)]
    if suffix != bytes(word(word(0x80171c1c) + i) & 255 for i in range(len(suffix))):
        raise ValueError('independent reward message suffix readers disagree')
    for reward in rewards:
        at = 2048 + reward['record_address'] - base
        encoded_name = main[at:main.index(0, at)]
        if len(encoded_name) > 21:
            raise ValueError('wheel reward name requires source truncation')
        message = item_tables.acquisition_message(reward['source_item_id'])
        if message != encoded_name + suffix + b'\0':
            raise ValueError('shared and independent wheel item message builders disagree')
        tokens, used = text(message, 0)
        if used != len(message) or ''.join(t.get('text', '\n' if t['kind'] == 'newline' else '?') for t in tokens) != reward['label'] + item_suffix:
            raise ValueError('independent wheel acquisition message readers disagree')
        reward['message_tokens'] = tokens
    for address, expected in {0x8013b9ac: 0x2404ff84, 0x8013b9a4: 0x34050026,
                              0x8013b9b0: 0x3406001e, 0x8013b9b8: 0x34070005,
                              0x8013b9b4: 0x0c051465, 0x8013b9d4: 0x34050080,
                              0x8013b9d0: 0x0c04ec32, 0x8013b4c8: 0x2404ff84,
                              0x8013b4cc: 0x34050026, 0x8013b4d0: 0x3406001e,
                              0x8013b4d8: 0x34070005, 0x8013b4d4: 0x0c051465}.items():
        if word(address) != expected: raise ValueError('reward and ordinary dialogue constructor agreement changed')
    for variant in variants:
        if variant['entity'] == 3: continue
        proxy = f"vb3_room_28_spin_{variant['entity']}_hero"
        variant['actor'] = {'id': proxy, 'entity': variant['entity'], 'character': 8,
                            'spawn_pixels': [168, 272], 'direction_operand': 0}
        variant['choreography'] = hq_choreography(data,
            [(r['offset'], r['opcode'], r['operands'], '') for r in variant['instructions']],
            {64: {'native_actor_id': proxy}, 0: {'native_actor_id': 'vb3_room_28_actor_06_200'}},
            word, (5, 1, [(0, -1, 80)] * 2 + [(0, 1, 80)] * 6), fixed_messages=True)
        variant['audio'] = []
        variant['fixed_boxes'] = []
        for row in variant['instructions']:
            if row['opcode'] == 0:
                slot, x, y, width, height = row['operands']
                variant['fixed_boxes'].append({'offset': row['offset'], 'command': {
                    'kind': 'open_fixed_box', 'box': slot, 'x': (x << 3) + 10, 'y': (y << 3) + 16,
                    'width': (width + 8) << 3, 'height': height * 12,
                    'requires': {'kind': 'box_closed', 'id': f'box_{slot}'}}})
            if row['opcode'] != 0x41: continue
            selector, = row['operands']
            at = 0x80171c2c + selector * 2
            cue = word(at & ~3) >> ((at & 3) * 8) & 65535
            if cue != {114: 0x505, 150: 0x52a}[selector]: raise ValueError('wheel outcome sound changed')
            variant['audio'].append({'offset': row['offset'], 'command': {'kind': 'play_sound', 'cue': cue}})
    doors = []
    for room, entity, start, literal in ((20, 3, 0x431b0, '41074154031c153bfd'),
                                        (28, 0, 0x431bc, '4107413403140927fd'),
                                        (28, 1, 0x431c8, '41074134031d131cfd')):
        raw = bytes.fromhex(literal)
        entry = scene.entities(data, scene.room_record(data, room))[entity]
        if entry['stream_offsets'][2] != start or data[start:start + len(raw)] != raw:
            raise ValueError('wheel room passage changed')
        target, x, y = raw[5:8]
        width, height, cells = area_room_walkable_grid(data, scene.section_off(data, scene.room_record(data, target)['section']), '/VB3.BIN', target)
        if not (x < width and y < height and cells[y * width + x] == '1'):
            raise ValueError('wheel room source arrival blocked')
        doors.append({'room': room, 'entity': entity, 'offset': start, 'bytes': literal,
                      'destination': target, 'spawn_pixels': [x * 8, y * 8], 'arrival_walkable': True,
                      'music_selectors': [raw[1], raw[3]]})
    music = []
    for selector, expected in ((7, 0x15), (52, 0x40d), (84, 0x42d)):
        address = 0x80171c2c + selector * 2
        request = (word(address & ~3) >> ((address & 3) * 8)) & 65535
        if request != expected:
            raise ValueError('wheel room music request changed')
        music.append({'selector': selector, 'request': request})
    if data[entries[5]['stream_offsets'][2]:entries[5]['stream_offsets'][2] + 4] != bytes.fromhex('092c01fd'):
        raise ValueError('wheel repeat reward writer changed')
    for address, expected in {0x800c4c2c: 0xa064000d, 0x800cd9e4: 0x9043000e,
                              0x800cd9f0: 0xac4300e0,
                              0x80138fe0: 0x9043000e, 0x80138fe8: 0x2c620006,
                              0x80139004: 0x8c641b9c, 0x80139008: 0x34020003,
                              0x80139024: 0x2463000a, 0x8013903c: 0x2c6203e8,
                              0x80139048: 0x0062001b, 0x80139058: 0x00001810,
                              0x80139068: 0x0c03a731, 0x80139088: 0x2c42000a,
                              0x80139098: 0xa460000e, 0x801390a4: 0x2442fff6,
                              0x801394f8: 0x8ca2001c, 0x80139500: 0x00622021,
                              0x80139558: 0x00041080, 0x8013957c: 0x8ca30020,
                              0x80139588: 0x8c430000, 0x80139594: 0x0c04b2ef,
                              0x80139598: 0xac431bb4, 0x8012cbd0: 0x34420004,
                              0x800e9cf4: 0x2c420063}.items():
        if word(address) != expected:
            raise ValueError('wheel experience/forced battle consumer changed')
    section = scene.section_off(data, scene.room_record(data, 28)['section'])
    context_count = struct.unpack_from('<I', data, section + 28)[0]
    context_table = scene.ptr_at(data, section + 32)
    directory = scene.ptr_at(data, context_table + context_count * 4)
    if (section, context_count, context_table, directory) != (0xd628, 2, 0x46c4, 0x67dc0):
        raise ValueError('wheel Monster directory selection changed')
    selectors, encounters = battle_placement.directory_encounters(data, directory, 0x80010000)
    direct_encounter = scene.ptr_at(data, selectors + 4)
    if len(encounters) != 1 or direct_encounter != encounters[0]['descriptor_offset'] or list(data[direct_encounter + 4:direct_encounter + 10]) != [1, 1, 1, 2, 0, 0]:
        raise ValueError('independent wheel Monster formation reads disagree')
    enemies = []
    enemy_table = scene.ptr_at(data, directory + 12)
    for source_id, expected_offset in ((1, 0x61fb4), (2, 0x634ec)):
        offset = scene.ptr_at(data, enemy_table + 4 * source_id)
        slots = [slot for slot in encounters[0]['slots'] if slot['enemy_id'] == source_id]
        if offset != expected_offset or any(slot['stats_offset'] != offset for slot in slots):
            raise ValueError('independent wheel Monster roster reads disagree')
        name, _ = war_text.decode(data[offset:offset + 16])
        if name != 'Robot Soldier':
            raise ValueError('wheel Monster source name changed')
        decision = scene.ptr_at(data, offset + 48)
        if decision != {1: 0x37c, 2: 0xd28}[source_id]:
            raise ValueError('wheel Monster decision callback changed')
        for relative, expected in {0x48: 0x92020045, 0x50: 0x14400020,
                                   0x58: 0x92020044, 0x60: 0x2c420004,
                                   0x64: 0x1040001b, 0x6c: 0x92620005,
                                   0x74: 0x14400017, 0x7c: 0x8e221258,
                                   0x8c: 0x0040f809, 0x98: 0x0043001a,
                                   0xc0: 0x00001810, 0xc8: 0x28630033,
                                   0xcc: 0x10600015, 0xe4: 0x1040ffd8}.items():
            if struct.unpack_from('<I', data, decision + relative)[0] != expected:
                raise ValueError('wheel Monster front-row random scan changed')
        enemies.append({'source_id': source_id, 'record_offset': offset, 'name': name,
                        'decision_offset': decision, 'target_policy': 'front_first',
                        'scan': {'front_only': True, 'draw': 'rand_mod_100', 'accept_at_least': 51}})
    # Geometry is exported as ordinary signed pixel offsets, not packed child words.
    from export_spell_scenes import effect_sine
    geometry_bodies = []
    for start, end, digest in ((0x80140170, 0x80140344, '1e690cfae979a8c893003f497a8eec7a0271bf871fd23f1867b6f0b58cf63e33'),
                              (0x8014d6ac, 0x8014d764, 'bc7daa649f0f1acbf95d2817e6f89520658b3887b60614079e0089532bf5840c'),
                              (0x80134118, 0x801343a0, 'fa35f72f597b83d588e062a0343abd33249e4ded6af39f4826e289602c4d6f6b'),
                              (0x8014ceb4, 0x8014d6ac, '5afce57fae76af736e351dd03b2ee3ad7b3d21d1814972808b5258cddc6b11b6'),
                              (0x8014dc24, 0x8014df2c, '7b58c9f614ad49d91c108f8c5cbeb48ea7613453481bc8d9e61e5b8f68f46263'),
                              (0x8014f31c, 0x8014f36c, 'b096f04a8aded97409fb838a52099375501261af496b816374e6c520a19b30b8'),
                              (0x8012ca44, 0x8012cb10, 'fb3a8817c90548747383159d274e17aba697137168c06a052d3b4804b9e42520'),
                              (0x8013e450, 0x8013e6c0, 'b47dc98b7dbfd4f7c944af71078eabbd454525982ef579ca119cca2590dd4b5a'),
                              (0x8013096c, 0x80130cb8, 'cea716eb029ce1ebd880595aa86e84d2502282bb2c1a2321b580d87fcc524ffe'),
                              (0x800c3ef0, 0x800c4244, '5ddfb20c08720d5b249fd09ca34a57555969ff037262fabf476d341339867f68'),
                              (0x8013a770, 0x8013a808, '951ed3abe86fb2dd98c89e73a7b41a8bc2d2b065ef7b4d55be5b76368bba1ccf'),
                              (0x8013a9c4, 0x8013abf4, '46bc630b436870c784a7c0aa3a4af20c3406c06e5417397bfc4e10884d2c133a'),
                              (0x800c3d38, 0x800c3d8c, '3a182477371d2ee580267e5878fd957907cc5eaf87128ce614a07351f5a6e5d1'),
                              (0x800c3dac, 0x800c3e9c, '99d24935552902ee742eb7012d3b6cc71145c7baaff87a6ea906ab14467e4b1c'),
                              (0x801343b4, 0x80134470, '8c330c1efbb53885eaf671ca9e79d6bba7395fd8757527d26439dbe5910ddae7'),
                              (0x8012ea40, 0x8012eb88, 'f0f2b04ea90e29dc3ed9263172b7094536b90ef2ffb6ff8a69de5b941103540f')):
        raw = main[2048 + start - base:2048 + end - base]
        independent = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(start, end, 4))
        if raw != independent or hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError('wheel geometry body readers disagree')
        geometry_bodies.append({'start': start, 'end': end, 'sha256': digest})
    clock_raw = main[2048 + 0x80140628 - base:2048 + 0x80140860 - base]
    clock_independent = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(0x80140628, 0x80140860, 4))
    if clock_raw != clock_independent or hashlib.sha256(clock_raw).hexdigest() != '652bfbef02128c79fb525a1103e2d1740d926f8ddf27cdb6603c129916dbaf43':
        raise ValueError('wheel map-angle gating body disagrees')
    geometry_bodies.append({'start': 0x80140628, 'end': 0x80140860, 'sha256': hashlib.sha256(clock_raw).hexdigest()})
    quarter_bytes = main[2048 + 0x801765bc - base:2048 + 0x80176dbe - base]
    quarter_hash = hashlib.sha256(quarter_bytes).hexdigest()
    if quarter_hash != 'bab3b71ba7f79dfb2b5cebb71f8382a79606a958d72031bc11b88066c36033bd':
        raise ValueError('wheel quarter-wave source changed')
    quarter = struct.unpack('<1025h', quarter_bytes)
    def direct_sine(angle):
        # Independent quadrant projection of the directly extracted quarter table.
        quadrant, index = divmod(angle % 4096, 1024)
        if quadrant & 1: index = 1024 - index
        return quarter[index] * (-1 if quadrant >= 2 else 1)
    def trunc_q12(value):
        return value // 4096 if value >= 0 else -((-value) // 4096)
    offsets, basis = [], []
    for degree in range(360):
        angle = degree * 4096 // 360
        argument = degree * 4096
        quotient = ((((argument * (0xb60b60b7 - (1 << 32))) >> 32) + argument) >> 8)
        if quotient != angle:
            raise ValueError('wheel rotation reciprocal division disagrees')
        sine, cosine = direct_sine(angle), direct_sine(angle + 1024)
        if [sine, cosine] != [effect_sine(angle), effect_sine(angle + 1024)]:
            raise ValueError('wheel independent trigonometry disagrees')
        xy = [-168 + trunc_q12(-80 * sine), -128 - trunc_q12(-80 * cosine)]
        # A second calculation follows each signed shift and packed-coordinate write.
        # Ordinary draw translations keep these within the packed signed ranges.
        sin_product, cos_product = -80 * effect_sine(angle), -80 * effect_sine(angle + 1024)
        sx = (sin_product + (4095 if sin_product < 0 else 0)) >> 12
        sy = (cos_product + (4095 if cos_product < 0 else 0)) >> 12
        for center in ((0, 0), (160, 120), (-160, -120), (320, 240)):
            x, y = center[0] + sx, center[1] - sy
            packed = ((x & 32767) << 1) | ((y & 16383) << 18)
            x = ((packed << 16) & 0xffffffff) >> 17
            if x & 16384: x -= 32768
            y = packed >> 18
            if y & 8192: y -= 16384
            x, y = x - 168, y - 128
            auxiliary = [x, y + 48]
            if [x - center[0], y - center[1]] != xy or auxiliary != [center[0] + xy[0], center[1] + xy[1] + 48]:
                raise ValueError('independent packed wheel geometry disagrees')
        offsets.append(xy)
        basis.append([sine, cosine])
    # Check the native projection's room-specific viewport against both readers.
    room = scene.room_record(data, 28)
    primary = scene.section_off(data, room['section'])
    companion = scene.section_off(data, room['byte9'])
    primary_tiles = struct.unpack_from('<HH', data, primary)
    companion_map = scene.tilemap(data, companion, companion + 0x14)
    secondary_pointer = struct.unpack_from('<I', data, primary + 0x18)[0] - 0x80010000
    companion_tiles = struct.unpack_from('<HH', data, companion)
    if (primary_tiles != (22, 32) or companion_tiles != (24, 32) or
            secondary_pointer != 0x12d8c or companion_map['offset'] != secondary_pointer or
            (companion_map['w'], companion_map['h']) != companion_tiles):
        raise ValueError('independent wheel map headers disagree')
    viewport = [min(primary_tiles[0] * 16, 320), min(primary_tiles[1] * 16, 240)]
    for address, expected in ((0x80140548, 0x28420140), (0x80140554, 0x34050140),
                              (0x8014056c, 0x284200f0), (0x80140578, 0x340400f0),
                              (0x80140588, 0xa4c20028), (0x801405a0, 0xa4c2002a),
                              (0x8014f350, 0x4a486012), (0x8014f354, 0xe8d90000),
                              (0x8014f358, 0xe8da0004)):
        if word(address) != expected:
            raise ValueError('wheel viewport/pivot or signed matrix output changed')
    camera_raw = main[2048 + 0x8012ca44 - base:2048 + 0x8012cb10 - base]
    camera_independent = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(0x8012ca44, 0x8012cb10, 4))
    if camera_raw != camera_independent:
        raise ValueError('wheel camera readers disagree')
    for address, expected in ((0x8012ca68, 0x2442ff68), (0x8012ca7c, 0x2463ff90),
                              (0x8012cab8, 0x2442fec0), (0x8012caf0, 0x2442ff10),
                              (0x8013e684, 0x0c04b291), (0x8013f140, 0x0c04f914),
                              (0x8013f148, 0x0c04fb5b)):
        if word(address) != expected:
            raise ValueError('wheel aligned camera or pan order changed')
    camera_starts = {}
    for variant in variants:
        if variant['entity'] not in (2, 3, 4):
            continue
        first = variant['instructions'][0]
        if first['opcode'] != 0x10:
            raise ValueError('wheel camera has no preceding alignment')
        cells = first['operands']
        scroll = [max(0, min(cell * 8 - bias, size * 16 - limit))
                  for cell, bias, size, limit in zip(cells, (152, 112), primary_tiles, viewport, strict=True)]
        # Literal unsigned focus bytes and signed subcell offsets from the consumer.
        independent = []
        for cell, bias, size, limit in zip(cells, (152, 112), primary_tiles, viewport, strict=True):
            value = ((cell & 255) << 3) + 0 - bias
            if value < 0: value = 0
            if size * 16 - limit < value: value = size * 16 - limit
            independent.append(value)
        if scroll != independent or scroll != ([16, 0] if variant['entity'] == 3 else [16, 160]):
            raise ValueError('wheel aligned camera projection disagrees')
        camera_starts[str(variant['entity'])] = {'kind': 'set_camera', 'x': scroll[0], 'y': scroll[1]}
    for address, expected in ((0x80130a48, 0x90830441), (0x80130a50, 0x10600003),
                              (0x80130a58, 0x11000028), (0x800c3f88, 0x92a40004),
                              (0x800c3f98, 0x00641823), (0x800c3fa8, 0x92a40005),
                              (0x800c3fb4, 0x00441023)):
        if word(address) != expected:
            raise ValueError('wheel actor coordinate hold or sheet anchor consumer changed')
    hero_raw, hero_origin = source('/04_PLAY/SHU.BIN')
    if hero_origin['sha256'] != 'e9fdbee8391cc74349a091428767e208a4255960eeb4a118952cb612088b2428':
        raise ValueError('wheel Hero graphics source changed')
    hero_section = struct.unpack_from('<I', hero_raw, 0x28)[0]
    hero_sheets = struct.unpack_from('<I', hero_raw, hero_section + 16)[0]
    for degree, (sx, sy) in enumerate(basis):
        # Literal packed coordinate projection, then GPU centre and sheet anchor.
        px = 160 + trunc_q12(-80 * sx) - 168
        py = 120 - trunc_q12(-80 * sy) - 128
        packed = ((px & 32767) << 1) | ((py & 16383) << 18)
        signed_x = (packed >> 1) & 32767
        if signed_x & 16384: signed_x -= 32768
        signed_y = packed >> 18
        if signed_y & 8192: signed_y -= 16384
        for sheet_index in range(12):
            sheet = struct.unpack_from('<I', hero_raw, hero_sheets + sheet_index * 4)[0]
            ax, ay = hero_raw[sheet + 4:sheet + 6]
            if [signed_x + 160 - ax, signed_y + 120 - ay] != [offsets[degree][0] + 320 - ax, offsets[degree][1] + 240 - ay]:
                raise ValueError('wheel native screen anchor differs from packed sprite consumer')
    # Scripted constructors use sequence1/frame0; the auxiliary sheet is retained.
    from parse_04play import Parser
    parser = Parser(hero_raw, 0xb0000000)
    parsed_hero = parser.parse_section('S2', hero_section)
    shadow_sheet_index, _ = parsed_hero['f']['entries'][1]['sequence']['pairs'][0]
    shadow_sheet = struct.unpack_from('<I', hero_raw, hero_sheets + shadow_sheet_index * 4)[0]
    shadow_header = tuple(hero_raw[shadow_sheet:shadow_sheet + 8])
    shadow_piece = tuple(hero_raw[shadow_sheet + 8:shadow_sheet + 16])
    parsed_sheet = parsed_hero['e']['entries'][shadow_sheet_index]['record']
    parsed_piece = parsed_sheet['sub_pieces'][0]
    if (parser.errors or shadow_sheet_index != 3 or shadow_header != (1, 0, 24, 48, 3, 36, 0, 0)
            or shadow_piece != (0, 0, 0, 96, 23, 47, 0, 0)
            or parsed_sheet['header_hex'] != hero_raw[shadow_sheet:shadow_sheet + 8].hex()
            or tuple(parsed_piece.values()) != shadow_piece
            or parsed_hero['f']['entries'][1]['sequence']['flags'] != 3):
        raise ValueError('independent wheel auxiliary sheet readers disagree')
    for address, expected in ((0x8013a7d4, 0x0c030f4e), (0x8013a7d8, 0x34050001),
                              (0x8013ab74, 0x0c04e9dc), (0x8013ab7c, 0xae22fffc),
                              (0x8013ab80, 0xa0400002), (0x8012ea60, 0xa0450000),
                              (0x80134448, 0x0c0310ba), (0x8013444c, 0x34050022),
                              (0x80134458, 0xa0620019), (0x800c4190, 0x2402fd56),
                              (0x800c4198, 0x34020aaa), (0x800c4188, 0x30420001)):
        if word(address) != expected:
            raise ValueError('wheel auxiliary construction or scale changed')
    for variant in variants:
        if 'choreography' not in variant: continue
        for source_track in variant['choreography']['tracks']:
            if any(c['kind'] not in ('move', 'finish') or c.get('direction', 'up') not in ('up', 'down') for c in source_track['commands']):
                raise ValueError('wheel auxiliary needs a new movement/direction case')
    # Signed matrix shifts agree with a separate integer floor of each corner.
    shadow_size, shadow_scale = [23, 47], [0xaaa, -0x2aa]
    shadow_extent = [size * scale // 4096 for size, scale in zip(shadow_size, shadow_scale, strict=True)]
    if shadow_extent != [15, -8] or shadow_extent != [(23 * 2730) >> 12, (-47 * 682) >> 12]:
        raise ValueError('wheel auxiliary vertex projection disagrees')
    def f32(value):
        return struct.unpack('<f', struct.pack('<f', value))[0]
    import math
    for channel in range(32):
        expanded = channel * 255 // 31
        restored = math.floor(f32(f32(expanded / 255) * 31) + 0.5)
        shader = math.floor(f32(f32(restored * 34) / 128))
        if restored != channel or shader != (channel * 34) >> 7:
            raise ValueError('wheel auxiliary palette/shader arithmetic disagrees')
    shadow = {'source_variant': 1, 'source_frame': 0, 'sheet_index': shadow_sheet_index,
              'crop_pixels': shadow_size, 'sheet_pixels': [24, 48], 'anchor_pixels': [3, 36],
              'scale_q12': shadow_scale, 'projected_extent_pixels': shadow_extent,
              'shade': 34, 'semitransparent': False,
              'modulation': 'RGB5 times shade, floor divide128, then linear RGB888 expansion',
              'scope': 'retained up-facing frame0, ordinary vertical wheel tracks; no jump or horizontal-direction path'}
    geometry = {'bodies': geometry_bodies, 'quarter_wave_sha256': quarter_hash,
                'angle_units_per_turn': 4096, 'radius_pixels': 80,
                'auxiliary_below_primary_pixels': 48,
                'primary_relative_to_translation': offsets, 'rotation_basis_q12': basis,
                'coordinate_contract': 'signed packed sprite anchor offsets relative to the secondary-map pivot, before adding the draw-environment centre and subtracting the current sheet anchor; not bitmap origins or entity world coordinates',
                'verification': '360 angles times four translations; independent quadrant/sine readers and literal packed-coordinate writes agree',
                'draw_consumer': {'active_call': 0x80134380, 'active_renderer': 0x8014ceb4,
                                  'idle_call': 0x80134398, 'idle_renderer': 0x8014c008},
                'map_angle_gate': 'alignment changes logical angle and image origins; root rotation is written only while the motion flag was active on entry',
                'projection': {'viewport_pixels': viewport, 'tile_pixels': 16,
                               'map_pixels': [companion_tiles[0] * 16, companion_tiles[1] * 16],
                               'map_offset': secondary_pointer,
                               'aligned_camera_commands': camera_starts,
                               'camera_body_sha256': hashlib.sha256(camera_raw).hexdigest(),
                               'pivot_pixels': [160, 120], 'rounding': 'signed_floor_q12',
                               'sampling': 'wrap_both_axes_split_at_source_tile_and_viewport_edges',
                               'preconditions': 'unit scale and identity field-library base transform; camera origin supplied separately'},
                'actor_drawing': {'hero_source': hero_origin, 'normal_coordinate_hold': 'wheel visible and vertical subcell offset zero',
                                  'native_anchor_offset': viewport, 'sheet_anchor_after_geometry': True,
                                  'verified_angle_sheet_cases': 360 * 12,
                                  'auxiliary': shadow,
                                  'scope': 'primary and bounded auxiliary drawing data; connected scene rendering remains unverified'},
                'scope': 'source geometry, primary sprite anchors and viewport projection; ordinary camera/display mapping and composed scene execution remain unbound'}
    returning = next(variant for variant in variants if variant['entity'] == 3)
    if next(row['operands'] for row in returning['instructions'] if row['opcode'] == 0x34) != [1, 8, 0, 21, 11]:
        raise ValueError('wheel return actor construction changed')
    return_actor = 'vb3_room_28_return_hero'
    return_choreography = hq_choreography(data,
        [(r['offset'], r['opcode'], r['operands'], '') for r in returning['instructions']],
        {64: {'native_actor_id': return_actor}}, word, (0, 2, [(0, 1, 80), (0, 1, 136)]))
    if any(c['kind'] not in ('move', 'finish') or c.get('direction', 'down') != 'down'
           for source_track in return_choreography['tracks'] for c in source_track['commands']):
        raise ValueError('wheel return auxiliary needs a new movement case')
    visibility_bodies = []
    for lo, hi, digest in ((0x8013c82c, 0x8013c8e4, 'f765f6c42173870c9ed748a04f4cf9b51cb49c8c6dee84566d3082448669dcb8'),
                           (0x8012fd10, 0x801300ec, '339a1365c86cebd706a6c7be2279d8fcd768b9b0b4122f6a4b09a36734cf9f3b'),
                           (0x8013c8e4, 0x8013cb78, 'b6fe4fee154b7006023774bd755eaf95f13440068faf6f364a1e9b6d4c265804')):
        direct = main[2048 + lo - base:2048 + hi - base]
        independent = b''.join(struct.pack('<I', maindec.mword(pc)) for pc in range(lo, hi, 4))
        if direct != independent or hashlib.sha256(direct).hexdigest() != digest:
            raise ValueError('fixed Hero release/position consumer body changed')
        visibility_bodies.append({'start': lo, 'end': hi, 'sha256': digest})
    for address, expected in {0x8013c8c0: 0xa0600005, 0x8013c8cc: 0x340200f0,
                              0x8013c8d0: 0xa0620000, 0x8013c8d4: 0x340200fe,
                              0x8013c8d8: 0xa0620001, 0x8012fd78: 0x92240000,
                              0x8012fda0: 0x000420c0, 0x8012fdc4: 0x92220001,
                              0x8012fdd8: 0x000210c0, 0x8012fdf4: 0xae450004,
                              0x8013ca04: 0xa0820000, 0x8013ca34: 0xa0820001}.items():
        if word(address) != expected: raise ValueError('fixed Hero offscreen/restore contract changed')
    return_scene = {'actor': {'id': return_actor, 'entity': 3, 'character': 8,
                              'spawn_pixels': [168, 88], 'direction_operand': 0},
                    'choreography': return_choreography,
                    'visibility_bodies': visibility_bodies,
                    'fixed_hero_release': {'offscreen_cells': [240, 254], 'clears_motion': True,
                                          'restore_pixels': [168, 328]},
                    'scope': 'two tracks/two pans and fixed-Hero offscreen coordinate writes qualified; native hide/atomic placement preserve visibility during this linear scene; complete wheel admission remains separate'}
    monster_entry = entries[6]
    classification, predicate = decode_predicate(data, monster_entry['stream_offsets'][0], 'classification', full=True)
    setup_at = monster_entry['stream_offsets'][0] + predicate['size']
    setup = data[setup_at:setup_at + 2]
    if struct.unpack_from('<4H', data, monster_entry['offset']) != (255, 255, 3, 200) or setup != bytes.fromhex('ff00'):
        raise ValueError('wheel offscreen Monster actor identity/setup changed')
    from opening_audience import actor_bindings
    for repeat in (0, 1):
        flags = bytearray(256)
        flags[44] = repeat
        independent_actors, _ = actor_bindings(data, 28, flags)
        if len(independent_actors) != 1 or independent_actors[0]['id'] != 'scene_actor_0':
            raise ValueError('independent wheel ordinary actor compaction disagrees')
        actor = independent_actors[0]
        if (actor['x'], actor['y'], actor['motion'], actor['variant'], actor['attached'], actor['auto_animate']) != (2040, 2040, 0, 0, True, False):
            raise ValueError('independent wheel Monster construction disagrees')
    monster_actor = {'room': 28, 'entity': 6, 'character': 200, 'record': monster_entry['offset'],
                     'position_pixels': [2040, 2040], 'classification': classification,
                     'setup_offset': setup_at, 'setup_bytes': setup.hex(), 'facing': 'down', 'speed': 0,
                     'id': 'vb3_room_28_actor_06_200'}
    return {'source': origin, 'main': main_origin, 'room': 28, 'variants': variants,
            'monster_actor': monster_actor,
            'return_scene': return_scene,
            'dialogues': dialogues, 'doors': doors, 'music': music,
            'clock_samples': samples, 'geometry': geometry,
            'clock_order': {'alignment_before_motion': True, 'spin_geometry_before_angle_advance': True,
                            'timed_turn_updates_geometry': False, 'angle_wrap': 'reset_zero_discard_overshoot',
                            'ordinary_stream_block_mask': 65532, 'motion_flag': 2048,
                            'update_after_ordinary_stream': True, 'launch_update_in_same_frame': True,
                            'start_counter': 'signed_halfword; cleared by room constructor; incremented before extra-draw test',
                            'timed_start': 'independent return start; no spin-counter increment or RNG; resets angle/turns/slowdown and sets doubled duration'},
            'item_rewards': rewards,
            'item_result': {'success_mode': 1, 'full_mode': 0, 'message_suffix': item_suffix,
                            'full_transition': {'selector': 8, 'index': 0},
                            'scope': 'first active party bag below nine slots; full result enters source item management; not a discarded reward'},
            'monster': {'section': section, 'context_count': context_count, 'context_table': context_table,
                        'directory': directory, 'selectors': selectors, 'encounters': encounters, 'enemies': enemies,
                        'battlefield': battle_placement.directory_battlefield(data, directory, 0x80010000)},
            'repeat_reward_writer': {'entity': 5, 'offset': entries[5]['stream_offsets'][2],
                                     'selection': decode_predicate(data, entries[5]['stream_offsets'][1], 'event', coordinate_ranges=True, full=True)[0],
                                     'scenario_byte': 44, 'mask': 1},
            'rules': {'initial_speed_degrees_per_update': 18, 'initial_distance_degrees': 1081,
                      'random_distance_divisor': 90, 'deceleration_below_degrees': 721,
                      'deceleration_accumulator_threshold': 60, 'continued_speed_degrees_per_update': 2,
                      'extra_discarded_random_draw_from_spin': 6, 'angle_intervals': intervals,
                      'alignment_angle_degrees': 180, 'turn_degrees': 360,
                      'default_outcome': 6},
            'scope': 'complete scripts including all seven branch arms and return scene; independent MAIN/operand readers agree; experience/Monster/reward-message consumers and offscreen actor construction qualified; native spin/return/reward-watch programs compile separately; room admission still requires graphics, sound-bank/presentation and connected execution; no wheel result or passage flag is supplied'}


def kouan_ladder():
    from export_first_room import area_room_walkable_grid
    from export_scene_population import PAD_DIRECTION_MASKS
    data, origin = source('/VB3.BIN')
    if origin['sha256'] != '67c548a5e5e7047da175e37c98c61506ec60da40ef9a990d63c93f8a464d3410':
        raise ValueError('unsupported mansion ladder source')
    main, main_origin = source('MAIN.EXE')
    if main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported mansion ladder consumer')
    base = struct.unpack_from('<I', main, 24)[0]
    words = {0x800c1b24: 0x80141be8, 0x80141bf4: 0x906201bb,
             0x80141bfc: 0x38420040, 0x80141c04: 0xa06201bb,
             0x8013d230: 0xa022a180, 0x8013d240: 0xa020a180,
             0x801399dc: 0x94a20024, 0x801399ec: 0x8ca20028,
             0x801399f0: 0x00041880, 0x801399f4: 0x00641821,
             0x801399fc: 0x90650002, 0x80139a6c: 0x0c030f4e,
             0x8013ea40: 0x8c250000, 0x8013ea44: 0x0c04f9ad,
             0x8013e6d8: 0xa0820000, 0x8013e6f0: 0xa0820001}
    for address, expected in words.items():
        if struct.unpack_from('<I', main, 2048 + address - base)[0] != expected or maindec.mword(address) != expected:
            raise ValueError('independent ladder consumer reads disagree')
    forward = [struct.unpack_from('<I', main, 2048 + 0x80171b98 - base + i * 4)[0] for i in range(4)]
    reverse = [struct.unpack_from('<I', main, 2048 + 0x80171ba8 - base + i * 4)[0] for i in range(4)]
    vectors = main[2048 + 0x801715a0 - base:2048 + 0x801715b0 - base]
    if forward != [1, 3, 0, 2] or reverse != [0, 2, 1, 3] or vectors != bytes.fromhex('000100f800ff0008ff0008000100f800'):
        raise ValueError('ladder source direction tables changed')
    if any(maindec.mword(table + i * 4) != value for table, values in ((0x80171b98, forward), (0x80171ba8, reverse)) for i, value in enumerate(values)):
        raise ValueError('independent ladder direction table readers disagree')
    if vectors != maindec.body()[0x801715a0 - maindec.MBASE:0x801715b0 - maindec.MBASE]:
        raise ValueError('independent ladder vectors disagree')
    rows = []
    for room, entity, start, literal in (
            (12, 2, 0x42f84, '4219030e0e03fd'), (12, 3, 0x42f7c, '030e0e03fd'),
            (13, 0, 0x42fa4, '030e171afd'), (13, 1, 0x42fac, '030f171afd'),
            (14, 0, 0x43098, '4219030c281cfd'), (14, 1, 0x43064, '030c281cfd'),
            (14, 2, 0x4306c, '030d091dfd'),
            (14, 3, 0x43074, '328004010000070a02000533fd'),
            (14, 4, 0x43084, '32800401000a0533fd'),
            (14, 5, 0x43090, '303e0031fd'), (15, 0, 0x430a0, '030d131dfd')):
        entry = scene.entities(data, scene.room_record(data, room))[entity]
        raw = bytes.fromhex(literal)
        if entry['stream_offsets'][2] != start or data[start:start + len(raw)] != raw:
            raise ValueError('ladder chamber stream changed')
        instructions, cursor = [], start
        for pc, op, args, _ in decode_stream(data, start, max_insns=8):
            if op == 0x32:
                stop = pc + 2
                while data[stop] != 5:
                    if data[stop] not in (0, 1, 2, 3, 4, 7):
                        raise ValueError('unsupported ladder track action')
                    stop += 2
                count = stop - pc
            else:
                count = {3: 3, 0x42: 1, 0x30: 0, 0x31: 0, 0x3e: 1, 0x33: 0, 0xfd: 0}[op]
            if pc != cursor or bytes(args) != data[pc + 1:pc + 1 + count]:
                raise ValueError('independent ladder operand walk disagrees')
            cursor += 1 + count
            instructions.append({'offset': pc, 'opcode': op, 'operands': list(args)})
            if op == 0xfd:
                break
        if cursor != start + len(raw):
            raise ValueError('ladder stream not fully consumed')
        selection, debug = decode_predicate(data, entry['stream_offsets'][1], 'event', full=True, coordinate_ranges=True)
        masks = [PAD_DIRECTION_MASKS[t['operands'][0]] for t in debug['terms'] if t['opcode'] == 4]
        for instruction in instructions:
            if instruction['opcode'] == 3:
                target, x, y = instruction['operands']
                width, height, cells = area_room_walkable_grid(data, scene.section_off(data, scene.room_record(data, target)['section']), '/VB3.BIN', target)
                if not (x < width and y < height and cells[y * width + x] == '1'):
                    raise ValueError('ladder source arrival blocked')
        rows.append({'room': room, 'entity': entity, 'offset': start, 'bytes': literal, 'consumed': len(raw),
                     'initialization': bool(entry['flags'] & 16), 'selection': selection,
                     'pressed_masks': masks, 'instructions': instructions})
    section = scene.section_off(data, 14)
    scenery = scene.scenery_template(data, section, 0)
    index, record_offset = scenery['index'], scenery['offset']
    record = bytes(scenery[key] for key in ('x_half', 'y_half', 'type', 'order', 'b4'))
    context = scene.contexts(data, section)[0]['offset']
    descriptor = scene.descriptor_sheet(data, context, record[2])
    if index != 3 or record != bytes.fromhex('0e0a49f801') or data[descriptor['descriptor']:descriptor['descriptor'] + 6] != bytes.fromhex('0100040054ff'):
        raise ValueError('ladder prop definition changed')
    track_rows = [tuple((i['offset'], i['opcode'], bytes(i['operands']), '')) for row in rows for i in row['instructions'] if i['opcode'] == 0x32]
    choreography = hq_choreography(data, track_rows, {}, maindec.mword, (0, 2, []))
    climbs = []
    for row, start, expected in ((next(r for r in rows if (r['room'], r['entity']) == (14, 3)), [14, 8], [14, 18]),
                                 (next(r for r in rows if (r['room'], r['entity']) == (14, 4)), [14, 18], [14, 8])):
        raw = row['instructions'][0]['operands'][1:-1]
        position, facing = list(start), 0
        for action, value in zip(raw[::2], raw[1::2]):
            if action < 4:
                facing = action
                direction = forward[action]
            elif action == 7:
                direction = reverse[facing]
            elif action == 4:
                continue
            else:
                raise ValueError('unsupported ladder endpoint action')
            dx, dy = struct.unpack_from('<bb', vectors, direction * 4)
            position[0] = (position[0] + dx * value) & 255
            position[1] = (position[1] + dy * value) & 255
        if position != expected:
            raise ValueError('independent ladder endpoint changed')
        climbs.append({'entity': row['entity'], 'start_pixels': [v * 8 for v in start],
                       'end_pixels': [v * 8 for v in position], 'final_facing': ('up', 'right', 'down', 'left')[facing]})

    import war_text
    from opening_audience import text
    identities = []
    name_ids = bytes(maindec.mword(0x80170095 + i) & 255 for i in range(109))
    for character, expected in ((85, 'Rock'), (39, 'Juppo')):
        pointer = maindec.mword(0x80170588 + (name_ids.index(character) + 1) * 4)
        offset = 2048 + pointer - base
        name, used = war_text.decode(main, offset)
        tokens, end = text(main, offset)
        if name != expected or ''.join(t['text'] for t in tokens) != name or end - offset != used:
            raise ValueError('independent mansion resident names disagree')
        identities.append({'character': character, 'name': name, 'source_pointer': pointer})
    return {'source': origin, 'entries': rows, 'choreography': choreography, 'climbs': climbs, 'resident_names': identities,
            'source_words': {hex(a): hex(w) for a, w in words.items()},
            'prop': {'record_index': index, 'record_offset': record_offset, 'record_bytes': record.hex(), 'context': context,
                     'descriptor': descriptor, 'position_pixels': [112, 80], 'animation': 73, 'depth': 8},
            'toggle': {'command': {'kind': 'world_mode', 'code': 25}, 'scenario': 43, 'xor_mask': 64},
            'scope': 'room14 ladder initializer and both climbs, exact surrounding passages; room13 Rock/chests and onward rooms17/20 remain separate'}


def kouan_mansion_doors():
    from export_first_room import area_room_walkable_grid
    from export_scene_population import PAD_DIRECTION_MASKS
    data, origin = source('/VB3.BIN')
    if origin['sha256'] != '67c548a5e5e7047da175e37c98c61506ec60da40ef9a990d63c93f8a464d3410':
        raise ValueError('unsupported mansion passage source')
    main, main_origin = source('MAIN.EXE')
    if main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported mansion music source')
    base = struct.unpack_from('<I', main, 24)[0]
    rows = []
    for room, entity, start, literal in (
            (11, 0, 0x42f5c, '4134030c0407fd'),
            (11, 1, 0x42f64, '03001c2afd'),
            (12, 0, 0x42f74, '4133030b060efd'),
            (12, 1, 0x42f6c, '4164030b060efd')):
        entry = scene.entities(data, scene.room_record(data, room))[entity]
        raw = bytes.fromhex(literal)
        if entry['stream_offsets'][2] != start or data[start:start + len(raw)] != raw:
            raise ValueError('mansion passage stream changed')
        instructions = []
        cursor = start
        for pc, op, args, _ in decode_stream(data, start, max_insns=4):
            count = {0x41: 1, 3: 3, 0xfd: 0}[op]
            if pc != cursor or bytes(args) != data[cursor + 1:cursor + 1 + count]:
                raise ValueError('independent mansion passage operand walk disagrees')
            cursor += count + 1
            instructions.append({'offset': pc, 'opcode': op, 'operands': list(args)})
            if op == 0xfd:
                break
        if cursor != start + len(raw):
            raise ValueError('mansion passage left bytes')
        selection, debug = decode_predicate(data, entry['stream_offsets'][1], 'event', coordinate_ranges=True, full=True)
        direction = [term for term in debug['terms'] if term['opcode'] == 4]
        if direction and (room, entity, direction[0]['operands']) != (11, 1, [1]):
            raise ValueError('mansion passage direction changed')
        warp = next(row['operands'] for row in instructions if row['opcode'] == 3)
        target, hx, hy = warp
        width, height, cells = area_room_walkable_grid(data, scene.section_off(data, scene.room_record(data, target)['section']), '/VB3.BIN', target)
        if not (hx < width and hy < height and cells[hy * width + hx] == '1'):
            raise ValueError('mansion source passage arrival is blocked')
        commands = []
        for instruction in instructions:
            if instruction['opcode'] == 0x41:
                selector = instruction['operands'][0]
                address = 0x80171c2c + selector * 2
                request = struct.unpack_from('<H', main, 2048 + address - base)[0]
                independent = maindec.mword(address & ~3) >> ((address & 3) * 8) & 65535
                if request != independent or request != {51: 0x40c, 52: 0x40d, 100: 0x43d}[selector]:
                    raise ValueError('independent mansion stream requests disagree')
                commands.append({'kind': 'field_music', 'music': {51: 'area_b', 52: 'mansion', 100: 'infiltration'}[selector]})
        commands.append({'kind': 'room_transition', 'destination': f'vb3_room_{target}', 'x': hx * 8, 'y': hy * 8})
        rows.append({'room': room, 'entity': entity, 'offset': start, 'bytes': literal, 'consumed': len(raw),
                     'instructions': instructions, 'selection': selection,
                     'pressed_mask': PAD_DIRECTION_MASKS[1] if direction else None,
                     'commands': commands, 'arrival_walkable': True})
    return {'source': origin, 'doors': rows, 'stream': {'selector': 52, 'request': 0x40d, 'resource_index': 13},
            'scope': 'four original entrance/return passages; additional ladder passages are in kouan_ladder; chests and onward rooms17/20 remain unbound'}


def kouan_mansion_approach():
    from export_field_actor_bindings import source_inventory
    data, origin = source('/VB3.BIN')
    if origin['sha256'] != '67c548a5e5e7047da175e37c98c61506ec60da40ef9a990d63c93f8a464d3410':
        raise ValueError('unsupported Kouan approach source')
    entries = scene.entities(data, scene.room_record(data, 0))
    entry = entries[15]
    start, end = 0x412bc, 0x41338
    literal = bytes.fromhex('101f2d1180001103020b0312000f1c000018020c460a05320303000602060006020600060205330a030d01000a051103020a050b0312000f1c000019020c46340123001f2d324001030000053317401201231c01001a02180b0312000f1c00001b020c0a0a324003030533393280030200000533092f40030b2310fd')
    if (entry['id'], entry['stream_offsets'][2], data[start:end]) != (15, start, literal):
        raise ValueError('Kouan approach stream identity changed')
    rows = []
    for row in decode_stream(data, start, max_insns=64):
        rows.append(row)
        if row[1] == 0xfd:
            break
    sizes = {0x10: 2, 0x11: 2, 0x0b: 1, 0x12: 2, 0x1c: 3, 2: 0,
             0x0c: 0, 0x46: 0, 0x0a: 1, 0x33: 0, 0x17: 1, 0x18: 0,
             0x39: 0, 9: 2, 3: 3, 0xfd: 0}
    cursor = start
    for pc, op, args, _ in rows:
        if op in (0x34, 0x0d):
            count = 1 + data[cursor + 1] * (4 if op == 0x34 else 1)
        elif op == 0x32:
            stop = cursor + 2
            while data[stop] != 5:
                if data[stop] not in (0, 1, 2, 3, 6):
                    raise ValueError('unsupported approach movement')
                stop += 2
            count = stop - cursor
        else:
            count = sizes[op]
        if pc != cursor or data[pc + 1:pc + 1 + count] != args:
            raise ValueError('independent approach operand walk disagrees')
        cursor += 1 + count
    if cursor != end or len(rows) != 45:
        raise ValueError('Kouan approach not fully consumed')
    main, main_origin = source('MAIN.EXE')
    if main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported approach prop consumer')
    base = struct.unpack_from('<I', main, 24)[0]
    words = {0x8013ad08: 0x8c730094, 0x8013ad50: 0x8c44002c,
             0x8013ad54: 0x02631821, 0x8013ad58: 0x00031080,
             0x8013ad5c: 0x00431021, 0x8013ad9c: 0x90850002,
             0x8013ada0: 0x8c420020, 0x8013ada8: 0x8c440000,
             0x8013adac: 0x0c030f4e, 0x80137ab0: 0x94420026,
             0x80137abc: 0x00021202, 0x80137ac0: 0xac620094,
             0x8012f7d4: 0x90c50002, 0x8012f7d8: 0x0c030fbc}
    for address, expected in words.items():
        if struct.unpack_from('<I', main, 2048 + address - base)[0] != expected or maindec.mword(address) != expected:
            raise ValueError('independent approach prop consumer reads disagree')
    section = scene.section_off(data, scene.room_record(data, 0)['section'])
    record_index = struct.unpack_from('<H', data, section + 0x26)[0] >> 8
    record_table = scene.ptr_at(data, section + 0x2c)
    record_offset = record_table + record_index * 5
    scenery = scene.scenery_record(data, record_offset, record_index)
    record = bytes(scenery[key] for key in ('x_half', 'y_half', 'type', 'order', 'b4'))
    if record_index != 6 or record != bytes.fromhex('1d2123d401'):
        raise ValueError('Kouan approach prop record changed')
    context = scene.contexts(data, section)[0]['offset']
    prop = scene.descriptor_sheet(data, context, record[2])
    if data[prop['descriptor']:prop['descriptor'] + 6] != bytes.fromhex('010006002cff'):
        raise ValueError('Kouan approach prop is no longer a single draw')
    destination = scene.room_record(data, 11)
    from export_first_room import area_room_walkable_grid
    width, height, cells = area_room_walkable_grid(data, scene.section_off(data, destination['section']), '/VB3.BIN', 11)
    if cells[16 * width + 35] != '1':
        raise ValueError('Kouan approach source spawn is blocked')
    actors = {3: {'native_actor_id': 'vb3_room_0_actor_15_015'},
              64: {'native_actor_id': 'vb3_room_0_approach_viktor'}}
    choreography = hq_choreography(data, rows, actors, maindec.mword, (4, 4, []))
    if [speech['speaker_name'] for speech in choreography['dialogues']] != ['Krin', 'Krin', 'Viktor', 'Krin']:
        raise ValueError('Kouan approach speakers changed')
    selectors, lifetimes = source_inventory(data, entries, 15, 'vb3_room_0_e15_interaction', 'vb3_room_0', False)
    return {'source': origin, 'room': 0, 'entity': 15, 'offset': start, 'end': end,
            'bytes': literal.hex(), 'consumed': end - start,
            'instructions': [{'offset': pc, 'opcode': op, 'operands': list(args)} for pc, op, args, _ in rows],
            'classification': decode_predicate(data, entry['stream_offsets'][0], 'classification', full=True)[0],
            'selection': decode_predicate(data, entry['stream_offsets'][1], 'event', coordinate_ranges=True)[0],
            'choreography': choreography, 'selectors': selectors, 'lifetimes': lifetimes,
            'actors': [{'selector': key, **value} for key, value in actors.items()],
            'prop': {'offset': 0x412e5, 'opcode': 13, 'selectors': [0], 'record_index': record_index, 'record_offset': record_offset,
                     'record_bytes': record.hex(), 'position_pixels': [record[0] * 8, record[1] * 8],
                     'animation': record[2], 'context': context, 'descriptor': prop,
                     'depth': scene.GROUND_DEPTH_ORIGIN - scene.scenery_tag(record[3], scene.room_record(data, 0)),
                     'consumer': 'MAIN8013ACB0; selected section+2C five-byte record at area-state+94 + selector; context0 animation',
                     'source_words': {hex(a): hex(w) for a, w in words.items()}},
            'transition': {'offset': 0x41333, 'destination_room': 11, 'spawn_pixels': [280, 128], 'walkable': True},
            'scope': 'complete bounded source inventory; native prop/approach emission and exact destination admission are being integrated; no operation is omitted'}


def krin_plan():
    from event_script_decode import switch_2f_targets
    from export_field_actor_bindings import source_inventory
    data, origin = source('/VB3.BIN')
    if origin['sha256'] != '67c548a5e5e7047da175e37c98c61506ec60da40ef9a990d63c93f8a464d3410':
        raise ValueError('unsupported Krin plan source')
    main, main_origin = source('MAIN.EXE')
    if main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported Krin fade source')
    base = struct.unpack_from('<I', main, 24)[0]
    words = {0x80139c50: 0x34420040, 0x80139c5c: 0x340200ff, 0x80139c60: 0xa06204dc,
             0x80139c6c: 0x34020002, 0x80139c7c: 0x34020001, 0x80139c84: 0x34020080,
             0x80139c8c: 0xac221594, 0x80139c90: 0x3402000a, 0x80139c94: 0x0c04cfd4, 0x80139ca4: 0x03e00008,
             0x8013e1c0: 0xa020a180, 0x8013f0f0: 0x9442c028, 0x8013f0f8: 0x3042fffc, 0x8013f11c: 0x0c04fc30,
             0x8013f124: 0x14400004, 0x8013f12c: 0x0c04f80a,
             0x8013e154: 0x3c028018, 0x8013e158: 0x9042a180, 0x8013e160: 0x1440ffb4,
             0x8013eef0: 0x90820039, 0x8013eef8: 0x00021040, 0x8013eefc: 0x00621823,
             0x8013ef00: 0xa08304dc, 0x8013ef1c: 0x0043102a, 0x8013ef20: 0x1440004d,
             0x8013ef34: 0x38420040, 0x8013ef40: 0xa08004dc, 0x8013ef4c: 0x34020080,
             0x8013ef54: 0xac221594, 0x8013ef5c: 0xac6004d8,
             0x8013f214: 0xac23a120, 0x8013f268: 0x24420018, 0x8013e1f8: 0x8c420014,
             0x80139adc: 0x8c42a120, 0x80139ae4: 0x94420004, 0x80139aec: 0x30420010,
             0x80139af0: 0x10400003, 0x80139afc: 0xa022bfe4, 0x80139b28: 0x000210c0,
             0x80139b30: 0xac22c008, 0x80139b3c: 0x000210c0, 0x80139b44: 0xac22c010,
             0x8013fb7c: 0x10a20007, 0x8013fba4: 0x0c04fd61}
    for address, expected in words.items():
        if struct.unpack_from('<I', main, 2048 + address - base)[0] != expected or maindec.mword(address) != expected:
            raise ValueError('independent Krin fade consumer reads disagree')
    music_address = 0x80171c2c + 100 * 2
    if int.from_bytes(main[2048 + music_address - base:2048 + music_address - base + 2], 'little') != 0x43d or maindec.mword(music_address) & 65535 != 0x43d:
        raise ValueError('Krin plan music selector changed')
    entries = scene.entities(data, scene.room_record(data, 2))
    variants = []
    sizes = {0xb: 1, 0x12: 2, 0x1c: 3, 2: 0, 0xc: 0, 0x17: 1, 0x18: 0, 5: 3,
             0x2f: 2, 0xa: 1, 0x46: 0, 0x24: 0, 7: 3, 0x11: 2, 0x26: 2, 0x25: 0,
             0x33: 0, 0x3a: 1, 0x29: 2, 0x41: 1, 0x39: 0, 9: 2, 0xfd: 0, 0xfc: 0, 0xfe: 0}
    def walk(start, end, count):
        rows = []
        for row in decode_stream(data, start, max_insns=160):
            rows.append(row)
            if row[1] == 0xfd: break
        cursor = start
        for pc, opcode, args, _ in rows:
            if opcode == 0x34:
                size = 1 + 4 * data[cursor + 1]
            elif opcode == 0x3b:
                size = 1 + data[cursor + 1]
            elif opcode == 0x32:
                stop = cursor + 2
                while data[stop] != 5:
                    if data[stop] not in range(4): raise ValueError('unsupported Krin movement')
                    stop += 2
                size = stop - cursor
            else:
                size = sizes[opcode]
            if pc != cursor or data[pc + 1:pc + 1 + size] != args:
                raise ValueError('independent Krin operand walk disagrees')
            cursor += size + 1
        if cursor != end or len(rows) != count:
            raise ValueError('Krin branch not fully consumed')
        return rows
    def serialized(rows):
        return [{'offset': pc, 'opcode': op, 'operands': list(args)} for pc, op, args, _ in rows]
    for entity, start, end, count, label, refusal_end, refusal_count in (
            (5, 0x416fc, 0x4182f, 121, 0xfc, 0x4183f, 8),
            (4, 0x41840, 0x41964, 113, 0xfe, 0x41971, 7)):
        if entries[entity]['stream_offsets'][2] != start or entries[entity]['stream_offsets'][0] is not None or data[end] != label or entries[entity]['flags'] != 3 or struct.unpack_from('<H', data, entries[entity]['offset'] + 4)[0] != 3:
            raise ValueError('Krin plan caller changed')
        rows, refusal = walk(start, end, count), walk(end, refusal_end, refusal_count)
        branch = next(pc for pc, op, _, _ in rows if op == 0x2f)
        targets = switch_2f_targets(data, branch)
        if targets != {0: branch + 3, 1: end} or data[branch + 1:branch + 3] != bytes((130, label)):
            raise ValueError('independent Krin choice label scan disagrees')
        actors = {2: {'native_actor_id': 'vb3_room_2_actor_03_015'},
                  64: {'native_actor_id': f'vb3_room_2_krin_{entity}_gremio'},
                  65: {'native_actor_id': f'vb3_room_2_krin_{entity}_cleo'},
                  66: {'native_actor_id': f'vb3_room_2_krin_{entity}_viktor'}}
        choreography = hq_choreography(data, rows, actors, maindec.mword, (17, 4, []))
        refused_dialogue = hq_choreography(data, refusal, actors, maindec.mword, (1, 0, []))['dialogues'][0]
        if [speech['index'] for speech in choreography['dialogues']] != [5 if entity == 5 else 10, 6, 8, 7, *range(11, 24)]:
            raise ValueError('Krin dialogue sequence changed')
        if [(row[1], bytes(row[2])) for row in rows if row[1] in (0x34, 0x3b)] != [(0x3b, bytes.fromhex('0408020123')), (0x34, bytes.fromhex('030203060c0101061223010912'))]:
            raise ValueError('Krin companion staging changed')
        if [bytes(args) for _, op, args, _ in rows if op == 9] != [bytes.fromhex('0d04')]:
            raise ValueError('Krin accepted story writer changed')
        if [bytes(args) for _, op, args, _ in refusal if op == 9] != ([bytes.fromhex('0d02')] if entity == 5 else []):
            raise ValueError('Krin refusal story writer changed')
        if [bytes(args) for _, op, args, _ in rows if op == 0x29] != [bytes.fromhex('2f40'), bytes.fromhex('2f80')]:
            raise ValueError('Krin scene reset flags changed')
        if [bytes(args) for _, op, args, _ in rows if op == 0x26] != [bytes((0, 1))] or [bytes(args) for _, op, args, _ in rows if op == 0x41] != [bytes((100,))]:
            raise ValueError('Krin camera/music operands changed')
        selectors, lifetimes = source_inventory(data, entries, entity, f'vb3_room_2_e{entity:02d}_interaction', 'vb3_room_2', False)
        variants.append({'entity': entity, 'start': start, 'end': end, 'bytes': data[start:end].hex(), 'consumed': end - start,
                         'instructions': serialized(rows), 'selection': decode_predicate(data, entries[entity]['stream_offsets'][1], 'event', coordinate_ranges=True)[0],
                         'camera': {'pixels': [0, 8], 'entry_flags': 3, 'transition_flag_write': False},
                         'choice_offset': branch, 'targets': {str(k): v for k,v in targets.items()}, 'choreography': choreography,
                         'refusal': {'start': end, 'end': refusal_end, 'bytes': data[end:refusal_end].hex(), 'consumed': refusal_end - end,
                                     'instructions': serialized(refusal), 'dialogue': refused_dialogue,
                                     'story_or': {'scenario': 13, 'mask': 2} if entity == 5 else None},
                         'selectors': selectors, 'lifetimes': lifetimes,
                         'accepted_story_or': {'scenario': 13, 'mask': 4},
                         'native': {'commands': 130 if entity == 5 else 121, 'anchors': 17, 'prefixes': 17, 'owner_actor': 'vb3_room_2_actor_03_015'},
                         'scene_actors': [{'selector': selector, 'actor': actors[selector]['native_actor_id'], 'character': character,
                                           'direction_operand': direction, 'spawn_pixels': [x * 8, y * 8]}
                                          for selector, character, direction, x, y in ((64, 2, 3, 6, 12), (65, 1, 1, 6, 18), (66, 35, 1, 9, 18))]})
    return {'source': origin, 'main': main_origin, 'room': 2, 'variants': variants,
            'inherited_actor': {'entity': 3, 'id': 'vb3_room_2_actor_03_015', 'position_pixels': [192, 152],
                                'classification': decode_predicate(data, entries[3]['stream_offsets'][0], 'classification', full=True)[0]},
            'fade_in': {'opcode': 37, 'initial_level': 255, 'amount_per_update': 8, 'updates': 31,
                        'completion_level': 0, 'clears_overlay': True, 'blocks_next_script_pump': True,
                        'words': {hex(a): hex(w) for a,w in words.items()}},
            'music': {'selector': 100, 'request': 0x43d, 'table_address': music_address},
            'scope': 'complete bounded first/retry acceptance and refusal source inventories; both lower in candidate39/IR17 with explicit inherited owner, choice prefix, linear actor suffix, camera reset and source043D stream; source-event execution, post-scene camera follow, fresh-process continuation, device cadence and media acceptance remain unverified'}


def hq_departure():
    from event_script_decode import switch_2f_targets
    from opening_audience import text
    import war_text

    data, origin = source('/VB5AG.BIN')
    if origin['sha256'] != CASTLE_SOURCES['/VB5AG.BIN']:
        raise ValueError('unsupported headquarters departure source')
    entity = scene.entities(data, scene.room_record(data, 0))[1]
    start, end = 0x46280, 0x4629a
    literal = bytes.fromhex('17801201081c01030005000201182f82fc420c03fb09644bfcfd')
    if entity['stream_offsets'][2] != start or data[start:end] != literal:
        raise ValueError('headquarters departure stream changed')
    rows = []
    for row in decode_stream(data, start, max_insns=12):
        rows.append(row)
        if row[1] == 0xfd:
            break
    cursor = start
    for (pc, opcode, args, _), size in zip(rows, (2, 3, 4, 4, 1, 3, 2, 5, 1, 1), strict=True):
        if pc != cursor or data[pc] != opcode or data[pc + 1:pc + size] != args:
            raise ValueError('independent departure operand walk disagrees')
        cursor += size
    targets = switch_2f_targets(data, 0x4628e)
    if cursor != end or targets != {0: 0x46291, 1: 0x46298}:
        raise ValueError('departure choice/consumption changed')
    predicate, raw = decode_predicate(data, entity['stream_offsets'][1], 'event', coordinate_ranges=True)
    if [(row['opcode'], row.get('operands', [])) for row in raw['terms']] != [(11, [28, 28]), (12, [42, 45]), (4, [1]), (6, [])]:
        raise ValueError('headquarters boarding trigger changed')
    tables = scene.ptr_at(data, scene.root(data) + 20)
    pointer = scene.ptr_at(data, scene.ptr_at(data, tables + 3 * 4))
    tokens, text_end = text(data, pointer)
    plain, used = war_text.decode(data, pointer)
    if ''.join(token.get('text', '\n') for token in tokens) != plain or plain != "Board\nDon't board" or used != text_end - pointer:
        raise ValueError('independent departure choice text disagrees')
    main, main_origin = source('MAIN.EXE')
    if main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported ordinary boat consumer source')
    base = struct.unpack_from('<I', main, 24)[0]
    words = {0x80127198: 0x1462000a, 0x801271a0: 0x0c049c09,
             0x801271a8: 0x1440001a, 0x801271b0: 0x2a020015,
             0x801271b4: 0x10400017, 0x801271bc: 0x08049c85,
             0x8012776c: 0x0c031091, 0x80127460: 0x0c031091,
             0x8013fb78: 0x34020008, 0x8013fb7c: 0x10a20007,
             0x8013fb94: 0x0c04fe90, 0x8013fba4: 0x0c04fd61}
    for address, expected in words.items():
        if struct.unpack_from('<I', main, 2048 + address - base)[0] != expected or maindec.mword(address) != expected:
            raise ValueError('ordinary boat collision/animation consumer changed')
    bodies = []
    for first, last, digest in ((0x80127114, 0x80127224, '506f5ff956ebfc408bcf697d1f25593553efd9f35c938dfa2fa092b4445b267e'),
                                (0x80127024, 0x801270c4, 'a2e8e0a13aca561eb14b60363fa062fe08309987fb85172d1feb4511be96c83e')):
        body = main[2048 + first - base:2048 + last - base]
        if body != b''.join(maindec.mword(a).to_bytes(4, 'little') for a in range(first, last, 4)) or hashlib.sha256(body).hexdigest() != digest:
            raise ValueError('independent boat collision consumer reads disagree')
        bodies.append({'start': first, 'end': last, 'sha256': digest})
    return {'source': origin, 'room': 0, 'entity': 1, 'offset': start, 'end': end,
            'bytes': literal.hex(), 'instruction_count': len(rows), 'consumed': end - start,
            'instructions': [{'offset': pc, 'opcode': op, 'operands': list(args)} for pc, op, args, _ in rows],
            'trigger': {'half_cells': {'x': [28, 28], 'y': [42, 45]}, 'pressed_mask': 0x2000,
                        'predicate_offset': raw['offset'], 'source_terms': predicate['terms']},
            'choice': {'box': 1, 'page': 3, 'index': 0, 'offset': pointer, 'consumed': used,
                       'tokens': tokens, 'choices': plain.split('\n'),
                       'targets': {str(k): v for k, v in targets.items()}},
            'board': {'world_mode_operand': 12, 'world_mode': 1, 'region': 9,
                      'camera': [100, 75], 'auto_route': None},
            'decline': {'world_mode_write': False, 'terminal': 'end_stream'},
            'hero_prefix': 'opcode12 code8 bypasses name-prefix copy at8013FB7C while retaining image lookup at8013FBA4',
            'native': {'event': 'vb5ag_room_0_e01_ordinary', 'commands': 11,
                       'owner': 'Journey Boat over the shared Session.steer consumer', 'save_version': 33,
                       'scope': 'normal boat steering, loaded shore destinations, saved camera/heading and separate field facing; maelstrom feedback, upgraded art and unattached destinations remain explicit refusals'},
            'ordinary_boat': {'main': main_origin, 'bodies': bodies,
                              'words': {hex(a): hex(w) for a, w in words.items()},
                              'collision': 'conditional303..310 via variant helper, otherwise code<21; no foot-threshold fallback',
                              'animation': 'ordinary ready-state advance plus moving-state advance; scripted movement omits the ready-state advance'},
            'scope': 'complete bounded departure binds in candidate37, using Hero-relative choice and image-only header, normal Journey boat owner and shore cleanup; no scripted return route is substituted. Full source-event execution, device cadence, conditional feedback and media acceptance remain unfinished'}


def hq_mathiu_briefing():
    from opening_audience import text
    import character_table
    import war_text
    data, origin = source('/VB5A2.BIN')
    if origin['sha256'] != CASTLE_SOURCES['/VB5A2.BIN']:
        raise ValueError('unsupported headquarters briefing identity')
    entities = scene.entities(data, scene.room_record(data, 0))
    compact = [entry for entry in entities if entry['stream_offsets'][0] is not None]
    actors = []
    for selector, index, character, expected in ((1, 10, 1, '10010f0106ff03'),
                                                (2, 12, 27, '101b06ff00'),
                                                (14, 33, 35, '06ff03')):
        entry = compact[selector]
        x, y, flags, native_id = struct.unpack_from('<4H', data, entry['offset'])
        classification, predicate = decode_predicate(data, entry['stream_offsets'][0], 'classification', full=True)
        start = entry['stream_offsets'][0]
        if (entry['index'], native_id, flags) != (index, character, 3) or data[start:start + len(bytes.fromhex(expected))] != bytes.fromhex(expected):
            raise ValueError('briefing actor identity/classification changed')
        parameter, orientation = data[start + predicate['size']:start + predicate['size'] + 2]
        actors.append({'selector': selector, 'entity': index, 'character': character,
                       'record': entry['offset'], 'classification_offset': start,
                       'native_actor_id': f'vb5a2_room_0_actor_{index:02d}_{character:03d}',
                       'initial_pixels': [x * 8, y * 8], 'classification': classification,
                       'appearance': {'setup_parameter': parameter, 'variant': orientation & 3,
                                      'facing': ('down', 'up', 'left', 'right')[orientation & 3],
                                      'speed': (flags >> 2) & 1, 'auto_animate': bool(flags & 0x200)}})
    if actors[-1]['initial_pixels'] != [2032, 2032]:
        raise ValueError('briefing Viktor staging changed')
    if actors[1]['initial_pixels'] != [544, 280] or entities[13]['stream_offsets'][0] is not None:
        raise ValueError('briefing inherited Mathiu interaction anchor changed')
    start, end = 0x3fe14, 0x3fe8f
    rows = []
    for row in decode_stream(data, start, max_insns=64):
        rows.append(row)
        if row[1] == 0xfd:
            break
    cursor = start
    lengths = {0x10: 2, 0x11: 2, 0x0b: 1, 0x12: 2, 0x1c: 3, 2: 0, 0x0c: 0,
               7: 3, 0x33: 0, 0x17: 1, 0x18: 0, 0x3a: 1, 0x1f: 2, 0x4a: 2,
               0x46: 0, 9: 2, 0x43: 2, 0xfd: 0}
    for pc, opcode, args, _ in rows:
        if opcode == 0x32:
            following = cursor + 2
            while data[following] != 5:
                if data[following] not in range(4):
                    raise ValueError('unsupported briefing movement')
                following += 2
            following += 1
        else:
            following = cursor + 1 + lengths[opcode]
        if pc != cursor or following > end or data[cursor + 1:following] != args:
            raise ValueError('independent briefing operand walk disagrees')
        cursor = following
    if cursor != end or len(rows) != 45 or rows[-1][1] != 0xfd or entities[13]['stream_offsets'][2] != start:
        raise ValueError('briefing stream not fully consumed')
    selection, _ = decode_predicate(data, entities[13]['stream_offsets'][1], 'event', full=True)
    root = scene.root(data)
    table = scene.ptr_at(data, root + 16)
    if scene.u32(data, table + 44 * 4) != 0x8001371c or data[0x3fe8b:0x3fe8e] != bytes.fromhex('43ff2c'):
        raise ValueError('briefing callback selection changed')
    menu, menu_end = text(data, 0x6d828)
    plain, used = war_text.decode(data, 0x6d828)
    if used != menu_end - 0x6d828 or ''.join(t.get('text', '\n') for t in menu) != plain or plain.split('\n') != ['Admit to party', 'Eject from party', 'No change']:
        raise ValueError('independent headquarters party menu text disagrees')
    anchors = {0x371c: 0x3c038008, 0x3730: 0x24423a18, 0x3734: 0xac820498,
               0x3c18: 0, 0x3cc8: 0xa0620001, 0x3d00: 0xa0800001,
               0x3ed8: 0x24425d58, 0x3ee8: 0x24426d6c, 0x3ef8: 0x24423f14,
               0x437c: 0x90510294, 0x4384: 0x2622ff94, 0x4388: 0x2c420002,
               0x4390: 0x26520050, 0x4398: 0x0c005060, 0x43b8: 0x90431af4,
               0x43c0: 0x30620001, 0x43c8: 0x30620004, 0x440c: 0x2a421860,
               0x6cd0: 0x9042000e, 0x6cf4: 0x90420000, 0x6cfc: 0xa0620021,
               0x46b8: 0x34020008, 0x46bc: 0x14820003, 0x46c8: 0x00001021,
               0x46dc: 0x90420028, 0x46e4: 0x1082fff7, 0x46ec: 0x28620006,
               0x46f8: 0x34020001, 0x5acc: 0x0c0051a9, 0x5ad4: 0x1040006b,
               0x72b8: 0x0c0050a7, 0x4308: 0x8c4200d8,
               0x3864: 0x34070080, 0x3868: 0xa0870008,
               0x3bd8: 0x30620041, 0x3be0: 0x30620024,
               0x5aa8: 0x30820041, 0x5ae4: 0x30820024,
               0x5b1c: 0x3084f000, 0x5b74: 0x0064182a,
               0x5ba4: 0x0083182a, 0x5bb8: 0x0082102a,
               0x5bfc: 0x0064182a, 0x5c2c: 0x00021040,
               0x5c34: 0xa082001e,
               0x5c9c: 0x30820041, 0x5ca8: 0x30820024,
               0x5cc4: 0xa0830020, 0x5cc8: 0x3084f000,
               0x64d4: 0xa0400020, 0x65c4: 0x1440003a,
               0x65f0: 0x0c00507d, 0x65f8: 0x0c0050d2,
               0x6370: 0x3c058008, 0x636c: 0xa082001c,
               0x6384: 0x1462000c, 0x6838: 0x30420065,
               0x4214: 0x8c420008, 0x4244: 0x8c42000c,
               0x4254: 0x1440fff6, 0x4270: 0x8c4200cc,
               0x76a0: 0x24423a18, 0x76a8: 0xa0600000,
               0x76b8: 0xa0400001,
               0x3f2c: 0x2c620004, 0x3f34: 0x2463fffc,
               0x3f40: 0x24423fb8, 0x3ff4: 0xae000498}
    for offset, expected in anchors.items():
        if struct.unpack_from('<I', data, offset)[0] != expected:
            raise ValueError('headquarters party callback consumer changed')
    main, main_origin = source('MAIN.EXE')
    if main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported briefing MAIN identity')
    base = struct.unpack_from('<I', main, 24)[0]
    def word(address):
        value = struct.unpack_from('<I', main, 2048 + address - base)[0]
        if value != maindec.mword(address):
            raise ValueError('independent briefing MAIN readers disagree')
        return value
    for slot, target in ((8, 0x800c48d4), (12, 0x800c2fa4), (0xcc, 0x800c49b8), (0xd8, 0x800c4afc)):
        if word(0x80165608 + slot) != target:
            raise ValueError('party-selection loading/removal vtable changed')
    actor_ids = [{'native_actor_id': f"vb5a2_room_0_actor_{entry['index']:02d}_{entry['id']:03d}"} for entry in compact]
    choreography = hq_choreography(data, rows, actor_ids, word, (4, 4, []))
    for speech in choreography['dialogues']:
        speaker = next(actor for actor in actors if actor['native_actor_id'] == speech['actor'])
        if speaker['character'] != speech['character']:
            raise ValueError('briefing actor disagrees with named speaker')
    mission = ''.join(token.get('text', '') for token in choreography['dialogues'][0]['tokens'])
    if 'Lepant' not in mission or 'Kouan' not in mission:
        raise ValueError('briefing mission destination changed')
    resident, resident_origin = source('SLUS_002.92')
    if resident_origin['sha256'] != '68a41f0228ae1fca8cb8b39f29dfed552f1305a3c86a686917290124e77f131d':
        raise ValueError('unsupported party admission record source')
    record_ids = [struct.unpack_from('<I', resident, 2048 + 0x33274 + index * 0x50)[0] for index in range(78)]
    if record_ids != [record['id'] for record in character_table.records()] or len(set(record_ids)) != 78:
        raise ValueError('independent party admission record order disagrees')
    return {'source': origin, 'room': 0, 'entity': 13, 'offset': start, 'end': end,
            'instruction_count': len(rows), 'consumed': end - start, 'selection': selection,
            'instructions': [{'offset': pc, 'opcode': op, 'operands': list(args)} for pc, op, args, _ in rows],
            'actors': actors, 'choreography': choreography,
            'mission_text': {'page': 4, 'index': 30, 'destination': 'Kouan', 'character': 'Lepant'},
            'party_callback': {'selector': 255, 'index': 44, 'slot': table + 44 * 4,
                               'constructor': 0x8001371c, 'main_callback': 0x80013a18,
                               'dispatch': 0x80013ea0, 'choices': plain.split('\n'),
                               'choice_callbacks': [0x80015d58, 0x80016d6c, 0x80013f14],
                               'roster_source': resident_origin, 'admission_order': [identity for identity in record_ids if identity not in (108, 109)],
                               'required_recruit_bits': 1, 'forbidden_recruit_bits': 4,
                               'admit': '78 persistent records in source order; exclude108/109 and active members; require recruit bit0 and clear bit2',
                               'eject': 'active party order; reject Hero8 and any auxiliary-party member; confirmed removal reaches shared loaded-slot removal through vtable+D8',
                               'mandatory_hero': 8, 'forced_members': 'source_auxiliary_party',
                               'windows': hq_party_windows(data, word),
                               'background': hq_party_background(data, word),
                               'window_drawing': hq_party_window_drawing(data, word),
                               'name_lists': hq_party_names(data, word),
                               'details': hq_party_details(data, word),
                               'portraits': hq_party_portraits(data, word),
                               'native_callback': {
                                   'command': 'party_select', 'event_ir': 15, 'field_packet': 37,
                                   'request_owner': 'one field receipt until selector cleanup',
                                   'mutation_owner': 'existing Journey active/reserve records; prepare before commit',
                                   'save_during_mode': 'busy',
                                   'scope': 'owner reads the separate saved field auxiliary list; save32 persistence implemented. Complete mutation execution, native rendering/audio and source cleanup scheduling remain unfinished'},
                               'input_contract': {
                                   'sampling': hq_party_input(data),
                                   'confirm_mask': 0x41, 'cancel_mask': 0x24,
                                   'direction_mask': 0xf000, 'one_direction_only': True,
                                   'confirm_precedes_cancel': True, 'main_wrap': True,
                                   'rows_per_page': 10, 'list_vertical_wrap': False,
                                   'page_change_row': 0, 'confirmation_default': 'yes',
                                   'confirmation_cancel': 'no', 'return_main_choice': 'admit',
                                   'commit': 'each confirmed change; leaving the selector does not roll it back',
                                   'readiness': 'wait for window opening/closing; admission waits for shared load readiness before relocation',
                                   'empty_list_precedes_full_party': True,
                                   'exit_fade': {'initial': 128, 'decrement': 4,
                                                 'handoff_update': 33, 'cleanup': 'following callback'}},
                               'source_words': {hex(offset): hex(value) for offset, value in anchors.items()}},
            'native_command_count': 45,
            'interaction_anchor': {'entity': 12, 'position': [544, 280],
                                   'rule': 'null classification inherits the preceding actor slot; Mathiu is stationary'},
            'scope': 'complete briefing binds in candidate37 through the existing headquarters scene compiler, with four dialogues/tracks, separate axis writes, Viktor/Cleo loads and auxiliary edits, story flag and party selector; full mutation/return execution and platform/scheduling acceptance remain unfinished'}


def hq_party_input(data):
    main, origin = source('MAIN.EXE')
    if origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported selector input source')
    base = struct.unpack_from('<I', main, 24)[0]
    start, end = 0x800c29cc, 0x800c2b34
    raw = main[2048 + start - base:2048 + end - base]
    independent = b''.join(maindec.mword(a).to_bytes(4, 'little') for a in range(start, end, 4))
    if raw != independent:
        raise ValueError('independent input routine reads disagree')
    anchors = {0x800c2a68: 0x30c60001, 0x800c2a70: 0x00852026,
               0x800c2a74: 0x00852024, 0x800c2a98: 0x14c00014,
               0x800c2ac4: 0x00822024, 0x800c2ac8: 0x2862001e,
               0x800c2ae0: 0x00821025, 0x800c2b18: 0xac440010,
               0x800c2b20: 0xac460018, 0x800c2b68: 0xa020b7b0,
               0x800c2b6c: 0x340300ff, 0x800c2b78: 0xac40003c,
               0x800c2b80: 0x0461fffd}
    for address, expected in anchors.items():
        offset = 2048 + address - base
        if int.from_bytes(main[offset:offset+4], 'little') != expected or maindec.mword(address) != expected:
            raise ValueError(f'selector input producer changed at {address:#x}')
    consumers = {0x3bd0: 0x8c430018, 0x63c4: 0x8c440018,
                 0x64e4: 0x8c440010, 0x6788: 0x8c440010,
                 0x708c: 0x8c440018, 0x71ac: 0x8c440010}
    for offset, expected in consumers.items():
        if struct.unpack_from('<I', data, offset)[0] != expected:
            raise ValueError('selector input consumer changed')
    return {'source': origin, 'routine': [start, end], 'sha256': hashlib.sha256(raw).hexdigest(),
            'held_history_updates': 30, 'repeat_update_parity': 'even',
            'initial_history': 'zero; first update has index1',
            'main_and_list': 'pressed edges OR intersection of last30 held samples on even updates',
            'native': 'selector Sampler uses per-button saturated durations; native frame samples every playing simulation update and dispatches selector ownership',
            'remaining': 'native rendering/audio, entry cleanup context and original wall-clock scheduling remain unqualified',
            'confirmation_and_full_report': 'pressed edges only',
            'producer_words': {hex(a): hex(w) for a, w in anchors.items()},
            'consumer_words': {hex(0x80010000+a): hex(w) for a, w in consumers.items()}}



def hq_party_background(data, word):
    def literal(offset):
        raw = struct.unpack_from('<I', data, offset)[0]
        if raw >> 26 not in (9, 13) or raw >> 21 & 31:
            raise ValueError('unsupported party background literal')
        value = raw & 65535
        return value - 65536 if raw >> 26 == 9 and value >= 32768 else value
    top, right, split, left, bottom = [literal(o) for o in (0x38c4, 0x38c8, 0x38d8, 0x38dc, 0x38f4)]
    expected = {0x0c: left, 0x0e: top, 0x14: split, 0x16: top,
                0x1c: left, 0x1e: bottom, 0x24: split, 0x26: bottom,
                0x34: split, 0x36: top, 0x3c: right, 0x3e: top,
                0x44: split, 0x46: bottom, 0x4c: right, 0x4e: bottom}
    # Independently propagate constants to the constructor's halfword stores.
    constants, stores = {0: 0}, {}
    for offset in range(0x38c4, 0x3924, 4):
        raw = struct.unpack_from('<I', data, offset)[0]
        op, rs, rt, immediate = raw >> 26, raw >> 21 & 31, raw >> 16 & 31, raw & 65535
        if op in (9, 13):
            prior = constants.get(rs)
            constants.pop(rt, None)
            if prior is not None:
                signed = immediate - 65536 if immediate >= 32768 else immediate
                constants[rt] = prior + signed if op == 9 else prior | immediate
        elif op == 0x29 and rs == 2:
            if rt not in constants:
                raise ValueError('unknown party background coordinate')
            stores[immediate] = constants[rt]
        elif op in (15, 0x23):
            constants.pop(rt, None)
    if stores != expected or (left, top, right, bottom, split) != (-160, -120, 160, 120, 32):
        raise ValueError('independent background geometry disagrees')
    overlay_words = {0x378c: 0x34020140, 0x3794: 0x340200f0,
                     0x37a8: 0x34050280, 0x37b0: 0x34060100,
                     0x3864: 0x34070080, 0x3f2c: 0x2c620004,
                     0x3f34: 0x2463fffc, 0x3f44: 0xac820498,
                     0x36d0: 0x3406000a, 0x3700: 0x3406000a}
    for offset, expected_word in overlay_words.items():
        if struct.unpack_from('<I', data, offset)[0] != expected_word:
            raise ValueError('party background capture/fade changed')
    main_words = {0x8016566c: 0x80148658, 0x801657d0: 0x8014b4ec,
                  0x8014b508: 0x91040007, 0x8014b51c: 0x95020008,
                  0x8014b524: 0x00431021, 0x8014b53c: 0x00431021}
    for address, expected_word in main_words.items():
        if word(address) != expected_word:
            raise ValueError('party background upload/submission changed')
    return {'capture': {'x': 0, 'y': 0, 'width': right-left, 'height': bottom-top},
            'quads': [[left, top, split-left, bottom-top], [split, top, right-split, bottom-top]],
            'neutral_brightness': literal(0x3864), 'draw_bucket': 10,
            'exit_fade': {'decrement': 4, 'handoff_when_previous_below': 4},
            'overlay_words': {hex(o): hex(w) for o, w in overlay_words.items()},
            'main_words': {hex(a): hex(w) for a, w in main_words.items()},
            'native': 'snapshot the retained native field canvas once; suppress field redraw while selector owns input; draw the snapshot with brightness/128; release on mode return',
            'scope': 'background ownership and continuous shader brightness only; entry capture timing under stalls, GPU pixels, menu panels and media acceptance remain unverified'}



def hq_party_window_drawing(data, word):
    main_words = {0x800c2be8: 0x34040140, 0x800c2bec: 0x340500f0,
                  0x800c2c0c: 0x0c052de9, 0x800c2cbc: 0x0c0531f6,
                  0x8014b7ec: 0x0c052e7b, 0x8014b9f4: 0xac25c068,
                  0x8014ba08: 0xac24c058,
                  0x8014c7f8: 0x00021043, 0x8014c800: 0xa422bd0c,
                  0x8014c80c: 0x00031843, 0x8014c814: 0xa423bd0e,
                  0x80144258: 0x2442fffe, 0x80144324: 0x34110020,
                  0x8014432c: 0x34020030, 0x80144334: 0x34020040,
                  0x801446f8: 0x2442fffe}
    for address, expected in main_words.items():
        if word(address) != expected:
            raise ValueError('selector window drawing dependency changed')
    overlay_words = {0x3d2c: 0x34020010, 0x3d34: 0x34020001,
                     0x3d3c: 0xafa00018, 0x6554: 0x34020018,
                     0x6564: 0xafa00018, 0x67e4: 0x34050002,
                     0x67ec: 0x34060001}
    for offset, expected in overlay_words.items():
        if struct.unpack_from('<I', data, offset)[0] != expected:
            raise ValueError('selector prompt/cursor drawing changed')
    width, height = word(0x800c2be8) & 65535, word(0x800c2bec) & 65535
    # Independently recover the same viewport from the screenshot constructor.
    if (width, height) != tuple(struct.unpack_from('<I', data, offset)[0] & 65535 for offset in (0x378c, 0x3794)):
        raise ValueError('selector capture and screen initialization dimensions disagree')
    return {'draw_origin': {'x': width // 2, 'y': height // 2},
            'cursor': {'row_height': 12, 'y_offset': -2, 'instant': True,
                       'fill_rgb': [32, 48, 64], 'width': 'window columns times8'},
            'acknowledge_cell': [2, 1],
            'main_words': {hex(a): hex(w) for a, w in main_words.items()},
            'overlay_words': {hex(o): hex(w) for o, w in overlay_words.items()},
            'native': 'shared source font/window pieces, transition outlines and rectangle-sized selection fill/border; fixed main/confirmation/full prompts are composed in the native frame',
            'scope': 'fixed prompts and window envelopes; character names, portraits, stats, GPU pixels, source bucket/layer ordering and entry cleanup remain unfinished'}




def hq_party_page_separator():
    import system_glyphs
    from psx_vram import texpage_encode, rgb555_to_rgb888

    raw, origin = source('SLUS_002.92')
    if origin['sha256'] != '68a41f0228ae1fca8cb8b39f29dfed552f1305a3c86a686917290124e77f131d':
        raise ValueError('unsupported selector footer font source')
    sources = system_glyphs.sources()
    plane = next(row for row in sources if row['role'] == 'glyph_bottom')
    palette = next(row for row in sources if row['role'] == 'palettes')
    for entry in (plane, palette):
        if raw[entry['file_offset']:entry['file_offset']+entry['size']] != entry['payload']:
            raise ValueError('independent embedded font source reads disagree')
    vram = system_glyphs.replay()
    page = texpage_encode(960, 0, 0)
    pixels, rgba = [], []
    for y in range(12):
        row = []
        for x in range(8):
            # Upload starts at pixel u128,y128; glyph68 samples u136,y212.
            byte = plane['payload'][(84+y)*64 + (8+x)//2]
            index = byte >> (((8+x) & 1)*4) & 15
            if index != vram.sample_texel(page, 136+x, 212+y) or index > 3:
                raise ValueError('independent direct footer glyph pixels disagree')
            row.append(index)
            color = int.from_bytes(palette['payload'][index*2:index*2+2], 'little')
            if color != vram.get_word(1008+index, 504):
                raise ValueError('independent footer glyph palette reads disagree')
            rgba.extend((*rgb555_to_rgb888(color), 0 if color == 0 else 255))
        pixels.append(row)
    colors = [list(rgb555_to_rgb888(int.from_bytes(palette['payload'][i*2:i*2+2], 'little'))) for i in range(4)]
    return {'source': origin, 'decoder': 'raw4bpp-low-nibble-first/1; RGB555 linear rescale',
            'uploads': [{k: v for k, v in entry.items() if k != 'payload'} for entry in (plane, palette)],
            'glyph_code': 0x68, 'sample': {'u': 136, 'v': 212, 'width': 8, 'height': 12},
            'pixels': pixels, 'colors': colors, 'transparent_index': 0,
            'rgba_sha256': hashlib.sha256(bytes(rgba)).hexdigest(),
            'independent_verification': 'direct font-plane nibble reads and palette words agree with independent VRAM upload/sample for all96 pixels',
            'image_gate': 'candidate; native composed output and human acceptance pending'}


def hq_party_names(data, word):
    from opening_audience import text
    import character_table
    import war_text

    names = []
    for record in character_table.records():
        identity = record['id']
        if identity in (108, 109):
            continue
        offset = 0x6d878 + identity * 3
        page, quadrant, palette = struct.unpack_from('<3B', data, offset)
        if [page, quadrant, palette] != list(data[offset:offset+3]):
            raise ValueError('independent selector name-index readers disagree')
        slot = 0x6d55c + (page * 4 + quadrant) * 4
        pointer = struct.unpack_from('<I', data, slot)[0]
        if pointer != int.from_bytes(data[slot:slot+4], 'little'):
            raise ValueError('independent selector name-pointer readers disagree')
        start = pointer - 0x80010000
        plain, consumed = war_text.decode(data, start)
        tokens, end = text(data, start)
        if consumed != end - start or plain != ''.join(t.get('text', '') for t in tokens) or plain != record['name']:
            raise ValueError('selector overlay and independent character names disagree')
        names.append({'character': identity, 'name': plain, 'selector_record': offset,
                      'name_slot': slot, 'text_offset': start, 'bytes_consumed': consumed})
    if len(names) != 76:
        raise ValueError('selector name inventory changed')
    overlay_words = {0x4758: 0x00021880, 0x4764: 0x00031840,
                     0x4778: 0x90500021, 0x47a8: 0x02203021, 0x4810: 0x2a22000a,
                     0x4838: 0x34050004, 0x4840: 0x3406000a,
                     0x485c: 0x9065001d, 0x4bd8: 0x34020008,
                     0x4c08: 0x28620008, 0x4cd4: 0x34020020,
                     0x4cd8: 0xafa20018, 0x5838: 0x02203021, 0x5874: 0x28620008}
    for offset, expected in overlay_words.items():
        if struct.unpack_from('<I', data, offset)[0] != expected:
            raise ValueError('selector name list consumer changed')
    main_words = {0x800c1bfc: 0x80145f80, 0x800c4eac: 0xafa80010,
                  0x800c4eb4: 0x0c051c4b, 0x800c4eb8: 0xafa20014,
                  0x801471ac: 0x01621025, 0x8014671c: 0x0c0517d1,
                  0x80145f80: 0x34020030, 0x80145f88: 0x34020070,
                  0x80145f94: 0x34020080}
    for address, expected in main_words.items():
        if word(address) != expected:
            raise ValueError('selector protected-row color consumer changed')
    range_words = {0x4d70: 0x92020044, 0x4d88: 0x90430056,
                   0x4de4: 0x3405003d, 0x4e10: 0x34050037,
                   0x4e3c: 0x34050036, 0x5924: 0x34040009,
                   0x592c: 0x02202821}
    for offset, expected in range_words.items():
        if struct.unpack_from('<I', data, offset)[0] != expected:
            raise ValueError('selector party range consumer changed')
    labels = {}
    for code, offset in ((1, 0x4de4), (2, 0x4e3c), (3, 0x4e10)):
        glyph = struct.unpack_from('<I', data, offset)[0] & 65535
        decoded, _ = war_text.decode(bytes([glyph, 0]), 0)
        independent = chr(ord('A') + glyph - 0x2b)
        if decoded != independent or decoded not in ('S', 'M', 'L'):
            raise ValueError('independent selector range glyph decoders disagree')
        labels[code] = decoded
    return {'names': names, 'admission_page_rows': 10,
            'name_column': 0, 'row_height': 12,
            'party_range': {'column': 9, 'labels': labels,
                            'words': {hex(o): hex(w) for o, w in range_words.items()},
                            'native': 'existing battle profile weapon-range label initial; missing profile/range fails explicitly'},
            'hero': 'ejection and active-party lists substitute eight-byte player name; admission excludes active Hero',
            'protected_ejection_rows': {'text_attribute': 1, 'source_rgb': [48, 112, 128],
                                        'native_rgb': [96, 224, 255]},
            'page_footer': {'column': 4, 'row': 10, 'raw_separator': 0x68, 'raw_suffix': 0x3a,
                            'separator_art': hq_party_page_separator(),
                            'status': 'native footer binds direct glyph pixels; composed output and human acceptance pending'},
            'overlay_words': {hex(o): hex(w) for o, w in overlay_words.items()},
            'main_words': {hex(a): hex(w) for a, w in main_words.items()},
            'scope': 'all76 non-guest names agree across overlay pointer/triple readers, both text decoders and independent character catalogue; native list/party names and protected tint bind; footer pixels bind without atlas changes; portrait/stat composition, native GPU output and human acceptance remain unfinished'}



def hq_party_details(data, word):
    from opening_audience import text
    from mipsdec import dec
    import war_text

    def literal(offset, register):
        register_name = {4: 'a0', 5: 'a1', 6: 'a2'}[register]
        raw = struct.unpack_from('<I', data, offset)[0]
        if raw == (register << 11 | 0x21):
            value, instruction = 0, f'addu ${register_name},$zero,$zero'
        elif raw >> 26 == 13 and raw >> 21 & 31 == 0 and raw >> 16 & 31 == register:
            value = raw & 65535
            instruction = f'ori ${register_name},$zero,0x{value:x}'
        else:
            raise ValueError(f'unsupported details-layout literal at {offset:#x}: {raw:#x}')
        if dec(0x80010000+offset, raw)[0] != instruction:
            raise ValueError('independent details-layout decoders disagree')
        return value
    rows = []
    for field, label_slot, column_at, row_at, width_at in (
            ('level', 0x6d814, 0x4eec, 0x4ef4, 0x4f50),
            ('attack', 0x6d80c, 0x4f70, 0x4f78, 0x4fd4),
            ('armour', 0x6d810, 0x4ff4, 0x4ffc, 0x5058),
            ('max_hp', 0x6d804, 0x5078, 0x5080, 0x50dc),
            ('power', 0x6d7ec, 0x52fc, 0x5304, 0x5360),
            ('skill', 0x6d7f0, 0x5380, 0x5388, 0x53e4),
            ('defense', 0x6d7f4, 0x5404, 0x540c, 0x5468),
            ('speed', 0x6d7f8, 0x5488, 0x5490, 0x54ec),
            ('magic', 0x6d7fc, 0x550c, 0x5514, 0x5570),
            ('luck', 0x6d800, 0x5590, 0x5598, 0x55f4)):
        pointer = struct.unpack_from('<I', data, label_slot)[0] - 0x80010000
        label, consumed = war_text.decode(data, pointer)
        tokens, end = text(data, pointer)
        if consumed != end-pointer or label != ''.join(t.get('text', '') for t in tokens):
            raise ValueError('independent details labels disagree')
        rows.append({'field': field, 'label': label, 'column': literal(column_at, 5),
                     'row': literal(row_at, 6), 'width': literal(width_at, 6),
                     'label_slot': label_slot, 'layout_sites': [column_at, row_at, width_at]})
    main, origin = source('MAIN.EXE')
    if origin['sha256'] != MAIN_SHA256 or word(0x80165768) != 0x800d4ec0:
        raise ValueError('unsupported menu stats helper')
    base = struct.unpack_from('<I', main, 24)[0]
    body = main[2048+0x800d4ec0-base:2048+0x800d50a4-base]
    if body != b''.join(maindec.mword(a).to_bytes(4, 'little') for a in range(0x800d4ec0, 0x800d50a4, 4)):
        raise ValueError('independent menu-stats helper reads disagree')
    labels = {}
    for label_name, slot in (('mp', 0x6d808), ('range', 0x6d81c), ('rune', 0x6d824)):
        offset = struct.unpack_from('<I', data, slot)[0] - 0x80010000
        plain, used = war_text.decode(data, offset)
        tokens, end = text(data, offset)
        if used != end-offset or plain != ''.join(t.get('text', '') for t in tokens):
            raise ValueError('independent details extra-label readers disagree')
        labels[label_name] = plain
    positions = {'mp': [literal(0x50fc, 5), literal(0x5104, 6)],
                 'mp_separators': [literal(0x5154, 5), literal(0x515c, 6)],
                 'charges': [literal(o, 5) for o in (0x51ac, 0x5200, 0x5254, 0x52a8)],
                 'range': [literal(0x5614, 5), literal(0x561c, 6)],
                 'range_value': [literal(0x5658, 4), literal(0x5660, 5)],
                 'rune': [literal(0x5688, 5), literal(0x5690, 6)],
                 'rune_value_column': literal(0x5704, 5)}
    if positions != {'mp': [8, 1], 'mp_separators': [12, 1], 'charges': [11, 13, 15, 17],
                     'range': [0, 6], 'range_value': [11, 6], 'rune': [0, 7], 'rune_value_column': 6} or data[0x6d7dc:0x6d7e2] != bytes.fromhex('681068106800'):
        raise ValueError('details charge/range/rune layout changed')
    formatter = main[2048+0x80146fe8-base:2048+0x8014707c-base]
    if formatter != b''.join(maindec.mword(a).to_bytes(4, 'little') for a in range(0x80146fe8, 0x8014707c, 4)):
        raise ValueError('independent fixed-width number formatter reads disagree')
    import character_table
    cleo = character_table.by_id()[1]
    worn = [item for item in cleo['inventory'][:cleo['inventory_count']] if item['slot_flags']]
    armour_bonuses = []
    for item in worn:
        pointer = word(0x80167658 + item['id']*4)
        bonuses = struct.unpack_from('<8b', main, 2048 + pointer + 0x20 - base)
        armour_bonuses.append(bonuses[7])
    if cleo['stats'][2] != 15 or armour_bonuses != [2, 3]:
        raise ValueError('independent Cleo menu-stat reference changed')
    return {'numbers': rows, 'labels': labels, 'stats_source': origin,
            'stats_helper_sha256': hashlib.sha256(body).hexdigest(),
            'extra_positions': positions, 'number_formatter_sha256': hashlib.sha256(formatter).hexdigest(),
            'reference': {'character': 'Cleo', 'defense': 15, 'equipped_armour_bonuses': armour_bonuses, 'armour': 20},
            'stats_rule': 'six persistent stats; Gale doubles speed; wind/earth fragments add defense/skill; eight signed equipped-item bonuses; attack adds power and current weapon power; armour adds defense; every store narrows to16 bits',
            'number_format': 'fixed width, right aligned with spaces, retaining low decimal digits; MAIN80146FE8..80147078',
            'native_mapping': 'owned base attack minus initial weapon power recovers persistent PWR; previews borrow active/reserve records or pure seed materialization and do not publish state or RNG',
            'scope': 'numeric detail fields and persistent preview; portrait drawing, GPU output, entry/cleanup and complete selector execution remain unfinished'}



def hq_party_portraits(data, word):
    import character_table
    import face_portraits
    from export_opening_scene import portrait_payload

    catalogue = json.loads((ROOT / 'game/assets/party_session/catalogue.json').read_text())['characters']
    records = face_portraits.face_records()
    pages, rows = {}, []
    palette_pointers = list(struct.unpack_from('<9I', data, 0x6d854))
    if palette_pointers != [int.from_bytes(data[0x6d854+i*4:0x6d858+i*4], 'little') for i in range(9)]:
        raise ValueError('independent selector portrait palette tables disagree')
    for record in character_table.records():
        identity = record['id']
        if identity >= 108:
            continue
        page, cell, palette_index = struct.unpack_from('<3B', data, 0x6d878 + identity*3)
        if cell >= 4 or palette_index >= 9 or page >= len(records):
            raise ValueError('invalid selector portrait reference')
        if page not in pages:
            raw_face, face_origin = source(records[page]['path'])
            pages[page] = (face_portraits.page_cells(face_portraits.decode_page(raw_face)), face_origin)
        admit = pages[page][0][cell]
        raw, origin = source('/04_PLAY/' + record['sprite_file'])
        image_at, palette_at = struct.unpack_from('<II', raw, 44)
        eject, palette, compressed = portrait_payload(raw, image_at, palette_at)
        palette_offset = palette_pointers[palette_index] - 0x80010000
        raw_palette = data[palette_offset:palette_offset+512]
        if raw_palette != struct.pack('<256H', *palette):
            raise ValueError('selector admission/ejection portrait palettes disagree')
        native, = [entry for entry in catalogue if entry['source_character_id'] == identity]
        if native['name'] != record['name']:
            raise ValueError('selector native portrait identity disagrees')
        rows.append({'id': native['id'], 'source_character': identity,
                     'admit_plane_sha256': hashlib.sha256(admit).hexdigest(),
                     'eject_plane_sha256': hashlib.sha256(eject).hexdigest(),
                     'palette_sha256': hashlib.sha256(raw_palette).hexdigest(),
                     'face_source': pages[page][1], 'face_page': page, 'face_cell': cell,
                     'eject_source': origin, 'eject_offset': image_at, 'eject_compressed_bytes': compressed,
                     'palette_offset': palette_offset, 'palette_index': palette_index})
    variants = [row['id'] for row in rows if row['admit_plane_sha256'] != row['eject_plane_sha256']]
    if len(rows) != 76 or variants != ['flik']:
        raise ValueError('selector portrait variant inventory changed')
    anchors = {0x5f7c: 0x2652d854, 0x5f8c: 0x262201e0, 0x5f94: 0x34020100,
               0x5f9c: 0x34020001, 0x5fc0: 0x2a220009,
               0x4590: 0x3c020100, 0x459c: 0x34020040, 0x45a8: 0x34020020,
               0x45e4: 0x34021000, 0x462c: 0x34060001,
               0x4b30: 0x2404ffde, 0x4b38: 0x34050020,
               0x6bb0: 0x2c420004, 0x6bd0: 0x10620003,
               0x7574: 0x2c420005, 0x7594: 0x2404ffde, 0x7598: 0x34050020}
    for offset, expected in anchors.items():
        if struct.unpack_from('<I', data, offset)[0] != expected:
            raise ValueError(f'selector portrait owner changed at {offset:#x}')
    main_words = {0x80165690: 0x8014c8e4, 0x8014ca28: 0x01034023,
                  0x8014ca34: 0x01224823, 0x80145298: 0x34020002}
    for address, expected in main_words.items():
        if word(address) != expected:
            raise ValueError('selector portrait anchor consumer changed')
    return {'portraits': rows, 'variant_ids': variants, 'relative_rect': {'x': -66, 'y': 0, 'w': 64, 'h': 64},
            'position': [-34, 32], 'anchor': [32, 32], 'ordering_bucket': 1,
            'palette_uploads': {'count': 9, 'x': 0, 'first_y': 480, 'width': 256, 'height': 1},
            'visibility': {'admit_states': [2, 3, 4, 5], 'admit_full_party': False, 'eject_states': [2, 3, 4, 5, 6]},
            'words': {hex(o): hex(w) for o, w in anchors.items()},
            'main_words': {hex(a): hex(w) for a, w in main_words.items()},
            'scope': '75 shared admission/ejection images and one Flik plane variant; native resolves source hashes against existing decoded room portraits; missing variants refuse rather than substitute; GPU/human acceptance remains pending'}


def hq_party_windows(data, word):
    from opening_audience import text
    import war_text

    # Literal operands and a separate straight-line stack-constant walk must agree.
    sites = ((0x3a68, 0x3a70, 0x3a78, 0x3a80),
             (0x605c, 0x6064, 0x606c, 0x6074),
             (0x60ec, 0x6064, 0x60f8, 0x6100),
             (0x605c, 0x6144, 0x614c, 0x6138),
             (0x61c0, 0x61c8, 0x61d0, 0x61d8),
             (0x6214, 0x621c, 0x6224, 0x6138))
    def literal(offset):
        raw = struct.unpack_from('<I', data, offset)[0]
        op, rs = raw >> 26, raw >> 21 & 31
        if rs != 0 or op not in (9, 13):
            raise ValueError('unsupported selector window literal')
        value = raw & 65535
        return value - 65536 if op == 9 and value >= 32768 else value
    literals = [tuple(literal(offset) for offset in offsets) for offsets in sites]
    def rectangles(first, last):
        registers, stack, constructors, result = {0: 0}, {}, set(), []
        for offset in range(first, last, 4):
            raw = struct.unpack_from('<I', data, offset)[0]
            op, rs, rt, rd, immediate = raw >> 26, raw >> 21 & 31, raw >> 16 & 31, raw >> 11 & 31, raw & 65535
            signed = immediate - 65536 if immediate >= 32768 else immediate
            if op == 3 or op == 0 and raw & 63 == 9:
                if op == 0 and rs in constructors:
                    if stack.get(0x10) != 3:
                        raise ValueError('selector window style changed')
                    result.append(tuple(stack[key] for key in (0x20, 0x22, 0x24, 0x26)))
                for reg in (1, *range(2, 16), 24, 25, 31):
                    registers.pop(reg, None)
                    constructors.discard(reg)
            elif op == 0x2b and rs == 29 and signed == 0x10:
                stack[signed] = registers.get(rt)
            elif op == 0x29 and rs == 29 and signed in (0x20, 0x22, 0x24, 0x26):
                if rt not in registers:
                    raise ValueError('unknown selector rectangle stack value')
                value = registers[rt] & 65535
                stack[signed] = value - 65536 if value >= 32768 else value
            elif op in (9, 13):
                prior = registers.get(rs)
                registers.pop(rt, None)
                constructors.discard(rt)
                if prior is not None:
                    registers[rt] = prior + signed if op == 9 else prior | immediate
            elif op == 15:
                registers[rt] = immediate << 16
                constructors.discard(rt)
            elif op in (0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26):
                registers.pop(rt, None)
                constructors.discard(rt)
                if op == 0x23 and signed == 0x94:
                    constructors.add(rt)
            elif op == 0 and rd != 0 and raw & 63 not in (8, 9):
                registers.pop(rd, None)
                constructors.discard(rd)
        return result
    independent = rectangles(0x3a60, 0x3aac) + rectangles(0x6054, 0x6264)
    if literals != independent or literals != [(-64, -20, 16, 3), (-148, -94, 8, 11),
            (-58, -94, 25, 9), (-148, 78, 24, 2), (62, 31, 10, 6), (-88, -20, 21, 2)]:
        raise ValueError('independent selector window rectangles disagree')
    eject_sites = ((0x6e50, 0x6e58, 0x6e60, 0x6e68),
                   (0x6ee0, 0x6e58, 0x6eec, 0x6ef4),
                   (0x6f30, 0x6f38, 0x6f40, 0x6f48))
    eject = [tuple(literal(offset) for offset in offsets) for offsets in eject_sites]
    if eject != rectangles(0x6e48, 0x6f70) or eject != [(-140, -94, 8, 6), (-58, -94, 25, 9), (-144, 76, 29, 2)]:
        raise ValueError('independent ejection window rectangles disagree')
    anchors = {0x8016569c: 0x800c4cc8, 0x800c4cd0: 0x34090001,
               0x800c4d48: 0x0c051465, 0x800c4d4c: 0xafa90010,
               0x800c4dd4: 0x0c030c41, 0x800c4dd8: 0x34040501,
               0x80145230: 0x34020008, 0x8014523c: 0x3402000c,
               0x80145254: 0x00430018, 0x80145268: 0x00430018,
               0x801455e0: 0xa4c20030, 0x801455e4: 0xa4c20032,
               0x801455f4: 0xa0c50002, 0x801455f8: 0xa0c50001,
               0x80145664: 0xa0850002, 0x80145668: 0xa0850001,
               0x80145a48: 0x92020001, 0x80145a50: 0x14400005,
               0x80145a70: 0x2442ffff, 0x80145a78: 0xa2020001,
               0x80145ab4: 0x2442ffff, 0x80145abc: 0xa2020001,
               0x801475b8: 0x0064001a, 0x80147714: 0x0064001a,
               0x80147858: 0x0064001a}
    for address, expected in anchors.items():
        if word(address) != expected:
            raise ValueError('selector window geometry/countdown consumer changed')
    callback_anchors = {0x3b34: 0x94820020, 0x3b3c: 0x30420002,
                        0x3d70: 0x94420020, 0x3d78: 0x30420004,
                        0x6300: 0x90420001, 0x6318: 0x90420001,
                        0x64b0: 0x90420001, 0x6598: 0x90420001,
                        0x6720: 0x08005a17, 0x76a0: 0x24423a18,
                        0x76a8: 0xa0600000, 0x76b8: 0xa0400001}
    for offset, expected in callback_anchors.items():
        if struct.unpack_from('<I', data, offset)[0] != expected:
            raise ValueError('selector window owner observation changed')
    callback_tables = {
        'main': {'offset': 0xc4, 'callbacks': [0x80013a60, 0x80013b20, 0x80013bc4, 0x80013d5c, 0x80013d98]},
        'admit': {'offset': 0xdc, 'callbacks': [0x80016054, 0x800162ec, 0x80016348, 0x8001649c, 0x800164d8,
                                             0x80016584, 0x800165b0, 0x800165d4, 0x800166b8, 0x80016728,
                                             0x8001677c, 0x80016824, 0x8001688c]},
        'eject': {'offset': 0x114, 'callbacks': [0x80016e48, 0x80017000, 0x8001705c, 0x80017164, 0x800171a0,
                                               0x8001724c, 0x80017278, 0x8001729c, 0x800172f4, 0x80017364]}}
    for table in callback_tables.values():
        count, offset = len(table['callbacks']), table['offset']
        alternate = [int.from_bytes(data[offset + i * 4:offset + i * 4 + 4], 'little') for i in range(count)]
        if list(struct.unpack_from('<' + 'I' * count, data, offset)) != table['callbacks'] or alternate != table['callbacks']:
            raise ValueError('selector callback phase table changed')
    prompts = {}
    for name, offset in (('admit', 0x6d710), ('eject', 0x6d73c), ('full', 0x6d774), ('acknowledge', 0x6d78c)):
        tokens, end = text(data, offset)
        plain, used = war_text.decode(data, offset)
        if used != end - offset or ''.join(token.get('text', '\n') for token in tokens) != plain:
            raise ValueError('independent selector prompt decoders disagree')
        prompts[name] = {'offset': offset, 'end': end, 'text': plain, 'tokens': tokens}
    names = ('main', 'list', 'details', 'confirmation', 'party', 'full')
    windows = [{'id': name, 'origin': [x, y], 'columns': columns, 'rows': rows,
                'pixels': {'x': x, 'y': y, 'w': columns * 8, 'h': rows * 12}}
               for name, (x, y, columns, rows) in zip(names, literals, strict=True)]
    eject_windows = [{'id': name, 'origin': [x, y], 'columns': columns, 'rows': rows,
                      'pixels': {'x': x, 'y': y, 'w': columns * 8, 'h': rows * 12}}
                     for name, (x, y, columns, rows) in zip(('list', 'details', 'confirmation'), eject, strict=True)]
    return {'windows': windows, 'eject_windows': eject_windows, 'prompts': prompts, 'transition_updates': 8,
            'window_open_cue': 0x501,
            'native_opening_audio': 'native frame drains each opening notification once after mode update and voice advancement through existing common-bank cue0501',
            'callback_tables': callback_tables,
            'callback_words': {hex(offset): hex(value) for offset, value in callback_anchors.items()},
            'owner_waits': 'main waits for opening/closing flags to clear; submenus observe the countdown byte',
            'opening_shape': 'one pixel at the target rectangle midpoint; weighted signed division truncates toward zero',
            'update_order': 'owner callback observes the previous countdown; window callback decrements before drawing its outline; zero clears the opening/closing flag on the following window update',
            'coordinates': 'draw-environment-relative; viewport placement and complete composition remain unbound',
            'source_words': {hex(address): hex(value) for address, value in anchors.items()},
            'scope': 'main/admit/eject window geometry, prompts and common window clock; native callback/window ownership is bound; stat/portrait composition, cursor, audio and native frame rendering remain unfinished'}


def hq_founding_sprite_modes(data, actors, word):
    import character_table
    from parse_04play import Parser
    banks = []
    for character in (8, *(actor['character'] for actor in actors)):
        binding = next((actor['area_graphics'] for actor in actors if actor['character'] == character), None)
        if binding is not None:
            raw, origin = data, source('/VB7.BIN')[1]
            section = binding['context']
            normalized = bytearray(raw)
            for field, count in ((8, 1), (12, 1), (16, 12), (20, 4)):
                table = scene.ptr_at(raw, section + field)
                for pointer in (section + field, *(table + i * 4 for i in range(count))):
                    struct.pack_into('<I', normalized, pointer, scene.ptr_at(raw, pointer))
            normalized = bytes(normalized)
        else:
            raw, origin = source('/04_PLAY/' + character_table.by_id()[character]['sprite_file'])
            section = struct.unpack_from('<I', raw, 0x28)[0]
            normalized = raw
        if struct.unpack_from('<HHBB', normalized, section) != (13 if character == 8 else 12, 4, 1, 0x81):
            raise ValueError('unsupported founding normal sprite bank')
        parser = Parser(normalized, 0)
        parsed = parser.parse_section('founding_blend', section)
        table = struct.unpack_from('<I', normalized, section + 20)[0]
        sequences = []
        for index, entry in enumerate(parsed['f']['entries']):
            pointer = struct.unpack_from('<I', normalized, table + index * 4)[0]
            count, flags, capacity, reserved = struct.unpack_from('<4B', normalized, pointer)
            if (pointer != entry['target_file_offset'] or entry['sequence'] !=
                    {'frame_count': count, 'flags': flags, 'draw_capacity': capacity, 'reserved': reserved,
                     'pairs': [list(normalized[pointer + 4 + i * 2:pointer + 6 + i * 2]) for i in range(count)]}):
                raise ValueError('independent founding animation flags disagree')
            if flags != 3:
                raise ValueError('founding normal animation blend flag changed')
            sequences.append({'offset': pointer, 'flags': flags})
        if parser.errors or len(sequences) != 4:
            raise ValueError('invalid founding normal sprite sequences')
        banks.append({'character': character, 'source': origin, 'section': section, 'sequences': sequences,
                      'object_semitransparent_bit': 0, 'normal_descriptor': 0x01000000, 'blend_selector': 0})
    anchors = {0x800c3e74: 0x00021082, 0x800c3e78: 0x30420001,
               0x800c3e7c: 0x00021440, 0x800c3e88: 0xac860004,
               0x801345b0: 0x00021082, 0x801345b4: 0x30420001,
               0x801345b8: 0x00021440, 0x801345c0: 0xacc40004,
               0x800c40cc: 0x3c030002, 0x800c40d0: 0x00431024,
               0x800c40d4: 0x10400008, 0x800c40d8: 0x3c020100,
               0x800c40f0: 0x3c027100, 0x800c40f4: 0x3c024100,
               0x800c40f8: 0xafa20010, 0x8012ffe0: 0x34050100,
               0x800c43ec: 0x00002821, 0x800c4420: 0x0c052ac3,
               0x800c442c: 0x0040b821, 0x800c4454: 0xa6370002,
               0x80131538: 0xac400498,
               0x80131540: 0xac4004d8}
    for address, expected in anchors.items():
        if word(address) != expected:
            raise ValueError('founding sprite blend consumer changed')
    return {'banks': banks, 'shadow_ordering_index': 256, 'scenery_blend_selector': 0,
            'source_words': {f'{address:#010x}': f'{value:#010x}' for address, value in anchors.items()},
            'scope': 'normal animation bit2 writers and sprite descriptor consumers agree on selector0; normal founding caller combines these inputs with the scene drawing scope'}


def hq_choreography(data, rows, actors, word, expected_inventory, *, fixed_messages=False):
    from opening_audience import text, track
    import war_text
    tables = scene.ptr_at(data, scene.root(data) + 20)
    names = bytes(word(0x80170095 + i) & 255 for i in range(109))
    source_words = {0x8013fa50: 0x2ca2006e, 0x8013fa70: 0x10450009,
                    0x8013fa90: 0x00a01821, 0x8013fa9c: 0x24210588,
                    0x8013faa4: 0x8c240000,
                    0x8013cc94: 0x000318c0, 0x8013cc9c: 0xa423a130,
                    0x8013edbc: 0x24e2fffe, 0x8013edd4: 0xac23c008,
                    0x8013ede0: 0xac24c010, 0x8013edf8: 0x38420004}
    for address, expected in source_words.items():
        if word(address) != expected:
            raise ValueError('founding choreography consumer changed')
    boxes, speakers = {}, {}
    dialogues, tracks, pans, facing = [], [], [], []
    actors = dict(enumerate(actors)) if isinstance(actors, list) else actors
    def actor(selector):
        if selector == 128:
            return 'hero'
        if selector not in actors:
            raise ValueError('unsupported founding actor selector')
        return actors[selector]['native_actor_id']
    for pc, opcode, args, _ in rows:
        if fixed_messages and opcode == 0:
            boxes[args[0]] = None
            speakers[args[0]] = 8
        elif opcode in (0x0b, 0x17):
            boxes[0 if opcode == 0x0b else 1] = actor(args[0])
        elif opcode == 0x12:
            speakers[args[0]] = args[1]
        elif opcode == 0x1c:
            box, page, index = args
            pointer = scene.ptr_at(data, scene.ptr_at(data, tables + 4 * page) + 4 * index)
            tokens, end = text(data, pointer)
            # Split name substitutions so the independent plain-text reader sees only ordinary strings.
            pieces = data[pointer:end - 1].split(b'\x06\x00')
            independent = []
            for piece in pieces:
                plain, used = war_text.decode(piece + b'\0')
                if used != len(piece) + 1:
                    raise ValueError('independent founding text left bytes')
                independent.append(plain.replace('\n[---]\n', '\f'))
            preview = ''.join(token.get('text', {'newline': '\n', 'page': '\f', 'player_name': '{PLAYER}'}.get(token['kind'], '?')) for token in tokens)
            if '{PLAYER}'.join(independent) != preview:
                raise ValueError('independent founding dialogue decoders disagree')
            character = speakers[box]
            if character == 8:
                name_pointer, speaker, prefix = None, None, []
            else:
                name_index = names.index(character) + 1 if character < 110 else character
                name_pointer = word(0x80170588 + name_index * 4)
                name = bytearray()
                for i in range(64):
                    value = word(name_pointer + i) & 255
                    if value == 0:
                        break
                    name.append(value)
                else:
                    raise ValueError('unterminated founding speaker name')
                prefix, prefix_end = text(bytes(name) + b'\x03\0', 0)
                speaker, used = war_text.decode(bytes(name) + b'\0')
                if used != len(name) + 1 or prefix_end != len(name) + 2 or prefix != [*({'kind': 'glyph', 'text': c} for c in speaker), {'kind': 'newline'}]:
                    raise ValueError('independent founding speaker decoders disagree')
            dialogues.append({'source_offset': pc, 'box': box, 'page': page, 'index': index,
                              'string_offset': pointer, 'end': end, 'tokens': tokens,
                              'actor': boxes[box], 'character': character,
                              'speaker_name': speaker, 'name_pointer': name_pointer, 'prefix_tokens': prefix,
                              **({'image_only': True} if character == 8 else {})})
        elif opcode == 0x32:
            commands = track(args[1:])
            cursor, independent = 1, []
            while args[cursor] != 5:
                action, value = args[cursor:cursor + 2]
                if action < 4:
                    command = {'kind': 'move', 'direction': ('up', 'right', 'down', 'left')[action], 'cells': value}
                elif action == 4 and value in (0, 1):
                    command = {'kind': 'set_motion', 'motion': value}
                elif action == 7 and value:
                    command = {'kind': 'advance', 'cells': value}
                elif action == 6:
                    command = {'kind': 'hold', 'updates': value * 5} if value else {'kind': 'hop'}
                else:
                    raise ValueError('unqualified founding motion action')
                independent.append(command)
                cursor += 2
            independent.append({'kind': 'finish'})
            if cursor + 1 != len(args) or independent != commands:
                raise ValueError('independent founding tracks disagree or leave bytes')
            tracks.append({'offset': pc, 'selector': args[0], 'actor': actor(args[0]), 'commands': commands})
        elif opcode == 8:
            dx, dy = (struct.unpack('<i', struct.pack('<I', word(table + args[0] * 4)))[0]
                      for table in (0x80171860, 0x80171870))
            updates = args[1] * 4
            pans.append({'offset': pc, 'command': {'kind': 'pan', 'dx': dx, 'dy': dy, 'updates': updates,
                                                  'wait': {'kind': 'pan', 'id': 'pan'}}})
        elif opcode == 0x11:
            facing.append({'offset': pc, 'command': {'kind': 'actor_transition', 'actor': actor(args[0]),
                                                     'transition': word(0x80171b98 + args[1] * 4)}})
    if (len(dialogues), len(tracks), [(p['command']['dx'], p['command']['dy'], p['command']['updates']) for p in pans]) != expected_inventory:
        raise ValueError('founding choreography inventory changed')
    return {'dialogues': dialogues, 'tracks': tracks, 'pans': pans, 'facing': facing,
            'source_words': {f'{address:#010x}': f'{value:#010x}' for address, value in source_words.items()},
            'scope': 'source dialogue, anchors, facing and movement lowerings; caller controls complete-scene admission; native playback remains unfinished'}


def hq_founding():
    data, origin = source('/VB7.BIN')
    if origin['sha256'] != CASTLE_SOURCES['/VB7.BIN']:
        raise ValueError('unsupported founding source identity')
    entity = scene.entities(data, scene.room_record(data, 4))[4]
    from export_field_actor_bindings import require_original_instructions
    selector_consumers = require_original_instructions()
    entities = scene.entities(data, scene.room_record(data, 4))
    actor_entities = [entry for entry in entities if entry['stream_offsets'][0] is not None]
    if [(entry['index'], entry['id']) for entry in actor_entities] != list(enumerate((27, 32, 3, 35, 1, 2, 118, 26, 38), 4)):
        raise ValueError('founding compact actor inventory changed')
    actors = []
    graphics = scene.character_bindings(data, scene.section_off(data, scene.room_record(data, 4)['section']))
    graphics_table = scene.ptr_at(data, scene.section_off(data, scene.room_record(data, 4)['section']) + 0x34)
    if (set(graphics) != {38, 27, 118, 26, 32} or struct.unpack_from('<6I', data, graphics_table) !=
            tuple(scene.RAM_BASE + graphics[character]['record'] for character in (38, 27, 118, 26, 32)) + (0,)):
        raise ValueError('founding terminated area graphics table changed')
    for selector, actor in enumerate(actor_entities):
        x, y, flags, character = struct.unpack_from('<4H', data, actor['offset'])
        if (x, y, flags, character) != (actor['x_half'], actor['y_half'], actor['flags'], actor['id']):
            raise ValueError('independent founding actor record reads disagree')
        classification, predicate = decode_predicate(data, actor['stream_offsets'][0], 'classification')
        if classification != {'pointer_state': 'present', 'terms': [{'kind': 'story_mask_set', 'flag': {'id': 'scenario_0012', 'mask': 64}}]}:
            raise ValueError('founding actor classification changed')
        actors.append({'selector': selector, 'entity': actor['index'], 'character': character,
                       'record': actor['offset'], 'flags': flags, 'initial_pixels': [x * 8, y * 8],
                       'classification': classification, 'predicate': predicate,
                       'classifier_return': data[actor['stream_offsets'][0] + predicate['size']:actor['stream_offsets'][0] + predicate['size'] + 2].hex(),
                       'area_graphics': graphics.get(character),
                       'scope': 'compact source identity; initial draw flags/facing and full runtime actor construction remain unfinished'})
    from opening_audience import actor_bindings
    flags = bytearray(256)
    flags[12] = 64
    independent_actors, _ = actor_bindings(data, 4, flags)
    if len(independent_actors) != len(actors):
        raise ValueError('independent founding constructor count disagrees')
    for actor, original in zip(actors, independent_actors, strict=True):
        parameter, orientation = bytes.fromhex(actor['classifier_return'])
        variant = orientation & 3
        appearance = {'variant': variant, 'facing': ('down', 'up', 'left', 'right')[variant],
                      'speed': (actor['flags'] >> 2) & 1, 'auto_animate': bool(actor['flags'] & 0x200),
                      'setup_parameter': parameter, 'orientation_flags': orientation}
        if (original['x'], original['y'], original['variant'], original['motion'], original['auto_animate'], original['attached']) != (
                *actor['initial_pixels'], variant, appearance['speed'], appearance['auto_animate'], True):
            raise ValueError('independent founding initial actor state disagrees')
        actor['appearance'] = appearance
        actor['native_actor_id'] = f"vb7_room_4_actor_{actor['entity']:02d}_{actor['character']:03d}"
        actor['staged'] = actor['initial_pixels'] == [2040, 2040]
        actor['resource_lookup'] = ({'kind': 'area', 'context': actor['area_graphics']['context']} if actor['area_graphics'] is not None else
                                    {'kind': 'party', 'required_party_graphic': actor['character']})
        actor['scope'] = 'source identity, initial setup and resource ownership qualified; setup-parameter depth lifetime and full founding native execution remain unfinished'
    if [(actor['selector'], actor['character']) for actor in actors if actor['staged']] != [(6, 118), (7, 26)]:
        raise ValueError('founding off-screen staging identity changed')
    if {actor['character'] for actor in actors if actor['resource_lookup']['kind'] == 'party'} != {1, 2, 3, 35}:
        raise ValueError('founding party resource fallback inventory changed')
    start, end = 0x154, 0x27b
    if entity['stream_offsets'][2] != start:
        raise ValueError('founding entry pointer changed')
    rows = []
    for row in decode_stream(data, start, max_insns=160):
        rows.append(row)
        if row[1] == 0xfd:
            break
    lengths = {2: 0, 3: 5, 7: 3, 8: 2, 9: 2, 0xa: 1, 0xb: 1, 0xc: 0,
               0x11: 2, 0x12: 2, 0x17: 1, 0x18: 0, 0x1c: 3, 0x20: 1, 0x24: 0,
               0x30: 0, 0x31: 0, 0x33: 0, 0x3a: 1, 0x41: 1, 0x45: 1,
               0x46: 0, 0x4b: 3, 0x4c: 2, 0x4f: 3, 0xfd: 0}
    cursor = start
    for offset, opcode, args, _ in rows:
        raw_opcode = data[cursor]
        if raw_opcode == 0x32:
            following = cursor + 2
            while following < end and data[following] != 5:
                if data[following] not in (0, 1, 2, 3, 4, 6, 7):
                    raise ValueError('unsupported literal founding motion')
                following += 2
            following += 1
        else:
            following = cursor + 1 + lengths[raw_opcode]
        if offset != cursor or opcode != raw_opcode or following > end or data[cursor + 1:following] != args:
            raise ValueError('independent founding operand walk disagrees')
        cursor = following
    if cursor != end or len(rows) != 123 or rows[-1][1] != 0xfd:
        raise ValueError('founding decode leaves bytes or changes its instruction inventory')
    if [(pc, args) for pc, op, args, _ in rows if op == 3] != [(0x274, bytes.fromhex('fc 22 00 0a 1c'))]:
        raise ValueError('founding terminal handoff changed')
    if (any(op in (5, 0x15, 0x21, 0x25, 0x2a, 0x2b, 0x43) for _, op, _, _ in rows)
            or [(pc, op) for pc, op, _, _ in rows if op == 0x24] != [(0x26c, 0x24)]
            or not any(pc == 0x217 and op == 0x0a and args == b'\x14' for pc, op, args, _ in rows)):
        raise ValueError('founding effect drawing scope changed')
    speaker_checks = []
    for current, following in zip(rows, rows[1:]):
        if current[1] in (0x0b, 0x17) and following[1] == 0x12:
            selector, character = current[2][0], following[2][1]
            if selector >= len(actors) or actors[selector]['character'] != character:
                raise ValueError('founding actor selectors disagree with named speaker prefixes')
            speaker_checks.append({'offset': current[0], 'selector': selector, 'character': character})
    if {row['selector'] for row in speaker_checks} != set(range(8)):
        raise ValueError('founding named actor cross-check coverage changed')
    destination, destination_origin = source('/VB5A2.BIN')
    main, main_origin = source('MAIN.EXE')
    if (destination_origin['sha256'] != '809159ba5816345f3314a3dec50c2a1e4cedd54f1086ed412ea5530a18d423d3'
            or main_origin['sha256'] != MAIN_SHA256):
        raise ValueError('unsupported founding destination identity')
    base = struct.unpack_from('<I', main, 24)[0]
    def word(address):
        value = struct.unpack_from('<I', main, 2048 + address - base)[0]
        if value != maindec.mword(address):
            raise ValueError('independent founding destination readers disagree')
        return value
    actor_setup_words = {0x8012f184: 0x27a50014, 0x8012f188: 0x0c04d177, 0x8012f18c: 0x27a60016,
                         0x801345e0: 0x34020006, 0x80134648: 0x24840001,
                         0x8013464c: 0x90820000, 0x80134654: 0xa4a20000,
                         0x80134658: 0x90820001, 0x80134660: 0xa0c20000,
                         0x8012f1c4: 0x93a50016, 0x8012f1d0: 0x30a50003,
                         0x8012f240: 0x93a50016, 0x8012f244: 0x87a60014,
                         0x8012f25c: 0x0c04ba90, 0x8012ea48: 0xa0450000,
                         0x8012f030: 0x00031882, 0x8012f034: 0x30630001}
    actor_setup_words.update({0x8012eac4: 0x340300ff, 0x8012eac8: 0x10430019,
                              0x8012eae0: 0xa0860016, 0x8012eb6c: 0xa0820016,
                              0x8012eb70: 0x90820001, 0x8012eb78: 0x00021023,
                              0x8012eb7c: 0xa0820016,
                              0x8012fe04: 0x1060000f, 0x8012fe2c: 0x10620005,
                              0x8012fe40: 0xa2220016, 0x8012fe48: 0x92220001,
                              0x8012fe50: 0x00021023, 0x8012fe54: 0xa2220016,
                              0x8012fe58: 0x92250016, 0x8012fe5c: 0x0c030fbc})
    for actor in actors:
        parameter = actor['appearance']['setup_parameter']
        tag = (-actor['initial_pixels'][1] // 8) & 255
        actor['appearance']['explicit_setup_draw_tag'] = None if parameter == 255 else parameter
        actor['appearance']['unattached_frame_draw_tag'] = tag
        if parameter != 255 and parameter != tag:
            raise ValueError('founding explicit draw tag differs from initial unattached Y')
    for address, expected_word in actor_setup_words.items():
        if word(address) != expected_word:
            raise ValueError('founding actor setup consumer changed')
    party_graphics_words = {0x801346b8: 0x8c420034, 0x801346f8: 0x8c420020,
                           0x80134704: 0x8c440004, 0x80134708: 0x0c04d11c,
                           0x80134738: 0x1440ffe8, 0x80134740: 0x90e20003, 0x80134758: 0x9042000e,
                           0x80134764: 0x00021080, 0x8013476c: 0x8c431b9c,
                           0x80134774: 0x90620000, 0x8013477c: 0x14440006,
                           0x80134784: 0x8c640028, 0x80134788: 0x0c04d11c,
                           0x801347ac: 0x3c04800c, 0x801347b4: 0x0c04e1fb,
                           0x801347bc: 0x00001021}
    for address, expected_word in party_graphics_words.items():
        if word(address) != expected_word:
            raise ValueError('founding party graphics lookup changed')
    descriptors = []
    for region in (1, 9):
        table = word(0x8016f67c + region * 4)
        descriptor = word(table + 34 * 4)
        if (descriptor != 0x80163e2c
                or (word(descriptor), word(descriptor + 4)) != (destination_origin['size'], destination_origin['lba'])):
            raise ValueError('founding destination descriptor disagrees with disc catalog')
        descriptors.append({'region': region, 'table': table, 'descriptor': descriptor})
    destination_room = scene.room_record(destination, 0)
    if destination_room is None or destination_room['entity_count'] != 52:
        raise ValueError('founding destination room changed')
    atomic_placements = []
    for pc, target, x, y in ((0x1ab, 6, 60, 13), (0x1e6, 7, 65, 9)):
        fragment = bytes((0x30, 7, target, 1, x, 7, target, 2, y, 0x31))
        group = [(offset, op, args) for offset, op, args, _ in rows if pc <= offset < pc + len(fragment)]
        expected_group = [(pc, 0x30, b''), (pc + 1, 7, bytes((target, 1, x))),
                          (pc + 5, 7, bytes((target, 2, y))), (pc + 9, 0x31, b'')]
        if data[pc:pc + len(fragment)] != fragment or group != expected_group:
            raise ValueError('independent founding atomic placement reads disagree')
        atomic_placements.append({'offset': pc, 'end': pc + len(fragment), 'consumed': len(fragment),
                                  'bytes': fragment.hex(), 'selector': target, 'position': {'x': x * 8, 'y': y * 8},
                                  'character': actors[target]['character'], 'entity': actors[target]['entity'],
                                  'native_kind': 'place_actor',
                                  'scope': 'one source continue/yield pump becomes one atomic x/y command; source actor identity derived; full scene binds in candidate36; native execution remains unfinished'})
    audio_inventory = [(0x1a5, 120, 0x50b), (0x1be, 37, 0x304), (0x1e0, 120, 0x50b),
                       (0x20b, 231, 0x813), (0x20d, 231, 0x813), (0x215, 42, 0x403), (0x272, 7, 0x15)]
    if [(pc, args[0]) for pc, op, args, _ in rows if op == 0x41] != [(pc, selector) for pc, selector, _ in audio_inventory]:
        raise ValueError('founding audio opcode inventory changed')
    audio_requests = []
    for pc, selector, expected in audio_inventory:
        address = 0x80171c2c + selector * 2
        request = struct.unpack_from('<H', main, 2048 + address - base)[0]
        if request != expected or (word(address & ~3) >> ((address & 3) * 8) & 65535) != request:
            raise ValueError('independent founding audio request readers disagree')
        entry = {'offset': pc, 'selector': selector, 'table_address': address, 'request': request,
                 'status': 'source-only; native binding remains unfinished'}
        if selector == 42:
            entry.update(kind='field_music', command=dict(hq_entry_music()['program']['commands'][0]),
                         status='packet33/IR14 ordinary music capability; complete founding scene binds in candidate36; native execution remains unverified')
        elif selector == 7:
            entry.update(kind='field_music', command=dict(ruins_audio_requests()[7]['command']))
        elif selector == 120:
            descriptor = 0x801651bc + (request - 0x500) * 4
            if word(descriptor) != 0x14270001:
                raise ValueError('founding sound descriptor changed')
            entry.update(kind='sound', descriptor=descriptor, bank=0, program=1, note=39, level=20,
                         status='common-bank candidate available; complete founding scene binds in candidate36; native execution remains unverified')
        elif selector == 37:
            from dot8_probe import _iso_listing
            descriptor = 0x80164e30 + (request & 255) * 8
            packed, volume, unused, length = struct.unpack_from('<BBHI', main, 2048 + descriptor - base)
            if (word(descriptor), word(descriptor + 4)) != (0x7f20, 7248) or (packed, volume, unused, length) != (0x20, 127, 0, 7248):
                raise ValueError('founding CD-XA descriptor changed')
            for address, expected_word in ((0x800c080c, 0x800c5044), (0x800c5048, 0x0c0318dd),
                                            (0x800c6390, 0x000210c0), (0x800c6398, 0x24214e31),
                                            (0x800c6508, 0x34030001), (0x800c6510, 0xa0239120),
                                            (0x800c6534, 0x3042000f), (0x800c659c, 0x00021102),
                                            (0x800c65a0, 0x00021080), (0x800c65a8, 0x242155f8),
                                            (0x800c65b0, 0x8c220000), (0x800c65d0, 0x3c021000),
                                            (0x800c65d4, 0x00621024), (0x800c65d8, 0x14400008),
                                            (0x800c65e4, 0xac239ca0), (0x800c65e8, 0x34020001),
                                            (0x800c65f0, 0xa0229bed), (0x800c8cdc, 0x0082202b),
                                            (0x800c8cf4, 0x14400021), (0x800c8d9c, 0xac229ca8),
                                            (0x800c8da0, 0x0c031c29), (0x800c8da4, 0x34040002)):
                if word(address) != expected_word:
                    raise ValueError('founding CD-XA consumer changed')
            lba = word(0x801655f8 + (packed >> 4) * 4)
            source_file, = [row for row in _iso_listing() if row['lba'] == lba and row['path'].endswith('/XA2.')]
            if lba != 183804 or source_file['size'] != 97632256:
                raise ValueError('founding CD-XA source lookup disagrees with catalog')
            entry.update(kind='cd_xa', descriptor=descriptor, file_index=packed >> 4, file_number=1, channel=packed & 15,
                         volume=volume, length_parameter=length,
                         repeat=True, restart_counter_threshold=length,
                         restart_condition='unsigned elapsed counter > threshold; reset baseline and queue CD action2',
                         command={'kind': 'field_music', 'music': 'founding'},
                         source={'file': source_file['path'], 'lba': lba, 'size': source_file['size']},
                         status='field audio3 and packet34/IR14 native restart/readiness capability; complete scene remains unbound')
        elif selector == 231:
            descriptor = 0x8016546c + (request - 0x800) * 12
            raw = main[2048 + descriptor - base:2048 + descriptor - base + 12]
            if raw.hex() != '00020328010001000800012d' or raw != b''.join(struct.pack('<I', word(descriptor + offset)) for offset in (0, 4, 8)):
                raise ValueError('founding timed sound descriptor changed')
            for address, expected_word in ((0x800c0820, 0x800c5094), (0x800c5098, 0x0c0316d7),
                                            (0x800c5b64, 0x2484f800), (0x800c5bc4, 0x00041040),
                                            (0x800c5bc8, 0x00441021), (0x800c5bcc, 0x00021080),
                                            (0x800c5c8c, 0x2421546c), (0x800c5d04, 0x34021000),
                                            (0x800c8f10, 0x26319d90), (0x800c8f14, 0x26300014),
                                            (0x800c9024, 0x34020010), (0x800c90c0, 0x00621821),
                                            (0x800c9224, 0x0c057db4), (0x8015f79c, 0x32220010),
                                            (0x8015f7b4, 0x96040014), (0x8015f7bc, 0xa4440004),
                                            (0x80178768, 0x1f801c00)):
                if word(address) != expected_word:
                    raise ValueError('founding timed sound dispatch/index changed')
            entry.update(kind='timed_sound', descriptor=descriptor, bank=0, program=2, tone_index=3, note=40,
                         period=1, pitch_delta=1, duration_parameter=8, mode=1, level=45,
                         status='sound schema5 candidate with pitch-delta1 controller; complete founding scene binds in candidate36; native execution remains unverified')
        audio_requests.append(entry)
    classification, _ = decode_predicate(data, entity['stream_offsets'][0], 'classification')
    selection, _ = decode_predicate(data, entity['stream_offsets'][1], 'event', coordinate_ranges=True)
    return {'source': origin, 'room': 4, 'entity': 4, 'offset': start, 'end': end,
            'consumed': end - start, 'instruction_count': len(rows), 'classification': classification,
            'selection': selection, 'stream_sha256': hashlib.sha256(data[start:end]).hexdigest(),
            'instructions': [{'offset': pc, 'opcode': op, 'operands': list(args)} for pc, op, args, _ in rows],
            'effects': hq_effect_callbacks(),
            'party_recovery': hq_party_recovery(),
            'party_dismissal': hq_party_dismissal(),
            'audio_requests': audio_requests,
            'actors': actors, 'actor_selector_consumers': selector_consumers, 'actor_speaker_checks': speaker_checks,
            'actor_setup_words': {f'{address:#010x}': f'{value:#010x}' for address, value in actor_setup_words.items()},
            'choreography': hq_choreography(data, rows, actors, word, (12, 3, [(0, 1, 40), (0, -1, 40)])),
            'sprite_modes': hq_founding_sprite_modes(data, actors, word),
            'field_effect_blend': 'half',
            'field_effect_blend_scope': 'normal founding drawing only: normal sprites/scenery and dialogue select0; shadows submit at256; room initialization clears the optional callback/fade; no choice or optional-draw dispatcher is installed; the sole fade follows the25-update collapse by a100-update delay',
            'party_graphics_words': {f'{address:#010x}': f'{value:#010x}' for address, value in party_graphics_words.items()},
            'atomic_placements': atomic_placements,
            'actor_draw_tag_policy': 'setup FF chooses support tag or negative cell Y; explicit setup tags are overwritten by the ground draw pass using support tag or negative current cell Y',
            'terminal_handoff': {'offset': 0x274, 'area': 34, 'room': 0, 'spawn_pixels': [80, 224],
                                 'destination': destination_origin, 'main': main_origin,
                                 'descriptors': descriptors, 'room_record': destination_room,
                                 'auxiliary_party': hq_auxiliary_party(),
                                 'scope': 'destination and morning continuation bound in candidate32; incoming founding scene binds in candidate36; native playback remains unfinished'},
            'effect_lowerings': [{'offset': pc, 'command': {'kind': 'field_effect',
                                   'effect': {0: 'appearance', 2: 'disappearance'}[args[0]],
                                   'x': args[1] * 8, 'y': args[2] * 8}}
                                 for pc, op, args, _ in rows if op == 0x4f],
            'scope': 'independently bounded straight-line inventory; complete candidate36 scene binding uses116 commands, with two atomic placement groups folded and the terminal handoff owning completion; native execution remains unverified'}


def initial_island(read, word):
    data, origin = source('/VB5I0.BIN')
    ruins, ruins_origin = source('/VB5.BIN')
    if origin['sha256'] != '4dc12f64841f271d696cdc4e8fbd5a595665d4556cd6b3837fe2af0bff34f762' or ruins_origin['sha256'] != 'bcbec83e79544720ff347e426dbbb2353d9594cdffe2da7e51c55b08a488d127':
        raise ValueError('unsupported initial island identity')
    record = scene.room_record(data, 0)
    entities = scene.entities(data, record)
    if record['entity_count'] != 2 or [e['flags'] for e in entities] != [16, 0]:
        raise ValueError('initial island entity roles changed')
    conditions = [{'kind': 'story_mask_clear', 'flag': {'id': 'scenario_0029', 'mask': 32}}]
    for entity in entities:
        predicate, _ = decode_predicate(data, entity['stream_offsets'][1], 'classification')
        if predicate['terms'] != conditions:
            raise ValueError('initial island selection changed')
    expected = [bytes.fromhex('30 07 80 01 ff 07 80 02 ff 26 04 12 31 fd'),
                bytes.fromhex('0a 32 08 00 24 0a 32 09 1d 20 03 fc 04 00 11 2b fd')]
    streams = []
    for entity, fragment in zip(entities, expected, strict=True):
        start = entity['stream_offsets'][2]
        if data[start:start + len(fragment)] != fragment:
            raise ValueError('initial island stream changed')
        decoded = []
        for row in decode_stream(data, start, max_insns=16):
            decoded.append(row)
            if row[1] == 0xfd:
                break
        if decoded[-1][0] + 1 != start + len(fragment) or decoded[-1][1] != 0xfd:
            raise ValueError('initial island instruction decode leaves bytes')
        streams.append({'entity': entity['index'], 'offset': start,
                        'bytes': fragment.hex(), 'consumed': len(fragment),
                        'instructions': [{'offset': pc, 'opcode': op, 'operands': list(args)}
                                         for pc, op, args, _ in decoded]})
    # Independent full-header/headerless reads pin writers and their frame consumers.
    anchors = {0x8013cc94: 0x000318c0, 0x8013ccd8: 0x00031080,
               0x8013ccdc: 0x00431021, 0x8013edbc: 0x24e2fffe,
               0x8013ee18: 0x2462ffff, 0x8013ed98: 0x24211860,
               0x8013eda8: 0x24211870, 0x8013cbf8: 0x00431025,
               0x8013cc00: 0xa0820190, 0x80139b28: 0x000210c0,
               0x80139b3c: 0x000210c0}
    for address, expected_word in anchors.items():
        if word(address) != expected_word:
            raise ValueError(f'initial island consumer changed at {address:#x}')
    dx = struct.unpack('<i', read(0x80171860, 4))[0]
    dy = struct.unpack('<i', read(0x80171870, 4))[0]
    if (dx, dy) != (0, -1):
        raise ValueError('initial island pan direction changed')
    descriptor = word(word(0x8016f67c + 9 * 4) + 4 * 4)
    if struct.unpack('<II', read(descriptor, 8)) != (ruins_origin['size'], ruins_origin['lba']):
        raise ValueError('initial island onward module disagrees with catalog')
    spawn = (17 * 8, 43 * 8)
    if scene.room_record(ruins, 0)['section'] != 0:
        raise ValueError('ruins arrival room changed')
    ordinary = streams[1]['instructions']
    if [entry['opcode'] for entry in ordinary] != [0x0a, 0x08, 0x0a, 0x09, 0x03, 0xfd]:
        raise ValueError('initial island ordinary opcode sequence changed')
    pan_updates = ordinary[1]['operands'][1] * 8 // 2
    commands = [
        {'kind': 'delay', 'updates': ordinary[0]['operands'][0] * 5, 'wait': {'kind': 'delay', 'id': 'delay'}},
        {'kind': 'pan', 'dx': dx, 'dy': dy, 'updates': pan_updates, 'wait': {'kind': 'pan', 'id': 'pan'}},
        {'kind': 'delay', 'updates': ordinary[2]['operands'][0] * 5, 'wait': {'kind': 'delay', 'id': 'delay'}},
        {'kind': 'story_or', 'flag': {'id': 'scenario_0029', 'mask': 32}},
        {'kind': 'room_transition', 'destination': 'vb5_room_0', 'x': spawn[0], 'y': spawn[1]},
    ]
    return {'source': origin, 'room': 0, 'streams': streams,
            'selection': conditions,
            'initialization': {'hero_descriptor_position': [2040, 2040], 'camera_pixels': [32, 144],
                               'same_pump': True, 'yields_before_terminal_wait': True},
            'initialization_program': {'id': 'vb5i0_room_0_init', 'entry': 'initialization', 'entity': 0,
                                       'trigger': 'none', 'conditions': conditions, 'commands': [
                                           {'kind': 'continue_tick'},
                                           {'kind': 'set_hero_display', 'x': 2040, 'y': 2040},
                                           {'kind': 'set_camera', 'x': 32, 'y': 144},
                                           {'kind': 'yield_tick'}, {'kind': 'end_stream'}]},
            'pan': {'dx_per_update': dx, 'dy_per_update': dy, 'updates': 144, 'final_camera': [32, 0]},
            'onward': {'region': 9, 'area': 4, 'room': 0, 'room_id': 'vb5_room_0',
                       'spawn_pixels': list(spawn), 'module': ruins_origin, 'descriptor': descriptor},
            'ordinary_program': {'id': 'vb5i0_room_0_arrival', 'entry': 'ordinary', 'entity': 1,
                                 'trigger': 'none', 'conditions': conditions, 'commands': commands},
            'source_words': {f'{a:#010x}': f'{w:#010x}' for a, w in anchors.items()},
            'scope': 'initializer display/camera and ordinary commands lowered; native scene-view support implemented; source selection and consumers qualified; scheduling integration, live rooms and presentation acceptance remain pending'}


def dock_rows(data):
    """Cross-check the bounded dock stream with a separate literal operand walk."""
    rows = []
    for row in decode_stream(data, 0x1a48, max_insns=128):
        rows.append(row)
        if row[1] == 0xfd:
            break
    lengths = {0: 5, 1: 1, 2: 0, 7: 3, 9: 2, 0x0a: 1, 0x0b: 1, 0x0c: 0,
               0x10: 2, 0x11: 2, 0x12: 2, 0x17: 1, 0x18: 0, 0x1c: 3, 0x1f: 1,
               0x33: 0, 0x36: 0, 0x37: 0, 0x38: 0, 0x3a: 1, 0x41: 1, 0x46: 0, 0x4b: 3, 0xfd: 0}
    cursor = 0x1a48
    for offset, opcode, args, _ in rows:
        raw_opcode = data[cursor]
        if raw_opcode == 0x32:
            end = cursor + 2
            while end < 0x1b2a and data[end] != 5:
                if data[end] not in (0, 1, 2, 3, 4, 6, 7):
                    raise ValueError("unsupported literal dock track")
                end += 2
            if end >= 0x1b2a:
                raise ValueError("unterminated literal dock track")
            end += 1
        elif raw_opcode == 0x3b:
            end = cursor + 2 + data[cursor + 1]
        else:
            if raw_opcode not in lengths:
                raise ValueError("unsupported literal dock opcode")
            end = cursor + 1 + lengths[raw_opcode]
        if (offset, opcode, args) != (cursor, raw_opcode, data[cursor + 1:end]):
            raise ValueError("independent dock operand walk disagrees")
        cursor = end
    if cursor != 0x1b2a or len(rows) != 83 or rows[-1][1] != 0xfd:
        raise ValueError("dock stream not fully consumed")
    return rows


def dock_arrival(read, word):
    from opening_audience import track, text as decode_text
    from export_field_party_queue import export as party_queues
    import war_text
    import character_table
    from export_opening_scene import portrait_payload
    data, origin = source('/VB5.BIN')
    if origin['sha256'] != 'bcbec83e79544720ff347e426dbbb2353d9594cdffe2da7e51c55b08a488d127':
        raise ValueError('unsupported dock identity')
    entity = scene.entities(data, scene.room_record(data, 0))[2]
    if (entity['id'], entity['flags'], entity['stream_offsets'][2]) != (32, 3, 0x1a48):
        raise ValueError('dock arrival caller changed')
    rows = dock_rows(data)
    if rows[-1][0] != 0x1b29 or rows[0][1:3] != (9, bytes((12, 32))):
        raise ValueError('dock arrival stream boundary changed')
    party_order = next(args for _, op, args, _ in rows if op == 0x3b)
    if party_order != bytes((5, 8, 2, 1, 35, 3)):
        raise ValueError('dock transient party order changed')
    anchor = tuple(value * 8 for value in rows[1][2])
    if rows[1][1] != 0x10 or anchor != (136, 216) or rows[3][1] != 0x36 or [(off, op) for off, op, _, _ in rows if op in (0x37, 0x38)] != [(0x1af2, 0x37), (0x1af3, 0x38)]:
        raise ValueError('dock party formation entry changed')
    formation, formation_proof = party_queues()
    for entry, proof in zip(formation['tracks'], formation_proof['tracks'], strict=True):
        raw = bytes.fromhex(proof['bytes'])
        if read(proof['pointer'], len(raw)) != raw or track(raw) != entry['commands']:
            raise ValueError('independent party track decoders disagree')
    formation.pop('content_sha256')
    formation.update(schema='suikoden-field-party-queue/2', anchor={'x': anchor[0], 'y': anchor[1]})
    formation['content_sha256'] = hashlib.sha256(json.dumps(formation, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    from room_battle_package import validate_room_queues
    validate_room_queues(formation)
    anchors = {0x800c1a80: 0x8013ea6c, 0x8013ea6c: 0xa2400005,
               0x8013ea80: 0xa2020008, 0x8013ea9c: 0x34420004,
               0x8013ebc8: 0x3062001f, 0x8013ebd8: 0xa202000b,
               0x8013ebe4: 0x2442ffff, 0x8013ebf8: 0xa202000b,
               0x8013ed04: 0x9202000a, 0x8013ed0c: 0xa2420005,
               0x8013c4a4: 0xa0c2000a, 0x8013c4ac: 0xa2220005,
               0x8013e8b0: 0x144000d4,
               0x8013eab0: 0x34420088, 0x8013eab8: 0x2402fffe,
               0x8013eabc: 0xa2420003, 0x8013ec3c: 0x1840000c,
               0x8013ecb4: 0x30620080, 0x8013ecbc: 0x246200ff,
               0x8013ecc4: 0x3042001f, 0x8013ecc8: 0x2c420005,
               0x8013ecdc: 0x2442fffe, 0x8013ecf0: 0x24420002,
               0x8013ecfc: 0x14400004,
               0x8013c4f8: 0x0c04ea02, 0x8013c540: 0x24631a78,
               0x8013c56c: 0x36030040, 0x8013c594: 0xac620004,
               0x8013c5ac: 0xa062000a,
               0x8013a87c: 0x9063bd74, 0x8013a888: 0xa2430000,
               0x8013a890: 0x9063bd75, 0x8013a894: 0xa220ffee,
               0x8013a898: 0xa220ffef, 0x8013a8ac: 0xa223ffed,
               0x8013c3a0: 0x32020040, 0x8013c3b4: 0x3204003f,
               0x8013c3b8: 0x0082102a, 0x8013c3d0: 0x00441021,
               0x8013c3e8: 0x000210c0, 0x8013c498: 0x92220005,
               0x8013c49c: 0xa2200002, 0x8013c4a0: 0xa2200003,
               0x8013c4a8: 0x34020002}
    anchors.update({0x8013ce44: 0x24211b98, 0x8013ce4c: 0x8c250000,
                    0x8013ce50: 0x0c04f33c, 0x8013b0e8: 0x0c04ebe8,
                    0x8013b034: 0x3082003f, 0x8013b040: 0x8c84af94,
                    0x8013b048: 0x000318c0, 0x8013b06c: 0x90e20000,
                    0x8013b080: 0x24420001, 0x8013b098: 0x90e20001,
                    0x8013b0ac: 0x2442fffd, 0x801397a4: 0x30420003,
                    0x801397bc: 0x2442ffff})
    for address, expected in anchors.items():
        if word(address) != expected:
            raise ValueError(f'dock motion consumer changed at {address:#x}')
    # Independent reference follows the source low-five-bit divider and unit counter.
    for units in (1, 8, 255):
        flags, remaining, updates = 4, units, 0
        while remaining:
            updates += 1
            if flags & 31:
                flags -= 1
            else:
                remaining -= 1
                flags = 4
        if updates != units * 5:
            raise ValueError('source hold counter does not agree with exported units')
    # Independent byte-flag consumer reference; the native controller uses a named curve.
    flags, offset = 0x88, -2
    hop_offsets = [offset]
    while offset:
        flags = (flags + 255) & 255
        offset += 2 if flags & 31 < 5 else -2
        hop_offsets.append(offset)
        if len(hop_offsets) > 8:
            raise ValueError('source hop did not finish in eight queue passes')
    if hop_offsets != [-2, -4, -6, -8, -6, -4, -2, 0]:
        raise ValueError('source hop curve changed')
    tracks = []
    for offset, opcode, args, _ in rows:
        if opcode != 0x32:
            continue
        commands = track(args[1:])
        tracks.append({'offset': offset, 'selector': args[0], 'commands': commands})
    holds = [command for entry in tracks for command in entry.get('commands', []) if command['kind'] == 'hold']
    if holds != [{'kind': 'hold', 'updates': 40}] * 2 or len(tracks) != 5:
        raise ValueError('dock hold/track inventory changed')
    if tracks[3]['offset'] != 0x1abe or tracks[3]['commands'] != [{'kind': 'hop'}, {'kind': 'hop'}, {'kind': 'finish'}]:
        raise ValueError('dock double-hop track changed')
    temporary_tracks = []
    for entry in tracks:
        if entry['selector'] & 0x40:
            index = entry['selector'] & 63
            if entry['offset'] != 0x1a67 or index != 1 or party_order[index + 2] != 1:
                raise ValueError('dock temporary actor target changed')
            temporary_tracks.append({'id': 'vb5_room_0_arrival_cleo_track',
                                     'actor': f'party_follower_{index}', 'commands': entry['commands']})
    if len(temporary_tracks) != 1:
        raise ValueError('dock temporary track inventory changed')
    compact = [e for e in scene.entities(data, scene.room_record(data, 0))
               if e['flags'] & 0x101 and e['stream_offsets'][0] is not None]
    if [(e['index'], e['id']) for e in compact] != [(2, 32), (3, 38)]:
        raise ValueError('dock ordinary actor slots changed')
    axis_words = {0x800c197c: 0x8013c9e0, 0x800c1980: 0x8013ca10,
                  0x8013c9f8: 0x90420000, 0x8013ca04: 0xa0820000,
                  0x8013ca28: 0x90420000, 0x8013ca34: 0xa0820001,
                  0x8013c790: 0x90820001, 0x8013c798: 0x00021023,
                  0x8013c7a0: 0xa0820016}
    for address, expected in axis_words.items():
        if word(address) != expected:
            raise ValueError('dock axis write/depth consumer changed')
    placements = []
    for offset, opcode, args, _ in rows:
        if opcode != 7:
            continue
        selector, parameter, value = args
        if selector >= len(compact) or parameter not in (1, 2):
            raise ValueError('unsupported dock actor position action')
        entity = compact[selector]
        actor = f"vb5_room_0_actor_{entity['index']:02d}_{entity['id']:03d}"
        placements.append({'offset': offset, 'command': {'kind': 'place_actor', 'actor': actor,
                                                        'x' if parameter == 1 else 'y': value * 8}})
    if [entry['offset'] for entry in placements] != [0x1a57, 0x1a5b, 0x1a5f, 0x1a63]:
        raise ValueError('dock position action inventory changed')
    release_words = {0x8013c8a4: 0x8c620008, 0x8013c8ac: 0x1040000b,
                     0x8013c8c0: 0xa0600005, 0x8013c8c8: 0x340200fe,
                     0x8013c8d0: 0xa0620000, 0x8013c8d4: 0x340200fe,
                     0x8013c8d8: 0xa0620001, 0x80144b94: 0x92030001,
                     0x80144b9c: 0x30620001, 0x80144ba0: 0x1040001c}
    for address, expected in release_words.items():
        if word(address) != expected:
            raise ValueError('dock descriptor release/draw consumer changed')
    releases = [(offset, args) for offset, opcode, args, _ in rows if opcode == 0x3a]
    if releases != [(0x1af4, bytes((0,)))]:
        raise ValueError('dock descriptor release changed')
    release = {'offset': 0x1af4, 'command': {'kind': 'release_actor', 'actor': 'vb5_room_0_actor_02_032'},
               'scope': 'active ordinary descriptor after completed motion; roster unchanged'}
    fixed_words = {0x800c4dd4: 0x0c030c41, 0x800c4dd8: 0x34040501,
                   0x80171718: 0x8013b51c, 0x8017171c: 0x8013b694,
                   0x8013b590: 0x000420c0, 0x8013b594: 0x2484ff6a,
                   0x8013b5ac: 0x000528c0, 0x8013b5b0: 0x24a5ff98,
                   0x8013b5c8: 0x24c60008, 0x8013b5dc: 0x0c051465,
                   0x80145204: 0x34020008, 0x8014522c: 0x3402000c,
                   0x80145254: 0x00430018, 0x80145268: 0x00430018,
                   0x8013b604: 0xa7a0001e, 0x8013b608: 0xa7a0001c,
                   0x8013b60c: 0xa7a0001a, 0x8013b610: 0xa7a00018,
                   0x8013b628: 0x0c03136d, 0x8013b62c: 0x34060014,
                   0x8013b6ec: 0x0c051591, 0x8013b6f0: 0x34050014,
                   0x80145a70: 0x2442ffff, 0x80145a74: 0x0c051d5a,
                   0x801475b8: 0x0064001a}
    for address, expected in fixed_words.items():
        if word(address) != expected:
            raise ValueError('fixed text box constructor/transition consumer changed')
    fixed = [(offset, args) for offset, opcode, args, _ in rows if opcode == 0]
    if fixed != [(0x1b13, bytes((0, 10, 10, 12, 2)))]:
        raise ValueError('dock fixed text box operands changed')
    slot, cell_x, cell_y, columns, lines = fixed[0][1]
    rect = {'x': cell_x * 8 - 150 + 160, 'y': cell_y * 8 - 104 + 120,
            'width': (columns + 8) * 8, 'height': lines * 12}
    # Independent read of the five literal operands and constructor's pixel fields.
    literal = data[0x1b14:0x1b19]
    independent = {'x': (literal[1] << 3) + 10, 'y': (literal[2] << 3) + 16,
                   'width': (literal[3] + 8) << 3, 'height': literal[4] * 12}
    if literal[0] != slot or rect != independent or rect != {'x': 90, 'y': 96, 'width': 160, 'height': 24}:
        raise ValueError('independent fixed box rectangle decode disagrees')
    fixed_box = {'offset': 0x1b13, 'source_operands': list(literal),
                 'command': {'kind': 'open_fixed_box', 'box': slot, **rect,
                             'requires': {'kind': 'box_closed', 'id': f'box_{slot}'}},
                 'collapsed_screen_rect': [160, 120, 0, 0], 'transition_updates': 20,
                 'window_request_cue': 0x501,
                 'close': {'offset': 0x1b21, 'command': {'kind': 'close_box', 'box': slot}},
                 'source_words': {f'{a:#010x}': f'{w:#010x}' for a, w in fixed_words.items()}}
    if data[0x1b21:0x1b23] != bytes((1, slot)):
        raise ValueError('dock fixed box close changed')
    music_rows = [(offset, args) for offset, opcode, args, _ in rows if opcode == 0x41]
    if music_rows != [(0x1af6, bytes((150,)))]:
        raise ValueError('dock source audio request changed')
    request_address = 0x80171c2c + 150 * 2
    request = struct.unpack('<H', read(request_address, 2))[0]
    if request != 0x52a or word(request_address) & 65535 != request:
        raise ValueError('dock audio table readers disagree')
    audio_words = {0x80139970: 0x86040000, 0x80139974: 0x0c050910,
                   0x80139984: 0xa6220030, 0x80142460: 0x10830015,
                   0x80142468: 0x2602fdff, 0x80142470: 0x2c420245,
                   0x80142484: 0x0c030c41, 0x801651c0: 0xe2180000,
                   0x80165264: 0x1e250001, 0x800c2870: 0x0040f809,
                   0x800c295c: 0x0c030c31}
    for address, expected in audio_words.items():
        if word(address) != expected:
            raise ValueError('dock audio dispatch/order changed')
    audio = {'offset': 0x1af6, 'source_selector': 150, 'table_address': request_address,
             'command': {'kind': 'play_sound', 'cue': request}, 'window_cue': 0x501,
             'cached_music_range': [0x201, 0x445], 'request_updates_cache': False,
             'stream_restore': 'existing cue52A clears the level and requests one-unit per audio-poll restoration to the configured stream volume',
             'source_words': {f'{a:#010x}': f'{w:#010x}' for a, w in audio_words.items()}}
    ordinary_tracks = []
    for entry in tracks:
        if entry['selector'] & 0x40:
            continue
        entity = compact[entry['selector']]
        ordinary_tracks.append({'id': f"vb5_room_0_arrival_track_{entry['offset']:04x}",
                                'actor': f"vb5_room_0_actor_{entity['index']:02d}_{entity['id']:03d}",
                                'commands': entry['commands']})
    dialogues, facing, portraits = [], [], {}
    boxes, speakers = {}, {}
    text_table = scene.ptr_at(data, scene.ptr_at(data, 0) + 20)
    character_ids = read(0x80170095, 109)
    for offset, opcode, args, _ in rows:
        if opcode in (0x0b, 0x17):
            boxes[0 if opcode == 0x0b else 1] = {'source_offset': offset, 'selector': args[0]}
        elif opcode == 0:
            boxes[args[0]] = {'source_offset': offset, 'fixed_operands': list(args[1:])}
        elif opcode == 0x12:
            speakers[args[0]] = args[1]
        elif opcode == 0x1c:
            box, page, index = args
            pointer = scene.ptr_at(data, scene.ptr_at(data, text_table + page * 4) + index * 4)
            tokens, end = decode_text(data, pointer)
            decoded, used = war_text.decode(data, pointer)
            if any(token['kind'] not in ('glyph', 'newline') for token in tokens):
                raise ValueError('dock dialogue control inventory changed')
            plain = ''.join(token.get('text', '\n') for token in tokens)
            if used != end - pointer or plain != decoded:
                raise ValueError('independent dock text decoders disagree')
            character = speakers[box]
            rank = character_ids.index(character) + 1
            name_pointer = word(0x80170588 + rank * 4)
            name = bytearray()
            for i in range(64):
                byte = read(name_pointer + i, 1)[0]
                if byte == 0:
                    break
                name.append(byte)
            else:
                raise ValueError('unterminated dock speaker name')
            prefix, prefix_end = decode_text(bytes(name) + b'\x03\0', 0)
            speaker, name_used = war_text.decode(bytes(name) + b'\0')
            if prefix_end != len(name) + 2 or name_used != len(name) + 1 or prefix != [*({'kind': 'glyph', 'text': c} for c in speaker), {'kind': 'newline'}]:
                raise ValueError('dock speaker prefix disagrees with source name/control')
            if character not in portraits:
                raw, portrait_origin = source('/04_PLAY/' + character_table.by_id()[character]['sprite_file'])
                image_at, palette_at = struct.unpack_from('<II', raw, 44)
                plane, palette, _ = portrait_payload(raw, image_at, palette_at)
                portraits[character] = {'source': portrait_origin, 'image': image_at, 'palette': palette_at,
                                        'plane_sha256': hashlib.sha256(plane).hexdigest(),
                                        'palette_sha256': hashlib.sha256(struct.pack('<256H', *palette)).hexdigest()}
            anchor = dict(boxes[box])
            if anchor.get('selector', 0) & 0x40:
                follower = anchor['selector'] & 63
                if party_order[follower + 2] != character:
                    raise ValueError('dock dialogue speaker disagrees with temporary actor')
                anchor.update(follower=follower, actor=f'party_follower_{follower}')
            dialogues.append({'source_offset': offset, 'box': box, 'page': page, 'index': index,
                              'string_offset': pointer, 'end': end, 'tokens': tokens, 'anchor': anchor,
                              'character': character, 'speaker_name': speaker, 'prefix_tokens': prefix,
                              'name_pointer': name_pointer, 'prefix_updates': len(prefix), 'portrait': portraits[character]})
        elif opcode == 0x11 and args[0] & 0x40 and args[0] < 0x80:
            follower = args[0] & 63
            facing.append({'source_offset': offset, 'character': party_order[follower + 2],
                           'command': {'kind': 'actor_transition', 'actor': f'party_follower_{follower}',
                                       'transition': word(0x80171b98 + args[1] * 4)}})
    if len(dialogues) != 7 or [(entry['anchor'].get('follower'), entry['box']) for entry in dialogues[:3]] != [(1, 0), (3, 1), (0, 0)] or [entry['character'] for entry in facing] != [2, 1, 35, 3]:
        raise ValueError('dock dialogue/facing inventory changed')
    resources = scene.character_bindings(data, scene.section_off(data, 0))
    if resources[32]['index'] != 0:
        raise ValueError('dock character load slot changed')
    tail = [(offset, opcode, args) for offset, opcode, args, _ in rows if opcode in (0x1f, 0x4b)]
    if tail != [(0x1b23, 0x1f, bytes((0,))), (0x1b25, 0x4b, bytes((0, 32, 9)))]:
        raise ValueError('dock load/growth tail changed')
    roster_words = {0x800c4870: 0x28420006, 0x800c487c: 0x08031233,
                    0x800c49f0: 0xa0328003, 0x800c49f8: 0xa044000d,
                    0x800e9cf4: 0x2c420063, 0x800e9cf8: 0x1040005b,
                    0x80139614: 0x90431af4, 0x8013961c: 0x30620001,
                    0x80139624: 0x30620002, 0x80139638: 0x2882006c,
                    0x80139644: 0x28a20019, 0x8013964c: 0x28a2002d,
                    0x80139674: 0x30420002, 0x80139688: 0x28a2005a,
                    0x801396d4: 0xa0820034, 0x80139f48: 0x90420000, 0x80139f54: 0x90621af4,
                    0x80139f5c: 0x34420001, 0x80139f64: 0xa0621af4,
                    0x80139f90: 0x0c031255, 0x80139f98: 0x0c03126e,
                    0x80139134: 0x0c04e1d7, 0x8013916c: 0x90700000,
                    0x801391e8: 0x0c03a731, 0x801391f0: 0x2610ffff,
                    0x801391f8: 0x1440fffb, 0x80139200: 0x0c032983}
    for address, expected in roster_words.items():
        if word(address) != expected:
            raise ValueError('dock load/growth consumer changed')
    roster_tail = {'character': 'tai_ho', 'character_id': 32, 'resource_index': 0,
                   'load_offset': 0x1b23, 'loaded_flag_bits': 1,
                   'growth_offset': 0x1b25, 'requested_level_advances': 9,
                   'growth_record': 'existing Tai Ho character record',
                   'commands': [{'kind': 'party_load', 'character': 'tai_ho'},
                                {'kind': 'advance_character', 'character': 'tai_ho', 'level_advances': 9}],
                   'native_admission': 'IR10 separates loading from growth; full source scene execution remains unqualified',
                   'source_words': {f'{a:#010x}': f'{w:#010x}' for a, w in roster_words.items()}}
    positions = {e['index'] - 2: [e['x_half'] * 8, e['y_half'] * 8] for e in compact}
    final_facing, released = {}, []
    track_by_offset = {entry['offset']: entry for entry in tracks}
    for offset, opcode, args, _ in rows:
        if opcode == 7:
            positions[args[0]][args[1] - 1] = args[2] * 8
        elif opcode == 0x32 and args[0] in positions:
            for command in track_by_offset[offset]['commands']:
                if command['kind'] == 'move':
                    dx, dy = {'up': (0, -8), 'right': (8, 0), 'down': (0, 8), 'left': (-8, 0)}[command['direction']]
                    positions[args[0]][0] += dx * command['cells']
                    positions[args[0]][1] += dy * command['cells']
                elif command['kind'] not in ('hop', 'finish'):
                    raise ValueError('unqualified dock final displacement')
        elif opcode == 0x11 and args[0] in positions:
            final_facing[args[0]] = ('down', 'up', 'left', 'right')[word(0x80171b98 + 4 * args[1])]
        elif opcode == 0x3a:
            released.append(args[0])
    yam = compact[1]
    if positions != {0: [136, 216], 1: [112, 264]} or final_facing[1] != 'up' or released != [0]:
        raise ValueError('dock final actor state changed')
    if positions[1] != [yam['x_half'] * 8, yam['y_half'] * 8]:
        raise ValueError('dock survivor no longer ends at its constructor position')
    settled = {'survivor': {'entity': yam['index'], 'character': yam['id'], 'position': positions[1], 'facing': final_facing[1]},
               'released_character': 32, 'released_pre_hide_position': positions[0],
               'scope': 'algebraic endpoint and final explicit facing only; no execution or cadence claim'}
    return {'source': origin, 'room': 0, 'entity': 2, 'stream_start': 0x1a48, 'stream_end': 0x1b2a,
            'settled_actors': settled, 'stream_bytes': data[0x1a48:0x1b2a].hex(' '), 'instruction_count': len(rows),
            'source_offsets': [row[0] for row in rows],
            'stream_verification': 'canonical decoder and independent literal operand walk agree;83 instructions;226 bytes fully consumed',
            'source_party_order': list(party_order[1:]), 'tracks': tracks, 'motion_schema': 'suikoden-event-ir/6',
            'temporary_tracks': temporary_tracks, 'ordinary_tracks': ordinary_tracks,
            'placements': placements, 'release': release, 'fixed_box': fixed_box, 'audio': audio, 'roster_tail': roster_tail,
            'release_source_words': {f'{a:#010x}': f'{w:#010x}' for a, w in release_words.items()}, 'position_source_words': {f'{a:#010x}': f'{w:#010x}' for a, w in axis_words.items()},
            'scene_schema': 'suikoden-event-ir/10', 'dialogue_schema': 'suikoden-field-dialogue/9',
            'dialogues': dialogues, 'party_facing': facing, 'dialogue_anchor_offset_pixels': [8, -24],
            'temporary_track_target': {'selector': 0x41, 'follower': 1, 'character': 1,
                                       'name': 'Cleo', 'persistent_membership_changed': False,
                                       'start': 'save motion; clear offsets; set motion2',
                                       'scope': 'existing idle temporary descriptor only; absent/concurrent queue ownership is not admitted'},
            'formation': formation,
            'formation_proof': {'tables': formation_proof['tracks'], 'consumers': formation_proof['consumers'],
                                'anchor_pixels': list(anchor), 'party_order_scope': 'transient area order; persistent membership unchanged',
                                'scope': 'source spread/return tracks at the dock anchor; named custom temporary track and primary graphics bind separately; full scene remains unadmitted'},
            'hold': {'source_units': 8, 'updates': 40, 'dispatch_decrements': False,
                     'pause_while_interpolating': True, 'restore': 'pre-queue motion value on final countdown update'},
            'hop': {'offsets_y': hop_offsets, 'updates_including_dispatch': 8,
                    'changes_position_or_facing': False,
                    'restore': 'pre-queue motion value at zero offset; next command on following pass',
                    'busy_sprite_ticks': 'pre-hop motion is zero; auto-animate still ticks before offset update'},
            'source_words': {f'{a:#010x}': f'{w:#010x}' for a, w in anchors.items()},
            'scope': 'all five motion fragments lower through the shared decoder; native actor tracks support holds and hops, including the named temporary Cleo track; seven dialogue bodies and source names/portraits are exported; named temporary facing and dialogue anchors are supported; complete arrival binding is candidate-only with verified actor art; field music ownership and settled NPC retention are implemented; playback, original audio-poll cadence and full scene execution remain unqualified'}


def outputs():
    main, origin = source('MAIN.EXE')
    if origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported MAIN identity')
    base = struct.unpack_from('<I', main, 0x18)[0]

    def read(address, size):
        offset = 2048 + address - base
        if offset < 2048 or offset + size > len(main):
            raise ValueError('auto-route reference outside MAIN image')
        data = main[offset:offset + size]
        if data != maindec.body()[address - maindec.MBASE:address - maindec.MBASE + size]:
            raise ValueError('independent MAIN extractions disagree')
        return data

    def word(address):
        return struct.unpack('<I', read(address, 4))[0]

    for address, expected in {0x800c1b10: 0x80141b48, 0x80141b5c: 0x34420008,
                              0x80141b64: 0xa06201b6, 0x800c1b88: 0x80141cd4,
                              0x80131180: 0x34040014, 0x801312ec: 0x38420008,
                              0x801286f0: 0xa020f2a6, 0x801286fc: 0xa022f2a7}.items():
        if word(address) != expected:
            raise ValueError(f'crossing lifecycle source changed at {address:#x}')
    for address, expected in {0x8013c144: 0xa0450001, 0x8013c174: 0xa4a40004,
                              0x8013c22c: 0xa4a30006, 0x801313fc: 0x94820004,
                              0x80131404: 0xac620028, 0x80131410: 0x94850006,
                              0x80131450: 0xac65002c, 0x80131768: 0x90620028,
                              0x80131774: 0xa2020000, 0x80131778: 0x9062002c,
                              0x80131798: 0xa022bd75}.items():
        if word(address) != expected:
            raise ValueError('literal source arrival writer/consumer changed')

    dx = [struct.unpack('<h', read(0x8016f31c + i * 4, 2))[0] for i in range(4)]
    dy = [struct.unpack('<h', read(0x8016f32c + i * 4, 2))[0] for i in range(4)]
    if list(zip(dx, dy)) != [(0, -1), (1, 0), (0, 1), (-1, 0)]:
        raise ValueError('world direction mapping changed')
    routes = []
    for selector in range(5):
        address = word(0x8016f2f0 + selector * 4)
        cursor, pairs = address, []
        for _ in range(128):
            direction = read(cursor, 1)[0]
            cursor += 1
            if direction == 255:
                break
            count = read(cursor, 1)[0]
            cursor += 1
            if direction >= 4 or count == 0:
                raise ValueError('unsupported auto-route segment')
            pairs.append({'direction': DIRECTIONS[direction], 'count': count})
        else:
            raise ValueError('unterminated auto-route')
        raw = read(address, cursor - address)
        independent = []
        for direction, count in struct.iter_unpack('BB', raw[:-1]):
            independent.extend([DIRECTIONS[direction]] * count)
        expanded = [pair['direction'] for pair in pairs for _ in range(pair['count'])]
        if independent != expanded or len(raw) != len(pairs) * 2 + 1:
            raise ValueError('auto-route expansion disagrees or leaves bytes')
        routes.append({'id': selector, 'source_address': address, 'source_bytes': raw.hex(),
                       'consumed': len(raw), 'steps': len(expanded), 'segments': pairs})

    overlay, boat_origin = source('/VB2.BIN')
    if boat_origin['sha256'] != VB2_SHA256:
        raise ValueError('unsupported Kaku identity')
    entity = scene.entities(overlay, scene.room_record(overlay, 0))[21]
    predicate, _ = decode_predicate(overlay, entity['stream_offsets'][0], 'classification')
    terms = predicate['terms']
    if terms != [{'kind': 'story_mask_set', 'flag': {'id': 'scenario_0012', 'mask': 1}},
                 {'kind': 'story_mask_clear', 'flag': {'id': 'scenario_0012', 'mask': 32}}]:
        raise ValueError('first crossing eligibility changed')
    fragment = bytes.fromhex('420c42144e0403fb09774bfd')
    if overlay[0x2bfc0:0x2bfc0 + len(fragment)] != fragment:
        raise ValueError('first crossing mode/route/return changed')
    boarding_rows = []
    for row in decode_stream(overlay, entity['stream_offsets'][2], max_insns=32):
        boarding_rows.append(row)
        if row[1] == 0xfd:
            break
    if [r[1] for r in boarding_rows] != [0x0b, 0x12, 0x1c, 0x02, 0x0c, 0x46,
                                        0x32, 0x32, 0x32, 0x33, 0x0a, 0x42, 0x42, 0x4e, 0x03, 0xfd]:
        raise ValueError('first crossing boarding sequence changed')
    compact = [e for e in scene.entities(overlay, scene.room_record(overlay, 0))
               if e['flags'] & 0x101 and e['stream_offsets'][0] is not None]
    if [(e['index'], e['id']) for e in compact[:5]] != [(12, 125), (15, 132), (18, 125), (21, 32), (22, 38)]:
        raise ValueError('first crossing compact actor references changed')
    for address, expected in {0x8012ef48: 0x30420101, 0x8013d8f4: 0x34020001,
                              0x8012f2f8: 0x00000000, 0x8012f300: 0x0804bce6,
                              0x8012f308: 0x14620023, 0x8012f380: 0x24420001,
                              0x8013c3e0: 0x8c63daa0, 0x8012dc9c: 0x104000c1}.items():
        if word(address) != expected:
            raise ValueError(f'boarding actor/terrain source changed at {address:#x}')
    boarding_tracks = []
    for row, selector in zip(boarding_rows[6:9], (3, 4, 128), strict=True):
        if row[2] != bytes((selector, 2, 5, 1, 0, 5)):
            raise ValueError('boarding motion changed')
        boarding_tracks.append({'offset': row[0], 'selector': selector,
                                'entity': compact[selector]['index'] if selector != 128 else None,
                                'character': compact[selector]['id'] if selector != 128 else 8,
                                'commands': [{'kind': 'move', 'direction': 'down', 'cells': 5},
                                             {'kind': 'move', 'direction': 'right', 'cells': 0},
                                             {'kind': 'finish'}]})
    x, y = 119, 75
    for segment in routes[4]['segments']:
        direction = DIRECTIONS.index(segment['direction'])
        x += dx[direction] * segment['count']
        y += dy[direction] * segment['count']
    if (x, y) != (100, 74):
        raise ValueError('first crossing endpoint changed')
    point_address = word(0x80170064 + 9 * 4) + 44 * 14
    point = read(point_address, 14)
    px, py = struct.unpack_from('<HH', point, 2)
    if point[:2] != bytes((9, 0)) or not (px <= x <= px + 1 and py <= y <= py + 1):
        raise ValueError('first crossing no longer reaches the initial island point')
    if word(0x8016f37c + point[0] * 4) != 0x80128874 or word(0x80128898) != 0x30420020:
        raise ValueError('initial island point eligibility consumer changed')
    descriptor = word(word(0x8016f67c + 9 * 4) + 44 * 4)
    size, lba = struct.unpack('<II', read(descriptor, 8))
    _, island_origin = source('/VB5I0.BIN')
    if (size, lba) != (island_origin['size'], island_origin['lba']):
        raise ValueError('island descriptor disagrees with catalog extraction')
    arrival = initial_island(read, word)
    ruins, ruins_origin = source('/VB5.BIN')
    passages = [door for room in RUINS_ROOMS
                for entity in scene.entities(ruins, scene.room_record(ruins, room))
                if (door := ruins_door(ruins, room, entity['index'])) is not None]
    if len(passages) != 23:
        raise ValueError('ruins passage inventory changed')
    frontier_entity = scene.entities(ruins, scene.room_record(ruins, 19))[1]
    frontier_start = frontier_entity['stream_offsets'][2]
    if ruins[frontier_start:frontier_start + 9] != bytes.fromhex('41 06 03 fc 06 04 0a 0b fd'):
        raise ValueError('ruins onward frontier changed')
    hq, frontier_origin = source('/VB7.BIN')
    frontier_descriptor = word(word(0x8016f67c + 9 * 4) + 6 * 4)
    if struct.unpack('<II', read(frontier_descriptor, 8)) != (frontier_origin['size'], frontier_origin['lba']):
        raise ValueError('ruins onward module disagrees with independent catalog')
    hq_passages = [door for room in HQ_ROOMS
                   for entity in scene.entities(hq, scene.room_record(hq, room))
                   if (door := ruins_door(hq, room, entity['index'], '/VB7.BIN')) is not None]
    if len(hq_passages) != 5:
        raise ValueError('headquarters passage inventory changed')
    # Script records exist even when the scenery-only room helper omits a null section.
    record_off = scene.room_table(ruins) + 16
    raw_room = ruins[record_off:record_off + 16]
    entity_off = scene.ptr_at(ruins, record_off)
    ghost = scene.entities(ruins, {'entity_off': entity_off, 'entity_count': raw_room[4]})
    if raw_room.hex() != '681d0180050100000102000000000000' or len(ghost) != 5:
        raise ValueError('primary ghost script record changed')
    direct = [struct.unpack_from('<III', ruins, entity_off + i * 24 + 12) for i in range(5)]
    if direct != [tuple(entry['stream_ptrs']) for entry in ghost] or scene.section_off(ruins, 1) is not None:
        raise ValueError('primary ghost script readers disagree')
    founded = []
    for file, rooms in FOUNDED_ROOMS.items():
        data, _ = source(file)
        for room in rooms:
            for entity in scene.entities(data, scene.room_record(data, room)):
                door = founded_door(data, file, room, entity['index'])
                if door is not None:
                    founded.append(door)
    if len(founded) != 14 or not all(door['target_walkable'] for door in founded):
        raise ValueError('founded headquarters passage inventory changed')
    report = {'schema': 'suikoden-scripted-travel-proof/77', 'main': origin, 'free_party_recoveries': free_party_recoveries(), 'kouan': kouan_entry(), 'kouan_giovanni': kouan_giovanni(), 'krin_plan': krin_plan(), 'kouan_mansion_approach': kouan_mansion_approach(), 'kouan_mansion_doors': kouan_mansion_doors(), 'kouan_ladder': kouan_ladder(), 'kouan_juppo': kouan_juppo(), 'kouan_wheel': kouan_wheel(), 'item_overload': item_overload(),
              'decoder': 'export_scripted_travel.py/3', 'routes': routes,
              'initial_island': arrival,
              'dock_arrival': dock_arrival(read, word),
              'ruins_passages': {'source': ruins_origin, 'room_table_count': 20,
                                 'rooms': list(RUINS_ROOMS), 'doors': passages,
                                 'frontier': {'room': 19, 'entity': 1, 'stream_offset': frontier_start,
                                              'area': 6, 'destination_room': 4, 'spawn_pixels': [80, 88],
                                              'descriptor': frontier_descriptor, 'module': frontier_origin,
                                              'status': 'candidate passage bound; headquarters-founding event binds in candidate36; native execution remains unverified'},
                                 'ghost_room': {'room': 1, 'record_offset': record_off, 'record_bytes': raw_room.hex(),
                                                'entities': ghost, 'section': 1, 'section_present': False,
                                                'status': 'primary scripts exist; graphics-bank selection remains unresolved; no G-bank substitution'},
                                 'scope': '22 intra-module doors plus the area6 handoff with source audio; original spawns retained; original loader-poll cadence, chests and room1 graphics-bank selection remain separate'},
              'hq_passages': {'source': frontier_origin, 'rooms': list(HQ_ROOMS), 'doors': hq_passages,
                              'entry_music': hq_entry_music(),
                              'founding': hq_founding(),
                              'scope': 'four intra-module passages, exact return to VB5 room19 and room4 music initializer; area40 exit and founding event binds in candidate36; native execution remains unverified'},
              'founded_passages': {'rooms': FOUNDED_ROOMS, 'doors': founded,
                                   'mathiu_briefing': hq_mathiu_briefing(),
                                   'departure': hq_departure(),
                                   'scope': 'fourteen exact-spawn passages connect upper headquarters, middle floor and courtyard; actor scenes, services and Kirkis recruitment remain separate'},
              'first_crossing': {'source': boat_origin, 'room': 0, 'entity': 21,
                                 'eligibility': terms, 'fragment_offset': 0x2bfc0,
                                 'boarding': {'stream_offset': entity['stream_offsets'][2],
                                              'tracks': boarding_tracks, 'wait_updates': 25,
                                              'queue_join_offset': boarding_rows[9][0]},
                                 'fragment_bytes': fragment.hex(), 'selector': 4,
                                 'world_region': 9, 'start': [119, 75], 'end': [x, y],
                                 'point': {'index': 44, 'address': point_address, 'kind': point[0],
                                           'camera': [px, py], 'room': point[1],
                                           'spawn_pixels': [point[6] * 8, point[7] * 8],
                                           'module': island_origin, 'descriptor': descriptor}},
              'consumers': ['MAIN 801278B4: expand direction/count pairs through FF',
                            'MAIN 80127784: consume one direction when movement is ready',
                            'MAIN 801275E0: direction vectors',
                            'MAIN 80128874: kind9 admits tier0 while scenario29 mask32 is clear',
                            'MAIN 80130F48: region/point to field module descriptor'],
              'lifecycle': {'departure': '42 14 reaches MAIN80141B48, ORs GS+1B6 bit8 = scenario38 mask8',
                            'world_cleanup': 'MAIN801286F0/801286FC restores foot mode and selectorFF on field entry',
                            'field_music': 'MAIN80131180 selects query14; 801312D0/801312EC consumes the flag and skips the point music request'},
              'scope': 'Journey crossing ownership and candidate water/boat presentation are implemented; source boarding/departure and island programs export into a separate loadable candidate; canonical dice admission, carried water phase, timing/media acceptance and onward ruins events remain pending'}
    zig = ['//! Generated by kit/tools/export_scripted_travel.py; see its retained proof.',
           'pub const Direction = enum(u2) { north, east, south, west };',
           'pub const Pair = struct { direction: Direction, count: u8 };',
           'pub const sequences = [_][]const Pair{']
    for route in routes:
        segments = ', '.join('.{ .direction = .%s, .count = %d }' % (p['direction'], p['count']) for p in route['segments'])
        zig.append('    &.{ ' + segments + ' },')
    zig.append('};')
    zig.extend(['pub const first_crossing = .{',
                '    .world_room = "world_j",',
                '    .island_room = "vb5i0_room_0",',
                f'    .caller_sha256 = "{boat_origin["sha256"]}",',
                '    .selector = @as(u8, 4),',
                '    .start = [2]u16{ 119, 75 },',
                f'    .point = [2]u16{{ {px}, {py} }},',
                f'    .spawn = [2]u16{{ {point[6] * 8}, {point[7] * 8} }},',
                '};'])
    rays = report['hq_passages']['founding']['effects']['rays_q12']
    effect_zig = ('//! Generated by kit/tools/export_scripted_travel.py; source quarter-wave ray directions.\n'
                  'pub const rays_q12 = [180][2]i16{\n' +
                  ''.join('    .{ %d, %d },\n' % tuple(pair) for pair in rays) + '};\n')
    wheel = report['kouan_wheel']['rules']
    outcome_names = ('passage', 'lose_experience', 'medicine', 'monster', 'gain_experience', 'special_item', 'nothing')
    wheel_zig = ['//! Generated wheel rules; angles are degrees and durations are game updates.',
                 'pub const event_json = @embedFile("kouan_wheel_events.json");',
                 'pub const schema = "suikoden-wheel-motion/2";',
                 'pub const Outcome = enum(u3) { ' + ', '.join(outcome_names) + ' };']
    for name, field, kind in (('initial_speed', 'initial_speed_degrees_per_update', 'u8'),
            ('initial_distance', 'initial_distance_degrees', 'i16'), ('random_divisor', 'random_distance_divisor', 'u15'),
            ('slowdown_below', 'deceleration_below_degrees', 'i16'), ('slowdown_threshold', 'deceleration_accumulator_threshold', 'u8'),
            ('continued_speed', 'continued_speed_degrees_per_update', 'u8'),
            ('extra_draw_from_start', 'extra_discarded_random_draw_from_spin', 'i16'),
            ('alignment_angle', 'alignment_angle_degrees', 'u16'), ('turn_degrees', 'turn_degrees', 'u16')):
        wheel_zig.append(f'pub const {name}: {kind} = {wheel[field]};')
    wheel_zig.extend(['pub const Interval = struct { first_degree: u16, last_degree: u16, outcome: Outcome };',
                      'pub const intervals = [_]Interval{'])
    for interval in wheel['angle_intervals']:
        wheel_zig.append('    .{ .first_degree = %d, .last_degree = %d, .outcome = .%s },' %
                         (interval['first_degree'], interval['last_degree'], outcome_names[interval['outcome']]))
    wheel_zig.append('};')
    geometry = report['kouan_wheel']['geometry']
    wheel_zig.extend(['pub const map_tile_pixels: u16 = %d;' % geometry['projection']['tile_pixels'],
                      'pub const map_viewport_pixels = [2]u16{ %d, %d };' % tuple(geometry['projection']['viewport_pixels']),
                      'pub const auxiliary_drop_pixels: i16 = %d;' % geometry['auxiliary_below_primary_pixels'],
                      'pub const orbit_offsets = [360][2]i16{'])
    wheel_zig.extend('    .{ %d, %d },' % tuple(pair) for pair in geometry['primary_relative_to_translation'])
    wheel_zig.extend(['};', 'pub const rotation_basis_q12 = [360][2]i16{'])
    wheel_zig.extend('    .{ %d, %d },' % tuple(pair) for pair in geometry['rotation_basis_q12'])
    wheel_zig.append('};')
    shadow = geometry['actor_drawing']['auxiliary']
    for name, value in (('shadow_variant', shadow['source_variant']), ('shadow_frame', shadow['source_frame']), ('shadow_shade', shadow['shade'])):
        wheel_zig.append('pub const %s: u8 = %d;' % (name, value))
    for name, key, kind in (('shadow_crop', 'crop_pixels', 'u16'), ('shadow_anchor', 'anchor_pixels', 'i16'),
                            ('shadow_sheet_size', 'sheet_pixels', 'u16'), ('shadow_extent', 'projected_extent_pixels', 'i16')):
        wheel_zig.append('pub const %s = [2]%s{ %d, %d };' % (name, kind, *shadow[key]))
    overload = report['item_overload']
    overload_zig = ['//! Generated source overload labels and timing.', 'pub const settle_updates: u8 = %d;' % overload['settle_updates']]
    for name, label in overload['labels'].items():
        overload_zig.append('pub const %s = %s;' % (name, json.dumps(label)))
    callback = report['founded_passages']['mathiu_briefing']['party_callback']
    layout = callback['windows']
    selector_zig = ['//! Generated selector layout; coordinates remain draw-environment-relative.',
                    'pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };',
                    f'pub const window_open_cue: u16 = {layout["window_open_cue"]};',
                    f'pub const transition_updates: u8 = {layout["transition_updates"]};']
    for prefix, entries in (('admit', layout['windows']), ('eject', layout['eject_windows'])):
        for entry in entries:
            label = 'main' if entry['id'] == 'main' else prefix + '_' + entry['id']
            fields = ', '.join(f'.{key} = {value}' for key, value in entry['pixels'].items())
            selector_zig.append(f'pub const {label}: Rect = .{{ {fields} }};')
    draw_origin = callback['window_drawing']['draw_origin']
    selector_zig.extend([f'pub const origin_x: i32 = {draw_origin["x"]};',
                         f'pub const origin_y: i32 = {draw_origin["y"]};'])
    separator = callback['name_lists']['page_footer']['separator_art']
    selector_zig.append('pub const page_separator_pixels = [12][8]u8{')
    selector_zig.extend('    .{ ' + ', '.join(map(str, row)) + ' },' for row in separator['pixels'])
    selector_zig.append('};')
    selector_zig.append('pub const page_separator_colors = [4][3]u8{')
    selector_zig.extend('    .{ ' + ', '.join(map(str, row)) + ' },' for row in separator['colors'])
    selector_zig.append('};')
    detail = callback['details']
    selector_zig.append('pub const DetailField = enum { ' + ', '.join(r['field'] for r in detail['numbers']) + ' };')
    selector_zig.append('pub const DetailNumber = struct { field: DetailField, label: []const u8, column: u8, row: u8, width: u8 };')
    selector_zig.append('pub const detail_numbers = [_]DetailNumber{')
    for row in detail['numbers']:
        selector_zig.append('    .{ .field = .%s, .label = %s, .column = %d, .row = %d, .width = %d },' %
                            (row['field'], json.dumps(row['label']), row['column'], row['row'], row['width']))
    selector_zig.append('};')
    for name, label in detail['labels'].items():
        selector_zig.append(f'pub const detail_{name}_label = ' + json.dumps(label) + ';')
    portrait_data = callback['portraits']
    selector_zig.append('pub const Portrait = struct { id: []const u8, admit_plane_sha256: []const u8, eject_plane_sha256: []const u8, palette_sha256: []const u8 };')
    selector_zig.append('pub const portraits = [_]Portrait{')
    for row in portrait_data['portraits']:
        selector_zig.append('    .{ ' + ', '.join('.' + key + ' = ' + json.dumps(row[key]) for key in ('id', 'admit_plane_sha256', 'eject_plane_sha256', 'palette_sha256')) + ' },')
    selector_zig.append('};')
    selector_zig.append('pub const portrait_rect: Rect = .{ ' + ', '.join('.%s = %d' % (k,v) for k,v in portrait_data['relative_rect'].items()) + ' };')
    selector_zig.append('pub const choices = ' + json.dumps('\n'.join(callback['choices'])) + ';')
    for name, prompt in layout['prompts'].items():
        selector_zig.append(f'pub const {name}_prompt = ' + json.dumps(prompt['text']) + ';')
    from export_opening_field_package import wheel_event_content
    return report, {'kit/data/reports/scripted_travel.json': serialize(report),
                    'game/assets/travel/kouan_wheel_events.json': serialize(wheel_event_content()),
                    'game/assets/party_session/selector.zig': ('\n'.join(selector_zig) + '\n').encode(),
                    'game/assets/travel/founding_effects.zig': effect_zig.encode(),
                    'game/assets/travel/kouan_wheel.zig': ('\n'.join(wheel_zig) + '\n').encode(),
                    'game/assets/travel/item_overload.zig': ('\n'.join(overload_zig) + '\n').encode(),
                    'game/assets/travel/scripted_routes.zig': ('\n'.join(zig) + '\n').encode()}


if __name__ == '__main__':
    raise SystemExit(run_exporter(None, root=ROOT, description=__doc__, build_outputs=outputs,
                                 summary=lambda report: 'world auto-routes, first Kaku crossing and headquarters progression',
                                 error_types=(ValueError, OSError), error_prefix='scripted travel'))
