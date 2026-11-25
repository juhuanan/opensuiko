#!/usr/bin/env python3
"""Bridge existing rune/crystal source bindings to the supplied D catalogue."""
import argparse
import hashlib
import json
from pathlib import Path

import item_tables
import preparation


def build(magic_bytes):
    magic = json.loads(magic_bytes)
    if magic['schema'] != 'suikoden-magic-actions-catalogue/1':
        raise ValueError('unsupported magic catalogue')
    native = {row['addr']: row['name'] for row in item_tables.runes()}
    by_name = {row['name']: row for row in magic['runes']}
    if len(by_name) != len(magic['runes']):
        raise ValueError('ambiguous rune names')
    entries = []
    for row in preparation.rune_bindings():
        name = native[row['pointer']]
        rune = by_name[name]
        if rune['crystal_id'] != row['crystal']:
            raise ValueError('magic and source crystal identities disagree: ' + name)
        entries.append(dict(rune_id=rune['key'], source_item_id=row['crystal'], item_id=row['id'], item_name=row['name']))
    if len({entry['rune_id'] for entry in entries}) != len(entries):
        raise ValueError('duplicate rune binding')
    return dict(schema='suikoden-party-rune-crystals/1', magic_sha256=hashlib.sha256(magic_bytes).hexdigest(),
                source='preparation.rune_bindings; item_tables.runes; MAIN 0x8016B080', bindings=entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('magic', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(build(args.magic.read_bytes()), indent=2) + '\n')


if __name__ == '__main__':
    main()
