#!/usr/bin/env python3
"""Independent pointer-table consumer for the rune/crystal identity bridge."""
import json
import hashlib
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import maindec
import item_tables
import preparation


def check():
    bridge = json.loads((ROOT / 'game/assets/party_session/crystals.json').read_text())
    assert bridge['schema'] == 'suikoden-party-rune-crystals/1'
    raw = maindec.body()
    magic_bytes = Path(sys.argv[1]).read_bytes()
    assert hashlib.sha256(magic_bytes).hexdigest() == bridge['magic_sha256']
    magic = json.loads(magic_bytes)
    named = {row['name']: row for row in magic['runes']}
    rows = bridge['bindings']
    assert len(rows) == 29
    for i, row in enumerate(rows, 1):
        offset = 0x8016B080 - maindec.MBASE + 4*i
        rune_id, crystal_id = struct.unpack_from('<HH', raw, offset)
        assert row['source_item_id'] == crystal_id
        item_pointer = struct.unpack_from('<I', raw, 0x80167658 - maindec.MBASE + 4*crystal_id)[0]
        name = item_tables.name_at(item_pointer, 24)
        assert row['item_name'] == name and row['item_id'] == preparation.stable_id(name)
        rune_pointer = struct.unpack_from('<I', raw, 0x8016A0E0 - maindec.MBASE + 4*rune_id)[0]
        rune_name = item_tables.name_at(rune_pointer, 20)
        assert rune_name in named
        assert row['rune_id'] == named[rune_name]['key']
        assert crystal_id == named[rune_name]['crystal_id']
    boar = next(row for row in rows if row['rune_id'] == 'boar')
    assert (boar['source_item_id'], boar['item_id']) == (135, 'boar_crystal')
    print('PASS: 29 independent source rune/crystal pointer-table entries')


if __name__ == '__main__':
    check()
