#!/usr/bin/env python3
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
rows=json.loads((ROOT/'kit/data/reports/battle_actor_camera_scripts.json').read_text())
assert len(rows)==3, rows
by={(r['character'],r['script']):r for r in rows}
assert by[('Tai Ho',9)]['ops']==[{'op':20,'args':[2,20,0,0,0]}]
assert by[('Kirkis',10)]['ops'][0]=={'op':20,'args':[0,20,0,0,0]}
assert [o['op'] for o in by[('Kirkis',10)]['ops']]==[20,19,17]
print('ok   3 character camera scripts')
