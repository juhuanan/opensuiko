#!/usr/bin/env python3
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
r=json.loads((ROOT/'kit/data/reports/battle_camera_consumer_scan.json').read_text())
assert len(r['wrappers'])==38
for wrapper, refs in r['wrappers'].items():
    assert refs, wrapper
    assert all(0x8016D600 <= int(ref,16) < 0x8016EC00 for ref in refs), (wrapper, refs)
for value, refs in r['table_bases'].items():
    assert refs == [], (value, refs)
print('ok   wrappers referenced only by their own table records')
