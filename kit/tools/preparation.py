"""Export equipment and weapon preparation as semantic, character-keyed data."""
import hashlib
import re
import struct

import character_table
import item_tables
import maindec as main
from export_first_room import source


def stable_id(name):
    return re.sub(r'[^a-z0-9]+', '_', name.lower()).strip('_')


def compatible(header, flags, kind):
    restriction = flags & 0xF00
    character_type = header[10]
    if restriction and character_type < 4 and not restriction & [0x100, 0x200, 0x800, 0x400][character_type]:
        return False
    return bool(kind & header[11])


def rune_bindings():
    result = []
    for index in range(1,30):
        rune, crystal = struct.unpack_from('<HH', main.body(), 0x8016B080-main.MBASE+index*4)
        pointer = main.mword(0x8016A0E0+4*rune)
        item_pointer = main.mword(0x80167658+4*crystal)
        name = item_tables.name_at(item_pointer,24)
        result.append(dict(rune=rune, pointer=pointer, crystal=crystal,
            id=stable_id(name), name=name, price=main.mword(item_pointer+24),
            restricted=bool(item_tables.half(pointer+22)&0x8000)))
    return result


def crystal_goods():
    return [dict(id=row['id'],name=row['name'],price=row['price'],uses=0) for row in rune_bindings()]


def equipment_goods():
    result = []
    for record in item_tables.items():
        if not item_tables.half(record['addr'] + 28) & 0x80:
            continue
        result.append(dict(id=stable_id(record['name']), name=record['name'], price=record['price'], uses=0))
    return result


def weapon_element(seed):
    pointer = main.mword(0x80165890 + 4 * seed['weapon_id'])
    code = main.body()[pointer - main.MBASE + 0x55]
    return ('fire', 'water', 'earth', 'lightning', 'wind')[code - 1] if 1 <= code <= 5 else None


def bind_weapon_elements(content):
    records = {stable_id(row['name']): row for row in character_table.records()}
    for profile in content['party']:
        seed = records[profile['id']]
        weapon = profile['weapon']
        element = weapon_element(seed)
        if weapon.get('element', element) != element:
            raise ValueError('weapon element differs from source: ' + profile['id'])
        if element is not None:
            weapon['element'] = element
    schema=content.get('schema','suikoden-battle-trial/0');prefix='suikoden-battle-trial/'
    if not isinstance(schema,str) or not schema.startswith(prefix) or not schema[len(prefix):].isdecimal():
        raise ValueError('invalid battle schema for weapon elements')
    if int(schema[len(prefix):])<33:
        content['schema'] = 'suikoden-battle-trial/33'


def export(content, native_ids):
    records = {r['id']: r for r in character_table.records()}
    headers, witnesses = {}, []
    for profile, native_id in zip(content['party'], native_ids, strict=True):
        data, proof = source('/' + records[native_id]['sprite_file'])
        headers[profile['id']] = data[:32]
        profile['rune_locked'] = bool(records[native_id]['rune_locked'])
        witnesses.append(dict(character=profile['id'], source=proof,
                              header_sha256=hashlib.sha256(data[:32]).hexdigest()))
        seed = records[native_id]
        pointer = main.mword(0x80165890 + 4 * seed['weapon_id'])
        start = pointer-main.MBASE
        first, second = main.body()[start+0x15], main.body()[start+0x31]
        names = [item_tables.name_at(pointer+off, 0x1C) or item_tables.literal_at(pointer+off, 0x15) for off in (0, 0x1C, 0x38)]
        if any(name is None for name in names):raise ValueError('Unbound weapon name slot')
        curve = main.body()[start+0x54]
        profile['weapon'] = dict(initial_level=seed['weapon_level'],
            names=[names[0 if level < first else 1 if level < second else 2] for level in range(1,17)],
            powers=[item_tables.half(0x801659D0+32*curve+2*index) for index in range(16)],
            upgrade_costs=[main.mword(0x8016AF2C+4*index) for index in range(16)])
        element = weapon_element(seed)
        if element is not None:
            profile['weapon']['element'] = element
        witnesses[-1]['weapon_element'] = dict(source='MAIN.EXE', lba=main.EXE_LBA,
            offset=main.EXE_HEADER + pointer - main.MBASE + 0x55,
            code=main.body()[start + 0x55], element=element)
    gear = []
    for record in item_tables.items():
        flags = item_tables.half(record['addr'] + 28)
        if not flags & 0x80: continue
        kind = item_tables.byte(record['addr'] + 30)
        gear.append(dict(id=stable_id(record['name']), name=record['name'],
            category={0x80:'head', 0xA0:'body', 0xC0:'shield', 0xE0:'accessory'}[flags & 0xE0],
            bonuses=list(struct.unpack_from('<8b', main.body(), record['addr']-main.MBASE+32)),
            allowed_members=[id for id, header in headers.items() if compatible(header, flags, kind)]))
    content['systems']['equipment'] = gear
    native_runes = {row['addr']:row for row in item_tables.runes()}
    for row in rune_bindings():
        name = native_runes[row['pointer']]['name']
        rune = next(r for r in content['systems']['runes'] if r['name']==name)
        if row['rune'] in (8,13): rune['physical']=dict(power=2,recovery_rounds=1)
        rune.update(crystal=row['id'],allowed_members=[id for id,header in headers.items() if not row['restricted'] or row['rune'] in header[12:20]])
    return dict(exporter='preparation.py v2', characters=witnesses,
                consumers=['MAIN.EXE:0x800D47AC', 'MAIN.EXE:0x800D4EC0', 'MAIN.EXE:0x800F8A9C', 'MAIN.EXE:0x800F8B78', 'MAIN.EXE:0x800F881C'],
                policy='Compatibility is resolved during export; original masks stay outside gameplay. Ownership and spare-copy replacement are checked by the runtime loadout.')
