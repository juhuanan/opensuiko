#!/usr/bin/env python3
"""Source-backed character facts for the private party candidate.

This exports named identities, growth, equipment eligibility and weapon curves;
it does not claim that a source template is an owned or recruited member.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

import character_table
import item_tables
import maindec
import preparation
from export_first_room import source


def build():
    records = character_table.records()
    if len(records) != 78 or len({row['id'] for row in records}) != 78:
        raise ValueError('character IDs are not a 78-record unique catalogue')
    names = [preparation.stable_id(row['name']) for row in records]
    if not all(names) or len(set(names)) != 78:
        raise ValueError('character names do not provide unique named IDs')
    items = {row['id']: row for row in item_tables.items()}
    item_names = Counter(preparation.stable_id(row['name']) for row in items.values() if row['name'])
    def item_id(row):
        name = preparation.stable_id(row['name'])
        return f'{name}__source_{row["id"]}' if item_names[name] > 1 else name
    rune_names = item_tables.rune_names()
    characters = []
    for record, name in zip(records, names, strict=True):
        header, origin = source('/' + record['sprite_file'])
        if header[0] != record['id']:
            raise ValueError('character resource identity mismatch: ' + name)
        address = maindec.mword(0x80165890 + 4 * record['weapon_id'])
        start = address - maindec.MBASE
        raw = maindec.body()
        first, second = raw[start + 0x15], raw[start + 0x31]
        tiers = [item_tables.name_at(address + off, 0x1c) for off in (0, 0x1c, 0x38)]
        curve = raw[start + 0x54]
        weapon = dict(level=record['weapon_level'],
            names=[tiers[0 if level < first else 1 if level < second else 2] for level in range(1, 17)],
            powers=[item_tables.half(0x801659D0 + 32 * curve + 2 * i) for i in range(16)])
        inventory = []
        for entry in record['inventory'][:record['inventory_count']]:
            item = items.get(entry['id'])
            if item is None or not item['name']:
                raise ValueError('unresolved item for ' + name)
            flags = item_tables.half(item['addr'] + 28)
            status = entry['slot_flags']
            equipped = status & 0x7f if flags & 0x80 else 0
            if equipped > 5:
                raise ValueError('unsupported equipment slot for ' + name)
            slot = [None, 'head', 'body', 'shield', 'accessory_one', 'accessory_two'][equipped]
            inventory.append(dict(id=item_id(item), source_item_id=item['id'],
                                  source_status=status, uses=entry['uses'], slot=slot,
                                  locked=bool(slot and status & 0x80),
                                  identified=not (flags & 0x7000) or status == 0xff))
        equipment = []
        for item in items.values():
            flags = item_tables.half(item['addr'] + 28)
            if flags & 0x80 and preparation.compatible(header, flags, item_tables.byte(item['addr'] + 30)):
                equipment.append(item_id(item))
        rune_id = record['rune_id']
        rune_name = rune_names[rune_id - 1] if 0 < rune_id <= len(rune_names) else None
        characters.append(dict(id=name, name=record['name'], source_character_id=record['id'],
            resource=record['sprite_file'], resource_sha256=hashlib.sha256(header).hexdigest(),
            resource_provenance=origin, growth=record['growth'],
            seed=dict(hp=record['hp_current'], max_hp=record['hp_max'], level=record['level'],
                experience=record['experience'], stats=record['stats'], status=('healthy' if record['status'] == 0 else None), source_status=record['status'],
                charges=record['spell_charges'], inventory=inventory,
                weapon=weapon, rune_source_id=rune_id, rune_name=rune_name, rune_unresolved=bool(rune_id and not rune_name), rune_locked=bool(record['rune_locked']),
                weapon_element=['none', 'fire', 'water', 'wind', 'thunder', 'earth'][record['element_type']], weapon_fragments=record['element_coefficients']),
            allowed_equipment=equipment))
    return dict(schema='suikoden-party-source-facts/1', characters=characters,
        scope='Source seed facts only. These do not grant recruitment or provide battle assets. Source rune and status IDs require explicit runtime mappings.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(build(), indent=2) + '\n')


if __name__ == '__main__':
    main()
