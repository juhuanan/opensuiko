#!/usr/bin/env python3
"""Export the original New Game location/ledger seed; no artwork or runtime state."""
import hashlib
import json
from pathlib import Path
import struct

import area_scene
import character_table
import item_tables
from export_first_room import source, walkable_grid
import maindec as main
from preparation import stable_id

ROOT = Path(__file__).resolve().parents[2]
DEFAULT = ROOT / "kit/data/reports/canonical_start.json"


def export():
    executable, provenance = source("SLUS_002.92")
    if executable[:8] != b"PS-X EXE":
        raise ValueError("expected the original executable header")
    base, size = struct.unpack_from("<II", executable, 0x18)
    image = executable[2048:2048 + size]
    if base != 0x80010000 or len(image) != size:
        raise ValueError("unexpected SLUS image extent")

    def word(address):
        return struct.unpack_from("<I", image, address - base)[0]

    assert word(0x800175F8) == 0xA0400002
    values = {}
    for name, address, store, expected in [
        ("overlay_slot", 0x80017604, 0x80017608, 0xA0620000),
        ("room_slot", 0x80017618, 0x8001761C, 0xA0620001),
        ("x", 0x8001762C, 0x80017630, 0xA4620004),
        ("y", 0x80017634, 0x80017638, 0xA4620006),
    ]:
        instruction = word(address)
        assert instruction & 0xFFFF0000 == 0x34020000
        assert word(store) == expected
        values[name] = instruction & 0xFFFF
    seed = image[0x32FE0:0x34D40]
    if len(seed) != 0x1D60 or not 1 <= seed[3] <= 6:
        raise ValueError("invalid boot template")
    table = (main.mword(0x80130F54) & 0xFFFF) << 16
    low = main.mword(0x80130F58) & 0xFFFF
    table += low - 65536 if low & 0x8000 else low
    group = main.mword(table)
    descriptor = main.mword(group + values["overlay_slot"] * 4)
    size, lba = main.mword(descriptor), main.mword(descriptor + 4)
    data, area_source = source("/VAA.BIN")
    if (area_source["size"], area_source["lba"]) != (size, lba):
        raise ValueError("New Game selector no longer resolves VAA")
    room = area_scene.room_record(data, values["room_slot"])
    # These consumers copy the boot coordinates unchanged, then multiply by8.
    for address, expected in {
        0x801313FC:0x94820004, 0x80131404:0xAC620028,
        0x80131410:0x94850006, 0x80131450:0xAC65002C,
        0x80131768:0x90620028, 0x80131774:0xA2020000,
        0x80131778:0x9062002C, 0x80131798:0xA022BD75,
        0x801317D8:0x000528C0, 0x801317EC:0x000420C0,
        0x80131828:0x00021100, 0x80131860:0x00021100,
    }.items():
        assert main.mword(address) == expected
    signed_immediate = lambda pc: struct.unpack('<h', struct.pack('<H', main.mword(pc)&65535))[0]
    section = area_scene.section_off(data, room['section'])
    width, height = (area_scene.u16(data, section+off)*16 for off in (0,2))
    viewport = dict(width=-signed_immediate(0x8013182C), height=-signed_immediate(0x80131864))
    bias = dict(x=-signed_immediate(0x801317DC), y=-signed_immediate(0x801317F0))
    position = dict(x=values['x']*8, y=values['y']*8)
    camera = dict(x=min(max(position['x']-bias['x'],0),width-viewport['width']),
                  y=min(max(position['y']-bias['y'],0),height-viewport['height']))
    initial_party = []
    goods = {entry['id']:entry for entry in item_tables.items()}
    records = character_table.by_id()
    for slot in seed[0x0E:0x0E+seed[3]]:
        if slot >= 6: raise ValueError("invalid initial party slot")
        native_id = seed[8+slot]
        record = records[native_id]
        _, sprite_source = source('/'+record['sprite_file'])
        inventory, equipped = [], {}
        for item in record['inventory'][:record['inventory_count']]:
            inventory.append(dict(id=stable_id(goods[item['id']]['name']), uses=item['uses']))
            if item['slot_flags']:
                slot_name = {1:'head',2:'body',3:'shield',4:'accessory_one',5:'accessory_two'}.get(item['slot_flags'])
                if slot_name is None: raise ValueError('unsupported initial equipment flag')
                equipped[slot_name] = inventory[-1]['id']
        if record['rune_id'] or record['status']: raise ValueError('unsupported initial rune/status')
        initial_party.append(dict(inventory=inventory, equipped=equipped,
            weapon_level=record['weapon_level'], rune=None, rune_charges=record['spell_charges'],
            id=stable_id(record['name']), name=record['name'], active_slot=slot,
            native_character_id=native_id, record_row=record['row'], level=record['level'],
            hp=record['hp_current'], max_hp=record['hp_max'], experience=record['experience'],
            base_stats=dict(zip(('power','skill','defense','speed','magic','luck'),record['stats'])),
            sprite_source=sprite_source))
    return dict(
        schema="suikoden-canonical-start-evidence/3",
        status="source entry seed; canonical runtime not implemented",
        location=dict(source_file=area_source["file"], area_group=0,
                      overlay_slot=values["overlay_slot"], room_slot=values["room_slot"],
                      source_coordinates=dict(x=values["x"], y=values["y"], units="8-pixel cells")),
        field_entry=dict(position=position, camera=camera, viewport=viewport, camera_bias=bias, room_size=dict(width=width,height=height)),
        money=struct.unpack_from("<I", seed, 0x1C)[0],
        party_count=seed[3], party_slot_order=list(seed[0x0E:0x0E + seed[3]]),
        initial_party=initial_party,
        identity_note="Party order selects active slots; slot0 stores native character8, Hero. Native record lookup and resource lookup independently bind it to the first persistent record and SHU.BIN, not portrait index0.",
        room_entity_count=room["entity_count"],
        initialization_entries=[dict(entry=entry["index"], event_predicate=entry["stream_offsets"][1], stream=entry["stream_offsets"][2]) for entry in area_scene.entities(data, room) if entry["flags"] & 0x10],
        provenance=dict(slus=provenance, image_base=base, image_sha256=hashlib.sha256(image).hexdigest(),
                        new_game_writer="SLUS:0x800175F8..0x80017638", boot_template="SLUS image+0x32FE0..0x34D40",
                        main_loader="MAIN:0x80130F3C..0x80130F74", loader_table=hex(table), area=area_source,
                        identity_consumers=["MAIN:0x800C49CC..0x800C4A44", "MAIN:0x8013875C", "MAIN:0x800C4B94"],
                        room_record=room["record_off"], coordinate_consumers=["MAIN:0x801313E8..0x80131454", "MAIN:0x8013175C..0x8013179C", "MAIN:0x801317AC..0x80131884"],
                        parser="canonical_start.py/3; PS-X EXE header stripped; area_scene.py; character_table.py"),
        unresolved=["name-entry and movie handoff", "initial event classifier feasibility and full story path", "canonical field cadence", "required room/actor media review"],
    )


