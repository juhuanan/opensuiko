#!/usr/bin/env python3
"""Render the per-site battle camera table."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITES = ROOT / 'kit/data/reports/battle_camera_sites.json'


def main():
    rows = json.loads(SITES.read_text())
    print('| site | function | action | purpose | family | block | frames | owner | installer |')
    print('|---|---|---|---|---|---|---|---|---|')
    for row in rows:
        print(f"| {row['site']} | {row['function']} | {row['action']} | {row.get('purpose') or '-'} | {row['family']} | "
              f"{row['block'] or '-'} | {row['frames'] if row['frames'] is not None else '-'} | "
              f"{row.get('owner') or (row.get('range_owner') + '*') if row.get('range_owner') else '-'} | {row.get('installer') or '-'} |")


if __name__ == '__main__':
    main()
