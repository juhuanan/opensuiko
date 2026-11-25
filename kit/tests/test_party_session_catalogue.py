#!/usr/bin/env python3
"""Independent field slices against the party source-facts exporter."""
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import character_table


def check():
    catalog = json.loads((ROOT / 'game/assets/party_session/catalogue.json').read_text())
    image = character_table.image()
    rows = catalog['characters']
    assert len(rows) == 78
    assert len({row['id'] for row in rows}) == len({row['source_character_id'] for row in rows}) == 78
    for i, row in enumerate(rows):
        raw = image[character_table.IMAGE_OFF + 80*i:character_table.IMAGE_OFF + 80*(i+1)]
        seed = row['seed']
        assert row['source_character_id'] == struct.unpack_from('<I', raw)[0]
        assert (seed['max_hp'], seed['hp']) == struct.unpack_from('<HH', raw, 4)
        assert seed['charges'] == list(raw[9:13])
        assert seed['level'] == raw[13] and seed['experience'] == struct.unpack_from('<H', raw, 14)[0]
        assert seed['stats'] == list(raw[16:22]) and row['growth'] == list(raw[24:30])
        assert seed['weapon']['level'] == raw[0x45]
        assert seed['weapon_element'] == ['none', 'fire', 'water', 'wind', 'thunder', 'earth'][raw[0x46]] and seed['weapon_fragments'] == list(raw[0x47:0x4c])
        assert seed['rune_source_id'] == raw[0x4c] and seed['rune_locked'] == bool(raw[0x4d])
        assert len(seed['inventory']) == raw[0x1f]
        for j, item in enumerate(seed['inventory']):
            assert item['source_item_id'] == struct.unpack_from('<H', raw, 0x20 + 4*j)[0]
            assert item['source_status'] == raw[0x22 + 4*j]
            assert item['uses'] == raw[0x23 + 4*j]
            if item['slot'] is not None:
                assert item['locked'] == bool(raw[0x22 + 4*j] & 0x80)

    known = {row['id']: row['source_character_id'] for row in rows}
    assert known['hero'] == 8 and known['viktor'] == 35 and known['gremio'] == 2
    event = json.loads((ROOT / 'game/assets/events/vb6_room6_arrival.json').read_text())
    def walk(node):
        if isinstance(node, dict):
            if node.get('kind') == 'request_area_party_prefix':
                yield node
            for value in node.values():
                yield from walk(value)
        elif isinstance(node, list):
            for value in node:
                yield from walk(value)
    prefixes = list(walk(event))
    assert len(prefixes) == 1 and prefixes[0]['requested_prefix'] == [8, 2, 4]
    by_source = {row['source_character_id']: row['id'] for row in rows}
    assert [by_source[x] for x in prefixes[0]['requested_prefix']] == ['hero', 'gremio', 'kirkis']
    print('PASS: 78 identity, seed, growth and weapon-fragment source slices; VB6 transient prefix')


if __name__ == '__main__':
    check()
