#!/usr/bin/env python3
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
rows=json.loads((ROOT/'kit/data/reports/battle_spell_names.json').read_text())
names=[r['name'] for r in rows if r['name']]
assert len(names)==33, names
assert names[0]=='Flaming Arrows'
assert 'Drops of Kindness' in names
assert 'Wind of Sleep' in names
assert 'Deadly Fingertips' in names
assert names[-1]=='Guardian of Earth'
print('ok   33 battle spell names')
