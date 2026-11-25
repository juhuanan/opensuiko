#!/usr/bin/env python3
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
rows=json.loads((ROOT/'kit/data/reports/battle_camera_ownership.json').read_text())
assert len(rows)==38, len(rows)
assert sum(len(r['handlers']) for r in rows)==39
by={r['wrapper']:{h['handler'] for h in r['handlers']} for r in rows}
assert '0x801052F8' in by['0x8010508C']
assert '0x801082EC' in by['0x80107FB4']
assert '0x8010B404' in by['0x8010B044']
assert '0x80112CA8' in by['0x80112A8C']
assert '0x80119970' in by['0x80119584']
assert '0x80119970' not in by['0x80116638']
print('ok   38 setup wrappers, 39 installed handlers')
by_wrapper={r['wrapper']:r for r in rows}
assert by_wrapper['0x801179BC']['fields'][0]=='0x056B'
assert by_wrapper['0x8011BDE4']['fields'][1]=='0x0005'