def runtime():
    """Named startup/ground geometry only; no actor staging or playable New Game."""
    evidence = export()
    data, _ = source('/VAA.BIN')
    rooms = []
    for number in (2,1):
        record = area_scene.room_record(data,number)
        width,height,ground = walkable_grid(data,area_scene.section_off(data,record['section']))
        rooms.append(dict(id=f'vaa_room_{number}',title=f'Palace room {number}',
                          width=width*8,height=height*8,walkable=ground,draws=[],npcs=[],exits=[]))
    # This boundary has no story-bit predicate: do not invent an audience gate.
    entry = area_scene.entities(data,area_scene.room_record(data,2))[0]
    predicate,stream = entry['stream_offsets'][1:]
    p=data[predicate:predicate+7]
    if p[0]!=11 or p[3]!=12 or p[6]!=6: raise ValueError('unsupported opening exit predicate')
    code=data[stream:stream+7]
    if code[:3]!=bytes.fromhex('41 75 03') or code[3]!=1 or code[6]!=253:
        raise ValueError('unsupported opening exit stream')
    rooms[0]['exits'].append(dict(x=p[1]*8,y=p[4]*8,w=(p[2]-p[1]+1)*8,h=(p[5]-p[4]+1)*8,
                                 room='vaa_room_1',spawn_x=code[4]*8,spawn_y=code[5]*8))
    hero,=evidence['initial_party']
    slots=hero['inventory']+[None]*(9-len(hero['inventory']))
    member=dict(id=hero['id'],name=hero['name'],hp=hero['hp'],max_hp=hero['max_hp'],
                status='healthy',rune_charges=hero['rune_charges'],max_rune_charges=hero['rune_charges'],
                inventory=dict(slots=slots))
    initial_hero=dict(member=member,**{key:hero[key] for key in ('level','experience','base_stats','equipped','weapon_level','rune')})
    return dict(schema='suikoden-opening/1',room='vaa_room_2',money=evidence['money'],
                position=evidence['field_entry']['position'],camera=evidence['field_entry']['camera'],
                viewport=evidence['field_entry']['viewport'],camera_bias=evidence['field_entry']['camera_bias'],
                hero=initial_hero,
                rooms=rooms)


if __name__ == "__main__":
    value = export()
    DEFAULT.write_text(json.dumps(value, indent=2) + "\n")
    (ROOT/'game/assets/opening.json').write_text(json.dumps(runtime(),indent=2)+'\n')
    print(json.dumps({key: value[key] for key in ["location", "money", "party_count"]}))
