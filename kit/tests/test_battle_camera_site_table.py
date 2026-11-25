#!/usr/bin/env python3
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
text=(ROOT/'kit/data/reports/battle_camera_site_table.md').read_text()
rows=[line for line in text.splitlines() if line.startswith('| 0x')]
assert len(rows)==104, len(rows)
assert '| 0x800FEE2C | battle_action_resolver | Flaming Arrows |' in text
assert '0x800FF800' in text
assert '| battle_setup |' in text
assert '| action_setup |' in text
assert '| 0x801053A4 | battle_action_driver_branch_c | Charm Arrow |' in text
print('ok   104 site rows')
