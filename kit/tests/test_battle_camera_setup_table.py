#!/usr/bin/env python3
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
text=(ROOT/'kit/data/reports/battle_camera_setup_table.md').read_text()
assert '| wrapper | driver | dispatcher | action | name source | sites (range*) |' in text
assert '## Unassigned camera sites' in text
main=text.split('## Unassigned camera sites')[0]
rows=[line for line in main.splitlines() if line.startswith('| 0x')]
assert len(rows)==38, len(rows)
assert '| 0x8010508C | 0x801050B4 | 0x80105130, 0x801052F8 | Charm Arrow | setup table |' in text
assert '0x800FF800' in text
assert '0x8010A974*' in text
assert '| 0x80116638 | 0x80116660 | 0x80116B7C |' in text
print('ok   38 setup rows and unassigned section')
