#!/usr/bin/env python3
"""Scan MAIN and disc files for static references to the setup table."""
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import disc
import maindec

ROOT = Path(__file__).resolve().parents[2]
OWNERSHIP = ROOT / 'kit/data/reports/battle_camera_ownership.json'
FILES = json.loads((ROOT / 'kit/extracted/iso_files.json').read_text())


def main():
    wrappers = [int(row['wrapper'], 16) for row in json.loads(OWNERSHIP.read_text())]
    needles = {wrapper: struct.pack('<I', wrapper) for wrapper in wrappers}
    result = {'wrappers': {}, 'table_bases': {}}
    body = maindec.body()
    for wrapper, needle in needles.items():
        offsets = []
        start = 0
        while True:
            at = body.find(needle, start)
            if at < 0:
                break
            offsets.append(f'0x{maindec.MBASE + at:08X}')
            start = at + 1
        result['wrappers'][f'0x{wrapper:08X}'] = offsets
    for value in (0x8016D638, 0x8016D600, 0x8016D658, 0x8016D6B8):
        needle = struct.pack('<I', value)
        offsets = []
        for entry in FILES:
            if entry['size'] > 8_000_000:
                continue
            try:
                data = disc.extract(entry['lba'], entry['size'])
            except Exception:
                continue
            start = 0
            while True:
                at = data.find(needle, start)
                if at < 0:
                    break
                offsets.append(f"{entry['path']}@0x{at:X}")
                start = at + 1
        result['table_bases'][f'0x{value:08X}'] = offsets
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
